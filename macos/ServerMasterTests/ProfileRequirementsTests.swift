import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("A10 profile requirements", .serialized)
struct ProfileRequirementsTests {
    @MainActor private final class Packages {
        var formulas: Set<String> = []
        var paths: [String: String] = [:]
        var calls: [[String]] = []
        var failInstall = false
        var stopAfterInstall = false
        var canChange = true
        let commands = ["node": ["node", "npm"], "php": ["php", "php-fpm"],
                        "mariadb": ["mariadbd"], "caddy": ["caddy"], "nginx": ["nginx"], "httpd": ["httpd"]]

        func add(_ formula: String) {
            formulas.insert(formula)
            let stem = formula.components(separatedBy: "@")[0]
            for command in commands[stem] ?? [stem] {
                if stem == "php", paths[command] != nil { continue }
                paths[command] = "/fixture/opt/\(formula)/\(command == "php-fpm" ? "sbin" : "bin")/\(command)"
            }
        }

        func canonical(_ path: String) -> String {
            guard let range = path.range(of: "/opt/") else { return path }
            let suffix = path[range.upperBound...]
            let parts = suffix.split(separator: "/").map(String.init)
            guard let formula = parts.first else { return path }
            return "/fixture/Cellar/\(formula)/1.0.0" + (parts.count > 1 ? "/" + parts.dropFirst().joined(separator: "/") : "")
        }

        func status(_ command: String) -> DependencyStatus {
            if command == "brew" { return .init(installed: true, path: "/fixture/bin/brew") }
            return .init(installed: paths[command] != nil, path: paths[command])
        }

        func versions() -> [PHPVersions.Installed] {
            formulas.compactMap { formula in
                guard formula.hasPrefix("php@") else { return nil }
                let version = String(formula.dropFirst(4))
                return .init(version: version, binary: "/fixture/opt/\(formula)/sbin/php-fpm",
                             isDefault: paths["php-fpm"]?.contains("/\(formula)/") == true)
            }
        }

        func run(_ executable: String, _ args: [String], _ timeout: TimeInterval) async -> CommandResult {
            calls.append([executable] + args)
            if args.first == "info" {
                let formula = args.last!
                let data = try! JSONSerialization.data(withJSONObject: ["formulae": [["name": formula,
                    "versions": ["stable": "1.0.0"], "installed": formulas.contains(formula) ? [["version": "1.0.0"]] : [], "outdated": false]]])
                return .init(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            if args.first == "--prefix" { return .init(exitCode: 0, stdout: "/fixture/opt/\(args.last!)", stderr: "") }
            if args.first == "install" {
                if failInstall { return .init(exitCode: 1, stdout: "", stderr: "Fixture package download failed") }
                add(args.last!)
                if stopAfterInstall { canChange = false }
                return .init(exitCode: 0, stdout: "Installed", stderr: "")
            }
            if args.first == "uninstall" {
                let formula = args.last!
                formulas.remove(formula)
                paths = paths.filter { !$0.value.contains("/\(formula)/") }
                return .init(exitCode: 0, stdout: "Removed", stderr: "")
            }
            if ["--version", "-v", "version"].contains(args.first ?? "") {
                return .init(exitCode: 0, stdout: "1.0.0", stderr: "")
            }
            return .init(exitCode: 1, stdout: "", stderr: "Unexpected fixture command")
        }

        func checker() -> DependencyChecker {
            var probes = DependencyChecker.Probes()
            probes.refreshEnvironment = {}
            probes.dependency = { dependency in await self.status(dependency.command) }
            probes.extensions = { [] }
            probes.versions = { self.versions() }
            probes.isExecutable = { path in
                for formula in self.formulas where formula.hasPrefix("php@") {
                    if path.contains("/\(formula)/") { return true }
                }
                return false
            }
            probes.canonical = canonical
            probes.run = run
            return DependencyChecker(probes: probes,
                runtimePackages: RuntimePackages(run: run, which: { self.paths[$0] }, canonical: canonical))
        }
    }

    @Test("The selected PHP branch wins over the unrelated default PHP")
    func selectedPHP() async throws {
        let fake = Packages()
        fake.add("php@8.2")
        fake.add("nginx")
        let checker = fake.checker()
        await checker.checkAll()
        var value = ServerProfile()
        value.engine = .phpFpm
        value.phpVersion = "8.3"
        #expect(checker.status(for: "php-fpm").installed)
        #expect(checker.missingRequirements(for: value) == [.init(command: "php-fpm", phpVersion: "8.3")])
        fake.add("php@8.3")
        await checker.checkAll()
        #expect(checker.missingRequirements(for: value).isEmpty)
        value.phpVersion = ""
        #expect(checker.missingRequirements(for: value).isEmpty)
    }

    @Test("Requirements combine engine, recipe, database intent and HTTPS without duplicates")
    func combinations() {
        for engine in ServerEngine.allCases {
            for database in [false, true] {
                for https in [false, true] {
                    var profile = ServerProfile()
                    profile.engine = engine
                    profile.needsDatabase = database
                    profile.httpsEnabled = https
                    let list = ProfileRequirement.list(for: profile)
                    #expect(list.map(\.command).contains("mariadbd") == database)
                    #expect(list.map(\.command).contains("caddy") == (engine == .caddy || https && engine.requiresHTTPSProxy))
                    #expect(Set(list.map(\.id)).count == list.count)
                }
            }
        }
        var crm = ServerProfile()
        crm.engine = .nodeScript
        crm.templateId = "printshopcrm"
        #expect(crm.requiredTools == ["node", "npm"])
        var template = ProfileTemplate.builtIn.first { $0.id == "printshopcrm" }!
        template.id = "user.crm-copy"
        crm.templateId = template.id
        #expect(ProfileRequirement.list(for: crm, template: template).contains { $0.command == "npm" })
    }

    @Test("Old PHP profiles keep their DB default, while an explicit false survives round trips")
    func databaseIntent() throws {
        for engine in ServerEngine.allCases {
            let old = try JSONDecoder().decode(ServerProfile.self, from: Data("{\"engine\":\"\(engine.rawValue)\"}".utf8))
            #expect(old.needsDatabase == engine.typicallyNeedsDatabase)
            for flag in [false, true] {
                let source = Data("{\"engine\":\"\(engine.rawValue)\",\"needsDatabase\":\(flag)}".utf8)
                let profile = try JSONDecoder().decode(ServerProfile.self, from: source)
                #expect(profile.needsDatabase == flag)
                var withOldName = profile
                withOldName.databaseName = "keep_manual_database"
                let template = ProfileTemplate.from(profile: withOldName, title: "DB intent", summary: "Fixture")
                #expect(template.needsDatabase == flag)
                #expect(template.makeProfile(name: "Copy", port: 8188, root: "/tmp").needsDatabase == flag)
                #expect(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile)).needsDatabase == flag)
            }
        }
    }

    @Test("Homebrew's unversioned PHP is accepted only for its actual branch")
    func defaultBranch() {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let path = prefix + "/opt/php/bin/php"
            let correct = { (_: String) in prefix + "/Cellar/php/8.3.99_1/bin/php" }
            #expect(PHPVersions.matchesHomebrewPath(path, version: "8.3", canonical: correct))
            #expect(!PHPVersions.matchesHomebrewPath(path, version: "8.2", canonical: correct))
            #expect(!PHPVersions.matchesHomebrewPath(path, version: "8.30", canonical: correct))
            #expect(!PHPVersions.matchesHomebrewPath(path, version: "8.3", canonical: { _ in "/foreign/php" }))
        }
    }

    @Test("Install missing skips present packages and installs Node/npm once")
    func installRecipeRequirements() async throws {
        let fake = Packages()
        fake.add("caddy")
        let checker = fake.checker()
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.templateId = "printshopcrm"
        profile.httpsEnabled = true
        profile.needsDatabase = true
        try await checker.installMissing(for: profile, log: ConsoleLog(), canChange: { true })
        #expect(checker.missingRequirements(for: profile).isEmpty)
        let installs = fake.calls.filter { $0.dropFirst().first == "install" }
        #expect(installs == [["brew", "install", "--formula", "node"], ["brew", "install", "--formula", "mariadb"]])
        #expect(!checker.isManagingPackages)
    }

    @Test("Installing a missing selected PHP branch does not replace the default")
    func installPHPBranch() async throws {
        let fake = Packages()
        fake.add("php@8.2")
        let checker = fake.checker()
        var profile = ServerProfile()
        profile.engine = .phpBuiltIn
        profile.phpVersion = "8.3"
        try await checker.installMissing(for: profile, log: ConsoleLog(), canChange: { true })
        #expect(checker.missingRequirements(for: profile).isEmpty)
        #expect(fake.formulas.contains("php@8.2") && fake.formulas.contains("php@8.3"))
        #expect(fake.calls.contains(["brew", "install", "--formula", "php@8.3"]))
        #expect(checker.status(for: "php").path?.contains("php@8.2") == true)
        #expect(!fake.calls.flatMap { $0 }.contains("link"))
    }

    @Test("A refused or interrupted batch stops and releases its package lock", arguments: ["busy", "download", "after-first"])
    func failedInstall(mode: String) async throws {
        let fake = Packages()
        fake.failInstall = mode == "download"
        fake.canChange = mode != "busy"
        fake.stopAfterInstall = mode == "after-first"
        let checker = fake.checker()
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.needsDatabase = true
        do {
            try await checker.installMissing(for: profile, log: ConsoleLog(), canChange: { fake.canChange })
            Issue.record("A refused batch reported success")
        } catch { #expect(error is RuntimePackages.Failure) }
        #expect(!checker.isManagingPackages)
        #expect(!fake.formulas.contains("mariadb"))
        #expect(fake.calls.filter { $0.dropFirst().first == "install" }.count == (mode == "busy" ? 0 : 1))
    }

    @Test("Removing plain PHP also protects profiles using its versioned alias")
    func plainPHPUsage() async throws {
        var probes = DependencyChecker.Probes()
        probes.refreshEnvironment = {}
        probes.dependency = { dependency in
            .init(installed: ["php", "php-fpm"].contains(dependency.command), path: "/fixture/opt/php/bin/" + dependency.command)
        }
        probes.extensions = { [] }
        probes.versions = { [.init(version: "8.3", binary: "/fixture/opt/php/sbin/php-fpm", isDefault: true)] }
        probes.isExecutable = { $0.hasPrefix("/fixture/opt/php/") }
        probes.canonical = { $0.replacingOccurrences(of: "/opt/php/", with: "/Cellar/php/8.3.99/") }
        let checker = DependencyChecker(probes: probes)
        await checker.checkAll()
        var profile = ServerProfile()
        profile.engine = .phpFpm
        profile.phpVersion = "8.3"
        #expect(throws: RuntimePackages.Failure.self) { try checker.checkPHPRemoval(formula: "php", profiles: [profile]) }
        #expect(checker.profilesUsingPHP(formula: "php@8.2", profiles: [profile]).isEmpty)
    }

    @Test("Both removal paths protect explicit and automatic PHP consumers")
    func protectPHP() async throws {
        let fake = Packages()
        fake.add("php@8.3")
        let checker = fake.checker()
        await checker.checkAll()
        var profile = ServerProfile()
        profile.engine = .phpBuiltIn
        profile.name = "Keep this PHP"
        profile.phpVersion = "8.3"
        for version in ["8.3", ""] {
            profile.phpVersion = version
            #expect(throws: RuntimePackages.Failure.self) { try checker.checkPHPRemoval(formula: "php@8.3", profiles: [profile]) }
            #expect(!(await checker.uninstallPHP(version: "8.3", profiles: [profile], log: ConsoleLog(), canChange: { true })))
            do {
                _ = try await checker.runtimePackages.perform(command: "php", action: .remove, log: ConsoleLog(), beforeRemoval: {
                    try checker.checkPHPRemoval(formula: $0.formula, profiles: [profile])
                })
                Issue.record("Generic Manage removed a PHP package in use")
            } catch { #expect(error.localizedDescription.contains(profile.name)) }
        }
        #expect(!fake.calls.contains { $0.contains("uninstall") })
        #expect(fake.formulas.contains("php@8.3"))
        // A non-PHP profile's stale PHP field is not a package dependency.
        profile.engine = .httpServer
        profile.phpVersion = "8.3"
        #expect(await checker.uninstallPHP(version: "8.3", profiles: [profile], log: ConsoleLog(), canChange: { true }))
        #expect(!fake.calls.flatMap { $0 }.contains("--force"))
        #expect(!fake.calls.flatMap { $0 }.contains("--ignore-dependencies"))
    }
}

@MainActor
@Suite("A10 DB intent live", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_REQUIREMENTS_DB"] == "1"))
struct RequirementDatabaseTests {
    @Test("A failed required DB leaves the profile failed without launching its process")
    func failedDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-a10-db-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("db")
        try Data("not a directory".utf8).write(to: blocker)
        let database = DatabaseService(runtimeDirectory: blocker,
            socketPath: "/tmp/sm-a10-f-\(UUID().uuidString.prefix(9)).sock",
            port: try BuiltinHTTPS.freeBackendPort(excluding: 3307),
            credentials: .init(save: { _,_,_ in }, read: { _ in nil }, delete: { _ in }))
        defer { database.stopImmediately() }
        let model = AppModel(applicationDirectory: root.appendingPathComponent("app"), database: database)
        model.settings.writeLogsToFile = false
        var profile = ServerProfile()
        profile.engine = .custom
        profile.customCommand = "/bin/sleep"
        profile.customArguments = "30"
        profile.workingDirectory = root.path
        profile.needsDatabase = true
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: database.port)
        model.profiles = [profile]
        await model.startServer(profile: profile)
        guard case .failed = model.state(of: profile.id) else { Issue.record("A missing required DB was ignored"); return }
        #expect(model.controller(for: profile.id).processIdentifier == nil)
        #expect(model.banner?.isError == true)
    }

    @Test("Two profiles share a DB startup, while a DB-free PHP profile does not start MariaDB")
    func databaseIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-requirements-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RuntimePortLease.acquire(excluding: 3307)
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("db"),
            socketPath: "/tmp/sm-a10-\(UUID().uuidString.prefix(9)).sock", port: lease.port,
            credentials: .init(save: { _,_,_ in }, read: { _ in nil }, delete: { _ in }))
        defer { database.stopImmediately() }
        let model = AppModel(applicationDirectory: root.appendingPathComponent("app"), database: database)
        model.settings.writeLogsToFile = false
        model.settings.openBrowserOnStart = false
        var php = ServerProfile()
        php.engine = .phpFpm
        php.rootPath = root.path
        php.needsDatabase = false
        php.port = try BuiltinHTTPS.freeBackendPort(excluding: lease.port)
        model.profiles = [php]
        await model.startServer(profile: php)
        #expect(database.state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: database.dataDirectory))
        await model.stopAll()
        var first = ServerProfile()
        first.engine = .custom
        first.customCommand = "/bin/sleep"
        first.customArguments = "30"
        first.workingDirectory = root.path
        first.needsDatabase = true
        first.port = try BuiltinHTTPS.freeBackendPort(excluding: lease.port)
        var second = first
        second.id = UUID()
        second.port = try BuiltinHTTPS.freeBackendPort(excluding: first.port)
        model.profiles = [first, second]
        defer { model.stopAllImmediately() }
        lease.allowChildBind()
        try #require(PortScanner.isPortFree(database.port, host: database.host))
        let a = Task { await model.startServer(profile: first) }
        let b = Task { await model.startServer(profile: second) }
        await a.value
        await b.value
        let temporaryFiles = await database.query(sql: "SELECT @@tmpdir;")
        #expect(temporaryFiles.succeeded)
        #expect(temporaryFiles.stdout.trimmingCharacters(in: .whitespacesAndNewlines).contains(database.temporaryDirectory))
        #expect(database.state == .running, "DB startup log:\n\(database.log.plainText)")
        #expect(model.state(of: first.id) == .running, "First profile + DB:\n\(model.controller(for: first.id).log.plainText)\n\(database.log.plainText)")
        #expect(model.state(of: second.id) == .running, "Second profile + DB:\n\(model.controller(for: second.id).log.plainText)\n\(database.log.plainText)")
        #expect(await model.stopAll() == [])
        await database.stop()
    }
}
