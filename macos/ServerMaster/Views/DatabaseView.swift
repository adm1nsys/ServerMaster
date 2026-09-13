//
//  DatabaseView.swift
//  ServerMaster
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A wrapper for sheet(item:) — it needs Identifiable.
private struct BrowseTarget: Identifiable {
    var name: String
    var id: String { name }
}

struct DatabaseView: View {

    @Environment(AppModel.self) private var model

    @State private var newName = ""
    @State private var newUser = "smuser"
    @State private var importing = false
    @State private var newPassword = "smpass"
    @State private var dropCandidate: DatabaseInfo?
    @State private var showLog = false
    @State private var browsing: String?
    @State private var editingSchema: String?

    private var db: DatabaseService { model.database }
    private var panel: DatabaseAdminPanel { model.adminPanel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                ScreenTitle(title: "Database",
                            subtitle: "A separate MariaDB instance for local sites") {
                    HStack(spacing: 8) {
                        if db.state.isBusy { ProgressView().controlSize(.small) }
                        if db.state.isActive {
                            Button {
                                Task { await model.stopDatabase() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .modifier(HeaderButton())
                        } else {
                            Button {
                                Task { await model.startDatabase() }
                            } label: {
                                Label("Start", systemImage: "play.fill")
                            }
                            .modifier(HeaderButton(prominent: true))
                            .disabled(!db.isInstalled)
                        }
                    }
                }

                glassPanel(statusCard)

                if db.state == .running {
                    glassPanel(connectionCard)
                    glassPanel(adminPanelCard)
                    glassPanel(databasesCard)
                }

                if !db.isInstalled { glassPanel(installCard) }

                glassPanel(logCard)
            }
            .padding(36)
//            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task { await db.refreshState() }
        .sheet(item: Binding(get: { editingSchema.map { BrowseTarget(name: $0) } },
                             set: { editingSchema = $0?.name })) { target in
            SchemaEditorSheet(database: target.name).environment(model)
        }
        .sheet(item: Binding(get: { browsing.map { BrowseTarget(name: $0) } },
                             set: { browsing = $0?.name })) { target in
            DatabaseBrowserSheet(database: target.name).environment(model)
        }
        .confirmationDialog("Delete the database “\(dropCandidate?.name ?? "")” with all its data?",
                            isPresented: Binding(get: { dropCandidate != nil },
                                                 set: { if !$0 { dropCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let target = dropCandidate {
                    Task { _ = await db.dropDatabase(name: target.name) }
                }
                dropCandidate = nil
            }
            Button("Cancel", role: .cancel) { dropCandidate = nil }
        }
    }

    // MARK: - Glass

    /// The panels on this screen, on glass over the moving background.
    ///
    /// A GroupBox draws an opaque surface, which on this background reads as a
    /// grey card sitting on a photograph. Glass keeps the colour moving
    /// underneath while the text stays legible.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }

    /// The buttons beside the screen title, matching Control.
    private struct HeaderButton: ViewModifier {
        var prominent = false
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    /// Turns any button into the small glass chip used across this screen.
    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass).controlSize(.small).font(.caption)
            } else {
                content.buttonStyle(.bordered).controlSize(.small).font(.caption)
            }
        }
    }

    /// A small glass button in place of a link.
    @ViewBuilder
    private func chip(_ title: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        let button = Button(title, action: run).font(.caption)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).controlSize(.small)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        // No GroupBox: the glass panel around this is the container,
        // and a box inside it puts a second surface on the first.
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Connection", symbol: "cable.connector")
                .padding(.top, 15)
                .padding(.leading, 15)
            HStack(spacing: 14) {
                Circle()
                    .fill(color(for: db.state))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(db.state.title).fontWeight(.medium)
                    if case .failed(let message) = db.state {
                        Text(message)
                            .font(.callout).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if db.state == .running {
                        Text(db.version).font(.caption).foregroundStyle(.secondary)
                    } else if db.isInstalled {
                        Text("Its own data directory and port — your system MariaDB is left alone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let pid = db.processIdentifier, db.state == .running {
                    Text("PID \(String(pid))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 15)
        }
    }

    private func color(for state: DatabaseState) -> Color {
        switch state {
        case .running: return .green
        case .starting, .stopping, .initializing: return .orange
        case .failed: return .red
        case .notInstalled, .stopped: return .secondary
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        // No GroupBox: the glass panel around this is the container.
        Group {
            VStack(alignment: .leading, spacing: 0) {
                Text("These are the details you enter in the installer of Joomla, WordPress or any other CMS.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                InfoRow(label: "Host", value: db.host, monospaced: true)
                Divider()
                InfoRow(label: "Port", value: String(db.port), monospaced: true)
                Divider()
                InfoRow(label: "Host and port", value: db.connectionSummary, monospaced: true,
                        action: ("Copy", {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(db.connectionSummary, forType: .string)
                        }))
                Divider()
                InfoRow(label: "Socket", value: db.socketPath, monospaced: true)
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Port \(String(db.port)) speaks the MySQL protocol, not HTTP — a browser cannot open it. Use “Open” next to a database to view and edit its data.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.top, 6)
            }
            .padding(15)
        }
    }

    // MARK: - Web admin panel

    private var adminPanelCard: some View {
        // No GroupBox: the glass panel around this is the container,
        // and a box inside it puts a second surface on the first.
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Web admin panel", symbol: "tablecells.badge.ellipsis")
                .padding(.top, 15)
                .padding(.leading, 15)
            VStack(alignment: .leading, spacing: 10) {
                Text("A web interface for this database, the way MAMP had one: its own port, opened in your browser.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.openAdminPanel() }
                    } label: {
                        Label(panel.isRunning ? "Open panel" : "Start and open",
                              systemImage: "safari")
                    }
                    .disabled(!db.state.isActive || panel.state == .starting)

                    if panel.isRunning {
                        Button("Stop") { panel.stop() }
                            .modifier(ChipStyle())
                    }
                    if panel.state == .starting { ProgressView().controlSize(.small) }

                    Spacer()

                    Text(model.settings.databaseAdminTool.title)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !db.state.isActive {
                    Text("Start the database first.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let url = panel.address {
                    Divider()
                    InfoRow(label: "Address", value: url.absoluteString, monospaced: true,
                            action: ("Copy", {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }))
                    // Both panels sign in on their own. These are shown only as a
                    // fallback — and “Server” especially: left at “localhost”,
                    // Adminer looks for a socket that is not there.
                    if model.settings.databaseAdminTool == .adminer {
                        Divider()
                        InfoRow(label: "Server", value: db.connectionSummary, monospaced: true,
                                action: ("Copy", {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(db.connectionSummary, forType: .string)
                                }))
                        Divider()
                        InfoRow(label: "User", value: DatabaseAdminPanel.accountName, monospaced: true)
                        Divider()
                        InfoRow(label: "Password", value: panel.currentPassword, monospaced: true,
                                action: ("Copy", {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(panel.currentPassword, forType: .string)
                                }))
                        Text("The panel signs in by itself; these are only needed if that fails. Leave Server at 127.0.0.1 with the port — “localhost” makes Adminer look for a socket that is not there. A new password is generated on every start.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if case .failed(let message) = panel.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15)
        }
    }

    // MARK: - Databases

    private var databasesCard: some View {
        // No GroupBox: the glass panel around this is the container,
        // and a box inside it puts a second surface on the first.
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Databases", symbol: "cylinder.split.1x2")
                .padding(.top, 15)
                .padding(.leading, 15)
            VStack(alignment: .leading, spacing: 10) {
                if db.databases.isEmpty {
                    Text("No databases yet. Create one for your site.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(db.databases) { item in
                        HStack {
                            Image(systemName: "cylinder").foregroundStyle(.secondary)
                            Text(item.name).fontWeight(.medium)
                            Text("\(item.tables) tables")
                                .font(.caption).foregroundStyle(.secondary)
                            if item.sizeMB > 0 {
                                Text("· \(item.sizeMB, specifier: "%.1f") MB")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { browsing = item.name }
                                .modifier(ChipStyle())
                            Button("Structure") { editingSchema = item.name }
                                .modifier(ChipStyle())
                                .help("Tables, columns, indexes and accounts")
                            Button("Copy name") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.name, forType: .string)
                            }
                            .modifier(ChipStyle())
                            Button("Delete") { dropCandidate = item }
                                .modifier(ChipStyle())
                                .foregroundStyle(.red)
                        }
                        Divider()
                    }
                }

                HStack(spacing: 8) {
                    TextField("database name", text: $newName)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 150)
                    TextField("user", text: $newUser)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 130)
                    TextField("password", text: $newPassword)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 130)
                    Button("Create") {
                        let name = newName
                        Task {
                            let result = await db.createDatabase(name: name, user: newUser,
                                                                 password: newPassword)
                            model.notify(result.succeeded
                                         ? "Database “\(name)” created."
                                         : result.combined,
                                         isError: !result.succeeded)
                            if result.succeeded { newName = "" }
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Import…") { importDump() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || importing)

                    if importing { ProgressView().controlSize(.small) }
                    Spacer()
                }

                Text("Import loads a .sql file, a gzipped one, or an archive with a dump inside — a Joomla or WordPress backup goes straight in. Type the name first; the database is created if it is not there.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("The password is stored in the database and ends up in your site config. Fine for a local setup, not for production.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }

    // MARK: - Installation

    private var installCard: some View {
        // No GroupBox: the glass panel around this is the container,
        // and a box inside it puts a second surface on the first.
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Database log", symbol: "text.alignleft")
                .padding(.top, 15)
                .padding(.leading, 15)
            VStack(alignment: .leading, spacing: 8) {
                Text("MariaDB is not installed. Sites on Joomla, WordPress and other CMSes will not work without it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("brew install mariadb")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button("Open dependencies") { model.section = .dependencies }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
        }
    }

    // MARK: - Log

    private var logCard: some View {
        // No GroupBox: the glass panel around this is the container.
        Group {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Everything the database reports about itself, including why it crashed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    chip(showLog ? "Collapse" : "Expand") { showLog.toggle() }
                    chip("Clear") { db.log.clear() }
                }
                LogOutputView(log: db.log,
                              fontSize: model.settings.consoleFontSize,
                              autoScroll: true)
                    .frame(height: showLog ? 320 : 440)
            }
            .padding(15)
        }
    }

    /// Loading a dump someone already has. The name typed in the row above is
    /// the target: importing into a database chosen after the fact is how people
    /// overwrite the wrong one.
    private func importDump() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.message = String(localized: "Choose a .sql dump, or an archive with one inside")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let name = newName.trimmingCharacters(in: .whitespaces)
        importing = true
        Task {
            let outcome = await model.database.importDump(from: url, into: name,
                                                          user: newUser, password: newPassword)
            importing = false
            model.notify(outcome.message, isError: !outcome.succeeded)
            if outcome.succeeded { newName = "" }
        }
    }
}
