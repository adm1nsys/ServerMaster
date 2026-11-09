import Foundation
import Testing
import Darwin
@testable import ServerMaster

@Suite("Built-in HTTPS configuration")
struct BuiltinHTTPSTests {
    @Test("IPv4, localhost and IPv6 listeners are explicit", arguments: ["127.0.0.1", "localhost", "0.0.0.0", "::1", "::"])
    func configuration(host: String) throws {
        var profile = ServerProfile()
        profile.host = host
        profile.port = 8443
        profile.certificatePath = "/tmp/Certificate with spaces.pem"
        profile.privateKeyPath = "/tmp/key.pem"
        let raw = try BuiltinHTTPS.configuration(profile: profile, backendPort: 23456)
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((json["admin"] as? [String: Any])?["disabled"] as? Bool == true)
        let apps = try #require(json["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        let servers = try #require(http["servers"] as? [String: Any])
        let site = try #require(servers["site"] as? [String: Any])
        #expect(site["listen"] as? [String] == [try BuiltinHTTPS.listener(host: host, port: 8443)])
        #expect(raw.contains("127.0.0.1:23456"))
        #expect((site["automatic_https"] as? [String: Any])?["disable"] as? Bool == true)
    }

    @Test("Invalid hosts, conflicting ports and low backend ports are rejected")
    func invalidAddresses() throws {
        for host in ["example.org", "127.0.0.1\n:9000", "127.0.0.1:8000", ""] {
            #expect(throws: (any Error).self) { try BuiltinHTTPS.listener(host: host, port: 8443) }
        }
        let profile = ServerProfile()
        #expect(throws: (any Error).self) { try BuiltinHTTPS.configuration(profile: profile, backendPort: profile.port) }
        #expect(throws: (any Error).self) { try BuiltinHTTPS.configuration(profile: profile, backendPort: 443) }
        let allocated = try BuiltinHTTPS.freeBackendPort(excluding: profile.port)
        #expect(allocated != profile.port && allocated >= 1024)
    }

    @Test("Caddy is required only when managed HTTPS is enabled", arguments: [ServerEngine.pythonHTTP, .phpBuiltIn, .nodeScript])
    func requirements(engine: ServerEngine) {
        var profile = ServerProfile()
        profile.engine = engine
        #expect(!profile.requiredTools.contains("caddy"))
        profile.httpsEnabled = true
        #expect(profile.engine.supportsHTTPS)
        #expect(profile.requiredTools.contains("caddy"))
        #expect(profile.address.hasPrefix("https://"))
    }

    @Test("Supervisor is valid Bash and safely quotes paths and environment")
    func shellSyntax() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LaunchPlan(executable: "/tmp/php with ' quote", arguments: ["-S", "127.0.0.1:23456"], workingDirectory: directory.path,
                                 environment: ["DEMO": "value; $(not-run) ' \n"], generatedConfig: nil)
        let raw = try BuiltinHTTPS.supervisor(backend: backend, caddy: "/tmp/caddy with ' quote",
                                             configPath: "/tmp/caddy.json", readyPath: "/tmp/ready", backendPort: 23456, publicPort: 8443)
        let file = directory.appendingPathComponent("supervisor.sh")
        try raw.write(to: file, atomically: true, encoding: .utf8)
        let result = await ProcessRunner.run("/bin/bash", ["-n", file.path])
        #expect(result.succeeded)
        #expect(raw.contains("-p \"$backend_pid\""))
        #expect(raw.contains("-p \"$proxy_pid\""))
        #expect(raw.contains("unset PHP_CLI_SERVER_WORKERS"))
        #expect(raw.contains("kill -TERM -- \"-$pid\""))
    }
}

/// Opt-in tests use a temporary official Caddy binary supplied by the caller;
/// no package is installed and no system trust store is modified.
@MainActor
@Suite("Built-in HTTPS live lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_CADDY"] != nil))
struct BuiltinHTTPSLiveTests {
    private func writePlan(_ plan: LaunchPlan) throws {
        for file in plan.extraFiles + (plan.generatedConfig.map { [$0] } ?? []) {
            let url = URL(fileURLWithPath: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func start(_ executable: String, _ args: [String], cwd: String, log: FileHandle) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ShellEnvironment.shared.environment()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        return condition()
    }

    private func pid(on port: Int) async throws -> Int32 {
        let result = await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return try #require(result.stdout.split(separator: "\n").first.flatMap { Int32($0) })
    }

    @Test("Verified TLS, PHP scheme, restart and failure cleanup", arguments: ["python", "php"])
    func lifecycle(engine: String) async throws {
        let caddy = try #require(ProcessInfo.processInfo.environment["SERVERMASTER_TEST_CADDY"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("https-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("test.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let certificate = directory.appendingPathComponent("cert.pem").path
        let key = directory.appendingPathComponent("key.pem").path
        let generated = await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key, "-out", certificate, "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
        #expect(generated.succeeded)
        var profile = ServerProfile()
        profile.engine = engine == "php" ? .phpBuiltIn : .pythonHTTP
        profile.httpsEnabled = true
        profile.rootPath = directory.path
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        profile.certificatePath = certificate
        profile.privateKeyPath = key
        let backendPort = try BuiltinHTTPS.freeBackendPort(excluding: profile.port)
        let executable = try #require(ShellEnvironment.shared.which(engine == "php" ? "php" : "python3"))
        try "Python HTTPS fixture".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<?php echo json_encode(['https'=>$_SERVER['HTTPS'] ?? '', 'scheme'=>$_SERVER['REQUEST_SCHEME'] ?? '', 'port'=>$_SERVER['SERVER_PORT'], 'query'=>$_GET['demo'] ?? '']);".write(to: directory.appendingPathComponent("probe.php"), atomically: true, encoding: .utf8)
        if engine == "php" {
            for path in ["libraries/src/Uri/Uri.php", "administrator/index.php"] {
                let file = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "<?php".write(to: file, atomically: true, encoding: .utf8)
            }
        }
        let args = engine == "php" ? ["-S", "127.0.0.1:\(backendPort)", "-t", directory.path]
            : ["-u", "-m", "http.server", "\(backendPort)", "--bind", "127.0.0.1", "--directory", directory.path]
        let backend = LaunchPlan(executable: executable, arguments: args, workingDirectory: directory.path, environment: [:], generatedConfig: nil)
        let plan = try BuiltinHTTPS.wrap(profile: profile, backend: backend, caddy: caddy,
                                         backendPort: backendPort, directory: directory.path)
        try writePlan(plan)
        var supervisor: Process?
        defer {
            if let supervisor, supervisor.isRunning {
                supervisor.terminate()
                let deadline = Date().addingTimeInterval(4)
                while supervisor.isRunning && Date() < deadline { usleep(50_000) }
                if supervisor.isRunning { kill(supervisor.processIdentifier, SIGKILL) }
            }
        }
        for scenario in ["stop", "backend-failure", "proxy-failure"] {
            let process = try start(plan.executable, plan.arguments, cwd: directory.path, log: log)
            supervisor = process
            let ready = await waitUntil { FileManager.default.fileExists(atPath: plan.readinessFile!) || !process.isRunning }
            guard ready && process.isRunning else {
                Issue.record("\(try String(contentsOf: logURL, encoding: .utf8))")
                return
            }
            let request = await ProcessRunner.run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--noproxy", "*", "--max-time", "5", "--cacert", certificate,
                "https://127.0.0.1:\(profile.port)/\(engine == "php" ? "probe.php?demo=ok" : "index.html")"])
            #expect(request.succeeded, "\(request.combined)")
            if engine == "php" {
                let json = try #require(JSONSerialization.jsonObject(with: Data(request.stdout.utf8)) as? [String: String])
                #expect(json["https"] == "on")
                #expect(json["scheme"] == "https")
                #expect(json["port"] == String(profile.port))
                #expect(json["query"] == "ok")
                let redirect = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--noproxy", "*", "--max-time", "5", "--cacert", certificate,
                    "--output", "/dev/null", "--write-out", "%{http_code} %{redirect_url}", "https://127.0.0.1:\(profile.port)/installation/index.php?demo=ok"])
                #expect(redirect.stdout == "307 https://127.0.0.1:\(profile.port)/installation/?demo=ok")
            } else { #expect(request.stdout.contains("Python HTTPS fixture")) }
            if scenario == "stop" {
                let untrusted = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--noproxy", "*", "--max-time", "5", "https://127.0.0.1:\(profile.port)/index.html"])
                #expect(untrusted.exitCode == 60, "An untrusted fixture certificate must not be silently accepted")
            }
            if scenario == "stop" { process.terminate() }
            else {
                let child = try await pid(on: scenario == "backend-failure" ? backendPort : profile.port)
                #expect(kill(child, SIGTERM) == 0)
            }
            #expect(await waitUntil { !process.isRunning })
            #expect(PortScanner.isPortFree(profile.port, host: "127.0.0.1"))
            #expect(PortScanner.isPortFree(backendPort, host: "127.0.0.1"))
            #expect(!FileManager.default.fileExists(atPath: plan.readinessFile!))
        }

        // A lost internal-port race or a busy public port must not terminate
        // the pre-existing owner, or expose it through the new proxy.
        let python = try #require(ShellEnvironment.shared.which("python3"))
        for occupied in [backendPort, profile.port] {
            let occupant = try start(python, ["-m", "http.server", String(occupied), "--bind", "127.0.0.1"], cwd: directory.path, log: log)
            defer { if occupant.isRunning { occupant.terminate() } }
            #expect(await waitUntil { !PortScanner.isPortFree(occupied, host: "127.0.0.1") })
            let process = try start(plan.executable, plan.arguments, cwd: directory.path, log: log)
            supervisor = process
            #expect(await waitUntil { !process.isRunning })
            #expect(occupant.isRunning)
            #expect(!FileManager.default.fileExists(atPath: plan.readinessFile!))
            #expect(PortScanner.isPortFree(occupied == backendPort ? profile.port : backendPort, host: "127.0.0.1"))
            occupant.terminate()
            #expect(await waitUntil { !occupant.isRunning })
        }
        try "invalid private key".write(toFile: key, atomically: true, encoding: .utf8)
        let invalid = try start(plan.executable, plan.arguments, cwd: directory.path, log: log)
        supervisor = invalid
        #expect(await waitUntil { !invalid.isRunning })
        #expect(!FileManager.default.fileExists(atPath: plan.readinessFile!))
        #expect(PortScanner.isPortFree(profile.port, host: "127.0.0.1"))
        #expect(PortScanner.isPortFree(backendPort, host: "127.0.0.1"))
    }
}
