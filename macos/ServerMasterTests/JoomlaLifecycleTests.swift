import Foundation
import Testing
import Darwin
@testable import ServerMaster

@Suite("Private runtime port reservations")
struct RuntimePortLeaseTests {
    @Test("TIME_WAIT is not a hidden listener; IPv4 and IPv6 listeners remain visible")
    func listenerStates() {
        let entries = PortScanner.parseNetstatListeners("""
        tcp4 0 0 127.0.0.1.8082 *.* LISTEN
        tcp6 0 0 ::1.8083 *.* LISTEN
        tcp4 0 0 127.0.0.1.9000 127.0.0.1.50000 TIME_WAIT
        tcp4 0 0 *.443 *.* LISTEN
        """)
        #expect(entries.map(\.port) == [8082, 8083, 443])
        #expect(entries.map(\.address) == ["127.0.0.1", "::1", "*"])
    }

    @Test("Plans reserve distinct ports even before children start")
    func simultaneousReservations() throws {
        let leases = try (0..<40).map { _ in try RuntimePortLease.acquire(excluding: 8082) }
        #expect(Set(leases.map(\.port)).count == leases.count)
        for lease in leases {
            #expect(!PortScanner.isPortFree(lease.port, host: "127.0.0.1"))
            lease.allowChildBind()
        }
        let more = try (0..<40).map { _ in try RuntimePortLease.acquire(excluding: 8082) }
        #expect(Set(leases.map(\.port)).isDisjoint(with: more.map(\.port)))
    }
}

/// Official, unpacked CMS fixtures are supplied explicitly. No user site, DB,
/// package installation or persistent profile is changed by this suite.
@MainActor
@Suite("Parallel Joomla live lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_JOOMLA_ROOT"] != nil))
struct JoomlaLifecycleTests {
    private var settings: AppSettings {
        var value = AppSettings()
        value.writeLogsToFile = false
        value.openBrowserOnStart = false
        return value
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("joomla-t2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func profile(_ major: Int, engine: ServerEngine) throws -> ServerProfile {
        let base = try #require(ProcessInfo.processInfo.environment["SERVERMASTER_TEST_JOOMLA_ROOT"])
        var profile = ServerProfile()
        profile.name = "T2 Joomla \(major)"
        profile.engine = engine
        profile.host = "127.0.0.1"
        profile.rootPath = base + "/joomla\(major)"
        profile.phpVersion = major == 5 ? "8.2" : "8.3"
        profile.port = try BuiltinHTTPS.freeBackendPort(excluding: 0)
        #expect(PhpSiteCompatibility.isJoomla(root: profile.rootPath))
        try "<?php echo 'T2 Joomla \(major) PHP '.PHP_VERSION;".write(
            toFile: profile.rootPath + "/servermaster-t2-probe.php", atomically: true, encoding: .utf8)
        return profile
    }

    private func request(_ profile: ServerProfile, path: String, follow: Bool = false) async -> CommandResult {
        await ProcessRunner.run("/usr/bin/curl", ["--silent", "--show-error", "--noproxy", "*",
            "--max-time", "8"] + (follow ? ["--location", "--max-redirs", "5"] : []) +
            ["--write-out", "\n%{http_code}", "http://127.0.0.1:\(profile.port)\(path)"])
    }

    private func verify(_ profile: ServerProfile, major: Int) async {
        let probe = await request(profile, path: "/servermaster-t2-probe.php")
        #expect(probe.succeeded && probe.stdout.contains("T2 Joomla \(major) PHP \(profile.phpVersion)."), "\(probe.combined)")
        let installer = await request(profile, path: "/installation/", follow: true)
        #expect(installer.succeeded && installer.stdout.hasSuffix("200"), "Installer HTTP response: \(installer.combined.suffix(1500))")
        #expect(installer.stdout.contains("Joomla"))
        #expect(!installer.stdout.contains("unsupported PHP"))
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return condition()
    }

    private func released(_ ports: [Int]) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            var occupied = false
            for port in ports {
                if !(await PortScanner.processesListening(onPort: port)).isEmpty { occupied = true }
            }
            if !occupied { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    @Test("Concurrent start, stop, restart, quit and failure preserve the other site")
    func controllers() async throws {
        let runtime = try directory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let five = try profile(5, engine: .apachePHP)
        let six = try profile(6, engine: .apachePHP)
        let a = ServerController(runtimeRoot: runtime)
        let b = ServerController(runtimeRoot: runtime)
        defer { a.stopImmediately(); b.stopImmediately() }
        async let startA: Void = a.start(profile: five, settings: settings)
        async let startB: Void = b.start(profile: six, settings: settings)
        _ = await (startA, startB)
        #expect(a.state == .running, "\(a.log.plainText)")
        #expect(b.state == .running, "\(b.log.plainText)")
        guard a.state == .running, b.state == .running else { return }
        await verify(five, major: 5)
        await verify(six, major: 6)
        var duplicate = five
        duplicate.id = UUID()
        duplicate.port = six.port
        let intruder = ServerController(runtimeRoot: runtime)
        defer { intruder.stopImmediately() }
        await intruder.start(profile: duplicate, settings: settings)
        #expect(!intruder.state.isActive, "An occupied port must not be treated as this profile's readiness")
        await verify(six, major: 6)
        #expect(!(await PortScanner.processesListening(onPort: five.port)).isEmpty)
        await a.stop(settings: settings)
        #expect(PortScanner.isPortFree(five.port, host: five.host))
        await verify(six, major: 6)
        await a.start(profile: five, settings: settings)
        await verify(five, major: 5)
        await b.restart(profile: six, settings: settings)
        await verify(five, major: 5)
        await verify(six, major: 6)

        // Kill only this profile's Apache master. The supervisor must reap
        // its PHP-FPM and Apache workers, without touching Joomla 6.
        let pidPath = runtime.appendingPathComponent("apache-\(five.id.uuidString)/httpd.pid").path
        let apachePID = try #require(PrivilegedLauncher.readPID(pidPath))
        #expect(kill(apachePID, SIGTERM) == 0)
        #expect(await wait { !a.state.isActive })
        #expect(PortScanner.isPortFree(five.port, host: five.host))
        await verify(six, major: 6)
        await a.start(profile: five, settings: settings)
        await verify(five, major: 5)
        a.stopImmediately()
        b.stopImmediately()
        #expect(await wait { PortScanner.isPortFree(five.port, host: five.host) && PortScanner.isPortFree(six.port, host: six.host) })
        // New controllers model opening the app again after an orderly quit.
        let reopened = ServerController(runtimeRoot: runtime)
        defer { reopened.stopImmediately() }
        await reopened.start(profile: five, settings: settings)
        #expect(reopened.state == .running, "\(reopened.log.plainText)")
        await verify(five, major: 5)
    }

    @Test("Built-in router preserves installation, administrator and API queries")
    func builtinRouter() async throws {
        let runtime = try directory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        for major in [5, 6] {
            let profile = try profile(major, engine: .phpBuiltIn)
            let controller = ServerController(runtimeRoot: runtime)
            defer { controller.stopImmediately() }
            await controller.start(profile: profile, settings: settings)
            #expect(controller.state == .running, "\(controller.log.plainText)")
            guard controller.state == .running else { return }
            await verify(profile, major: major)
            for entry in ["installation", "administrator", "api"] {
                let redirect = await ProcessRunner.run("/usr/bin/curl", ["--silent", "--noproxy", "*", "--max-time", "5",
                    "--output", "/dev/null", "--write-out", "%{http_code} %{redirect_url}",
                    "http://127.0.0.1:\(profile.port)/\(entry)/index.php?option=test&value=one%20two"])
                #expect(redirect.stdout == "307 http://127.0.0.1:\(profile.port)/\(entry)/?option=test&value=one%20two")
            }
            await controller.stop(settings: settings)
            #expect(PortScanner.isPortFree(profile.port, host: profile.host))
        }
    }

    @Test("Watchdog/adoption retains both runtimes and stops only its profile")
    func watchdogAdoption() async throws {
        let runtime = try directory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let five = try profile(5, engine: .apachePHP)
        let six = try profile(6, engine: .apachePHP)
        let profiles = [five, six]
        var plans: [LaunchPlan] = []
        var sessions: [PrivilegedSession] = []
        var processes: [Process] = []
        var commands: [String] = []
        var scripts: [String] = []
        let root = ProcessInfo.processInfo.environment["SERVERMASTER_TEST_JOOMLA_ADMIN"] == "1"
        let trace = ProcessInfo.processInfo.environment["SERVERMASTER_TEST_JOOMLA_TRACE"] == "1"
        let coordinatorLock = runtime.appendingPathComponent("coordinator.lock").path
        let restartRequest = runtime.appendingPathComponent("restart.request").path
        let crashRequest = runtime.appendingPathComponent("crash.request").path
        defer {
            for session in sessions { PrivilegedLauncher.requestStop(session) }
            try? FileManager.default.removeItem(atPath: coordinatorLock)
            // Keep control-file directories until the watchdogs finish. Removing
            // them first prevents an elevated supervisor from receiving stop.
            let deadline = Date().addingTimeInterval(9)
            while sessions.contains(where: { !PrivilegedLauncher.hasStopped($0) }) && Date() < deadline { usleep(100_000) }
            for process in processes where process.isRunning { process.terminate() }
        }
        for profile in profiles {
            let plan = try LaunchPlanBuilder.build(for: profile, runtimeRoot: runtime)
            plans.append(plan)
            for file in plan.extraFiles + (plan.generatedConfig.map { [$0] } ?? []) {
                let contents = trace && file.path.hasSuffix(".sh")
                    ? file.contents.replacingOccurrences(of: "set -m", with: "set -mx") : file.contents
                try contents.write(toFile: file.path, atomically: true, encoding: .utf8)
            }
            let prefix = runtime.appendingPathComponent("root-\(profile.id.uuidString.prefix(8))").path
            try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
            let session = PrivilegedSession(serverPID: 0, logPath: prefix + "/privileged.log",
                sentinelPath: prefix + "/running.lock", pidPath: prefix + "/server.pid")
            sessions.append(session)
            FileManager.default.createFile(atPath: session.logPath, contents: Data())
            FileManager.default.createFile(atPath: session.sentinelPath, contents: Data())
            let script = prefix + "/launch.sh"
            scripts.append(script)
            let watchdog = PrivilegedLauncher.script(plan: plan, logPath: session.logPath, sentinelPath: session.sentinelPath, pidPath: session.pidPath)
            try (trace ? watchdog.replacingOccurrences(of: "set -m", with: "set -mx") : watchdog)
                .write(toFile: script, atomically: true, encoding: .utf8)
            for lease in plan.portLeases { lease.allowChildBind() }
            if root { commands.append("/bin/bash " + ProcessRunner.shellQuote(script) + " >>" + ProcessRunner.shellQuote(session.logPath) + " 2>&1 </dev/null &") }
            else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                processes.append(process)
            }
        }
        if root {
            // One authorization covers the whole test. Only these fixed fixture
            // commands are run; no command text is read from request files.
            FileManager.default.createFile(atPath: coordinatorLock, contents: Data())
            let q = ProcessRunner.shellQuote
            let coordinator = runtime.appendingPathComponent("coordinator.sh").path
            let fpmPath = runtime.appendingPathComponent("apache-\(five.id.uuidString)/php-fpm.pid").path
            let control = """
            #!/bin/bash
            while [ -e \(q(coordinatorLock)) ] && [ "$SECONDS" -lt 90 ]; do
                if [ -e \(q(restartRequest)) ]; then
                    /bin/rm -f \(q(restartRequest))
                    /bin/bash \(q(scripts[0])) >>\(q(sessions[0].logPath)) 2>&1 </dev/null &
                fi
                if [ -e \(q(crashRequest)) ]; then
                    /bin/rm -f \(q(crashRequest))
                    pid=$(/bin/cat \(q(fpmPath)))
                    case "$pid" in ''|*[!0-9]*) ;; *) kill -KILL "$pid" ;; esac
                fi
                /bin/sleep 0.1
            done
            /bin/rm -f \(q(sessions[0].sentinelPath)) \(q(sessions[1].sentinelPath))
            """
            try control.write(toFile: coordinator, atomically: true, encoding: .utf8)
            commands.append("/bin/bash " + q(coordinator) + " >/dev/null 2>&1 </dev/null &")
            let authorized = await ProcessRunner.runAsAdmin(commands.joined(separator: "\n"), prompt: "ServerMaster: isolated parallel Joomla lifecycle test", timeout: 55)
            try #require(authorized.succeeded, "\(authorized.combined)")
        }
        for index in profiles.indices {
            #expect(await wait { FileManager.default.fileExists(atPath: plans[index].readinessFile!) },
                "\((try? String(contentsOfFile: sessions[index].logPath, encoding: .utf8)) ?? "No log")")
            sessions[index].serverPID = try #require(PrivilegedLauncher.readPID(sessions[index].pidPath))
            if root {
                let owner = await ProcessRunner.run("/bin/ps", ["-p", String(sessions[index].serverPID), "-o", "uid="])
                #expect(owner.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
            await verify(profiles[index], major: index == 0 ? 5 : 6)
        }
        // Simulates reattachment after the previous app instance disappeared:
        // only the persisted session is needed, not an in-memory FPM Process.
        let discovered = PrivilegedLauncher.findOrphans(in: runtime)
        #expect(discovered.count == 2)
        let recovered = try #require(discovered.first { $0.profileKey == String(five.id.uuidString.prefix(8)) })
        let adopted = ServerController()
        adopted.adopt(session: recovered.session, profile: five, settings: settings)
        #expect(adopted.state == .running)
        #expect(adopted.isPrivileged)
        await verify(five, major: 5)
        await adopted.stop(settings: settings)
        #expect(await released([five.port, plans[0].portLeases[0].port]))
        await verify(six, major: 6)

        // Restart the same elevated plan while the other profile stays live.
        let plan = plans[0]
        try? FileManager.default.removeItem(atPath: plan.readinessFile! + ".stop")
        try? FileManager.default.removeItem(atPath: plan.readinessFile!)
        FileManager.default.createFile(atPath: sessions[0].sentinelPath, contents: Data())
        let script = scripts[0]
        if root {
            FileManager.default.createFile(atPath: restartRequest, contents: Data())
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
        }
        #expect(await wait { FileManager.default.fileExists(atPath: plan.readinessFile!) })
        sessions[0].serverPID = try #require(PrivilegedLauncher.readPID(sessions[0].pidPath))
        await verify(five, major: 5)
        await verify(six, major: 6)
        let fpmPID = try #require(PrivilegedLauncher.readPID(runtime.appendingPathComponent("apache-\(five.id.uuidString)/php-fpm.pid").path))
        if root {
            FileManager.default.createFile(atPath: crashRequest, contents: Data())
        } else { #expect(kill(fpmPID, SIGKILL) == 0) }
        #expect(await released([five.port, plan.portLeases[0].port]))
        await verify(six, major: 6)
        let other = ServerController()
        other.adopt(session: sessions[1], profile: six, settings: settings)
        #expect(other.state == .running)
        other.stopImmediately()
        #expect(await released([six.port, plans[1].portLeases[0].port]))
        #expect(await wait { sessions.allSatisfy { !FileManager.default.fileExists(atPath: $0.pidPath) } })
        withExtendedLifetime(plans) {}
    }
}
