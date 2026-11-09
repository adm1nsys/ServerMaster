import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("R10 profile and recipe diagnostics")
struct ProfileDiagnosticsTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-r10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relative: String, root: URL, text: String = "fixture") throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("Deleted CRM entry and working folder are reported without running project scripts")
    func crm() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package.json", root: root, text: "{\"scripts\":{\"start\":\"touch should-not-exist\"}}")
        try write("app/main.cjs", root: root)
        var profile = ServerProfile()
        profile.rootPath = root.path
        profile.engine = .nodeScript
        profile.templateId = "printshopcrm"
        profile.nodeEntryFile = "main.cjs"
        profile.workingDirectory = root.appendingPathComponent("app").path
        let node = try #require(ShellEnvironment.shared.which("node"))
        let healthy = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in node })
        #expect(!healthy.contains { $0.level >= .warning })
        #expect(healthy.contains { $0.id.hasSuffix("-http") && $0.level == .note })
        #expect(healthy.contains { $0.detail.contains(node) })
        try FileManager.default.removeItem(at: root.appendingPathComponent("app/main.cjs"))
        let missing = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in node })
        #expect(missing.contains { $0.id.hasSuffix("-entry") && $0.level == .broken && $0.detail.contains("main.cjs") && !$0.remedy.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
        profile.workingDirectory = root.appendingPathComponent("absent").path
        let badFolder = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in node })
        #expect(badFolder.contains { $0.id.hasSuffix("-working") && $0.level == .broken })
        #expect(!FileManager.default.fileExists(atPath: profile.workingDirectory))
    }

    @Test("Store and Showcase detect missing plugins and do not mark stopped DB broken", arguments: ["web-to-print-store", "web-to-print-showcase"])
    func wordpress(template: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let required = ["wp-config.php", "wp-admin/install.php", "wp-content/plugins/woocommerce/woocommerce.php", "wp-content/plugins/printcart-integration/nbdesigner.php"]
        for relative in required { try write(relative, root: root) }
        var profile = ServerProfile()
        profile.rootPath = root.path
        profile.engine = .phpBuiltIn
        profile.templateId = template
        profile.needsDatabase = true
        // Runtime resolution is isolated from installed dependencies in this filesystem test.
        let healthy = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in "/usr/bin/true" })
        #expect(!healthy.contains { $0.level >= .warning })
        #expect(healthy.contains { $0.id.hasSuffix("-database") && $0.level == .note })
        for relative in required {
            try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
            let found = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in "/usr/bin/true" })
            #expect(found.contains { $0.detail.hasSuffix(relative) && $0.level == .broken && !$0.remedy.isEmpty })
            try write(relative, root: root)
        }
        // A plugin symlink must not conceal a missing recipe file in another project.
        let plugin = root.appendingPathComponent(required.last!)
        try FileManager.default.removeItem(at: plugin)
        try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: root.appendingPathComponent("wp-config.php"))
        let linked = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { _, _ in "/usr/bin/true" })
        #expect(linked.contains { $0.id.hasSuffix("-printcart") && $0.level == .broken })
    }

    @Test("Selected missing PHP fails instead of silently using system PHP")
    func selectedPHP() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ServerProfile()
        profile.engine = .phpBuiltIn
        profile.rootPath = root.path
        profile.phpVersion = "999.42"
        let found = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false)
        #expect(found.contains { $0.id.hasSuffix("-runtime-php") && $0.level == .broken && $0.detail.contains("999.42") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Running loopback server receives HTTP check; busy, stopped and remote profiles do not")
    func http() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = try #require(ShellEnvironment.shared.which("node"))
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.rootPath = root.path
        profile.nodeEntryFile = "server.cjs"
        profile.host = "127.0.0.1"
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        _ = try StarterFiles.available(for: profile)[0].write(into: root.path, profile: profile, overwrite: false)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: node)
        server.arguments = [profile.resolvedNodeEntry]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PORT"); environment.removeValue(forKey: "HOST")
        server.environment = environment
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        var found: [Finding] = []
        for _ in 0..<30 {
            found = await ProfileDiagnostics.check(profile, state: .running, databaseRunning: true)
            if found.contains(where: { $0.id.hasSuffix("-http") && $0.level == .fine }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(found.contains { $0.id.hasSuffix("-http") && $0.level == .fine && $0.detail.contains("200") })
        let failure = ServerState.failed("fixture")
        for state in [ServerState.stopped, .starting, .stopping, failure] {
            let inactive = await ProfileDiagnostics.check(profile, state: state, databaseRunning: false)
            #expect(inactive.contains { $0.id.hasSuffix("-http") && $0.level == .note })
            #expect(inactive.contains { $0.id.hasSuffix("-state") && $0.level == (state == failure ? .broken : .note) })
        }
        profile.host = "example.invalid"
        let remote = await ProfileDiagnostics.check(profile, state: .running, databaseRunning: true)
        #expect(remote.contains { $0.id.hasSuffix("-http") && $0.level == .note })
        server.terminate()
        for _ in 0..<100 where server.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        profile.host = "127.0.0.1"
        let stopped = await ProfileDiagnostics.check(profile, state: .running, databaseRunning: true)
        #expect(!stopped.contains { $0.id.hasSuffix("-http") && $0.level == .fine })
    }

    @Test("Selected PHP version, missing TLS files and failed runtime have specific findings")
    func configuration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("php-fixture", root: root, text: "#!/bin/sh\nprintf 'PHP 8.2.99 (cli)\\n'\n")
        let binary = root.appendingPathComponent("php-fixture")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var profile = ServerProfile()
        profile.engine = .phpBuiltIn
        profile.rootPath = root.path
        profile.templateId = "joomla6"
        profile.phpVersion = "8.2"
        profile.needsDatabase = true
        profile.httpsEnabled = true
        profile.certificatePath = root.appendingPathComponent("missing.crt").path
        profile.privateKeyPath = root.appendingPathComponent("missing.key").path
        let found = await ProfileDiagnostics.check(profile, state: .stopped, databaseRunning: false, resolve: { selected, tool in
            #expect(selected.phpVersion == "8.2")
            return tool == "php" ? binary.path : "/usr/bin/false"
        })
        for suffix in ["-php-minimum", "-certificate", "-key", "-runtime-caddy"] {
            #expect(found.contains { $0.id.hasSuffix(suffix) && $0.level == .broken && !$0.remedy.isEmpty })
        }
        #expect(found.contains { $0.id.hasSuffix("-database") && $0.level == .note })
        profile.host = "example.invalid"
        let active = await ProfileDiagnostics.check(profile, state: .running, databaseRunning: false, resolve: { _, _ in "/usr/bin/true" })
        #expect(active.contains { $0.id.hasSuffix("-database") && $0.level == .warning })
    }
}
