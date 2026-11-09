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
        if let date = try? container.decode(Date.self, forKey: .taken) {
            taken = date
        } else if let number = try? container.decode(Double.self, forKey: .taken), number.isFinite {
            // Legacy JSONEncoder dates use seconds since Apple's reference date.
            taken = Date(timeIntervalSinceReferenceDate: number)
        } else if let raw = try? container.decode(String.self, forKey: .taken) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .taken, in: container, debugDescription: "Invalid snapshot date")
            }
            taken = date
        } else {
            throw DecodingError.dataCorruptedError(forKey: .taken, in: container, debugDescription: "Missing snapshot date")
        }
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
    private var operationActive = false
    private var batchID: UUID?
    var isWorking: Bool { operationActive || batchID != nil }

    /// A batch reserves the store across awaits between individual operations.
    func beginBatch() -> UUID? {
        guard !isWorking else { return nil }
        let id = UUID()
        batchID = id
        return id
    }

    func endBatch(_ id: UUID) {
        guard batchID == id, !operationActive else { return }
        batchID = nil
    }

    private func canBeginOperation(batch: UUID?) -> Bool {
        !operationActive && (batchID == nil ? batch == nil : batchID == batch)
    }
    private(set) var lastError: String?
    private(set) var lastPreservedSitePath: String?

    /// Where backups go. Documents by default: somewhere a person already knows
    /// how to find, and somewhere Time Machine already covers.
    static func defaultDestination() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerMaster Backups").path
    }

    var destinationPath: String { destination.path }
    private var destination: URL
    private let log: ConsoleLog?
    private var indexLoadFailed = false
    private var storageAccess: SiteFileAccess?

    init(destination: String, log: ConsoleLog? = nil) {
        self.destination = SnapshotFileSafety.normalized(URL(fileURLWithPath: AppPaths.expand(destination), isDirectory: true))
        self.log = log
        reload()
    }

    @discardableResult
    func setDestination(_ path: String) -> Bool {
        guard !isWorking else { return false }
        destination = SnapshotFileSafety.normalized(URL(fileURLWithPath: AppPaths.expand(path), isDirectory: true))
        storageAccess = nil
        reload()
        return true
    }

    // MARK: - Reading what is there

    /// The index lives beside the snapshots rather than in the app's own data,
    /// so pointing the app at a folder of backups from another Mac just works.
    private var indexFile: URL { destination.appendingPathComponent("snapshots.json") }

    func reload() {
        guard !isWorking else { return }
        lastError = nil
        indexLoadFailed = false
        do {
            guard try SnapshotFileSafety.exists(destination) else { snapshots = []; return }
            let scope = try storageScope(create: false)
            guard try SnapshotFileSafety.exists(indexFile) else { snapshots = []; return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([Snapshot].self, from: SnapshotFileSafety.readFile(indexFile, scope: scope, maximum: 64 * 1024 * 1024))
            guard decoded.allSatisfy({ Self.validID($0.id) }), Set(decoded.map(\.id)).count == decoded.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var found: [Snapshot] = []
            for snapshot in decoded where try SnapshotFileSafety.exists(folder(for: snapshot)) {
                let folder = try scope.checked(folder(for: snapshot))
                _ = try SnapshotFileSafety.directory(folder)
                found.append(snapshot)
            }
            snapshots = found.sorted { $0.taken > $1.taken }
        } catch {
            snapshots = []
            indexLoadFailed = true
            lastError = String(localized: "Could not read the backup index. It has not been overwritten: \(error.localizedDescription)")
        }
    }

    func snapshots(for profileID: UUID) -> [Snapshot] {
        snapshots.filter { $0.profileID == profileID }
    }

    func folder(for snapshot: Snapshot) -> URL {
        destination.appendingPathComponent(Self.validID(snapshot.id) ? snapshot.folderName : ".invalid-snapshot", isDirectory: true)
    }

    private func storageScope(create: Bool) throws -> SiteFileAccess {
        _ = try SnapshotFileSafety.directory(destination, allowMissing: create)
        if create { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if let storageAccess {
            _ = try storageAccess.checked(destination)
            return storageAccess
        }
        let scope = try SiteFileAccess(root: destination)
        storageAccess = scope
        return scope
    }

    private func verified(_ supplied: Snapshot) throws -> (snapshot: Snapshot, folder: URL, scope: SiteFileAccess) {
        guard Self.validID(supplied.id), !indexLoadFailed,
              let snapshot = snapshots.first(where: { $0.id == supplied.id }) else { throw SnapshotFileSafety.Failure.path }
        let scope = try storageScope(create: false)
        let folder = try scope.checked(folder(for: snapshot))
        _ = try SnapshotFileSafety.directory(folder)
        return (snapshot, folder, scope)
    }

    private func writeIndex(_ entries: [Snapshot]) throws {
        guard !indexLoadFailed else { throw CocoaError(.fileReadCorruptFile) }
        let scope = try storageScope(create: true)
        if try SnapshotFileSafety.exists(indexFile) { _ = try SnapshotFileSafety.regularFile(indexFile, scope: scope) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: indexFile, options: .atomic)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains("\0")
    }

    private func register(_ snapshot: Snapshot, folder: URL) -> Bool {
        let updated = [snapshot] + snapshots
        do {
            try writeIndex(updated)
            snapshots = updated
            return true
        } catch {
            removeNewFolder(folder)
            lastError = String(localized: "Could not save the backup index. The new snapshot was not added: \(error.localizedDescription)")
            return false
        }
    }

    private func removeNewFolder(_ folder: URL) {
        if let scope = storageAccess, let checked = try? scope.checked(folder) {
            try? FileManager.default.removeItem(at: checked)
        }
    }

    // MARK: - Taking one

    @discardableResult
    func take(profile: ServerProfile,
              database: DatabaseService?,
              trigger: Snapshot.Trigger = .manual,
              note: String? = nil, batch: UUID? = nil) async -> Snapshot? {

        guard canBeginOperation(batch: batch), !indexLoadFailed else { return nil }
        operationActive = true
        defer { operationActive = false }
        lastError = nil

        let stamp = Self.stamp.string(from: Date())
        let id = "\(Self.slug(profile.name))-\(stamp)-\(UUID().uuidString)"
        let folder = destination.appendingPathComponent(id, isDirectory: true)

        do {
            if !profile.rootPath.isEmpty {
                _ = try SnapshotFileSafety.project(URL(fileURLWithPath: AppPaths.expand(profile.rootPath)), storage: destination)
            }
            _ = try storageScope(create: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            lastError = String(localized: "Could not write to \(destination.path): \(error.localizedDescription)")
            return nil
        }

        // 1. The profile itself. Small, and the part most worth having.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(profile)
            try data.write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
        } catch {
            removeNewFolder(folder)
            lastError = String(localized: "Could not save the profile backup: \(error.localizedDescription)")
            return nil
        }

        // 2. The site. ditto keeps resource forks and permissions, which matter
        //    for anything that was ever unpacked from a downloaded archive.
        var siteSaved = false
        let root = AppPaths.expand(profile.rootPath)
        if !profile.rootPath.isEmpty, FileManager.default.fileExists(atPath: root) {
            let archive = folder.appendingPathComponent("site.zip")
            let source = SnapshotFileSafety.normalized(URL(fileURLWithPath: root))
            let staging = folder.appendingPathComponent(".site-source-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let copy = staging.appendingPathComponent(source.lastPathComponent)
                try await Task.detached { try SnapshotFileSafety.copyProject(source, to: copy) }.value
                let result = await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", copy.path, archive.path], timeout: 600)
                guard result.succeeded else { throw SnapshotFileSafety.Failure.extraction }
                _ = try await Task.detached { try SnapshotArchive.inspect(archive) }.value
                try FileManager.default.removeItem(at: staging)
                siteSaved = true
            } catch {
                removeNewFolder(folder)
                lastError = error.localizedDescription
                return nil
            }
        }

        // 3. The database, when the profile names one and it is running.
        var databaseSaved = false
        let databaseName = profile.databaseName.isEmpty ? nil : profile.databaseName
        if let databaseName, let database {
            if database.state != .running {
                lastError = String(localized: "Database not included: MariaDB was stopped.")
            } else {
                let dump = folder.appendingPathComponent("database.sql")
                databaseSaved = await database.dump(databaseName, to: dump.path)
                if !databaseSaved {
                    lastError = String(localized: "The database “\(databaseName)” could not be dumped.")
                }
            }
        }

        let snapshotNote = [note, lastError].compactMap { $0 }.joined(separator: "\n")
        let snapshot = Snapshot(id: id,
                                profileID: profile.id,
                                profileName: profile.name,
                                taken: Date(),
                                trigger: trigger,
                                includesSite: siteSaved,
                                includesDatabase: databaseSaved,
                                databaseName: databaseSaved ? databaseName : nil,
                                bytes: Self.size(of: folder),
                                note: snapshotNote.isEmpty ? nil : snapshotNote)

        guard register(snapshot, folder: folder) else { return nil }
        log?.system(lastError ?? String(localized: "Snapshot of “\(profile.name)” taken."))
        return snapshot
    }

    // MARK: - A database on its own

    @discardableResult
    func takeDatabase(named name: String,
                      database: DatabaseService,
                      trigger: Snapshot.Trigger = .manual, batch: UUID? = nil) async -> Snapshot? {
        guard canBeginOperation(batch: batch), !indexLoadFailed else { return nil }
        operationActive = true
        defer { operationActive = false }
        lastError = nil

        guard database.state == .running else {
            lastError = String(localized: "The database server is not running.")
            return nil
        }

        let id = "db-\(Self.slug(name))-\(Self.stamp.string(from: Date()))-\(UUID().uuidString)"
        let folder = destination.appendingPathComponent(id, isDirectory: true)
        do {
            _ = try storageScope(create: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            lastError = String(localized: "Could not write to \(destination.path): \(error.localizedDescription)")
            return nil
        }

        let dump = folder.appendingPathComponent("database.sql")
        guard await database.dump(name, to: dump.path) else {
            removeNewFolder(folder)
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
        guard register(snapshot, folder: folder) else { return nil }
        log?.system(String(localized: "Snapshot of database “\(name)” taken."))
        return snapshot
    }

    /// Puts a database snapshot back. The dump was written with `--databases`,
    /// so it recreates the database as it was — including dropping what is
    /// there now, which is the whole point and worth saying out loud in the UI.
    func restoreDatabase(_ snapshot: Snapshot, database: DatabaseService, batch: UUID? = nil) async -> String? {
        guard canBeginOperation(batch: batch) else { return String(localized: "Wait for the current backup operation to finish.") }
        operationActive = true
        defer { operationActive = false }
        let item: (snapshot: Snapshot, folder: URL, scope: SiteFileAccess)
        do { item = try verified(snapshot) }
        catch { return error.localizedDescription }
        guard item.snapshot.includesDatabase, let name = item.snapshot.databaseName else {
            return String(localized: "This snapshot has no database in it.")
        }
        guard database.state == .running else {
            return String(localized: "The database server is not running.")
        }
        let dump: URL
        do { dump = try SnapshotFileSafety.regularFile(item.folder.appendingPathComponent("database.sql"), scope: item.scope) }
        catch { return error.localizedDescription }
        guard await database.load(dump.path, into: name) else {
            return String(localized: "The database “\(name)” could not be restored.")
        }
        log?.system(String(localized: "Database “\(name)” restored from \(Self.readable.string(from: item.snapshot.taken))."))
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
                 database: DatabaseService?, batch: UUID? = nil) async -> (profile: ServerProfile, problems: [String]) {
        guard canBeginOperation(batch: batch) else { return (profile, [String(localized: "Wait for the current backup operation to finish.")]) }
        operationActive = true
        defer { operationActive = false }
        lastPreservedSitePath = nil

        var restored = profile
        var problems: [String] = []
        let item: (snapshot: Snapshot, folder: URL, scope: SiteFileAccess)
        do { item = try verified(snapshot) }
        catch { return (profile, [error.localizedDescription]) }
        let trusted = item.snapshot
        let folder = item.folder

        if parts.contains(.settings) {
            let file = folder.appendingPathComponent("profile.json")
            do {
                let data = try SnapshotFileSafety.readFile(file, scope: item.scope, maximum: 8 * 1024 * 1024)
                let profiles = try ProfileTransfer.decode(data)
                guard profiles.count == 1, let saved = profiles.first else { throw SnapshotFileSafety.Failure.path }
                // The id stays as it is: this is the same profile being put back,
                // not a second one, and everything else refers to it by id.
                var incoming = saved
                incoming.id = profile.id
                // Restore into the project selected now; saved JSON cannot redirect file writes.
                incoming.rootPath = profile.rootPath
                let oldRoot = URL(fileURLWithPath: AppPaths.expand(saved.rootPath)).standardizedFileURL
                let working = URL(fileURLWithPath: saved.effectiveWorkingDirectory).standardizedFileURL
                if SnapshotFileSafety.contains(oldRoot, working) {
                    var adapted = URL(fileURLWithPath: AppPaths.expand(profile.rootPath))
                    for component in working.pathComponents.dropFirst(oldRoot.pathComponents.count) { adapted.appendPathComponent(component) }
                    incoming.workingDirectory = adapted.path
                } else { incoming.workingDirectory = profile.workingDirectory }
                restored = incoming
            } catch {
                return (profile, [String(localized: "The saved settings could not be read.") + " " + error.localizedDescription])
            }
        }

        // Reject known missing/linked DB components before replacing any project files.
        if parts.contains(.database) {
            guard trusted.includesDatabase, let database, database.state == .running else {
                return (profile, [String(localized: "Start the database and choose a snapshot that includes its dump.")])
            }
            do { _ = try SnapshotFileSafety.regularFile(folder.appendingPathComponent("database.sql"), scope: item.scope) }
            catch { return (profile, [error.localizedDescription]) }
        }

        if parts.contains(.site) {
            guard trusted.includesSite else { return (profile, [String(localized: "This snapshot does not contain the selected backup component.")]) }
            do {
                let archive = try SnapshotFileSafety.regularFile(folder.appendingPathComponent("site.zip"), scope: item.scope)
                let previous = try await SnapshotFileSafety.restoreSite(archive: archive, into: URL(fileURLWithPath: AppPaths.expand(profile.rootPath)), storage: destination)
                lastPreservedSitePath = previous?.path
                if let previous { log?.system(String(localized: "Previous project files were kept at \(previous.path).")) }
            } catch {
                if case SnapshotFileSafety.Failure.rollback(let path) = error { lastPreservedSitePath = path }
                return (profile, [error.localizedDescription])
            }
        }

        if parts.contains(.database) {
            guard trusted.includesDatabase, let name = trusted.databaseName, let database else {
                return (restored, [String(localized: "This snapshot does not contain the selected backup component.")])
            }
            if database.state != .running {
                problems.append(String(localized: "The database server is not running."))
            } else {
                do {
                    let dump = try SnapshotFileSafety.regularFile(folder.appendingPathComponent("database.sql"), scope: item.scope)
                    if await !database.load(dump.path, into: name) { problems.append(String(localized: "The database “\(name)” could not be restored.")) }
                } catch { problems.append(error.localizedDescription) }
            }
        }

        log?.system(problems.isEmpty
                    ? String(localized: "Restored “\(snapshot.profileName)” from \(Self.readable.string(from: snapshot.taken)).")
                    : String(localized: "Restore of “\(snapshot.profileName)” finished with problems."))
        return (restored, problems)
    }

    // MARK: - Removing

    func delete(_ snapshot: Snapshot) {
        guard !isWorking, !indexLoadFailed, Self.validID(snapshot.id), snapshots.contains(where: { $0.id == snapshot.id }) else { return }
        let pending = destination.appendingPathComponent(".servermaster-delete-\(UUID().uuidString)")
        do {
            let item = try verified(snapshot)
            let original = item.folder
            try FileManager.default.moveItem(at: original, to: pending)
            do {
                let updated = snapshots.filter { $0.id != snapshot.id }
                try writeIndex(updated)
                snapshots = updated
            } catch {
                try FileManager.default.moveItem(at: pending, to: original)
                throw error
            }
            try FileManager.default.removeItem(at: pending)
            lastError = nil
        } catch {
            lastError = String(localized: "Could not delete the snapshot: \(error.localizedDescription)")
        }
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
