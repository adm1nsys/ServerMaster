import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("A6/A7 TLS and HTTP diagnostics", .serialized)
struct TLSHealthParityTests {
    private func fixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-tls-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for name in ["a", "b"] {
                let result = await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-keyout", root.appendingPathComponent(name + ".key").path,
                    "-out", root.appendingPathComponent(name + ".pem").path,
                    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1", "-addext", "extendedKeyUsage=serverAuth"])
                try #require(result.succeeded)
            }
            return root
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    private func profile(_ root: URL) throws -> ServerProfile {
        var value = ServerProfile()
        value.engine = .nodeScript
        value.rootPath = root.path
        value.nodeEntryFile = "server.cjs"
        value.host = "127.0.0.1"
        value.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        value.httpsEnabled = true
        value.certificatePath = root.appendingPathComponent("a.pem").path
        value.privateKeyPath = root.appendingPathComponent("a.key").path
        return value
    }

    private func server(_ root: URL, port: Int, mode: String, certificate: String = "a") async throws -> Process {
        let code = """
        const fs=require('fs');
        let count=0;
        const handler=(req,res)=>{
          fs.writeFileSync('requests',String(++count));
          res.setHeader('Server','ParityFixture');
          if ('\(mode)' === 'redirect') {res.writeHead(302,{Location:'http://127.0.0.1:1/unreachable'});res.end();}
          else if ('\(mode)' === 'stream') {res.writeHead(200);res.flushHeaders();const t=setInterval(()=>res.write('chunk'),30);res.on('close',()=>clearInterval(t));}
          else if ('\(mode)' === 'hang') {}
          else if ('\(mode)' === 'oversized') {res.setHeader('X-Large','x'.repeat(70*1024));res.end('large headers');}
          else {res.writeHead(200);res.end('ok');}
        };
        const server='\(mode)' === 'http'
          ? require('http').createServer(handler)
          : require('https').createServer({key:fs.readFileSync('\(certificate).key'),cert:fs.readFileSync('\(certificate).pem')},handler);
        server.listen(\(port),'127.0.0.1');
        """
        let file = root.appendingPathComponent("server.cjs")
        try code.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(ShellEnvironment.shared.which("node")))
        process.arguments = [file.path]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            for _ in 0..<150 where PortScanner.isPortFree(port, host: "127.0.0.1") {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(process.isRunning)
            return process
        } catch { stop(process); throw error }
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    @Test func certificatePairAndDates() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = try profile(root)
        try "// fixture".write(to: root.appendingPathComponent("server.cjs"), atomically: true, encoding: .utf8)
        #expect(TLSValidation.check(value).issues.isEmpty)
        #expect(TLSValidation.check(value, now: Date().addingTimeInterval(172800)).issues.contains { $0.contains("expired") })
        #expect(TLSValidation.check(value, now: Date().addingTimeInterval(-172800)).issues.contains { $0.contains("not yet") })
        value.privateKeyPath = root.appendingPathComponent("b.key").path
        #expect(TLSValidation.check(value).issues.contains { $0.contains("do not match") })
        #expect(!value.validationErrors.isEmpty)
        #expect(throws: LaunchPlanBuilder.BuildError.self) { try LaunchPlanBuilder.build(for: value, runtimeRoot: root.appendingPathComponent("runtime")) }
        let controller = ServerController(runtimeRoot: root.appendingPathComponent("runtime"))
        var settings = AppSettings(); settings.writeLogsToFile = false
        await controller.start(profile: value, settings: settings)
        #expect(controller.processIdentifier == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime").path))
        let findings = await ProfileDiagnostics.check(value, state: .stopped, databaseRunning: false, resolve: { _,_ in "/usr/bin/true" })
        #expect(findings.contains { $0.id.hasSuffix("validation") && $0.level == .broken })
        #expect(await DomainTrace().certificate(value)?.outcome == .failed)
    }

    @Test func invalidFilesAndHost() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = try profile(root)
        value.host = "localhost"
        #expect(TLSValidation.check(value).issues.contains { $0.contains("SAN") })
        value.host = "127.0.0.1"
        let encrypted = root.appendingPathComponent("encrypted.key")
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["pkey", "-in", value.privateKeyPath, "-aes-256-cbc", "-passout", "pass:test-only", "-out", encrypted.path])).succeeded)
        value.privateKeyPath = encrypted.path
        #expect(!TLSValidation.check(value).issues.isEmpty)
        let large = root.appendingPathComponent("large.pem")
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: large)
        #expect(throws: TLSValidation.Failure.self) { try TLSValidation.certificate(large.path) }
        let pipe = root.appendingPathComponent("not-a-key.fifo")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: TLSValidation.Failure.self) { try TLSValidation.read(pipe.path) }

    }

    @Test(arguments: ["redirect", "stream", "ok"])
    func healthAndTraceUseOriginalHeaders(mode: String) async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root)
        let process = try await server(root, port: value.port, mode: mode)
        defer { stop(process) }
        let health = await HealthCheck.check(value)
        #expect(health.status == (mode == "redirect" ? 302 : 200))
        #expect(health.server == "ParityFixture")
        #expect(health.problem == nil)
        let trace = await DomainTrace().request(value)
        #expect(trace.outcome == .ok)
        #expect(trace.detail.contains(mode == "redirect" ? "302" : "200"))
    }

    @Test func unexpectedCertificateAndHostnameFail() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = try profile(root)
        let process = try await server(root, port: value.port, mode: "ok", certificate: "b")
        defer { stop(process) }
        #expect(await HealthCheck.check(value).status == nil)
        #expect(await DomainTrace().request(value).outcome == .failed)
        value.certificatePath = root.appendingPathComponent("b.pem").path
        value.privateKeyPath = root.appendingPathComponent("b.key").path
        #expect(await HealthCheck.check(value).status == 200)
        value.host = "localhost"
        #expect(await HealthCheck.check(value).status == nil)
    }

    @Test func ecSANAndExternalIssuer() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("ec.key").path
        let cert = root.appendingPathComponent("ec.pem").path
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])).succeeded)
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-new", "-key", key, "-days", "1", "-out", cert,
            "-subj", "/CN=ignored.example.test", "-addext", "subjectAltName=DNS:*.example.test,IP:::1", "-addext", "extendedKeyUsage=serverAuth"])).succeeded)
        #expect(TLSValidation.check(certificatePath: cert, keyPath: key, host: "app.example.test").issues.isEmpty)
        #expect(TLSValidation.check(certificatePath: cert, keyPath: key, host: "::1").issues.isEmpty)
        #expect(!TLSValidation.check(certificatePath: cert, keyPath: key, host: "example.test").issues.isEmpty)
        #expect(!TLSValidation.check(certificatePath: cert, keyPath: key, host: "a.b.example.test").issues.isEmpty)
        // A CA-issued leaf is not mislabelled self-issued merely because it is external.
        let csr = root.appendingPathComponent("leaf.csr").path
        let leaf = root.appendingPathComponent("leaf.pem").path
        let config = root.appendingPathComponent("leaf.cnf")
        try "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n".write(to: config, atomically: true, encoding: .utf8)
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["req", "-new", "-key", key, "-subj", "/CN=External leaf", "-out", csr])).succeeded)
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["x509", "-req", "-in", csr, "-CA", root.appendingPathComponent("a.pem").path,
            "-CAkey", root.appendingPathComponent("a.key").path, "-CAcreateserial", "-days", "1", "-out", leaf, "-extfile", config.path])).succeeded)
        let assessment = TLSValidation.check(certificatePath: leaf, keyPath: key, host: "127.0.0.1")
        #expect(assessment.issues.isEmpty)
        #expect(!assessment.selfIssued)
        #expect(!assessment.systemTrusted)
        // A CN without SAN cannot satisfy the host preflight.
        try #require((await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-new", "-key", key, "-days", "1", "-out", cert,
            "-subj", "/CN=127.0.0.1", "-addext", "extendedKeyUsage=serverAuth"])).succeeded)
        #expect(TLSValidation.check(certificatePath: cert, keyPath: key, host: "127.0.0.1").issues.contains { $0.contains("SAN") })
    }

    @Test func headerLimitAndCancellation() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = try profile(root)
        let large = try await server(root, port: value.port, mode: "oversized")
        let response = await HealthCheck.check(value)
        #expect(response.status == nil)
        #expect(response.problem != nil)
        stop(large)
        value.port = try BuiltinHTTPS.freeBackendPort(excluding: value.port)
        let hanging = try await server(root, port: value.port, mode: "hang")
        defer { stop(hanging) }
        let url = try #require(HTTPStartup.address(for: value))
        #expect(await HTTPStartup.inspect(url: url, certificatePath: value.certificatePath, timeout: 0.2).result == .timedOut)
        let task = Task { await HTTPStartup.inspect(url: url, certificatePath: value.certificatePath, timeout: 60) }
        try await Task.sleep(for: .milliseconds(100))
        let began = Date()
        task.cancel()
        #expect(await task.value.status == nil)
        #expect(Date().timeIntervalSince(began) < 2)
    }
}
