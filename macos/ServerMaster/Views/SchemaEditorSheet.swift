//
//  SchemaEditorSheet.swift
//  ServerMaster
//
//  Changing the shape of a database with the mouse.
//
//  Three panes behind one window: the tables, the structure of the one selected,
//  and the accounts that can reach the database. Everything here writes DDL, so
//  every destructive action asks first and says what it will cost — a dropped
//  column does not come back, and the person clicking is usually the person who
//  will need it in an hour.
//
//  The SQL box stays. Not everything belongs in a form, and a screen that
//  removes the ability to type a statement is a screen someone has to work
//  around on their second afternoon with it.
//

import SwiftUI
import AppKit

struct SchemaEditorSheet: View {

    let database: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Pane: String, CaseIterable, Identifiable {
        case tables, users
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .tables ? "Tables" : "Accounts" }
    }

    @State private var pane: Pane = .tables
    @State private var tables: [DatabaseService.TableInfo] = []
    @State private var selected: String?
    @State private var columns: [DatabaseService.ColumnInfo] = []
    @State private var indexes: [IndexInfo] = []
    @State private var createStatement = ""
    @State private var users: [DatabaseUser] = []
    @State private var grants: [String] = []
    @State private var selectedUser: DatabaseUser?

    @State private var message: String?
    @State private var isError = false
    @State private var busy = false

    // Sheets and confirmations
    @State private var newTable = false
    @State private var editingColumn: ColumnDraft?
    @State private var replacing: String?          // the column being changed
    @State private var newIndex = false
    @State private var newUser = false
    @State private var confirming: Confirmation?

    private struct Confirmation: Identifiable {
        var id = UUID()
        var title: String
        var cost: String
        var run: () async -> CommandResult
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // Both halves have to be told to fill: HSplitView asks its children
            // how tall they want to be, and a List with three rows in it answers
            // honestly — which leaves the whole window squeezed into a band in
            // the middle with grey above and below.
            HSplitView {
                sidebar
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 300,
                           maxHeight: .infinity)
                Group {
                    switch pane {
                    case .tables: tableDetail
                    case .users:  userDetail
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 940, height: 620)
        .task { await reload() }
        .sheet(isPresented: $newTable) {
            TableBuilderSheet(database: database) { await reload() }
        }
        .sheet(item: $editingColumn) { draft in
            ColumnSheet(draft: draft, replacing: replacing) { finished, existing in
                await apply(existing == nil
                            ? { await model.database.addColumn(finished, to: selected ?? "", in: database) }
                            : { await model.database.changeColumn(existing!, to: finished,
                                                                  in: selected ?? "", database: database) })
            }
        }
        .sheet(isPresented: $newIndex) {
            IndexSheet(columns: columns.map(\.name)) { name, chosen, unique in
                await apply { await model.database.addIndex(named: name, on: chosen, unique: unique,
                                                            table: selected ?? "", database: database) }
            }
        }
        .sheet(isPresented: $newUser) {
            UserSheet { name, host, password in
                await apply { await model.database.createUser(name, host: host, password: password) }
            }
        }
        .alert(confirming?.title ?? "", isPresented: .init(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Do it", role: .destructive) {
                let action = confirming?.run
                confirming = nil
                guard let action else { return }
                Task { await apply(action) }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(confirming?.cost ?? "")
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
            Text(database).fontWeight(.medium)
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .green)
                    .lineLimit(2)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Left

    @ViewBuilder
    private var sidebar: some View {
        switch pane {
        case .tables:
            VStack(spacing: 0) {
                List(selection: $selected) {
                    if tables.isEmpty {
                        Text("No tables in this database yet.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(tables, id: \.name) { table in
                        HStack {
                            Image(systemName: "tablecells").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(table.name)
                                Text("\(table.rows) rows").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(table.name)
                        .contextMenu { tableMenu(table.name) }
                    }
                }
                Divider()
                HStack {
                    Button { newTable = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New table")
                    Spacer()
                }
                .padding(6)
            }
            .onChange(of: selected) { Task { await loadStructure() } }

        case .users:
            VStack(spacing: 0) {
                List(selection: Binding(get: { selectedUser?.id },
                                        set: { id in selectedUser = users.first { $0.id == id } })) {
                    if users.isEmpty {
                        Text("No accounts could be read — root access is needed for this list.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.name)
                            Text(user.host).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(user.id)
                    }
                }
                Divider()
                HStack {
                    Button { newUser = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New account")
                    Spacer()
                }
                .padding(6)
            }
            .onChange(of: selectedUser) { Task { await loadGrants() } }
        }
    }

    @ViewBuilder
    private func tableMenu(_ name: String) -> some View {
        Button("Rename…") { renameTable(name) }
        Button("Empty it…") {
            confirming = Confirmation(
                title: String(localized: "Remove every row from “\(name)”?"),
                cost: String(localized: "The table stays, the data does not. This cannot be undone."),
                run: { await model.database.truncateTable(name, in: database) })
        }
        Divider()
        Button("Drop table…", role: .destructive) {
            confirming = Confirmation(
                title: String(localized: "Drop the table “\(name)”?"),
                cost: String(localized: "The table and everything in it is removed. Take a snapshot first if you are unsure."),
                run: { await model.database.dropTable(name, in: database) })
        }
    }

    // MARK: - Right: a table

    @ViewBuilder
    private var tableDetail: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(selected).font(.title3).fontWeight(.medium)
                        Spacer()
                        Button("Add column") {
                            replacing = nil
                            editingColumn = ColumnDraft()
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(columns) { column in
                                HStack(spacing: 8) {
                                    Image(systemName: column.isPrimaryKey ? "key.fill" : "circle.dashed")
                                        .foregroundStyle(column.isPrimaryKey ? .yellow : .secondary)
                                        .frame(width: 16)
                                    Text(column.name).frame(width: 170, alignment: .leading)
                                    Text(column.type)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if column.isAutoIncrement {
                                        Text("auto").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(column.isNullable ? "NULL" : "NOT NULL")
                                        .font(.caption).foregroundStyle(.tertiary)

                                    Button("Edit") {
                                        replacing = column.name
                                        editingColumn = ColumnDraft(
                                            name: column.name, type: column.type,
                                            isNullable: column.isNullable,
                                            isPrimaryKey: column.isPrimaryKey,
                                            isAutoIncrement: column.isAutoIncrement)
                                    }
                                    .buttonStyle(.borderless)

                                    Button {
                                        confirming = Confirmation(
                                            title: String(localized: "Drop the column “\(column.name)”?"),
                                            cost: String(localized: "Everything stored in it is lost. This cannot be undone."),
                                            run: { await model.database.dropColumn(column.name, from: selected, in: database) })
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 5)
                                if column.id != columns.last?.id { Divider() }
                            }
                        }
                        .padding(4)
                    } label: { Label("Columns", systemImage: "tablecells") }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            if indexes.isEmpty {
                                Text("No indexes.").foregroundStyle(.secondary)
                            }
                            ForEach(indexes) { index in
                                HStack {
                                    Image(systemName: index.isPrimary ? "key.fill" : "list.bullet.indent")
                                        .foregroundStyle(index.isPrimary ? .yellow : .secondary)
                                    Text(index.name)
                                    Text(index.summary).font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        confirming = Confirmation(
                                            title: String(localized: "Drop the index “\(index.name)”?"),
                                            cost: String(localized: "No data is lost. Queries relying on it get slower."),
                                            run: { await model.database.dropIndex(index.name, table: selected, database: database) })
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            Divider()
                            Button("Add index") { newIndex = true }
                                .disabled(columns.isEmpty)
                        }
                        .padding(4)
                    } label: { Label("Indexes", systemImage: "list.bullet.indent") }

                    if !createStatement.isEmpty {
                        GroupBox {
                            Text(createStatement)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        } label: { Label("As SQL", systemImage: "curlybraces") }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(tables.isEmpty ? "No tables yet" : "Pick a table",
                                   systemImage: "tablecells",
                                   description: Text(tables.isEmpty
                                        ? "Create the first one with the plus below the list."
                                        : "Or create one with the plus below the list."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Right: an account

    @ViewBuilder
    private var userDetail: some View {
        if let user = selectedUser {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(user.name)@\(user.host)").font(.title3).fontWeight(.medium)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(grants, id: \.self) { grant in
                                Text(grant)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if grants.isEmpty { Text("No grants.").foregroundStyle(.secondary) }
                        }
                        .padding(4)
                    } label: { Label("What it may do", systemImage: "checklist") }

                    HStack(spacing: 8) {
                        Button("Grant everything on \(database)") {
                            Task { await apply { await model.database.grant("ALL PRIVILEGES", on: database, to: user) } }
                        }
                        Button("Read only on \(database)") {
                            Task { await apply { await model.database.grant("SELECT", on: database, to: user) } }
                        }
                        Button("Revoke on \(database)") {
                            Task { await apply { await model.database.revokeAll(on: database, from: user) } }
                        }
                    }

                    Divider()
                    Button("Remove this account…", role: .destructive) {
                        confirming = Confirmation(
                            title: String(localized: "Remove \(user.name)@\(user.host)?"),
                            cost: String(localized: "Anything connecting with it stops working — a site's configuration file usually names one."),
                            run: { await model.database.dropUser(user) })
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Pick an account", systemImage: "person.crop.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Doing things

    private func apply(_ action: @escaping () async -> CommandResult) async {
        busy = true
        let result = await action()
        busy = false
        isError = !result.succeeded
        message = result.succeeded
            ? String(localized: "Done.")
            : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        await reload()
        await loadStructure()
        await loadGrants()
    }

    private func renameTable(_ name: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(name)”")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wanted = field.stringValue
        guard wanted != name, !wanted.isEmpty else { return }
        Task { await apply { await model.database.renameTable(name, to: wanted, in: database) } }
    }

    private func reload() async {
        tables = await model.database.tables(in: database)
        users = await model.database.users()
        if selected == nil { selected = tables.first?.name }
    }

    private func loadStructure() async {
        guard let selected else { columns = []; indexes = []; createStatement = ""; return }
        columns = await model.database.columns(of: selected, in: database)
        indexes = await model.database.indexes(of: selected, in: database)
        createStatement = await model.database.createStatement(of: selected, in: database) ?? ""
    }

    private func loadGrants() async {
        guard let selectedUser else { grants = []; return }
        grants = await model.database.grants(of: selectedUser)
    }
}
