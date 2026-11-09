import Foundation
import Testing
@testable import ServerMaster

@Suite("Portable profile/template/translation combinations")
struct PortableFormatTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Windows profiles retain portable fields and tolerate unknown future fields", arguments: ["server.cjs", "server.mjs"])
    func profileCombination(entry: String) throws {
        let source: [String: Any] = [
            "id": UUID().uuidString, "name": "Проєкт — demo", "engine": "nodeScript",
            "rootPath": "C:\\Projects\\demo", "workingDirectory": "C:\\Projects\\demo",
            "port": 9134, "host": "127.0.0.1", "templateId": "node-api", "needsDatabase": true,
            "profileColor": "#14B8A6", "errorPageAccent": "#EF4444", "nodeEntryFile": entry,
            "enableCors": true, "enableGzip": false, "basicAuthEnabled": true,
            "basicAuthUser": "demo", "basicAuthPassword": "test-only-\"\\пароль",
            "phpVersion": "8.3", "phpMemoryLimit": "768M", "phpUploadMaxFilesize": "256M",
            "phpMaxExecutionTime": 600, "phpDisplayErrors": false, "httpsEnabled": true,
            "certificatePath": "C:\\certs\\local.pem", "privateKeyPath": "C:\\certs\\local.key",
            "customCommand": "node", "customArguments": "--trace-warnings", "extraArguments": "--demo",
            "environment": [["key": "MODE", "value": "демо"], ["key": "EMPTY", "value": ""]],
            "openBrowserOnStart": true, "futureWindowsSetting": ["ignored": true]
        ]
        let profile = try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: source))
        #expect(profile.enableCORS)
        #expect(profile.environment.count == 2, "Missing env IDs must not discard the whole array")
        #expect(Set(profile.environment.map(\.id)).count == 2)
        let exported = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        for (key, expected) in source where !["environment", "futureWindowsSetting"].contains(key) {
            #expect(exported[key] as? NSObject == expected as? NSObject, "Portable field lost: \(key)")
        }
        let env = try #require(exported["environment"] as? [[String: Any]])
        #expect(env.map { $0["key"] as? String } == ["MODE", "EMPTY"])
        #expect(env.map { $0["value"] as? String } == ["демо", ""])
        #expect(exported["enableCORS"] == nil, "Export one canonical Windows-compatible spelling")
    }

    @Test("Old Mac CORS key loads, while canonical Windows spelling wins a conflict")
    func legacyCors() throws {
        for (json, expected) in [(#"{"enableCORS":true}"#, true), (#"{"enableCORS":true,"enableCors":false}"#, false)] {
            let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
            #expect(profile.enableCORS == expected)
            #expect(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile)).enableCORS == expected)
        }
    }

    @Test("Windows single/array templates preserve custom commands, recipes and nested precedence", arguments: [false, true])
    func templateCombination(array: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(storeURL: directory.appendingPathComponent("store/templates.json"))
        let source: [String: Any] = [
            "id": "portable-custom", "title": "Свій сервер", "summary": "Fixture", "category": "custom",
            "nodeEntryFile": "server.mjs", "customCommand": "node", "customArguments": "--trace-warnings server.mjs",
            "needsDatabase": true, "phpVersion": "8.3", "rootHint": "public",
            "questions": ["folder", "command"], "quickSetup": true,
            "packageKind": "wordpress-w2p", "packageSource": "https://wordpress.org/latest.zip",
            "recipeKind": "wordpress-w2p-showcase", "pluginPackages": ["woocommerce", "printcart-integration"],
            "settings": ["engine": "custom", "customArguments": "--nested-wins", "phpMemoryLimit": "768M",
                         "phpUploadMaxFilesize": "256M", "phpMaxExecutionTime": 600, "httpsEnabled": true],
            "futureSetting": 1
        ]
        let input = directory.appendingPathComponent("input.smtemplate")
        try JSONSerialization.data(withJSONObject: array ? [source] as Any : source).write(to: input)
        let imported = try #require(try store.importTemplates(from: input).first)
        #expect(imported.settings.customCommand == "node")
        #expect(imported.settings.customArguments == "--nested-wins")
        #expect(imported.settings.nodeEntryFile == "server.mjs")
        let profile = imported.makeProfile(name: "Test", port: 9090, root: directory.path)
        #expect(profile.customCommand == "node")
        #expect(profile.customArguments == "--nested-wins")
        let output = directory.appendingPathComponent("output.smtemplate")
        try store.export([imported], to: output)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
        let exported = try #require(rows.first)
        for key in ["packageKind", "packageSource", "recipeKind", "pluginPackages", "needsDatabase", "phpVersion", "rootHint", "quickSetup"] {
            #expect(exported[key] as? NSObject == source[key] as? NSObject, "Template metadata lost: \(key)")
        }
        #expect(exported["customCommand"] as? String == "node")
        #expect(exported["customArguments"] as? String == "--nested-wins")
        #expect(exported["nodeEntryFile"] as? String == "server.mjs")
        let reread = try #require(try store.importTemplates(from: output).first)
        #expect(reread.id != imported.id)
        #expect(reread.settings == imported.settings)
        let reloaded = TemplateStore(storeURL: directory.appendingPathComponent("store/templates.json"))
        reloaded.load()
        #expect(reloaded.userTemplates.count == 2)
        #expect(reloaded.userTemplates.first?.settings == imported.settings)
    }

    @Test("A mixed valid/invalid template array never partially imports")
    func atomicTemplateImport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemplateStore(storeURL: directory.appendingPathComponent("store.json"))
        let file = directory.appendingPathComponent("bad.smtemplate")
        try Data(#"[{"id":"valid","title":"Valid","summary":"Fixture","settings":{"engine":"custom"}},{"title":"Missing ID"}]"#.utf8).write(to: file)
        #expect(throws: TemplateStore.TemplateError.self) { try store.importTemplates(from: file) }
        #expect(store.userTemplates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("store.json").path))
    }

    @Test("Windows UTF-8 BOM/CRLF packs preserve escapes, Ukrainian and placeholders")
    func windowsTranslation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("uk.strings")
        let text = #"""
        /* ServerMaster translation pack
           Language: uk
           App version: 2.1.0
           Pack version: 7 */
        "Escaped" = "Рядок\nТаб\tлапки \" і шлях C:\\demo\rкінець";
        "%lld items for %@" = "%lld елементів для %@";
        "Empty" = "";
        "// key /* literal */" = "Значення";
        "Start" = "Запустити";
        "Stop" = "Зупинити";
        """#
        try Data(("\u{FEFF}" + text.replacingOccurrences(of: "\n", with: "\r\n")).utf8).write(to: file)
        let pack = try #require(TranslationStore.read(file))
        #expect(pack.language == "uk")
        #expect(pack.appVersion == "2.1.0")
        #expect(pack.packVersion == "7")
        #expect(pack.strings["Escaped"] == "Рядок\nТаб\tлапки \" і шлях C:\\demo\rкінець")
        #expect(pack.strings["%lld items for %@"] == "%lld елементів для %@")
        #expect(pack.strings["Empty"] == "")
        let encoded = TranslationStore.serialized(pack)
        // Windows ReadQuoted stops at raw newlines and understands these five
        // escapes. Each exported entry must therefore occupy exactly one line.
        let lines = encoded.split(separator: "\n").filter { $0.hasPrefix("\"") }
        #expect(lines.count == pack.strings.count)
        #expect(!lines.contains { $0.contains("\r") || $0.contains("\t") })
        #expect(encoded.contains("\\r") && encoded.contains("\\t"))
        try encoded.write(to: file, atomically: true, encoding: .utf8)
        let back = try #require(TranslationStore.read(file))
        #expect(back.strings == pack.strings)
        #expect(back.packVersion == pack.packVersion)
    }

    @Test("Empty translation metadata uses the same fallbacks as Windows")
    func blankTranslationHeader() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("uk.strings")
        try "/* Language: \n App version: \n Pack version: */\n\"Start\" = \"Запустити\";".write(to: file, atomically: true, encoding: .utf8)
        let pack = try #require(TranslationStore.read(file))
        #expect(pack.language == "uk")
        #expect(pack.packVersion == "1")
        #expect(!pack.appVersion.isEmpty)
    }

    @Test("The real Windows Ukrainian resource loads and reserializes without losing entries")
    func actualWindowsTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("windows/src/ServerMaster.Windows/Resources/uk.windows.strings")
        let original = try String(contentsOf: resource, encoding: .utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("uk.strings")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let pack = try #require(TranslationStore.read(file))
        #expect(pack.language == "uk")
        #expect(pack.strings["Profile icon"] == "Іконка профілю")
        #expect(pack.strings.count > 50)
        try TranslationStore.serialized(pack).write(to: file, atomically: true, encoding: .utf8)
        #expect(TranslationStore.read(file)?.strings == pack.strings)
    }
}
