//
//  DatabaseView.swift
//  ServerMaster
//

import SwiftUI
import AppKit

/// A wrapper for sheet(item:) — it needs Identifiable.
private struct BrowseTarget: Identifiable {
    var name: String
    var id: String { name }
}

struct DatabaseView: View {

    @Environment(AppModel.self) private var model

    @State private var newName = ""
    @State private var newUser = "smuser"
    @State private var newPassword = "smpass"
    @State private var dropCandidate: DatabaseInfo?
    @State private var showLog = false
    @State private var browsing: String?

    private var db: DatabaseService { model.database }
    private var panel: DatabaseAdminPanel { model.adminPanel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                SectionHeader(title: "Database",
                              subtitle: "A separate MariaDB instance for local sites") {
                    HStack(spacing: 8) {
                        if db.state.isBusy { ProgressView().controlSize(.small) }
                        if db.state.isActive {
                            Button {
                                Task { await model.stopDatabase() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        } else {
                            Button {
                                Task { await model.startDatabase() }
                            } label: {
                                Label("Start", systemImage: "play.fill")
                            }
                            .disabled(!db.isInstalled)
                        }
                    }
                }

                statusCard

                if db.state == .running {
                    connectionCard
                    adminPanelCard
                    databasesCard
                }

                if !db.isInstalled { installCard }

                logCard
            }
            .padding(20)
//            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task { await db.refreshState() }
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

    // MARK: - Status

    private var statusCard: some View {
        GroupBox {
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
            .padding(6)
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
        GroupBox {
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
            .padding(6)
        } label: {
            Label("Connection", systemImage: "cable.connector")
        }
    }

    // MARK: - Web admin panel

    private var adminPanelCard: some View {
        GroupBox {
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
                            .buttonStyle(.link)
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
            .padding(6)
        } label: {
            Label("Web admin panel", systemImage: "tablecells.badge.ellipsis")
        }
    }

    // MARK: - Databases

    private var databasesCard: some View {
        GroupBox {
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
                                .buttonStyle(.link)
                            Button("Copy name") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.name, forType: .string)
                            }
                            .buttonStyle(.link)
                            Button("Delete") { dropCandidate = item }
                                .buttonStyle(.link)
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
                    Spacer()
                }

                Text("The password is stored in the database and ends up in your site config. Fine for a local setup, not for production.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Databases", systemImage: "cylinder.split.1x2")
        }
    }

    // MARK: - Installation

    private var installCard: some View {
        GroupBox {
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
            .padding(6)
        }
    }

    // MARK: - Log

    private var logCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Everything the database reports about itself, including why it crashed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(showLog ? "Collapse" : "Expand") { showLog.toggle() }
                        .buttonStyle(.link)
                    Button("Clear") { db.log.clear() }
                        .buttonStyle(.link)
                }
                LogOutputView(log: db.log,
                              fontSize: model.settings.consoleFontSize,
                              autoScroll: true)
                    .frame(height: showLog ? 320 : 440)
            }
            .padding(6)
        } label: {
            Label("Database log", systemImage: "text.alignleft")
        }
    }
}
