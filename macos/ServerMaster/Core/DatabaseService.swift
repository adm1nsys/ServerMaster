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

    var dataDirectory: String { AppPaths.subdir("Database/data").path }
    var runtimeDirectory: String { AppPaths.subdir("Database").path }
    var errorLogPath: String { (runtimeDirectory as NSString).appendingPathComponent("error.log") }

    /// A UNIX socket path is limited to 104 bytes and Application Support is long —
    /// so the socket goes into /tmp.
    var socketPath: String { "/tmp/servermaster-mysql.sock" }

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
        guard !state.isActive else { return }

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

        if !isInitialized {
            state = .initializing
            guard await initializeDataDirectory() else { return }
        }

        state = .starting
        log.system(String(localized: "Starting the database on port \(String(port))…"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary!)
        process.arguments = [
            "--datadir=\(dataDirectory)",
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
                                        ["--socket=\(socketPath)", "-u", "root", "shutdown"],
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
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: - Databases

    func reloadDatabases() async {
        guard state == .running else { databases = []; return }
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
        guard result.succeeded else { return }

        databases = result.stdout
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count >= 3 else { return nil }
                return DatabaseInfo(name: parts[0],
                                    tables: Int(parts[1]) ?? 0,
                                    sizeMB: Double(parts[2]) ?? 0)
            }
    }

    /// Creates a database and a user with full rights on it.
    func createDatabase(name: String, user: String, password: String) async -> CommandResult {
        let db = sanitizeIdentifier(name)
        let account = sanitizeIdentifier(user)
        guard !db.isEmpty, !account.isEmpty else {
            return CommandResult(exitCode: 1, stdout: "",
                                 stderr: String(localized: "Database and user names may contain only Latin letters, digits and underscores."))
        }
        let escaped = password.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE DATABASE IF NOT EXISTS `\(db)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '\(account)'@'127.0.0.1' IDENTIFIED BY '\(escaped)';
        CREATE USER IF NOT EXISTS '\(account)'@'localhost' IDENTIFIED BY '\(escaped)';
        GRANT ALL PRIVILEGES ON `\(db)`.* TO '\(account)'@'127.0.0.1';
        GRANT ALL PRIVILEGES ON `\(db)`.* TO '\(account)'@'localhost';
        FLUSH PRIVILEGES;
        """
        let result = await query(sql: sql)
        if result.succeeded {
            log.system(String(localized: "Created database “\(db)” and user “\(account)”."))
            await reloadDatabases()
        } else {
            log.append(result.combined, stream: .stderr)
        }
        return result
    }

    func dropDatabase(name: String) async -> CommandResult {
        let db = sanitizeIdentifier(name)
        guard !db.isEmpty else { return CommandResult(exitCode: 1, stdout: "", stderr: "") }
        let result = await query(sql: "DROP DATABASE IF EXISTS `\(db)`;")
        if result.succeeded {
            log.system(String(localized: "Database “\(db)” deleted."))
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
        let account = sanitizeIdentifier(name)
        guard !account.isEmpty else {
            return CommandResult(exitCode: 1, stdout: "",
                                 stderr: String(localized: "Invalid account name."))
        }
        let escaped = password.replacingOccurrences(of: "'", with: "''")
        let sql = """
        CREATE USER IF NOT EXISTS '\(account)'@'127.0.0.1' IDENTIFIED BY '\(escaped)';
        ALTER USER '\(account)'@'127.0.0.1' IDENTIFIED BY '\(escaped)';
        GRANT ALL PRIVILEGES ON *.* TO '\(account)'@'127.0.0.1' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        """
        return await query(sql: sql)
    }

    // MARK: - Browsing and editing

    nonisolated struct TableInfo: Identifiable, Sendable, Hashable {
        var id: String { name }
        var name: String
        var rows: Int
    }

    nonisolated struct QueryResult: Sendable {
        var columns: [String] = []
        var rows: [[String]] = []
        var message: String = ""
        var succeeded = true
        var affectedRows: Int?
    }

    /// Tables of the selected database.
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

    /// The first rows of a table — just to see what is inside.
    func preview(table: String, in database: String, limit: Int = 100) async -> QueryResult {
        guard let quoted = Self.quoteIdentifier(table) else {
            return QueryResult(message: String(localized: "Invalid table name."), succeeded: false)
        }
        return await run(sql: "SELECT * FROM \(quoted) LIMIT \(max(1, min(limit, 1000)));",
                         database: database)
    }

    /// An arbitrary query. Returns a result table or the error text.
    func run(sql: String, database: String?) async -> QueryResult {
        guard let client = clientBinary else {
            return QueryResult(message: String(localized: "Database client not found."), succeeded: false)
        }
        var arguments = ["--protocol=TCP", "-h", host, "-P", String(port), "-u", "root",
                         "--batch", "--column-names"]
        if let database, !database.isEmpty {
            // The database name goes as a separate argument, not into the query text.
            arguments += ["-D", database]
        }
        arguments += ["-e", sql]

        let output = await ProcessRunner.run(client, arguments, timeout: 120)
        let stderr = output.stderr
            .split(separator: "\n")
            .filter { !$0.contains("insecure passwordless login") }
            .joined(separator: "\n")

        guard output.succeeded else {
            return QueryResult(message: stderr.isEmpty ? output.stdout : stderr, succeeded: false)
        }

        // --batch returns TSV: the first line is the header.
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let header = lines.first else {
            return QueryResult(message: String(localized: "Query executed."), succeeded: true)
        }
        let columns = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let rows = lines.dropFirst().map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { field in
                // The client returns NULL as \N
                field == "\\N" ? "NULL" : String(field)
            }
        }
        return QueryResult(columns: columns, rows: rows,
                           message: String(localized: "Rows: \(String(rows.count))"),
                           succeeded: true)
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

    /// A value for SQL: NULL stays NULL, numbers go unquoted,
    /// everything else is escaped as a string.
    private static func literal(_ value: String, type: String) -> String {
        if value == "NULL" { return "NULL" }
        let numeric = ["int", "decimal", "float", "double", "bit", "year"]
        if numeric.contains(where: { type.lowercased().hasPrefix($0) }),
           Double(value) != nil {
            return value
        }
        return quoteString(value)
    }

    /// Changes one field of a row found by its primary key.
    func update(table: String, in database: String,
                set column: ColumnInfo, to value: String,
                key: [(ColumnInfo, String)]) async -> QueryResult {
        guard let quotedTable = Self.quoteIdentifier(table),
              let quotedColumn = Self.quoteIdentifier(column.name),
              !key.isEmpty else {
            return QueryResult(message: String(localized: "No primary key — the row cannot be identified."),
                               succeeded: false)
        }
        let conditions = key.compactMap { pair -> String? in
            guard let name = Self.quoteIdentifier(pair.0.name) else { return nil }
            return "\(name) = \(Self.literal(pair.1, type: pair.0.type))"
        }.joined(separator: " AND ")

        let sql = "UPDATE \(quotedTable) SET \(quotedColumn) = "
            + Self.literal(value, type: column.type)
            + " WHERE \(conditions) LIMIT 1;"
        return await run(sql: sql, database: database)
    }

    /// Deletes a row by its primary key.
    func delete(table: String, in database: String,
                key: [(ColumnInfo, String)]) async -> QueryResult {
        guard let quotedTable = Self.quoteIdentifier(table), !key.isEmpty else {
            return QueryResult(message: String(localized: "No primary key — the row cannot be identified."),
                               succeeded: false)
        }
        let conditions = key.compactMap { pair -> String? in
            guard let name = Self.quoteIdentifier(pair.0.name) else { return nil }
            return "\(name) = \(Self.literal(pair.1, type: pair.0.type))"
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
                                             ["--datadir=\(dataDirectory)",
                                              "--auth-root-authentication-method=normal"],
                                             timeout: 300)
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
                                             ["--protocol=TCP", "-h", host, "-P", String(port),
                                              "-u", "root", "-sN", "-e", "SELECT 1"],
                                             timeout: 10)
        return result.succeeded && result.stdout.contains("1")
    }

    private func readVersion() async -> String {
        let result = await query(sql: "SELECT VERSION();")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func query(sql: String) async -> CommandResult {
        guard let client = clientBinary else {
            return CommandResult(exitCode: 127, stdout: "",
                                 stderr: String(localized: "Database client not found."))
        }
        var result = await ProcessRunner.run(client,
                                             ["--protocol=TCP", "-h", host, "-P", String(port),
                                              "-u", "root", "-sN", "-e", sql],
                                             timeout: 60)
        // The client warns about a passwordless login — that is not an error.
        result.stderr = result.stderr
            .split(separator: "\n")
            .filter { !$0.contains("insecure passwordless login") }
            .joined(separator: "\n")
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

    /// A name for CREATING a database or user: the user types it by hand, so only
    /// letters, digits and underscores are kept. Unicode is allowed — MySQL supports
    /// it, and the escaping below is what protects against injection.
    private func sanitizeIdentifier(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespaces)
            .prefix(64)
            .filter { $0.isLetter || $0.isNumber || $0 == "_" })
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
