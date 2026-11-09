import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("New profile completion and duplication", .serialized)
struct NewProfilePreparationTests {
    @MainActor private final class Gate {
        var entered = false
        var released = false
        var calls = 0
    }

    @MainActor private final class Credentials {
        var values: [String: DatabaseCredentialStore.Credential] = [:]
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-wizard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func template(_ id: String = "printshopcrm") throws -> ProfileTemplate {
        try #require(ProfileTemplate.builtIn.first { $0.id == id })
    }

    private func profile(_ template: ProfileTemplate, root: URL) throws -> ServerProfile {
        var profile = template.makeProfile(name: "Wizard fixture", port: try BuiltinHTTPS.freeBackendPort(excluding: 0), root: root.path)
        profile.engine = .custom
        profile.customCommand = "/bin/sleep"
        profile.customArguments = "30"
        profile.needsDatabase = false
        profile.openBrowserOnStart = false
        return profile
    }

    private func wait(_ check: () -> Bool) async throws {
        for _ in 0..<200 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(check())
    }

    @Test("Port search skips reserved sockets and exclusions, wraps and reports exhaustion")
    func portSearch() throws {
        let reserved = PortReserver()
        defer { reserved.releaseAll() }
        let occupied = try #require(PortScanner.availablePort(startingAt: 28000))
        try reserved.reserve(port: occupied, note: "Fixture")
        let next = try #require(PortScanner.availablePort(startingAt: occupied, excluding: [occupied + 1]))
        #expect(next != occupied && next != occupied + 1)
        #expect(PortScanner.isPortFree(next, host: "127.0.0.1"))
        let only = try #require(PortScanner.availablePort(startingAt: 22000))
        let excluded = Set(1024...65535).subtracting([only])
        #expect(PortScanner.availablePort(startingAt: 65535, excluding: excluded) == only)
        #expect(PortScanner.availablePort(excluding: Set(1024...65535)) == nil)
        #expect(PortScanner.availablePort(startingAt: Int.max, excluding: excluded) == only)
    }

    @Test("Duplication keeps settings but selects an unreserved, free profile port")
    func duplicate() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationDirectory: root)
        defer { model.reserver.releaseAll() }
        var original = ServerProfile()
        original.name = "Preserve me"
        original.port = 8080
        original.rootPath = root.path
        original.environment = [EnvVar(key: "MODE", value: "fixture")]
        original.databaseName = "keep_database"
        original.phpVersion = "8.3"
        original.needsDatabase = false
        original.profileColor = "#112233"
        var other = ServerProfile()
        other.port = 8081
        model.profiles = [original, other]
        model.database.port = 8082
        model.settings.databaseAdminPort = 8083
        let reserved = try #require(model.suggestedProfilePort(startingAt: 8084))
        try model.reserver.reserve(port: reserved, note: "Fixture")
        try #require(model.duplicateProfile(original))
        var copy = try #require(model.profiles.last)
        #expect(copy.id != original.id && model.selectedProfileID == copy.id)
        #expect(copy.port != original.port && ![8081, 8082, 8083, reserved].contains(copy.port))
        #expect(PortScanner.isPortFree(copy.port, host: copy.host))
        #expect(copy.environment.first?.id != original.environment.first?.id)
        #expect(!model.isProfilePortAvailable(copy.port))
        copy.id = original.id
        copy.name = original.name
        copy.port = original.port
        copy.environment = original.environment
        #expect(copy == original)
        let reopened = AppModel(applicationDirectory: root)
        #expect(reopened.profiles == model.profiles)
    }

    @Test("A failed duplicate save restores the original list and selection")
    func duplicateSaveFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationDirectory: root)
        var original = ServerProfile()
        original.port = 18100
        model.profiles = [original]
        model.selectedProfileID = original.id
        let file = root.appendingPathComponent("profiles.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(!model.duplicateProfile(original))
        #expect(model.profiles == [original] && model.selectedProfileID == original.id)
        #expect(model.banner?.isError == true)
    }

    @Test("Preparation enables an explicit start only after success and uses the saved result")
    func prepareThenStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        let saved = try profile(source, root: root)
        let gate = Gate()
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"),
            recipeRunner: { _, _, _, _, _ in
                gate.calls += 1
                gate.entered = true
                while !gate.released { try? await Task.sleep(for: .milliseconds(20)) }
                return .init(databaseName: "prepared_database")
            })
        model.settings.writeLogsToFile = false
        model.settings.openBrowserOnStart = false
        model.profiles = [saved]
        defer { gate.released = true; model.stopAllImmediately() }
        let wizard = NewProfilePreparation()
        #expect(!wizard.canStart)
        let task = Task { await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model) }
        try await wait { gate.entered }
        #expect(wizard.phase == .preparing && !wizard.canStart)
        #expect(!(await wizard.start(using: model)))
        #expect(model.existingController(for: saved.id) == nil)
        await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model)
        #expect(gate.calls == 1)
        gate.released = true
        await task.value
        #expect(wizard.phase == .ready && wizard.canStart)
        #expect(model.existingController(for: saved.id) == nil) // No delayed autostart.
        #expect(await wizard.start(using: model))
        #expect(model.state(of: saved.id) == .running)
        #expect(model.existingController(for: saved.id)?.activeProfile?.databaseName == "prepared_database")
        #expect(model.existingController(for: saved.id)?.activeProfile?.openBrowserOnStart == false)
        #expect(!wizard.isStarting)
    }

    @Test("Failed recipes keep their profile and never enable Start")
    func failedPreparation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        let saved = try profile(source, root: root)
        let model = AppModel(applicationDirectory: root, recipeRunner: { _, _, _, _, _ in
            throw RuntimePackages.Failure(message: "Fixture setup failure")
        })
        model.profiles = [saved]
        defer { model.stopAllImmediately() }
        let wizard = NewProfilePreparation()
        await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model)
        #expect(wizard.phase == .failed("Fixture setup failure"))
        #expect(!wizard.canStart)
        #expect(!(await wizard.start(using: model)))
        #expect(model.profile(with: saved.id) == saved)
        #expect(model.existingController(for: saved.id) == nil)
    }

    @Test("Cancellation during preparation cannot enable a late start")
    func cancelledPreparation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        let saved = try profile(source, root: root)
        let gate = Gate()
        let model = AppModel(applicationDirectory: root, recipeRunner: { _, _, _, _, _ in
            gate.entered = true
            while !gate.released { try? await Task.sleep(for: .milliseconds(20)) }
            return .init(databaseName: nil)
        })
        model.profiles = [saved]
        defer { model.stopAllImmediately() }
        let wizard = NewProfilePreparation()
        let task = Task { await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model) }
        try await wait { gate.entered }
        task.cancel()
        gate.released = true
        await task.value
        #expect(!wizard.canStart)
        #expect(!(await wizard.start(using: model)))
        #expect(model.existingController(for: saved.id) == nil)
        #expect(wizard.phase == .failed(String(localized: "Profile setup was cancelled. No server was started.")))
    }

    @Test("No-preparation profiles wait for a click; deleted profiles and cancelled clicks cannot start")
    func deferredStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template("custom")
        let saved = try profile(source, root: root)
        let model = AppModel(applicationDirectory: root)
        model.profiles = [saved]
        defer { model.stopAllImmediately() }
        let wizard = NewProfilePreparation()
        await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model)
        #expect(wizard.canStart)
        #expect(model.existingController(for: saved.id) == nil)
        let click = Task { await wizard.start(using: model) }
        click.cancel()
        #expect(!(await click.value))
        #expect(model.existingController(for: saved.id) == nil)
        model.profiles = []
        #expect(!(await wizard.start(using: model)))
        #expect(model.existingController(for: saved.id) == nil)
    }

    @Test("First-run creation keeps the completion screen available before finishing setup")
    func firstRunCompletion() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationDirectory: root)
        try #require(model.needsFirstSetup)
        let saved = ServerProfile()
        #expect(model.addProfile(saved, completingFirstSetup: false))
        #expect(model.needsFirstSetup && model.profile(with: saved.id) == saved)
        model.completeFirstSetup()
        #expect(!model.needsFirstSetup)
        let reopened = AppModel(applicationDirectory: root)
        #expect(!reopened.needsFirstSetup && reopened.profile(with: saved.id) == saved)
    }

    @Test("A launch failure stays visible on the completion screen and permits retry")
    func failedStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template("custom")
        var saved = try profile(source, root: root)
        saved.customCommand = root.appendingPathComponent("missing-command").path
        let model = AppModel(applicationDirectory: root)
        model.profiles = [saved]
        defer { model.stopAllImmediately() }
        model.settings.writeLogsToFile = false
        let wizard = NewProfilePreparation()
        await wizard.prepare(profileID: saved.id, template: source, databaseName: nil, password: nil, using: model)
        #expect(wizard.canStart)
        #expect(!(await wizard.start(using: model)))
        #expect(wizard.startFailure?.isEmpty == false)
        #expect(wizard.canStart && !wizard.isStarting)
    }

    @Test("Wizard recipe passwords reach the runner but not profile JSON, exports or logs")
    func recipePassword() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template("web-to-print-store")
        let saved = try profile(source, root: root)
        let secret = "Private-'\\пароль-\(UUID().uuidString)"
        var received = false
        let model = AppModel(applicationDirectory: root, recipeRunner: { _, _, _, _, runtime in
            received = runtime.databasePassword == secret
            return .init(databaseName: "wizard_db")
        })
        model.profiles = [saved]
        let wizard = NewProfilePreparation()
        await wizard.prepare(profileID: saved.id, template: source, databaseName: "wizard_db", password: secret, using: model)
        #expect(received && wizard.canStart)
        #expect(try !String(decoding: JSONEncoder().encode(model.profiles), as: UTF8.self).contains(secret))
        #expect(try !String(contentsOf: root.appendingPathComponent("profiles.json"), encoding: .utf8).contains(secret))
        #expect(!model.installLog.plainText.contains(secret))
        #expect(model.recipePreparations[saved.id]?.log.plainText.contains(secret) == false)
    }

    @Test("A supplied empty password fails before any database starts")
    func emptyPassword() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseService(runtimeDirectory: root.appendingPathComponent("db"),
                                 socketPath: "/tmp/sm-wizard-\(UUID().uuidString.prefix(8)).sock")
        let model = AppModel(applicationDirectory: root, database: db)
        #expect(!(await model.prepareDatabase(named: "wizard", for: ServerProfile(), password: "")))
        #expect(db.state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: db.dataDirectory))
    }

    @Test("Wizard passwords use the normal credential store, preserve existing accounts and support generation",
          .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_REQUIREMENTS_DB"] == "1"))
    func databasePasswords() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = Credentials()
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("database with spaces"),
            socketPath: "/tmp/sm-u3-\(UUID().uuidString.prefix(10)).sock",
            port: try BuiltinHTTPS.freeBackendPort(excluding: 3307), credentials: .init(
                save: { name, user, password in credentials.values[name] = .init(user: user, password: password) },
                read: { credentials.values[$0] }, delete: { credentials.values.removeValue(forKey: $0) }))
        defer { database.stopImmediately() }
        try #require(database.isInstalled)
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database)
        var saved = ServerProfile()
        saved.needsDatabase = true
        model.profiles = [saved]
        let source = try template("joomla6")
        let wizard = NewProfilePreparation()
        let secret = "Custom-'\\пароль-\(UUID().uuidString)"
        await wizard.prepare(profileID: saved.id, template: source, databaseName: "wizard_custom", password: secret, using: model)
        try #require(wizard.canStart, "\(database.log.plainText)")
        #expect(try database.savedCredentials(for: "wizard_custom")?.password == secret)
        #expect(try await database.validatedSavedCredentials(for: "wizard_custom")?.password == secret)
        #expect(await model.prepareDatabase(named: "wizard_custom", for: saved, password: "must-not-replace"))
        #expect(try database.savedCredentials(for: "wizard_custom")?.password == secret)
        #expect(try await database.validatedSavedCredentials(for: "wizard_custom")?.password == secret)
        #expect(await model.prepareDatabase(named: "wizard_generated", for: saved))
        let generated = try #require(try database.savedCredentials(for: "wizard_generated"))
        #expect(generated.password.count >= 16 && generated.password != secret)
        #expect(try await database.validatedSavedCredentials(for: "wizard_generated") == generated)
        let failed = NewProfilePreparation()
        await failed.prepare(profileID: saved.id, template: source, databaseName: "root", password: "refuse", using: model)
        #expect(!failed.canStart)
        #expect(model.existingController(for: saved.id) == nil)
        #expect(!database.log.plainText.contains(secret) && !model.installLog.plainText.contains(secret))
        let fallbackDatabase = DatabaseService(runtimeDirectory: root.appendingPathComponent("fallback database"),
            socketPath: "/tmp/sm-u3f-\(UUID().uuidString.prefix(9)).sock",
            port: try BuiltinHTTPS.freeBackendPort(excluding: database.port), credentials: .init(
                save: { _, _, _ in throw NSError(domain: "FixtureKeychain", code: 1) },
                read: { _ in nil }, delete: { _ in }))
        defer { fallbackDatabase.stopImmediately() }
        let fallbackModel = AppModel(applicationDirectory: root.appendingPathComponent("fallback state"), database: fallbackDatabase)
        fallbackModel.profiles = [saved]
        let fallback = NewProfilePreparation()
        await fallback.prepare(profileID: saved.id, template: source, databaseName: "wizard_session", password: secret, using: fallbackModel)
        try #require(fallback.canStart, "\(fallbackDatabase.log.plainText)")
        #expect(fallbackDatabase.hasSessionOnlyCredentials(for: "wizard_session"))
        #expect(try fallbackDatabase.savedCredentials(for: "wizard_session")?.password == secret)
        #expect(try await fallbackDatabase.validatedSavedCredentials(for: "wizard_session")?.password == secret)
        #expect(!fallbackDatabase.log.plainText.contains(secret))
    }
}
