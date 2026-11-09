import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("R8 generated Node starters")
struct NodeStarterTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-starter-r8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Generated entry runs standalone in CJS, ESM and both .js package modes",
          arguments: ["server.js", "api.cjs", "api.mjs", "nested/api.cjs", "nested/api.mjs", "nested/a' $(touch unexpected).js"])
    func generated(entry: String) async throws {
        let node = try #require(ShellEnvironment.shared.which("node"))
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.nodeEntryFile = entry
        profile.name = "Ім’я ' \" ` ${process.exit(99)} \\ \n 🎉"
        profile.host = "127.0.0.1"
        profile.rootPath = root.path

        for mode in ["commonjs", "module"] {
            try "{\"type\":\"\(mode)\"}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            let starters = StarterFiles.available(for: profile).filter { $0.id != "package.json" }
            #expect(starters.count == 4)
            for starter in starters {
                profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
                #expect(starter.fileName == entry)
                let file = try starter.write(into: root.path, profile: profile, overwrite: true)
                let syntax = await ProcessRunner.run(node, ["--check", file.path])
                try #require(syntax.succeeded, "\(starter.id): \(syntax.combined)")
                // Express requires a separately installed dependency; syntax is checked here.
                if starter.id == StarterFiles.nodeExpress.id { continue }
                let publicFolder = file.deletingLastPathComponent().appendingPathComponent("public")
                try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: true)
                try "static response".write(to: publicFolder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                let external = root.appendingPathComponent("private.txt")
                try "secret".write(to: external, atomically: true, encoding: .utf8)
                let link = publicFolder.appendingPathComponent("outside.txt")
                if !FileManager.default.fileExists(atPath: link.path) {
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
                }
                let server = Process()
                server.executableURL = URL(fileURLWithPath: node)
                server.arguments = [file.path]
                server.currentDirectoryURL = root
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "PORT")
                environment.removeValue(forKey: "HOST")
                server.environment = environment
                let logURL = root.appendingPathComponent("server.log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                let log = try FileHandle(forWritingTo: logURL)
                server.standardOutput = log
                server.standardError = log
                try server.run()
                defer {
                    if server.isRunning { server.terminate() }
                    try? log.close()
                }
                let address = "http://127.0.0.1:\(profile.port)"
                var response = ""
                for _ in 0..<60 {
                    let result = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--fail", "--noproxy", "*", "--max-time", "1", address + "/"])
                    if result.succeeded { response = result.stdout; break }
                    if !server.isRunning { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try #require(!response.isEmpty, "\(starter.id), \(mode), \(entry): \((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")")
                if starter.id == StarterFiles.nodeMinimal.id { #expect(response.contains(profile.name)) }
                if starter.id == StarterFiles.nodeJSONAPI.id { #expect(response.contains("\"ok\":true")) }
                if starter.id == StarterFiles.nodeStatic.id {
                    #expect(response == "static response")
                    for (path, code) in [("/%zz", "400"), ("/outside.txt", "403"), ("/..%2fprivate.txt", "403")] {
                        let result = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--path-as-is", "--noproxy", "*", "--max-time", "2", "-o", "/dev/null", "-w", "%{http_code}", address + path])
                        #expect(result.stdout == code)
                    }
                }
                server.terminate()
                for _ in 0..<100 where server.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                #expect(!server.isRunning)
            }
        }
    }

    @Test("Entry boundaries, overwrite confirmation and package script quoting")
    func boundaries() async throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        var profile = ServerProfile()
        profile.engine = .nodeScript
        for entry in ["../escaped.cjs", "/absolute.cjs", "nested/../escaped.cjs", "bad\0.cjs"] {
            profile.nodeEntryFile = entry
            let starter = try #require(StarterFiles.available(for: profile).first)
            #expect(throws: (any Error).self) { try starter.write(into: root.path, profile: profile, overwrite: false) }
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        profile.nodeEntryFile = "link/api.cjs"
        #expect(throws: (any Error).self) { try StarterFiles.available(for: profile)[0].write(into: root.path, profile: profile, overwrite: true) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        profile.nodeEntryFile = "nested/a' $(touch unexpected).cjs"
        let starter = StarterFiles.available(for: profile)[0]
        _ = try starter.write(into: root.path, profile: profile, overwrite: false)
        #expect(throws: StarterError.self) { try starter.write(into: root.path, profile: profile, overwrite: false) }
        let package = try #require(JSONSerialization.jsonObject(with: Data(StarterFiles.packageJSON.contents(profile).utf8)) as? [String: Any])
        let scripts = try #require(package["scripts"] as? [String: String])
        let command = try #require(scripts["start"])
        // Substitute a harmless argv printer for node to test the shell boundary.
        let arguments = await ProcessRunner.run("/bin/sh", ["-c", "node() { printf '%s' \"$1\"; }; " + command], cwd: root.path)
        #expect(arguments.stdout == "./" + profile.nodeEntryFile)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))

        profile.workingDirectory = root.appendingPathComponent("app").path
        profile.nodeEntryFile = "src/api.cjs"
        let nested = try StarterFiles.available(for: profile)[0].write(into: root.path, profile: profile, overwrite: false)
        #expect(nested.standardizedFileURL == URL(fileURLWithPath: profile.resolvedNodeEntry).standardizedFileURL)
        profile.workingDirectory = outside.path
        #expect(throws: (any Error).self) { try StarterFiles.available(for: profile)[0].write(into: root.path, profile: profile, overwrite: false) }
    }
}
