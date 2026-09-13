//
//  RunRegistry.swift
//  ServerMaster
//
//  A record on disk of every server that is running, written by whoever started
//  it — the window or the terminal.
//
//  Without this the two cannot be peers. The app knows its own child processes
//  and nothing else; the command line tool knew even less and had to refuse to
//  stop anything. Neither could see the other's work, so “start it in the
//  terminal, stop it in the app” was impossible, which is the whole point of
//  having both.
//
//  One file per running server, named by profile. A file whose process is gone
//  is not a record, it is litter, and is cleared on the next read: a machine
//  that lost power leaves these behind and nobody should have to know that.
//

import Foundation

nonisolated struct RunRecord: Codable, Sendable, Identifiable, Equatable {

    /// Who started it, so each side can tell its own work from the other's.
    enum Origin: String, Codable, Sendable {
        case app
        case commandLine
    }

    var id: String            // the profile's UUID string
    var name: String
    var address: String
    var port: Int
    var pid: Int32
    var origin: Origin
    var startedAt: Date

    /// Whether the process behind this record is still there. kill(pid, 0) does
    /// not kill; EPERM means it exists but belongs to someone else, which for
    /// this purpose still counts as alive.
    var isAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

nonisolated enum RunRegistry {

    static var directory: URL {
        AppPaths.support.appendingPathComponent("Runtime/running", isDirectory: true)
    }

    private static func file(for id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    // MARK: - Writing

    static func record(_ entry: RunRecord) {
        AppPaths.ensure(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: file(for: entry.id), options: .atomic)
    }

    static func forget(_ id: String) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    static func forget(_ id: UUID) { forget(id.uuidString) }

    // MARK: - Reading

    /// Everything currently running, with dead records cleared away.
    static func all() -> [RunRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else { return [] }
        var alive: [RunRecord] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(RunRecord.self, from: data)
            else {
                try? fm.removeItem(at: url)          // unreadable is not useful
                continue
            }
            if record.isAlive {
                alive.append(record)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        return alive.sorted { $0.startedAt < $1.startedAt }
    }

    static func find(profileID: UUID) -> RunRecord? {
        all().first { $0.id == profileID.uuidString }
    }

    // MARK: - Stopping

    enum StopResult: Equatable {
        case stopped
        case notRunning
        case refused(String)
    }

    /// Ends the process behind a record, gently first.
    ///
    /// Works whichever side started it: a server is a process, and the record
    /// says which one. What this deliberately does not do is guess — if the pid
    /// is gone the answer is “not running”, never “probably fine”.
    static func stop(_ record: RunRecord, timeout: TimeInterval = 8) async -> StopResult {
        guard record.isAlive else {
            forget(record.id)
            return .notRunning
        }

        if kill(record.pid, SIGTERM) != 0, errno == EPERM {
            return .refused(String(localized: "That server belongs to another user and cannot be stopped from here."))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !record.isAlive { break }
            try? await Task.sleep(for: .milliseconds(120))
        }

        // Some engines ignore SIGTERM while they are finishing a request.
        if record.isAlive { kill(record.pid, SIGKILL) }
        forget(record.id)
        return .stopped
    }
}
