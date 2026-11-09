import Foundation
import Testing
import Darwin
@testable import ServerMaster

@MainActor
@Suite(.serialized)
struct ReleaseFlowRegressionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-final-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func record(_ name: String, _ value: [String: Any]) throws {
        let expected: [String: [String: Bool]] = [
            "chunks": ["unicodePreserved": true, "containsReplacement": false, "detectedCompleteURL": true],
            "descendants": ["childStillAlive": false, "childStillOwnsPort": false],
            "overlap": ["newStartAcceptedWhileStopping": false, "controllerHasPID": false, "secondPortStillOccupied": false],
            "storage": ["stoppedDatabaseIncluded": false, "stoppedDatabaseOmissionHasNote": true,
                        "stoppedDatabaseOmissionHasError": true, "destinationChangeWhileBusyIgnored": true,
                        "unwritableTemplateImportReportedSuccess": false, "unwritableTemplateFileExists": false,
                        "copiedTemplateIDChanged": true, "copiedTemplateDownloadAvailable": true,
                        "unknownTemplateEngineAccepted": false],
            "ports": ["occupiedIPv6PortReportedFree": false, "selectedPortFreeBeforeKill": true,
                      "staleEntryPIDSignalSucceeded": false, "staleEntryProcessTerminated": false]
        ]
        for (key, expectedValue) in expected[name] ?? [:] {
            #expect(value[key] as? Bool == expectedValue, "\(name).\(key)")
        }
        if name == "ports" {
            #expect((value["ipv6WildcardURL"] as? String)?.hasPrefix("http://[::1]:") == true)
        }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "/tmp/servermaster-b-verified-\(name).json"), options: .atomic)
    }
    private func settings() -> AppSettings {
        var result = AppSettings()
        result.writeLogsToFile = false
        result.openBrowserOnStart = false
        return result
    }
    private func profile(root: URL, file: String) throws -> ServerProfile {
        var value = ServerProfile()
        value.engine = .nodeScript
        value.rootPath = root.path
        value.nodeEntryFile = file
        value.host = "127.0.0.1"
        value.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        return value
    }
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }
    private func killFixture(_ pidFile: URL) {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text), pid > 1 {
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    @Test func outputChunks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root: root, file: "chunks.cjs")
        let expectedURL = "http://127.0.0.1:\(value.port)/"
        try """
        const http = require('http');
        const message = Buffer.from('Привіт 🌻\\n');
        const url = 'http://127.0.0.1:' + process.env.PORT + '/';
        http.createServer((req,res) => res.end('ok')).listen(Number(process.env.PORT), '127.0.0.1', () => {
          process.stdout.write(message.subarray(0,1));
          setTimeout(() => process.stdout.write(message.subarray(1)), 180);
          setTimeout(() => process.stdout.write(url.slice(0,18)), 380);
          setTimeout(() => process.stdout.write(url.slice(18) + '\\n'), 580);
        });
        """.write(to: root.appendingPathComponent(value.nodeEntryFile), atomically: true, encoding: .utf8)
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings())
        try #require(controller.state == .running)
        // Running is not a promise that the fixture's delayed output has arrived.
        // Wait for that output explicitly instead of depending on Node startup speed.
        await until {
            controller.log.lines.contains { $0.stream == .stdout && $0.text.contains(expectedURL) }
        }
        let output = controller.log.lines.filter { $0.stream == .stdout }.map(\.text).joined()
        try record("chunks", ["unicodePreserved": output.contains("Привіт 🌻"), "containsReplacement": output.contains("�"),
                              "expectedURL": expectedURL, "detectedURLs": controller.detectedURLs,
                              "detectedCompleteURL": controller.detectedURLs.contains(expectedURL)])
        await controller.stop(settings: settings())
    }

    @Test func descendants() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try profile(root: root, file: "parent.cjs")
        let pidFile = root.appendingPathComponent("child.pid")
        defer { killFixture(pidFile) }
        try """
        const fs = require('fs');
        if (process.argv[2] === 'child') {
          require('http').createServer((req,res)=>res.end('child')).listen(Number(process.env.PORT), '127.0.0.1', () => fs.writeFileSync('child.pid',String(process.pid)));
        } else {
          require('child_process').spawn(process.execPath,[__filename,'child'],{stdio:'ignore'});
          setInterval(()=>{},1000);
        }
        """.write(to: root.appendingPathComponent(value.nodeEntryFile), atomically: true, encoding: .utf8)
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings())
        await until { FileManager.default.fileExists(atPath: pidFile.path) }
        try #require(FileManager.default.fileExists(atPath: pidFile.path))
        let childPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        await controller.stop(settings: settings())
        let occupants = await PortScanner.processesListening(onPort: value.port)
        try record("descendants", ["stateAfterStop": String(describing: controller.state),
                                   "childStillAlive": PrivilegedLauncher.isAlive(pid: childPID),
                                   "childStillOwnsPort": occupants.contains { $0.pid == childPID }])
        killFixture(pidFile)
        await until { !PrivilegedLauncher.isAlive(pid: childPID) }
    }

    @Test func overlappingLifecycle() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var value = try profile(root: root, file: "lifecycle.cjs")
        let pidFile = root.appendingPathComponent("second.pid")
        defer { killFixture(pidFile) }
        try """
        const second = process.argv.includes('--second');
        if (!second) process.on('SIGTERM', () => setTimeout(() => process.exit(0),2500));
        require('http').createServer((req,res)=>res.end('ok')).listen(Number(process.env.PORT), '127.0.0.1', () => {
          if (second) require('fs').writeFileSync('second.pid',String(process.pid));
        });
        """.write(to: root.appendingPathComponent(value.nodeEntryFile), atomically: true, encoding: .utf8)
        let controller = ServerController(runtimeRoot: root)
        defer { controller.stopImmediately() }
        await controller.start(profile: value, settings: settings())
        try #require(controller.state == .running)
        let stopping = Task { await controller.stop(settings: settings()) }
        await until { controller.state == .stopping }
        try #require(controller.state == .stopping)
        value.port = try BuiltinHTTPS.freeBackendPort(excluding: value.port)
        value.extraArguments = "--second"
        await controller.start(profile: value, settings: settings())
        let newStartAccepted = FileManager.default.fileExists(atPath: pidFile.path)
        #expect(await stopping.value)
        let occupants = await PortScanner.processesListening(onPort: value.port)
        try record("overlap", ["newStartAcceptedWhileStopping": newStartAccepted,
                               "controllerState": String(describing: controller.state),
                               "controllerHasPID": controller.processIdentifier != nil,
                               "secondPortStillOccupied": !occupants.isEmpty])
        killFixture(pidFile)
        await controller.start(profile: value, settings: settings())
        #expect(controller.state == .running)
        #expect(controller.processIdentifier != nil)
        await controller.stop(settings: settings())
        #expect(PortScanner.isPortFree(value.port, host: value.host))
    }

    @Test func storageAndTemplates() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: false)
        try "snapshot fixture".write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var value = ServerProfile()
        value.rootPath = site.path
        value.databaseName = "audit_db"
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("db"), credentials: .init(save: { _,_,_ in }, read: { _ in nil }, delete: { _ in }))
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let store = SnapshotStore(destination: first.path)
        let taking = Task { await store.take(profile: value, database: database, trigger: .scheduled) }
        await until { store.isWorking }
        try #require(store.isWorking)
        store.setDestination(second.path)
        let snapshot = try #require(await taking.value)
        var result: [String: Any] = ["stoppedDatabaseIncluded": snapshot.includesDatabase,
                                     "stoppedDatabaseOmissionHasNote": snapshot.note != nil,
                                     "stoppedDatabaseOmissionHasError": store.lastError != nil,
                                     "destinationChangeWhileBusyIgnored": store.folder(for: snapshot).path.hasPrefix(first.path + "/")]
        let blocker = root.appendingPathComponent("blocker")
        try Data("blocker".utf8).write(to: blocker)
        let badStore = TemplateStore(storeURL: blocker.appendingPathComponent("templates.json"))
        let goodStore = TemplateStore(storeURL: root.appendingPathComponent("templates.json"))
        let template = try #require(ProfileTemplate.builtIn.first { $0.id == "wordpress" })
        let input = root.appendingPathComponent("source.smtemplate")
        try goodStore.export([template], to: input)
        do {
            let imported = try badStore.importTemplates(from: input)
            result["unwritableTemplateImportReportedSuccess"] = !imported.isEmpty
        } catch { result["unwritableTemplateImportReportedSuccess"] = false }
        result["unwritableTemplateFileExists"] = FileManager.default.fileExists(atPath: blocker.appendingPathComponent("templates.json").path)
        let imported = try #require(try goodStore.importTemplates(from: input).first)
        result["copiedTemplateIDChanged"] = imported.id != template.id
        result["copiedTemplatePackageKind"] = imported.packageKind
        result["copiedTemplateDownloadAvailable"] = DownloadableProject.forTemplate(imported) != nil
        let unknown = root.appendingPathComponent("unknown.smtemplate")
        try Data(#"{"id":"unknown-audit","title":"Audit","summary":"Fixture","questions":["folder"],"settings":{"engine":"unknown-future-engine"}}"#.utf8).write(to: unknown)
        do {
            let loaded = try goodStore.importTemplates(from: unknown)
            result["unknownTemplateEngineAccepted"] = true
            result["unknownTemplateEngineBecame"] = loaded.first?.settings.engine.rawValue
        } catch { result["unknownTemplateEngineAccepted"] = false }
        let strings = root.appendingPathComponent("uk.strings")
        try "/* Language: uk\nApp version: 2.0\nPack version: 1 */\n\"Audit\" = \"Перевірка\";\n".write(to: strings, atomically: true, encoding: .utf8)
        result["foundationReadsBareStrings"] = (NSDictionary(contentsOf: strings) as? [String: String])?["Audit"] == "Перевірка"
        result["translationCodecReadsBareStrings"] = TranslationStore.read(strings)?.strings["Audit"] == "Перевірка"
        let log = root.appendingPathComponent("same-name_same-second.log")
        FileManager.default.createFile(atPath: log.path, contents: Data("first session".utf8))
        FileManager.default.createFile(atPath: log.path, contents: nil)
        result["createExistingLogTruncatesPrevious"] = try Data(contentsOf: log).isEmpty
        try record("storage", result)
    }

    @Test func ports() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        try #require(bound == 0 && listen(fd,1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd,$0,&length) } }
        let ipv6Port = Int(UInt16(bigEndian: address.sin6_port))
        var result: [String: Any] = ["occupiedIPv6PortReportedFree": PortScanner.isPortFree(ipv6Port, host: "::1")]
        let entry = PortEntry(pid: 0, command: "fixture", user: "fixture", proto: "TCP", family: "IPv6", address: "::", port: ipv6Port)
        result["ipv6WildcardURL"] = entry.localURL?.absoluteString
        let node = try #require(ShellEnvironment.shared.which("node"))
        let port = try BuiltinHTTPS.freeBackendPort(excluding: ipv6Port)
        let script = root.appendingPathComponent("close-port.cjs")
        try """
        const fs = require('fs');
        const server = require('net').createServer().listen(\(port),'127.0.0.1');
        setInterval(() => { if (fs.existsSync('close')) server.close(); },30);
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var selected: PortEntry?
        for _ in 0..<60 {
            selected = await PortScanner.processesListening(onPort: port).first { $0.pid == process.processIdentifier }
            if selected != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let savedEntry = try #require(selected)
        try Data().write(to: root.appendingPathComponent("close"))
        for _ in 0..<60 {
            if PortScanner.isPortFree(port,host:"127.0.0.1") { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        result["selectedPortFreeBeforeKill"] = PortScanner.isPortFree(port,host:"127.0.0.1")
        let killed = await PortScanner.terminate(savedEntry, signal: .term)
        try await Task.sleep(for: .milliseconds(100))
        result["staleEntryPIDSignalSucceeded"] = killed.succeeded
        result["staleEntryProcessTerminated"] = !process.isRunning
        try record("ports", result)
    }
}
