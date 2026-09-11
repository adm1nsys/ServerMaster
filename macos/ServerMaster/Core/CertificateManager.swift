//
//  CertificateManager.swift
//  ServerMaster
//

import Foundation
import Observation

nonisolated struct CertificatePair: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var certificatePath: String
    var privateKeyPath: String
    var subject: String?
    var notAfter: Date?
    var domains: [String] = []

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    var daysLeft: Int? {
        guard let notAfter else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day
    }
}

/// The state of the mkcert local certificate authority.
/// Without it the browser complains about the certificate anyway, so this is shown explicitly.
nonisolated struct MkcertStatus: Sendable, Equatable {
    var available = false
    var caRoot: String?
    var caExists = false
    var trustedInSystem = false

    var summary: String {
        if !available { return String(localized: "mkcert is not installed.") }
        if !caExists { return String(localized: "The local CA does not exist yet — it appears on the first generation.") }
        if !trustedInSystem { return String(localized: "The local CA exists but is not in the system keychain: browsers will not trust the certificates yet.") }
        return String(localized: "The local CA is installed — certificates are trusted.")
    }
}

@Observable
final class CertificateManager {

    private(set) var certificates: [CertificatePair] = []
    private(set) var isWorking = false
    private(set) var mkcert = MkcertStatus()

    enum CertError: LocalizedError {
        case opensslMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .opensslMissing: return String(localized: "openssl not found. Install it on the Dependencies tab.")
            case .failed(let message): return message
            }
        }
    }

    func reload() async {
        let dir = AppPaths.certificates
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let names = Set(files.filter { $0.hasSuffix(".crt.pem") }.map { String($0.dropLast(8)) })

        var found: [CertificatePair] = []
        for name in names.sorted() {
            let cert = dir.appendingPathComponent("\(name).crt.pem").path
            let key = dir.appendingPathComponent("\(name).key.pem").path
            guard FileManager.default.fileExists(atPath: key) else { continue }
            var pair = CertificatePair(name: name, certificatePath: cert, privateKeyPath: key)
            await Self.enrich(&pair)
            found.append(pair)
        }
        certificates = found
    }

    /// A self-signed certificate with a SAN — modern browsers reject it otherwise.
    @discardableResult
    func generateSelfSigned(name: String, domains: String, days: Int) async throws -> CertificatePair {
        guard ShellEnvironment.shared.which("openssl") != nil else { throw CertError.opensslMissing }

        isWorking = true
        defer { isWorking = false }

        let safeName = Self.sanitizeName(name)
        guard !safeName.isEmpty else { throw CertError.failed(String(localized: "Empty certificate name.")) }

        let dir = AppPaths.certificates
        let certPath = dir.appendingPathComponent("\(safeName).crt.pem").path
        let keyPath = dir.appendingPathComponent("\(safeName).key.pem").path

        let entries = Self.parseDomains(domains)
        guard !entries.isEmpty else {
            throw CertError.failed(String(localized: "Specify at least one domain or IP address."))
        }
        let sanList = entries.map { entry -> String in
            isIPAddress(entry) ? "IP:\(entry)" : "DNS:\(entry)"
        }.joined(separator: ",")

        let commonName = entries.first ?? "localhost"

        let result = await ProcessRunner.run("openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256",
            "-days", String(max(1, days)), "-nodes",
            "-keyout", keyPath, "-out", certPath,
            "-subj", "/CN=\(commonName)/O=ServerMaster",
            "-addext", "subjectAltName=\(sanList)",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=digitalSignature,keyEncipherment",
            "-addext", "extendedKeyUsage=serverAuth"
        ], timeout: 120)

        guard result.succeeded,
              FileManager.default.fileExists(atPath: certPath),
              FileManager.default.fileExists(atPath: keyPath) else {
            throw CertError.failed(result.combined.isEmpty
                                   ? String(localized: "openssl returned code \(String(result.exitCode))")
                                   : result.combined)
        }

        // The key must not be readable by just anyone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        var pair = CertificatePair(name: safeName, certificatePath: certPath, privateKeyPath: keyPath)
        await Self.enrich(&pair)
        await reload()
        return pair
    }

    /// mkcert issues a certificate the system already trusts.
    @discardableResult
    func generateWithMkcert(name: String, domains: String) async throws -> CertificatePair {
        guard ShellEnvironment.shared.which("mkcert") != nil else {
            throw CertError.failed(String(localized: "mkcert is not installed. Install it on the Dependencies tab."))
        }
        isWorking = true
        defer { isWorking = false }

        let safeName = Self.sanitizeName(name)
        guard !safeName.isEmpty else { throw CertError.failed(String(localized: "Empty certificate name.")) }
        let dir = AppPaths.certificates
        let certPath = dir.appendingPathComponent("\(safeName).crt.pem").path
        let keyPath = dir.appendingPathComponent("\(safeName).key.pem").path

        let entries = Self.parseDomains(domains)
        guard !entries.isEmpty else {
            throw CertError.failed(String(localized: "Specify at least one domain or IP address."))
        }

        let result = await ProcessRunner.run("mkcert",
                                             ["-cert-file", certPath, "-key-file", keyPath] + entries,
                                             timeout: 180)
        // Without a host list mkcert prints its help and exits with code 0
        // without creating any files — so check the result on disk.
        guard result.succeeded,
              FileManager.default.fileExists(atPath: certPath),
              FileManager.default.fileExists(atPath: keyPath) else {
            throw CertError.failed(result.combined.isEmpty
                                   ? String(localized: "mkcert did not create the certificate files.")
                                   : result.combined)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        var pair = CertificatePair(name: safeName, certificatePath: certPath, privateKeyPath: keyPath)
        await Self.enrich(&pair)
        await reload()
        return pair
    }

    // MARK: - The mkcert local CA

    func refreshMkcertStatus() async {
        var status = MkcertStatus()
        defer { mkcert = status }

        guard ShellEnvironment.shared.which("mkcert") != nil else { return }
        status.available = true

        let caRoot = await ProcessRunner.run("mkcert", ["-CAROOT"], timeout: 20)
        let path = caRoot.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            status.caRoot = path
            status.caExists = FileManager.default.fileExists(atPath: path + "/rootCA.pem")
        }

        let trusted = await ProcessRunner.run(
            "/usr/bin/security",
            ["find-certificate", "-c", "mkcert", "/Library/Keychains/System.keychain"],
            timeout: 20)
        status.trustedInSystem = trusted.succeeded
    }

    /// Add the mkcert local CA to the system keychain (will ask for a password).
    func installMkcertCA() async -> CommandResult {
        guard let binary = ShellEnvironment.shared.which("mkcert") else {
            return CommandResult(exitCode: 127, stdout: "", stderr: String(localized: "mkcert is not installed."))
        }
        isWorking = true
        defer { isWorking = false }

        let caRoot = mkcert.caRoot ?? (NSHomeDirectory() + "/Library/Application Support/mkcert")

        // The command runs as root, so CAROOT is set explicitly — otherwise the CA ends
        // up in root's home folder. After installing, the files are handed back to the
        // user so ordinary mkcert runs can read them.
        let command = "CAROOT=\(ProcessRunner.shellQuote(caRoot)) \(ProcessRunner.shellQuote(binary)) -install"
            + " && /usr/sbin/chown -R \(getuid()):\(getgid()) \(ProcessRunner.shellQuote(caRoot))"

        let result = await ProcessRunner.runAsAdmin(
            command,
            prompt: String(localized: "ServerMaster wants to add the local mkcert certificate authority to the system keychain."))
        await refreshMkcertStatus()
        return result
    }

    func delete(_ pair: CertificatePair) async {
        try? FileManager.default.removeItem(atPath: pair.certificatePath)
        try? FileManager.default.removeItem(atPath: pair.privateKeyPath)
        await reload()
    }

    /// Add the certificate to the system keychain as trusted (needs an administrator password).
    func trustInSystemKeychain(_ pair: CertificatePair) async -> CommandResult {
        await ProcessRunner.runAsAdmin(
            "/usr/bin/security add-trusted-cert -d -r trustRoot"
            + " -k /Library/Keychains/System.keychain"
            + " \(ProcessRunner.shellQuote(pair.certificatePath))",
            prompt: String(localized: "ServerMaster wants to add the certificate “\(pair.name)” to the system keychain.")
        )
    }

    // MARK: - Private

    /// The certificate name becomes the file name — strip whatever would break the path.
    nonisolated static func sanitizeName(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned
    }

    nonisolated static func parseDomains(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func enrich(_ pair: inout CertificatePair) async {
        let result = await ProcessRunner.run("openssl",
                                             ["x509", "-in", pair.certificatePath, "-noout",
                                              "-subject", "-enddate", "-ext", "subjectAltName"],
                                             timeout: 20)
        guard result.succeeded else { return }

        for line in result.stdout.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("subject=") {
                pair.subject = String(text.dropFirst("subject=".count)).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("notAfter=") {
                pair.notAfter = parseOpenSSLDate(String(text.dropFirst("notAfter=".count)))
            } else if text.contains("DNS:") || text.contains("IP Address:") {
                pair.domains = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.replacingOccurrences(of: "DNS:", with: "")
                             .replacingOccurrences(of: "IP Address:", with: "") }
                    .filter { !$0.isEmpty }
            }
        }
    }

    private nonisolated static func parseOpenSSLDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        // openssl pads single-digit numbers with a space: "Nov  3 …".
        let normalized = raw
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return formatter.date(from: normalized)
    }

    private func isIPAddress(_ value: String) -> Bool {
        if value.contains(":") { return true }             // IPv6
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}
