//
//  DatabaseService.swift
//  ServerMaster
//
//  A managed MariaDB/MySQL instance: its own data folder, its own port.
//  The system installation is left alone — brew services stay as they are.
//

import Foundation
import Observation
import AppKit

nonisolated struct DatabaseInfo: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var tables: Int
    var sizeMB: Double
}

nonisolated enum DatabaseState: Equatable, Sendable {
    case notInstalled
    case stopped
    case initializing
    case starting
    case running
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .notInstalled: return String(localized: "Not installed")
        case .stopped:      return String(localized: "Stopped")
        case .initializing: return String(localized: "Preparing the data directory…")
        case .starting:     return String(localized: "Starting…")
        case .running:      return String(localized: "Running")
        case .stopping:     return String(localized: "Stopping…")
        case .failed:       return String(localized: "Error")
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping || self == .initializing }
    var isActive: Bool { self == .running || self == .starting }
}

@Observable
final class DatabaseService {

    private(set) var state: DatabaseState = .stopped
    private(set) var databases: [DatabaseInfo] = []
    private(set) var version: String = ""
    private(set) var processIdentifier: Int32?

    let log = ConsoleLog()

    /// The default port differs from 3306 so it does not clash
    /// with a system MySQL the user may already have.
    var port: Int = 3307

    private var process: Process?
    private var logTail: Process?
    private var creatingDatabase = false
    private let runtimeOverride: URL?
    private let socketOverride: String?
    private let credentialAccess: DatabaseCredentialAccess
    /// If Keychain rejects a new credential, keep it only until this process
    /// exits so wizard-generated passwords can still be copied by the user.
    private var sessionOnlyCredentials: [String: DatabaseCredentialStore.Credential] = [:]

    init(runtimeDirectory: URL? = nil, socketPath: String? = nil, port: Int = 3307,
         credentials: DatabaseCredentialAccess = .system) {
        self.runtimeOverride = runtimeDirectory
        self.socketOverride = socketPath
        self.port = port
        self.credentialAccess = credentials
    }

    func savedCredentials(for database: String) throws -> DatabaseCredentialStore.Credential? {
        if let credential = sessionOnlyCredentials[database] { return credential }
        return try credentialAccess.read(database)
    }

    func hasSessionOnlyCredentials(for database: String) -> Bool { sessionOnlyCredentials[database] != nil }

    /// Keychain deletion may have failed while locked, or an account may have
    /// been changed externally. Never present a stale password as current.
    func validatedSavedCredentials(for database: String) async throws -> DatabaseCredentialStore.Credential? {
        guard let credential = try savedCredentials(for: database) else { return nil }
        guard state == .running, let client = clientBinary else {
            throw NSError(domain: "ServerMaster.Database", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Start the database to verify its saved credentials.")])
        }
        let result = await ProcessRunner.run(client, defaultsArguments + ["--protocol=TCP", "-h", host, "-P", String(port),
            "--user=\(credential.user)", "--database=\(database)", "-sN"],
            env: ["MYSQL_PWD": credential.password], stdin: "SELECT 1;\n", timeout: 15)
        guard result.succeeded else {
            throw NSError(domain: "ServerMaster.Database", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Saved credentials could not be verified. Use the account details from your site configuration.")])
        }
        return credential
    }

    /// Consult the server rather than the potentially stale sidebar list.
    func databaseExists(_ name: String) async throws -> Bool {
        let result = await query(sql: "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = \(Self.quoteString(name));")
        guard result.succeeded, let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "ServerMaster.Database", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not check whether the database exists.")])
        }
        return count > 0
    }

    /// A database credential describes the pair of local accounts created by
    /// the wizard. Changing either account independently makes that summary
    /// ambiguous. Forget it instead of displaying a potentially stale password.
    func invalidateSavedCredentials(for user: DatabaseUser) async {
        guard ["localhost", "127.0.0.1"].contains(user.host) else { return }
        await reloadDatabases()
        for database in databases {
            do {
                if try savedCredentials(for: database.name)?.user == user.name {
                    sessionOnlyCredentials.removeValue(forKey: database.name)
                    try credentialAccess.delete(database.name)
                }
            } catch {
                log.append(String(localized: "Saved database credentials could not be refreshed: \(error.localizedDescription)"), stream: .stderr)
            }
        }
    }

    var dataDirectory: String { runtimeOverride?.appendingPathComponent("data").path ?? AppPaths.subdir("Database/data").path }
    var runtimeDirectory: String { runtimeOverride?.path ?? AppPaths.subdir("Database").path }
    var errorLogPath: String { (runtimeDirectory as NSString).appendingPathComponent("error.log") }
    var temporaryDirectory: String { (runtimeDirectory as NSString).appendingPathComponent("tmp") }

    /// A UNIX socket path is limited to 104 bytes and Application Support is long —
    /// so the socket goes into /tmp.
    var socketPath: String { socketOverride ?? "/tmp/servermaster-mysql.sock" }
    private var defaultsArguments: [String] { runtimeOverride == nil ? [] : ["--no-defaults"] }

    /// Ready-made connection details — pasted into a CMS installer.
    var host: String { "127.0.0.1" }
    var connectionSummary: String { "\(host):\(String(port))" }

    // MARK: - Availability

    var serverBinary: String? {
        ShellEnvironment.shared.which("mariadbd") ?? ShellEnvironment.shared.which("mysqld")
    }

    var clientBinary: String? {
        ShellEnvironment.shared.which("mariadb") ?? ShellEnvironment.shared.which("mysql")
    }

    var installBinary: String? {
        ShellEnvironment.shared.which("mariadb-install-db") ?? ShellEnvironment.shared.which("mysql_install_db")
    }

    var isInstalled: Bool { serverBinary != nil && clientBinary != nil }

    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: (dataDirectory as NSString).appendingPathComponent("mysql"))
    }

    // MARK: - Startup

    func refreshState() async {
        guard isInstalled else { state = .notInstalled; return }
        if let pid = processIdentifier, PrivilegedLauncher.isAlive(pid: pid) {
            state = .running
        } else if !state.isBusy {
            // Our instance may already be up from a previous run of the application.
            if await ping() {
                state = .running
            } else if state.isActive {
                state = .stopped
            }
        }
    }

    func start() async {
        guard isInstalled else {
            state = .notInstalled
            log.append(String(localized: "MariaDB is not installed. Install it on the Dependencies tab."),
                       stream: .stderr)
            return
        }
        guard !state.isActive && !state.isBusy else { return }

        // Is the port taken by someone else?
        if !PortScanner.isPortFree(port, host: host) {
            if await ping() {
                log.system(String(localized: "The database is already running on port \(String(port))."))
                state = .running
                await reloadDatabases()
                return
            }
            let occupants = await PortScanner.processesListening(onPort: port)
            let who = occupants.map { "\($0.command) (PID \($0.pid))" }.joined(separator: ", ")
            let message = String(localized: "Port \(String(port)) is taken by another process: \(who)")
            log.append(message, stream: .stderr)
            state = .failed(message)
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: temporaryDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            let message = String(localized: "Could not prepare database temporary files: \(error.localizedDescription)")
            log.append(message, stream: .stderr)
            state = .failed(message)
            return
        }

        if !isInitialized {
            state = .initializing
            guard await initializeDataDirectory() else { return }
        }

        state = .starting
        log.system(String(localized: "Starting the database on port \(String(port))…"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary!)
        process.arguments = defaultsArguments + [
            "--datadir=\(dataDirectory)",
            "--tmpdir=\(temporaryDirectory)",
            "--port=\(String(port))",
            "--socket=\(socketPath)",
            "--pid-file=\((runtimeDirectory as NSString).appendingPathComponent("mysql.pid"))",
            "--log-error=\(errorLogPath)",
            "--skip-name-resolve",
            "--bind-address=127.0.0.1"
        ]
        process.environment = ShellEnvironment.shared.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            let message = error.localizedDescription
            log.append(message, stream: .stderr)
            state = .failed(message)
            return
        }

        self.process = process
        processIdentifier = process.processIdentifier
        startLogTail()

        // Wait until it is ready to accept connections.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await ping() {
                state = .running
                version = await readVersion()
                log.system(String(localized: "Database ready: \(version)"))
                await reloadDatabases()
                return
            }
            if !process.isRunning { break }
        }

        let tail = lastErrorLines()
        let message = tail.isEmpty
            ? String(localized: "The database did not respond in time.")
            : tail
        log.append(message, stream: .stderr)
        state = .failed(message)
        stopLogTail()
        if process.isRunning { process.terminate() }
        self.process = nil
        processIdentifier = nil
    }

    func stop() async {
        guard state.isActive || process != nil else { return }
        state = .stopping
        log.system(String(localized: "Stopping the database…"))

        // Graceful shutdown: mysqladmin/mariadb-admin closes the tables properly.
        if let admin = ShellEnvironment.shared.which("mariadb-admin")
            ?? ShellEnvironment.shared.which("mysqladmin") {
            _ = await ProcessRunner.run(admin,
                                        defaultsArguments + ["--protocol=SOCKET", "--socket=\(socketPath)", "-u", "root", "shutdown"],
                                        timeout: 30)
        }

        if let process {
            for _ in 0..<40 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        stopLogTail()
        process = nil
        processIdentifier = nil
        databases = []
        state = .stopped
        log.system(String(localized: "Database stopped."))
    }

    func stopImmediately() {
        stopLogTail()
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: - Databases

    @discardableResult
    func reloadDatabases() async -> Bool {
        guard state == .running else { databases = []; return false }
        let sql = """
        SELECT s.schema_name,
               COALESCE(COUNT(t.table_name), 0),
               COALESCE(ROUND(SUM(t.data_length + t.index_length) / 1048576, 1), 0)
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
        WHERE s.schema_name NOT IN ('information_schema','mysql','performance_schema','sys')
        GROUP BY s.schema_name ORDER BY s.schema_name;
        """
        let result = await query(sql: sql)
        guard result.succeeded else { return false }

        databases = result.stdout
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count >= 3 else { return nil }
                return DatabaseInfo(name: parts[0],
                                    tables: Int(parts[1]) ?? 0,
                                    sizeMB: Double(parts[2]) ?? 0)
            }
        return true
    }

    /// Creates a database and a user with full rights on it.
    func createDatabase(name: String, user: String, password: String) async -> CommandResult {
        guard !DatabaseUser.isProtectedName(user) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: DatabaseUser.protectedMessage)
        }
        guard state == .running else {
            return CommandResult(exitCode: 1, stdout: "", stderr: String(localized: "The database server is not running."))
        }
        guard !creatingDatabase else {
            return CommandResult(exitCode: 1, stdout: "", stderr: String(localized: "Another database is being created. Try again when it finishes."))
        }
        creatingDatabase = true
        defer { creatingDatabase = false }
        guard let db = validIdentifier(name), let account = validIdentifier(user) else {
            return CommandResult(exitCode: 1, stdout: "",
                                 stderr: String(localized: "A database or user name may contain only letters, digits and underscores — nothing was created."))
        }
        do {
            guard try await !databaseExists(db) else {
                return CommandResult(exitCode: 1, stdout: "", stderr: String(localized: "This database already exists. Open it or import into it instead."))
            }
        } catch {
            return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
        // Never silently reuse an existing account: CREATE USER IF NOT EXISTS
        // does not apply the supplied password, so remembering it would lie.
        let accounts = await query(sql: "SELECT COUNT(*) FROM mysql.user WHERE User = \(Self.quoteString(account)) AND Host IN ('127.0.0.1', 'localhost');")
        guard accounts.succeeded,
              let count = Int(accounts.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), count == 0 else {
            return CommandResult(exitCode: 1, stdout: "", stderr: String(localized: "This user already exists or could not be checked. Choose a new user name; its password has not been changed."))
        }
        let escaped = Self.quoteString(password)
        let sql = """
        CREATE DATABASE `\(db)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER '\(account)'@'127.0.0.1' IDENTIFIED BY \(escaped);
        CREATE USER '\(account)'@'localhost' IDENTIFIED BY \(escaped);
        GRANT ALL PRIVILEGES ON `\(db)`.* TO '\(account)'@'127.0.0.1';
        GRANT ALL PRIVILEGES ON `\(db)`.* TO '\(account)'@'localhost';
        FLUSH PRIVILEGES;
        """
        let result = await query(sql: sql, redacting: [password])
        if result.succeeded {
            log.system(String(localized: "Created database “\(db)” and user “\(account)”."))
            do {
                try credentialAccess.save(db, account, password)
                sessionOnlyCredentials.removeValue(forKey: db)
            } catch {
                sessionOnlyCredentials[db] = .init(user: account, password: password)
                // Creation is already complete. Keep the database usable and
                // report the separate Keychain problem without exposing its
                // password in the console.
                log.append(String(localized: "Database created, but its credentials could not be saved in Keychain: \(error.localizedDescription)"), stream: .stderr)
            }
            await reloadDatabases()
        } else {
            log.append(result.combined, stream: .stderr)
        }
        return result
    }

    func dropDatabase(name: String) async -> CommandResult {
        guard state == .running else {
            return CommandResult(exitCode: 1, stdout: "", stderr: String(localized: "The database server is not running."))
        }
        // Dropping names an EXISTING database, which may legitimately contain
        // anything — including the mangled leftovers of an older version of this
        // code. So it is quoted rather than filtered.
        guard let db = Self.quoteIdentifier(name) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        let result = await query(sql: "DROP DATABASE IF EXISTS \(db);")
        if result.succeeded {
            log.system(String(localized: "Database “\(name)” deleted."))
            sessionOnlyCredentials.removeValue(forKey: name)
            do {
                try credentialAccess.delete(name)
            } catch {
                log.append(String(localized: "Database deleted, but its saved credentials could not be removed from Keychain: \(error.localizedDescription)"), stream: .stderr)
            }
            await reloadDatabases()
        }
        return result
    }

    /// Creates (or re-creates) the account the web admin panel signs in with.
    ///
    /// It is deliberately not root: both Adminer and phpMyAdmin refuse a
    /// passwordless account, and giving root a password would break every CMS
    /// already installed against “no password”.
    @discardableResult
    func grantPanelAccount(name: String, password: String) async -> CommandResult {
        guard let account = validIdentifier(name) else {
            return CommandResult(exitCode: 1, stdout: "",
                                 stderr: String(localized: "A user name may contain only letters, digits and underscores."))
        }
        let escaped = password.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE USER IF NOT EXISTS '\(account)'@'127.0.0.1' IDENTIFIED BY '\(escaped)';
        ALTER USER '\(account)'@'127.0.0.1' IDENTIFIED BY '\(escaped)';
        GRANT ALL PRIVILEGES ON *.* TO '\(account)'@'127.0.0.1' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        """
        return await query(sql: sql, redacting: [password])
    }

    // MARK: - Browsing and editing

    nonisolated struct TableInfo: Identifiable, Sendable, Hashable {
        var id: String { name }
        var name: String
        var rows: Int
    }

    nonisolated struct QueryResult: Sendable {
        var columns: [String] = []
        var rows: [[String?]] = []
        var message: String = ""
        var succeeded = true
        var affectedRows: Int?
    }

    /// Tables of the selected database.
    // MARK: - Importing a dump from somewhere else

    nonisolated struct ImportOutcome: Sendable {
        var succeeded: Bool
        var message: String
        /// The file actually imported — useful when it came out of an archive
        /// and is not the file that was chosen.
        var source: String?
    }

    /// UI and integration tests share the same confirmation/cancel path.
    /// Returning nil means Cancel: no import, user creation or credential write.
    func importDumpConfirmingReplacement(from url: URL, into name: String, user: String, password: String,
                                         confirm: @MainActor (String) -> Bool) async throws -> ImportOutcome? {
        let existing = try await databaseExists(name)
        if existing && !confirm(name) { return nil }
        return await importDump(from: url, into: name, user: user, password: password, allowExisting: existing)
    }

    /// Loads a database from a file someone has: a plain `.sql`, a gzipped one,
    /// or an archive with one inside.
    ///
    /// The archive case is the reason this exists. A Joomla backup is a zip with
    /// the dump buried in it, and getting that into a database by hand means
    /// unpacking, hunting for the right `.sql`, creating the database, creating a
    /// user, granting, and piping — every step of which has its own way of going
    /// wrong at eleven at night.
    ///
    /// The target database is created if it is not there, and named on the
    /// client command line, because a dump exported from inside phpMyAdmin
    /// usually carries no CREATE DATABASE of its own — only tables.
    func importDump(from url: URL, into name: String, user: String, password: String,
                    allowExisting: Bool = false) async -> ImportOutcome {
        guard state == .running else {
            return ImportOutcome(succeeded: false,
                                 message: String(localized: "The database server is not running."),
                                 source: nil)
        }
        guard validIdentifier(name) != nil else {
            return ImportOutcome(succeeded: false,
                                 message: String(localized: "A database name may contain only letters, digits and underscores."),
                                 source: nil)
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("servermaster-import-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let extracted = await Self.extractSQL(from: url, into: staging)
        guard let found = extracted.file else {
            return ImportOutcome(succeeded: false,
                                 message: extracted.problem ?? String(localized: "No dump was found."),
                                 source: nil)
        }

        do {
            if try await databaseExists(name) {
                guard allowExisting else {
                    return ImportOutcome(succeeded: false,
                                         message: String(localized: "Confirm importing into the existing database first. Its tables and data may be replaced."), source: nil)
                }
            } else {
                let created = await createDatabase(name: name, user: user, password: password)
                guard created.succeeded else {
                    return ImportOutcome(succeeded: false, message: created.stderr, source: nil)
                }
            }
        } catch {
            return ImportOutcome(succeeded: false, message: error.localizedDescription, source: nil)
        }

        guard let client = clientBinary else {
            return ImportOutcome(succeeded: false,
                                 message: String(localized: "The database client was not found."),
                                 source: nil)
        }
        let result = await ProcessRunner.run(
            "/bin/sh",
            ["-c",
             "\(ProcessRunner.shellQuote(client)) \(defaultsArguments.joined(separator: " ")) --protocol=TCP --host=127.0.0.1 "
             + "--port=\(port) --user=root --database=\(ProcessRunner.shellQuote(name)) "
             + "< \(ProcessRunner.shellQuote(found.path))"],
            timeout: 1800)

        if result.succeeded {
            await reloadDatabases()
            let tables = await tables(in: name).count
            log.system(String(localized: "Imported \(found.lastPathComponent) into “\(name)” — \(tables) tables."))
            return ImportOutcome(succeeded: true,
                                 message: String(localized: "Imported \(tables) tables into “\(name)”."),
                                 source: found.lastPathComponent)
        }
        log.append(result.combined, stream: .stderr)
        return ImportOutcome(succeeded: false,
                             message: result.stderr.isEmpty
                                ? String(localized: "The dump could not be loaded.")
                                : result.stderr,
                             source: found.lastPathComponent)
    }

    /// Finds the SQL in whatever was handed over.
    ///
    /// The biggest `.sql` in an archive is the one wanted: a Joomla backup also
    /// carries small installer scripts, and the dump of a real site dwarfs them.
    private static func extractSQL(from url: URL, into staging: URL) async -> (file: URL?, problem: String?) {
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".sql") { return (url, nil) }

        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        if name.hasSuffix(".sql.gz") || name.hasSuffix(".gz") {
            let out = staging.appendingPathComponent("dump.sql")
            let result = await ProcessRunner.run(
                "/bin/sh",
                ["-c", "/usr/bin/gzip -dc \(ProcessRunner.shellQuote(url.path)) > \(ProcessRunner.shellQuote(out.path))"],
                timeout: 600)
            return result.succeeded ? (out, nil)
                                    : (nil, String(localized: "The file could not be unzipped."))
        }

        let unpack: CommandResult
        if name.hasSuffix(".zip") {
            unpack = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, staging.path], timeout: 900)
        } else if name.hasSuffix(".tar") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            unpack = await ProcessRunner.run("/usr/bin/tar", ["-xf", url.path, "-C", staging.path], timeout: 900)
        } else {
            return (nil, String(localized: "That is not a dump this can read — expected .sql, .sql.gz, .zip or .tar.gz."))
        }
        guard unpack.succeeded else {
            return (nil, String(localized: "The archive could not be unpacked."))
        }

        return findSQL(in: staging)
    }

    /// Keep DirectoryEnumerator inside a synchronous scope; its iterator is
    /// unavailable from asynchronous contexts in Swift 6.
    private nonisolated static func findSQL(in staging: URL) -> (file: URL?, problem: String?) {
        guard let walk = FileManager.default.enumerator(at: staging,
                                                        includingPropertiesForKeys: [.fileSizeKey]) else {
            return (nil, String(localized: "The archive could not be read."))
        }
        var best: (url: URL, size: Int)?
        for case let file as URL in walk where file.pathExtension.lowercased() == "sql" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > (best?.size ?? -1) { best = (file, size) }
        }
        guard let best else {
            return (nil, String(localized: "No .sql file was found inside the archive."))
        }
        return (best.url, nil)
    }

    // MARK: - Dumping and loading

    /// mariadb-dump under whichever name it goes by here. Written straight to a
    /// file rather than through a pipe: a dump of any real site is large enough
    /// that holding it in memory to write it out again is a waste.
    func dump(_ name: String, to path: String) async -> Bool {
        guard state == .running, let tool = ShellEnvironment.shared.which("mariadb-dump")
                ?? ShellEnvironment.shared.which("mysqldump"),
              Self.quoteIdentifier(name) != nil else { return false }

        let result = await ProcessRunner.run(
            "/bin/sh",
            ["-c",
                        "\(ProcessRunner.shellQuote(tool)) \(defaultsArguments.map(ProcessRunner.shellQuote).joined(separator: " ")) --protocol=TCP --host=127.0.0.1 "
                        + "--port=\(port) --user=root --single-transaction --routines --events "
                        + "--databases \(ProcessRunner.shellQuote(name)) "
                        + "> \(ProcessRunner.shellQuote(path))"])
        if !result.succeeded { log.append(result.combined, stream: .stderr) }
        return result.succeeded
    }

    /// Loads a dump back. The dump was written with `--databases`, so it carries
    /// its own CREATE DATABASE and USE — the target name is not needed inside,
    /// only to say which one is being replaced.
    func load(_ path: String, into name: String) async -> Bool {
        guard state == .running, let client = clientBinary,
              FileManager.default.fileExists(atPath: path),
              Self.quoteIdentifier(name) != nil else { return false }

        let result = await ProcessRunner.run(
            "/bin/sh",
            ["-c",
                        "\(ProcessRunner.shellQuote(client)) \(defaultsArguments.map(ProcessRunner.shellQuote).joined(separator: " ")) --protocol=TCP --host=127.0.0.1 "
                        + "--port=\(port) --user=root < \(ProcessRunner.shellQuote(path))"])
        if result.succeeded {
            await reloadDatabases()
        } else {
            log.append(result.combined, stream: .stderr)
        }
        return result.succeeded
    }

    func tables(in database: String) async -> [TableInfo] {
        let name = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let result = await query(sql: """
            SELECT table_name, COALESCE(table_rows, 0)
            FROM information_schema.tables
            WHERE table_schema = \(Self.quoteString(name))
            ORDER BY table_name;
            """)
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { return nil }
            return TableInfo(name: parts[0], rows: Int(parts[1]) ?? 0)
        }
    }

    /// Pages are ordered by the full primary key where one exists.
    func preview(table: String, in database: String, limit: Int = 100, offset: Int = 0) async -> QueryResult {
        guard let quoted = Self.quoteIdentifier(table) else {
            return QueryResult(message: String(localized: "Invalid table name."), succeeded: false)
        }
        guard offset >= 0 else {
            return QueryResult(message: String(localized: "Invalid row offset."), succeeded: false)
        }
        let schema = await columns(of: table, in: database)
        let keys = schema.filter(\.isPrimaryKey).compactMap { Self.quoteIdentifier($0.name) }
        let ordering = keys.isEmpty ? "" : " ORDER BY " + keys.joined(separator: ", ")
        var result = await run(sql: "SELECT * FROM \(quoted)\(ordering) LIMIT \(max(1, min(limit, 1000))) OFFSET \(offset);",
                               database: database)
        if result.succeeded && result.columns.isEmpty {
            result.columns = schema.map(\.name)
        }
        return result
    }

    /// An arbitrary query. Returns a result table or the error text.
    func run(sql: String, database: String?) async -> QueryResult {
        guard state == .running else {
            return QueryResult(message: String(localized: "The database server is not running."), succeeded: false)
        }
        guard let client = clientBinary else {
            return QueryResult(message: String(localized: "Database client not found."), succeeded: false)
        }
        var arguments = defaultsArguments + ["--protocol=TCP", "-h", host, "-P", String(port), "-u", "root",
                         "--xml", "--default-character-set=utf8mb4"]
        if let database, !database.isEmpty {
            // The database name goes as a separate argument, not into the query text.
            arguments += ["-D", database]
        }
        let output = await ProcessRunner.run(client, arguments, stdin: sql + "\n", timeout: 120)
        let stderr = output.stderr
            .split(separator: "\n")
            .filter { !$0.contains("insecure passwordless login") }
            .joined(separator: "\n")

        guard output.succeeded else {
            return QueryResult(message: stderr.isEmpty ? output.stdout : stderr, succeeded: false)
        }

        do {
            return try DatabaseQueryOutput.decode(output.stdout)
        } catch {
            return QueryResult(message: String(localized: "The query completed, but its result could not be read. Do not repeat data-changing queries without checking the database."), succeeded: false)
        }
    }

    // MARK: - Editing data

    nonisolated struct ColumnInfo: Identifiable, Sendable, Hashable {
        var id: String { name }
        var name: String
        var type: String
        var isPrimaryKey: Bool
        var isNullable: Bool
        var isAutoIncrement: Bool
    }

    /// The table structure. Without a primary key rows cannot be edited —
    /// there is no way to say unambiguously which one to change.
    func columns(of table: String, in database: String) async -> [ColumnInfo] {
        let result = await query(sql: """
            SELECT column_name, column_type, column_key, is_nullable, extra
            FROM information_schema.columns
            WHERE table_schema = \(Self.quoteString(database))
              AND table_name = \(Self.quoteString(table))
            ORDER BY ordinal_position;
            """)
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            return ColumnInfo(name: parts[0],
                              type: parts[1],
                              isPrimaryKey: parts[2] == "PRI",
                              isNullable: parts[3] == "YES",
                              isAutoIncrement: parts[4].contains("auto_increment"))
        }
    }

    /// Hex UTF-8 literals avoid SQL-mode-dependent quote/backslash conversion.
    nonisolated static func cellLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "CONVERT(X'" + value.utf8.map { String(format: "%02x", $0) }.joined() + "' USING utf8mb4)"
    }

    /// Changes one field of a row found by its primary key.
    func update(table: String, in database: String,
                set column: ColumnInfo, to value: String?,
                key: [(ColumnInfo, String?)]) async -> QueryResult {
        guard value != nil || column.isNullable else {
            return QueryResult(message: String(localized: "This column does not allow SQL NULL."), succeeded: false)
        }
        guard let quotedTable = Self.quoteIdentifier(table),
              let quotedColumn = Self.quoteIdentifier(column.name),
              !key.isEmpty, key.allSatisfy({ Self.quoteIdentifier($0.0.name) != nil && $0.1 != nil && $0.0.isPrimaryKey }) else {
            return QueryResult(message: String(localized: "No primary key — the row cannot be identified."),
                               succeeded: false)
        }
        let conditions = key.compactMap { pair -> String? in
            guard let name = Self.quoteIdentifier(pair.0.name) else { return nil }
            return "\(name) = \(Self.cellLiteral(pair.1))"
        }.joined(separator: " AND ")

        let sql = "UPDATE \(quotedTable) SET \(quotedColumn) = "
            + Self.cellLiteral(value)
            + " WHERE \(conditions) LIMIT 1;"
        return await run(sql: sql, database: database)
    }

    /// Deletes a row by its primary key.
    func delete(table: String, in database: String,
                key: [(ColumnInfo, String?)]) async -> QueryResult {
        guard let quotedTable = Self.quoteIdentifier(table), !key.isEmpty,
              key.allSatisfy({ Self.quoteIdentifier($0.0.name) != nil && $0.1 != nil && $0.0.isPrimaryKey }) else {
            return QueryResult(message: String(localized: "No primary key — the row cannot be identified."),
                               succeeded: false)
        }
        let conditions = key.compactMap { pair -> String? in
            guard let name = Self.quoteIdentifier(pair.0.name) else { return nil }
            return "\(name) = \(Self.cellLiteral(pair.1))"
        }.joined(separator: " AND ")
        return await run(sql: "DELETE FROM \(quotedTable) WHERE \(conditions) LIMIT 1;",
                         database: database)
    }

    /// Adds an empty row: auto-increment and defaulted fields fill themselves in,
    /// the rest get NULL or an empty string.
    func insertRow(table: String, in database: String,
                   columns list: [ColumnInfo]) async -> QueryResult {
        guard let quotedTable = Self.quoteIdentifier(table) else {
            return QueryResult(message: String(localized: "Invalid table name."), succeeded: false)
        }
        let fillable = list.filter { !$0.isAutoIncrement }
        guard !fillable.isEmpty else {
            return await run(sql: "INSERT INTO \(quotedTable) () VALUES ();", database: database)
        }
        let names = fillable.compactMap { Self.quoteIdentifier($0.name) }.joined(separator: ", ")
        let values = fillable.map { column -> String in
            if column.isNullable { return "NULL" }
            let type = column.type.lowercased()
            if type.hasPrefix("int") || type.hasPrefix("decimal")
                || type.hasPrefix("float") || type.hasPrefix("double") { return "0" }
            if type.hasPrefix("date") || type.hasPrefix("timestamp") { return "NOW()" }
            return "''"
        }.joined(separator: ", ")
        return await run(sql: "INSERT INTO \(quotedTable) (\(names)) VALUES (\(values));",
                         database: database)
    }

    // MARK: - Internals

    private func initializeDataDirectory() async -> Bool {
        guard let installer = installBinary else {
            let message = String(localized: "mariadb-install-db not found — cannot prepare the data directory.")
            log.append(message, stream: .stderr)
            state = .failed(message)
            return false
        }
        log.system(String(localized: "Preparing the data directory — this happens once."))
        AppPaths.ensure(URL(fileURLWithPath: dataDirectory))

        let result = await ProcessRunner.run(installer,
                                             defaultsArguments + ["--datadir=\(dataDirectory)",
                                              "--auth-root-authentication-method=normal"],
                                             env: ["TMPDIR": temporaryDirectory], timeout: 300)
        if !result.succeeded {
            log.append(result.combined, stream: .stderr)
            state = .failed(String(localized: "Could not prepare the data directory."))
            return false
        }
        log.system(String(localized: "Data directory ready: \(dataDirectory)"))
        return true
    }

    private func ping() async -> Bool {
        guard let client = clientBinary else { return false }
        let result = await ProcessRunner.run(client,
                                             defaultsArguments + ["--protocol=TCP", "-h", host, "-P", String(port),
                                              "-u", "root", "-sN", "-e", "SELECT @@datadir"],
                                             timeout: 10)
        let actual = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: dataDirectory).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func readVersion() async -> String {
        let result = await query(sql: "SELECT VERSION();")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Internal rather than private: the schema operations live in their own
    /// file and go through exactly this one entry point, which is what keeps
    /// every statement quoted and logged the same way.
    func query(sql: String, redacting secrets: [String] = []) async -> CommandResult {
        guard let client = clientBinary else {
            return CommandResult(exitCode: 127, stdout: "",
                                 stderr: String(localized: "Database client not found."))
        }
        var result = await ProcessRunner.run(client,
                                             defaultsArguments + ["--protocol=TCP", "-h", host, "-P", String(port),
                                              "-u", "root", "-sN"], stdin: sql + "\n",
                                             timeout: 60)
        // The client warns about a passwordless login — that is not an error.
        result.stderr = result.stderr
            .split(separator: "\n")
            .filter { !$0.contains("insecure passwordless login") }
            .joined(separator: "\n")
        // MariaDB can echo the failing statement in batch errors. Do not let
        // CREATE/ALTER USER secrets escape through returned errors or logs.
        for secret in secrets where !secret.isEmpty {
            for text in [Self.quoteString(secret), String(Self.quoteString(secret).dropFirst().dropLast()), secret] {
                result.stdout = result.stdout.replacingOccurrences(of: text, with: "[redacted]")
                result.stderr = result.stderr.replacingOccurrences(of: text, with: "[redacted]")
            }
        }
        return result
    }

    private func startLogTail() {
        stopLogTail()
        guard FileManager.default.fileExists(atPath: errorLogPath)
                || FileManager.default.createFile(atPath: errorLogPath, contents: Data()) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "0", "-F", errorLogPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let service = self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in service.log.append(text, stream: .stdout) }
        }
        try? process.run()
        logTail = process
    }

    private func stopLogTail() {
        logTail?.terminate()
        logTail = nil
    }

    private func lastErrorLines() -> String {
        guard let text = try? String(contentsOfFile: errorLogPath, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(4).joined(separator: "\n")
    }

    /// A name for CREATING a database or user. Letters, digits and underscores
    /// only; Unicode letters are fine, MySQL takes them.
    ///
    /// Returns nil for anything else rather than stripping the offending
    /// characters out. Stripping is how “плохое; DROP DATABASE mysql;” quietly
    /// becomes a real database called `плохоеDROPDATABASEmysql` — the injection
    /// is defused, which was the point, but the person is left with a database
    /// they did not ask for and cannot explain. Refusing says what happened.
    private func validIdentifier(_ raw: String) -> String? {
        let name = String(raw.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        return name
    }

    /// The name of an EXISTING object comes from the database itself and can be
    /// anything at all. Stripping characters is not an option, or the name stops matching.
    /// Escaped by MySQL rules: backticks are doubled.
    nonisolated static func quoteIdentifier(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\u{0}") else { return nil }
        return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// An SQL string literal.
    nonisolated static func quoteString(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "'", with: "''") + "'"
    }
}
