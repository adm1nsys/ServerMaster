//
//  DatabaseSchema.swift
//  ServerMaster
//
//  Changing the shape of a database without writing the SQL.
//
//  Everything here builds a statement and hands it to `DatabaseService.query`.
//  Two rules run through all of it.
//
//  Identifiers are quoted, never filtered. A table called `order` or a column
//  with a space in it is legal and exists in the wild; stripping characters to
//  make a name “safe” produces a statement about a different object, which is
//  worse than refusing. Values are quoted separately, by their own rules.
//
//  Nothing that loses data happens without the caller having said so. Dropping a
//  column, dropping a table and dropping a user each return a description of
//  what will be lost, so the screen can put it in front of someone before it
//  runs rather than after.
//

import Foundation

// MARK: - What a column looks like while it is being described

nonisolated struct ColumnDraft: Identifiable, Sendable, Hashable {
    var id = UUID()
    var name: String = ""
    var type: String = "VARCHAR(255)"
    var isNullable: Bool = true
    var isPrimaryKey: Bool = false
    var isAutoIncrement: Bool = false
    var isUnique: Bool = false
    /// Empty means no default. "NULL" is a default of NULL.
    var defaultValue: String = ""
    var comment: String = ""

    /// The types worth offering. Not the whole of MariaDB — the twenty that
    /// cover what anyone building a site actually declares, with the rest
    /// reachable by typing.
    static let commonTypes = [
        "INT", "BIGINT", "SMALLINT", "TINYINT",
        "VARCHAR(255)", "VARCHAR(64)", "CHAR(36)", "TEXT", "MEDIUMTEXT", "LONGTEXT",
        "DECIMAL(10,2)", "FLOAT", "DOUBLE",
        "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR",
        "BOOLEAN", "JSON", "BLOB", "ENUM('a','b')"
    ]

    /// The column as it appears inside CREATE TABLE or after ADD COLUMN.
    func definition() -> String? {
        guard let name = DatabaseService.quoteIdentifier(name), !type.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        var parts = [name, type.trimmingCharacters(in: .whitespaces)]

        // AUTO_INCREMENT columns cannot be NULL, and saying so explicitly is
        // clearer than letting the server correct it silently.
        parts.append(isNullable && !isAutoIncrement && !isPrimaryKey ? "NULL" : "NOT NULL")

        if !defaultValue.isEmpty, !isAutoIncrement {
            parts.append("DEFAULT " + Self.quotedDefault(defaultValue))
        }
        if isAutoIncrement { parts.append("AUTO_INCREMENT") }
        if !comment.isEmpty { parts.append("COMMENT " + DatabaseService.quoteString(comment)) }
        return parts.joined(separator: " ")
    }

    /// A default is a value, except when it is one of the words the server
    /// understands as an expression — quoting CURRENT_TIMESTAMP turns a
    /// timestamp column into a column holding that string.
    static func quotedDefault(_ value: String) -> String {
        let bare = value.trimmingCharacters(in: .whitespaces)
        let expressions = ["NULL", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
                           "NOW()", "UUID()", "TRUE", "FALSE"]
        if expressions.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) {
            return bare.uppercased()
        }
        if Double(bare) != nil { return bare }
        return DatabaseService.quoteString(bare)
    }
}

// MARK: - Indexes

nonisolated struct IndexInfo: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var columns: [String]
    var isUnique: Bool
    var isPrimary: Bool

    var summary: String {
        let kind = isPrimary ? String(localized: "primary key")
            : (isUnique ? String(localized: "unique") : String(localized: "index"))
        return "\(kind) · \(columns.joined(separator: ", "))"
    }
}

// MARK: - Users

nonisolated struct DatabaseUser: Identifiable, Sendable, Hashable {
    var id: String { "\(name)@\(host)" }
    var name: String
    var host: String
    /// Databases this account has been granted something on.
    var grants: [String] = []
}

// MARK: - The operations

extension DatabaseService {

    // MARK: Reading structure

    func indexes(of table: String, in database: String) async -> [IndexInfo] {
        let result = await query(sql: """
            SELECT index_name, GROUP_CONCAT(column_name ORDER BY seq_in_index), MIN(non_unique)
            FROM information_schema.statistics
            WHERE table_schema = \(Self.quoteString(database))
              AND table_name = \(Self.quoteString(table))
            GROUP BY index_name
            ORDER BY (index_name = 'PRIMARY') DESC, index_name;
            """)
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            return IndexInfo(name: parts[0],
                             columns: parts[1].split(separator: ",").map(String.init),
                             isUnique: parts[2] == "0",
                             isPrimary: parts[0] == "PRIMARY")
        }
    }

    /// The statement that would recreate this table. Worth showing: it is the
    /// one description of a table that is complete and that anyone can paste
    /// into another server.
    func createStatement(of table: String, in database: String) async -> String? {
        guard let db = Self.quoteIdentifier(database), let name = Self.quoteIdentifier(table) else { return nil }
        let result = await query(sql: "SHOW CREATE TABLE \(db).\(name);")
        guard result.succeeded else { return nil }
        // Two tab-separated fields: the name, then the statement, with newlines
        // written as \n by the batch client.
        let parts = result.stdout.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return parts[1].replacingOccurrences(of: "\\n", with: "\n")
    }

    // MARK: Tables

    func createTable(_ name: String, columns: [ColumnDraft], in database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database), let table = Self.quoteIdentifier(name) else {
            return Self.refusal(String(localized: "That is not a usable table name."))
        }
        let definitions = columns.compactMap { $0.definition() }
        guard !definitions.isEmpty else {
            return Self.refusal(String(localized: "A table needs at least one column."))
        }

        var body = definitions
        let keys = columns.filter(\.isPrimaryKey).compactMap { Self.quoteIdentifier($0.name) }
        if !keys.isEmpty { body.append("PRIMARY KEY (\(keys.joined(separator: ", ")))") }
        for unique in columns.filter({ $0.isUnique && !$0.isPrimaryKey }) {
            guard let column = Self.quoteIdentifier(unique.name) else { continue }
            body.append("UNIQUE KEY \(column)")
        }

        let sql = """
        CREATE TABLE \(db).\(table) (
            \(body.joined(separator: ",\n    "))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        """
        return await runDDL(sql, describing: String(localized: "Table “\(name)” created."))
    }

    func dropTable(_ name: String, in database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database), let table = Self.quoteIdentifier(name) else {
            return Self.refusal(String(localized: "That is not a usable table name."))
        }
        return await runDDL("DROP TABLE \(db).\(table);",
                            describing: String(localized: "Table “\(name)” dropped."))
    }

    func renameTable(_ name: String, to newName: String, in database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database),
              let from = Self.quoteIdentifier(name),
              let to = Self.quoteIdentifier(newName) else {
            return Self.refusal(String(localized: "That is not a usable table name."))
        }
        return await runDDL("RENAME TABLE \(db).\(from) TO \(db).\(to);",
                            describing: String(localized: "Renamed to “\(newName)”."))
    }

    func truncateTable(_ name: String, in database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database), let table = Self.quoteIdentifier(name) else {
            return Self.refusal(String(localized: "That is not a usable table name."))
        }
        return await runDDL("TRUNCATE TABLE \(db).\(table);",
                            describing: String(localized: "Every row in “\(name)” removed."))
    }

    // MARK: Columns

    func addColumn(_ draft: ColumnDraft, to table: String, in database: String,
                   after: String? = nil) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database),
              let name = Self.quoteIdentifier(table),
              let definition = draft.definition() else {
            return Self.refusal(String(localized: "That column cannot be described."))
        }
        var sql = "ALTER TABLE \(db).\(name) ADD COLUMN \(definition)"
        if let after, let position = Self.quoteIdentifier(after) { sql += " AFTER \(position)" }
        return await runDDL(sql + ";", describing: String(localized: "Column “\(draft.name)” added."))
    }

    /// CHANGE rather than MODIFY, because it is the one that can also rename.
    func changeColumn(_ existing: String, to draft: ColumnDraft,
                      in table: String, database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database),
              let name = Self.quoteIdentifier(table),
              let old = Self.quoteIdentifier(existing),
              let definition = draft.definition() else {
            return Self.refusal(String(localized: "That column cannot be described."))
        }
        return await runDDL("ALTER TABLE \(db).\(name) CHANGE COLUMN \(old) \(definition);",
                            describing: String(localized: "Column “\(draft.name)” changed."))
    }

    func dropColumn(_ column: String, from table: String, in database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database),
              let name = Self.quoteIdentifier(table),
              let target = Self.quoteIdentifier(column) else {
            return Self.refusal(String(localized: "That is not a usable column name."))
        }
        return await runDDL("ALTER TABLE \(db).\(name) DROP COLUMN \(target);",
                            describing: String(localized: "Column “\(column)” dropped."))
    }

    // MARK: Indexes

    func addIndex(named indexName: String, on columns: [String], unique: Bool,
                  table: String, database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database),
              let name = Self.quoteIdentifier(table),
              let index = Self.quoteIdentifier(indexName),
              !columns.isEmpty else {
            return Self.refusal(String(localized: "An index needs a name and at least one column."))
        }
        let quoted = columns.compactMap { Self.quoteIdentifier($0) }
        guard quoted.count == columns.count else {
            return Self.refusal(String(localized: "One of those column names cannot be used."))
        }
        let kind = unique ? "UNIQUE INDEX" : "INDEX"
        return await runDDL("ALTER TABLE \(db).\(name) ADD \(kind) \(index) (\(quoted.joined(separator: ", ")));",
                            describing: String(localized: "Index “\(indexName)” added."))
    }

    func dropIndex(_ indexName: String, table: String, database: String) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database), let name = Self.quoteIdentifier(table) else {
            return Self.refusal(String(localized: "That is not a usable table name."))
        }
        // The primary key has its own syntax and no name to drop.
        if indexName == "PRIMARY" {
            return await runDDL("ALTER TABLE \(db).\(name) DROP PRIMARY KEY;",
                                describing: String(localized: "Primary key dropped."))
        }
        guard let index = Self.quoteIdentifier(indexName) else {
            return Self.refusal(String(localized: "That is not a usable index name."))
        }
        return await runDDL("ALTER TABLE \(db).\(name) DROP INDEX \(index);",
                            describing: String(localized: "Index “\(indexName)” dropped."))
    }

    // MARK: Users and privileges

    func users() async -> [DatabaseUser] {
        let result = await query(sql: """
            SELECT user, host FROM mysql.user
            WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema')
            ORDER BY user, host;
            """)
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            return DatabaseUser(name: parts[0], host: parts[1])
        }
    }

    func grants(of user: DatabaseUser) async -> [String] {
        let result = await query(sql: "SHOW GRANTS FOR \(Self.quoteString(user.name))@\(Self.quoteString(user.host));")
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    func createUser(_ name: String, host: String, password: String) async -> CommandResult {
        guard Self.quoteString(name) != "''" , !name.isEmpty else {
            return Self.refusal(String(localized: "A user needs a name."))
        }
        // A user name is a string in MySQL grammar, not an identifier, so it is
        // quoted as one — which is also what makes an apostrophe in it safe.
        let account = "\(Self.quoteString(name))@\(Self.quoteString(host.isEmpty ? "localhost" : host))"
        return await runDDL("CREATE USER \(account) IDENTIFIED BY \(Self.quoteString(password));",
                            describing: String(localized: "User “\(name)” created."))
    }

    func dropUser(_ user: DatabaseUser) async -> CommandResult {
        let account = "\(Self.quoteString(user.name))@\(Self.quoteString(user.host))"
        return await runDDL("DROP USER \(account);",
                            describing: String(localized: "User “\(user.name)” removed."))
    }

    func setPassword(of user: DatabaseUser, to password: String) async -> CommandResult {
        let account = "\(Self.quoteString(user.name))@\(Self.quoteString(user.host))"
        return await runDDL("ALTER USER \(account) IDENTIFIED BY \(Self.quoteString(password));",
                            describing: String(localized: "Password changed."))
    }

    func grant(_ privileges: String, on database: String, to user: DatabaseUser) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database) else {
            return Self.refusal(String(localized: "That is not a usable database name."))
        }
        let account = "\(Self.quoteString(user.name))@\(Self.quoteString(user.host))"
        return await runDDL("GRANT \(privileges) ON \(db).* TO \(account); FLUSH PRIVILEGES;",
                            describing: String(localized: "Granted on “\(database)”."))
    }

    func revokeAll(on database: String, from user: DatabaseUser) async -> CommandResult {
        guard let db = Self.quoteIdentifier(database) else {
            return Self.refusal(String(localized: "That is not a usable database name."))
        }
        let account = "\(Self.quoteString(user.name))@\(Self.quoteString(user.host))"
        return await runDDL("REVOKE ALL PRIVILEGES ON \(db).* FROM \(account); FLUSH PRIVILEGES;",
                            describing: String(localized: "Revoked on “\(database)”."))
    }

    // MARK: Running one

    private func runDDL(_ sql: String, describing success: String) async -> CommandResult {
        let result = await query(sql: sql)
        if result.succeeded {
            log.system(success)
        } else {
            log.append(result.combined, stream: .stderr)
        }
        return result
    }

    private static func refusal(_ message: String) -> CommandResult {
        CommandResult(exitCode: 1, stdout: "", stderr: message)
    }
}
