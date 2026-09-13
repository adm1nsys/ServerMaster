//
//  ProfileStore.swift
//  servermaster
//
//  Reading the profiles the app saved, and finding the one the user meant.
//
//  The tool deliberately does not run the app's AppModel: that pulls in SwiftUI,
//  a window and a whole lifecycle. It reads the same files and uses the same
//  launch logic, which is the part that has to agree.
//

import Foundation
import AppKit

enum ProfileStore {

    /// Where the app keeps them.
    static var profilesURL: URL {
        AppPaths.support.appendingPathComponent("profiles.json")
    }

    static func load() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data)
        else { return [] }
        return profiles
    }

    /// Writes the profile list back.
    ///
    /// The app keeps its own copy in memory, so a change made here while the app
    /// is open is overwritten the next time the app saves. Every command that
    /// writes says so rather than letting the edit quietly disappear.
    static func save(_ profiles: [ServerProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        AppPaths.ensure(AppPaths.support)
        try encoder.encode(profiles).write(to: profilesURL, options: .atomic)
    }

    /// Whether the app is running right now, which decides whether an edit made
    /// here will survive.
    static var appIsRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.adm1nsys.ServerMaster").isEmpty
    }

    /// A free port, skipping the ones profiles already claim.
    static func suggestPort(from start: Int = 8080, profiles: [ServerProfile]) -> Int {
        let taken = Set(profiles.map(\.port))
        var candidate = start
        while candidate < 65_535 {
            if !taken.contains(candidate), PortScanner.isPortFree(candidate, host: "127.0.0.1") {
                return candidate
            }
            candidate += 1
        }
        return start
    }

    static func settings() -> AppSettings {
        let url = AppPaths.support.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    /// Finds a profile by name, by the start of a name, or by id. Names are what
    /// a person types and ids are what a script stores, so both have to work.
    ///
    /// An ambiguous prefix is an error rather than a guess: starting the wrong
    /// server because two profiles begin with “test” is worse than being asked.
    enum Match {
        case one(ServerProfile)
        case none
        case ambiguous([ServerProfile])
    }

    static func find(_ needle: String, in profiles: [ServerProfile]) -> Match {
        if let exact = profiles.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
            return .one(exact)
        }
        if let byID = profiles.first(where: { $0.id.uuidString.lowercased() == needle.lowercased() }) {
            return .one(byID)
        }
        let prefix = profiles.filter { $0.name.lowercased().hasPrefix(needle.lowercased()) }
        switch prefix.count {
        case 0:  return .none
        case 1:  return .one(prefix[0])
        default: return .ambiguous(prefix)
        }
    }

    /// The version of the installed application. `AppInfo` reads Bundle.main,
    /// which for a command line tool is the tool itself, so the app has to be
    /// looked up where it lives.
    static func installedAppVersion() -> String? {
        let candidates = [
            "/Applications/ServerMaster.app",
            NSHomeDirectory() + "/Applications/ServerMaster.app"
        ]
        for path in candidates {
            let plist = path + "/Contents/Info.plist"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String
            else { continue }
            return version
        }
        return nil
    }

    /// What the app is currently running, as it last wrote it down.
    static func status() -> StatusSnapshot {
        StatusSnapshot.read()
    }

    static func describe(_ profile: ServerProfile, running: StatusSnapshot.Entry?) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.name,
            "engine": profile.engine.rawValue,
            "address": profile.address,
            "root": profile.rootPath,
            "port": profile.port,
            "phpVersion": profile.phpVersion,
            "state": running?.state ?? "stopped",
            "detail": running?.detail as Any
        ].compactMapValues { $0 }
    }
}
