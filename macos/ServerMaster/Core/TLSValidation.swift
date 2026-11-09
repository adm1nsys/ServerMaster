import Foundation
import Security

nonisolated enum TLSValidation {
    struct Assessment: Sendable {
        var issues: [String] = []
        var systemTrusted = false
        var selfIssued = false
    }

    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { String(localized: "The certificate or private key could not be read. Use a readable PEM certificate and an unencrypted private key.") }
    }

    static func read(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: AppPaths.expand(path)).resolvingSymlinksInPath()
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw Failure.invalid }
        return data
    }

    static func certificate(_ path: String) throws -> SecCertificate {
        let data = try read(path)
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex),
              let der = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.invalid }
        return cert
    }

    static func host(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value.isEmpty || value == "0.0.0.0" { return "127.0.0.1" }
        return value == "::" ? "::1" : value
    }

    static func check(_ profile: ServerProfile, now: Date = Date()) -> Assessment {
        guard profile.httpsEnabled && profile.engine.supportsHTTPS else { return Assessment() }
        return check(certificatePath: profile.certificatePath, keyPath: profile.privateKeyPath, host: host(profile.host), now: now)
    }

    static func check(certificatePath: String, keyPath: String, host: String, now: Date = Date()) -> Assessment {
        do {
            let cert = try certificate(certificatePath)
            var result = Assessment(issues: certificateIssues(cert, host: host, now: now))
            // Explicit nil importKeychain: transient SecKey references only; no keychain import.
            let data = try read(keyPath)
            guard !String(decoding: data, as: UTF8.self).contains("ENCRYPTED") else { throw Failure.invalid }
            var format = SecExternalFormat.formatUnknown
            var type = SecExternalItemType.itemTypePrivateKey
            var parameters = SecItemImportExportKeyParameters()
            parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
            let passphrase = "" as CFString
            parameters.passphrase = Unmanaged.passUnretained(passphrase) // never request a password dialog
            var items: CFArray?
            let status = withExtendedLifetime(passphrase) { SecItemImport(data as CFData, "pem" as CFString, &format, &type, [], &parameters, nil, &items) }
            guard status == errSecSuccess,
                  let keys = items as? [AnyObject], keys.count == 1,
                  CFGetTypeID(keys[0]) == SecKeyGetTypeID() else { throw Failure.invalid }
            let key = keys[0] as! SecKey
            guard let publicKey = SecKeyCopyPublicKey(key), let certificateKey = SecCertificateCopyKey(cert),
                  let first = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
                  let second = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? else { throw Failure.invalid }
            if first != second { result.issues.append(String(localized: "The certificate and private key do not match.")) }
            result.systemTrusted = result.issues.isEmpty && systemTrust(cert, host: host, now: now)
            if let subject = SecCertificateCopyNormalizedSubjectSequence(cert),
               let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) {
                result.selfIssued = (subject as Data) == (issuer as Data)
            }
            return result
        } catch { return Assessment(issues: [Failure.invalid.localizedDescription]) }
    }

    static func certificateIssues(_ cert: SecCertificate, host: String, now: Date = Date()) -> [String] {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              let before = (values[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? NSNumber,
              let after = (values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? NSNumber else {
            return [String(localized: "The certificate validity dates could not be read.")]
        }
        var issues: [String] = []
        if now < Date(timeIntervalSinceReferenceDate: before.doubleValue) || now >= Date(timeIntervalSinceReferenceDate: after.doubleValue) {
            issues.append(String(localized: "The HTTPS certificate is expired or not yet valid."))
        }
        let names = (values[kSecOIDSubjectAltName as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        let matches = names.contains { item in
            guard let label = item[kSecPropertyKeyLabel as String] as? String,
                  let value = item[kSecPropertyKeyValue as String] as? String else { return false }
            if label == "IP Address" { return sameIP(host, value) }
            guard label == "DNS Name", !isIP(host) else { return false }
            let name = value.lowercased(), host = host.lowercased()
            if name.hasPrefix("*.") {
                let suffix = String(name.dropFirst())
                return host.hasSuffix(suffix) && !host.dropLast(suffix.count).contains(".") && host.count > suffix.count
            }
            return name == host
        }
        if !matches { issues.append(String(localized: "The certificate SAN does not include the profile host.")) }
        return issues
    }

    static func systemTrust(_ cert: SecCertificate, host: String, now: Date = Date()) -> Bool {
        guard certificateIssues(cert, host: host, now: now).isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess, let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, now as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func accepts(_ trust: SecTrust, host: String, expected: SecCertificate?) -> Bool {
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if SecTrustEvaluateWithError(trust, nil) { return true }
        guard let expected, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let presented = chain.first,
              (SecCertificateCopyData(expected) as Data) == (SecCertificateCopyData(presented) as Data),
              certificateIssues(presented, host: host).isEmpty,
              SecTrustSetAnchorCertificates(trust, [expected] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func isIP(_ value: String) -> Bool { sameIP(value, value) }
    private static func sameIP(_ first: String, _ second: String) -> Bool {
        var a = in_addr(), b = in_addr()
        if inet_pton(AF_INET, first, &a) == 1, inet_pton(AF_INET, second, &b) == 1 { return a.s_addr == b.s_addr }
        var x = in6_addr(), y = in6_addr()
        guard inet_pton(AF_INET6, first, &x) == 1, inet_pton(AF_INET6, second, &y) == 1 else { return false }
        return withUnsafeBytes(of: x) { Data($0) } == withUnsafeBytes(of: y) { Data($0) }
    }
}
