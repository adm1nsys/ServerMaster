import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("A11 saved profile preparation", .serialized)
struct RecipePreparationTests {
    @MainActor private final class Gate {
        var entered = false
        var released = false
        weak var model: AppModel?
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-recipe-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func database(_ root: URL) -> DatabaseService {
        DatabaseService(runtimeDirectory: root.appendingPathComponent("db"),
            socketPath: "/tmp/sm-a11-\(UUID().uuidString.prefix(9)).sock",
            credentials: .init(save: { _,_,_ in }, read: { _ in nil }, delete: { _ in }))
    }

    private func template(_ id: String = "printshopcrm") throws -> ProfileTemplate {
        try #require(ProfileTemplate.builtIn.first { $0.id == id })
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    @Test("Failure and retry keep the same profile and report progress", arguments: ["printshopcrm", "web-to-print-store", "web-to-print-showcase"])
    func retry(id: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template(id)
        let original = source.makeProfile(name: "Keep this profile", port: 18193, root: root.path)
        var calls = 0
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { template, profile, _, log, runtime in
                calls += 1
                #expect(profile.id == original.id)
                #expect(template.recipeKind == source.recipeKind)
                #expect(runtime.privateDirectory?.path.hasPrefix(root.path) == true)
                runtime.progress(.dependencies)
                log.system("Attempt \(calls)")
                if calls == 1 { throw RuntimePackages.Failure(message: "Fixture offline") }
                runtime.progress(.verifying)
                return .init(databaseName: id == "printshopcrm" ? nil : "keep_existing_db")
            })
        model.profiles = [original]
        #expect(!(await model.prepareProjectRecipe(source, profileID: original.id)))
        let state = try #require(model.recipePreparations[original.id])
        #expect(state.phase == .failed("Fixture offline"))
        #expect(!model.isPreparingProjects)
        #expect(!model.snapshots.isWorking)
        #expect(!model.dependencies.isManagingPackages)
        #expect(model.profiles == [original])
        #expect(await model.prepareProjectRecipe(source, profileID: original.id))
        #expect(state.phase == .ready)
        #expect(model.profiles.count == 1 && model.profiles[0].id == original.id)
        #expect(model.profiles[0].rootPath == original.rootPath)
        #expect(calls == 2)
        #expect(state.log.plainText.contains(WebToPrintRecipe.Step.verifying.title))
        if id != "printshopcrm" {
            #expect(model.profiles[0].databaseName == "keep_existing_db")
            let loaded = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root))
            #expect(loaded.profiles.first?.databaseName == "keep_existing_db")
        }
        #expect(await model.prepareProjectRecipe(source, profileID: original.id))
        #expect(calls == 3)
        #expect(model.recipeTemplate(for: original)?.id == source.id)
        model.deleteProfile(model.profiles[0])
        #expect(model.recipePreparations[original.id] == nil)
        #expect(model.profiles.isEmpty)
    }

    @Test("Duplicate requests join one operation and conflicting changes are blocked")
    func operationBarrier() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        let profile = source.makeProfile(name: "Busy", port: 18194, root: root.path)
        var calls = 0
        let gate = Gate()
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { _,_,_,_,runtime in
                calls += 1
                runtime.progress(.dependencies)
                gate.entered = true
                while !gate.released { try? await Task.sleep(for: .milliseconds(20)) }
                return .init(databaseName: nil)
            })
        model.profiles = [profile]
        let first = Task { await model.prepareProjectRecipe(source, profileID: profile.id) }
        defer { gate.released = true }
        try await wait { gate.entered }
        let second = Task { await model.prepareProjectRecipe(source, profileID: profile.id) }
        #expect(model.isPreparingProjects)
        #expect(!model.runtimeChangesAllowed)
        #expect(model.snapshots.isWorking)
        #expect(model.dependencies.isManagingPackages)
        var changed = profile
        changed.rootPath = root.appendingPathComponent("other").path
        model.updateProfile(changed)
        model.deleteProfile(profile)
        #expect(model.profiles == [profile])
        await model.startServer(profile: profile)
        #expect(model.existingController(for: profile.id)?.processIdentifier == nil)
        #expect(await model.snapshots.take(profile: profile, database: nil) == nil)
        do {
            try await model.installMissingRequirements(for: profile)
            Issue.record("A package operation entered during preparation")
        } catch { #expect(error is RuntimePackages.Failure) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(calls == 1)
        gate.released = true
        #expect(await first.value)
        #expect(await second.value)
        #expect(!model.isPreparingProjects)
        #expect(!model.snapshots.isWorking)
        #expect(!model.dependencies.isManagingPackages)
    }

    @Test("An active server using the same folder blocks preparation, including aliases")
    func activeProject() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        let project = source.makeProfile(name: "CRM", port: 18195, root: root.path)
        var calls = 0
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { _,_,_,_,_ in calls += 1; return .init(databaseName: nil) })
        model.settings.writeLogsToFile = false
        model.settings.openBrowserOnStart = false
        var server = ServerProfile()
        server.engine = .custom
        server.customCommand = "/bin/sleep"
        server.customArguments = "30"
        server.rootPath = root.path + "/../" + root.lastPathComponent
        server.workingDirectory = root.path
        server.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        model.profiles = [project, server]
        defer { model.stopAllImmediately() }
        await model.startServer(profile: server)
        try #require(model.state(of: server.id) == .running)
        #expect(!(await model.prepareProjectRecipe(source, profileID: project.id)))
        #expect(calls == 0)
        #expect(model.state(of: server.id) == .running)
        #expect(model.banner?.isError == true)
    }

    @Test("Graceful quit waits for preparation and keeps the stop-on-quit preference", arguments: [false, true])
    func shutdown(stopServers: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let source = try template()
        let project = source.makeProfile(name: "CRM", port: 18196, root: projectRoot.path)
        let gate = Gate()
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { _,_,_,_,_ in
                gate.entered = true
                while !gate.released { try? await Task.sleep(for: .milliseconds(20)) }
                return .init(databaseName: nil)
            })
        model.settings.writeLogsToFile = false
        model.settings.stopServerOnQuit = stopServers
        var server = ServerProfile()
        server.engine = .custom
        server.customCommand = "/bin/sleep"
        server.customArguments = "30"
        server.rootPath = root.path
        server.workingDirectory = root.path
        server.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        model.profiles = [project, server]
        defer { gate.released = true; model.stopAllImmediately() }
        await model.startServer(profile: server)
        try #require(model.state(of: server.id) == .running)
        let preparing = Task { await model.prepareProjectRecipe(source, profileID: project.id) }
        try await wait { gate.entered }
        #expect(model.needsGracefulShutdown)
        var completed = false
        model.beginShutdown { completed = true }
        try await Task.sleep(for: .milliseconds(60))
        #expect(!completed)
        #expect(model.state(of: server.id) == .running)
        gate.released = true
        #expect(await preparing.value)
        try await wait { completed }
        #expect(model.state(of: server.id) == (stopServers ? .stopped : .running))
    }

    @Test("A failed profile save is visible and a retry can finish without duplicating the profile")
    func saveFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("state")
        let source = try template("web-to-print-store")
        let original = source.makeProfile(name: "Store", port: 18197, root: root.path)
        let model = AppModel(applicationDirectory: stateRoot, database: database(root),
            recipeRunner: { _,_,_,_,_ in .init(databaseName: "existing_store") })
        model.profiles = [original]
        let profilesFile = stateRoot.appendingPathComponent("profiles.json")
        if FileManager.default.fileExists(atPath: profilesFile.path) { try FileManager.default.removeItem(at: profilesFile) }
        try FileManager.default.createDirectory(at: profilesFile, withIntermediateDirectories: true)
        #expect(!(await model.prepareProjectRecipe(source, profileID: original.id)))
        #expect(model.profiles == [original])
        guard case .failed = model.recipePreparations[original.id]?.phase else { Issue.record("Save failure was hidden"); return }
        try FileManager.default.removeItem(at: profilesFile)
        #expect(await model.prepareProjectRecipe(source, profileID: original.id))
        #expect(model.profiles.count == 1)
        #expect(model.profiles[0].databaseName == "existing_store")
    }

    @Test("A profile changed outside the editor does not receive another project's result")
    func externalProfileChange() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template("web-to-print-store")
        let original = source.makeProfile(name: "Store", port: 18199, root: root.path)
        let holder = Gate()
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { _,_,_,_,_ in
                // Simulate an external profiles-file reload, bypassing the editor guard.
                holder.model?.profiles[0].rootPath = root.appendingPathComponent("different").path
                return .init(databaseName: "do_not_attach_here")
            })
        holder.model = model
        model.profiles = [original]
        #expect(!(await model.prepareProjectRecipe(source, profileID: original.id)))
        #expect(model.profiles[0].rootPath.hasSuffix("/different"))
        #expect(model.profiles[0].databaseName == original.databaseName)
        guard case .failed = model.recipePreparations[original.id]?.phase else { Issue.record("Profile change was hidden"); return }
    }

    @Test("An empty or missing project folder fails before running setup")
    func invalidFolder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try template()
        for path in ["", root.appendingPathComponent("missing").path] {
            let profile = source.makeProfile(name: "Missing", port: 18200, root: path)
            var executed = false
            var runtime = WebToPrintRecipe.Runtime()
            runtime.execute = { _,_,_,_ in executed = true; return .init(exitCode: 0, stdout: "", stderr: "") }
            do {
                _ = try await WebToPrintRecipe.prepare(template: source, profile: profile, database: database(root), log: ConsoleLog(), runtime: runtime)
                Issue.record("Invalid project folder was accepted")
            } catch WebToPrintRecipe.RecipeError.missingProjectFolder { }
            catch { Issue.record("Unexpected folder error: \(error)") }
            #expect(!executed)
        }
    }

    @Test("The real CRM recipe resumes after an npm error and preserves existing data")
    func realCRMRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("CRM with spaces")
        let uploads = projectRoot.appendingPathComponent("public/uploads")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let data = projectRoot.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let source = try template()
        let profile = source.makeProfile(name: "CRM", port: 18198, root: projectRoot.path)
        let kept = [".env": "PSC_DB=./data/user.sqlite\nPSC_SECRET=keep-this-secret\n",
                    profile.nodeEntryFile: "// existing application entry\n", "public/uploads/keep.txt": "user upload"]
        for (name, contents) in kept {
            try Data(contents.utf8).write(to: projectRoot.appendingPathComponent(name))
        }
        try Data(#"{"scripts":{"seed":"must-not-run"}}"#.utf8).write(to: projectRoot.appendingPathComponent("package.json"))
        let sqlite = data.appendingPathComponent("user.sqlite")
        let created = await ProcessRunner.run("/usr/bin/sqlite3", [sqlite.path, "CREATE TABLE kept(value TEXT); INSERT INTO kept VALUES('user data');"])
        try #require(created.succeeded)
        let originalDatabase = try Data(contentsOf: sqlite)
        var installs = 0
        let model = AppModel(applicationDirectory: root.appendingPathComponent("state"), database: database(root),
            recipeRunner: { template, value, database, log, supplied in
                var runtime = supplied
                runtime.execute = { _, arguments, _, _ in
                    if arguments == ["install"] {
                        installs += 1
                        if installs == 1 { return .init(exitCode: 1, stdout: "", stderr: "Fixture npm offline") }
                        try? FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
                        return .init(exitCode: 0, stdout: "Fixture dependencies installed", stderr: "")
                    }
                    Issue.record("Unexpected command or a destructive reseed: \(arguments)")
                    return .init(exitCode: 1, stdout: "", stderr: "Unexpected command")
                }
                return try await WebToPrintRecipe.prepare(template: template, profile: value, database: database, log: log, runtime: runtime)
            })
        model.profiles = [profile]
        #expect(!(await model.prepareProjectRecipe(source, profileID: profile.id)))
        #expect(!FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".servermaster-recipe.json").path))
        #expect(await model.prepareProjectRecipe(source, profileID: profile.id))
        #expect(await model.prepareProjectRecipe(source, profileID: profile.id))
        #expect(model.recipePreparations[profile.id]?.phase == .ready)
        #expect(model.profiles == [profile])
        #expect(model.database.state == .stopped)
        for (name, contents) in kept {
            #expect(try Data(contentsOf: projectRoot.appendingPathComponent(name)) == Data(contents.utf8))
        }
        #expect(try Data(contentsOf: sqlite) == originalDatabase)
        #expect(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".servermaster-recipe.json").path))
        #expect(model.recipePreparations[profile.id]?.log.plainText.contains(WebToPrintRecipe.Step.verifying.title) == true)
    }
}
