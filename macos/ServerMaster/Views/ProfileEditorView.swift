//
//  ProfileEditorView.swift
//  ServerMaster
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfileEditorView: View {

    @Environment(AppModel.self) private var model

    @State private var draft: ServerProfile
    @State private var showCertificates = false
    @State private var editingFile: ConfigFile?
    @State private var permissions: PermissionReport?
    @State private var checkingPermissions = false
    @State private var fixingPermissions = false

    init(profile: ServerProfile) {
        _draft = State(initialValue: profile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                generalSection
                if draft.engine.usesRootDirectory { directoriesSection }
                if draft.engine == .nodeScript { nodeSection }
                if draft.engine == .custom { customSection }
                if draft.engine.usesConfigFile { configSection }
                configFilesSection
                if draft.engine.supportsHTTPS { httpsSection }
                if draft.engine.usesRootDirectory { permissionsSection }
                if draft.engine.runsPHP { phpSection }
                if isStaticEngine { staticOptionsSection }
                securitySection
                errorPagesSection
                environmentSection
                notesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: draft) { _, newValue in
            model.updateProfile(newValue)
        }
        .sheet(isPresented: $showCertificates) {
            CertificatesSheet { pair in
                draft.certificatePath = pair.certificatePath
                draft.privateKeyPath = pair.privateKeyPath
                draft.httpsEnabled = true
            }
            .environment(model)
        }
        .sheet(item: $editingFile) { file in
            ConfigEditorSheet(file: file) { adoptedPath in
                draft.configPath = adoptedPath
            }
            .environment(model)
        }
    }

    private var isStaticEngine: Bool {
        [.httpServer, .nginx, .caddy].contains(draft.engine)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Button {
                        draft.iconName = ""
                    } label: {
                        Label("Same as the engine", systemImage: draft.engine.symbol)
                    }
                    ForEach(ProfileIcons.groups) { group in
                        Section(group.title) {
                            ForEach(group.symbols, id: \.self) { symbol in
                                Button {
                                    draft.iconName = symbol
                                } label: {
                                    Label(symbol, systemImage: symbol)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: draft.symbol)
                        .font(.title3)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Profile icon")

                TextField("Profile name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title2).fontWeight(.semibold)

                if model.settings.defaultProfileID == draft.id {
                    Label("Default", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                } else {
                    Button("Make default") { model.makeDefault(draft) }
                        .buttonStyle(.link)
                }

                Button {
                    Task { await model.startServer(profile: draft) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(model.isActive(draft.id))
            }

            let issues = draft.validationIssues
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Basics

    private var generalSection: some View {
        Card("General", systemImage: "gearshape") {
            Picker("Engine", selection: $draft.engine) {
                ForEach(ServerEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            HStack(spacing: 8) {
                Text(draft.engine.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // The guide follows the engine: picking Apache offers the
                // .htaccess page, a PHP engine offers the CMS walkthrough.
                Button("Guide") { AppLinks.open(AppLinks.guide(for: draft.engine)) }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if draft.engine.runsPHP {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.secondary)
                    Text("The PHP version is selected below, in the “PHP” section.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if draft.engine.usesRootDirectory {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                    Text("This engine serves files as they are and does not execute PHP. For a PHP site pick “PHP site (Nginx + PHP-FPM)” — the PHP version selector appears then.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }

            let missing = model.dependencies.missingTools(for: draft.engine)
            if !missing.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Not installed: \(missing.joined(separator: ", "))").font(.caption)
                    Button("Open dependencies") { model.section = .dependencies }
                        .buttonStyle(.link).font(.caption)
                }
            }

            Divider()

            HStack {
                TextField("Host", text: $draft.host)
                    .frame(maxWidth: 200)
                Picker("", selection: $draft.host) {
                    Text("127.0.0.1 (this Mac only)").tag("127.0.0.1")
                    Text("0.0.0.0 (reachable on the network)").tag("0.0.0.0")
                    Text("localhost").tag("localhost")
                }
                .labelsHidden()
                .frame(minWidth: 150, idealWidth: 220, maxWidth: 240)
                Spacer()
            }

            portRow

            Toggle("Open the browser after start", isOn: $draft.openBrowserOnStart)
        }
    }

    // MARK: - Port

    private var portRow: some View {
        let secure = draft.httpsEnabled && draft.engine.supportsHTTPS
        let presets = PortPresets.list(secure: secure)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Port").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)

                Menu {
                    Section(secure ? "Standard HTTPS ports" : "Standard ports") {
                        ForEach(presets) { preset in
                            Button {
                                draft.port = preset.port
                            } label: {
                                Text(PortScanner.isPortFree(preset.port, host: draft.host)
                                     ? preset.label
                                     : preset.label + "  (busy)")
                            }
                        }
                    }
                    Section(secure ? "Plain ports" : "HTTPS ports") {
                        ForEach(PortPresets.list(secure: !secure)) { preset in
                            Button(preset.label) { draft.port = preset.port }
                        }
                    }
                    Divider()
                    Button("Nearest free") { draft.port = firstFreePort(from: draft.port) }
                } label: {
                    Text(PortPresets.preset(for: draft.port)?.label ?? "Custom port")
                }
                .frame(minWidth: 140, idealWidth: 240, maxWidth: 280)

                TextField("", value: $draft.port, format: .number.grouping(.never))
                    .frame(minWidth: 60, idealWidth: 80, maxWidth: 100)

                portStatusBadge
                Spacer()
            }

            if let preset = PortPresets.preset(for: draft.port) {
                Text(preset.note)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 160)
            }

            if draft.port < 1024 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: draft.runAsAdministrator ? "lock.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(draft.runAsAdministrator ? Color.secondary : Color.orange)
                        Text(draft.runAsAdministrator
                             ? "Port \(String(draft.port)) will be opened as root."
                             : "Ports below 1024 are available to root only.")
                            .font(.caption)
                        if !draft.runAsAdministrator,
                           let replacement = PortPresets.localReplacement(for: draft.port) {
                            Button("Use \(String(replacement))") { draft.port = replacement }
                                .buttonStyle(.link).font(.caption)
                            Text("or")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("start as administrator") { draft.runAsAdministrator = true }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                .padding(.leading, 160)
            }

            Toggle("Start with administrator rights", isOn: $draft.runAsAdministrator)
                .padding(.leading, 160)
            if draft.runAsAdministrator {
                Text("macOS asks for the password once at start — the app never sees or stores it. Stopping and quitting need no password. Required for ports 80 and 443.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 180)
            }
        }
    }

    @ViewBuilder
    private var portStatusBadge: some View {
        let free = PortScanner.isPortFree(draft.port, host: draft.host)
        HStack(spacing: 4) {
            Circle().fill(free ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(free ? "free" : "busy")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !free {
            Button("Show who") { model.section = .ports }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func firstFreePort(from start: Int) -> Int {
        var candidate = max(1024, start)
        while candidate < 65535 {
            if PortScanner.isPortFree(candidate, host: draft.host) { return candidate }
            candidate += 1
        }
        return start
    }

    // MARK: - Directories

    private var directoriesSection: some View {
        Card("Directories", systemImage: "folder") {
            PathField(title: "Site root", path: $draft.rootPath, isDirectory: true)
            PathField(title: "Working directory", path: $draft.workingDirectory,
                      isDirectory: true, placeholder: "same as site root")
        }
    }

    // MARK: - Node

    private var nodeSection: some View {
        Card("Node.js", systemImage: "shippingbox") {
            PathField(title: "Entry file", path: $draft.nodeEntryFile, isDirectory: false,
                      placeholder: "server.js")
            Text("The port and host are passed to the process through the PORT and HOST variables.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Custom command

    private var customSection: some View {
        Card("Command", systemImage: "terminal") {
            TextField("Executable", text: $draft.customCommand,
                      prompt: Text("for example: bun or /usr/local/bin/myserver"))
            TextField("Arguments", text: $draft.customArguments,
                      prompt: Text("--port 8080 --dir ./public"))
                .font(.system(.body, design: .monospaced))
            PathField(title: "Working directory", path: $draft.workingDirectory, isDirectory: true,
                      placeholder: "home folder")
            Text("Arguments are parsed with quotes in mind. The PORT variable is available to the process.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Config

    private var configSection: some View {
        Card("\(draft.engine == .caddy ? "Caddy" : "nginx") configuration", systemImage: "doc.text") {
            PathField(title: "Config file", path: $draft.configPath, isDirectory: false,
                      placeholder: "generate automatically")

            HStack {
                if !draft.configPath.isEmpty {
                    Button("Reset to auto generation") { draft.configPath = "" }
                        .buttonStyle(.link)
                }
                Spacer()
            }

            Text(draft.configPath.isEmpty
                 ? "The config is generated from the profile settings on every start. You can open and edit it below — the app will offer to keep your changes as your own file."
                 : "Your own file is used — the static and security options above do not affect it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Profile files

    private var configFilesSection: some View {
        let files = ConfigInventory.files(for: draft, databaseLogPath: model.database.errorLogPath)
        let groups = ConfigFile.Kind.allCases.compactMap { kind -> (ConfigFile.Kind, [ConfigFile])? in
            let items = files.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }

        return Card("Configuration files", systemImage: "doc.on.doc") {
            if groups.isEmpty {
                Text("This engine has no separate config files — everything is set by the launch options above.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups, id: \.0) { kind, items in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(items) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.bottom, 4)
                }

                Divider()
                HStack {
                    Button("App folder") { model.revealSupportFolder() }
                        .buttonStyle(.link).font(.caption)
                    if draft.engine.usesRootDirectory {
                        Button("Site folder") {
                            NSWorkspace.shared.selectFile(nil,
                                inFileViewerRootedAtPath: AppPaths.expand(draft.rootPath))
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                }
            }
        }
    }

    private func fileRow(_ file: ConfigFile) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(file.exists ? Color.green.opacity(0.6) : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.title)
                        .font(.callout)
                    if file.isGenerated {
                        Text("generated").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !file.exists {
                        Text("no file").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !file.note.isEmpty {
                    Text(file.note)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if file.exists {
                Text(file.sizeText).font(.caption2).foregroundStyle(.tertiary)
            }

            Button(file.isReadOnly ? "View" : "Open") { editingFile = file }
                .buttonStyle(.link)
                .disabled(!file.exists && !file.isGenerated)

            Button {
                if file.exists {
                    NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(!file.exists)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    // MARK: - HTTPS

    private var httpsSection: some View {
        Card("HTTPS", systemImage: "lock") {
            Toggle("Enable HTTPS", isOn: $draft.httpsEnabled)

            if draft.httpsEnabled {
                PathField(title: "Certificate", path: $draft.certificatePath, isDirectory: false,
                          placeholder: "cert.pem")
                PathField(title: "Private key", path: $draft.privateKeyPath, isDirectory: false,
                          placeholder: "key.pem")

                HStack {
                    Button {
                        showCertificates = true
                    } label: {
                        Label("Certificates…", systemImage: "seal")
                    }
                    Spacer()
                }

                Text("The browser will mark a self-signed certificate as unsafe until you add it to the system keychain — do that in the certificates window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Static options

    private var staticOptionsSection: some View {
        Card("Serving files", systemImage: "square.grid.3x3") {
            if draft.engine != .httpServer {
                HStack {
                    Text("Index file").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                    TextField("index.html", text: $draft.indexFile).frame(minWidth: 110, idealWidth: 200, maxWidth: 220)
                    Spacer()
                }
            }
            Toggle("Directory listing", isOn: $draft.directoryListing)
            Toggle("Gzip compression", isOn: $draft.enableGzip)
            Toggle("CORS (Access-Control-Allow-Origin: *)", isOn: $draft.enableCORS)
            Toggle("SPA: serve the index file for every 404", isOn: $draft.spaFallback)

            Divider()

            HStack {
                Text("Cache").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                Picker("", selection: Binding(
                    get: { draft.cacheSeconds >= 0 },
                    set: { draft.cacheSeconds = $0 ? 3600 : -1 }
                )) {
                    Text("Disabled").tag(false)
                    Text("Set duration").tag(true)
                }
                .labelsHidden()
                .frame(minWidth: 110, idealWidth: 150, maxWidth: 170)

                if draft.cacheSeconds >= 0 {
                    TextField("seconds", value: $draft.cacheSeconds, format: .number.grouping(.never))
                        .frame(minWidth: 66, idealWidth: 90, maxWidth: 110)
                    Text("s").foregroundStyle(.secondary)
                }
                Spacer()
            }


            Divider()

            HStack(alignment: .top) {
                Text("Extra arguments").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                TextField("", text: $draft.extraArguments, prompt: Text("--silent --robots"))
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - File permissions

    private var permissionsSection: some View {
        Card("File permissions", systemImage: "lock.doc") {
            Text("A CMS must be able to write to its own folders — cache, logs, uploads. Without those rights the site fails with no clear explanation.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Check") { checkPermissions() }
                    .disabled(checkingPermissions || fixingPermissions)
                if checkingPermissions || fixingPermissions {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let report = permissions {
                if report.isClean {
                    Label(report.truncated
                          ? "No problems among the first \(report.checkedCount) files."
                          : "Permissions are fine: \(report.checkedCount) files checked.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Problems: \(report.problems.count) of \(report.checkedCount) checked",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)

                        ForEach(report.problems.prefix(6)) { problem in
                            HStack(spacing: 6) {
                                Image(systemName: problem.isDirectory ? "folder" : "doc")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(shortPath(problem.path))
                                    .font(.system(.caption2, design: .monospaced))
                                    .lineLimit(1).truncationMode(.head)
                                Text("— \(problem.kind.title)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if problem.kind == .foreignOwner {
                                    Text("(\(problem.owner))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                        }
                        if report.problems.count > 6 {
                            Text("…and \(report.problems.count - 6) more")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Button("Fix permissions") { fixPermissions(asAdmin: false) }
                                .disabled(fixingPermissions)
                            if report.needsAdmin {
                                Button("Take ownership…") { fixPermissions(asAdmin: true) }
                                    .disabled(fixingPermissions)
                            }
                            Spacer()
                        }

                        if report.needsAdmin {
                            Text("Some files belong to another user — a common result of unpacking an archive as root. Taking ownership asks for a password.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        let root = AppPaths.expand(draft.rootPath)
        if path.hasPrefix(root) {
            let tail = String(path.dropFirst(root.count))
            return tail.isEmpty ? "." : String(tail.dropFirst())
        }
        return AppPaths.abbreviate(path)
    }

    private func checkPermissions() {
        checkingPermissions = true
        let root = draft.rootPath
        Task {
            let report = await Task.detached { SitePermissions.check(root: root) }.value
            permissions = report
            checkingPermissions = false
        }
    }

    private func fixPermissions(asAdmin: Bool) {
        fixingPermissions = true
        let root = draft.rootPath
        Task {
            let result = asAdmin
                ? await SitePermissions.takeOwnership(root: root)
                : await SitePermissions.fix(root: root)
            if result.succeeded {
                let report = await Task.detached { SitePermissions.check(root: root) }.value
                permissions = report
                model.notify(report.isClean
                             ? String(localized: "Permissions fixed.")
                             : String(localized: "Some problems remain — check the list."))
            } else {
                model.notify(result.combined, isError: true)
            }
            fixingPermissions = false
        }
    }

    // MARK: - PHP

    private var phpSection: some View {
        Card("PHP", systemImage: "curlybraces") {
            let missing = model.dependencies.missingPHPExtensions
            if !missing.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Missing PHP extensions: \(missing.joined(separator: ", "))")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("A typical CMS will not install without them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !model.dependencies.phpExtensions.isEmpty {
                Label("All CMS extensions are present", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            let installed = model.dependencies.phpVersions
            HStack {
                Text("PHP version").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                Picker("", selection: $draft.phpVersion) {
                    Text(installed.first(where: \.isDefault).map {
                        String(localized: "Match the system (PHP \($0.version))")
                    } ?? String(localized: "Match the system")).tag("")
                    ForEach(PHPVersions.known, id: \.self) { version in
                        let have = installed.contains { $0.version == version }
                        Text(have ? "PHP \(version)" : "PHP \(version) — not installed").tag(version)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 140, idealWidth: 210, maxWidth: 240)
                Spacer()
            }

            if !installed.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Text("Installed: \(installed.map(\.version).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 160)
            }

            if !draft.phpVersion.isEmpty,
               !installed.contains(where: { $0.version == draft.phpVersion }) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("PHP \(draft.phpVersion) is not installed — this profile will not start.")
                        .font(.caption)
                    Button("Install") {
                        model.section = .dependencies
                        model.notify(String(localized: "Run: brew install php@\(draft.phpVersion)"))
                    }
                    .buttonStyle(.link).font(.caption)
                    Spacer()
                }
                .padding(.leading, 160)
            }

            Divider()

            HStack {
                Text("Memory limit").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                TextField("256M", text: $draft.phpMemoryLimit)
                    .font(.system(.callout, design: .monospaced)).frame(minWidth: 66, idealWidth: 90, maxWidth: 110)
                Text("File uploads").frame(minWidth: 90, idealWidth: 130, alignment: .trailing)
                TextField("64M", text: $draft.phpUploadMaxFilesize)
                    .font(.system(.callout, design: .monospaced)).frame(minWidth: 66, idealWidth: 90, maxWidth: 110)
                Spacer()
            }
            HStack {
                Text("Execution time").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                TextField("300", value: $draft.phpMaxExecutionTime, format: .number.grouping(.never))
                    .frame(minWidth: 66, idealWidth: 90, maxWidth: 110)
                Text("s").foregroundStyle(.secondary)
                Spacer()
            }
            Toggle("Show PHP errors in the browser", isOn: $draft.phpDisplayErrors)
            Text("Handy on a local setup: an error shows up immediately instead of vanishing silently. The same output also goes to the app console.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.engine.typicallyNeedsDatabase {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: model.database.state == .running ? "checkmark.circle.fill" : "cylinder")
                        .foregroundStyle(model.database.state == .running ? Color.green : Color.secondary)
                    Text(model.database.state == .running
                         ? "Database is running: \(model.database.connectionSummary)"
                         : "The database is not running — it starts automatically with the profile.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open") { model.section = .database }
                        .buttonStyle(.link).font(.caption)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Protection

    private var securitySection: some View {
        Card("Protection", systemImage: "shield") {
            Text("A local server is usually visible only to this Mac, so protection is not critical. It matters once you open access to the network or show the setup to colleagues.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.host == "0.0.0.0" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    Text("The address is set to 0.0.0.0 — anyone on the same Wi-Fi network can reach the server.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("This Mac only") { draft.host = "127.0.0.1" }
                        .buttonStyle(.link).font(.caption)
                }
            }

            Divider()

            Toggle("Block dotfiles (.env, .git and similar)", isOn: $draft.hideDotfiles)
            if draft.hideDotfiles && !draft.engine.blocksDotfileAccess {
                Text(draft.engine.hidesDotfilesFromListing
                     ? "\(draft.engine.title) will only hide them from the directory listing — a direct request to /.env still returns the contents. Nginx and Caddy block access completely."
                     : "\(draft.engine.title) cannot block access to such files.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Toggle("Security response headers", isOn: $draft.securityHeaders)
                .disabled(!draft.engine.supportsCustomHeaders)
            if draft.securityHeaders && draft.engine.supportsCustomHeaders {
                Text("X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy — the same ones a real server sets.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if !draft.engine.supportsCustomHeaders {
                Text("\(draft.engine.title) cannot set custom headers. Available in Nginx and Caddy.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Toggle("HSTS — HTTPS only", isOn: $draft.hstsEnabled)
                .disabled(!draft.engine.supportsCustomHeaders || !draft.httpsEnabled)
            if draft.hstsEnabled {
                Text("The browser will remember this host as HTTPS-only. On localhost that can make it hard to go back to HTTP later.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            if isStaticEngine {
                Divider()
                Toggle("Basic authentication (login and password)", isOn: $draft.basicAuthEnabled)
                if draft.basicAuthEnabled {
                    HStack {
                        TextField("Login", text: $draft.basicAuthUser).frame(minWidth: 110, idealWidth: 180, maxWidth: 200)
                        SecureField("Password", text: $draft.basicAuthPassword).frame(minWidth: 110, idealWidth: 180, maxWidth: 200)
                        Spacer()
                    }
                    .padding(.leading, 20)
                    Text("The password is stored in profiles.json as plain text — do not use production passwords.")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: - Error pages

    private var errorPagesSection: some View {
        Card("Error pages", systemImage: "exclamationmark.bubble") {
            Toggle("Custom pages for every error code", isOn: $draft.customErrorPages)
                .disabled(!draft.engine.supportsErrorPages)

            if !draft.engine.supportsErrorPages {
                Text("\(draft.engine.title) serves only its built-in pages. Nginx and Caddy can show custom ones — switch the engine if you want a setup close to a real server.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.customErrorPages {
                Text("Ready-made pages for \(ErrorPages.codes.count) codes: 404, 403, 500, 502, 503 and the rest. They follow the dark theme and are regenerated on every start.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Accent color").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                    TextField("#3B82F6", text: $draft.errorPageAccent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minWidth: 80, idealWidth: 110, maxWidth: 130)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: ErrorPages.sanitizeColor(draft.errorPageAccent)))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Spacer()
                }
                HStack {
                    Text("Footer text").frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
                    TextField(draft.name, text: $draft.errorPageFooter)
                    Spacer()
                }

                HStack {
                    Button("Preview 404") { previewErrorPage(code: 404) }
                    Button("Preview 500") { previewErrorPage(code: 500) }
                    Spacer()
                }
            }
        }
    }

    private func previewErrorPage(code: Int) {
        guard let item = ErrorPages.codes.first(where: { $0.code == code }) else { return }
        let html = ErrorPages.page(for: item, profile: draft)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-preview-\(String(code)).html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Environment variables

    private var environmentSection: some View {
        Card("Environment variables", systemImage: "list.bullet.rectangle") {
            ForEach($draft.environment) { $item in
                HStack(spacing: 8) {
                    TextField("KEY", text: $item.key)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 110, idealWidth: 180, maxWidth: 200)
                    TextField("value", text: $item.value)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        draft.environment.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button {
                    draft.environment.append(EnvVar())
                } label: {
                    Label("Add variable", systemImage: "plus")
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
    }

    private var notesSection: some View {
        Card("Notes", systemImage: "note.text") {
            TextEditor(text: $draft.notes)
                .font(.callout)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }
}

// MARK: - Helper views

/// A card section with a heading.
struct Card<Content: View>: View {
    // LocalizedStringKey, not String: Label(String, systemImage:) does not go
    // through localization, and the section headings stayed in the source language.
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// A path field with a button that opens the system panel.
struct PathField: View {
    let title: LocalizedStringKey
    @Binding var path: String
    var isDirectory: Bool
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(minWidth: 110, idealWidth: 150, maxWidth: 170, alignment: .leading)
            TextField("", text: $path, prompt: Text(placeholder))
                .font(.system(.callout, design: .monospaced))
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = isDirectory
        panel.canChooseFiles = !isDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = isDirectory
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expand(path)).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}

// MARK: - Colour from HEX

extension Color {
    /// HEX of the form #RGB or #RRGGBB. An invalid string gives grey.
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let expanded = raw.count == 3 ? raw.map { "\($0)\($0)" }.joined() : raw
        guard expanded.count == 6, let value = UInt32(expanded, radix: 16) else {
            self = .gray
            return
        }
        self = Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
