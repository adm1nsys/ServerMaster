import Foundation
import Testing
@testable import ServerMaster

@Suite("R3 typed database cells")
struct DatabaseCellTests {
    @Test("SQL NULL, empty text, NULL text and escaped characters are distinct")
    func output() throws {
        let xml = """
        <?xml version="1.0"?>
        <resultset xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <row><field name="a" xsi:nil="true"/><field name="b"></field><field name="c">NULL</field><field name="d">\\N</field><field name="e">Українська &amp; &lt;tag&gt;&#9;&#10;&#13;</field></row>
        </resultset>
        """
        let result = try DatabaseQueryOutput.decode(xml)
        #expect(result.columns == ["a", "b", "c", "d", "e"])
        #expect(result.rows == [[nil, "", "NULL", "\\N", "Українська & <tag>\t\n\r"]])
        let rawCR = "<resultset><row><field name=\"text\">one\rtwo\r\nthree</field></row></resultset>"
        #expect(try DatabaseQueryOutput.decode(rawCR).rows == [["one\rtwo\r\nthree"]])
        let multiple = try DatabaseQueryOutput.decode(xml + "\n" + xml)
        #expect(multiple.rows == result.rows)
        #expect(multiple.message.contains("2"))
        #expect(try DatabaseQueryOutput.decode("").rows.isEmpty)
        #expect(throws: (any Error).self) { try DatabaseQueryOutput.decode("not XML") }
        #expect(throws: (any Error).self) { try DatabaseQueryOutput.decode("<resultset><row><field>broken</field></row></resultset>") }
    }

    @Test("Cell literals preserve all text and do not depend on SQL quote modes")
    func literals() {
        #expect(DatabaseService.cellLiteral(nil) == "NULL")
        #expect(DatabaseService.cellLiteral("") == "CONVERT(X'' USING utf8mb4)")
        #expect(DatabaseService.cellLiteral("NULL") == "CONVERT(X'4e554c4c' USING utf8mb4)")
        #expect(DatabaseService.cellLiteral("'\\\n") == "CONVERT(X'275c0a' USING utf8mb4)")
    }
}

@MainActor
@Suite("R3 isolated MariaDB cell editing", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SERVERMASTER_TEST_DATABASE_CELLS"] == "1"))
struct DatabaseCellLiveTests {
    @Test("Real database reads and writes preserve nullable text, keys and SQL mode")
    func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("database-r3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RuntimePortLease.acquire(excluding: 3307)
        defer { withExtendedLifetime(lease) {} }
        let database = DatabaseService(runtimeDirectory: root.appendingPathComponent("database"),
            socketPath: "/tmp/sm-r3-\(UUID().uuidString.prefix(10)).sock", port: lease.port)
        defer { database.stopImmediately() }
        try #require(database.isInstalled)
        lease.allowChildBind()
        await database.start()
        try #require(database.state == .running, "\(database.log.lines.map(\.text).joined(separator: "\n"))")
        let schema = await database.run(sql: "CREATE DATABASE r3; CREATE TABLE r3.cells (id INT PRIMARY KEY, value TEXT NULL, required TEXT NOT NULL); INSERT INTO r3.cells VALUES (1, NULL, 'keep');", database: nil)
        try #require(schema.succeeded, "\(schema.message)")
        let columns = await database.columns(of: "cells", in: "r3")
        let id = try #require(columns.first { $0.name == "id" })
        let value = try #require(columns.first { $0.name == "value" })
        let required = try #require(columns.first { $0.name == "required" })
        let values: [String?] = [nil, "", "NULL", "\\N", "Українська 😺 ' \\ \t\n\rnext", "0"]
        for text in values {
            let changed = await database.update(table: "cells", in: "r3", set: value, to: text, key: [(id, "1")])
            try #require(changed.succeeded, "\(changed.message)")
            let result = await database.preview(table: "cells", in: "r3")
            try #require(result.succeeded, "\(result.message)")
            #expect(result.rows == [["1", text, "keep"]])
        }
        #expect(!(await database.update(table: "cells", in: "r3", set: required, to: nil, key: [(id, "1")])).succeeded)
        #expect(!(await database.update(table: "cells", in: "r3", set: value, to: "bad", key: [(id, nil)])).succeeded)
        let modes = await database.run(sql: "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'; SELECT \(DatabaseService.cellLiteral("'\\\nNULL")) AS exact;", database: "r3")
        #expect(modes.succeeded)
        #expect(modes.rows == [["'\\\nNULL"]])
        let multiple = await database.run(sql: "SELECT 'first' AS a; SELECT 'last' AS b;", database: "r3")
        #expect(multiple.columns == ["b"] && multiple.rows == [["last"]])
        try #require((await database.run(sql: "CREATE TABLE keyed (id VARCHAR(100) PRIMARY KEY, value TEXT NULL); INSERT INTO keyed VALUES ('NULL', 'old');", database: "r3")).succeeded)
        let keyedColumns = await database.columns(of: "keyed", in: "r3")
        let textKey = try #require(keyedColumns.first { $0.name == "id" })
        let textValue = try #require(keyedColumns.first { $0.name == "value" })
        #expect((await database.update(table: "keyed", in: "r3", set: textValue, to: "", key: [(textKey, "NULL")])).succeeded)
        #expect((await database.preview(table: "keyed", in: "r3")).rows == [["NULL", ""]])
        #expect((await database.delete(table: "keyed", in: "r3", key: [(textKey, "NULL")])).succeeded)
        #expect((await database.preview(table: "keyed", in: "r3")).rows.isEmpty)
        #expect((await database.delete(table: "cells", in: "r3", key: [(id, "1")])).succeeded)
        let empty = await database.preview(table: "cells", in: "r3")
        #expect(empty.succeeded && empty.columns == ["id", "value", "required"] && empty.rows.isEmpty)
        // R9: insert out of order to verify that page boundaries follow the key.
        let data = (1...205).reversed().map { "(\($0), 'row', 'keep')" }.joined(separator: ",")
        try #require((await database.run(sql: "INSERT INTO cells VALUES \(data);", database: "r3")).succeeded)
        let first = await database.preview(table: "cells", in: "r3", limit: 101)
        let second = await database.preview(table: "cells", in: "r3", limit: 101, offset: 100)
        let last = await database.preview(table: "cells", in: "r3", limit: 101, offset: 200)
        #expect(first.rows.count == 101 && first.rows.first?.first == "1" && first.rows.last?.first == "101")
        #expect(second.rows.count == 101 && second.rows.first?.first == "101" && second.rows.last?.first == "201")
        #expect(last.rows.count == 5 && last.rows.first?.first == "201" && last.rows.last?.first == "205")
        #expect((await database.delete(table: "cells", in: "r3", key: [(id, "205")])).succeeded)
        #expect((await database.preview(table: "cells", in: "r3", offset: 200)).rows.count == 4)
        #expect(!(await database.preview(table: "cells", in: "r3", offset: -1)).succeeded)
        await database.stop()
        #expect(database.state == .stopped)
    }
}
