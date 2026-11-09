import Foundation
import Security
import Testing
@testable import ServerMaster

/// Opt-in: starts a real MariaDB with an isolated datadir/socket/port and a
/// disposable file Keychain. No login-keychain items or working DBs are used.
@MainActor
@Suite("T1 isolated MariaDB and Keychain", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_DATABASE"] == "1"))
struct DatabaseKeychainTests {
    private final class PrivateKeychain {
        let keychain: SecKeychain
        let service = "com.adm1nsys.ServerMaster.test." + UUID().uuidString

        init(directory: URL) throws {
            let path = directory.appendingPathComponent("fixture.keychain-db").path
            let password = Data(UUID().uuidString.utf8)
            var reference: SecKeychain?
            let status = password.withUnsafeBytes {
                SecKeychainCreate(path, UInt32(password.count), $0.baseAddress, false, nil, &reference)
            }
            guard status == errSecSuccess, let reference else { throw KeychainError(status: status) }
            keychain = reference
        }

        func save(_ database: String, _ user: String, _ password: String) throws {
            try DatabaseCredentialStore.save(database: database, user: user, password: password, service: service, keychain: keychain)
        }
        func read(_ database: String) throws -> DatabaseCredentialStore.Credential? {
            try DatabaseCredentialStore.read(database: database, service: service, keychain: keychain)
        }
        func delete(_ database: String) throws {
            try DatabaseCredentialStore.delete(database: database, service: service, keychain: keychain)
        }
        var access: DatabaseCredentialAccess { .init(save: save, read: read, delete: delete) }
        func close() { SecKeychainDelete(keychain) }
    }

    @Test("Create, duplicates, imports/cancel, password/users, deletion and unavailable Keychain")
    func lifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("database-t1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = try PrivateKeychain(directory: root)
        defer { keychain.close() }
        let socket = "/tmp/sm-t1-\(UUID().uuidString.prefix(12)).sock"
        let port = try BuiltinHTTPS.freeBackendPort(excluding: 3307)
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("database"), socketPath: socket,
                                       port: port, credentials: keychain.access)
        defer { database.stopImmediately() }
        #expect(database.dataDirectory.hasPrefix(root.path))
        #expect(database.socketPath != "/tmp/servermaster-mysql.sock")
        #expect(database.port != 3307)
        try #require(database.isInstalled, "MariaDB must be installed before enabling this integration suite")
        await database.start()
        try #require(database.state == .running, "\(database.log.lines.map(\.text).joined(separator: "\n"))")

        let foreign = DatabaseService(runtimeDirectory: root.appendingPathComponent("other-datadir"),
                                      socketPath: "/tmp/other-\(UUID().uuidString.prefix(10)).sock", port: port,
                                      credentials: keychain.access)
        await foreign.refreshState()
        #expect(foreign.state != .running, "A different datadir must not be adopted")
        await foreign.start()
        if case .failed = foreign.state { } else { Issue.record("Busy foreign database was adopted") }
        #expect(foreign.processIdentifier == nil)
        #expect(!(await foreign.createDatabase(name: "t1_forbidden", user: "t1_forbidden", password: "unused")).succeeded)
        #expect(try await !database.databaseExists("t1_forbidden"))
        #expect((await database.query(sql: "SELECT 1;")).succeeded)

        let password = "T1-only-'\\пароль \(UUID().uuidString)"
        let created = await database.createDatabase(name: "t1_first", user: "t1_user", password: password)
        try #require(created.succeeded, "\(created.combined)")
        #expect(try keychain.read("t1_first") == .init(user: "t1_user", password: password))
        #expect(try await database.validatedSavedCredentials(for: "t1_first")?.password == password)

        // Updating the same Keychain key must replace, not duplicate, the item.
        try keychain.save("keychain_only", "before", "one")
        try keychain.save("keychain_only", "after", "two")
        #expect(try keychain.read("keychain_only") == .init(user: "after", password: "two"))
        try keychain.delete("keychain_only")
        try keychain.delete("keychain_only")
        #expect(try keychain.read("keychain_only") == nil)

        let duplicate = await database.createDatabase(name: "t1_first", user: "different_user", password: "wrong")
        #expect(!duplicate.succeeded)
        #expect(try keychain.read("t1_first")?.password == password)
        let reusedAccount = await database.createDatabase(name: "t1_collision", user: "t1_user", password: "wrong")
        #expect(!reusedAccount.succeeded)
        #expect(try await !database.databaseExists("t1_collision"))
        #expect(try keychain.read("t1_collision") == nil)
        #expect(!(await database.createDatabase(name: "bad-name;DROP", user: "t1_bad", password: "wrong")).succeeded)

        _ = await database.query(sql: "CREATE TABLE t1_first.sample (id INT PRIMARY KEY, value TEXT); INSERT INTO t1_first.sample VALUES (1, 'original');")
        let dump = root.appendingPathComponent("fixture.sql")
        try "DROP TABLE IF EXISTS sample; CREATE TABLE sample (id INT PRIMARY KEY, value TEXT); INSERT INTO sample VALUES (2, 'imported');".write(to: dump, atomically: true, encoding: .utf8)
        let refused = await database.importDump(from: dump, into: "t1_first", user: "wrong", password: "wrong")
        #expect(!refused.succeeded)
        var asked = false
        let cancelled = try await database.importDumpConfirmingReplacement(from: dump, into: "t1_first", user: "wrong", password: "wrong") { target in
            asked = true
            #expect(target == "t1_first")
            return false
        }
        #expect(asked && cancelled == nil)
        #expect((await database.query(sql: "SELECT value FROM t1_first.sample;")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "original")
        #expect(try keychain.read("t1_first")?.password == password)
        let confirmed = try await database.importDumpConfirmingReplacement(from: dump, into: "t1_first", user: "wrong", password: "wrong") { _ in true }
        #expect(confirmed?.succeeded == true)
        #expect((await database.query(sql: "SELECT value FROM t1_first.sample;")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "imported")
        #expect(try keychain.read("t1_first")?.password == password)

        let imported = try await database.importDumpConfirmingReplacement(from: dump, into: "t1_imported", user: "t1_import_user", password: "T1-import-only") { _ in
            Issue.record("A new database must not ask to replace data")
            return false
        }
        #expect(imported?.succeeded == true)
        #expect(try await database.validatedSavedCredentials(for: "t1_imported")?.user == "t1_import_user")

        let changed = await database.setPassword(of: .init(name: "t1_user", host: "127.0.0.1"), to: "T1-new-only")
        #expect(changed.succeeded)
        #expect(try keychain.read("t1_first") == nil)
        #expect(try keychain.read("t1_imported") != nil)
        // Simulate an old credential surviving a locked Keychain or external
        // password change: the UI-facing API must refuse to present it.
        try keychain.save("t1_first", "t1_user", password)
        do {
            _ = try await database.validatedSavedCredentials(for: "t1_first")
            Issue.record("An obsolete password was presented as current")
        } catch { #expect((error as NSError).domain == "ServerMaster.Database") }
        try keychain.save("t1_first", "t1_user", "T1-new-only")
        #expect(try await database.validatedSavedCredentials(for: "t1_first") != nil)
        let removedUser = await database.dropUser(.init(name: "t1_import_user", host: "localhost"))
        #expect(removedUser.succeeded)
        #expect(try keychain.read("t1_imported") == nil)
        #expect((await database.dropDatabase(name: "t1_first")).succeeded)
        #expect(try keychain.read("t1_first") == nil)
        #expect(try await !database.databaseExists("t1_first"))

        let unavailable = DatabaseCredentialAccess(save: { _, _, _ in throw KeychainError(status: errSecInteractionNotAllowed) },
            read: { _ in throw KeychainError(status: errSecInteractionNotAllowed) },
            delete: { _ in throw KeychainError(status: errSecInteractionNotAllowed) })
        let failing = DatabaseService(runtimeDirectory: root.appendingPathComponent("database"), socketPath: socket,
                                      port: port, credentials: unavailable)
        await failing.refreshState()
        try #require(failing.state == .running)
        #expect((await failing.createDatabase(name: "t1_keychain_failure", user: "t1_failure_user", password: "T1-failure-only")).succeeded)
        #expect(try await failing.databaseExists("t1_keychain_failure"))
        #expect(failing.log.lines.contains { $0.stream == .stderr })
        #expect(failing.hasSessionOnlyCredentials(for: "t1_keychain_failure"))
        #expect(try await failing.validatedSavedCredentials(for: "t1_keychain_failure")?.password == "T1-failure-only")
        do {
            _ = try await failing.validatedSavedCredentials(for: "no_session_fallback")
            Issue.record("Unavailable Keychain was reported as valid credentials")
        } catch { #expect(error is KeychainError) }
        #expect((await failing.dropDatabase(name: "t1_keychain_failure")).succeeded)
        #expect(!failing.hasSessionOnlyCredentials(for: "t1_keychain_failure"))
        #expect(try await !failing.databaseExists("t1_keychain_failure"))
        let redacted = await database.query(sql: "CREATE USER 't1_user'@'localhost' IDENTIFIED BY \(DatabaseService.quoteString(password));", redacting: [password])
        #expect(!redacted.succeeded)
        #expect(!redacted.combined.contains(password))
        #expect(!redacted.combined.contains(DatabaseService.quoteString(password)))
        #expect(!database.log.lines.map(\.text).joined().contains(password))
        #expect(!failing.log.lines.map(\.text).joined().contains("T1-failure-only"))
        await database.stop()
        #expect(database.state == .stopped)
        #expect(PortScanner.isPortFree(port, host: "127.0.0.1"))
    }
}
