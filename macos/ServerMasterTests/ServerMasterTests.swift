//
//  ServerMasterTests.swift
//  ServerMasterTests
//
//  These used to live in a scratch folder outside the repository and were lost
//  when the system cleared its temporary files. Anything worth keeping belongs
//  here, where it is version controlled and runs with the project.
//
//  Kept to checks that need nothing but the app itself — no servers, no
//  database, no network — so they stay fast and never fail for reasons that
//  have nothing to do with the code.
//

import Testing
import Foundation
@testable import ServerMaster

// MARK: - Guides

@Suite("Guide links")
struct GuideLinkTests {

    @Test("Every guide points at a real address on the site")
    func addresses() {
        let guides: [AppLinks.Guide] = [.index, .install, .staticSite, .php, .joomla,
                                        .wordpress, .drupal, .laravel, .database,
                                        .phpVersion, .https, .ports, .htaccess, .errors]
        for guide in guides {
            let url = guide.url
            #expect(url.scheme == "https")
            #expect(url.host == "adm1nsys.github.io")
            #expect(url.path.hasSuffix("wiki.html"))
        }
    }

    @Test("The index has no stray anchor, a section carries one")
    func anchors() {
        #expect(!AppLinks.Guide.index.url.absoluteString.hasSuffix("#"))
        #expect(AppLinks.Guide.joomla.url.absoluteString.hasSuffix("#joomla"))
        #expect(AppLinks.Guide.errors.url.absoluteString.hasSuffix("#errors"))
    }

    @Test("The offered guide follows the engine")
    func perEngine() {
        #expect(AppLinks.guide(for: .apache) == .htaccess)
        #expect(AppLinks.guide(for: .apachePHP) == .joomla)
        #expect(AppLinks.guide(for: .phpFpm) == .joomla)
        #expect(AppLinks.guide(for: .httpServer) == .staticSite)
        #expect(AppLinks.guide(for: .pythonHTTP) == .staticSite)
        #expect(AppLinks.guide(for: .phpBuiltIn) == .php)
    }

    @Test("A failed start points at the page explaining that failure")
    func perFailure() {
        #expect(AppLinks.guide(forFailure: "listen EACCES: permission denied 127.0.0.1:443") == .ports)
        #expect(AppLinks.guide(forFailure: "Port 8080 is taken") == .ports)
        #expect(AppLinks.guide(forFailure: "SSL certificate not found") == .https)
        #expect(AppLinks.guide(forFailure: "php-fpm exited unexpectedly") == .php)
        #expect(AppLinks.guide(forFailure: "something nobody predicted") == .errors)
    }

    @Test("Every engine has an answer, including ones added later")
    func everyEngineCovered() {
        for engine in ServerEngine.allCases {
            _ = AppLinks.guide(for: engine)     // must not trap
        }
    }
}

// MARK: - Presets

@Suite("Profile presets")
struct ProfilePresetTests {

    @Test("A preset leaves nothing to fix but the folder")
    func readyToStart() {
        for preset in ProfilePreset.all {
            let profile = preset.makeProfile(name: preset.title, port: 8080)
            // The document root is the one thing the person still chooses.
            let remaining = profile.validationIssues.filter { issue in
                let text = issue.lowercased()
                return !text.contains("folder") && !text.contains("directory") && !text.contains("root")
            }
            #expect(remaining.isEmpty, "\(preset.id): \(remaining.joined(separator: "; "))")
            #expect(!profile.name.isEmpty)
            #expect(profile.port == 8080)
        }
    }

    @Test("Presets are distinct and every one has a guide")
    func distinct() {
        let ids = ProfilePreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ProfilePreset.all.isEmpty)
    }

    @Test("The CMS preset picks an engine that reads .htaccess and raises PHP limits")
    func cms() throws {
        let preset = try #require(ProfilePreset.all.first { $0.id == "cms" })
        let profile = preset.makeProfile(name: "CMS", port: 8080)
        #expect(profile.engine.honoursHtaccess)
        #expect(profile.engine.runsPHP)
        #expect(profile.phpMemoryLimit == "512M")
        #expect(profile.phpMaxExecutionTime >= 300)
    }

    @Test("The single-page preset switches the fallback on, the static one does not")
    func spa() throws {
        let spa = try #require(ProfilePreset.all.first { $0.id == "spa" })
        let plain = try #require(ProfilePreset.all.first { $0.id == "static" })
        #expect(spa.makeProfile(name: "SPA", port: 8080).spaFallback)
        #expect(!plain.makeProfile(name: "Static", port: 8080).spaFallback)
    }
}

// MARK: - Build identifier

@Suite("Build identifier")
struct BuildIdentifierTests {

    @Test("The scheme is read apart into its pieces")
    func scheme() {
        let build = BuildIdentifier("arm.27.0.b6.arm")
        #expect(build.host == "arm")
        #expect(build.system == "27.0")
        #expect(build.beta == 6)
        #expect(build.target == "arm")
        #expect(build.summary?.contains("Apple Silicon") == true)
    }

    @Test("A universal target and a released system read correctly")
    func variants() {
        #expect(BuildIdentifier("arm.27.0.b6.uni").targetName == "Universal")
        let released = BuildIdentifier("arm.26.0.arm")
        #expect(released.beta == nil)
        #expect(released.summary == "macOS 26.0 · Apple Silicon")
    }

    @Test("A plain counter is not mistaken for a version")
    func counter() {
        #expect(BuildIdentifier("1").summary == nil)
        #expect(BuildIdentifier("").summary == nil)
    }
}

// MARK: - Settings and profiles survive an older file

@Suite("Reading files from earlier versions")
struct DecodingTests {

    /// Changing a value in the stored JSON must change the decoded object. When
    /// it does not, the field was forgotten in `init(from:)` — which is how a
    /// whole settings file used to reset itself on upgrade.
    private func coverage<T: Codable & Equatable>(_ type: T.Type, _ sample: T) throws -> [String] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(sample)) as? [String: Any])
        let baseline = try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: json))
        var forgotten: [String] = []

        // Fields with a fixed set of values need a valid alternative, or the
        // tolerant decoder rightly falls back and the check reads as a failure.
        let alternatives: [String: Any] = [
            "engine": "caddy",
            "terminalApp": "iTerm",
            "defaultKillSignal": "KILL",
            "language": "de",
            "databaseAdminTool": "phpMyAdmin",
            "lastUpdateCheck": "2020-01-01T00:00:00Z"
        ]

        for (key, value) in json {
            var other: Any
            if let fixed = alternatives[key] {
                other = fixed
            } else if key == "id" {
                other = UUID().uuidString
            } else if let text = value as? String {
                other = text == "changed" ? "other" : "changed"
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { other = !number.boolValue }
                else if let int = number as? Int { other = int == 4242 ? 777 : 4242 }
                else { other = 4242.5 }
            } else {
                continue                        // arrays and dictionaries are covered elsewhere
            }

            var modified = json
            modified[key] = other
            let data = try JSONSerialization.data(withJSONObject: modified)
            guard let decoded = try? decoder.decode(T.self, from: data) else {
                forgotten.append("\(key) (does not decode)")
                continue
            }
            if decoded == baseline { forgotten.append(key) }
        }
        return forgotten
    }

    @Test("Every settings field is actually read")
    func settings() throws {
        let forgotten = try coverage(AppSettings.self, AppSettings())
        #expect(forgotten.isEmpty, "forgotten in init(from:): \(forgotten.joined(separator: ", "))")
    }

    @Test("Every profile field is actually read")
    func profiles() throws {
        let forgotten = try coverage(ServerProfile.self, ServerProfile())
        #expect(forgotten.isEmpty, "forgotten in init(from:): \(forgotten.joined(separator: ", "))")
    }

    @Test("A file written before a field existed still loads")
    func olderFile() throws {
        let old = #"{"name":"From 1.0","engine":"nginx","port":8443}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(old.utf8))
        #expect(profile.name == "From 1.0")
        #expect(profile.port == 8443)
        #expect(profile.engine == .nginx)
        // Everything absent falls back rather than throwing.
        #expect(profile.phpVersion == ServerProfile().phpVersion)
    }

    @Test("An unknown value falls back instead of losing the file")
    func unknownValue() throws {
        let json = #"{"databaseAdminTool":"nonsense","databaseAdminPort":9999}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.databaseAdminTool == AppSettings().databaseAdminTool)
        #expect(settings.databaseAdminPort == 9999)
    }

    @Test("Release tags use the full three-part version")
    func releaseTagVersion() {
        #expect(UpdateChecker.releaseTagVersion("1.2") == "1.2.0")
        #expect(UpdateChecker.releaseTagVersion("2.0.0") == "2.0.0")
        #expect(UpdateChecker.releaseTagVersion("v1.1") == "1.1.0")
    }
}

// MARK: - Engines

@Suite("Engines")
struct EngineTests {

    @Test("Only Apache claims to read .htaccess")
    func htaccess() {
        for engine in ServerEngine.allCases {
            let expected = (engine == .apache || engine == .apachePHP)
            #expect(engine.honoursHtaccess == expected, "\(engine.rawValue)")
        }
    }

    @Test("An engine that cannot deny dotfiles does not claim it can")
    func dotfiles() {
        // http-server only hides them from the listing; a direct request still
        // returns the file. The UI relies on this being honest.
        #expect(ServerEngine.httpServer.hidesDotfilesFromListing)
        #expect(!ServerEngine.httpServer.blocksDotfileAccess)
        #expect(ServerEngine.nginx.blocksDotfileAccess)
        #expect(ServerEngine.apache.blocksDotfileAccess)
    }

    @Test("Every engine has a title, a subtitle and a symbol")
    func presentable() {
        for engine in ServerEngine.allCases {
            #expect(!engine.title.isEmpty)
            #expect(!engine.subtitle.isEmpty)
            #expect(!engine.symbol.isEmpty)
        }
    }
}
