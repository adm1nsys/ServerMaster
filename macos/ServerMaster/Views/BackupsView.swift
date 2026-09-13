//
//  BackupsView.swift
//  ServerMaster
//
//  Snapshots: taking one, seeing what is there, and putting one back.
//
//  Restoring is the part worth being careful with, so it is deliberately not one
//  click. What gets put back is chosen — settings, files, database — and the
//  screen says plainly that the files currently in the folder are replaced.
//

import SwiftUI
import AppKit

struct BackupsView: View {

    @Environment(AppModel.self) private var model

    @State private var restoring: Snapshot?
    @State private var parts: Set<SnapshotStore.RestoreOption> = [.settings, .site, .database]
    @State private var problems: [String] = []
    @State private var deleting: Snapshot?
    @State private var restoringDatabase: Snapshot?
    @State private var clock = WaitingClock()
    @State private var job: Waiting.Job = .snapshot

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Backups",
                              subtitle: "Take a snapshot before you break something") {
                    Button {
                        job = .snapshot
                        Task { await takeAll() }
                    } label: {
                        Label("Snapshot every profile", systemImage: "camera")
                    }
                    .disabled(model.profiles.isEmpty || model.snapshots.isWorking)
                }

                if model.snapshots.isWorking {
                    glassPanel(
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(Waiting.line(for: job, elapsed: clock.elapsed))
                                Spacer()
                                if clock.elapsed >= 15 {
                                    Text("\(Int(clock.elapsed)) s")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        .padding(15))
                }

                scheduleCard
                takeCard
                databaseCard
                listCard

                if let error = model.snapshots.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(36)
        }
        .onChange(of: model.snapshots.isWorking) { _, working in
            if working { clock.start() } else { clock.stop() }
        }
        .sheet(item: $restoring) { snapshot in
            restoreSheet(snapshot)
        }
        .alert("Delete this snapshot?", isPresented: .init(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { model.snapshots.delete(deleting) }
                deleting = nil
            }
            Button("Keep", role: .cancel) { deleting = nil }
        } message: {
            Text("The files are removed from disk. This cannot be undone.")
        }
        .alert("Restore this database?", isPresented: .init(
            get: { restoringDatabase != nil },
            set: { if !$0 { restoringDatabase = nil } })) {
            Button("Restore", role: .destructive) {
                let snapshot = restoringDatabase
                restoringDatabase = nil
                guard let snapshot else { return }
                job = .restore
                Task {
                    let problem = await model.snapshots.restoreDatabase(snapshot,
                                                                        database: model.database)
                    model.notify(problem ?? String(localized: "Database “\(snapshot.profileName)” restored."),
                                 isError: problem != nil)
                }
            }
            Button("Cancel", role: .cancel) { restoringDatabase = nil }
        } message: {
            Text("“\(restoringDatabase?.profileName ?? "")” is replaced with the saved copy. Everything in it now is lost.")
        }
    }

    /// The panels on this screen, on glass over the moving background.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct GlassStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass).controlSize(.small).font(.caption)
            } else {
                content.buttonStyle(.bordered).controlSize(.small).font(.caption)
            }
        }
    }

    // MARK: - When it happens by itself

    private var scheduleCard: some View {
        @Bindable var model = model

        return glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Schedule", symbol: "clock")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Take snapshots automatically", isOn: $model.settings.backupsEnabled)
                        .onChange(of: model.settings.backupsEnabled) { model.saveSettings() }

                    HStack(spacing: 8) {
                        Text("Every")
                        TextField("", value: $model.settings.backupEvery, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Picker("", selection: $model.settings.backupUnit) {
                            ForEach(BackupInterval.allCases) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        Spacer()

                        Text("Keep")
                        TextField("", value: $model.settings.backupsToKeep, format: .number)
                            .frame(width: 50)
                            .multilineTextAlignment(.trailing)
                        Text("scheduled ones per profile")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!model.settings.backupsEnabled)
                    .onChange(of: model.settings.backupEvery) { model.saveSettings() }
                    .onChange(of: model.settings.backupUnit) { model.saveSettings() }
                    .onChange(of: model.settings.backupsToKeep) { model.saveSettings() }

                    Toggle("Include the database", isOn: $model.settings.backupIncludesDatabase)
                        .onChange(of: model.settings.backupIncludesDatabase) { model.saveSettings() }
                        .disabled(!model.settings.backupsEnabled)

                    Divider()

                    HStack(spacing: 8) {
                        Text("Into")
                        Text(AppPaths.abbreviate(destinationPath))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…") { chooseDestination() }
                        Button("Show") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destinationPath)
                        }
                    }

                    if let last = model.settings.lastBackup {
                        Text("Last automatic snapshot \(SnapshotStore.readable.string(from: last))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if model.settings.backupsEnabled {
                        Text("Nothing taken automatically yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .padding(15))
    }

    private var destinationPath: String {
        model.settings.backupDestination.isEmpty
            ? SnapshotStore.defaultDestination()
            : model.settings.backupDestination
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: destinationPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.backupDestination = url.path
        model.saveSettings()
        model.snapshots.setDestination(url.path)
    }

    // MARK: - Taking one now

    private var takeCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Profiles", symbol: "square.stack.3d.up")
                VStack(alignment: .leading, spacing: 8) {
                    if model.profiles.isEmpty {
                        Text("No profiles yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.profiles) { profile in
                        HStack {
                            Label(profile.name, systemImage: profile.iconName)
                            Text(AppPaths.abbreviate(profile.rootPath))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Text(count(for: profile))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Snapshot") {
                                job = .snapshot
                                Task {
                                    await model.snapshots.take(profile: profile,
                                                               database: model.database)
                                }
                            }
                            .disabled(model.snapshots.isWorking)
                        }
                        if profile.id != model.profiles.last?.id { Divider() }
                    }
                }
                .padding(4)
            }
            .padding(15))
    }

    private func count(for profile: ServerProfile) -> String {
        let all = model.snapshots.snapshots(for: profile.id)
        guard let newest = all.first else { return String(localized: "never") }
        return String(localized: "\(all.count) — newest \(SnapshotStore.readable.string(from: newest.taken))")
    }

    // MARK: - Databases on their own

    /// Separate from the profile snapshots above, because the two break
    /// separately: a database that will not come back after an interrupted write
    /// has nothing to do with the files beside it, and rolling a whole site back
    /// to fix it is the wrong trade.
    private var databaseCard: some View {
        @Bindable var model = model

        return glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Databases", symbol: "cylinder.split.1x2")
                VStack(alignment: .leading, spacing: 8) {
                    if model.database.state != .running {
                        Text("The database server is not running — start it to take or restore a snapshot.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if model.database.databases.isEmpty {
                        Text("No databases yet.").foregroundStyle(.secondary)
                    }

                    ForEach(model.database.databases, id: \.name) { item in
                        HStack {
                            Label(item.name, systemImage: "cylinder")
                            Text("\(item.tables) tables")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(databaseCount(item.name))
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Snapshot") {
                                job = .database
                                Task {
                                    await model.snapshots.takeDatabase(named: item.name,
                                                                       database: model.database)
                                }
                            }
                            .disabled(model.database.state != .running || model.snapshots.isWorking)
                        }
                        if item.name != model.database.databases.last?.name { Divider() }
                    }

                    Divider()
                    Toggle("Snapshot every database on the schedule too", isOn: $model.settings.backupAllDatabases)
                        .onChange(of: model.settings.backupAllDatabases) { model.saveSettings() }
                }
                .padding(4)
            }
            .padding(15))
    }

    private func databaseCount(_ name: String) -> String {
        let all = model.snapshots.snapshots(ofDatabase: name)
        guard let newest = all.first else { return String(localized: "never") }
        return String(localized: "\(all.count) — newest \(SnapshotStore.readable.string(from: newest.taken))")
    }

    // MARK: - What is there

    private var listCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Snapshots", symbol: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 8) {
                    if model.snapshots.snapshots.isEmpty {
                        Text("Nothing has been saved yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshots.snapshots) { snapshot in
                        HStack(spacing: 10) {
                            Image(systemName: snapshot.kind == .database
                                  ? "cylinder"
                                  : (snapshot.trigger == .scheduled ? "clock" : "camera"))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.profileName)
                                Text(contents(of: snapshot))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(SnapshotStore.readable.string(from: snapshot.taken))
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if snapshot.kind == .database {
                                Button("Restore…") { restoringDatabase = snapshot }
                                    .disabled(model.database.state != .running)
                            } else {
                                Button("Restore…") {
                                    parts = [.settings]
                                    if snapshot.includesSite { parts.insert(.site) }
                                    if snapshot.includesDatabase { parts.insert(.database) }
                                    problems = []
                                    restoring = snapshot
                                }
                                .disabled(model.profiles.allSatisfy { $0.id != snapshot.profileID })
                            }

                            Button {
                                NSWorkspace.shared.selectFile(nil,
                                    inFileViewerRootedAtPath: model.snapshots.folder(for: snapshot).path)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)

                            Button { deleting = snapshot } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        if snapshot.id != model.snapshots.snapshots.last?.id { Divider() }
                    }
                }
                .padding(4)
            }
            .padding(15))
    }

    private func contents(of snapshot: Snapshot) -> String {
        if snapshot.kind == .database {
            return String(localized: "database only") + "  "
                + ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file)
        }
        var parts = [String(localized: "settings")]
        if snapshot.includesSite { parts.append(String(localized: "files")) }
        if let name = snapshot.databaseName { parts.append(name) }
        let size = ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file)
        return parts.joined(separator: " · ") + "  " + size
    }

    // MARK: - Putting one back

    private func restoreSheet(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore “\(snapshot.profileName)”")
                .font(.headline)
            Text("Taken \(SnapshotStore.readable.string(from: snapshot.taken))")
                .foregroundStyle(.secondary)

            Toggle("Settings", isOn: binding(.settings))
            Toggle("Files in the site folder", isOn: binding(.site))
                .disabled(!snapshot.includesSite)
            Toggle(snapshot.databaseName.map { "Database “\($0)”" } ?? "Database",
                   isOn: binding(.database))
                .disabled(!snapshot.includesDatabase)

            if parts.contains(.site) {
                Label("What is in the folder now is replaced. A copy is kept beside it until the restore finishes.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).font(.callout).foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { restoring = nil }
                Button("Restore") {
                    Task { await restore(snapshot) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parts.isEmpty || model.snapshots.isWorking)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func binding(_ option: SnapshotStore.RestoreOption) -> Binding<Bool> {
        Binding(get: { parts.contains(option) },
                set: { wanted in
                    if wanted { parts.insert(option) } else { parts.remove(option) }
                })
    }

    private func restore(_ snapshot: Snapshot) async {
        job = .restore
        guard let profile = model.profiles.first(where: { $0.id == snapshot.profileID }) else { return }
        // A running server holding the folder open is the shortest route to a
        // half-restored site.
        if model.state(of: profile.id) != .stopped {
            await model.stopServer(profileID: profile.id)
        }
        let outcome = await model.snapshots.restore(snapshot, parts: parts,
                                                    into: profile, database: model.database)
        if parts.contains(.settings) {
            model.updateProfile(outcome.profile)
        }
        problems = outcome.problems
        if problems.isEmpty { restoring = nil }
    }

    private func takeAll() async {
        for profile in model.profiles {
            await model.snapshots.take(profile: profile, database: model.database)
        }
    }
}
