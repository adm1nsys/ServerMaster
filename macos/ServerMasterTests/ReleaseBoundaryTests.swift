import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("Release operation boundaries", .serialized)
struct ReleaseBoundaryTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-release-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(_ root: URL) -> AppModel {
        let model = AppModel(applicationDirectory: root)
        model.profiles = []
        model.settings.writeLogsToFile = false
        model.settings.openBrowserOnStart = false
        model.settings.restartOnCrash = true
        return model
    }

    private func nodeProfile(_ root: URL, crashing: Bool = false) throws -> ServerProfile {
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.rootPath = root.path
        profile.nodeEntryFile = "server.cjs"
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        let crash = crashing ? "setTimeout(() => process.exit(7), 1600);" : ""
        try """
        require('http').createServer((req,res) => res.end('ok')).listen(Number(process.env.PORT),'127.0.0.1');
        \(crash)
        """.write(to: root.appendingPathComponent(profile.nodeEntryFile), atomically: true, encoding: .utf8)
        return profile
    }

    @Test("UTF-8 split at every byte, CRLF and EOF preserve complete lines")
    func unicodeChunks() {
        let source = "Привіт 🌻\r\nhttp://[::1]:8080/path?q=1\nХвіст"
        let reader = ProcessOutputLines()
        var lines: [ProcessOutputLines.Line] = []
        for byte in source.utf8 { lines += reader.consume(Data([byte])) }
        lines += reader.consume(Data(), endOfFile: true)
        #expect(lines.map(\.text).joined() == source)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.complete })
        #expect(ServerController.extractURLs(from: lines[1].text) == ["http://[::1]:8080/path?q=1"])
    }

    @Test("Unterminated output is bounded without cutting multibyte characters")
    func boundedOutput() {
        let source = String(repeating: "🌻", count: 40_000)
        let reader = ProcessOutputLines()
        let fragments = reader.consume(Data(source.utf8))
        let tail = reader.consume(Data(), endOfFile: true)
        #expect(!fragments.isEmpty)
        #expect(fragments.allSatisfy { !$0.complete && !$0.text.contains("�") })
        #expect((fragments + tail).map(\.text).joined() == source)
        #expect(reader.consume(Data(), endOfFile: true).isEmpty)
    }

    @Test("Two concurrent sessions with the same name preserve both log files")
    func logIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConsoleLog()
        let second = ConsoleLog()
        first.startFileLogging(name: "Same name", directory: root)
        first.append("First session")
        second.startFileLogging(name: "Same name", directory: root)
        second.append("Second session")
        first.stopFileLogging()
        second.stopFileLogging()
        let firstURL = try #require(first.fileURL)
        let secondURL = try #require(second.fileURL)
        #expect(firstURL != secondURL)
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "First session\n")
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "Second session\n")
    }

    @Test("Failed template add, rename and removal preserve memory and previous disk data")
    func templateTransactions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("templates.json")
        let store = TemplateStore(storeURL: path)
        let source = try #require(ProfileTemplate.builtIn.first { $0.id == "wordpress" })
        let first = try store.add(source)
        let previous = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let sentinel = path.appendingPathComponent("preserve")
        try previous.write(to: sentinel)
        #expect(throws: (any Error).self) { try store.add(source) }
        #expect(throws: (any Error).self) { try store.rename(first, to: "Changed") }
        #expect(throws: (any Error).self) { try store.remove(first) }
        #expect(store.userTemplates == [first])
        #expect(try Data(contentsOf: sentinel) == previous)
    }

    @Test("One invalid engine rejects a whole batch; older valid settings still load")
    func templateValidation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemplateStore(storeURL: root.appendingPathComponent("templates.json"))
        let file = root.appendingPathComponent("batch.smtemplate")
        try Data(#"[{"id":"ok","title":"OK","summary":"Old format"},{"id":"bad","title":"Bad","summary":"Unknown engine","settings":{"engine":"future"}}]"#.utf8).write(to: file)
        #expect(throws: TemplateStore.TemplateError.self) { try store.importTemplates(from: file) }
        #expect(store.userTemplates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("templates.json").path))
        try Data(#"{"id":"old","title":"Old","summary":"Old format","settings":{"engine":"nodeScript"}}"#.utf8).write(to: file)
        #expect(try store.importTemplates(from: file).first?.settings.engine == .nodeScript)
    }

    @Test("Supported package metadata survives an arbitrary imported ID")
    func downloadMetadata() throws {
        for kind in ["wordpress", "wordpress-w2p", "joomla5", "joomla6", "printshopcrm"] {
            var template = try #require(ProfileTemplate.builtIn.first)
            template.id = "user-copy.1234"
            template.packageKind = kind
            #expect(DownloadableProject.forTemplate(template) != nil)
            template.packageKind = "unsupported-kind"
            #expect(DownloadableProject.forTemplate(template) == nil)
        }
    }

    @Test("A batch reserves the store between operations and rejects other tokens")
    func snapshotBatch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(destination: root.path)
        let batch = try #require(store.beginBatch())
        #expect(store.isWorking)
        #expect(store.beginBatch() == nil)
        #expect(!store.setDestination(root.appendingPathComponent("other").path))
        var profile = ServerProfile()
        profile.rootPath = ""
        #expect(await store.take(profile: profile, database: nil) == nil)
        #expect(await store.take(profile: profile, database: nil, batch: UUID()) == nil)
        #expect(await store.take(profile: profile, database: nil, batch: batch) != nil)
        #expect(store.isWorking)
        store.endBatch(UUID())
        #expect(store.isWorking)
        store.endBatch(batch)
        #expect(!store.isWorking)
        #expect(await store.take(profile: profile, database: nil, batch: batch) == nil)
        #expect(store.setDestination(root.appendingPathComponent("other").path))
    }

    @Test("Shared model blocks all starts and destination changes during a backup reservation")
    func modelBackupBarrier() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root)
        let profile = try nodeProfile(root)
        model.profiles = [profile]
        let batch = try #require(model.snapshots.beginBatch())
        await model.startServer(profile: profile)
        #expect(model.state(of: profile.id) == .stopped)
        #expect(!model.setBackupDestination(root.appendingPathComponent("other").path))
        #expect(model.settings.backupDestination.isEmpty)
        model.snapshots.endBatch(batch)
        #expect(model.setBackupDestination(root.appendingPathComponent("other").path))
        let loaded = AppModel(applicationDirectory: root)
        #expect(loaded.settings.backupDestination == model.settings.backupDestination)
        await model.startServer(profile: profile)
        #expect(model.state(of: profile.id) == .running)
        await model.stopAll()
        #expect(model.state(of: profile.id) == .stopped)
    }

    @Test("Stop all, deletion and shutdown cancel an actual pending crash recovery")
    func cancelRecovery() async throws {
        for action in ["stop-all", "delete", "shutdown"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = model(root)
            let profile = try nodeProfile(root, crashing: true)
            model.profiles = [profile]
            defer { model.controller(for: profile.id).stopImmediately() }
            await model.startServer(profile: profile)
            for _ in 0..<150 {
                if case .failed = model.state(of: profile.id) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .failed = model.state(of: profile.id) else {
                Issue.record("Fixture must crash before testing cancellation")
                return
            }
            #expect(model.canStopAllServers)
            if action == "stop-all" { await model.stopAll() }
            if action == "delete" { model.deleteProfile(profile) }
            if action == "shutdown" { model.beginShutdown {} }
            try await Task.sleep(for: .milliseconds(1400))
            #expect(model.controller(for: profile.id).processIdentifier == nil)
            #expect(PortScanner.isPortFree(profile.port, host: profile.host))
            #expect(!model.canStopAllServers)
        }
    }

    @Test("Database-only schedules report a stopped DB even with no profiles")
    func databaseOnlySchedule() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root)
        model.settings.backupsEnabled = true
        model.settings.backupEvery = 1
        model.settings.backupAllDatabases = true
        model.settings.lastBackup = nil
        await model.runScheduledBackupIfDue()
        #expect(model.banner?.text == String(localized: "Database not included: MariaDB was stopped."))
        #expect(model.settings.lastBackup == nil)
        #expect(!model.snapshots.isWorking)
        #expect(!model.scheduledBackupInProgress)
    }

    @Test("A settings write failure rolls back the backup destination")
    func backupDestinationRollback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root)
        let previousPath = model.snapshots.destinationPath
        let file = root.appendingPathComponent("settings.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let keep = file.appendingPathComponent("preserve")
        try saved.write(to: keep)
        #expect(!model.setBackupDestination(root.appendingPathComponent("new").path))
        #expect(model.snapshots.destinationPath == previousPath)
        #expect(model.settings.backupDestination.isEmpty)
        #expect(try Data(contentsOf: keep) == saved)
    }

    @Test("Cancelling a pending start cleans its process and allows a later start")
    func cancelStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try nodeProfile(root)
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        var settings = AppSettings()
        settings.writeLogsToFile = false
        settings.openBrowserOnStart = false
        let start = Task { await controller.start(profile: profile, settings: settings) }
        for _ in 0..<100 where controller.processIdentifier == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(controller.processIdentifier != nil)
        start.cancel()
        await start.value
        #expect(controller.state == .stopped)
        #expect(controller.processIdentifier == nil)
        #expect(PortScanner.isPortFree(profile.port, host: profile.host))
        await controller.start(profile: profile, settings: settings)
        #expect(controller.state == .running)
        await controller.stop(settings: settings)
    }
}
