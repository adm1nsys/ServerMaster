//
//  AppSettingsView.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct AppSettingsView: View {

    @Environment(AppModel.self) private var model
    @State private var newPathEntry = ""
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                SectionHeader(title: "App settings",
                              subtitle: "Defaults, console, ports and environment")

                Card("Profiles", systemImage: "star") {
                    Picker("Default profile", selection: $model.settings.defaultProfileID) {
                        Text("Not selected").tag(UUID?.none)
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                    Toggle("Start the default profile when the app launches",
                           isOn: $model.settings.autostartDefaultProfile)
                    Toggle("Open the last used section",
                           isOn: $model.settings.restoreLastSection)
                }

                Card("Starting and stopping", systemImage: "play.circle") {
                    Toggle("Open the browser after start (all profiles)",
                           isOn: $model.settings.openBrowserOnStart)
                    Toggle("Stop servers when the app quits",
                           isOn: $model.settings.stopServerOnQuit)
                    Toggle("Ask for confirmation before stopping",
                           isOn: $model.settings.confirmBeforeStop)
                    Toggle("Restart automatically after a crash",
                           isOn: $model.settings.restartOnCrash)

                    Divider()

                    Toggle("Check whether the port is free before starting",
                           isOn: $model.settings.checkPortBeforeStart)
                    Toggle("Free the port automatically if it is taken",
                           isOn: $model.settings.killPortOccupantOnStart)
                        .disabled(!model.settings.checkPortBeforeStart)
                    if model.settings.killPortOccupantOnStart {
                        Text("The app will send SIGTERM to whichever process holds the port. Be careful with system services.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card("Console", systemImage: "terminal") {
                    HStack {
                        Text("Font size").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        Slider(value: $model.settings.consoleFontSize, in: 9...20, step: 1)
                            .frame(width: 200)
                        Text("\(Int(model.settings.consoleFontSize)) pt")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Buffered lines").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        TextField("", value: $model.settings.consoleBufferLines,
                                  format: .number.grouping(.never))
                            .frame(width: 100)
                        Spacer()
                    }
                    Toggle("Auto scroll", isOn: $model.settings.autoScrollConsole)
                    Toggle("Write the server log to a file", isOn: $model.settings.writeLogsToFile)
                    if model.settings.writeLogsToFile {
                        HStack {
                            Text("Keep logs for").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                            TextField("", value: $model.settings.logRetentionDays,
                                      format: .number.grouping(.never))
                                .frame(minWidth: 60, idealWidth: 80, maxWidth: 100)
                            Text("days (0 — never remove)").foregroundStyle(.secondary).font(.caption)
                            Spacer()
                        }
                        Text("Every server start creates its own file. Old ones are removed when the app launches, and a file stops growing past 20 MB.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("External terminal").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        Picker("", selection: $model.settings.terminalApp) {
                            ForEach(TerminalApp.allCases) { app in
                                Text(app.rawValue).tag(app)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Spacer()
                    }

                    HStack {
                        Button("Open logs folder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.logs.path)
                        }
                        Button("Clear old logs") { clearLogs() }
                        Spacer()
                    }
                }

                Card("Ports", systemImage: "point.3.connected.trianglepath.dotted") {
                    Toggle("Auto refresh the list", isOn: $model.settings.portsAutoRefresh)
                    HStack {
                        Text("Interval").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        Slider(value: $model.settings.portsRefreshInterval, in: 2...60, step: 1)
                            .frame(width: 200)
                            .disabled(!model.settings.portsAutoRefresh)
                        Text("\(Int(model.settings.portsRefreshInterval)) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Show UDP", isOn: $model.settings.portsIncludeUDP)
                    Toggle("Show system processes", isOn: $model.settings.portsShowSystemProcesses)
                    Toggle("Confirm before terminating a process", isOn: $model.settings.confirmBeforeKill)

                    HStack {
                        Text("Default signal").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        Picker("", selection: $model.settings.defaultKillSignal) {
                            ForEach(KillSignal.allCases) { signal in
                                Text(signal.title).tag(signal)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        Spacer()
                    }

                    Divider()

                    Toggle("Enable port reservations (experimental)",
                           isOn: $model.settings.portReservationsEnabled)
                    Text("The app holds the port with its own socket. It helps to claim a port for a project, but the reservation lives only while the app runs and blocks starting a server on that same port.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card("Environment", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    Text("Extra directories to look for executables. They are prepended to PATH.")
                        .font(.caption).foregroundStyle(.secondary)

                    ForEach(Array(model.settings.extraPATHEntries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text(entry)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                model.settings.extraPATHEntries.remove(at: index)
                                model.saveSettings()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("/opt/homebrew/bin", text: $newPathEntry)
                            .font(.system(.callout, design: .monospaced))
                        Button("Add") {
                            let value = newPathEntry.trimmingCharacters(in: .whitespaces)
                            guard !value.isEmpty else { return }
                            model.settings.extraPATHEntries.append(value)
                            newPathEntry = ""
                            model.saveSettings()
                        }
                        Button("Choose…") { choosePath() }
                    }

                    Toggle("Check dependencies when the app launches",
                           isOn: $model.settings.checkDependenciesOnLaunch)
                }

                Card("Database admin panel", systemImage: "tablecells.badge.ellipsis") {
                    Picker("Panel", selection: $model.settings.databaseAdminTool) {
                        ForEach(DatabaseAdminTool.allCases) { tool in
                            Text(tool.title).tag(tool)
                        }
                    }
                    Text(model.settings.databaseAdminTool.subtitle)
                        .font(.caption).foregroundStyle(.secondary)

                    if model.settings.databaseAdminTool == .phpMyAdmin
                        && DatabaseAdminPanel.phpMyAdminDirectory() == nil {
                        Text("phpMyAdmin is not installed yet. Install it: brew install phpmyadmin")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("Port")
                        TextField("", value: $model.settings.databaseAdminPort,
                                  format: .number.grouping(.never))
                            .frame(width: 90)
                    }
                    Text("A port of its own, so it never collides with a profile. Reachable from this Mac only.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card("Certificates", systemImage: "lock") {
                    HStack {
                        Text("Default validity").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        TextField("", value: $model.settings.certificateDefaultDays,
                                  format: .number.grouping(.never))
                            .frame(width: 90)
                        Text("days").foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack {
                        Text("Default domains").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        TextField("localhost,127.0.0.1", text: $model.settings.certificateDefaultDomains)
                            .font(.system(.callout, design: .monospaced))
                    }
                }

                Card("Interface language", systemImage: "globe") {
                    Picker("Language", selection: $model.settings.language) {
                        Text("Match the system").tag(AppLanguage.systemCode)
                        ForEach(AppLanguage.available) { entry in
                            Text(entry.nativeName).tag(entry.code)
                        }
                    }
                    .onChange(of: model.settings.language) { _, value in
                        AppLanguage.apply(value)
                        model.notify("The language will apply after the app restarts.")
                    }
                    Text(model.settings.language.isEmpty
                         ? String(localized: "Currently using \(AppLanguage.effective?.nativeName ?? "—"). The app follows the system language.")
                         : String(localized: "The language change takes effect after restarting the app."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card("Updates", systemImage: "arrow.down.circle") {
                    HStack {
                        Text("Repository").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        TextField("owner/repo or a GitHub link",
                                  text: $model.settings.updateRepository)
                            .font(.system(.callout, design: .monospaced))
                    }
                    HStack {
                        Text("Version file").frame(minWidth: 130, idealWidth: 190, maxWidth: 210, alignment: .leading)
                        TextField("updates/maclastversion.txt", text: $model.settings.updateVersionFile)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 160)
                        Text("Builds folder").frame(minWidth: 80, idealWidth: 110, alignment: .trailing)
                        TextField("mac", text: $model.settings.updateBuildsFolder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 90)
                        Spacer()
                    }

                    if model.updates.isConfigured {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The app reads the version number from a file in the repository root and, if it is higher than the installed one, gives you a link to the build folder. Nothing is downloaded or run automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.updates.versionFileURL)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Text("The build is expected in \(model.updates.buildsFolder)/<version>. We look in the main and master branches.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Enter the repository as owner/repo — for example adm1nsys/ServerMaster.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Check for updates on launch", isOn: $model.settings.checkUpdatesOnLaunch)
                        .disabled(!model.updates.isConfigured)

                    HStack(spacing: 10) {
                        Button("Check now") {
                            Task {
                                await model.updates.check()
                                model.settings.lastUpdateCheck = Date()
                            }
                        }
                        .disabled(!model.updates.isConfigured || model.updates.state.isChecking)

                        if model.updates.isConfigured {
                            Button("Open repository") { model.updates.openRepository() }
                                .buttonStyle(.link)
                        }
                        if model.updates.state.isChecking { ProgressView().controlSize(.small) }
                        Spacer()
                    }

                    updateStatusRow
                }

                Card("About", systemImage: "info.circle") {
                    HStack(alignment: .top, spacing: 16) {
                        LogoView(size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppInfo.name).font(.title3).fontWeight(.semibold)
                            Text(AppInfo.versionLine)
                                .font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(AppInfo.bundleIdentifier)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text("\(AppInfo.systemVersion) · \(AppInfo.architecture)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let built = AppInfo.buildIdentifier.summary {
                                Text("Built against \(built)")
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button("Copy details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                """
                                \(AppInfo.name) \(AppInfo.versionLine)
                                \(AppInfo.bundleIdentifier)
                                \(AppInfo.systemVersion) · \(AppInfo.architecture)
                                \(AppInfo.buildIdentifier.summary ?? "")
                                """, forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }

                Card("Data", systemImage: "externaldrive") {
                    HStack {
                        Text(AppPaths.abbreviate(AppPaths.support.path))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Show in Finder") { model.revealSupportFolder() }
                    }
                    HStack {
                        Button("Reset settings") { confirmReset = true }
                        Spacer()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: model.settings) { _, _ in
            model.saveSettings()
        }
        .confirmationDialog("Reset all app settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetSettings() }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch model.updates.state {
        case .notConfigured:
            EmptyView()
        case .idle:
            Text("No check has run yet.")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            EmptyView()
        case .upToDate(let date):
            Label("You have the latest version (checked \(date.formatted(date: .omitted, time: .shortened))).",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                Label("Version \(release.version) is available", systemImage: "sparkles")
                    .font(.callout).fontWeight(.medium)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                Text("Installed \(AppInfo.version), repository has \(release.version) (branch \(release.branch)).")
                    .font(.caption).foregroundStyle(.secondary)
                if !release.buildFolderExists {
                    Label("Folder \(model.updates.buildsFolder)/\(release.version) not found — the repository root will open instead.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(release.buildFolderExists ? "Open the build folder" : "Open repository") {
                    model.updates.openReleasePage()
                }
                .buttonStyle(.link)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.extraPATHEntries.append(url.path)
        model.saveSettings()
    }

    private func clearLogs() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: AppPaths.logs,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var removed = 0
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let inUse = model.servers.values.contains { $0.log.fileURL == file }
            if let date, date < cutoff, !inUse {
                try? manager.removeItem(at: file)
                removed += 1
            }
        }
        model.notify(removed == 0 ? "No old logs found." : "Files removed: \(removed).")
    }
}
