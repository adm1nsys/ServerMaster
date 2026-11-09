//
//  DatabaseBrowserSheet.swift
//  ServerMaster
//
//  Browsing tables and running queries. MariaDB has no web admin panel:
//  port 3307 speaks the binary MySQL protocol, which a browser cannot open.
//

import SwiftUI
import AppKit

struct DatabaseBrowserSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let database: String

    @State private var tables: [DatabaseService.TableInfo] = []
    @State private var selectedTable: String?
    @State private var result = DatabaseService.QueryResult()
    @State private var sql = ""
    @State private var isWorking = false
    @State private var showEditor = false
    @State private var columns: [DatabaseService.ColumnInfo] = []
    @State private var editing: (row: Int, column: Int, revision: UUID)?
    @State private var editText = ""
    @State private var editNull = false
    @State private var isTablePreview = false
    @State private var queryRevision = UUID()
    @State private var resultRevision = UUID()
    @State private var resultTableName: String?
    @State private var pageOffset = 0
    @State private var hasNextPage = false
    private let pageSize = 100
    @State private var deleteRow: (index: Int, revision: UUID)?

    private var db: DatabaseService { model.database }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                tableList
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
                    .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    if showEditor { queryEditor; Divider() }
                    resultTable
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 900, height: 620)
        .task { await load() }
        .confirmationDialog("Delete this row?", isPresented: Binding(
            get: { deleteRow != nil },
            set: { if !$0 { deleteRow = nil } })) {
            Button("Delete", role: .destructive) {
                if let target = deleteRow { Task { await removeRow(target.index, revision: target.revision) } }
                deleteRow = nil
            }
            Button("Cancel", role: .cancel) { deleteRow = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(database).font(.headline)
                Text(db.connectionSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("SQL query", isOn: $showEditor)
                .toggleStyle(.button)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isWorking)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tableList: some View {
        List(tables, selection: $selectedTable) { table in
            HStack {
                Image(systemName: "tablecells").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.name).lineLimit(1)
                    Text("~\(String(table.rows)) rows")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tag(table.name)
        }
        .listStyle(.inset)
        .disabled(isWorking)
        .onChange(of: selectedTable) { _, name in
            queryRevision = UUID()
            isTablePreview = false
            resultTableName = nil
            editing = nil
            deleteRow = nil
            guard let name else {
                result = .init()
                columns = []
                isWorking = false
                return
            }
            pageOffset = 0
            Task { await preview(name, offset: 0) }
        }
        .overlay {
            if tables.isEmpty && !isWorking {
                ContentUnavailableView("No tables", systemImage: "tablecells",
                                       description: Text("The database is empty — the CMS installer will fill it."))
            }
        }
    }

    private var queryEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $sql)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Text("Runs as root against the “\(database)” database.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Run") { Task { await execute() } }
                    .disabled(sql.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    /// Only a table preview with a primary key can be edited: an arbitrary query
    /// may return anything at all, and a row cannot be identified there.
    private var canEdit: Bool {
        !isWorking && isTablePreview && selectedTable != nil && resultTableName == selectedTable
            && resultRevision == queryRevision && columns.contains(where: \.isPrimaryKey)
            && !result.columns.isEmpty
            && columns.filter(\.isPrimaryKey).allSatisfy { key in
                result.columns.contains(key.name)
            }
    }

    private var keyColumns: [DatabaseService.ColumnInfo] { columns.filter(\.isPrimaryKey) }

    @ViewBuilder
    private var resultTable: some View {
        if !result.succeeded {
            ContentUnavailableView {
                Label("Query error", systemImage: "exclamationmark.triangle")
            } description: {
                ScrollView {
                    Text(result.message)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } else if result.columns.isEmpty {
            ContentUnavailableView("Pick a table", systemImage: "tablecells",
                                   description: Text("The table list is on the left. Or switch on the SQL query."))
        } else {
            let sourceRevision = resultRevision
            VStack(spacing: 0) {
                if selectedTable != nil {
                    editingBar
                    Divider()
                }
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow {
                            if canEdit { Text("").frame(width: 18) }
                            ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                                HStack(spacing: 3) {
                                    if columns.first(where: { $0.name == column })?.isPrimaryKey == true {
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 8)).foregroundStyle(.orange)
                                    }
                                    Text(column)
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        Divider().gridCellColumns(result.columns.count + (canEdit ? 1 : 0))
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
                            GridRow {
                                if canEdit {
                                    Button {
                                        guard canEdit, sourceRevision == queryRevision else { return }
                                        deleteRow = (rowIndex, sourceRevision)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .help("Delete row")
                                }
                                ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, field in
                                    cell(row: rowIndex, column: columnIndex, value: field)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(row: Int, column: Int, value: String?) -> some View {
        let name = column < result.columns.count ? result.columns[column] : ""
        let info = columns.first { $0.name == name }
        let sourceRevision = resultRevision
        let editable = canEdit && !(info?.isPrimaryKey ?? false) && !(info?.isAutoIncrement ?? false)

        if let editing, editing.row == row, editing.column == column {
            HStack(spacing: 6) {
                TextField("", text: $editText)
                    .font(.system(.caption, design: .monospaced))
                    .glassField()
                    .frame(minWidth: 90)
                    .disabled(editNull || isWorking)
                    .onSubmit { Task { await commitEdit() } }
                    .onExitCommand { self.editing = nil }
                if info?.isNullable == true {
                    Toggle("SQL NULL", isOn: $editNull)
                        .toggleStyle(.checkbox)
                        .disabled(isWorking)
                }
                Button {
                    Task { await commitEdit() }
                } label: { Image(systemName: "checkmark") }
                .help("Save cell")
                .disabled(isWorking)
                Button { self.editing = nil } label: { Image(systemName: "xmark") }
                    .help("Cancel")
                    .disabled(isWorking)
            }
        } else {
            let display = value ?? "NULL"
            Text(display.count > 120 ? String(display.prefix(120)) + "…" : display)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard editable, canEdit, sourceRevision == queryRevision else { return }
                    editText = value ?? ""
                    editNull = value == nil
                    editing = (row, column, sourceRevision)
                }
                .help(editable ? String(localized: "Double-click to edit")
                               : String(localized: "Read-only field"))
        }
    }

    private var editingBar: some View {
        HStack(spacing: 10) {
            if canEdit {
                Label("Double-click a cell to edit it", systemImage: "pencil")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await addRow() }
                } label: {
                    Label("Add row", systemImage: "plus")
                }
                .disabled(isWorking)
            } else {
                Label("This table has no primary key — rows cannot be edited here, only with a query.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Text(result.message)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isTablePreview, let table = selectedTable {
                Button("Previous") { Task { await preview(table, offset: max(0, pageOffset - pageSize)) } }
                    .disabled(isWorking || pageOffset == 0)
                Button("Next") { Task { await preview(table, offset: pageOffset + pageSize) } }
                    .disabled(isWorking || !hasNextPage)
            }
            if !result.rows.isEmpty {
                Button("Copy as CSV") { copyCSV() }
                    .buttonStyle(.link)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func commitEdit() async {
        guard !isWorking, isTablePreview, let editing, let table = selectedTable,
              resultTableName == table, editing.revision == resultRevision, resultRevision == queryRevision,
              result.columns.indices.contains(editing.column), result.rows.indices.contains(editing.row) else { return }
        let columnName = result.columns[editing.column]
        guard let info = columns.first(where: { $0.name == columnName }) else { return }

        let value: String? = editNull ? nil : editText
        let key = keyColumns.compactMap { column -> (DatabaseService.ColumnInfo, String?)? in
            guard let index = result.columns.firstIndex(of: column.name),
                  index < result.rows[editing.row].count else { return nil }
            return (column, result.rows[editing.row][index])
        }
        guard key.count == keyColumns.count else { return }

        isWorking = true
        let outcome = await db.update(table: table, in: database,
                                      set: info, to: value, key: key)
        self.editing = nil
        if outcome.succeeded {
            await preview(table)
        } else {
            model.notify(outcome.message, isError: true)
            isWorking = false
        }
    }

    private func addRow() async {
        guard !isWorking, isTablePreview, let table = selectedTable,
              resultTableName == table, resultRevision == queryRevision else { return }
        isWorking = true
        let outcome = await db.insertRow(table: table, in: database, columns: columns)
        if outcome.succeeded {
            await preview(table)
        } else {
            model.notify(outcome.message, isError: true)
            isWorking = false
        }
    }

    private func removeRow(_ index: Int, revision: UUID) async {
        guard !isWorking, isTablePreview, let table = selectedTable, resultTableName == table,
              revision == resultRevision, revision == queryRevision, result.rows.indices.contains(index) else { return }
        let key = keyColumns.compactMap { column -> (DatabaseService.ColumnInfo, String?)? in
            guard let position = result.columns.firstIndex(of: column.name),
                  position < result.rows[index].count else { return nil }
            return (column, result.rows[index][position])
        }
        guard key.count == keyColumns.count else { return }
        isWorking = true
        let outcome = await db.delete(table: table, in: database, key: key)
        if outcome.succeeded {
            await preview(table)
        } else {
            model.notify(outcome.message, isError: true)
            isWorking = false
        }
    }

    private func load() async {
        guard !isWorking else { return }
        isWorking = true
        tables = await db.tables(in: database)
        if let table = selectedTable, tables.contains(where: { $0.name == table }) {
            await preview(table)
        } else {
            selectedTable = nil
            result = .init()
            columns = []
            isTablePreview = false
            pageOffset = 0
            isWorking = false
        }
    }

    private func preview(_ table: String, offset requestedOffset: Int? = nil) async {
        guard selectedTable == table else { return }
        let revision = UUID()
        queryRevision = revision
        let offset = requestedOffset ?? pageOffset
        isWorking = true
        isTablePreview = false
        resultTableName = nil
        editing = nil
        deleteRow = nil
        let schema = await db.columns(of: table, in: database)
        var rows = await db.preview(table: table, in: database, limit: pageSize + 1, offset: offset)
        guard queryRevision == revision, selectedTable == table else { return }
        hasNextPage = rows.succeeded && rows.rows.count > pageSize
        rows.rows = Array(rows.rows.prefix(pageSize))
        pageOffset = offset
        if rows.succeeded {
            rows.message = rows.rows.isEmpty ? String(localized: "No rows")
                : String(localized: "Rows \(offset + 1)–\(offset + rows.rows.count)")
        }
        columns = schema
        result = rows
        resultRevision = revision
        resultTableName = table
        isTablePreview = rows.succeeded
        let keys = schema.filter(\.isPrimaryKey).map { "`" + $0.name.replacingOccurrences(of: "`", with: "``") + "`" }
        let order = keys.isEmpty ? "" : " ORDER BY " + keys.joined(separator: ", ")
        sql = "SELECT * FROM `\(table.replacingOccurrences(of: "`", with: "``"))`\(order) LIMIT \(pageSize) OFFSET \(offset);"
        isWorking = false
    }

    private func execute() async {
        guard !isWorking else { return }
        let revision = UUID()
        queryRevision = revision
        isWorking = true
        isTablePreview = false
        resultTableName = nil
        editing = nil
        deleteRow = nil
        let outcome = await db.run(sql: sql, database: database)
        guard queryRevision == revision else { return }
        result = outcome
        if result.succeeded { tables = await db.tables(in: database) }
        isWorking = false
    }

    private func copyCSV() {
        var lines = [result.columns.joined(separator: ",")]
        for row in result.rows {
            lines.append(row.map { field in
                guard let field else { return "NULL" }
                return field.isEmpty || field == "NULL" || field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
                    ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : field
            }.joined(separator: ","))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        model.notify(String(localized: "Rows copied: \(String(result.rows.count))"))
    }
}
