//
//  Menu.swift
//  servermaster
//
//  The screen the interactive tool opens on.
//
//  It mirrors the sections of the Mac application rather than inventing its own
//  arrangement: someone who has used the window should find the same things in
//  the same order, and someone who has only ever used the terminal should be
//  able to open the window and recognise it. One idea of what this program is,
//  in two shapes.
//
//  Sections that are not wired up yet are shown, not hidden. Hiding them would
//  make the terminal look like a smaller product than it is, and a menu that
//  grows items later is a menu people have to relearn.
//

import Foundation

nonisolated struct MenuItem: Identifiable, Sendable {

    /// What pressing it does.
    enum Destination: Sendable {
        case screen(String)
        /// Built, but not connected to the interactive screen yet.
        case notYet
    }

    var id: String
    var title: String
    var subtitle: String
    /// The single key that jumps straight here.
    var key: Character
    var destination: Destination
    var group: Group

    enum Group: String, CaseIterable, Sendable {
        case server = "Server"
        case configuration = "Configuration"
    }

    var isReady: Bool {
        if case .notYet = destination { return false }
        return true
    }
}

nonisolated enum Menu {

    static let items: [MenuItem] = [
        MenuItem(id: "control", title: "Control",
                 subtitle: "Start and stop, see what is running",
                 key: "c", destination: .screen("profiles"), group: .server),
        MenuItem(id: "logs", title: "Logs",
                 subtitle: "What a server is writing right now",
                 key: "l", destination: .screen("logs"), group: .server),
        MenuItem(id: "database", title: "Database",
                 subtitle: "MariaDB, its databases and the admin panel",
                 key: "d", destination: .screen("services"), group: .server),
        MenuItem(id: "ports", title: "Ports",
                 subtitle: "Who is listening, and how to free a port",
                 key: "p", destination: .screen("ports"), group: .server),
        MenuItem(id: "files", title: "Files",
                 subtitle: "Hidden files and the ones worth editing",
                 key: "f", destination: .notYet, group: .server),

        MenuItem(id: "profiles", title: "Profiles",
                 subtitle: "Create one, change it, remove it",
                 key: "r", destination: .screen("templates"), group: .configuration),
        MenuItem(id: "dependencies", title: "Dependencies",
                 subtitle: "What is installed and what is missing",
                 key: "e", destination: .screen("dependencies"), group: .configuration),
        MenuItem(id: "backups", title: "Backups",
                 subtitle: "Snapshots of a profile, and rolling one back",
                 key: "b", destination: .notYet, group: .configuration),
        MenuItem(id: "diagnostics", title: "Diagnostics",
                 subtitle: "What is wrong when everything looks installed",
                 key: "g", destination: .notYet, group: .configuration),
        MenuItem(id: "web", title: "Web interface",
                 subtitle: "The same control panel in a browser",
                 key: "w", destination: .screen("web"), group: .configuration),
        MenuItem(id: "settings", title: "Settings",
                 subtitle: "Defaults, ports and the environment",
                 key: "s", destination: .screen("settings"), group: .configuration),
        MenuItem(id: "about", title: "About",
                 subtitle: "Version, where things live, and the guide",
                 key: "a", destination: .screen("help"), group: .configuration)
    ]

    static func items(in group: MenuItem.Group) -> [MenuItem] {
        items.filter { $0.group == group }
    }

    static func item(forKey key: Character) -> MenuItem? {
        items.first { $0.key == key }
    }
}
