//
//  ServiceCommands.swift
//  servermaster
//
//  The things around a server: the database, PHP versions, certificates and
//  ports. Everything the app's other screens do, without the screens.
//

import Foundation

extension Commands {

    // MARK: - Database

    func database() async -> ExitCode {
        let action = options.first ?? "status"
        let service = DatabaseService()

        switch action {
        case "start":
            // The database is one process for the whole machine, so starting it
            // here and using it from the app is the same instance.
            await service.start()
            guard service.state == .running else {
                printer.result(false, "The database did not start. " + service.log.tail(4))
                return .failed
            }
            printer.result(true, "Database running on \(service.connectionSummary)",
                           extra: ["host": service.host, "port": service.port,
                                   "socket": service.socketPath])
            return .ok

        case "stop":
            await service.stop()
            printer.result(true, "Database stopped.")
            return .ok

        case "status":
            let snapshot = ProfileStore.status()
            if options.json {
                printer.json(["running": snapshot.databaseRunning,
                              "port": service.port,
                              "adminPanel": snapshot.adminPanelAddress as Any].compactMapValues { $0 })
            } else {
                printer.line(snapshot.databaseRunning
                             ? "Running on \(service.connectionSummary)"
                             : "Stopped.")
            }
            return .ok

        case "list":
            await service.start()
            guard service.state == .running else {
                printer.result(false, "The database is not running.")
                return .unavailable
            }
            await service.reloadDatabases()
            if options.json {
                printer.json(["databases": service.databases.map { ["name": $0.name, "tables": $0.tables] }])
            } else {
                for entry in service.databases { printer.line("  \(entry.name)") }
            }
            return .ok

        case "create":
            guard let name = options.arguments.dropFirst().first else {
                printer.error("What should it be called? servermaster db create <name>")
                return .usage
            }
            await service.start()
            let user = options.flag("user") ?? name
            let password = options.flag("password") ?? DatabaseAdminPanel.generatedPassword(length: 16)
            let result = await service.createDatabase(name: name, user: user, password: password)
            guard result.succeeded else {
                printer.result(false, result.stderr.isEmpty ? "Could not create it." : result.stderr)
                return .failed
            }
            // The password is printed once, because it is generated here and
            // nowhere else — a CMS installer is about to ask for it.
            printer.result(true, "Created \(name)",
                           extra: ["database": name, "user": user, "password": password,
                                   "host": service.host, "port": service.port])
            if !options.json {
                printer.line("  user     \(user)")
                printer.line("  password \(password)")
                printer.line("  host     \(service.connectionSummary)")
            }
            return .ok

        case "drop":
            guard let name = options.arguments.dropFirst().first else {
                printer.error("Which one? servermaster db drop <name> --yes")
                return .usage
            }
            guard options.flag("yes") != nil else {
                printer.error("This deletes “\(name)” and everything in it. Repeat with --yes.")
                return .usage
            }
            await service.start()
            let result = await service.dropDatabase(name: name)
            printer.result(result.succeeded,
                           result.succeeded ? "Dropped \(name)" : result.stderr)
            return result.succeeded ? .ok : .failed

        default:
            printer.error("Unknown: db \(action). One of: start, stop, status, list, create, drop")
            return .usage
        }
    }

    // MARK: - PHP

    func php() async -> ExitCode {
        let action = options.first ?? "list"
        let checker = DependencyChecker()

        switch action {
        case "list":
            let installed = PHPVersions.scan()
            if options.json {
                printer.json(["installed": installed.map { ["version": $0.version, "default": $0.isDefault, "binary": $0.binary] },
                              "available": PHPVersions.known])
            } else {
                for version in PHPVersions.known {
                    let found = installed.first { $0.version == version }
                    let mark = found == nil ? "·" : "✓"
                    let suffix = found?.isDefault == true ? "  (in PATH)" : ""
                    printer.line("\(mark) PHP \(version)\(suffix)")
                }
            }
            return .ok

        case "install":
            guard let version = options.arguments.dropFirst().first else {
                printer.error("Which version? servermaster php install 8.3")
                return .usage
            }
            let log = ConsoleLog()
            let ok = await checker.installPHP(version: version, log: log)
            if !options.json, !options.quiet { print(log.tail(60)) }
            printer.result(ok, ok ? "PHP \(version) is ready." : "PHP \(version) did not install.")
            return ok ? .ok : .failed

        default:
            printer.error("Unknown: php \(action). One of: list, install")
            return .usage
        }
    }

    // MARK: - Certificates

    func certificates() async -> ExitCode {
        let action = options.first ?? "list"
        let manager = CertificateManager()
        await manager.refreshMkcertStatus()
        await manager.reload()

        switch action {
        case "list":
            if options.json {
                printer.json([
                    "trustedAuthority": manager.mkcert.trustedInSystem,
                    "certificates": manager.certificates.map {
                        ["name": $0.name, "trusted": manager.isTrusted($0),
                         "issuer": $0.issuer as Any, "expires": $0.notAfter as Any].compactMapValues { $0 }
                    }
                ])
            } else {
                printer.line(manager.mkcert.summary)
                for pair in manager.certificates {
                    printer.line("  \(manager.isTrusted(pair) ? "✓" : "!") \(pair.name)"
                                 + (manager.isTrusted(pair) ? "" : "  (the browser will warn)"))
                }
            }
            return .ok

        case "trust":
            // Adding the authority needs a password, and macOS asks for it in
            // its own window — which a terminal cannot show. Say so rather than
            // appearing to hang.
            guard let name = options.arguments.dropFirst().first else {
                printer.error("Which certificate? servermaster cert trust <name>")
                return .usage
            }
            let log = ConsoleLog()
            do {
                let pair = try await manager.makeTrustedCertificate(
                    name: CertificateManager.sanitizeName(name),
                    domains: ProfileStore.settings().certificateDefaultDomains,
                    log: log)
                printer.result(true, "\(pair.name) is ready and trusted.",
                               extra: ["certificate": pair.certificatePath, "key": pair.privateKeyPath])
                return .ok
            } catch {
                printer.result(false, error.localizedDescription)
                return .failed
            }

        default:
            printer.error("Unknown: cert \(action). One of: list, trust")
            return .usage
        }
    }

    // MARK: - Ports

    func killPort() async -> ExitCode {
        guard let port = options.integer("port") ?? options.first.flatMap(Int.init) else {
            printer.error("Which port? servermaster kill 8080")
            return .usage
        }
        let holders = await PortScanner.processesListening(onPort: port)
        guard !holders.isEmpty else {
            printer.result(true, "Nothing is listening on \(port).")
            return .ok
        }
        guard options.flag("yes") != nil else {
            let names = holders.map { "\($0.command) (\($0.pid))" }.joined(separator: ", ")
            printer.error("Port \(port) is held by \(names). Repeat with --yes to end it.")
            return .usage
        }
        var ended: [String] = []
        for holder in holders {
            let result = await PortScanner.kill(pid: holder.pid, signal: .term)
            if result.succeeded { ended.append("\(holder.command) (\(holder.pid))") }
        }
        printer.result(!ended.isEmpty, ended.isEmpty ? "Could not end it." : "Ended: \(ended.joined(separator: ", "))",
                       extra: ["ended": ended])
        return ended.isEmpty ? .failed : .ok
    }

    // MARK: - Opening

    func open() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        let profiles = ProfileStore.load()
        guard case .one(let profile) = ProfileStore.find(needle, in: profiles) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }
        guard let url = URL(string: profile.address) else {
            printer.result(false, "That profile has no usable address.")
            return .failed
        }
        if RunRegistry.find(profileID: profile.id) == nil {
            printer.line("It is not running — opening anyway.")
        }
        NSWorkspaceOpen(url)
        printer.result(true, "Opened \(profile.address)", extra: ["address": profile.address])
        return .ok
    }
}
