//
//  SchemaSheets.swift
//  ServerMaster
//
//  The small forms the schema editor opens: a new table, one column, an index,
//  an account.
//
//  Each one is deliberately dumb. It collects what it needs, validates only what
//  it can validate locally, and hands the answer back — the statement is built
//  and run by the caller, so there is exactly one place where SQL is assembled.
//

import SwiftUI

// MARK: - A new table

struct TableBuilderSheet: View {

    let database: String
    let onDone: () async -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// Starts with an id column, because a table without a primary key cannot
    /// have its rows edited later and almost nobody wants that on purpose.
    @State private var columns: [ColumnDraft] = [
        ColumnDraft(name: "id", type: "INT", isNullable: false,
                    isPrimaryKey: true, isAutoIncrement: true)
    ]
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New table in \(database)").font(.headline)

            HStack {
                Text("Name").frame(width: 70, alignment: .leading)
                TextField("things", text: $name)
                    .font(.system(.body, design: .monospaced))
            }

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($columns) { $column in
                        HStack(spacing: 6) {
                            TextField("name", text: $column.name)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 130)
                            Picker("", selection: $column.type) {
                                ForEach(ColumnDraft.commonTypes, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Toggle("PK", isOn: $column.isPrimaryKey)
                                .toggleStyle(.checkbox).help("Primary key")
                            Toggle("A/I", isOn: $column.isAutoIncrement)
                                .toggleStyle(.checkbox).help("Auto increment")
                            Toggle("null", isOn: $column.isNullable)
                                .toggleStyle(.checkbox).help("May be empty")
                            Spacer()
                            Button {
                                columns.removeAll { $0.id == column.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(columns.count == 1)
                        }
                    }
                }
            }
            .frame(height: 200)

            Button("Add column") { columns.append(ColumnDraft()) }

            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 660)
    }

    private func create() {
        busy = true
        Task {
            let result = await model.database.createTable(name, columns: columns, in: database)
            busy = false
            if result.succeeded {
                await onDone()
                dismiss()
            } else {
                problem = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

// MARK: - One column

struct ColumnSheet: View {

    @State var draft: ColumnDraft
    /// The name of the column being replaced, or nil when adding.
    let replacing: String?
    let onDone: (ColumnDraft, String?) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(replacing == nil ? "Add a column" : "Change “\(replacing!)”")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("", text: $draft.name)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Type")
                    HStack(spacing: 6) {
                        Picker("", selection: $draft.type) {
                            ForEach(ColumnDraft.commonTypes, id: \.self) { Text($0).tag($0) }
                            if !ColumnDraft.commonTypes.contains(draft.type) {
                                Text(draft.type).tag(draft.type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        TextField("or type it", text: $draft.type)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                GridRow {
                    Text("Default")
                    TextField("none", text: $draft.defaultValue)
                        .font(.system(.callout, design: .monospaced))
                }
            }

            Toggle("May be empty (NULL)", isOn: $draft.isNullable)
            Toggle("Primary key", isOn: $draft.isPrimaryKey)
            Toggle("Auto increment", isOn: $draft.isAutoIncrement)

            Text("CURRENT_TIMESTAMP, NOW(), UUID(), TRUE, FALSE and NULL are used as expressions. Anything else becomes a value.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(replacing == nil ? "Add" : "Change") {
                    Task {
                        await onDone(draft, replacing)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - An index

struct IndexSheet: View {

    let columns: [String]
    let onDone: (String, [String], Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chosen: Set<String> = []
    @State private var unique = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an index").font(.headline)

            HStack {
                Text("Name").frame(width: 60, alignment: .leading)
                TextField(suggestion, text: $name)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle("Unique — refuse duplicate values", isOn: $unique)

            Text("Columns, in order").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(
                            get: { chosen.contains(column) },
                            set: { wanted in
                                if wanted { chosen.insert(column) } else { chosen.remove(column) }
                            }))
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
            .frame(height: 160)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let ordered = columns.filter { chosen.contains($0) }
                    let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestion : name
                    Task {
                        await onDone(finalName, ordered, unique)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// The name MySQL would have picked, offered so nobody has to invent one.
    private var suggestion: String {
        let ordered = columns.filter { chosen.contains($0) }
        return ordered.isEmpty ? "idx" : "idx_" + ordered.joined(separator: "_")
    }
}

// MARK: - An account

struct UserSheet: View {

    let onDone: (String, String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = "localhost"
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New account").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("", text: $name).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Host")
                    Picker("", selection: $host) {
                        Text("localhost").tag("localhost")
                        Text("127.0.0.1").tag("127.0.0.1")
                        Text("any host (%)").tag("%")
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Password")
                    TextField("", text: $password).font(.system(.body, design: .monospaced))
                }
            }

            Text("A site's config file names both the account and the host. localhost and 127.0.0.1 are different accounts to MySQL, which is a common half-hour to lose.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        await onDone(name, host, password)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
