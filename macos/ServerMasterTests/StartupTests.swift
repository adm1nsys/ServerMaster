import Foundation
import Testing
import Darwin
@testable import ServerMaster

@MainActor
@Suite("T4 first launch storage")
struct FirstLaunchTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("startup-t4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Interrupted first run, cancel, later and repeat preserve the pending choice")
    func pendingChoice() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ApplicationStore(directory: root)
        var seedCount = 0
        func starter() -> [ServerProfile] { seedCount += 1; return [ServerProfile()] }
        let first = store.load(starter: starter)
        #expect(first.needsFirstSetup)
        #expect(first.errors.isEmpty)
        let before = try Data(contentsOf: store.profilesFile)
        // Cancel/back and an interrupted splash do not commit a choice.
        let reopened = store.load(starter: starter)
        #expect(reopened.needsFirstSetup)
        #expect(reopened.profiles.map(\.id) == first.profiles.map(\.id))
        #expect(try Data(contentsOf: store.profilesFile) == before)
        #expect(seedCount == 1)
        try store.finishFirstSetup() // Later/Check software dismiss permanently.
        #expect(!store.load(starter: starter).needsFirstSetup)
        #expect(seedCount == 1)
    }

    @Test("Create persists the chosen profile; deleting all profiles stays empty")
    func creationAndEmptyList() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ApplicationStore(directory: root)
        _ = store.load { [] }
        let template = try #require(ProfileTemplate.builtIn.first { $0.id == "static" })
        let profile = template.makeProfile(name: "Перший сайт", port: 8080, root: root.appendingPathComponent("site").path)
        try store.save([profile], to: store.profilesFile)
        try store.finishFirstSetup()
        let restored = store.load { Issue.record("Persisted profiles must not be reseeded"); return [] }
        #expect(restored.profiles.first?.name == "Перший сайт")
        #expect(restored.profiles.first?.id == profile.id)
        #expect(!restored.needsFirstSetup)
        try store.save([ServerProfile](), to: store.profilesFile)
        #expect(store.load { Issue.record("An intentionally empty list was reseeded"); return [profile] }.profiles.isEmpty)
    }

    @Test("Legacy settings migrate without showing onboarding or replacing an empty list")
    func legacy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ApplicationStore(directory: root)
        try Data(#"{"language":"uk","updateRepository":"","updateVersionFile":"lastversion.txt"}"#.utf8).write(to: store.settingsFile)
        try Data("[]".utf8).write(to: store.profilesFile)
        let loaded = store.load { Issue.record("Legacy list was overwritten"); return [] }
        #expect(!loaded.needsFirstSetup)
        #expect(loaded.settings.language == "uk")
        #expect(loaded.settings.updateVersionFile == AppSettings().updateVersionFile)
        #expect(!loaded.settings.updateRepository.isEmpty)
        #expect(try Data(contentsOf: store.profilesFile) == Data("[]".utf8))
    }

    @Test("Unreadable JSON survives load and is backed up before an explicit replacement")
    func damagedStorage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ApplicationStore(directory: root)
        let damaged = Data("{ damaged file — не видаляти".utf8)
        try damaged.write(to: store.profilesFile)
        try damaged.write(to: store.settingsFile)
        let loaded = store.load { Issue.record("Damaged profiles were replaced by a preset"); return [] }
        #expect(loaded.errors.count == 2)
        #expect(try Data(contentsOf: store.profilesFile) == damaged)
        #expect(try Data(contentsOf: store.settingsFile) == damaged)
        try store.save(AppSettings(), to: store.settingsFile)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("settings.json.unreadable-") })
        #expect(try Data(contentsOf: backup) == damaged)
        #expect(try Data(contentsOf: store.profilesFile) == damaged)
    }

    @Test("An unavailable data directory reports errors without destroying the blocking file")
    func cannotWrite() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocker)
        let loaded = ApplicationStore(directory: blocker).load { [] }
        #expect(loaded.needsFirstSetup)
        #expect(!loaded.errors.isEmpty)
        #expect(try Data(contentsOf: blocker) == Data("keep".utf8))
    }
}

/// The probe stays unfinished until the test explicitly releases it; scheduler
/// delays cannot turn a "20 ms before 150 ms" assumption into a false failure.
nonisolated private final class StartupProbeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var starts = 0
    var count: Int {
        condition.lock(); defer { condition.unlock() }
        return starts
    }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        starts += 1
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}

@MainActor
@Suite("T4 bounded slow startup")
struct SlowStartupTests {
    @MainActor private final class Gate { var released = false }
    @Test("Shared budget releases the splash while slow jobs finish once in the background")
    func budget() async {
        let budget = StartupBudget(seconds: 0.08)
        let dependencies = StartupWork(), updates = StartupWork()
        let gate = Gate()
        var starts = 0, completed = 0
        let result = await dependencies.run(wait: budget.remaining(upTo: 30)) {
            starts += 1
            while !gate.released { try? await Task.sleep(for: .milliseconds(10)) }
            completed += 1
        }
        #expect(result == .timedOut)
        #expect(budget.remaining(upTo: 20) == 0)
        _ = await dependencies.run(wait: 0) { Issue.record("Slow startup check was duplicated") }
        _ = await updates.run(wait: budget.remaining(upTo: 20)) { completed += 1 }
        gate.released = true
        for _ in 0..<100 where !dependencies.finished || !updates.finished { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(starts == 1)
        #expect(completed == 2)
        #expect(dependencies.finished && updates.finished)
    }

    @Test("Closing a window cancels its wait, not the owned background check")
    func cancellation() async {
        let work = StartupWork()
        var released = false
        let waiter = Task { await work.run(wait: 30) {
            while !released { try? await Task.sleep(for: .milliseconds(10)) }
        } }
        await Task.yield()
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        released = true
        for _ in 0..<100 where !work.finished { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(work.finished)
    }

    @Test("PATH reads remain immediate while a single login probe is slow")
    func environment() async {
        let gate = StartupProbeGate()
        defer { gate.release() }
        let shell = ShellEnvironment(loginProbe: {
            gate.wait()
            return ["/tmp/t4-login-path", "/usr/bin"]
        })
        shell.setExtraEntries(["/tmp/t4-extra"])
        #expect(shell.path.hasPrefix("/tmp/t4-extra:"))
        #expect(!shell.path.contains("/tmp/t4-login-path"))
        async let a: Void = shell.refresh()
        async let b: Void = shell.refresh()
        for _ in 0..<100 where gate.count == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.count == 1)
        #expect(!shell.path.contains("/tmp/t4-login-path"), "MainActor must remain able to read fallback PATH during the probe")
        gate.release()
        _ = await (a, b)
        #expect(gate.count == 1)
        #expect(shell.path.contains("/tmp/t4-login-path"))
        #expect(shell.path.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count == 1)
    }

    @Test("Real hung/flooding probes have bounded output and clean up descendants", arguments: [false, true])
    func processes(waitForChild: Bool) async throws {
        let start = ContinuousClock.now
        let result = await Task.detached {
            ExecutableProbe.run("/bin/bash", arguments: ["-c", "/bin/sleep 30 & echo $!; " + (waitForChild ? "wait" : "exit 0")],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 0.12)
        }.value
        #expect(result.timedOut == waitForChild)
        #expect(result.succeeded != waitForChild)
        #expect(start.duration(to: .now) < .seconds(3))
        let child = try #require(Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if PrivilegedLauncher.isAlive(pid: child) { kill(child, SIGKILL) } }
        for _ in 0..<100 where PrivilegedLauncher.isAlive(pid: child) { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!PrivilegedLauncher.isAlive(pid: child))
        let flood = await Task.detached {
            ExecutableProbe.run("/usr/bin/yes", arguments: [], environment: [:], timeout: 0.08, outputLimit: 128)
        }.value
        #expect(flood.timedOut)
        #expect(flood.output.utf8.count == 128)
    }

    @Test("The actual PHP version helper times out without blocking MainActor")
    func phpVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("php-startup-t4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let php = directory.appendingPathComponent("php")
        try "#!/bin/bash\nprintf '8.3'\n".write(to: php, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: php.path)
        let result = await Task.detached { PHPVersions.versionProbe(php.path) }.value
        #expect(result.succeeded, "timeout=\(result.timedOut), exit=\(String(describing: result.exitCode)), launch=\(String(describing: result.launchError)), output=\(result.output)")
        #expect(result.output == "8.3")
        try "#!/bin/bash\n/bin/sleep 30\n".write(to: php, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: php.path)
        var heartbeat = false
        let slow = Task.detached { PHPVersions.matches(binary: php.path, version: "8.3") }
        try? await Task.sleep(for: .milliseconds(30))
        heartbeat = true
        #expect(heartbeat)
        #expect(await slow.value == false)
    }

    @Test("Version probes retain stderr output used by tools such as nginx")
    func stderrVersion() async {
        let result = await Task.detached {
            ExecutableProbe.run("/bin/bash", arguments: ["-c", "printf 'tool version 1.2.3' >&2"],
                environment: [:], includeStandardError: true)
        }.value
        #expect(result.succeeded)
        #expect(result.output == "tool version 1.2.3")
    }

    @Test("Dependency checks do not duplicate; offline results and late PHP scan update state")
    func dependencies() async {
        var released = false
        var environmentChecks = 0
        var probes = DependencyChecker.Probes()
        probes.refreshEnvironment = {
            environmentChecks += 1
            while !released { try? await Task.sleep(for: .milliseconds(10)) }
        }
        probes.dependency = { _ in DependencyStatus(installed: false, path: nil, version: nil, checking: false) }
        probes.extensions = { [] }
        probes.versions = { try? await Task.sleep(for: .milliseconds(40)); return [] }
        let checker = DependencyChecker(probes: probes)
        let work = Task { await checker.checkAll() }
        await Task.yield()
        #expect(checker.isChecking)
        await checker.checkAll()
        await checker.check(command: "php")
        #expect(environmentChecks == 1)
        released = true
        await work.value
        #expect(!checker.isChecking)
        #expect(checker.lastCheck != nil)
        #expect(checker.missingTools(for: .apachePHP).contains("php-fpm"))
    }

    @Test("Read-only startup inventory on the actual machine",
          .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_STARTUP_LIVE"] == "1"))
    func actualDependencies() async {
        let checker = DependencyChecker()
        await checker.checkAll()
        #expect(checker.lastCheck != nil)
        #expect(!checker.isChecking)
        for dependency in Dependency.catalog {
            #expect(!checker.status(for: dependency.command).checking)
        }
        if checker.status(for: "nginx").installed {
            #expect(checker.status(for: "nginx").version?.isEmpty == false)
        }
    }

    @Test("Offline update checking has a silent fallback and remains retryable")
    func offlineUpdates() async {
        let checker = UpdateChecker()
        checker.repository = "test/startup"
        checker.fetchResponse = { _ in throw URLError(.notConnectedToInternet) }
        await checker.check(silently: true)
        #expect(checker.state == .idle)
        await checker.check()
        if case .failed = checker.state {} else { Issue.record("Manual offline check must explain its failure") }
    }

    @Test("Late update response arrives after the splash budget without a second request")
    func delayedUpdate() async {
        let checker = UpdateChecker()
        checker.repository = "test/startup"; checker.currentVersion = "2.0.0"
        var released = false, requests = 0
        checker.fetchResponse = { request in
            requests += 1
            while !released { try? await Task.sleep(for: .milliseconds(10)) }
            return (Data("2.0.0".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let work = StartupWork()
        #expect(await work.run(wait: 0.05) { await checker.check(silently: true) } == .timedOut)
        #expect(checker.state == .checking)
        await checker.check()
        #expect(requests == 1)
        released = true
        for _ in 0..<100 where !work.finished { try? await Task.sleep(for: .milliseconds(10)) }
        if case .upToDate = checker.state {} else { Issue.record("Late response did not reach the menu state") }
    }
}
