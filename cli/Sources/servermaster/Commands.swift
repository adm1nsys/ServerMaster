//
//  Commands.swift
//  servermaster
//
//  What the tool can do. Each command is small on purpose: an agent chains them,
//  so every one has to be independently meaningful and independently checkable.
//

import Foundation

struct Commands {

    let printer: Printer
    let options: Options

    // MARK: - Listing and status

    func list() async -> ExitCode {
        let profiles = ProfileStore.load()
        let snapshot = ProfileStore.status()

        if options.json {
            printer.json([
                "profiles": profiles.map { profile in
                    ProfileStore.describe(profile,
                                          running: snapshot.profiles.first { $0.id == profile.id.uuidString })
                }
            ])
            return .ok
        }

        guard !profiles.isEmpty else {
            printer.line("No profiles. Create one in ServerMaster.")
            return .ok
        }
        for profile in profiles {
            let state = snapshot.profiles.first { $0.id == profile.id.uuidString }?.state ?? "stopped"
            let mark = state == "running" ? "●" : (state == "failed" ? "✗" : "○")
            printer.line("\(mark) \(profile.name.padding(toLength: max(24, profile.name.count), withPad: " ", startingAt: 0)) \(profile.address)")
        }
        return .ok
    }

    func status() async -> ExitCode {
        let snapshot = ProfileStore.status()
        // The registry is the live truth: it holds what is running right now,
        // whoever started it. The app's snapshot only says what the window knew
        // when it last wrote it down.
        let running = RunRegistry.all()

        if options.json {
            printer.json([
                "updated": ISO8601DateFormatter().string(from: snapshot.updated),
                "running": running.count,
                "servers": running.map {
                    ["name": $0.name, "address": $0.address, "pid": Int($0.pid),
                     "startedBy": $0.origin.rawValue]
                },
                "databaseRunning": snapshot.databaseRunning,
                "adminPanel": snapshot.adminPanelAddress as Any,
                "profiles": snapshot.profiles.map {
                    ["name": $0.name, "address": $0.address, "state": $0.state,
                     "detail": $0.detail as Any].compactMapValues { $0 }
                }
            ].compactMapValues { $0 })
            return .ok
        }

        // The snapshot is written by the app. Without it we know nothing, and
        // saying "nothing is running" would be a guess dressed as a fact.
        if snapshot.updated == .distantPast {
            printer.line("ServerMaster has not run yet, so there is nothing to report.")
            return .ok
        }

        printer.line(running.isEmpty ? "Nothing is running." : "Running: \(running.count)")
        for record in running {
            printer.line("  \(record.name) — \(record.address) — pid \(record.pid)"
                         + " — started in the \(record.origin == .app ? "app" : "terminal")")
        }
        for entry in snapshot.profiles where entry.state == "failed" {
            printer.line("  \(entry.name) — failed" + (entry.detail.map { ": \($0)" } ?? ""))
        }
        if snapshot.databaseRunning { printer.line("  database — running") }
        return .ok
    }

    // MARK: - Running a profile

    func start() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        let profiles = ProfileStore.load()
        switch ProfileStore.find(needle, in: profiles) {
        case .none:
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        case .ambiguous(let matches):
            printer.result(false, "“\(needle)” matches several profiles: "
                           + matches.map(\.name).joined(separator: ", "),
                           extra: ["matches": matches.map(\.name)])
            return .usage
        case .one(var profile):
            if let port = options.integer("port") { profile.port = port }

            // Refuse early rather than half-starting: the reasons here are the
            // ones a person would otherwise meet as a wall of engine output.
            let problems = profile.validationIssues
            if !problems.isEmpty, options.flag("force") == nil {
                printer.result(false, "The profile is not ready: " + problems.joined(separator: "; "),
                               extra: ["problems": problems])
                return .failed
            }
            guard PortScanner.isPortFree(profile.port, host: profile.host) else {
                printer.result(false, "Port \(profile.port) is already in use.")
                return .unavailable
            }

            let logPath = AppPaths.subdir("Logs").appendingPathComponent(
                "\(profile.name)-cli.log").path

            if options.wait {
                // Attached: the server belongs to this terminal, and Ctrl-C ends
                // it. Nothing is written to the registry because nothing outlives
                // the command.
                let controller = ServerController()
                await controller.start(profile: profile, settings: ProfileStore.settings())
                if case .failed(let message) = controller.state {
                    printer.result(false, message, extra: ["profile": profile.name])
                    return .failed
                }
                printer.result(true, "Started \(profile.name) on \(profile.address)",
                               extra: ["profile": profile.name, "address": profile.address,
                                       "attached": true])
                printer.line("Running. Press Ctrl-C to stop.")
                await waitForSignal(controller)
                return .ok
            }

            // Detached: it has to survive this process, so it is spawned into a
            // session of its own and written into the registry — that record is
            // what lets the app and `servermaster stop` find it afterwards.
            do {
                let plan = try LaunchPlanBuilder.build(for: profile)
                try DetachedLauncher.prepare(plan, profile: profile)
                _ = try DetachedLauncher.launchSidecars(plan, logPath: logPath)
                let pid = try DetachedLauncher.launch(plan, logPath: logPath)

                // A process that exits immediately is a failed start, not a
                // successful one — saying "started" here would be a lie the
                // person discovers in the browser.
                try await Task.sleep(for: .milliseconds(700))
                guard kill(pid, 0) == 0 || errno == EPERM else {
                    let tail = (try? String(contentsOfFile: logPath, encoding: .utf8))?
                        .split(separator: "\n").suffix(4).joined(separator: " ") ?? ""
                    printer.result(false, "It started and stopped immediately. \(tail)",
                                   extra: ["profile": profile.name, "log": logPath])
                    return .failed
                }

                RunRegistry.record(RunRecord(id: profile.id.uuidString,
                                             name: profile.name,
                                             address: profile.address,
                                             port: profile.port,
                                             pid: pid,
                                             origin: .commandLine,
                                             startedAt: Date()))

                printer.result(true, "Started \(profile.name) on \(profile.address)",
                               extra: ["profile": profile.name, "address": profile.address,
                                       "pid": Int(pid), "log": logPath, "attached": false])
                return .ok
            } catch {
                printer.result(false, error.localizedDescription, extra: ["profile": profile.name])
                return .failed
            }
        }
    }

    func stop() async -> ExitCode {
        let running = RunRegistry.all()

        // No name given stops everything, which is what a teardown script wants.
        guard let needle = options.first else {
            guard !running.isEmpty else {
                printer.result(true, "Nothing is running.")
                return .ok
            }
            var stopped: [String] = []
            for record in running where await RunRegistry.stop(record) == .stopped {
                stopped.append(record.name)
            }
            printer.result(true, "Stopped: \(stopped.joined(separator: ", "))",
                           extra: ["stopped": stopped])
            return .ok
        }

        let profiles = ProfileStore.load()
        switch ProfileStore.find(needle, in: profiles) {
        case .none:
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        case .ambiguous(let matches):
            printer.result(false, "“\(needle)” matches several profiles: "
                           + matches.map(\.name).joined(separator: ", "),
                           extra: ["matches": matches.map(\.name)])
            return .usage
        case .one(let profile):
            guard let record = RunRegistry.find(profileID: profile.id) else {
                printer.result(false, "\(profile.name) is not running.")
                return .ok
            }
            switch await RunRegistry.stop(record) {
            case .stopped:
                printer.result(true, "Stopped \(profile.name)",
                               extra: ["profile": profile.name,
                                       "startedBy": record.origin.rawValue])
                return .ok
            case .notRunning:
                printer.result(false, "\(profile.name) is not running.")
                return .ok
            case .refused(let message):
                printer.result(false, message)
                return .failed
            }
        }
    }

    func restart() async -> ExitCode {
        let code = await stop()
        guard code == .ok else { return code }
        try? await Task.sleep(for: .milliseconds(500))
        return await start()
    }

    func logs() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        let profiles = ProfileStore.load()
        guard case .one(let profile) = ProfileStore.find(needle, in: profiles) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }
        let path = AppPaths.subdir("Logs").appendingPathComponent("\(profile.name)-cli.log").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            printer.result(false, "No log for \(profile.name) yet.", extra: ["path": path])
            return .notFound
        }
        let lines = options.integer("lines") ?? 40
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines) {
            print(line)
        }
        return .ok
    }

    // MARK: - Environment

    func doctor() async -> ExitCode {
        let checker = DependencyChecker()
        await checker.checkAll()

        var report: [[String: Any]] = []
        var missing = 0
        for dependency in Dependency.catalog {
            let status = checker.status(for: dependency.command)
            if dependency.required && !status.installed { missing += 1 }
            report.append([
                "name": dependency.title,
                "command": dependency.command,
                "installed": status.installed,
                "required": dependency.required,
                "version": status.version as Any,
                "install": dependency.installCommand
            ].compactMapValues { $0 })
        }

        if options.json {
            printer.json(["missing": missing, "dependencies": report,
                          "php": PHPVersions.scan().map { ["version": $0.version, "default": $0.isDefault] }])
        } else {
            for entry in report {
                let ok = entry["installed"] as? Bool == true
                let required = entry["required"] as? Bool == true
                let mark = ok ? "✓" : (required ? "✗" : "·")
                printer.line("\(mark) \(entry["name"] as? String ?? "")"
                             + (ok ? "" : "   → \(entry["install"] as? String ?? "")"))
            }
            let versions = PHPVersions.scan().map(\.version)
            printer.line(versions.isEmpty ? "PHP: none found"
                                          : "PHP: \(versions.joined(separator: ", "))")
        }
        return missing == 0 ? .ok : .unavailable
    }

    func ports() async -> ExitCode {
        let entries = await PortScanner.scan(includeUDP: false)
        if options.json {
            printer.json(["ports": entries.map {
                ["port": $0.port, "address": $0.address, "process": $0.command, "pid": $0.pid]
            }])
        } else {
            for entry in entries.sorted(by: { $0.port < $1.port }) {
                printer.line("\(entry.port)\t\(entry.command) (\(entry.pid))")
            }
        }
        return .ok
    }

    // MARK: - Waiting

    /// Keeps the process alive while the server runs, and stops it cleanly on
    /// Ctrl-C. Without this the child would be orphaned and keep the port.
    private func waitForSignal(_ controller: ServerController) async {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        let stopped = Stopper()

        source.setEventHandler {
            Task { @MainActor in
                await controller.stop(settings: ProfileStore.settings())
                await stopped.finish()
            }
        }
        source.resume()

        while await !stopped.isDone {
            if !controller.state.isActive { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        source.cancel()
    }

    private actor Stopper {
        private(set) var isDone = false
        func finish() { isDone = true }
    }
}
