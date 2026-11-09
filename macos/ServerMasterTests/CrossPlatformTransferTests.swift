import Foundation
import Testing
@testable import ServerMaster

@Suite("T5 profile transfer validation")
struct ProfileTransferTests {
    @MainActor
    @Test("A saved Mac user template retains database intent and PHP display-errors policy")
    func templateSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ServerProfile()
        profile.engine = .phpBuiltIn; profile.needsDatabase = true; profile.phpDisplayErrors = false
        profile.phpMemoryLimit = "768M"
        let template = ProfileTemplate.from(profile: profile, title: "Свій PHP", summary: "Fixture")
        let store = TemplateStore(storeURL: root.appendingPathComponent("store.json"))
        let file = root.appendingPathComponent("template.smtemplate")
        try store.export([template], to: file)
        let back = try #require(try store.importTemplates(from: file).first)
        let restored = back.makeProfile(name: "Restored", port: 8080, root: root.path)
        #expect(restored.needsDatabase)
        #expect(restored.phpMemoryLimit == "768M")
        #expect(!restored.phpDisplayErrors)
    }
    @Test("Single/array imports retain data and remap only colliding profile IDs")
    func merge() throws {
        var profile = ServerProfile()
        profile.name = "Перенесення"; profile.engine = .nodeScript
        profile.rootPath = "C:\\Projects\\demo"; profile.nodeEntryFile = "server.cjs"
        profile.profileColor = "#14B8A6"
        profile.environment = [.init(key: "DEMO", value: "тест")]
        let data = try ProfileTransfer.data([profile])
        let decoded = try ProfileTransfer.decode(data)
        #expect(decoded.first?.rootPath == profile.rootPath)
        #expect(decoded.first?.nodeEntryFile == profile.nodeEntryFile)
        #expect(decoded.first?.id == profile.id)
        let merged = ProfileTransfer.appending(decoded + decoded, to: [profile])
        #expect(Set(merged.map(\.id)).count == 2)
        #expect(!merged.contains { $0.id == profile.id })
        #expect(merged.map(\.environment) == [profile.environment, profile.environment])
        let single = try JSONSerialization.data(withJSONObject: (JSONSerialization.jsonObject(with: data) as! [[String: Any]])[0])
        #expect(try ProfileTransfer.decode(single).first?.name == profile.name)
        #expect(try ProfileTransfer.decode(Data([0xEF, 0xBB, 0xBF]) + data).first?.id == profile.id)
    }

    @Test("Mixed malformed imports are rejected before any merge", arguments: [
        #"{"name":"Bad","engine":"future-engine"}"#,
        #"{"name":"Bad","engine":"nodeScript","port":"oops"}"#,
        #"{"name":"Bad","engine":"nodeScript","port":70000}"#,
        #"{"name":"Bad","engine":"nodeScript","phpMaxExecutionTime":1e100}"#,
        #"{"name":"Bad","engine":"nodeScript","enableCors":1}"#,
        #"{"name":"Bad","engine":"nodeScript","id":"bad-guid"}"#,
        #"{"name":"Bad","engine":"nodeScript","environment":[{"key":"X","value":4}]}"#
    ])
    func malformed(bad: String) {
        let mixed = "[{\"name\":\"Valid\",\"engine\":\"nodeScript\"},\(bad)]"
        #expect(throws: (any Error).self) { try ProfileTransfer.decode(Data(mixed.utf8)) }
    }
}

@MainActor
@Suite("T5 production Swift and C# codec round trips", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_DOTNET"] != nil))
struct CrossPlatformTransferTests {
    @Test("Real Windows ProfileStore, UserTemplateStore and TranslationPacks consume Mac exports")
    func roundTrips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("interop-t5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dotnet = try #require(ProcessInfo.processInfo.environment["SERVERMASTER_TEST_DOTNET"])
        let harness = try #require(ProcessInfo.processInfo.environment["SERVERMASTER_TEST_INTEROP"])
        var profiles: [ServerProfile] = []
        for entry in ["server.cjs", "server.mjs", "php", "static", "php-auto"] {
            var p = ServerProfile()
            p.name = "Mac → Windows «демо» \(entry)"
            p.engine = entry.hasPrefix("php") ? .phpBuiltIn : entry == "static" ? .httpServer : .nodeScript
            p.rootPath = "/Users/example/Демо with spaces"; p.workingDirectory = p.rootPath
            p.port = 9400 + profiles.count; p.nodeEntryFile = entry.hasPrefix("server") ? entry : "server.js"
            p.profileColor = "#14B8A6"; p.errorPageAccent = "#EF4444"; p.errorPageFooter = "Український підпис"
            p.templateId = "portable-template"; p.needsDatabase = true; p.databaseName = "t5_demo"
            p.enableCORS = true; p.enableGzip = false; p.configPreset = "spa"; p.spaFallback = false; p.directoryListing = true
            p.basicAuthEnabled = true; p.basicAuthUser = "demo"; p.basicAuthPassword = "test-only-\"\\пароль"
            p.phpVersion = entry == "php-auto" ? "" : "8.3"; p.phpMemoryLimit = "768M"; p.phpUploadMaxFilesize = "256M"; p.phpMaxExecutionTime = 600
            p.phpDisplayErrors = false; p.httpsEnabled = true; p.certificatePath = "/tmp/demo.pem"; p.privateKeyPath = "/tmp/demo.key"
            p.notes = "Тест\nline\tend"; p.environment = [.init(key: "MODE", value: "демо"), .init(key: "EMPTY", value: "")]
            profiles.append(p)
        }
        try ProfileTransfer.data(profiles).write(to: root.appendingPathComponent("mac-profiles.json"))
        let templates = TemplateStore(storeURL: root.appendingPathComponent("templates/store.json"))
        var node = ProfileTemplate.from(profile: profiles[0], title: "Свій Node", summary: "Portable fixture")
        node.questions = [.folder, .name, .port, .entryFile]
        #expect(node.needsDatabase, "A Node product's database requirement must survive saving a user template")
        var command = ProfileTemplate.from(profile: profiles[1], title: "Своя команда", summary: "Portable custom command")
        command.id = "portable-command"; command.settings.engine = .custom
        command.settings.customCommand = "node"; command.settings.customArguments = "server.mjs --demo"
        var rich = node; rich.id = "portable-rich"; rich.quickSetup = true; rich.settings.httpsEnabled = true
        rich.settings.iconName = "terminal"; rich.category = .publishing
        rich.packageKind = "wordpress-w2p"; rich.packageSource = "https://wordpress.org/latest.zip"
        rich.recipeKind = "wordpress-w2p-showcase"; rich.pluginPackages = ["woocommerce", "printcart-integration"]
        try templates.export([node, command, rich], to: root.appendingPathComponent("mac-templates.smtemplate"))
        var native = node; native.id = "mac-native"; native.settings.engine = .apachePHP
        try templates.export([native], to: root.appendingPathComponent("mac-native.smtemplate"))
        let strings = ["T5 test": "Перенесення працює", "Escaped": "Рядок\nТаб\t\"шлях\" C:\\demo\rкінець",
                       "%lld items for %@": "%lld елементів для %@", "Empty": ""]
        let pack = TranslationPack(language: "uk", appVersion: "2.1.0", packVersion: "7", strings: strings)
        try TranslationStore.serialized(pack).write(to: root.appendingPathComponent("mac-uk.strings"), atomically: true, encoding: .utf8)
        let result = await ProcessRunner.run(dotnet, [harness, root.path], env: ["DOTNET_CLI_TELEMETRY_OPTOUT": "1",
            "DOTNET_CLI_HOME": root.appendingPathComponent("dotnet-home").path], timeout: 60)
        try #require(result.succeeded, "\(result.combined)")
        let back = try ProfileTransfer.read(root.appendingPathComponent("mac-via-windows.json"))
        #expect(back.count == profiles.count)
        for (before, after) in zip(profiles, back) {
            // IDs are GUIDs in C#: casing changes are not identity changes.
            #expect(before.id == after.id)
            let automaticPHP = before.engine == .phpBuiltIn && before.phpVersion.isEmpty
            if automaticPHP { #expect(after.phpVersion == "8.3", "Current Windows model has no automatic PHP branch") }
            let a = try #require(JSONSerialization.jsonObject(with: ProfileTransfer.data([before])) as? [[String: Any]])[0]
            let b = try #require(JSONSerialization.jsonObject(with: ProfileTransfer.data([after])) as? [[String: Any]])[0]
            for (key, value) in a where !["id", "environment"].contains(key) {
                if automaticPHP && key == "phpVersion" { continue }
                #expect(value as? NSObject == b[key] as? NSObject, "Profile field changed via Windows: \(key)")
            }
            #expect(before.environment == after.environment)
        }
        let windows = try ProfileTransfer.read(root.appendingPathComponent("windows-profiles.json"))
        #expect(windows.count == 3)
        #expect(windows[0].rootPath == "C:\\Projects\\Демо with spaces")
        #expect(windows[0].profileColor == "#14B8A6")
        #expect(windows[0].nodeEntryFile == "server.cjs")
        #expect(windows[1].nodeEntryFile == "server.mjs")
        #expect(windows[2].phpMemoryLimit == "768M" && windows[2].phpDisplayErrors == false)

        let returned = try templates.importTemplates(from: root.appendingPathComponent("mac-via-windows.smtemplate"))
        #expect(returned[0].settings.nodeEntryFile == node.settings.nodeEntryFile)
        #expect(returned[0].settings.phpMemoryLimit == node.settings.phpMemoryLimit)
        #expect(returned[0].settings.phpUploadMaxFilesize == node.settings.phpUploadMaxFilesize)
        #expect(returned[0].settings.phpMaxExecutionTime == node.settings.phpMaxExecutionTime)
        #expect(returned[0].needsDatabase == node.needsDatabase)
        #expect(returned[0].settings.phpDisplayErrors, "Current Windows template codec does not retain this flag")
        #expect(returned[1].settings.customCommand == "node")
        #expect(returned[1].settings.customArguments == command.settings.customArguments)
        // Current, unmodified Windows codec limitations are explicit evidence,
        // not fixed by stripping these fields from the Mac exporter.
        #expect(returned[2].quickSetup == false)
        #expect(returned[2].settings.httpsEnabled == false)
        #expect(returned[2].settings.iconName == nil)
        #expect(returned[2].packageKind == rich.packageKind && returned[2].recipeKind == rich.recipeKind)
        #expect(returned[2].pluginPackages == rich.pluginPackages)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("report.json"))) as? [String: Any])
        #expect((report["nativeRejection"] as? String)?.contains("not available on Windows") == true)

        let translation = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mac-translation-read.json"))) as? [String: Any])
        #expect(translation["strings"] as? [String: String] == strings)
        #expect(translation["packVersion"] as? String == "7")
        let windowsPack = try #require(TranslationStore.read(root.appendingPathComponent("windows-uk.strings")))
        #expect(windowsPack.language == "uk")
        #expect(windowsPack.strings["Profile icon"] == "Іконка профілю")
        #expect(windowsPack.strings.count > 100)
        try TranslationStore.serialized(windowsPack).write(to: root.appendingPathComponent("uk-again.strings"), atomically: true, encoding: .utf8)
        #expect(TranslationStore.read(root.appendingPathComponent("uk-again.strings"))?.strings == windowsPack.strings)
        try ProfileTransfer.data(windows).write(to: root.appendingPathComponent("windows-via-mac.json"))
        let verified = await ProcessRunner.run(dotnet, [harness, root.path, "verify-return"], env: ["DOTNET_CLI_TELEMETRY_OPTOUT": "1",
            "DOTNET_CLI_HOME": root.appendingPathComponent("dotnet-home").path], timeout: 60)
        try #require(verified.succeeded, "\(verified.combined)")

        // Adapt paths explicitly, then launch the transferred Node source on
        // Mac; neither import nor the C# serializer is allowed to start it.
        var settings = AppSettings(); settings.writeLogsToFile = false
        for original in windows.prefix(2) {
            var local = original
            local.rootPath = root.appendingPathComponent(original.nodeEntryFile + "-project").path
            local.workingDirectory = local.rootPath; local.httpsEnabled = false
            local.port = try BuiltinHTTPS.freeBackendPort(excluding: 0); local.openBrowserOnStart = false
            try FileManager.default.createDirectory(atPath: local.rootPath, withIntermediateDirectories: true)
            let nodeSource = original.nodeEntryFile.hasSuffix(".cjs") ? "const http=require('node:http');" : "import http from 'node:http';"
            try (nodeSource + "http.createServer((req,res)=>{res.end(JSON.stringify({mode:process.env.MODE,empty:process.env.EMPTY}));}).listen(Number(process.env.PORT),'127.0.0.1');")
                .write(toFile: local.rootPath + "/" + local.nodeEntryFile, atomically: true, encoding: .utf8)
            let controller = ServerController(runtimeRoot: root.appendingPathComponent("runtime"))
            defer { controller.stopImmediately() }
            await controller.start(profile: local, settings: settings)
            try #require(controller.state == .running, "\(controller.log.plainText)")
            let page = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--max-time", "5", local.address])
            #expect(page.succeeded)
            let payload = try #require(JSONSerialization.jsonObject(with: Data(page.stdout.utf8)) as? [String: String])
            #expect(payload["mode"] == "демо" && payload["empty"] == "")
            await controller.stop(settings: settings)
        }
    }
}
