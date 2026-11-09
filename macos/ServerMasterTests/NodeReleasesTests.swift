import Foundation
import CryptoKit
import Testing
@testable import ServerMaster

private actor NodeReleaseFeed {
    let index: Data
    let archive: Data
    let filename: String
    var badChecksum = false
    var offline = false
    var requests = 0
    init(index: Data, archive: Data, filename: String) {
        self.index = index; self.archive = archive; self.filename = filename
    }
    func failChecksum() { badChecksum = true }
    func goOffline() { offline = true }
    func count() -> Int { requests }
    func fetch(_ url: URL, to file: URL, maximum: Int64) throws {
        requests += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let data: Data
        if url.lastPathComponent == "index.json" { data = index }
        else if url.lastPathComponent == "SHASUMS256.txt" {
            let digest = badChecksum ? String(repeating: "0", count: 64) : SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            data = Data((digest + "  " + filename + "\n").utf8)
        } else if url.lastPathComponent == filename { data = archive }
        else { throw URLError(.badURL) }
        guard data.count <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
        try data.write(to: file, options: .withoutOverwriting)
    }
}

@MainActor
@Suite("R11 exact Node releases")
struct NodeReleasesTests {
    private let version = "v22.15.0"
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-r11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, arch: String = "arm64", reported: String? = nil,
                         reportedArchitecture: String? = nil, reportedNpm: String = "10.9.2") async throws -> NodeReleaseFeed {
        let name = "node-\(version)-darwin-\(arch)"
        let source = root.appendingPathComponent("source/" + name)
        let bin = source.appendingPathComponent("bin")
        let npm = source.appendingPathComponent("lib/node_modules/npm/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = '-p' ]; then
          printf '%s\\n' '{"version":"\(reported ?? version)","arch":"\(reportedArchitecture ?? arch)"}'
        else
          printf '\(reportedNpm)\\n'
        fi
        """
        try script.write(to: bin.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        for path in [bin.appendingPathComponent("node"), npm.appendingPathComponent("npm-cli.js"), npm.appendingPathComponent("npx-cli.js")] {
            if !FileManager.default.fileExists(atPath: path.path) { try "fixture".write(to: path, atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        for command in ["npm", "npx"] {
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(command).path,
                withDestinationPath: "../lib/node_modules/npm/bin/\(command)-cli.js")
        }
        let archive = root.appendingPathComponent(name + ".tar.gz")
        let result = await ProcessRunner.run("/usr/bin/tar", ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, name])
        try #require(result.succeeded, "\(result.combined)")
        let index = Data("[{\"version\":\"\(version)\",\"files\":[\"osx-\(arch)-tar\"],\"npm\":\"10.9.2\"}]".utf8)
        return NodeReleaseFeed(index: index, archive: try Data(contentsOf: archive), filename: name + ".tar.gz")
    }

    @Test("Architecture catalogue, stable version and checksum boundaries")
    func catalogue() throws {
        let json = Data("""
        [{"version":"v22.9.0","files":["osx-arm64-tar"],"npm":"10.9.0"},
         {"version":"v22.10.0","files":["osx-arm64-tar","osx-x64-tar"],"npm":"10.9.2"},
         {"version":"v25.0.0-rc.1","files":["osx-arm64-tar"],"npm":"10.9.2"},
         {"version":"../../bad","files":["osx-arm64-tar"],"npm":"10.9.2"},
         {"version":"v22.10.0","files":["osx-arm64-tar"],"npm":"10.9.2"},
         {"version":"v0.1.0","files":["osx-arm64-tar"]}]
        """.utf8)
        #expect(try NodeReleases.catalogue(json, architecture: "arm64").map(\.version) == ["v22.10.0", "v22.9.0"])
        #expect(try NodeReleases.catalogue(json, architecture: "x64").map(\.version) == ["v22.10.0"])
        #expect(throws: (any Error).self) { try NodeReleases.catalogue(json, architecture: "x86") }
        for bad in ["latest", "v1.2", "v01.2.3", "v1.2.3;echo", "v1.2.3\n", "../v1.2.3"] { #expect(!NodeReleases.validVersion(bad)) }
        let checksum = String(repeating: "a", count: 64)
        #expect(try NodeReleases.checksum(checksum + "  exact.tar.gz\n", filename: "exact.tar.gz") == checksum)
        for bad in ["bad  exact.tar.gz", checksum + "  other.tar.gz", checksum + "  exact.tar.gz\n" + checksum + "  exact.tar.gz"] {
            #expect(throws: (any Error).self) { try NodeReleases.checksum(bad, filename: "exact.tar.gz") }
        }
    }

    @Test("Verified archive, bundled npm, offline reselection and System keep original PATH", arguments: ["arm64", "x64"])
    func lifecycle(arch: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await fixture(root: root, arch: arch)
        let manager = NodeReleases(root: root.appendingPathComponent("installed"), architecture: arch,
                                   fetch: { try await feed.fetch($0, to: $1, maximum: $2) }, probe: { binary, args, environment in
            #expect(environment["NPM_CONFIG_USERCONFIG"] != environment["NPM_CONFIG_GLOBALCONFIG"])
            #expect(environment["NODE_OPTIONS"] == "")
            return await ProcessRunner.run(binary, args, env: environment)
        })
        let environment = ShellEnvironment(loginProbe: { [] })
        environment.setExtraEntries(["/original/custom/bin", "/opt/homebrew/bin"])
        let previousPATH = environment.path
        var active = ""
        try await manager.select(version, canChange: { true }, commit: { value, bin in
            active = value; environment.setManagedNodeDirectory(bin)
        }, log: ConsoleLog())
        #expect(active == version)
        let selectedBin = try manager.bin(version: version)
        #expect(environment.which("node") == selectedBin.appendingPathComponent("node").path)
        #expect(environment.which("npm") == selectedBin.appendingPathComponent("npm").path)
        #expect(environment.path.hasPrefix(selectedBin.path + ":"))
        #expect(manager.installed().map(\.version) == [version])
        #expect(throws: (any Error).self) { try manager.remove(version, activeVersion: active, canChange: { true }) }
        let count = await feed.count()
        await feed.goOffline()
        try await manager.select(version, canChange: { true }, commit: { active = $0; environment.setManagedNodeDirectory($1) }, log: ConsoleLog())
        try await manager.select("System", canChange: { true }, commit: { active = $0; environment.setManagedNodeDirectory($1) }, log: ConsoleLog())
        #expect(await feed.count() == count)
        #expect(environment.path == previousPATH)
        #expect(active.isEmpty)
        #expect(manager.installed().count == 1)
        try manager.remove(version, activeVersion: active, canChange: { true })
        #expect(manager.installed().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.root.path).isEmpty)
    }

    @Test("Checksum, probe and persistence failures do not commit a selection", arguments: ["checksum", "identity", "architecture", "npm", "offline", "unoffered", "commit", "busy", "changed"])
    func failure(kind: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await fixture(root: root, reported: kind == "identity" ? "v20.0.0" : nil,
                                     reportedArchitecture: kind == "architecture" ? "x64" : nil,
                                     reportedNpm: kind == "npm" ? "9.0.0" : "10.9.2")
        if kind == "checksum" { await feed.failChecksum() }
        if kind == "offline" { await feed.goOffline() }
        let manager = NodeReleases(root: root.appendingPathComponent("installed"), architecture: "arm64", fetch: { try await feed.fetch($0, to: $1, maximum: $2) })
        var active = "previous selection"
        var guards = 0
        do {
            try await manager.select(kind == "unoffered" ? "v999.0.0" : version, canChange: {
                guards += 1
                return kind != "busy" && (kind != "changed" || guards == 1)
            }, commit: { selected, _ in
                if kind == "commit" { throw CocoaError(.fileWriteOutOfSpace) }
                active = selected
            }, log: ConsoleLog())
            Issue.record("Invalid selection was committed")
        } catch { #expect(active == "previous selection") }
        if kind == "busy" { #expect(await feed.count() == 0) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: manager.root.path)) ?? []
        #expect(!files.contains { $0.hasPrefix(".download-") })
        if ["checksum", "identity", "architecture", "npm", "offline", "unoffered"].contains(kind) { #expect(files.isEmpty) }
    }

    @Test("Damaged copies stay removable; escaped binaries fail verification")
    func damaged() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await fixture(root: root)
        let manager = NodeReleases(root: root.appendingPathComponent("installed"), architecture: "arm64", fetch: { try await feed.fetch($0, to: $1, maximum: $2) })
        try await manager.select(version, canChange: { true }, commit: { _, _ in }, log: ConsoleLog())
        let node = try manager.bin(version: version).appendingPathComponent("node")
        try FileManager.default.removeItem(at: node)
        try FileManager.default.createSymbolicLink(at: node, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        do { _ = try await manager.verify(version: version); Issue.record("External Node link accepted") } catch { }
        try FileManager.default.removeItem(at: node.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".servermaster-node.json"))
        #expect(manager.installed().map(\.version) == [version])
        try manager.remove(version, activeVersion: "", canChange: { true })
        #expect(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        let environment = ShellEnvironment(loginProbe: { [] })
        environment.setManagedNodeDirectory(root.appendingPathComponent("missing/bin").path)
        #expect(environment.which("node") == nil)
        #expect(environment.which("npm") == nil)
        #expect(environment.which("/bin/sh") != nil)
    }

    @Test("Selection setting survives roundtrip and old settings default to System")
    func settings() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).managedNodeVersion.isEmpty)
        var value = AppSettings()
        value.managedNodeVersion = version
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value))
        #expect(restored.managedNodeVersion == version)
        #expect(restored.extraPATHEntries == value.extraPATHEntries)
    }
}

@MainActor
@Suite("R11 official Node distribution", .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_NODE_RELEASE_LIVE"] == "1"))
struct NodeReleasesLiveTests {
    @Test("Real official archive: hash, native Node/npm, reuse offline and isolated removal")
    func official() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-r11-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = NodeReleases(root: root)
        let version = "v22.15.0"
        var active = ""
        try await manager.select(version, canChange: { true }, commit: { value, _ in active = value }, log: ConsoleLog())
        #expect(active == version)
        let bin = try await manager.verify(version: version)
        let identity = await ProcessRunner.run(bin.appendingPathComponent("node").path, ["--version"])
        #expect(identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == version)
        let environment = ShellEnvironment(loginProbe: { [] })
        let before = environment.path
        environment.setManagedNodeDirectory(bin.path)
        let npm = await ProcessRunner.run("/usr/bin/env", ["npm", "--version"], env: ["PATH": environment.path, "NODE_OPTIONS": "", "NPM_CONFIG_UPDATE_NOTIFIER": "false"])
        #expect(npm.succeeded && npm.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == manager.installed().first?.npm)
        let offline = NodeReleases(root: root, fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        try await offline.select(version, canChange: { true }, commit: { value, _ in active = value }, log: ConsoleLog())
        try await offline.select("System", canChange: { true }, commit: { value, directory in active = value; environment.setManagedNodeDirectory(directory) }, log: ConsoleLog())
        #expect(environment.path == before && active.isEmpty)
        try offline.remove(version, activeVersion: active, canChange: { true })
        #expect(offline.installed().isEmpty)
    }
}
