import Foundation
import Testing
@testable import ServerMaster

@Suite("R1 per-profile PHP configuration")
struct PHPBuiltinSettingsTests {
    @Test("Built-in settings are individual arguments, independent of global ini")
    func arguments() {
        var profile = ServerProfile()
        profile.phpMemoryLimit = " 768M "
        profile.phpUploadMaxFilesize = "256M"
        profile.phpMaxExecutionTime = 127
        profile.phpDisplayErrors = false
        let args = LaunchPlanBuilder.phpConfigurationArguments(profile)
        #expect(args == ["-d", "memory_limit=768M", "-d", "upload_max_filesize=256M",
                         "-d", "post_max_size=256M", "-d", "max_execution_time=127",
                         "-d", "max_input_time=127", "-d", "display_errors=0", "-d", "log_errors=1"])
    }
}

@MainActor
@Suite("R1 actual PHP built-in settings", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_PHP_LIVE"] == "1"))
struct PHPBuiltinSettingsLiveTests {
    @Test("Two simultaneous PHP servers expose independent profile settings; HTTPS keeps them")
    func simultaneous() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-r1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "<?php header('Content-Type: application/json'); echo json_encode(array_map('ini_get', ['memory_limit','upload_max_filesize','post_max_size','max_execution_time','max_input_time','display_errors','log_errors']));"
        try script.write(to: root.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        var children: [Process] = []
        var leases: [RuntimePortLease] = []
        defer { withExtendedLifetime(leases) {} }
        defer {
            for child in children where child.isRunning { child.terminate() }
            for child in children { child.waitUntilExit() }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var profiles: [ServerProfile] = []
        for index in 0..<2 {
            let lease = try RuntimePortLease.acquire(excluding: 0)
            leases.append(lease)
            var profile = ServerProfile()
            profile.engine = .phpBuiltIn
            profile.rootPath = root.path
            profile.port = lease.port
            profile.phpMemoryLimit = index == 0 ? "384M" : "768M"
            profile.phpUploadMaxFilesize = index == 0 ? "64M" : "256M"
            profile.phpMaxExecutionTime = index == 0 ? 117 : 229
            profile.phpDisplayErrors = index == 0
            let plan = try LaunchPlanBuilder.build(for: profile, runtimeRoot: root)
            #expect(plan.arguments.starts(with: LaunchPlanBuilder.phpConfigurationArguments(profile)))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            process.currentDirectoryURL = root
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            lease.allowChildBind()
            try process.run()
            children.append(process)
            profiles.append(profile)

            var tlsProfile = profile
            tlsProfile.httpsEnabled = true
            tlsProfile.port = 8443
            let tlsPlan = try BuiltinHTTPS.wrap(profile: tlsProfile, backend: plan, caddy: "/fixture/caddy",
                                               backendPort: profile.port, directory: root.appendingPathComponent("tls-\(index)").path)
            let supervisor = try #require(tlsPlan.generatedConfig?.contents)
            #expect(supervisor.contains("memory_limit=\(profile.phpMemoryLimit)"))
            #expect(supervisor.contains("display_errors=\(profile.phpDisplayErrors ? "1" : "0")"))
        }
        for profile in profiles {
            var received: [String]?
            for _ in 0..<50 {
                if let (data, response) = try? await session.data(from: URL(string: profile.address)!),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    received = try JSONDecoder().decode([String].self, from: data)
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(received == [profile.phpMemoryLimit, profile.phpUploadMaxFilesize,
                                 profile.phpUploadMaxFilesize, String(profile.phpMaxExecutionTime),
                                 String(profile.phpMaxExecutionTime), profile.phpDisplayErrors ? "1" : "0", "1"])
        }
    }
}
