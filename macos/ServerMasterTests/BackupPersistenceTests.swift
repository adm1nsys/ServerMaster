import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("R5 snapshot persistence")
struct BackupPersistenceTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-r5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var profile: ServerProfile {
        var value = ServerProfile()
        value.name = "Однакове ім’я"
        value.rootPath = ""
        return value
    }

    @Test("The actual store retains dates and creates separate snapshots with identical names")
    func reloadAndIdentity() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(destination: root.path)
        let source = profile
        let first = try #require(await store.take(profile: source, database: nil, trigger: .scheduled))
        let second = try #require(await store.take(profile: source, database: nil, trigger: .scheduled))
        #expect(first.id != second.id)
        #expect(UUID(uuidString: String(first.id.suffix(36))) != nil)
        let reopened = SnapshotStore(destination: root.path)
        #expect(reopened.lastError == nil)
        #expect(reopened.snapshots.map(\.id) == [second.id, first.id])
        #expect(abs(try #require(reopened.snapshots.first?.taken).timeIntervalSince(second.taken)) < 1)
        for snapshot in reopened.snapshots {
            #expect(FileManager.default.fileExists(atPath: reopened.folder(for: snapshot).appendingPathComponent("profile.json").path))
        }
        reopened.prune(keep: 1)
        #expect(reopened.snapshots.map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: first).path))
        #expect(SnapshotStore(destination: root.path).snapshots.map(\.id) == [second.id])
    }

    @Test("Legacy numeric and fractional ISO dates remain readable")
    func legacyDates() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (date, expected) in [("0", Date(timeIntervalSinceReferenceDate: 0)),
                                 (#""2026-11-07T12:00:00.125Z""#, Date(timeIntervalSince1970: 1794052800.125))] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("legacy"), withIntermediateDirectories: true)
            let json = "[{\"id\":\"legacy\",\"taken\":\(date)}]"
            try Data(json.utf8).write(to: root.appendingPathComponent("snapshots.json"))
            let store = SnapshotStore(destination: root.path)
            #expect(store.lastError == nil)
            #expect(try #require(store.snapshots.first?.taken) == expected)
        }
    }

    @Test("An index write failure preserves existing backups and removes only the new attempt")
    func failedWrite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(destination: root.path)
        let first = try #require(await store.take(profile: profile, database: nil))
        let index = root.appendingPathComponent("snapshots.json")
        let before = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let keep = index.appendingPathComponent("do-not-delete")
        try before.write(to: keep)
        #expect(await store.take(profile: profile, database: nil) == nil)
        #expect(store.lastError != nil)
        #expect(store.snapshots.map(\.id) == [first.id])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == [first.id, "snapshots.json"])
        store.delete(first)
        #expect(store.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: store.folder(for: first).path))
        #expect(store.snapshots.map(\.id) == [first.id])
        #expect(try Data(contentsOf: keep) == before)
    }

    @Test("Corrupt dates, duplicate IDs and external IDs cannot be silently overwritten")
    func damagedIndex() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in [#"[{"id":"valid","taken":"broken"}]"#,
                        #"[{"id":"../outside","taken":0}]"#,
                        #"[{"id":"x","taken":0},{"id":"x","taken":0}]"#] {
            let index = root.appendingPathComponent("snapshots.json")
            let data = Data(fixture.utf8)
            try data.write(to: index)
            let store = SnapshotStore(destination: root.path)
            #expect(store.lastError != nil)
            #expect(await store.take(profile: profile, database: nil) == nil)
            #expect(try Data(contentsOf: index) == data)
        }
    }
}
