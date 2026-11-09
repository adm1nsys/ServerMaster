import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("A4/A5 startup contract", .serialized)
struct StartupContractTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-startup-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var settings: AppSettings {
        var value = AppSettings()
        value.writeLogsToFile = false
        value.openBrowserOnStart = false
        return value
    }

    private func node(_ root: URL, source: String) throws -> ServerProfile {
        var value = ServerProfile()
        value.engine = .nodeScript
        value.host = "127.0.0.1"
        value.rootPath = root.path
        value.nodeEntryFile = "server.cjs"
        value.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        try source.write(to: root.appendingPathComponent(value.nodeEntryFile), atomically: true, encoding: .utf8)
        return value
    }

    @Test func invalidProfilesNeverLaunch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var base = ServerProfile()
        base.engine = .custom
        base.customCommand = "/bin/sleep"
        base.customArguments = "30"
        base.workingDirectory = root.path
        var port = base; port.port = 70000
        var environment = base; environment.environment = [.init(key: "PORT", value: "1"), .init(key: "PORT", value: "2")]
        var php = base; php.engine = .phpBuiltIn; php.rootPath = root.path; php.phpMemoryLimit = "invalid"
        var entry = base; entry.engine = .nodeScript; entry.rootPath = root.path; entry.nodeEntryFile = "missing.cjs"
        var working = base; working.workingDirectory = root.appendingPathComponent("missing").path
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"))
        model.settings = settings
        for value in [port, environment, php, entry, working] {
            #expect(!value.validationErrors.isEmpty)
            #expect(throws: LaunchPlanBuilder.BuildError.self) { try LaunchPlanBuilder.build(for: value, runtimeRoot: root.appendingPathComponent("runtime")) }
            let controller = ServerController(runtimeRoot: root.appendingPathComponent("runtime"))
            await controller.start(profile: value, settings: settings)
            #expect(controller.processIdentifier == nil)
            guard case .failed = controller.state else { Issue.record("Invalid profile did not fail"); return }
            model.profiles = [value]
            await model.startServer(profile: value)
            #expect(model.controller(for: value.id).processIdentifier == nil)
            #expect(model.database.state == .stopped)
            let findings = await ProfileDiagnostics.check(value, state: .stopped, databaseRunning: false, resolve: { _,_ in "/usr/bin/true" })
            #expect(findings.contains { $0.id.hasSuffix("validation") && $0.level == .broken })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime").path))
        let target = root.appendingPathComponent("actual.cjs")
        try "// valid linked entry".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("linked.cjs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        entry.nodeEntryFile = link.path
        try "{}".write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        entry.basicAuthEnabled = true // a Node script owns its auth; these http-server flags are unused
        #expect(entry.validationErrors.isEmpty)
        entry.nodeEntryFile = root.path
        #expect(!entry.validationErrors.isEmpty)

    }

    @Test func warningsAndCustomStayUsable() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = ServerProfile()
        value.engine = .custom
        value.customCommand = "/bin/sleep"
        value.customArguments = "30"
        value.rootPath = ""
        value.workingDirectory = root.path
        value.host = "0.0.0.0"
        value.hstsEnabled = true
        #expect(value.validationErrors.isEmpty)
        #expect(!value.validationIssues.isEmpty)
        #expect(Diagnostics().folders(profiles: [value]).isEmpty)
        _ = try LaunchPlanBuilder.build(for: value)
        let controller = ServerController(runtimeRoot: root, startupTimeout: 0.5)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings)
        #expect(controller.state == .running)
        await controller.stop(settings: settings)
    }

    @Test(arguments: ["idle", "wrong-port", "no-headers"])
    func nonHTTPFails(mode: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spare = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        let code = mode == "idle" ? "setInterval(()=>{},1000);" :
            "require('http').createServer((req,res)=>{}).listen(\(mode == "wrong-port" ? String(spare) : "Number(process.env.PORT)"),'127.0.0.1');"
        let value = try node(root, source: code)
        let controller = ServerController(runtimeRoot: root, startupTimeout: 0.8, responseTimeout: 0.7)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings)
        guard case .failed = controller.state else { Issue.record("Non-HTTP fixture reported running"); return }
        #expect(controller.processIdentifier == nil)
        #expect(PortScanner.isPortFree(value.port, host: value.host))
        #expect(PortScanner.isPortFree(spare, host: value.host))
    }

    @Test(arguments: ["500", "slow", "stream", "redirect"])
    func headersAreReadiness(mode: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try node(root, source: """
        const fs = require('fs'); let count=0;
        require('http').createServer((req,res)=>{
          fs.writeFileSync('requests',String(++count));
          if ('\(mode)' === 'slow') setTimeout(()=>res.end('ok'),800);
          else if ('\(mode)' === 'stream') { res.writeHead(200);res.flushHeaders();setInterval(()=>res.write('data'),50); }
          else if ('\(mode)' === 'redirect') { res.writeHead(302,{Location:'http://127.0.0.1:1/unreachable'});res.end(); }
          else { res.writeHead(500);res.end('site error'); }
        }).listen(Number(process.env.PORT),'127.0.0.1');
        """)
        let controller = ServerController(runtimeRoot: root, startupTimeout: 1, responseTimeout: 3)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings)
        #expect(controller.state == .running, "\(controller.log.plainText)")
        #expect(try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8) == "1")
        await controller.stop(settings: settings)
    }

    @Test func stopCancelsAcceptedRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try node(root, source: """
        require('http').createServer((req,res)=>require('fs').writeFileSync('accepted','yes'))
          .listen(Number(process.env.PORT),'127.0.0.1');
        """)
        let controller = ServerController(runtimeRoot: root, responseTimeout: 60)
        defer { controller.stopImmediately() }
        let start = Task { await controller.start(profile: value, settings: settings) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("accepted").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("accepted").path))
        let began = Date()
        await controller.stop(settings: settings)
        await start.value
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(controller.state == .stopped)
        #expect(controller.processIdentifier == nil)
    }

    @Test func delayedListenerAndOccupiedPort() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try node(root, source: """
        setTimeout(()=>require('http').createServer((req,res)=>res.end('ok'))
          .listen(Number(process.env.PORT),'127.0.0.1'),700);
        """)
        let first = ServerController(runtimeRoot: root, startupTimeout: 3)
        let second = ServerController(runtimeRoot: root, startupTimeout: 1)
        defer { first.stopImmediately(); second.stopImmediately() }
        await first.start(profile: value, settings: settings)
        try #require(first.state == .running)
        var noOptionalCheck = settings
        noOptionalCheck.checkPortBeforeStart = false
        await second.start(profile: value, settings: noOptionalCheck)
        guard case .failed = second.state else { Issue.record("Foreign listener was accepted as readiness"); return }
        #expect(second.processIdentifier == nil)
        #expect(first.state == .running)
        await first.stop(settings: settings)
    }

    @Test func selectedTLSCertificateAndHostname() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["server", "other"] {
            let generated = await ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-keyout", root.appendingPathComponent(name + ".key").path,
                "-out", root.appendingPathComponent(name + ".pem").path,
                "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1", "-addext", "extendedKeyUsage=serverAuth"])
            try #require(generated.succeeded)
        }
        let value = try node(root, source: """
        const fs=require('fs');
        require('https').createServer({key:fs.readFileSync('server.key'),cert:fs.readFileSync('server.pem')},
          (req,res)=>{res.writeHead(500);res.end('HTTP still ready');})
          .listen(Number(process.env.PORT),'127.0.0.1');
        """)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(ShellEnvironment.shared.which("node")))
        process.arguments = [root.appendingPathComponent(value.nodeEntryFile).path]
        process.currentDirectoryURL = root
        process.environment = ShellEnvironment.shared.environment(extra: ["PORT":String(value.port)])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<100 where PortScanner.isPortFree(value.port, host: value.host) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = try #require(URL(string: "https://127.0.0.1:\(value.port)/"))
        #expect(await HTTPStartup.headers(url: url, certificatePath: root.appendingPathComponent("server.pem").path, timeout: 3) == .response)
        #expect(await HTTPStartup.headers(url: url, certificatePath: root.appendingPathComponent("other.pem").path, timeout: 3) != .response)
        let wrongHost = try #require(URL(string: "https://localhost:\(value.port)/"))
        #expect(await HTTPStartup.headers(url: wrongHost, certificatePath: root.appendingPathComponent("server.pem").path, timeout: 3) != .response)
    }
}

@MainActor
@Suite("A9 custom environment", .serialized)
struct CustomEnvironmentTests {
    @Test("Custom child receives profile defaults and preserves explicit overrides", arguments: ["defaults", "overrides", "empty"])
    func childEnvironment(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-custom-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("environment.sh")
        try """
        printf '%s\\n%s\\n' "$HOST" "$PORT" > actual.txt
        exec /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        var profile = ServerProfile()
        profile.engine = .custom
        profile.host = "::1"
        profile.port = 8187
        profile.rootPath = ""
        profile.workingDirectory = root.path
        profile.customCommand = "/bin/sh"
        profile.customArguments = ProcessRunner.shellQuote(script.path)
        if mode != "defaults" {
            profile.environment = [.init(key: "HOST", value: mode == "empty" ? "" : "127.0.0.2"),
                                   .init(key: "PORT", value: mode == "empty" ? "" : "9199")]
        }
        var settings = AppSettings()
        settings.writeLogsToFile = false
        settings.openBrowserOnStart = false
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        await controller.start(profile: profile, settings: settings)
        try #require(controller.state == .running)
        let actual = try String(contentsOf: root.appendingPathComponent("actual.txt"), encoding: .utf8)
        let expected = mode == "defaults" ? "::1\n8187\n" : mode == "empty" ? "\n\n" : "127.0.0.2\n9199\n"
        #expect(actual == expected)
        #expect(await controller.stop(settings: settings))
    }
}
