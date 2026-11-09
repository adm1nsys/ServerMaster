import Foundation
import Testing
import Darwin
@testable import ServerMaster

@MainActor
@Suite("R2 Node managed HTTPS", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_CADDY"] != nil))
struct NodeHTTPSTests {
    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    private func pid(on port: Int) async throws -> Int32 {
        let result = await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return try #require(result.stdout.split(separator: "\n").first.flatMap { Int32($0) })
    }

    private func backendPort(config: URL) throws -> Int {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let apps = try #require(json["apps"] as? [String: Any])
        let http = try #require(apps["http"] as? [String: Any])
        let servers = try #require(http["servers"] as? [String: Any])
        let site = try #require(servers["site"] as? [String: Any])
        let route = try #require((site["routes"] as? [[String: Any]])?.first)
        let handle = try #require((route["handle"] as? [[String: Any]])?.first)
        let upstream = try #require((handle["upstreams"] as? [[String: Any]])?.first)
        let dial = try #require(upstream["dial"] as? String)
        return try #require(dial.split(separator: ":").last.flatMap { Int($0) })
    }

    @Test("CJS/ESM use verified TLS, private environment, restart and joint failure cleanup", arguments: ["cjs", "mjs"])
    func lifecycle(ext: String) async throws {
        let caddy = try #require(ProcessInfo.processInfo.environment["SERVERMASTER_TEST_CADDY"])
        try #require(ShellEnvironment.shared.which("caddy") == caddy, "The test PATH must point to the isolated Caddy binary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-https-r2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let certificate = root.appendingPathComponent("certificate.pem").path
        let key = root.appendingPathComponent("key.pem").path
        let generated = await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key, "-out", certificate, "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
        try #require(generated.succeeded)
        let script = (ext == "cjs" ? "const { createServer } = require('node:http');\n" : "import { createServer } from 'node:http';\n") + """
        const host = process.argv.includes('--wrong-bind') ? '::1' : process.env.HOST;
        const port = Number(process.env.PORT);
        createServer((request, response) => {
          response.setHeader('Content-Type', 'application/json');
          response.end(JSON.stringify({host, port, demo: process.env.DEMO,
            args: process.argv.slice(2), path: request.url, forwarded: request.headers['x-forwarded-proto']}));
        }).listen(port, host, () => console.log(`private http://${host}:${port}`));
        """
        try script.write(to: root.appendingPathComponent("server.\(ext)"), atomically: true, encoding: .utf8)
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.rootPath = root.path
        profile.nodeEntryFile = "server.\(ext)"
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        profile.httpsEnabled = true
        profile.certificatePath = certificate
        profile.privateKeyPath = key
        profile.extraArguments = "--label 'argument with spaces'"
        profile.environment = [.init(key: "PORT", value: "1"), .init(key: "HOST", value: "203.0.113.1"),
                               .init(key: "DEMO", value: "Українська ' \\ \n")]
        var settings = AppSettings()
        settings.writeLogsToFile = false
        settings.openBrowserOnStart = false
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        let config = root.appendingPathComponent("https-\(profile.id.uuidString)/caddy.json")

        for scenario in ["stop", "backend-failure", "proxy-failure"] {
            await controller.start(profile: profile, settings: settings)
            try #require(controller.state == .running, "\(controller.log.lines.map(\.text).joined(separator: "\n"))")
            let backend = try backendPort(config: config)
            #expect(backend != profile.port && backend > 1023)
            let response = await ProcessRunner.run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--noproxy", "*", "--max-time", "5", "--cacert", certificate, profile.address + "/probe?demo=yes"])
            try #require(response.succeeded, "\(response.combined)")
            let json = try #require(JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any])
            #expect(json["host"] as? String == "127.0.0.1")
            #expect(json["port"] as? Int == backend)
            #expect(json["demo"] as? String == profile.environment.last?.value)
            #expect(json["args"] as? [String] == ["--label", "argument with spaces"])
            #expect(json["forwarded"] as? String == "https")
            #expect(json["path"] as? String == "/probe?demo=yes")
            #expect(controller.detectedURLs == [profile.address], "The backend URL must not replace the public HTTPS URL")
            #expect(profile.environment.first?.value == "1", "Building a backend must not rewrite the saved profile")
            if scenario == "stop" {
                let untrusted = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--noproxy", "*", "--max-time", "5", profile.address])
                #expect(untrusted.exitCode == 60)
                await controller.stop(settings: settings)
                #expect(controller.state == .stopped)
            } else {
                let child = try await pid(on: scenario == "backend-failure" ? backend : profile.port)
                #expect(kill(child, SIGTERM) == 0)
                #expect(await waitUntil { if case .failed = controller.state { return true }; return false })
            }
            #expect(await waitUntil { PortScanner.isPortFree(profile.port, host: "127.0.0.1") && PortScanner.isPortFree(backend, host: "127.0.0.1") })
        }
        // Ignore HOST but bind only to another loopback address: no LAN exposure.
        profile.extraArguments = "--wrong-bind"
        await controller.start(profile: profile, settings: settings)
        if case .failed = controller.state { } else { Issue.record("An unmanaged Node bind was accepted") }
        let refusedBackend = try backendPort(config: config)
        #expect(controller.log.lines.contains { $0.text.contains("managed loopback") })
        #expect(await waitUntil { PortScanner.isPortFree(profile.port, host: "127.0.0.1") && PortScanner.isPortFree(refusedBackend, host: "::1") })
    }
}
