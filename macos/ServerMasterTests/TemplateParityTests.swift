import Foundation
import Testing
@testable import ServerMaster

/// Reads the checked-out Windows catalogue so a later edit on either platform
/// cannot silently invalidate a hand-maintained snapshot of expected defaults.
@Suite("Windows/macOS built-in template parameters")
struct TemplateParityTests {
    private func captures(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern)
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<match.numberOfRanges).map {
                let range = match.range(at: $0)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    private func literal(_ value: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
    }

    private func windows() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("windows/src/ServerMaster.Windows/Models/ProfileTemplate.cs")
        let source = try String(contentsOf: path, encoding: .utf8)
        let split = try #require(source.range(of: "public static IReadOnlyList<ProfileTemplate> BuiltIn"))
        let declaration = String(source[..<split.lowerBound])
        var defaults: [String: Any] = [:]
        // Restrict the parser to literal initializer fields, failing rather than
        // guessing if the Windows catalogue begins using computed expressions.
        for field in try captures(#"public (?:string|bool|int|string\[\]) (\w+) \{ get; init; \}(?: = ([^;]+);)?"#, in: declaration) {
            if !field[1].isEmpty { defaults[field[0]] = try literal(field[1]) }
        }
        let catalogue = String(source[split.lowerBound...])
        let blocks = try captures(#"new ProfileTemplate\s*\{((?:"(?:\\.|[^"\\])*"|[^{}"])*)\}"#, in: catalogue)
        var result: [[String: Any]] = []
        for block in blocks {
            var fields = defaults
            for field in try captures(#"\b(\w+)\s*=\s*("(?:\\.|[^"\\])*"|true|false|-?\d+|\[[^\]]*\])\s*(?:,|$)"#, in: block[0]) {
                fields[field[0]] = try literal(field[1])
            }
            _ = try #require(fields["Id"] as? String)
            result.append(fields)
        }
        #expect(result.count == 25, "Review new Windows template IDs/default rules when the catalogue changes")
        return result
    }

    @Test("All shared IDs keep their scalar defaults, package metadata and root hints")
    func catalogueParameters() throws {
        let cms: Set<String> = ["joomla5", "joomla6", "wordpress", "drupal", "typo3", "prestashop", "moodle", "mediawiki", "phpbb", "web-to-print-store", "web-to-print-showcase"]
        let nativePHP = cms.union(["laravel", "symfony", "php-plain", "php-htaccess"])
        let local = Dictionary(uniqueKeysWithValues: ProfileTemplate.builtIn.map { ($0.id, $0) })
        let shared = try windows()
        let ids = try shared.map { try #require($0["Id"] as? String) }
        #expect(Set(local.keys).subtracting(ids) == ["nginx", "caddy"])

        for windows in shared {
            let id = try #require(windows["Id"] as? String)
            let template = try #require(local[id], "Missing shared template \(id)")
            let profile = template.makeProfile(name: "Parity", port: 8080, root: "/tmp/parity")
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
            let fields = ["IndexFile": "indexFile", "DirectoryListing": "directoryListing", "SpaFallback": "spaFallback", "HideDotfiles": "hideDotfiles", "EnableCors": "enableCors", "EnableGzip": "enableGzip", "OpenBrowserOnStart": "openBrowserOnStart", "CacheSeconds": "cacheSeconds", "NodeEntryFile": "nodeEntryFile", "CustomCommand": "customCommand", "CustomArguments": "customArguments"]
            for (key, localKey) in fields {
                let expected = windows[key] ?? (["SpaFallback", "EnableCors"].contains(key) ? false as Any : "")
                let actual = try #require(object[localKey] as? NSObject, "Missing \(id).\(localKey)")
                let reference = try #require(expected as? NSObject)
                #expect(actual == reference, "\(id).\(key): \(actual) != \(reference)")
            }
            #expect((template.rootHint ?? "") == (windows["RootHint"] as? String ?? ""), "\(id).RootHint")
            #expect(template.needsDatabase == (windows["NeedsDatabase"] as? Bool ?? false), "\(id).NeedsDatabase")
            #expect(template.packageKind == (windows["PackageKind"] as? String ?? ""), "\(id).PackageKind")
            #expect(template.packageSource == (windows["PackageSource"] as? String ?? ""), "\(id).PackageSource")
            #expect(template.recipeKind == (windows["RecipeKind"] as? String ?? ""), "\(id).RecipeKind")
            #expect(template.pluginPackages == (windows["PluginPackages"] as? [String] ?? []), "\(id).PluginPackages")
            #expect(template.quickSetup == (windows["QuickSetup"] as? Bool ?? false), "\(id).QuickSetup")
            #expect(profile.httpsEnabled == (id == "static-https"), "\(id).HTTPS")

            let expectedEngine: String
            if nativePHP.contains(id) {
                expectedEngine = cms.contains(id) || id == "php-htaccess" ? "apachePHP" : "phpFpm"
                #expect(windows["Engine"] as? String == "phpBuiltIn")
            } else {
                expectedEngine = try #require(windows["Engine"] as? String)
            }
            #expect(profile.engine.rawValue == expectedEngine, "\(id).Engine (native PHP adapter)")
            if profile.engine.runsPHP {
                let version = windows["PhpVersion"] as? String ?? ""
                #expect(profile.phpVersion == (version.isEmpty ? "8.3" : version), "\(id).PHP")
            }

            // Preserve the existing, more generous native CMS limits instead
            // of reducing them to Windows defaults as a side effect of parity.
            var memory = windows["PhpMemoryLimit"] as? String ?? "256M"
            if cms.contains(id) { memory = "512M" }
            if ["typo3", "moodle"].contains(id) { memory = "768M" }
            var upload = windows["PhpUploadMaxFilesize"] as? String ?? "64M"
            if cms.contains(id) { upload = "128M" }
            if id == "prestashop" { upload = "256M" }
            let seconds = ["prestashop", "moodle"].contains(id) ? 600 : (windows["PhpMaxExecutionTime"] as? Int ?? 300)
            #expect(profile.phpMemoryLimit == memory, "\(id).memory")
            #expect(profile.phpUploadMaxFilesize == upload, "\(id).upload")
            #expect(profile.phpMaxExecutionTime == seconds, "\(id).timeout")
            #expect(profile.securityHeaders == (nativePHP.contains(id) || id == "php"), "\(id).native security headers")
            #expect(profile.customErrorPages == cms.contains(id), "\(id).native error pages")
            if template.packageKind == "wordpress-w2p" {
                #expect(profile.databaseName == "servermaster_w2p_8080")
            }
            if id == "printshopcrm" {
                #expect(profile.workingDirectory == "/tmp/parity")
                #expect(profile.environmentDictionary["PSC_HOST"] == "127.0.0.1")
                #expect(profile.environmentDictionary["PSC_AUTH"] == "0")
            }
        }
    }

    @Test("Quick setup uses its defaults and WordPress offers the official download")
    func wizardDefaults() throws {
        let showcase = try #require(ProfileTemplate.builtIn.first { $0.id == "web-to-print-showcase" })
        #expect(showcase.setupQuestions == [.folder])
        for template in ProfileTemplate.builtIn where !template.quickSetup {
            #expect(template.setupQuestions == template.questions)
        }
        let wordpress = try #require(DownloadableProject.forTemplate("wordpress"))
        #expect(wordpress.title == "WordPress")
        #expect(wordpress.directArchiveURL?.absoluteString == "https://wordpress.org/latest.zip")
    }
}
