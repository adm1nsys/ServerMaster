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
import AppKit
import SwiftUI
import Foundation
import CryptoKit
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
        // Compared against the parsed field, not the display name. The display
        // name goes through String(localized:) and changes with the interface
        // language — this assertion was written when English was the only one,
        // and it started failing the day Ukrainian was added.
        #expect(BuildIdentifier("arm.27.0.b6.uni").target == "uni")
        #expect(BuildIdentifier("arm.27.0.b6.uni").targetName == String(localized: "Universal"))

        let released = BuildIdentifier("arm.26.0.arm")
        #expect(released.beta == nil)
        #expect(released.system == "26.0")
        #expect(released.target == "arm")
        // The shape of the summary, without depending on the words in it.
        let summary = try? #require(released.summary)
        #expect(summary?.contains("26.0") == true)
        #expect(summary?.contains("·") == true)
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
            "lastUpdateCheck": "2020-01-01T00:00:00Z",
            "backupUnit": "hours",
            "sidebarStyle": "modern",
            "lastBackup": "2020-01-01T00:00:00Z"
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

// MARK: - Templates

@Suite("Profile templates")
struct ProfileTemplateTests {

    @Test("Every built-in template produces a profile with nothing left but the folder")
    func usable() {
        for template in ProfileTemplate.builtIn {
            let profile = template.makeProfile(name: template.title, port: 8080,
                                               root: NSTemporaryDirectory())
            let remaining = profile.validationIssues.filter { issue in
                let text = issue.lowercased()
                // The wizard asks for these separately; a bare template cannot
                // know a command or an entry file.
                return !text.contains("command") && !text.contains("entry")
            }
            #expect(remaining.isEmpty, "\(template.id): \(remaining.joined(separator: "; "))")
        }
    }

    @Test("Identifiers are unique and every template is presentable")
    func catalogue() {
        let ids = ProfileTemplate.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        for template in ProfileTemplate.builtIn {
            #expect(!template.title.isEmpty)
            #expect(!template.summary.isEmpty)
            #expect(!template.symbol.isEmpty)
            #expect(template.questions.contains(.folder), "\(template.id) never asks for a folder")
        }
    }

    @Test("A template that needs a database says so, and asks about it")
    func databases() {
        for template in ProfileTemplate.builtIn where template.needsDatabase {
            #expect(template.questions.contains(.database), "\(template.id)")
        }
        // The CMS templates are the reason this feature exists.
        let joomla = ProfileTemplate.builtIn.first { $0.id == "joomla5" }
        #expect(joomla?.needsDatabase == true)
        #expect(joomla?.settings.engine.honoursHtaccess == true)
    }

    @Test("Joomla 5 and 6 differ where they actually differ")
    func joomlaVersions() throws {
        let five = try #require(ProfileTemplate.builtIn.first { $0.id == "joomla5" })
        let six = try #require(ProfileTemplate.builtIn.first { $0.id == "joomla6" })
        #expect(five.phpVersion != six.phpVersion)
        #expect(five.makeProfile(name: "a", port: 1, root: "/tmp").phpVersion == five.phpVersion)
    }

    @Test("Templates that serve a subfolder say which one")
    func rootHints() throws {
        let laravel = try #require(ProfileTemplate.builtIn.first { $0.id == "laravel" })
        #expect(laravel.rootHint == "public")
        let drupal = try #require(ProfileTemplate.builtIn.first { $0.id == "drupal" })
        #expect(drupal.rootHint == "web")
    }

    @Test("A profile can be turned into a template and back")
    func roundTrip() {
        var profile = ServerProfile()
        profile.engine = .apachePHP
        profile.phpMemoryLimit = "768M"
        profile.spaFallback = true
        profile.rootPath = "/Users/somebody/private/project"

        let template = ProfileTemplate.from(profile: profile, title: "Mine", summary: "Test")
        let rebuilt = template.makeProfile(name: "Rebuilt", port: 9000, root: "/tmp")

        #expect(rebuilt.engine == .apachePHP)
        #expect(rebuilt.phpMemoryLimit == "768M")
        #expect(rebuilt.spaFallback)
        // A template must never carry someone's folder to another machine.
        #expect(rebuilt.rootPath == "/tmp")
    }
}

@Suite("Template files")
struct TemplateStoreTests {

    @Test("Exported templates come back unchanged")
    func exportImport() throws {
        let store = TemplateStore()
        let source = try #require(ProfileTemplate.builtIn.first { $0.id == "wordpress" })
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-test-\(UUID().uuidString).smtemplate")
        defer { try? FileManager.default.removeItem(at: url) }

        try store.export([source], to: url)
        let imported = try store.importTemplates(from: url)

        #expect(imported.count == 1)
        let copy = try #require(imported.first)
        #expect(copy.title == source.title)
        #expect(copy.settings == source.settings)
        #expect(copy.isUserDefined, "an imported template belongs to the user")
    }

    @Test("A file that is not a template is refused, not half-read")
    func rubbish() throws {
        let store = TemplateStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"hello":"world"}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: TemplateStore.TemplateError.self) {
            try store.importTemplates(from: url)
        }
        #expect(store.userTemplates.isEmpty)
    }

    @Test("Importing the same template twice does not collide")
    func duplicates() throws {
        let store = TemplateStore()
        let source = try #require(ProfileTemplate.builtIn.first { $0.id == "laravel" })
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-test-\(UUID().uuidString).smtemplate")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.export([source], to: url)

        _ = try store.importTemplates(from: url)
        _ = try store.importTemplates(from: url)

        let ids = store.all.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
    }
}

// MARK: - What the widget reads

@Suite("Status snapshot")
struct StatusSnapshotTests {

    /// The widget extension carries its own copy of these types, because an
    /// extension cannot share code with its host without project surgery. This
    /// pins the JSON so the two cannot drift apart without a test failing.
    @Test("The file keeps the shape the widget expects")
    func contract() throws {
        let snapshot = StatusSnapshot(
            updated: Date(timeIntervalSince1970: 1_700_000_000),
            profiles: [.init(id: "abc", name: "Site", address: "http://127.0.0.1:8080",
                             state: "running", detail: nil)],
            databaseRunning: true,
            adminPanelAddress: "http://127.0.0.1:8036/")

        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["updated"] != nil)
        #expect(json["databaseRunning"] as? Bool == true)
        #expect(json["adminPanelAddress"] as? String == "http://127.0.0.1:8036/")

        let profiles = try #require(json["profiles"] as? [[String: Any]])
        let first = try #require(profiles.first)
        for key in ["id", "name", "address", "state"] {
            #expect(first[key] != nil, "the widget reads “\(key)” and it is missing")
        }
    }

    @Test("Only the four state names the widget can colour are ever written")
    func states() {
        // The widget colours by string. An unknown value would show as grey with
        // no hint that anything is wrong.
        let allowed: Set<String> = ["running", "starting", "stopped", "failed"]
        for state in [ServerState.running, .starting, .stopping, .stopped, .failed("x")] {
            let name: String
            switch state {
            case .running:  name = "running"
            case .starting, .stopping: name = "starting"
            case .failed:   name = "failed"
            case .stopped:  name = "stopped"
            }
            #expect(allowed.contains(name))
        }
    }

    @Test("A missing or broken file reads as empty rather than crashing")
    func missing() throws {
        let decoded = try? JSONDecoder().decode(StatusSnapshot.self, from: Data("not json".utf8))
        #expect(decoded == nil)
        #expect(StatusSnapshot.empty.profiles.isEmpty)
    }

    @Test("The snapshot carries nothing private")
    func nothingPrivate() throws {
        var profile = ServerProfile()
        profile.name = "Site"
        profile.rootPath = "/Users/somebody/secret-project"
        profile.certificatePath = "/Users/somebody/cert.pem"

        let entry = StatusSnapshot.Entry(id: profile.id.uuidString, name: profile.name,
                                         address: profile.address, state: "running", detail: nil)
        let text = String(data: try JSONEncoder().encode(entry), encoding: .utf8) ?? ""
        #expect(!text.contains("secret-project"))
        #expect(!text.contains("cert.pem"))
    }
}

// MARK: - Downloading a project

@Suite("Download integrity")
struct ProjectDownloadTests {

    private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-dl-\(UUID().uuidString).zip")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("A file that does not match its checksum is rejected")
    func mismatch() throws {
        let downloader = ProjectDownloader()
        let file = try temporaryFile([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: file) }

        // The digest of something else entirely.
        let wrong = String(repeating: "ab", count: 32)
        #expect(throws: ProjectDownloader.DownloadError.self) {
            try downloader.verify(file, against: wrong)
        }
    }

    @Test("A file that matches its checksum is accepted")
    func match() throws {
        let downloader = ProjectDownloader()
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x0a, 0x0b, 0x0c]
        let file = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: file) }

        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        try downloader.verify(file, against: digest)          // must not throw
        try downloader.verify(file, against: digest.uppercased())
    }

    @Test("Without a published checksum, at least the format is checked")
    func noDigest() throws {
        let downloader = ProjectDownloader()
        let zip = try temporaryFile([0x50, 0x4B, 0x03, 0x04, 0x00])
        let notAZip = try temporaryFile([0x00, 0x01, 0x02, 0x03])
        defer {
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.removeItem(at: notAZip)
        }

        try downloader.verify(zip, against: nil)               // starts with PK
        #expect(throws: ProjectDownloader.DownloadError.self) {
            try downloader.verify(notAZip, against: nil)
        }
    }

    @Test("Only the templates that have a source offer a download")
    func sources() {
        #expect(DownloadableProject.forTemplate("joomla5") != nil)
        #expect(DownloadableProject.forTemplate("joomla6") != nil)
        #expect(DownloadableProject.forTemplate("wordpress") == nil)
        #expect(DownloadableProject.forTemplate("static") == nil)
    }
}

// MARK: - Which Apache, and where the site may live

@Suite("Apache installation")
struct ApacheInstallationTests {

    @Test("Homebrew's copy is preferred over the one macOS ships")
    func preference() throws {
        let installation = try #require(ApacheInstallation.resolve())
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/opt/httpd/bin/httpd") {
            #expect(!installation.isSystemCopy,
                    "the system copy cannot read privacy-protected folders")
            #expect(installation.binary.contains("homebrew"))
        }
        // Binary, modules and ServerRoot must come from the same installation:
        // mixing them loads the wrong modules and Apache refuses to start.
        if installation.isSystemCopy {
            #expect(installation.modulesDirectory == "/usr/libexec/apache2")
            #expect(installation.serverRoot == "/usr")
        } else {
            #expect(installation.modulesDirectory.contains("httpd"))
            #expect(!installation.modulesDirectory.hasPrefix("/usr/libexec"))
        }
    }

    @Test("The folders macOS protects are recognised")
    func protectedFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ApacheInstallation.isProtected(home + "/Documents/site"))
        #expect(ApacheInstallation.isProtected(home + "/Desktop"))
        #expect(ApacheInstallation.isProtected(home + "/Downloads/joomla"))
        #expect(!ApacheInstallation.isProtected(home + "/Sites"))
        #expect(!ApacheInstallation.isProtected("/tmp/site"))
        // A folder that merely starts with the same letters is not inside it.
        #expect(!ApacheInstallation.isProtected(home + "/DocumentsOld"))
    }

    @Test("A protected folder warns only when the system Apache would be used")
    func warning() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let warning = ApacheInstallation.privacyWarning(forRoot: home + "/Documents/site")
        if ApacheInstallation.homebrewAvailable {
            #expect(warning == nil, "Homebrew's Apache reads these folders fine")
        } else {
            #expect(warning != nil, "the failure is a 403 on every asset — say so first")
        }
        #expect(ApacheInstallation.privacyWarning(forRoot: "/tmp/site") == nil)
    }

    @Test("The warning reaches the profile's own list of problems")
    func surfaced() {
        var profile = ServerProfile()
        profile.engine = .apachePHP
        profile.rootPath = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/site"
        let issues = profile.validationIssues
        if ApacheInstallation.homebrewAvailable {
            #expect(!issues.contains { $0.contains("privacy-protected") })
        } else {
            #expect(issues.contains { $0.contains("privacy-protected") })
        }
    }
}

@Suite("PHP versions")
struct PHPVersionTests {

    @Test("Only versions Homebrew offers can be installed")
    func known() {
        #expect(PHPVersions.known.contains("8.3"))
        #expect(!PHPVersions.known.contains("5.6"))
        for version in PHPVersions.known {
            #expect(version.contains("."), "\(version) does not look like a version")
        }
    }

    @Test("Scanning reports each version once, with a usable binary")
    func scan() {
        let found = PHPVersions.scan()
        let versions = found.map(\.version)
        #expect(Set(versions).count == versions.count)
        for installed in found {
            #expect(FileManager.default.isExecutableFile(atPath: installed.binary),
                    "\(installed.binary)")
        }
    }
}

// MARK: - Certificates the browser accepts

@Suite("Certificate trust")
struct CertificateTrustTests {

    private func pair(issuer: String?) -> CertificatePair {
        CertificatePair(name: "test",
                        certificatePath: "/tmp/test.crt.pem",
                        privateKeyPath: "/tmp/test.key.pem",
                        subject: "CN=localhost",
                        issuer: issuer,
                        notAfter: Date().addingTimeInterval(86_400),
                        domains: ["localhost"])
    }

    @Test("Who signed it is what decides whether the browser complains")
    func issuer() {
        #expect(pair(issuer: "CN=mkcert somebody@mac, O=mkcert development CA").isFromMkcert)
        #expect(!pair(issuer: "CN=localhost, O=ServerMaster").isFromMkcert)
        #expect(!pair(issuer: nil).isFromMkcert)
    }

    @Test("Being signed by mkcert is not enough on its own")
    func authorityAlsoNeeded() async {
        let manager = CertificateManager()
        let signed = pair(issuer: "CN=mkcert dev, O=mkcert development CA")

        await manager.refreshMkcertStatus()
        // Trust needs both halves: the right issuer and its authority in the
        // keychain. Claiming trust with only the first would be a lie the user
        // discovers in the browser.
        if !manager.mkcert.trustedInSystem {
            #expect(!manager.isTrusted(signed))
        }
        #expect(!manager.isTrusted(pair(issuer: "CN=localhost, O=ServerMaster")))
    }

    @Test("The status explains which of the two steps is missing")
    func summaries() {
        var status = MkcertStatus()
        #expect(status.summary.contains("not installed"))

        status.available = true
        #expect(status.summary.contains("does not exist"))

        status.caExists = true
        #expect(status.summary.contains("not in the system keychain"))

        status.trustedInSystem = true
        #expect(status.summary.contains("trusted"))
    }
}

// MARK: - Staged releases

@Suite("Feature gates")
struct FeatureGateTests {

    @Test("Version comparison gets the case string sorting gets wrong")
    func versions() {
        // "1.10" sorts before "1.9" as text, which would release a feature early.
        #expect(Features.compare("1.10", "1.9") > 0)
        #expect(Features.compare("1.9", "1.10") < 0)
        #expect(Features.compare("1.3", "1.3") == 0)
        #expect(Features.compare("2.0", "1.99") > 0)
        #expect(Features.compare("1.4.1", "1.4") > 0)
        // Something unreadable must not open a gate by accident.
        #expect(Features.compare("", "1.4") < 0)
        #expect(Features.compare("beta", "1.4") < 0)
    }

    @Test("Every gate names a version that can be read")
    func thresholds() {
        for feature in Feature.allCases {
            #expect(feature.availableFrom.contains("."), "\(feature.rawValue)")
            #expect(!feature.title.isEmpty)
            // The note is what stops a gate becoming “hidden because nobody
            // remembers why”, so it has to say something.
            #expect(feature.settlingNote.count > 20, "\(feature.rawValue)")
        }
    }

    @Test("A local switch shows a feature without releasing it")
    func override() {
        let feature = Feature.desktopWidgets
        let wasOn = Features.overrides.contains(feature.rawValue)
        let wasDev = Features.developerMode
        defer {
            Features.setOverride(feature, on: wasOn)
            Features.developerMode = wasDev
        }

        Features.developerMode = true
        Features.setOverride(feature, on: false)
        #expect(Features.isOn(feature) == Features.isReleased(feature))
        #expect(!Features.isEarly(feature))

        Features.setOverride(feature, on: true)
        #expect(Features.isOn(feature))
        // Switching it on here must not make it released for anyone else.
        if !Features.isReleased(feature) {
            #expect(Features.isEarly(feature))
        }

        // One switch returns the app to what everyone else sees, without having
        // to remember which gates were opened.
        Features.developerMode = false
        #expect(Features.isOn(feature) == Features.isReleased(feature))
        #expect(!Features.isEarly(feature))
    }

    @Test("A section disappears with the feature it belongs to")
    func sections() {
        let visible = SidebarSection.visible
        #expect(visible.contains(.control))
        #expect(visible.contains(.profiles))
        #expect(visible.contains(.commandLine) == Features.isOn(.commandLineTool))
    }
}

@Suite("Renaming to a dotted name")
struct DottedNameTests {

    @Test("The files projects ship with a suffix are recognised")
    func recognised() {
        #expect(SiteFilesView.dottedName(for: "htaccess.txt") == ".htaccess")
        #expect(SiteFilesView.dottedName(for: "HTACCESS.TXT") == ".htaccess")
        #expect(SiteFilesView.dottedName(for: "htaccess.dist") == ".htaccess")
        #expect(SiteFilesView.dottedName(for: "env.example") == ".env")
        #expect(SiteFilesView.dottedName(for: "dot.env") == ".env")
        #expect(SiteFilesView.dottedName(for: "gitignore") == ".gitignore")
    }

    @Test("Ordinary files are left alone")
    func leftAlone() {
        // “env” on its own is a real command name and a real folder name; it is
        // deliberately not treated as a stand-in for .env.
        #expect(SiteFilesView.dottedName(for: "env") == nil)
        #expect(SiteFilesView.dottedName(for: "index.php") == nil)
        #expect(SiteFilesView.dottedName(for: ".htaccess") == nil)
        #expect(SiteFilesView.dottedName(for: "readme.txt") == nil)
    }
}

@Suite("Config presets")
struct ConfigPresetTests {

    @Test("Only presets an engine can honour are offered")
    func perEngine() {
        let nginx = ConfigPreset.available(for: .nginx).map(\.id)
        #expect(nginx.contains("cms"))
        #expect(nginx.contains("hardened"))
        // A plain Python server rewrites nothing.
        #expect(ConfigPreset.available(for: .pythonHTTP).map(\.id) == ["standard"])
    }

    @Test("An unknown preset falls back rather than throwing")
    func unknown() {
        #expect(ConfigPreset.named("nonsense", for: .nginx).id == "standard")
    }

    @Test("Choosing a preset sets the switches it implies")
    func applied() {
        var profile = ServerProfile()
        profile.indexFile = "index.html"
        ConfigPreset.named("cms", for: .nginx).apply(to: &profile)
        #expect(profile.indexFile == "index.php")
        #expect(profile.directoryListing == false)

        var spa = ServerProfile()
        ConfigPreset.named("spa", for: .nginx).apply(to: &spa)
        #expect(spa.spaFallback)
    }

    @Test("The preset reaches the generated config")
    func generated() {
        var profile = ServerProfile()
        profile.engine = .nginx
        profile.configPreset = "cms"
        profile.indexFile = "index.php"
        let config = ConfigTemplates.nginx(for: profile, prefix: "/tmp/x")
        #expect(config.contains("try_files $uri $uri/ /index.php?$query_string"))
    }
}

@Suite("The sidebar shows every section")
struct SidebarTests {

    /// This is the test the last release needed and did not have. Backups,
    /// Diagnostics and Files were all added to the enum, given a title, an icon
    /// and a screen — and left out of the hand-written list of rows in the view,
    /// so none of them could be reached.
    @Test("Every visible section lands in a group")
    func nothingUnreachable() {
        let grouped = SidebarSection.Group.allCases
            .flatMap { SidebarSection.visible(in: $0) }
        let missing = Set(SidebarSection.visible).subtracting(grouped).map(\.rawValue).sorted()
        #expect(missing.isEmpty, "sections missing from the sidebar: \(missing.joined(separator: ", "))")
    }

    @Test("No section is listed twice")
    func noDuplicates() {
        let grouped = SidebarSection.Group.allCases
            .flatMap { SidebarSection.visible(in: $0) }
        #expect(grouped.count == Set(grouped).count)
    }

    @Test("Every section has a title and an icon")
    func labelled() {
        for section in SidebarSection.allCases {
            #expect(!section.title.isEmpty, "no title: \(section.rawValue)")
            #expect(!section.symbol.isEmpty, "no icon: \(section.rawValue)")
        }
    }
}

@Suite("Snapshot index")
struct SnapshotIndexTests {

    /// An index written before database snapshots existed has no `kind` and a
    /// non-optional `profileID`. It has to keep loading, or someone's backups
    /// vanish from the list the moment they update.
    @Test("An index from the previous version still reads")
    func olderIndex() throws {
        let old = #"""
        [{"id":"site-2026-01-01-120000","profileID":"4E7F1F0B-1111-2222-3333-444455556666",
          "profileName":"Joomla","taken":"2026-01-01T12:00:00Z","trigger":"manual",
          "includesSite":true,"includesDatabase":false,"bytes":2048}]
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode([Snapshot].self, from: Data(old.utf8))
        let first = try #require(list.first)
        #expect(first.kind == .profile)
        #expect(first.profileName == "Joomla")
        #expect(first.includesSite)
    }

    @Test("A database snapshot belongs to no profile")
    func databaseKind() throws {
        let snapshot = Snapshot(id: "db-x-1", kind: .database, profileID: nil,
                                profileName: "joomla5", taken: Date(), trigger: .manual,
                                includesSite: false, includesDatabase: true,
                                databaseName: "joomla5", bytes: 10)
        let encoded = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(Snapshot.self, from: encoded)
        #expect(back.kind == .database)
        #expect(back.profileID == nil)
        #expect(back.databaseName == "joomla5")
    }
}

@Suite("Waiting messages")
struct WaitingTests {

    @Test("The line changes as the wait goes on")
    func escalates() {
        let quick = Waiting.line(for: .snapshot, elapsed: 1)
        let later = Waiting.line(for: .snapshot, elapsed: 20)
        let ages = Waiting.line(for: .snapshot, elapsed: 120)
        #expect(quick != later)
        #expect(later != ages)
    }

    @Test("Every job has a line at every length of wait")
    func complete() {
        for job in [Waiting.Job.snapshot, .restore, .download, .database] {
            for seconds in [0.0, 15, 30, 45, 600, 86_400] {
                #expect(!Waiting.line(for: job, elapsed: seconds).isEmpty)
            }
        }
    }

    /// The bands are indexes into fixed arrays, so a wait longer than the last
    /// band must clamp rather than run off the end.
    @Test("A very long wait does not run past the last line")
    func clamped() {
        let last = Waiting.line(for: .restore, elapsed: 45)
        #expect(Waiting.line(for: .restore, elapsed: 999_999) == last)
    }
}

@Suite("Diagnostics does not cry wolf")
struct DiagnosticsPrecisionTests {

    /// The Apache warning is about the copy macOS ships, which cannot read
    /// privacy-protected folders. A Homebrew httpd can, and warning about it
    /// anyway is how a diagnostic screen stops being read.
    @Test("A protected folder alone is not a warning")
    func onlySystemApache() {
        let documents = NSHomeDirectory() + "/Documents/WEB/Site"
        #expect(ApacheInstallation.isProtected(documents))

        // The warning is only produced when the resolved Apache is the system
        // one. On a machine with Homebrew httpd there is nothing to say.
        let warning = ApacheInstallation.privacyWarning(forRoot: documents)
        let resolved = ApacheInstallation.resolve()
        if resolved?.isSystemCopy == true {
            #expect(warning != nil)
        } else {
            #expect(warning == nil)
        }
    }

    @Test("Folders outside the protected ones never warn")
    func plainFolder() {
        #expect(!ApacheInstallation.isProtected(NSHomeDirectory() + "/Sites/mine"))
        #expect(ApacheInstallation.privacyWarning(forRoot: NSHomeDirectory() + "/Sites/mine") == nil)
    }
}

@Suite("Schema statements")
struct SchemaTests {

    @Test("A column becomes a definition")
    func definition() throws {
        var draft = ColumnDraft(name: "title", type: "VARCHAR(255)", isNullable: false)
        #expect(try #require(draft.definition()) == "`title` VARCHAR(255) NOT NULL")

        draft.isAutoIncrement = true
        draft.isPrimaryKey = true
        draft.name = "id"
        draft.type = "INT"
        let auto = try #require(draft.definition())
        #expect(auto.contains("AUTO_INCREMENT"))
        // An auto-increment column cannot be NULL whatever the switch says.
        #expect(auto.contains("NOT NULL"))
    }

    /// A name is quoted, never filtered — a table called `order` is legal, and
    /// stripping characters would produce a statement about something else.
    @Test("Names with reserved words and backticks survive")
    func quoting() throws {
        let reserved = ColumnDraft(name: "order", type: "INT")
        #expect(try #require(reserved.definition()).hasPrefix("`order`"))

        let awkward = ColumnDraft(name: "we`ird", type: "TEXT")
        #expect(try #require(awkward.definition()).hasPrefix("`we``ird`"))
    }

    @Test("A column with no name produces nothing")
    func refused() {
        #expect(ColumnDraft(name: "", type: "INT").definition() == nil)
        #expect(ColumnDraft(name: "ok", type: "  ").definition() == nil)
    }

    /// Quoting CURRENT_TIMESTAMP turns a timestamp column into one holding that
    /// word, which is the kind of thing nobody notices for a week.
    @Test("Expressions are not quoted, values are")
    func defaults() {
        #expect(ColumnDraft.quotedDefault("CURRENT_TIMESTAMP") == "CURRENT_TIMESTAMP")
        #expect(ColumnDraft.quotedDefault("now()") == "NOW()")
        #expect(ColumnDraft.quotedDefault("NULL") == "NULL")
        #expect(ColumnDraft.quotedDefault("42") == "42")
        #expect(ColumnDraft.quotedDefault("hello") == "'hello'")
        #expect(ColumnDraft.quotedDefault("it's") == "'it''s'")
    }
}

@Suite("Ambient background")
struct AmbientTests {

    /// A profile's accent is where the colour comes from. A malformed one has
    /// to be dropped rather than crash or render black.
    /// The first version of this background rendered flat, and the reason was
    /// the palette: three near-identical navy tones give a mesh nothing to
    /// blend. Whatever comes in, six distinguishable colours have to come out.
    @Test("A palette is always six colours")
    func paletteSize() {
        #expect(AmbientBackground.palette(from: [], scheme: .dark).count == 6)
        #expect(AmbientBackground.palette(from: [.blue], scheme: .dark).count == 6)
        #expect(AmbientBackground.palette(from: [.blue, .red, .green], scheme: .light).count == 6)
    }

    /// Shades of one colour, not a spread of hues — but the shades have to
    /// actually differ, or the mesh has nothing to blend and renders flat. That
    /// is the failure this catches.
    @Test("Every palette is one hue in distinguishable shades")
    func oneHueManyShades() {
        for accents in [[], [Color.blue], [Color.orange, Color.green]] {
            let palette = AmbientBackground.palette(from: accents, scheme: .dark)
            let parts = palette.compactMap { AmbientBackground.HSB($0) }
            #expect(parts.count == 6)

            // Compared with a tolerance, not for equality: reading a colour back
            // goes through sRGB and moves the hue in the last decimal.
            let hues = parts.map(\.hue)
            let spread = (hues.max() ?? 0) - (hues.min() ?? 0)
            #expect(spread < 0.02, "the palette should be one hue, it spans \(spread)")

            let shades = Set(parts.map { Int($0.saturation * 100) * 1000 + Int($0.brightness * 100) })
            #expect(shades.count >= 5, "only \(shades.count) distinct shades")
        }
    }

    @Test("A running server sets the hue")
    func accentDrivesHue() throws {
        let accent = try #require(Color.accent(fromHex: "#E11D48"))
        let wanted = try #require(AmbientBackground.HSB(accent)).hue
        let got = try #require(AmbientBackground.HSB(
            AmbientBackground.palette(from: [accent], scheme: .dark)[0])).hue
        #expect(abs(got - wanted) < 0.01)
    }

    @Test("With nothing running the hue is the app's own")
    func restingHue() throws {
        let got = try #require(AmbientBackground.HSB(
            AmbientBackground.palette(from: [], scheme: .dark)[0])).hue
        #expect(abs(got - AmbientBackground.baseHue) < 0.01)
    }

    @Test("Accent colours are read, bad ones ignored")
    func hexParsing() {
        #expect(Color.accent(fromHex: "#3B82F6") != nil)
        #expect(Color.accent(fromHex: "3B82F6") != nil)
        #expect(Color.accent(fromHex: " #3B82F6 ") != nil)

        // The editor's own init(hex:) answers grey for these, which is right for
        // a swatch and wrong for the background — hence the separate reader.
        #expect(Color.accent(fromHex: "") == nil)
        #expect(Color.accent(fromHex: "#GGGGGG") == nil)
        #expect(Color.accent(fromHex: "#FFF") == nil)
        #expect(Color.accent(fromHex: "#3B82F6FF") == nil)
    }
}

@Suite("Mesh geometry")
struct MeshGeometryTests {

    /// A control point that reaches past its neighbour folds the quad inside
    /// out, and a folded quad draws as a hard-edged wedge across the window.
    /// The amplitude has to stay under half the spacing between points.
    @Test("Interior points can never cross")
    func noFold() {
        let side = 4
        let spacing = 1.0 / Double(side - 1)
        let amplitude = 0.12                    // must match MeshBackground

        #expect(amplitude < spacing / 2,
                "amplitude \(amplitude) is not under half the spacing \(spacing / 2)")

        // The two interior columns, at their closest approach.
        let firstMax = spacing + amplitude
        let secondMin = spacing * 2 - amplitude
        #expect(firstMax < secondMin, "columns overlap: \(firstMax) reaches past \(secondMin)")
    }
}

@Suite("Health check")
struct HealthCheckTests {

    @Test("Nothing running means nothing to report")
    func empty() async {
        let check = HealthCheck()
        await check.run([])
        #expect(check.results.isEmpty)
        #expect(!check.hasResults)
    }

    /// A server whose process is alive but whose site is broken answers with an
    /// error code, and that has to count as a failure — the whole reason this
    /// exists is that “running” and “working” are different things.
    @Test("Only 2xx and 3xx count as answering")
    func verdicts() {
        func result(_ status: Int?) -> HealthResult {
            HealthResult(id: UUID(), name: "x", address: "http://127.0.0.1:8080",
                         status: status, elapsed: 0.01, server: nil, problem: nil)
        }
        #expect(result(200).isGood)
        #expect(result(301).isGood)
        #expect(!result(404).isGood)
        #expect(!result(500).isGood)
        #expect(!result(nil).isGood)
    }

    @Test("A refused connection reports the reason, not a blank")
    func refused() async {
        var profile = ServerProfile()
        profile.name = "Nothing here"
        profile.host = "127.0.0.1"
        // A port nothing is listening on. The check has to come back, and come
        // back with something a person can read.
        profile.port = 59_997

        let check = HealthCheck()
        await check.run([profile])
        let first = check.results.first
        #expect(first != nil)
        #expect(first?.isGood == false)
        #expect(first?.summary.isEmpty == false)
    }
}

@Suite("Icons that actually exist")
struct SymbolTests {

    /// A name that is not an SF Symbol renders as nothing — no icon, no error,
    /// no warning. Both Apache engines shipped like that because Apache's mark
    /// is a feather and "feather" is not a symbol.
    @Test("Every engine has a real icon")
    func engineSymbols() {
        for engine in ServerEngine.allCases {
            #expect(NSImage(systemSymbolName: engine.symbol, accessibilityDescription: nil) != nil,
                    "\(engine.rawValue) uses “\(engine.symbol)”, which is not an SF Symbol")
        }
    }

    @Test("Every sidebar section has a real icon")
    func sectionSymbols() {
        for section in SidebarSection.allCases {
            #expect(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) != nil,
                    "\(section.rawValue) uses “\(section.symbol)”")
        }
    }

    @Test("Every profile template has a real icon")
    func templateSymbols() {
        for template in ProfileTemplate.builtIn {
            #expect(NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil) != nil,
                    "\(template.id) uses “\(template.symbol)”")
        }
    }
}

@Suite("Background settings")
struct BackgroundSettingTests {

    /// Hue is a circle, so the distance between two of them is the shorter way
    /// round. Comparing them as plain numbers calls 0.99 and 0.01 the width of
    /// the spectrum apart when they are both red.
    static func apart(_ a: Double, _ b: Double) -> Double {
        let direct = abs(a - b)
        return min(direct, 1 - direct)
    }

    @Test("The resting hue comes from settings")
    func hueFollowsSettings() throws {
        for wanted in [0.0, 0.33, 0.62, 0.95] {
            let got = try #require(AmbientBackground.HSB(
                AmbientBackground.palette(from: [], scheme: .dark, restingHue: wanted)[0])).hue
            #expect(Self.apart(got, wanted) < 0.02, "asked for \(wanted), got \(got)")
        }
    }

    /// A running server's accent wins over the setting — the background says
    /// what is happening, and that matters more than the chosen colour.
    @Test("A running server overrides the chosen hue")
    func accentWins() throws {
        let accent = try #require(Color.accent(fromHex: "#E11D48"))
        let wanted = try #require(AmbientBackground.HSB(accent)).hue
        let got = try #require(AmbientBackground.HSB(
            AmbientBackground.palette(from: [accent], scheme: .dark, restingHue: 0.1)[0])).hue
        #expect(Self.apart(got, wanted) < 0.02)
    }

    @Test("The new settings survive a round trip")
    func encoding() throws {
        var settings = AppSettings()
        settings.backgroundEnabled = false
        settings.backgroundHue = 0.42
        settings.backgroundSpeed = 2.5
        settings.backgroundSaturation = 0
        settings.sidebarStyle = .modern

        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back.backgroundEnabled == false)
        #expect(abs(back.backgroundHue - 0.42) < 0.0001)
        #expect(abs(back.backgroundSpeed - 2.5) < 0.0001)
        #expect(back.backgroundSaturation == 0)
        #expect(back.sidebarStyle == .modern)
    }

    /// Colour amount at zero has to give actual greys, not a very slightly
    /// tinted set that still reads as blue.
    @Test("Zero colour is black and white")
    func greyscale() throws {
        let palette = AmbientBackground.palette(from: [], scheme: .dark,
                                                restingHue: 0.62, colourfulness: 0)
        for colour in palette {
            let parts = try #require(AmbientBackground.HSB(colour))
            #expect(parts.saturation < 0.001, "saturation \(parts.saturation) is not grey")
        }
        // The brightness steps still have to differ, or the mesh goes flat.
        let brightnesses = Set(palette.compactMap { AmbientBackground.HSB($0)?.brightness }
            .map { Int($0 * 100) })
        #expect(brightnesses.count >= 5)
    }

    /// Choosing a colour and then starting a server used to throw the choice
    /// away: the background went back to the profile's accent, which is blue
    /// unless someone changed it. A setting you picked outranks one you did not.
    @Test("Following servers is off by default")
    func choiceWins() {
        #expect(AppSettings().backgroundFollowsServers == false)
    }

    @Test("The new setting survives a round trip")
    func followEncoding() throws {
        var settings = AppSettings()
        settings.backgroundFollowsServers = true
        let back = try JSONDecoder().decode(AppSettings.self,
                                            from: try JSONEncoder().encode(settings))
        #expect(back.backgroundFollowsServers)
    }

    @Test("A running server still colours a greyscale background")
    func accentBeatsGreyscale() throws {
        let accent = try #require(Color.accent(fromHex: "#22C55E"))
        // Colourfulness scales what is there; an accent with the amount at zero
        // is still grey. That is the setting doing what it says.
        let grey = AmbientBackground.palette(from: [accent], scheme: .dark, colourfulness: 0)
        #expect(try #require(AmbientBackground.HSB(grey[0])).saturation < 0.001)

        let full = AmbientBackground.palette(from: [accent], scheme: .dark, colourfulness: 1)
        #expect(try #require(AmbientBackground.HSB(full[0])).saturation > 0.3)
    }
}

@Suite("Ukrainian")
struct UkrainianTests {

    /// The translation only shows up in the language list if its .lproj is
    /// actually in the bundle. Adding the entry to the registry and forgetting
    /// the file is the way to ship a language nobody can pick.
    @Test("Ukrainian is offered")
    func offered() {
        let ukrainian = AppLanguage.supported.first { $0.code == "uk" }
        #expect(ukrainian != nil)
        #expect(ukrainian?.nativeName == "Українська")
    }

    @Test("English is the source and needs no file")
    func sourceLanguage() {
        let english = AppLanguage.supported.first { $0.code == "en" }
        #expect(english?.isSource == true)
        #expect(english?.isBundled == true)
    }

    /// A key whose translation carries different format specifiers than the
    /// original crashes at the point it is shown, not at build time. This is the
    /// only cheap way to catch it.
    @Test("Every translation keeps the original's placeholders")
    func placeholders() throws {
        guard let path = Bundle.main.path(forResource: "uk", ofType: "lproj"),
              let bundle = Bundle(path: path),
              let file = bundle.path(forResource: "Localizable", ofType: "strings"),
              let table = NSDictionary(contentsOfFile: file) as? [String: String]
        else {
            // The test bundle does not carry the app's resources in every
            // configuration; nothing to check then.
            return
        }
        #expect(!table.isEmpty)

        func specifiers(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: "%[0-9]*\\$?[@a-z]+")
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }

        for (key, value) in table {
            #expect(specifiers(key) == specifiers(value),
                    "“\(key)” and its translation do not carry the same placeholders")
        }
    }
}

@Suite("Translation packs")
struct TranslationPackTests {

    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-\(UUID().uuidString).strings")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("A pack round-trips through a file")
    func roundTrip() throws {
        let url = try write("""
        /* ServerMaster translation pack
           Language: uk
           App version: 2.0
           Pack version: 3 */

        "Start" = "Запустити";
        "Stop" = "Зупинити";
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let pack = try #require(TranslationStore.read(url))
        #expect(pack.language == "uk")
        #expect(pack.appVersion == "2.0")
        #expect(pack.packVersion == "3")
        #expect(pack.strings["Start"] == "Запустити")
        #expect(pack.strings.count == 2)
    }

    /// The whole point of recording the app version: a pack written for an older
    /// release is missing whatever was added since, and may translate strings
    /// that have changed meaning. Saying so beats letting someone wonder why
    /// half a screen is in English.
    @Test("A pack from another version is flagged")
    func versionMismatch() throws {
        let old = try write("""
        /* Language: uk
           App version: 0.9 */
        "Start" = "Запустити";
        """)
        defer { try? FileManager.default.removeItem(at: old) }
        #expect(TranslationStore.read(old)?.matchesApp == false)

        let current = try write("""
        /* Language: uk
           App version: \(AppInfo.version) */
        "Start" = "Запустити";
        """)
        defer { try? FileManager.default.removeItem(at: current) }
        #expect(TranslationStore.read(current)?.matchesApp == true)
    }

    @Test("A file with no strings is not a pack")
    func rubbish() throws {
        let url = try write("this is not a strings file at all")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranslationStore.read(url) == nil)
    }

    /// An empty value in a hand-edited pack means "not translated yet", not
    /// "translate this to nothing" — otherwise one stray blank line wipes a
    /// label off the screen.
    @Test("An empty translation falls through instead of blanking the label")
    func emptyValue() throws {
        let url = try write("""
        /* Language: uk
           App version: \(AppInfo.version) */
        "Start" = "";
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let pack = try #require(TranslationStore.read(url))
        #expect(pack.strings["Start"] == "")
    }

    /// A pack with no header still has to land in the right language, or a file
    /// someone renamed by hand is imported as nothing.
    @Test("The language falls back to the file name")
    func languageFromName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uk.strings")
        try "\"Start\" = \"Запустити\";".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranslationStore.read(url)?.language == "uk")
    }
}
