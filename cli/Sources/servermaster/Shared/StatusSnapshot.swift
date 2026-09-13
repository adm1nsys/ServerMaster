//
//  StatusSnapshot.swift
//  ServerMaster
//
//  What is running, written to disk so something outside the app can read it.
//  The widget lives in its own process and cannot see the app's memory, so the
//  app leaves a small file behind every time the picture changes.
//
//  Deliberately tiny and deliberately dumb: names, addresses, states. No paths,
//  no passwords, no configuration. If this file leaked it would tell someone
//  which ports are open on this Mac, which they could have found with lsof
//  anyway.
//
//  The widget target carries its own copy of these types — an extension cannot
//  share code with the app without project surgery. `snapshotContract` in the
//  tests pins the JSON shape so the two cannot drift apart unnoticed.
//

import Foundation

nonisolated struct StatusSnapshot: Codable, Sendable, Equatable {

    nonisolated struct Entry: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var address: String
        /// "running", "starting", "stopped", "failed"
        var state: String
        var detail: String?
    }

    var updated: Date
    var profiles: [Entry]
    var databaseRunning: Bool
    var adminPanelAddress: String?

    static let empty = StatusSnapshot(updated: .distantPast, profiles: [],
                                      databaseRunning: false, adminPanelAddress: nil)

    // MARK: - Where it lives

    /// In the group container, which is the only folder the sandboxed
    /// extensions can see. See `AppPaths.shared`.
    static var fileURL: URL {
        AppPaths.shared.appendingPathComponent("status.json")
    }

    /// Where it used to live. Read as a fallback so a widget added before this
    /// moved does not go blank until the app next writes.
    static var legacyFileURL: URL {
        AppPaths.support.appendingPathComponent("status.json")
    }

    // MARK: - Reading and writing

    static func read() -> StatusSnapshot {
        let data = (try? Data(contentsOf: fileURL)) ?? (try? Data(contentsOf: legacyFileURL))
        guard let data,
              let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: StatusSnapshot.fileURL, options: .atomic)
    }
}
