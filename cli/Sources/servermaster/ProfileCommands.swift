//
//  ProfileCommands.swift
//  servermaster
//
//  Creating and changing profiles from the terminal, so a project can be set up
//  without opening the window at all.
//
//  Every command that writes checks whether the app is running first. The app
//  holds its profiles in memory and saves the whole list, so an edit made here
//  while it is open would be silently overwritten later. Saying so is better
//  than losing someone's work and never mentioning it.
//

import Foundation

extension Commands {

    // MARK: - Looking at one

    func show() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        let profiles = ProfileStore.load()
        guard case .one(let profile) = ProfileStore.find(needle, in: profiles) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }

        let record = RunRegistry.find(profileID: profile.id)
        if options.json {
            var payload = ProfileStore.describe(profile, running: nil)
            payload["running"] = record != nil
            payload["pid"] = record.map { Int($0.pid) } as Any
            payload["problems"] = profile.validationIssues
            printer.json(payload.compactMapValues { $0 })
            return .ok
        }

        printer.line(profile.name)
        printer.line("  engine    \(profile.engine.title)")
        printer.line("  address   \(profile.address)")
        printer.line("  root      \(profile.rootPath)")
        if profile.engine.runsPHP {
            printer.line("  php       \(profile.phpVersion.isEmpty ? "whatever is in PATH" : profile.phpVersion)")
        }
        printer.line("  state     \(record == nil ? "stopped" : "running (pid \(record!.pid))")")
        let problems = profile.validationIssues
        if !problems.isEmpty {
            printer.line("  problems")
            for problem in problems { printer.line("    - \(problem)") }
        }
        return .ok
    }

    // MARK: - Templates

    func templates() async -> ExitCode {
        let all = ProfileTemplate.builtIn
        if options.json {
            printer.json(["templates": all.map {
                ["id": $0.id, "title": $0.title, "summary": $0.summary,
                 "engine": $0.settings.engine.rawValue, "needsDatabase": $0.needsDatabase,
                 "php": $0.phpVersion, "servesSubfolder": $0.rootHint as Any].compactMapValues { $0 }
            }])
            return .ok
        }
        var category: TemplateCategory?
        for template in all.sorted(by: { $0.category.rawValue < $1.category.rawValue }) {
            if template.category != category {
                category = template.category
                printer.line("")
                printer.line(template.category.title.uppercased())
            }
            printer.line("  \(template.id.padded(to: 16))\(template.summary)")
        }
        return .ok
    }

    // MARK: - Creating

    func new() async -> ExitCode {
        guard let templateID = options.first else {
            printer.error("Which template? Try: servermaster templates")
            return .usage
        }
        guard let template = ProfileTemplate.builtIn.first(where: { $0.id == templateID }) else {
            printer.result(false, "No template called “\(templateID)”.")
            return .notFound
        }
        guard let root = options.flag("root") else {
            printer.error("Where is the site? Add --root <folder>")
            return .usage
        }

        let expanded = AppPaths.expand(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            printer.result(false, "That folder does not exist: \(expanded)")
            return .usage
        }

        var profiles = ProfileStore.load()
        let name = options.flag("name") ?? uniqueName(template.title, in: profiles)
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            printer.result(false, "A profile called “\(name)” already exists.")
            return .usage
        }

        let port = options.integer("port") ?? ProfileStore.suggestPort(profiles: profiles)
        guard PortScanner.isPortFree(port, host: "127.0.0.1") else {
            printer.result(false, "Port \(port) is already in use.")
            return .unavailable
        }

        var profile = template.makeProfile(name: name, port: port, root: expanded)
        if let php = options.flag("php") { profile.phpVersion = php }
        if options.flag("https") != nil, profile.engine.supportsHTTPS { profile.httpsEnabled = true }

        profiles.append(profile)
        do {
            try ProfileStore.save(profiles)
        } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }

        warnIfAppRunning()
        printer.result(true, "Created \(profile.name) — \(profile.address)",
                       extra: ["profile": profile.name, "id": profile.id.uuidString,
                               "address": profile.address, "engine": profile.engine.rawValue])
        if template.rootHint != nil {
            printer.line("This kind of project usually serves its “\(template.rootHint!)” subfolder — check --root if it does not work.")
        }
        return .ok
    }

    func duplicate() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        var profiles = ProfileStore.load()
        guard case .one(let original) = ProfileStore.find(needle, in: profiles) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }
        var copy = original.duplicated()
        copy.name = options.flag("name") ?? uniqueName(original.name, in: profiles)
        copy.port = options.integer("port") ?? ProfileStore.suggestPort(profiles: profiles)

        profiles.append(copy)
        do { try ProfileStore.save(profiles) } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
        warnIfAppRunning()
        printer.result(true, "Copied to \(copy.name) — \(copy.address)",
                       extra: ["profile": copy.name, "address": copy.address])
        return .ok
    }

    // MARK: - Changing

    /// `servermaster set "My site" --port 9000 --php 8.3`
    func set() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        var profiles = ProfileStore.load()
        guard case .one(let found) = ProfileStore.find(needle, in: profiles),
              let index = profiles.firstIndex(where: { $0.id == found.id }) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }

        var profile = profiles[index]
        var changed: [String] = []

        if let value = options.flag("name"), !value.isEmpty { profile.name = value; changed.append("name") }
        if let value = options.integer("port") {
            guard value > 0, value < 65_536 else {
                printer.result(false, "A port has to be between 1 and 65535.")
                return .usage
            }
            profile.port = value; changed.append("port")
        }
        if let value = options.flag("root") { profile.rootPath = AppPaths.expand(value); changed.append("root") }
        if let value = options.flag("php") { profile.phpVersion = value; changed.append("php") }
        if let value = options.flag("index") { profile.indexFile = value; changed.append("index") }
        if let value = options.flag("host") { profile.host = value; changed.append("host") }
        if let value = options.flag("engine") {
            guard let engine = ServerEngine(rawValue: value) else {
                printer.result(false, "No engine called “\(value)”. One of: "
                               + ServerEngine.allCases.map(\.rawValue).joined(separator: ", "))
                return .usage
            }
            profile.engine = engine; changed.append("engine")
        }
        if let value = options.flag("https") { profile.httpsEnabled = (value != "false"); changed.append("https") }

        guard !changed.isEmpty else {
            printer.error("Nothing to change. Try --port, --root, --php, --engine, --name, --host, --index, --https")
            return .usage
        }

        profiles[index] = profile
        do { try ProfileStore.save(profiles) } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
        warnIfAppRunning()

        // Saying what is now wrong is more useful than a bare confirmation: a
        // changed root or engine is exactly how a profile stops being startable.
        let problems = profile.validationIssues
        printer.result(true, "Changed \(changed.joined(separator: ", ")) on \(profile.name)",
                       extra: ["profile": profile.name, "changed": changed, "problems": problems])
        if !problems.isEmpty, !options.json {
            for problem in problems { printer.line("  ! \(problem)") }
        }
        if RunRegistry.find(profileID: profile.id) != nil {
            printer.line("It is running — restart it for this to take effect: servermaster restart \(profile.name)")
        }
        return .ok
    }

    func delete() async -> ExitCode {
        guard let needle = options.first else {
            printer.error("Which profile? Try: servermaster list")
            return .usage
        }
        var profiles = ProfileStore.load()
        guard case .one(let profile) = ProfileStore.find(needle, in: profiles) else {
            printer.result(false, "No profile called “\(needle)”.")
            return .notFound
        }
        // Deleting is not undoable and the name may have been a prefix match, so
        // the full name has to be confirmed unless --yes was given.
        guard options.flag("yes") != nil else {
            printer.error("This removes “\(profile.name)” for good. Repeat with --yes to confirm.")
            return .usage
        }
        if let record = RunRegistry.find(profileID: profile.id) {
            _ = await RunRegistry.stop(record)
        }
        profiles.removeAll { $0.id == profile.id }
        do { try ProfileStore.save(profiles) } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
        warnIfAppRunning()
        printer.result(true, "Deleted \(profile.name)", extra: ["profile": profile.name])
        return .ok
    }

    // MARK: - Helpers

    func uniqueName(_ base: String, in profiles: [ServerProfile]) -> String {
        guard profiles.contains(where: { $0.name.caseInsensitiveCompare(base) == .orderedSame })
        else { return base }
        var counter = 2
        while profiles.contains(where: { $0.name.caseInsensitiveCompare("\(base) \(counter)") == .orderedSame }) {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    /// A note, not a refusal.
    ///
    /// The window and the terminal are independent: either works without the
    /// other, and neither blocks the other's work. What makes that safe is that
    /// the app watches this file and reloads when something else writes it, so
    /// an edit made here is picked up rather than overwritten.
    ///
    /// The note stays because the app may be mid-edit in its profile form, and
    /// knowing both were touched at once explains anything surprising.
    func warnIfAppRunning() {
        guard ProfileStore.appIsRunning, !options.json else { return }
        printer.line("Note: ServerMaster is open and was told to write anyway. Quit it without saving, or this change may still be overwritten.")
    }
}

extension String {
    /// Column padding for the plain-text listings.
    func padded(to width: Int) -> String {
        count >= width ? self + " " : padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
