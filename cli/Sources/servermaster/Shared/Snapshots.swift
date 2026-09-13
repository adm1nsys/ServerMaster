//
//  Snapshots.swift
//  ServerMaster
//
//  Taking a copy of a profile so a bad afternoon can be undone.
//
//  A snapshot is a folder, not an archive format: the settings as JSON, the site
//  as one zip, the database as one dump. Plain files on purpose — if this app is
//  ever gone, the backup is still a folder anyone can open, and that matters more
//  for a local development tool than saving a few megabytes.
//
//  Nothing here overwrites without being asked. Restoring writes the site back
//  beside the old one first and only then swaps, so a restore that fails halfway
//  leaves what was already there.
//

import Foundation

// MARK: - What a snapshot is

nonisolated struct Snapshot: Codable, Sendable, Identifiable, Equatable {

    enum Trigger: String, Codable, Sendable {
        case manual, scheduled
    }

    /// A snapshot is either a whole profile or one database on its own.
    ///
    /// Separate because the two break separately. A database that will not start
    /// after an interrupted write has nothing to do with the files beside it, and
    /// having to roll a whole site back to fix it is the wrong trade.
    enum Kind: String, Codable, Sendable {
        case profile, database
    }

    var id: String
    var kind: Kind = .profile
    /// Nil for a database snapshot: it belongs to no profile.
    var profileID: UUID?
    /// The profile's name, or the database's.
    var profileName: String
    var taken: Date
    var trigger: Trigger
    /// What actually made it in. A site with no database has no dump, and a
    /// folder that could not be read leaves the settings alone worth keeping.
    var includesSite: Bool
    var includesDatabase: Bool
    var databaseName: String?
    var bytes: Int64
    var note: String?

    var folderName: String { id }

    /// Hand-written so an index file from before database snapshots existed
    /// still reads: `kind` is absent there, and `profileID` was not optional.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .profile
        profileID = try? container.decode(UUID.self, forKey: .profileID)
        profileName = (try? container.decode(String.self, forKey: .profileName)) ?? "—"
        taken = (try? container.decode(Date.self, forKey: .taken)) ?? .distantPast
        trigger = (try? container.decode(Trigger.self, forKey: .trigger)) ?? .manual
        includesSite = (try? container.decode(Bool.self, forKey: .includesSite)) ?? false
        includesDatabase = (try? container.decode(Bool.self, forKey: .includesDatabase)) ?? false
        databaseName = try? container.decode(String.self, forKey: .databaseName)
        bytes = (try? container.decode(Int64.self, forKey: .bytes)) ?? 0
        note = try? container.decode(String.self, forKey: .note)
    }

    init(id: String, kind: Kind = .profile, profileID: UUID?, profileName: String,
         taken: Date, trigger: Trigger, includesSite: Bool, includesDatabase: Bool,
         databaseName: String?, bytes: Int64, note: String? = nil) {
        self.id = id; self.kind = kind; self.profileID = profileID
        self.profileName = profileName; self.taken = taken; self.trigger = trigger
        self.includesSite = includesSite; self.includesDatabase = includesDatabase
        self.databaseName = databaseName; self.bytes = bytes; self.note = note
    }
}

// MARK: - How often

nonisolated enum BackupInterval: String, Codable, CaseIterable, Sendable, Identifiable {
    case minutes, hours, days, weeks, months, years

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minutes: String(localized: "minutes")
        case .hours:   String(localized: "hours")
        case .days:    String(localized: "days")
        case .weeks:   String(localized: "weeks")
        case .months:  String(localized: "months")
        case .years:   String(localized: "years")
        }
    }

    /// Seconds in one of these. Months and years are the average kind — this
    /// decides when to take a backup, not when to bill anyone.
    var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours:   3600
        case .days:    86_400
        case .weeks:   604_800
        case .months:  2_629_746
        case .years:   31_556_952
        }
    }
}

// MARK: - Doing it

@Observable
final class SnapshotStore {

    private(set) var snapshots: [Snapshot] = []
    private(set) var isWorking = false
    private(set) var lastError: String?

    /// Where backups go. Documents by default: somewhere a person already knows
    /// how to find, and somewhere Time Machine already covers.
    static func defaultDestination() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerMaster Backups").path
    }

    private var destination: URL
    private let log: ConsoleLog?

    init(destination: String, log: ConsoleLog? = nil) {
        self.destination = URL(fileURLWithPath: AppPaths.expand(destination), isDirectory: true)
        self.log = log
        reload()
    }

    func setDestination(_ path: String) {
        destination = URL(fileURLWithPath: AppPaths.expand(path), isDirectory: true)
        reload()
    }

    // MARK: - Reading what is there

    /// The index lives beside the snapshots rather than in the app's own data,
    /// so pointing the app at a folder of backups from another Mac just works.
    private var indexFile: URL { destination.appendingPathComponent("snapshots.json") }

    func reload() {
        guard let data = try? Data(contentsOf: indexFile),
              let decoded = try? JSONDecoder().decode([Snapshot].self, from: data) else {
            snapshots = []
            return
        }
        // A folder someone deleted by hand should not stay in the list.
        snapshots = decoded
            .filter { FileManager.default.fileExists(atPath: folder(for: $0).path) }
            .sorted { $0.taken > $1.taken }
    }

    func snapshots(for profileID: UUID) -> [Snapshot] {
        snapshots.filter { $0.profileID == profileID }
    }

    func folder(for snapshot: Snapshot) -> URL {
        destination.appendingPathComponent(snapshot.folderName, isDirectory: true)
    }

    private func writeIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? data.write(to: indexFile, options: .atomic)
    }

    // MARK: - Taking one

    @discardableResult
    func take(profile: ServerProfile,
              database: DatabaseService?,
              trigger: Snapshot.Trigger = .manual,
              note: String? = nil) async -> Snapshot? {

        isWorking = true
        defer { isWorking = false }
        lastError = nil

        let stamp = Self.stamp.string(from: Date())
        let id = "\(Self.slug(profile.name))-\(stamp)"
        let folder = destination.appendingPathComponent(id, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = String(localized: "Could not write to \(destination.path): \(error.localizedDescription)")
            return nil
        }

        // 1. The profile itself. Small, and the part most worth having.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profile) {
            try? data.write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
        }

        // 2. The site. ditto keeps resource forks and permissions, which matter
        //    for anything that was ever unpacked from a downloaded archive.
        var siteSaved = false
        let root = AppPaths.expand(profile.rootPath)
        if !profile.rootPath.isEmpty, FileManager.default.fileExists(atPath: root) {
            let archive = folder.appendingPathComponent("site.zip")
            let result = await ProcessRunner.run("/usr/bin/ditto",
                                                 ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                             root, archive.path])
            siteSaved = result.succeeded
            if !siteSaved { lastError = result.stderr }
        }

        // 3. The database, when the profile names one and it is running.
        var databaseSaved = false
        let databaseName = profile.databaseName.isEmpty ? nil : profile.databaseName
        if let databaseName, let database, database.state == .running {
            let dump = folder.appendingPathComponent("database.sql")
            databaseSaved = await database.dump(databaseName, to: dump.path)
            if !databaseSaved {
                lastError = String(localized: "The database “\(databaseName)” could not be dumped.")
            }
        }

        let snapshot = Snapshot(id: id,
                                profileID: profile.id,
                                profileName: profile.name,
                                taken: Date(),
                                trigger: trigger,
                                includesSite: siteSaved,
                                includesDatabase: databaseSaved,
                                databaseName: databaseSaved ? databaseName : nil,
                                bytes: Self.size(of: folder),
                                note: note)

        snapshots.insert(snapshot, at: 0)
        writeIndex()
        log?.system(String(localized: "Snapshot of “\(profile.name)” taken."))
        return snapshot
    }

    // MARK: - A database on its own

    @discardableResult
    func takeDatabase(named name: String,
                      database: DatabaseService,
                      trigger: Snapshot.Trigger = .manual) async -> Snapshot? {
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        guard database.state == .running else {
            lastError = String(localized: "The database server is not running.")
            return nil
        }

        let id = "db-\(Self.slug(name))-\(Self.stamp.string(from: Date()))"
        let folder = destination.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = String(localized: "Could not write to \(destination.path): \(error.localizedDescription)")
            return nil
        }

        let dump = folder.appendingPathComponent("database.sql")
        guard await database.dump(name, to: dump.path) else {
            try? FileManager.default.removeItem(at: folder)
            lastError = String(localized: "The database “\(name)” could not be dumped.")
            return nil
        }

        let snapshot = Snapshot(id: id,
                                kind: .database,
                                profileID: nil,
                                profileName: name,
                                taken: Date(),
                                trigger: trigger,
                                includesSite: false,
                                includesDatabase: true,
                                databaseName: name,
                                bytes: Self.size(of: folder))
        snapshots.insert(snapshot, at: 0)
        writeIndex()
        log?.system(String(localized: "Snapshot of database “\(name)” taken."))
        return snapshot
    }

    /// Puts a database snapshot back. The dump was written with `--databases`,
    /// so it recreates the database as it was — including dropping what is
    /// there now, which is the whole point and worth saying out loud in the UI.
    func restoreDatabase(_ snapshot: Snapshot, database: DatabaseService) async -> String? {
        isWorking = true
        defer { isWorking = false }

        guard let name = snapshot.databaseName else {
            return String(localized: "This snapshot has no database in it.")
        }
        guard database.state == .running else {
            return String(localized: "The database server is not running.")
        }
        let dump = folder(for: snapshot).appendingPathComponent("database.sql")
        guard FileManager.default.fileExists(atPath: dump.path) else {
            return String(localized: "The dump file is missing from the snapshot folder.")
        }
        guard await database.load(dump.path, into: name) else {
            return String(localized: "The database “\(name)” could not be restored.")
        }
        log?.system(String(localized: "Database “\(name)” restored from \(Self.readable.string(from: snapshot.taken))."))
        return nil
    }

    var databaseSnapshots: [Snapshot] { snapshots.filter { $0.kind == .database } }
    var profileSnapshots: [Snapshot] { snapshots.filter { $0.kind == .profile } }

    func snapshots(ofDatabase name: String) -> [Snapshot] {
        snapshots.filter { $0.kind == .database && $0.databaseName == name }
    }

    // MARK: - Putting one back

    enum RestoreOption: String, CaseIterable, Sendable, Identifiable {
        case settings, site, database
        var id: String { rawValue }
    }

    /// Restores the parts asked for. Returns what could not be done, so the
    /// caller can say so rather than claiming a clean restore.
    func restore(_ snapshot: Snapshot,
                 parts: Set<RestoreOption>,
                 into profile: ServerProfile,
                 database: DatabaseService?) async -> (profile: ServerProfile, problems: [String]) {

        isWorking = true
        defer { isWorking = false }

        var restored = profile
        var problems: [String] = []
        let folder = folder(for: snapshot)

        if parts.contains(.settings) {
            let file = folder.appendingPathComponent("profile.json")
            if let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode(ServerProfile.self, from: data) {
                // The id stays as it is: this is the same profile being put back,
                // not a second one, and everything else refers to it by id.
                var incoming = saved
                incoming.id = profile.id
                restored = incoming
            } else {
                problems.append(String(localized: "The saved settings could not be read."))
            }
        }

        if parts.contains(.site), snapshot.includesSite {
            let archive = folder.appendingPathComponent("site.zip")
            let root = URL(fileURLWithPath: AppPaths.expand(restored.rootPath))
            let parent = root.deletingLastPathComponent()
            let staging = parent.appendingPathComponent(".servermaster-restore-\(UUID().uuidString.prefix(8))")

            // Unpacked beside the site and swapped in at the end. Unpacking over
            // the live folder is how a restore that fails halfway leaves neither
            // the old site nor the new one.
            let unpack = await ProcessRunner.run("/usr/bin/ditto",
                                                 ["-x", "-k", archive.path, staging.path])
            if unpack.succeeded {
                let unpacked = (try? FileManager.default.contentsOfDirectory(at: staging,
                                                                            includingPropertiesForKeys: nil))?
                    .first(where: { $0.hasDirectoryPath })
                if let unpacked {
                    let aside = parent.appendingPathComponent(root.lastPathComponent + ".before-restore")
                    try? FileManager.default.removeItem(at: aside)
                    try? FileManager.default.moveItem(at: root, to: aside)
                    do {
                        try FileManager.default.moveItem(at: unpacked, to: root)
                        try? FileManager.default.removeItem(at: aside)
                    } catch {
                        // Put the old one back rather than leave nothing there.
                        try? FileManager.default.moveItem(at: aside, to: root)
                        problems.append(String(localized: "The site could not be put back: \(error.localizedDescription)"))
                    }
                } else {
                    problems.append(String(localized: "The saved site is empty."))
                }
            } else {
                problems.append(String(localized: "The saved site could not be unpacked."))
            }
            try? FileManager.default.removeItem(at: staging)
        }

        if parts.contains(.database), snapshot.includesDatabase,
           let name = snapshot.databaseName, let database {
            if database.state != .running {
                problems.append(String(localized: "The database server is not running."))
            } else if await !database.load(folder.appendingPathComponent("database.sql").path, into: name) {
                problems.append(String(localized: "The database “\(name)” could not be restored."))
            }
        }

        log?.system(problems.isEmpty
                    ? String(localized: "Restored “\(snapshot.profileName)” from \(Self.readable.string(from: snapshot.taken)).")
                    : String(localized: "Restore of “\(snapshot.profileName)” finished with problems."))
        return (restored, problems)
    }

    // MARK: - Removing

    func delete(_ snapshot: Snapshot) {
        try? FileManager.default.removeItem(at: folder(for: snapshot))
        snapshots.removeAll { $0.id == snapshot.id }
        writeIndex()
    }

    /// Keeps the newest `keep` scheduled snapshots per profile. Manual ones are
    /// left alone — someone took those on purpose.
    func prune(keep: Int) {
        guard keep > 0 else { return }
        // Grouped by what the snapshot is of — a profile id, or a database name
        // — so keeping ten does not mean ten in total across everything.
        let byProfile = Dictionary(grouping: snapshots.filter { $0.trigger == .scheduled },
                                   by: { $0.profileID?.uuidString ?? "db:\($0.databaseName ?? "")" })
        for (_, list) in byProfile {
            for old in list.sorted(by: { $0.taken > $1.taken }).dropFirst(keep) {
                delete(old)
            }
        }
    }

    // MARK: - Odds and ends

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let readable: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// A folder name that survives every filesystem and still reads as the
    /// profile it came from.
    private static func slug(_ name: String) -> String {
        let cleaned = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let text = String(cleaned).split(separator: "-").joined(separator: "-")
        return text.isEmpty ? "profile" : String(text.prefix(40))
    }

    private static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder,
                                                         includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
