import Foundation
import Testing
import zlib
@testable import ServerMaster

@MainActor
@Suite("R4 backup paths, ZIP and recovery")
struct BackupRestoreSafetyTests {
    private struct Entry {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
        var localName: String?
        var checksum: UInt32?
        var compressed: Data?
        var declaredSize: UInt64?
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-r4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Minimal independent fixture writer; production still reads real ditto ZIPs below.
    private func zip(_ entries: [Entry], at url: URL, wide: Bool = false, countOverride: UInt64? = nil) throws {
        var local = Data(), central = Data()
        func number(_ value: UInt64, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for entry in entries {
            let name = Data(entry.name.utf8), localName = Data((entry.localName ?? entry.name).utf8)
            let packed = entry.compressed ?? entry.data
            let checksum = entry.checksum ?? entry.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let length = entry.declaredSize ?? UInt64(entry.data.count)
            let position = UInt64(local.count)
            let localExtra = wide ? number(1, 2) + number(16, 2) + number(length, 8) + number(UInt64(packed.count), 8) : Data()
            let centralExtra = wide ? number(1, 2) + number(24, 2) + number(length, 8) + number(UInt64(packed.count), 8) + number(position, 8) : Data()
            local += number(0x04034b50, 4) + number(wide ? 45 : 20, 2) + number(0x800, 2) + number(entry.compressed == nil ? 0 : 8, 2)
            local += number(0, 4) + number(UInt64(checksum), 4) + number(wide ? 0xffffffff : UInt64(packed.count), 4) + number(wide ? 0xffffffff : length, 4)
            local += number(UInt64(localName.count), 2) + number(UInt64(localExtra.count), 2) + localName + localExtra + packed
            central += number(0x02014b50, 4) + number(0x0314, 2) + number(wide ? 45 : 20, 2) + number(0x800, 2) + number(entry.compressed == nil ? 0 : 8, 2)
            central += number(0, 4) + number(UInt64(checksum), 4) + number(wide ? 0xffffffff : UInt64(packed.count), 4) + number(wide ? 0xffffffff : length, 4)
            central += number(UInt64(name.count), 2) + number(UInt64(centralExtra.count), 2) + number(0, 2) + number(0, 2) + number(0, 2)
            central += number(UInt64(entry.mode) << 16, 4) + number(wide ? 0xffffffff : position, 4) + name + centralExtra
        }
        let start = UInt64(local.count), size = UInt64(central.count), count = countOverride ?? UInt64(entries.count)
        var output = local + central
        if wide {
            let position = UInt64(output.count)
            output += number(0x06064b50, 4) + number(44, 8) + number(45, 2) + number(45, 2) + number(0, 4) + number(0, 4)
            output += number(count, 8) + number(count, 8) + number(size, 8) + number(start, 8)
            output += number(0x07064b50, 4) + number(0, 4) + number(position, 8) + number(1, 4)
        }
        output += number(0x06054b50, 4) + number(0, 2) + number(0, 2)
        output += number(wide ? 0xffff : count, 2) + number(wide ? 0xffff : count, 2)
        output += number(wide ? 0xffffffff : size, 4) + number(wide ? 0xffffffff : start, 4) + number(0, 2)
        try output.write(to: url)
    }

    @Test("Valid stored/deflated ZIP and ZIP64 payloads; CRC and real size bounds")
    func container() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.zip")
        for wide in [false, true] {
            try zip([Entry(name: "Project/data.txt", data: Data("Українська".utf8))], at: file, wide: wide)
            #expect(try SnapshotArchive.inspect(file).rootName == "Project")
        }
        let compressed = Data([0x73, 0x74, 0x74, 0x74, 0x04, 0x00])
        try zip([Entry(name: "Project/file", data: Data("AAAA".utf8), compressed: compressed)], at: file)
        #expect(try SnapshotArchive.inspect(file).rootName == "Project")
        try zip([Entry(name: "Project/file", data: Data("AAAA".utf8), compressed: compressed, declaredSize: 0)], at: file)
        #expect(throws: SnapshotArchive.Failure.limit) { try SnapshotArchive.inspect(file) }
        try zip([Entry(name: "Project/file", data: Data("crc mismatch".utf8), checksum: 0)], at: file)
        #expect(throws: SnapshotArchive.Failure.invalid) { try SnapshotArchive.inspect(file) }
        try zip([Entry(name: "Project/file", declaredSize: SnapshotArchive.maximumBytes + 1)], at: file, wide: true)
        #expect(throws: SnapshotArchive.Failure.limit) { try SnapshotArchive.inspect(file) }
        try zip([Entry(name: "Project/file")], at: file, wide: true, countOverride: 200_001)
        #expect(throws: SnapshotArchive.Failure.limit) { try SnapshotArchive.inspect(file) }
        try Data([0x50, 0x4b]).write(to: file)
        #expect(throws: SnapshotArchive.Failure.invalid) { try SnapshotArchive.inspect(file) }
    }

    @Test("Traversal, links, conflicting roots/names and header mismatches are refused")
    func unsafeContainers() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.zip")
        let fixtures: [[Entry]] = [
            [Entry(name: "../outside")], [Entry(name: "/absolute")], [Entry(name: "Project/../outside")],
            [Entry(name: "Project/escape", mode: 0o120777)], [Entry(name: "Project/a", mode: 0o010644)],
            [Entry(name: "Project/a"), Entry(name: "Project/A")],
            [Entry(name: "Project/a"), Entry(name: "Project/a")],
            [Entry(name: "one/a"), Entry(name: "two/b")],
            [Entry(name: "Project/a", localName: "../outside")],
            [Entry(name: "Project/file"), Entry(name: "Project/file/child")],
            [Entry(name: "Project/file"), Entry(name: "__MACOSX/Other/._file")],
            [Entry(name: "Project\\outside")], [Entry(name: "Project/C:drive")]
        ]
        for entries in fixtures {
            try zip(entries, at: file)
            #expect(throws: (any Error).self) { try SnapshotArchive.inspect(file) }
        }
    }

    @Test("Real ditto backup/restore retains resources and keeps the old project at a unique path")
    func realRestore() async throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("value.txt")
        try Data("saved".utf8).write(to: file)
        try Data("exclude".utf8).write(to: source.appendingPathComponent(".secret.servermaster-tmp"))
        try #require((await ProcessRunner.run("/usr/bin/xattr", ["-w", "com.adm1nsys.r4", "resource", file.path])).succeeded)
        var profile = ServerProfile(); profile.rootPath = source.path; profile.workingDirectory = source.appendingPathComponent("sub").path
        let storage = base.appendingPathComponent("Backups")
        let store = SnapshotStore(destination: storage.path)
        let snapshot = try #require(await store.take(profile: profile, database: nil), "\(store.lastError ?? "")")
        #expect(snapshot.includesSite)
        try Data("source after backup".utf8).write(to: file)
        let target = base.appendingPathComponent("Current")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: target.appendingPathComponent("current.txt"))
        let untouched = base.appendingPathComponent("Current.before-restore")
        try Data("keep previous artifact".utf8).write(to: untouched)
        profile.rootPath = target.path
        let restored = await store.restore(snapshot, parts: [.site, .settings], into: profile, database: nil)
        #expect(restored.problems.isEmpty, "\(restored.problems)")
        #expect(restored.profile.id == profile.id && restored.profile.rootPath == target.path)
        #expect(restored.profile.workingDirectory == target.appendingPathComponent("sub").path)
        #expect(try String(contentsOf: target.appendingPathComponent("value.txt"), encoding: .utf8) == "saved")
        #expect(try String(contentsOf: file, encoding: .utf8) == "source after backup")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".secret.servermaster-tmp").path))
        let resource = await ProcessRunner.run("/usr/bin/xattr", ["-p", "com.adm1nsys.r4", target.appendingPathComponent("value.txt").path])
        #expect(resource.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "resource")
        let previous = try #require(store.lastPreservedSitePath)
        #expect(try String(contentsOfFile: previous + "/current.txt", encoding: .utf8) == "current")
        #expect(try String(contentsOf: untouched, encoding: .utf8) == "keep previous artifact")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".servermaster-restore-") })
    }

    @Test("Backup storage cannot overlap a project or hide linked source files")
    func refusedBackup() async throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var profile = ServerProfile(); profile.rootPath = source.path
        let nested = source.appendingPathComponent("Backups")
        let invalid = SnapshotStore(destination: nested.path)
        #expect(await invalid.take(profile: profile, database: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        let outside = base.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: outside)
        let store = SnapshotStore(destination: base.appendingPathComponent("Backups").path)
        #expect(await store.take(profile: profile, database: nil) == nil)
        #expect(store.lastError != nil && store.snapshots.isEmpty)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(throws: (any Error).self) { try SnapshotFileSafety.project(URL(fileURLWithPath: NSHomeDirectory()), storage: base) }
        #expect(throws: (any Error).self) { try SnapshotFileSafety.project(URL(fileURLWithPath: "/"), storage: base) }
        #expect(throws: (any Error).self) { try SnapshotFileSafety.project(base, storage: source) }
    }

    @Test("Invalid IDs, linked snapshot folders and linked ZIP files cannot redirect restore/delete")
    func storedPaths() async throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("Backups")
        let store = SnapshotStore(destination: storage.path)
        var profile = ServerProfile(); profile.rootPath = ""
        let snapshot = try #require(await store.take(profile: profile, database: nil))
        var forged = snapshot; forged.id = "../outside"
        #expect(!(await store.restore(forged, parts: [.settings], into: profile, database: nil)).problems.isEmpty)
        store.delete(forged)
        let folder = store.folder(for: snapshot)
        var included = snapshot
        included.includesSite = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([included]).write(to: storage.appendingPathComponent("snapshots.json"))
        store.reload()
        let trusted = try #require(store.snapshots.first)
        let linkedZip = base.appendingPathComponent("outside.zip")
        try zip([Entry(name: "Project/file", data: Data("keep".utf8))], at: linkedZip)
        let originalZip = try Data(contentsOf: linkedZip)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("site.zip"), withDestinationURL: linkedZip)
        profile.rootPath = base.appendingPathComponent("Target").path
        #expect(!(await store.restore(trusted, parts: [.site], into: profile, database: nil)).problems.isEmpty)
        #expect(try Data(contentsOf: linkedZip) == originalZip)
        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("held"))
        let outside = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(!(await store.restore(snapshot, parts: [.settings], into: profile, database: nil)).problems.isEmpty)
        store.delete(snapshot)
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        store.reload()
        #expect(store.lastError != nil)
        let index = storage.appendingPathComponent("snapshots.json")
        let outsideIndex = outside.appendingPathComponent("index.json")
        let indexData = try encoder.encode([included])
        try indexData.write(to: outsideIndex)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outsideIndex)
        store.reload()
        #expect(store.lastError != nil)
        #expect(await store.take(profile: profile, database: nil) == nil)
        #expect(try Data(contentsOf: outsideIndex) == indexData)
    }

    @Test("A failed final swap rolls back; failed rollback preserves the old folder and reports its location")
    func rollback() async throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let storage = base.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let archive = storage.appendingPathComponent("site.zip")
        try zip([Entry(name: "Project/value.txt", data: Data("saved".utf8))], at: archive)
        let target = base.appendingPathComponent("Current")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("old.txt"))
        do {
            _ = try await SnapshotFileSafety.restoreSite(archive: archive, into: target, storage: storage) { from, to in
                if from.path.contains("/unpacked/") { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("Final swap failure was ignored")
        } catch { }
        #expect(try String(contentsOf: target.appendingPathComponent("old.txt"), encoding: .utf8) == "old")
        try zip([Entry(name: "../outside", data: Data("bad".utf8))], at: archive)
        do {
            _ = try await SnapshotFileSafety.restoreSite(archive: archive, into: target, storage: storage)
            Issue.record("Unsafe ZIP reached restore")
        } catch { }
        #expect(try String(contentsOf: target.appendingPathComponent("old.txt"), encoding: .utf8) == "old")
        try zip([Entry(name: "Project/value.txt", data: Data("saved".utf8))], at: archive)
        do {
            _ = try await SnapshotFileSafety.restoreSite(archive: archive, into: target, storage: storage) { from, to in
                if from.path.contains("/unpacked/") || from.lastPathComponent.hasPrefix("Current.before-restore-") { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: from, to: to)
            }
            Issue.record("Rollback failure was ignored")
        } catch SnapshotFileSafety.Failure.rollback(let path) {
            #expect(try String(contentsOfFile: path + "/old.txt", encoding: .utf8) == "old")
        } catch { Issue.record("Wrong rollback error: \(error)") }
    }
}

@MainActor
@Suite("R4 isolated database backup restore", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_DATABASE_CELLS"] == "1"))
struct BackupDatabaseSafetyTests {
    @Test("The real dump restores only the isolated server; linked SQL is not imported")
    func databaseDump() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("database-r4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RuntimePortLease.acquire(excluding: 3307)
        defer { withExtendedLifetime(lease) {} }
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("database"),
            socketPath: "/tmp/sm-r4-\(UUID().uuidString.prefix(10)).sock", port: lease.port)
        defer { database.stopImmediately() }
        lease.allowChildBind()
        await database.start()
        try #require(database.state == .running)
        try #require((await database.query(sql: "CREATE DATABASE r4_backup; CREATE TABLE r4_backup.sample (id INT PRIMARY KEY, value TEXT); INSERT INTO r4_backup.sample VALUES (1, 'saved');")).succeeded)
        let store = SnapshotStore(destination: root.appendingPathComponent("Backups").path)
        let snapshot = try #require(await store.takeDatabase(named: "r4_backup", database: database), "\(store.lastError ?? "")")
        _ = await database.query(sql: "UPDATE r4_backup.sample SET value = 'changed';")
        let restored = await store.restoreDatabase(snapshot, database: database)
        #expect(restored == nil, "\(restored ?? "")")
        #expect((await database.query(sql: "SELECT value FROM r4_backup.sample;")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "saved")
        let sql = store.folder(for: snapshot).appendingPathComponent("database.sql")
        try FileManager.default.moveItem(at: sql, to: root.appendingPathComponent("held.sql"))
        let outside = root.appendingPathComponent("outside.sql")
        try "DROP TABLE r4_backup.sample;".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sql, withDestinationURL: outside)
        #expect(await store.restoreDatabase(snapshot, database: database) != nil)
        #expect((await database.query(sql: "SELECT value FROM r4_backup.sample;")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "saved")
        await database.stop()
        #expect(database.state == .stopped)
    }
}
