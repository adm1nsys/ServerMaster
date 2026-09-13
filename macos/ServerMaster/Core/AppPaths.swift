//
//  AppPaths.swift
//  ServerMaster
//

import Foundation

/// Every place on disk the application uses.
nonisolated enum AppPaths {

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ServerMaster", isDirectory: true)
        ensure(dir)
        return dir
    }()

    static var profilesFile: URL { support.appendingPathComponent("profiles.json") }
    static var settingsFile: URL { support.appendingPathComponent("settings.json") }

    static var certificates: URL { subdir("Certificates") }
    static var configs: URL { subdir("Configs") }
    static var logs: URL { subdir("Logs") }

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// The one folder the app, the widget and the Safari extension can all
    /// reach.
    ///
    /// The extensions are sandboxed — they have to be, macOS will not register
    /// an extension that is not — so the app's own Application Support folder is
    /// invisible to them. A group container is the supported way through, and
    /// all three carry the group in their entitlements.
    ///
    /// Resolved through the container API when it works, and by path when it
    /// does not: the command line tool has no entitlements of its own, but it is
    /// not sandboxed either, so the plain path is open to it.
    static let shared: URL = {
        // The Team ID prefix is required on macOS: a group without it is not a
        // valid container for a sandboxed process, and `containerURL` answers
        // nil rather than complaining — which is why the widget and the Safari
        // extension both reported that the app had never run.
        let group = "88M5SYPGUR.com.adm1nsys.ServerMaster"
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) {
            ensure(container)
            return container
        }
        let byPath = home
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(group, isDirectory: true)
        ensure(byPath)
        return byPath
    }()

    static func subdir(_ name: String) -> URL {
        let dir = support.appendingPathComponent(name, isDirectory: true)
        ensure(dir)
        return dir
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Collapse a path to `~/…` for compact display.
    static func abbreviate(_ path: String) -> String {
        let h = NSHomeDirectory()
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// Expand `~` back into an absolute path.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

// MARK: - Tolerant JSON reading

nonisolated extension KeyedDecodingContainer {
    /// The value for a key, or the default if the key is absent or unreadable.
    /// Needed so a file from an older version of the application does not lose all
    /// of its contents because of one new field.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        // try? collapses the double optional: both a missing key and a read error
        // give nil — in either case the default is used.
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded
    }
}
