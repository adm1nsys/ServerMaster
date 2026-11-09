import Foundation
import Testing
import Darwin
@testable import ServerMaster

@MainActor
@Suite("C1 stop results", .serialized)
struct StopResultTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-stop-result-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var settings: AppSettings {
        var result = AppSettings()
        result.writeLogsToFile = false
        result.openBrowserOnStart = false
        result.killPortOccupantOnStart = true // Restart must never reach this after a failed Stop.
        return result
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }

    private func spawn(_ root: URL, file: String, source: String) throws -> Process {
        let script = root.appendingPathComponent(file)
        try source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(ShellEnvironment.shared.which("node")))
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    private func profile(_ root: URL) throws -> ServerProfile {
        var profile = ServerProfile()
        profile.name = "Stop fixture"
        profile.engine = .nodeScript
        profile.host = "127.0.0.1"
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        profile.rootPath = root.path
        profile.nodeEntryFile = "server.cjs"
        try """
        const fs = require('fs');
        const server = require('http').createServer((req, res) => res.end('owned'));
        server.listen(Number(process.env.PORT), '127.0.0.1');
        process.on('SIGTERM', () => {
          server.close(() => fs.writeFileSync('released', 'yes'));
          setTimeout(() => process.exit(0), 1000);
        });
        """.write(to: root.appendingPathComponent(profile.nodeEntryFile), atomically: true, encoding: .utf8)
        return profile
    }

    private func replacement(_ root: URL, port: Int) throws -> Process {
        try spawn(root, file: "replacement.cjs", source: """
        const fs = require('fs');
        const timer = setInterval(() => {
          if (!fs.existsSync('released')) return;
          clearInterval(timer);
          const server = require('http').createServer((req,res) => res.end('independent'));
          server.listen(\(port), '127.0.0.1', () => fs.writeFileSync('replacement.ready', 'yes'));
        }, 5);
        fs.writeFileSync('replacement.waiting', 'yes');
        """)
    }

    @Test("A clean stop releases the endpoint, including concurrent Stop callers")
    func cleanStop() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root)
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings)
        try #require(controller.state == .running)
        let first = Task { await controller.stop(settings: settings) }
        try await wait { controller.state == .stopping }
        let second = await controller.stop(settings: settings)
        #expect(await first.value)
        #expect(second)
        #expect(controller.state == .stopped)
        #expect(controller.stopFailure == nil)
        #expect(controller.processIdentifier == nil)
        #expect(PortScanner.isPortFree(value.port, host: value.host))
    }

    @Test("A replacement listener fails Stop and blocks both Restart paths", arguments: ["stop", "controller-restart", "model-restart", "stop-all", "restore", "database-restore", "shutdown"])
    func replacedEndpoint(action: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root)
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"))
        model.settings = settings
        model.profiles = [value]
        let controller = model.controller(for: value.id)
        defer { controller.stopImmediately() }
        await model.startServer(profile: value)
        try #require(controller.state == .running)
        var second: ServerProfile?
        if action == "stop-all" {
            let secondRoot = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            let healthy = try profile(secondRoot)
            second = healthy
            model.profiles.append(healthy)
            await model.startServer(profile: healthy)
            try #require(model.state(of: healthy.id) == .running)
        }
        defer { if let second { model.controller(for: second.id).stopImmediately() } }
        let snapshot = Snapshot(id: "blocked-restore", profileID: value.id, profileName: value.name,
            taken: Date(), trigger: .manual, includesSite: true, includesDatabase: true,
            databaseName: "unused_fixture", bytes: 0)
        let other = try replacement(root, port: value.port)
        defer { terminate(other) }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement.waiting").path) }
        switch action {
        case "stop": #expect(!(await controller.stop(settings: settings)))
        case "controller-restart": await controller.restart(profile: value, settings: settings)
        case "model-restart": await model.restartServer(profile: value)
        case "restore":
            let result = await model.restoreSnapshot(snapshot, parts: [.site], into: value)
            #expect(result.problems.first?.contains(String(value.port)) == true)
            #expect(!model.restoreInProgress)
            #expect(!model.snapshots.isWorking)
        case "database-restore":
            let message = await model.restoreDatabaseSnapshot(snapshot)
            #expect(message?.contains(String(value.port)) == true)
            #expect(!model.restoreInProgress)
            #expect(!model.snapshots.isWorking)
        case "shutdown":
            var completed = false
            model.beginShutdown { completed = true }
            try await wait { model.shutdownItems.contains { $0.status == .failed } }
            #expect(!completed)
            #expect(model.shutdownItems.first?.detail.contains(String(value.port)) == true)
        default:
            let problems = await model.stopAll()
            #expect(problems.count == 1)
            #expect(problems.first?.contains(value.name) == true)
            #expect(model.banner?.isError == true)
            if let second {
                #expect(model.state(of: second.id) == .stopped)
                #expect(PortScanner.isPortFree(second.port, host: second.host))
            }
        }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement.ready").path) }
        guard case .failed = controller.state else { Issue.record("Occupied endpoint was reported stopped or restarted"); return }
        #expect(controller.stopFailure?.contains(String(value.port)) == true)
        #expect(controller.processIdentifier == nil)
        #expect(other.isRunning) // killPortOccupantOnStart must never run here.
        #expect(model.canStopAllServers)
        #expect(model.canStopServer(value.id))
        #expect(!controller.log.lines.contains { $0.text == "Server stopped." })
        let owners = await PortScanner.processesListening(onPort: value.port)
        #expect(owners.contains { $0.pid == other.processIdentifier })
        terminate(other)
        try await wait { !other.isRunning }
        #expect(await model.stopServer(profileID: value.id))
        #expect(controller.state == .stopped)
        #expect(controller.stopFailure == nil)
        #expect(!model.canStopAllServers)
        #expect(!model.canStopServer(value.id))
    }

    @Test("An unconfirmed elevated-session shutdown keeps its handle and can be retried")
    func elevatedTimeout() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root)
        // Exercise the same supervisor protocol without authorization or root processes.
        let process = try spawn(root, file: "supervisor.cjs", source: "setInterval(() => {}, 1000);")
        defer { terminate(process) }
        let session = PrivilegedSession(serverPID: process.processIdentifier,
            logPath: root.appendingPathComponent("privileged.log").path,
            sentinelPath: root.appendingPathComponent("running.lock").path,
            pidPath: root.appendingPathComponent("server.pid").path)
        for path in [session.logPath, session.sentinelPath, session.pidPath] {
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        }
        let controller = ServerController(runtimeRoot: root)
        defer {
            terminate(process)
            try? FileManager.default.removeItem(atPath: session.pidPath)
            controller.stopImmediately()
        }
        controller.adopt(session: session, profile: value, settings: settings)
        #expect(!(await controller.stop(settings: settings)))
        #expect(controller.isPrivileged)
        #expect(controller.processIdentifier == process.processIdentifier)
        #expect(controller.stopFailure != nil)
        #expect(!FileManager.default.fileExists(atPath: session.sentinelPath))
        await controller.start(profile: value, settings: settings)
        #expect(controller.isPrivileged)
        #expect(controller.processIdentifier == process.processIdentifier)
        terminate(process)
        try await wait { !process.isRunning }
        try FileManager.default.removeItem(atPath: session.pidPath)
        #expect(await controller.stop(settings: settings))
        #expect(!controller.isPrivileged)
        #expect(controller.state == .stopped)
    }

    @Test("Stop checks the selected interface and hidden wildcard listeners")
    func endpointAddresses() {
        var entry = PortEntry(pid: 0, command: "hidden", user: "root", proto: "TCP", family: "IPv4", address: "127.0.0.2", port: 8082)
        #expect(!PortScanner.listener(entry, matchesHost: "127.0.0.1"))
        #expect(PortScanner.listener(entry, matchesHost: "0.0.0.0"))
        entry.address = "*"
        #expect(PortScanner.listener(entry, matchesHost: "localhost"))
        entry.family = "IPv6"
        entry.address = "::"
        #expect(PortScanner.listener(entry, matchesHost: "[::1]"))
        #expect(!PortScanner.listener(entry, matchesHost: "127.0.0.1"))
    }
}
