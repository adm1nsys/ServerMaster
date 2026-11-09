import Foundation
import Testing
@testable import ServerMaster

@MainActor
@Suite("Account permissions and command redaction", .serialized)
struct AccountParityTests {
    @Test func protectedAccounts() async {
        let database = DatabaseService()
        for name in ["root", "ROOT", "mysql.sys", "mysql.session", "mysql.infoschema", "mysql", "mariadb.sys", "servermaster_panel"] {
            let user = DatabaseUser(name: name, host: "192.0.2.55")
            #expect(user.isProtected)
            let operations = [
                await database.createUser(name, host: user.host, password: "fixture"),
                await database.dropUser(user),
                await database.setPassword(of: user, to: "fixture"),
                await database.grant("ALL PRIVILEGES", on: "fixture", to: user),
                await database.makeReadOnly(on: "fixture", for: user),
                await database.revokeAll(on: "fixture", from: user),
                await database.createDatabase(name: "fixture", user: name, password: "fixture")
            ]
            #expect(operations.allSatisfy { !$0.succeeded && $0.stderr == DatabaseUser.protectedMessage })
        }
        #expect(!DatabaseUser(name: "site_user", host: "localhost").isProtected)
    }

    @Test func accountHosts() async {
        for host in ["localhost", "127.0.0.1", "192.0.2.25", "2001:db8::1", "db.example.com", "%.example.com", "192.0.2.%", "10.0.0.0/255.255.255.0", "%", "_"] {
            #expect(DatabaseUser.normalizedHost(host) == host)
            #expect(DatabaseUser.normalizedHost("  " + host + "  ") == host)
        }
        let database = DatabaseService()
        for host in ["", "   ", "host name", "host\nname", "host\tname", "host\u{0}name"] {
            #expect(DatabaseUser.normalizedHost(host) == nil)
            let result = await database.createUser("test_host", host: host, password: "fixture")
            #expect(!result.succeeded)
            #expect(result.stderr == String(localized: "Enter an account host without spaces or control characters."))
        }
    }

    @Test func scopedReplacement() throws {
        let user = DatabaseUser(name: "site", host: "localhost")
        let statements = try DatabaseService.readOnlyStatements(on: "first", for: user, grants: [
            "GRANT USAGE ON *.* TO 'site'@'localhost'",
            "GRANT ALL PRIVILEGES ON `first`.* TO 'site'@'localhost' WITH GRANT OPTION",
            "GRANT ALL PRIVILEGES ON `second`.* TO 'site'@'localhost'"
        ])
        #expect(statements.count == 3)
        #expect(statements[0].hasPrefix("REVOKE ALL PRIVILEGES ON `first`.*"))
        #expect(statements[1].hasPrefix("REVOKE GRANT OPTION ON `first`.*"))
        #expect(statements[2].hasPrefix("GRANT SELECT ON `first`.*"))
        #expect(!statements.joined().contains("second"))
    }

    @Test func broaderGrantsRefused() {
        let user = DatabaseUser(name: "site", host: "%")
        for grants in [[], ["GRANT ALL PRIVILEGES ON *.* TO 'site'@'%'"],
                       ["GRANT `writer_role` TO 'site'@'%'"],
                       ["GRANT UPDATE (value) ON `first`.`table` TO 'site'@'%'"],
                       ["GRANT INSERT ON `fi%`.* TO 'site'@'%'"],
                       ["unrecognized"]] {
            #expect(throws: DatabaseService.AccountPolicyError.self) {
                try DatabaseService.readOnlyStatements(on: "first", for: user, grants: grants)
            }
        }
    }

    @Test func displaySecrets() {
        let secrets = ["test-only-\"\\пароль with spaces", "second=test-only"]
        let plan = LaunchPlan(executable: "/tmp/http server", arguments: ["--password", secrets[0], "--port", "8080", "--password=" + secrets[1]],
                              workingDirectory: "/tmp", environment: [:])
        #expect(!plan.displayCommand.contains(secrets[0]))
        #expect(!plan.displayCommand.contains(secrets[1]))
        #expect(plan.displayCommand.contains("--password ********"))
        #expect(plan.displayCommand.contains("--password=********"))
        #expect(plan.arguments[1] == secrets[0])
        #expect(plan.arguments.last == "--password=" + secrets[1])
        let log = ConsoleLog()
        log.system(plan.displayCommand)
        #expect(!log.plainText.contains("test-only"))
    }
}

@MainActor
@Suite("Account privilege live MariaDB", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_ACCOUNTS"] == "1"))
struct AccountParityLiveTests {
    @Test func accountEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-account-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RuntimePortLease.acquire(excluding: 3307)
        var credentials: [String: DatabaseCredentialStore.Credential] = [:]
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("database with spaces"),
            socketPath: "/tmp/sm-a3-\(UUID().uuidString.prefix(9)).sock", port: lease.port,
            credentials: .init(save: { credentials[$0] = .init(user: $1, password: $2) },
                               read: { credentials[$0] }, delete: { credentials.removeValue(forKey: $0) }))
        defer { database.stopImmediately() }
        lease.allowChildBind()
        await database.start()
        try #require(database.state == .running, "\(database.log.plainText)")
        let temp = await database.query(sql: "SELECT @@tmpdir;")
        try #require(temp.succeeded)
        let actualTemp = temp.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: actualTemp).standardizedFileURL.path == URL(fileURLWithPath: database.temporaryDirectory).standardizedFileURL.path)
        let first = "A3-old-'\\пароль"
        let changed = "A3-new-'\\пароль"
        try #require((await database.createDatabase(name: "a3_site", user: "a3_user", password: first)).succeeded)
        try #require((await database.createDatabase(name: "a3_other", user: "a3_other", password: "unrelated")).succeeded)
        #expect(credentials["a3_site"]?.password == first)
        let account = DatabaseUser(name: "a3_user", host: "127.0.0.1")
        let result = await database.setPassword(of: account, to: changed)
        try #require(result.succeeded, "\(result.stderr)")
        #expect(credentials["a3_site"] == nil)
        #expect(credentials["a3_other"]?.password == "unrelated")
        let client = try #require(database.clientBinary)
        func login(_ password: String) async -> Bool {
            await ProcessRunner.run(client, ["--no-defaults", "--protocol=TCP", "-h", "127.0.0.1", "-P", String(lease.port), "-u", account.name, "-sN"],
                                    env: ["MYSQL_PWD": password], stdin: "SELECT 1;").succeeded
        }
        #expect(await login(changed))
        #expect(!(await login(first)))
        // Failure must leave unrelated credentials and all other accounts alone.
        let failed = await database.setPassword(of: .init(name: "a3_missing", host: "127.0.0.1"), to: changed)
        #expect(!failed.succeeded)
        #expect(!failed.combined.contains(changed))
        #expect(credentials["a3_other"]?.password == "unrelated")
        #expect(await login(changed))
        for host in ["192.0.2.25", "2001:db8::1", "%.example.com", "192.0.2.%", "10.0.0.0/255.255.255.0"] {
            let created = await database.createUser("a3_remote", host: host, password: first)
            try #require(created.succeeded, "\(created.stderr)")
            let users = await database.users()
            let remote = try #require(users.first { $0.name == "a3_remote" && $0.host == host })
            #expect((await database.setPassword(of: remote, to: changed)).succeeded)
            #expect((await database.dropUser(remote)).succeeded)
        }
        // Quoted account components must stay data, even when they contain SQL syntax.
        let quoted = "a3'name"
        let created = await database.createUser(quoted, host: "localhost", password: first)
        try #require(created.succeeded, "\(created.stderr)")
        #expect((await database.dropUser(.init(name: quoted, host: "localhost"))).succeeded)
        #expect(try await database.databaseExists("a3_site"))
        #expect(!database.log.plainText.contains(first))
        #expect(!database.log.plainText.contains(changed))
        await database.stop()
    }

    @Test func lifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RuntimePortLease.acquire(excluding: 3307)
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("db"),
            socketPath: "/tmp/sm-acc-\(UUID().uuidString.prefix(9)).sock", port: lease.port,
            credentials: .init(save: { _,_,_ in }, read: { _ in nil }, delete: { _ in }))
        defer { database.stopImmediately() }
        lease.allowChildBind()
        await database.start()
        try #require(database.state == .running, "\(database.log.plainText)")
        let setup = await database.query(sql: """
        CREATE DATABASE acc_first; CREATE DATABASE acc_second;
        CREATE TABLE acc_first.sample (id INT); CREATE TABLE acc_second.sample (id INT);
        CREATE USER 'acc_site'@'127.0.0.1' IDENTIFIED BY 'fixture-only';
        CREATE USER 'root'@'192.0.2.55' IDENTIFIED BY 'fixture-only';
        GRANT ALL PRIVILEGES ON acc_first.* TO 'acc_site'@'127.0.0.1' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON acc_second.* TO 'acc_site'@'127.0.0.1';
        """)
        try #require(setup.succeeded, "\(setup.stderr)")
        let user = DatabaseUser(name: "acc_site", host: "127.0.0.1")
        let changed = await database.makeReadOnly(on: "acc_first", for: user)
        try #require(changed.succeeded, "\(changed.stderr)")
        let client = try #require(database.clientBinary)
        func asSite(_ sql: String) async -> CommandResult {
            await ProcessRunner.run(client, ["--no-defaults", "--protocol=TCP", "-h", "127.0.0.1", "-P", String(lease.port), "-u", "acc_site", "-sN"], env: ["MYSQL_PWD": "fixture-only"], stdin: sql)
        }
        #expect((await asSite("SELECT * FROM acc_first.sample;")).succeeded)
        #expect(!(await asSite("INSERT INTO acc_first.sample VALUES (1);")).succeeded)
        #expect((await asSite("INSERT INTO acc_second.sample VALUES (2);")).succeeded)
        #expect((await database.makeReadOnly(on: "acc_first", for: user)).succeeded)
        let grants = await database.grants(of: user)
        #expect(!grants.contains { $0.contains("acc_first") && $0.contains("WITH GRANT OPTION") })
        let synthetic = DatabaseUser(name: "root", host: "192.0.2.55")
        #expect(!(await database.dropUser(synthetic)).succeeded)
        #expect(!(await database.setPassword(of: synthetic, to: "blocked")).succeeded)
        #expect((await database.query(sql: "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host='192.0.2.55';")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        // Refuse a broader global grant without taking it away or claiming read-only.
        try #require((await database.query(sql: "GRANT INSERT ON *.* TO 'acc_site'@'127.0.0.1';")).succeeded)
        #expect(!(await database.makeReadOnly(on: "acc_first", for: user)).succeeded)
        #expect((await asSite("INSERT INTO acc_first.sample VALUES (3);")).succeeded)
        try #require((await database.query(sql: "REVOKE INSERT ON *.* FROM 'acc_site'@'127.0.0.1'; GRANT UPDATE ON acc_first.sample TO 'acc_site'@'127.0.0.1';")).succeeded)
        #expect(!(await database.makeReadOnly(on: "acc_first", for: user)).succeeded)
        // The dedicated internal panel setup still works, despite the public mutation guard.
        #expect((await database.grantPanelAccount(name: DatabaseAdminPanel.accountName, password: "panel-fixture-only")).succeeded)
        await database.stop()
    }
}
