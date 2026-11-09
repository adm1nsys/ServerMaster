import Foundation
import CryptoKit
import Darwin

/// Official, app-local distributions. Does not link/unlink Homebrew or change a
/// shell configuration. Selection is committed separately, only after verification.
@MainActor
final class NodeReleases {
    struct Release: Codable, Equatable, Sendable {
        let version: String
        let npm: String
        let architecture: String
        var name: String { "node-\(version)-darwin-\(architecture)" }
        var archive: String { name + ".tar.gz" }
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    typealias Fetch = @Sendable (URL, URL, Int64) async throws -> Void
    typealias Probe = @MainActor (String, [String], [String: String]) async -> CommandResult
    let root: URL
    let architecture: String
    private let fetch: Fetch
    private let probe: Probe
    private var busy = false

    nonisolated static var nativeArchitecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
        return "x64"
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ServerMaster/Runtime/node", isDirectory: true)
    }

    init(root: URL = NodeReleases.defaultRoot, architecture: String = NodeReleases.nativeArchitecture,
         fetch: @escaping Fetch = NodeReleases.download,
         probe: @escaping Probe = { await ProcessRunner.run($0, $1, env: $2, timeout: 15) }) {
        self.root = root.standardizedFileURL
        self.architecture = architecture
        self.fetch = fetch
        self.probe = probe
    }

    nonisolated static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$"#, options: .regularExpression) == (value.startIndex..<value.endIndex)
            && value.count < 40
    }

    nonisolated static func catalogue(_ data: Data, architecture: String) throws -> [Release] {
        guard ["arm64", "x64"].contains(architecture) else { throw Failure(message: String(localized: "Unsupported Node architecture.")) }
        struct Entry: Decodable { let version: String; let files: [String]; let npm: String? }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard validVersion(entry.version), entry.files.contains("osx-\(architecture)-tar"),
                  let npm = entry.npm, validVersion("v" + npm), seen.insert(entry.version).inserted else { return nil }
            return Release(version: entry.version, npm: npm, architecture: architecture)
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    nonisolated static func checksum(_ text: String, filename: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, String(parts[1]) == filename else { return nil }
            return String(parts[0]).lowercased()
        }
        guard matches.count == 1, let value = matches.first,
              value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw Failure(message: String(localized: "The official Node checksum is missing or invalid."))
        }
        return value
    }

    func versions() async throws -> [Release] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("node-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.json")
        try await fetch(URL(string: "https://nodejs.org/dist/index.json")!, index, 8_000_000)
        let releases = try Self.catalogue(Data(contentsOf: index), architecture: architecture)
        guard !releases.isEmpty else { throw Failure(message: String(localized: "The package catalogue returned no supported versions.")) }
        return releases
    }

    func installed() -> [Release] {
        guard let access = try? SiteFileAccess(root: root),
              let entries = try? access.entries(in: access.root) else { return [] }
        return entries.compactMap { entry in
            guard entry.isDirectory, !entry.isLink, Self.validVersion(entry.name) else { return nil }
            // Keep damaged copies visible so an inactive one can be removed in UI.
            return (try? receipt(version: entry.name)) ?? Release(version: entry.name, npm: "", architecture: architecture)
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func bin(version: String) throws -> URL {
        guard Self.validVersion(version) else { throw Failure(message: String(localized: "Choose a Node.js release from the list.")) }
        return root.appendingPathComponent(version + "/bin")
    }

    private func receipt(version: String) throws -> Release {
        let bin = try bin(version: version)
        let access = try SiteFileAccess(root: root)
        let file = try access.checked(bin.deletingLastPathComponent().appendingPathComponent(".servermaster-node.json"))
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) < 4096 else { throw Failure(message: String(localized: "The saved Node copy is invalid. Remove the unused copy and install it again.")) }
        let value = try JSONDecoder().decode(Release.self, from: Data(contentsOf: file))
        guard value.version == version, value.architecture == architecture, Self.validVersion("v" + value.npm) else {
            throw Failure(message: String(localized: "The saved Node copy is invalid. Remove the unused copy and install it again."))
        }
        return value
    }

    /// PATH is computed without changing the shared environment. npm is invoked
    /// explicitly with its bundled Node during verification, never with system Node.
    func verify(version: String) async throws -> URL {
        let release = try receipt(version: version)
        let directory = try bin(version: version).deletingLastPathComponent()
        try await verify(release, directory: directory)
        return directory.appendingPathComponent("bin")
    }

    private func verify(_ release: Release, directory: URL) async throws {
        let access = try SiteFileAccess(root: directory)
        let node = try access.checked(access.root.appendingPathComponent("bin/node"))
        guard try node.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: node.path) else {
            throw Failure(message: String(localized: "The requested Node version could not run on this Mac."))
        }
        let npm = access.root.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
        _ = try access.checked(npm)
        // Official bin/npm and bin/npx are links, but neither may escape this release.
        for command in ["npm", "npx"] {
            let link = access.root.appendingPathComponent("bin/" + command)
            let resolved = link.resolvingSymlinksInPath()
            _ = try access.checked(resolved)
            let expected = access.root.appendingPathComponent("lib/node_modules/npm/bin/\(command)-cli.js")
            guard resolved.standardizedFileURL == expected.standardizedFileURL,
                  FileManager.default.isExecutableFile(atPath: link.path) else {
                throw Failure(message: String(localized: "The downloaded Node archive has no usable npm or npx."))
            }
        }
        var environment = ["PATH": node.deletingLastPathComponent().path + ":" + ShellEnvironment.shared.path]
        let verification = FileManager.default.temporaryDirectory.appendingPathComponent("node-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: verification, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: verification) }
        for name in ["user.npmrc", "global.npmrc"] {
            try Data().write(to: verification.appendingPathComponent(name), options: .withoutOverwriting)
        }
        // Avoid user NODE_OPTIONS/npm config changing or preloading the verifier.
        environment["NODE_OPTIONS"] = ""
        environment["NODE_PATH"] = ""
        environment["NPM_CONFIG_USERCONFIG"] = verification.appendingPathComponent("user.npmrc").path
        environment["NPM_CONFIG_GLOBALCONFIG"] = verification.appendingPathComponent("global.npmrc").path
        environment["NPM_CONFIG_CACHE"] = verification.appendingPathComponent("cache").path
        environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        let checked = await probe(node.path, ["-p", "JSON.stringify({version:process.version,arch:process.arch})"], environment)
        struct Identity: Decodable { let version: String; let arch: String }
        guard checked.succeeded,
              let identity = try? JSONDecoder().decode(Identity.self, from: Data(checked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
              identity.version == release.version, identity.arch == architecture else {
            throw Failure(message: String(localized: "The requested Node version could not run on this Mac."))
        }
        let npmChecked = await probe(node.path, [npm.path, "--version"], environment)
        guard npmChecked.succeeded, npmChecked.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == release.npm else {
            throw Failure(message: String(localized: "The bundled npm version could not be verified.") + "\n" + String(npmChecked.combined.prefix(512)))
        }
    }

    /// Callers hold the shared dependency lock, preventing new server starts.
    /// Recheck canChange after awaits and before committing a new selection.
    func select(_ version: String, canChange: @MainActor () -> Bool,
                commit: @MainActor (String, String?) throws -> Void,
                log: ConsoleLog) async throws {
        guard !busy, canChange() else { throw Failure(message: String(localized: "Stop servers and the database before changing packages.")) }
        busy = true
        defer { busy = false }
        if version == "System" { try commit("", nil); return }
        guard Self.validVersion(version) else { throw Failure(message: String(localized: "Choose a Node.js release from the list.")) }
        let target = root.appendingPathComponent(version)
        if !FileManager.default.fileExists(atPath: target.path) {
            try await install(version, log: log)
        }
        let selected = try await verify(version: version)
        guard canChange() else { throw Failure(message: String(localized: "Stop servers and the database before changing packages.")) }
        try commit(version, selected.path)
        log.system(String(localized: "Active Node.js: \(version)"))
    }

    private func install(_ version: String, log: ConsoleLog) async throws {
        let releases = try await versions()
        guard let release = releases.first(where: { $0.version == version }) else {
            throw Failure(message: String(localized: "That Node version is not available for this Mac architecture."))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let access = try SiteFileAccess(root: root)
        let staging = access.root.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stagingAccess = try SiteFileAccess(root: staging)
        defer {
            if (try? stagingAccess.checked(stagingAccess.root)) != nil { try? FileManager.default.removeItem(at: stagingAccess.root) }
        }
        let base = "https://nodejs.org/dist/\(version)/"
        let sums = staging.appendingPathComponent("SHASUMS256.txt")
        try await fetch(URL(string: base + "SHASUMS256.txt")!, sums, 1_000_000)
        let expected = try Self.checksum(String(contentsOf: sums, encoding: .utf8), filename: release.archive)
        log.system(String(localized: "Downloading official Node.js \(version)…"))
        let archive = staging.appendingPathComponent(release.archive)
        try await fetch(URL(string: base + release.archive)!, archive, 256_000_000)
        let digest = try await Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hasher.update(data: data) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == expected else { throw Failure(message: String(localized: "Node.js checksum mismatch. The active version was not changed.")) }
        // Only a checksum-verified official archive reaches tar. Keep ownership
        // local and extract to a new private directory, never over an existing copy.
        let listing = await ProcessRunner.run("/usr/bin/tar", ["-tzf", archive.path], timeout: 60)
        let names = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard listing.succeeded, !names.isEmpty, names.count < 100_000,
              names.allSatisfy({ name in
                  let parts = name.split(separator: "/")
                  return !name.hasPrefix("/") && parts.first == Substring(release.name)
                      && !parts.contains("..") && !name.contains("\0")
              }) else { throw Failure(message: String(localized: "The downloaded Node archive has an unexpected layout.")) }
        let extracted = staging.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let result = await ProcessRunner.run("/usr/bin/tar", ["-xzf", archive.path, "--no-same-owner", "-C", extracted.path], timeout: 120)
        guard result.succeeded else { throw Failure(message: result.combined) }
        let source = extracted.appendingPathComponent(release.name)
        try await verify(release, directory: source)
        try JSONEncoder().encode(release).write(to: source.appendingPathComponent(".servermaster-node.json"), options: .withoutOverwriting)
        _ = try access.checked(access.root)
        _ = try stagingAccess.checked(source)
        try FileManager.default.moveItem(at: source, to: access.root.appendingPathComponent(version))
    }

    func remove(_ version: String, activeVersion: String, canChange: @MainActor () -> Bool) throws {
        guard !busy, canChange(), version != activeVersion else {
            throw Failure(message: String(localized: "Switch to System or another Node version before removing this copy. Stop running servers first."))
        }
        _ = try bin(version: version)
        let access = try SiteFileAccess(root: root)
        let target = try access.checked(access.root.appendingPathComponent(version))
        try FileManager.default.removeItem(at: target)
    }

    /// No redirects: official metadata, checksums and archives must all come
    /// directly over HTTPS from nodejs.org. Limits apply while downloading too.
    nonisolated static func download(_ url: URL, to target: URL, maximum: Int64) async throws {
        guard url.scheme == "https", url.host == "nodejs.org" else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = maximum > 8_000_000 ? 600 : 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: NodeDownloadLimit(maximum: maximum))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximum else { throw URLError(.badServerResponse) }
        try FileManager.default.copyItem(at: temporary, to: target)
    }
}

private final class NodeDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    init(maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
