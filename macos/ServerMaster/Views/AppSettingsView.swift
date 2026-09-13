//
//  AppSettingsView.swift
//  ServerMaster
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppSettingsView: View {

    /// Bumped when a gate is toggled, so the sidebar and cards redraw at once.
    @State private var pendingRefresh = 0

    @Environment(AppModel.self) private var model
    @State private var newPathEntry = ""
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                ScreenTitle(title: "App settings",
                              subtitle: "Defaults, console, ports and environment")

                Card("Appearance", systemImage: "paintpalette") {
                    Toggle("Moving background", isOn: $model.settings.backgroundEnabled)
                        .onChange(of: model.settings.backgroundEnabled) { model.saveSettings() }
                    Text("A mesh of colour behind every screen. It takes its colour from the servers that are running, so the window says what is happening before you have read a word.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text("Colour").frame(width: 110, alignment: .leading)
                        // The hue as a strip of the colour itself. A number from
                        // 0 to 1 means nothing to anyone; the swatch does.
                        LinearGradient(colors: (0...12).map {
                            Color(hue: Double($0) / 12, saturation: 0.55, brightness: 0.55)
                        }, startPoint: .leading, endPoint: .trailing)
                            .frame(height: 10)
                            .clipShape(Capsule())
                        Slider(value: $model.settings.backgroundHue, in: 0...1)
                            .frame(width: 200)
                            .onChange(of: model.settings.backgroundHue) { model.saveSettings() }
                        Circle()
                            .fill(Color(hue: model.settings.backgroundHue,
                                        saturation: 0.6, brightness: 0.6))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.quaternary))
                    }
                    .disabled(!model.settings.backgroundEnabled)

                    HStack {
                        Text("Speed").frame(width: 110, alignment: .leading)
                        Slider(value: $model.settings.backgroundSpeed, in: 0...8) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("still").font(.caption2).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("fast").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 260)
                        .onChange(of: model.settings.backgroundSpeed) { model.saveSettings() }
                        // A fixed box. Without it the label is as wide as
                        // whatever it currently says — "held still" and "×1.0"
                        // are different widths — so dragging the slider resized
                        // the row and everything under it jumped.
                        Text(model.settings.backgroundSpeed == 0
                             ? "held still"
                             : String(format: "×%.1f", model.settings.backgroundSpeed))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 78, alignment: .leading)
                    }
                    .disabled(!model.settings.backgroundEnabled)

                    HStack {
                        Text("Colour amount").frame(width: 110, alignment: .leading)
                        Slider(value: $model.settings.backgroundSaturation, in: 0...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("grey").font(.caption2).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("full").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 260)
                        .onChange(of: model.settings.backgroundSaturation) { model.saveSettings() }
                        Text(model.settings.backgroundSaturation == 0
                             ? "black and white"
                             : String(format: "%.0f%%", model.settings.backgroundSaturation * 100))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 96, alignment: .leading)
                    }
                    .disabled(!model.settings.backgroundEnabled)

                    Toggle("Take the colour from running servers", isOn: $model.settings.backgroundFollowsServers)
                        .onChange(of: model.settings.backgroundFollowsServers) { model.saveSettings() }
                        .disabled(!model.settings.backgroundEnabled)
                    Text("With this on, starting a server repaints the background with that profile's accent colour, and the colour chosen above applies only while nothing is running.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Text("Sidebar").frame(width: 110, alignment: .leading)
                        Picker("", selection: $model.settings.sidebarStyle) {
                            ForEach(SidebarStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: model.settings.sidebarStyle) { model.saveSettings() }
                        Spacer()
                    }

                }

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

                if Features.isOn(.commandLineTool) {
                Card("Command line", systemImage: "terminal") {
                    Text("A servermaster command for scripts, Makefiles and AI agents. Every command can print JSON, and the exit codes say what went wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch model.commandLineTool.state {
                    case .working:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.caption).foregroundStyle(.secondary)
                        }

                    case .installed(let path):
                        HStack(spacing: 10) {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { Task { await model.commandLineTool.uninstall() } }
                                .modifier(ChipStyle())
                        }
                        Text("Try: servermaster list --json")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)

                    case .pointsElsewhere(let destination):
                        // Two copies of the app, or one moved: silently
                        // overwriting someone else's link would be rude.
                        VStack(alignment: .leading, spacing: 6) {
                            Label("A servermaster command is already installed, pointing somewhere else.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(destination)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("Point it at this copy") { Task { await model.commandLineTool.install() } }
                        }

                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try again") { Task { await model.commandLineTool.install() } }
                        }

                    case .notInstalled:
                        HStack(spacing: 10) {
                            Button {
                                Task { await model.commandLineTool.install() }
                            } label: {
                                Label("Install the command", systemImage: "arrow.down.to.line")
                            }
                            .disabled(!model.commandLineTool.isAvailable)
                            Text("Puts a link in /usr/local/bin. Asks for your password once.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.commandLineTool.isAvailable {
                            Text("This build does not carry the tool yet.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }

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

                Card("Developer mode", systemImage: "hammer") {
                    Toggle(isOn: Binding(
                        get: { Features.developerMode },
                        set: {
                            Features.developerMode = $0
                            model.featuresChanged()
                            pendingRefresh += 1
                        }
                    )) {
                        Text("Show beta features")
                    }
                    Text("Beta features are finished but not released yet, and they may be unstable. Each one goes out in its own version so a problem in one does not arrive alongside four others. Switch this off and the app is exactly what everyone else has.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if Features.developerMode {
                        Label("Beta features are on. Anything unusual here is worth reporting rather than working around.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if Features.developerMode, !Features.pending.isEmpty {
                    Card("Beta features", systemImage: "hourglass") {
                        Text("Finished and waiting for the version it is tied to. Switch one on to use it now — a feature that sits behind a gate untouched is not seasoned, only late.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(Features.pending) { feature in
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(isOn: Binding(
                                    get: { Features.isOn(feature) },
                                    set: {
                                        Features.setOverride(feature, on: $0)
                                        model.featuresChanged()
                                        pendingRefresh += 1
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(feature.title)
                                        Text("from \(feature.availableFrom)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(feature.settlingNote)
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }

                        Text("Switching one on changes this Mac only — it never reaches anyone else.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .id(pendingRefresh)
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

                    Label("The command line tool is English only. Its output is read by scripts as often as by people, and a translated message is one a script cannot match on.",
                          systemImage: "apple.terminal")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    // Packs: taken out, edited, put back.
                    if let stale = model.translations.mismatched {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("An imported translation was made for ServerMaster \(stale.appVersion), and this is \(AppInfo.version).")
                                    .fontWeight(.medium)
                                Text("Strings added since then show in English, and any that changed meaning may read wrong. Export a fresh pack and move your wording into it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(Array(model.translations.installed.values), id: \.language) { pack in
                        HStack {
                            Image(systemName: pack.matchesApp ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(pack.matchesApp ? Color.green : Color.orange)
                            Text(AppLanguage.title(for: pack.language))
                            Text(pack.summary)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { model.translations.remove(language: pack.language) }
                                .modifier(ChipStyle())
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Export translation…") { exportTranslation() }
                            .modifier(ChipStyle())
                        Button("Import translation…") { importTranslation() }
                            .modifier(ChipStyle())
                        Spacer()
                    }

                    Text("An exported pack is a plain text file: one line per string, the English key on the left and the translation on the right. Edit it in any editor and import it back — an imported pack takes precedence over the built-in one, and anything left out falls back to it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card("Updates", systemImage: "arrow.down.circle") {
                    HStack(spacing: 8) {
                        // Drawn but not wired up, and disabled so it cannot be
                        // switched on. Shown rather than hidden because the shape
                        // of this card is settled now — a row that appears later
                        // moves everything under it.
                        Toggle("Update automatically", isOn: .constant(false))
                            .disabled(true)
                        Text("SOON")
                            .font(.caption2).fontWeight(.semibold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("For now the app only tells you a new version exists and gives you the link. Downloading and replacing itself is not written yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

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
                                .modifier(ChipStyle())
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
                        .modifier(ChipStyle())
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
            .padding(36)
//.frame(maxWidth: 820, alignment: .leading)
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
                .modifier(ChipStyle())
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

    // MARK: - Translation packs

    /// Writes out every key the app knows, with the current translation, so the
    /// file is a starting point rather than an empty form.
    private func exportTranslation() {
        let code = AppLanguage.effective?.code ?? "en"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(code).strings"
        panel.allowedContentTypes = [.plainText]
        panel.message = String(localized: "Save the translation for editing")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if TranslationStore.export(language: code, to: url) {
            model.notify(String(localized: "Translation exported to \(url.lastPathComponent)."))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            model.notify(String(localized: "The translation could not be written."), isError: true)
        }
    }

    private func importTranslation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose an exported translation file")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch model.translations.importPack(from: url) {
        case .installed(let pack):
            TranslationOverride.shared.refresh()
            model.notify(pack.matchesApp
                         ? String(localized: "Translation imported. Restart the app to see it.")
                         : String(localized: "Imported, but it was made for ServerMaster \(pack.appVersion) — some strings will stay in English."),
                         isError: !pack.matchesApp)
        case .notAStringsFile:
            model.notify(String(localized: "That file is not a translation the app can read."), isError: true)
        case .couldNotSave(let message):
            model.notify(message, isError: true)
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

}
