//
//  NewProfileSheet.swift
//  ServerMaster
//
//  The path from “I need to run this” to a working profile: pick what it is,
//  then answer only the questions that thing actually needs. Everything else the
//  template already knows.
//
//  This is the simple interface. The full editor is still there for anyone who
//  wants it — the difference is that nobody has to start there.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NewProfileSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Stage: Equatable {
        case gallery
        case questions(ProfileTemplate)
        case created(UUID)
    }

    @State private var stage: Stage = .gallery
    @State private var search = ""

    // Answers
    @State private var folder = ""
    @State private var name = ""
    @State private var port = 8080
    @State private var phpVersion = ""
    @State private var createDatabase = true
    @State private var databaseName = ""
    @State private var databasePassword = ""
    @State private var showDatabasePassword = false
    @State private var preparation = NewProfilePreparation()
    @State private var httpsEnabled = false
    @State private var command = ""
    @State private var entryFile = "server.js"
    @State private var step = 0
    @State private var problem: String?
    @State private var downloader = ProjectDownloader()
    @State private var clock = WaitingClock()
    @State private var preparingProfile = false

    /// The first-run assistant already knows the kind of site the person
    /// picked. Opening the normal wizard at that template preserves one shared
    /// flow instead of maintaining a second, subtly different creation path.
    private let initialTemplateID: String?
    private let onCancel: (() -> Void)?

    init(initialTemplateID: String? = nil, onCancel: (() -> Void)? = nil) {
        self.initialTemplateID = initialTemplateID
        self.onCancel = onCancel
    }

    private var store: TemplateStore { model.templates }

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .gallery:                 gallery
            case .questions(let template): questions(for: template)
            case .created(let id):         completion(for: id)
            }
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(preparingProfile || preparation.isStarting || isDownloading)
        .onDisappear {
            if case .created = stage, model.needsFirstSetup { model.completeFirstSetup() }
        }
        .onAppear {
            guard stage == .gallery,
                  let initialTemplateID,
                  let template = store.all.first(where: { $0.id == initialTemplateID })
            else { return }
            begin(template)
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        // Ties the gated buttons below to the developer-mode switch.
        let _ = model.featureRevision
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What are you running?").font(.title2).fontWeight(.semibold)
                    Text("Pick the closest match — everything can be changed afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    if let onCancel { onCancel() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.loadFailed {
                        Label("Your saved templates could not be read. The built-in ones still work.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    ForEach(visibleCategories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(category.title, systemImage: category.symbol)
                                .font(.caption).foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 10)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(matches(in: category)) { template in
                                    card(template)
                                }
                            }
                        }
                    }

                    if visibleCategories.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(height: 200)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 10) {
                if Features.isOn(.templateSharing) {
                Button {
                    importTemplates()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .help("Add templates from a file someone sent you")

                Menu {
                    ForEach(store.all) { template in
                        Button(template.title) { export([template]) }
                    }
                    if !store.userTemplates.isEmpty {
                        Divider()
                        Button("All of my templates") { export(store.userTemplates) }
                    }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .frame(width: 130)
                .help("Save a template to a file")
                }

                Spacer()
                Button("Empty profile") { createEmpty() }
            }
            .padding(12)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search templates")
    }

    private var visibleCategories: [TemplateCategory] {
        store.categories.filter { !matches(in: $0).isEmpty }
    }

    private func matches(in category: TemplateCategory) -> [ProfileTemplate] {
        let list = store.templates(in: category)
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return list }
        let needle = search.lowercased()
        return list.filter {
            $0.title.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
        }
    }

    private func card(_ template: ProfileTemplate) -> some View {
        Button {
            begin(template)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: template.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(template.title).fontWeight(.medium)
                        if template.isUserDefined {
                            Image(systemName: "person.crop.circle")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(template.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open the guide") { AppLinks.open(template.guide) }
            if Features.isOn(.templateSharing) { Button("Export…") { export([template]) } }
            if template.isUserDefined {
                Divider()
                Button("Delete template", role: .destructive) {
                    do { try store.remove(template) }
                    catch { model.notify(error.localizedDescription, isError: true) }
                }
            }
        }
    }

    // MARK: - Questions

    private func questions(for template: ProfileTemplate) -> some View {
        let filtered = template.setupQuestions.filter { shouldAsk($0, in: template) }
        let asked: [TemplateQuestion] = filtered.isEmpty ? [.folder] : filtered
        let current = asked.indices.contains(step) ? asked[step] : .folder

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: template.symbol).font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.title).fontWeight(.semibold)
                    Text("Step \(String(step + 1)) of \(String(asked.count))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    AppLinks.open(template.guide)
                } label: {
                    Label("Guide", systemImage: "book")
                }
                .buttonStyle(.link)
            }
            .padding(16)

            ProgressView(value: Double(step + 1), total: Double(max(asked.count, 1)))
                .progressViewStyle(.linear)
                .padding(.horizontal, 16)

            Divider().padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ProfileRequirementsView(profile: draftProfile(from: template), template: template)
                        .disabled(preparingProfile || isDownloading)
                    questionBody(current, template: template)
                        .disabled(preparingProfile)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Back") {
                    problem = nil
                    if step == 0 { stage = .gallery } else { step -= 1 }
                }
                .disabled(isDownloading || preparingProfile)
                Spacer()
                Button(step == asked.count - 1 ? "Create" : "Next") {
                    advance(asked: asked, template: template)
                }
                .keyboardShortcut(.defaultAction)
                // Moving on mid-download leaves a half-unpacked folder behind
                // and a profile pointed at it, which looks exactly like a broken
                // download and is much harder to explain.
                .disabled(!isAnswered(current, template: template) || isDownloading || preparingProfile || model.dependencies.isManagingPackages)
                if preparingProfile { ProgressView().controlSize(.small) }
            }
            .padding(12)
        }
    }

    /// True while a project is being fetched — the wizard is held still for the
    /// duration rather than letting someone walk away from a half-unpacked folder.
    private var isDownloading: Bool {
        switch downloader.stage {
        case .findingRelease, .downloading, .verifying, .unpacking: return true
        case .idle, .failed, .done:                                 return false
        }
    }

    /// Some questions only make sense for certain engines, whatever the template
    /// lists — asking for a PHP version when PHP is not involved is noise.
    private func shouldAsk(_ question: TemplateQuestion, in template: ProfileTemplate) -> Bool {
        switch question {
        case .phpVersion: return template.settings.engine.runsPHP
        case .https:      return template.settings.engine.supportsHTTPS
        case .database:   return true
        default:          return true
        }
    }

    @ViewBuilder
    private func questionBody(_ question: TemplateQuestion, template: ProfileTemplate) -> some View {
        switch question {
        case .folder:
            ask("Which folder?", template.folderAdvice ?? String(localized: "Choose the folder to serve.")) {
                if let hint = template.rootHint {
                    Label("This kind of project usually serves its “\(hint)” subfolder.",
                          systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("", text: $folder, prompt: Text("No folder chosen"))
                        .glassField()
                    Button("Choose…") { chooseFolder(hint: template.rootHint) }
                }

                // For something like Joomla the honest answer to an empty folder
                // is not “make a placeholder page” but “fetch the actual thing”.
                if Features.isOn(.projectDownloads),
                   let project = DownloadableProject.forTemplate(template),
                   !folder.trimmingCharacters(in: .whitespaces).isEmpty {
                    Divider()
                    downloadRow(project)
                }

                // An empty folder is the commonest way a first profile fails to
                // start, and the wizard is the moment to fix it — not the editor
                // afterwards, once the failure has already happened.
                if !folder.trimmingCharacters(in: .whitespaces).isEmpty,
                   folderLooksEmpty(for: template),
                   !(Features.isOn(.projectDownloads) && DownloadableProject.forTemplate(template) != nil) {
                    let starters = StarterFiles.available(for: draftProfile(from: template))
                    if !starters.isEmpty {
                        Divider()
                        Text("This folder has nothing to serve yet.")
                            .font(.caption).foregroundStyle(.orange)
                        Menu {
                            ForEach(starters) { starter in
                                Button {
                                    generate(starter, for: template)
                                } label: {
                                    Label("\(starter.title) — \(starter.fileName)",
                                          systemImage: starter.symbol)
                                }
                            }
                        } label: {
                            Label("Create a starting file…", systemImage: "plus.rectangle.on.folder")
                        }
                        .frame(width: 220)
                    }
                }
            }

        case .name:
            ask("What should it be called?", String(localized: "Only you see this — it names the profile in the list.")) {
                TextField("", text: $name).glassField()
            }

        case .port:
            ask("Which port?", String(localized: "Anything from 1024 upwards needs no password. The suggestion below is free right now.")) {
                HStack {
                    TextField("", value: $port, format: .number.grouping(.never))
                        .glassField().frame(width: 110)
                    Text("http://127.0.0.1:\(String(port))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

        case .phpVersion:
            ask("Which PHP?", String(localized: "The version belongs to this profile alone — other projects keep theirs.")) {
                Picker("", selection: $phpVersion) {
                    Text("Whatever is in PATH").tag("")
                    ForEach(model.dependencies.phpVersions, id: \.version) { installed in
                        Text("PHP \(installed.version)").tag(installed.version)
                    }
                }
                .labelsHidden()
                if !phpVersion.isEmpty,
                   !model.dependencies.phpVersions.contains(where: { $0.version == phpVersion }) {
                    // Telling someone to go and type a brew command, in a wizard
                    // whose whole point is not having to, would be absurd.
                    HStack(spacing: 10) {
                        if model.dependencies.installingPHP.contains(phpVersion) {
                            ProgressView().controlSize(.small)
                            Text("Installing PHP \(phpVersion) — this takes a few minutes.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("PHP \(phpVersion) is not installed yet.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Install it") {
                                Task {
                                    _ = await model.dependencies.installPHP(version: phpVersion,
                                                                            log: model.installLog)
                                }
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .database:
            ask("Does it need a database?", String(localized: "A MariaDB of its own, on its own port. Any MySQL you already have is untouched.")) {
                Toggle("Create a database for this project", isOn: $createDatabase)
                    .disabled(template.packageKind == "wordpress-w2p")
                if createDatabase {
                    TextField("", text: $databaseName, prompt: Text("Database name"))
                        .glassField()
                    HStack {
                        Group {
                            if showDatabasePassword {
                                TextField("Database password", text: $databasePassword)
                            } else {
                                SecureField("Database password", text: $databasePassword)
                            }
                        }
                        .glassField()
                        Button(showDatabasePassword ? "Hide" : "Show") { showDatabasePassword.toggle() }
                        Button("Generate") { databasePassword = DatabaseAdminPanel.generatedPassword(length: 16) }
                    }
                    Text("Credentials are saved in Keychain when available; otherwise they are kept for this session.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Latin letters, digits and underscores. The installer of your CMS will ask for this name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .https:
            ask("Over HTTPS?", String(localized: "A certificate is generated for you. The browser warns about it unless mkcert is installed.")) {
                Toggle("Serve over HTTPS", isOn: $httpsEnabled)
                if template.settings.engine.requiresHTTPSProxy && httpsEnabled {
                    Text("HTTPS for this engine also requires Caddy. Install it on the Dependencies screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .command:
            ask("Which command?", String(localized: "Run exactly as typed, in the folder you chose.")) {
                TextField("", text: $command, prompt: Text("npm run dev"))
                    .glassField()
                    .font(.system(.body, design: .monospaced))
            }

        case .entryFile:
            ask("Which file starts it?", String(localized: "Relative to the folder you chose.")) {
                TextField("", text: $entryFile, prompt: Text("server.js"))
                    .glassField()
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private func ask(_ title: LocalizedStringKey, _ detail: String,
                     @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).fontWeight(.medium)
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 4)
        }
    }

    private func isAnswered(_ question: TemplateQuestion, template: ProfileTemplate) -> Bool {
        switch question {
        case .folder:    return !folder.trimmingCharacters(in: .whitespaces).isEmpty
        case .name:      return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .port:      return port > 0 && port < 65536
        case .database:  return !createDatabase || (!databaseName.trimmingCharacters(in: .whitespaces).isEmpty && !databasePassword.isEmpty)
        case .command:   return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .entryFile: return !entryFile.trimmingCharacters(in: .whitespaces).isEmpty
        default:         return true
        }
    }



    @ViewBuilder
    private func downloadRow(_ project: DownloadableProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch downloader.stage {
            case .idle, .failed:
                Text("The folder is empty — ServerMaster can fetch \(project.title) into it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Task { await downloader.fetch(project, into: folder) }
                    } label: {
                        Label("Download \(project.title)", systemImage: "arrow.down.circle")
                    }
                    Text("From the official release, checked against its published checksum.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let message) = downloader.stage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .findingRelease:
                busy("Looking for the newest release…")

            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 4) {
                    if fraction < 0 {
                        busy("Downloading…")
                    } else {
                        Text("Downloading… \(String(Int(fraction * 100)))%").font(.caption)
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    }
                }

            case .verifying:
                busy("Checking the download…")

            case .unpacking:
                busy("Unpacking…")

            case .done(let version):
                Label("\(project.title) \(version) is in place.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            if isDownloading {
                Text(Waiting.line(for: .download, elapsed: clock.elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isDownloading) { _, running in
            if running { clock.start() } else { clock.stop() }
        }
    }

    private func busy(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The profile as it would be, used to work out which starter files fit.
    private func draftProfile(from template: ProfileTemplate) -> ServerProfile {
        var profile = template.makeProfile(name: name.trimmingCharacters(in: .whitespaces), port: port, root: AppPaths.expand(folder))
        profile.phpVersion = phpVersion
        if profile.engine.supportsHTTPS { profile.httpsEnabled = httpsEnabled }
        if profile.engine == .nodeScript { profile.nodeEntryFile = entryFile }
        if profile.engine == .custom { profile.customCommand = command }
        if template.packageKind != "wordpress-w2p" { profile.needsDatabase = createDatabase }
        if createDatabase { profile.databaseName = databaseName.trimmingCharacters(in: .whitespacesAndNewlines) }
        return profile
    }

    /// Whether the chosen folder has the file this template needs to serve.
    private func folderLooksEmpty(for template: ProfileTemplate) -> Bool {
        let root = AppPaths.expand(folder)
        var wanted = [template.settings.indexFile]
        if template.settings.engine == .nodeScript { wanted = [entryFile] }
        if template.settings.engine == .custom { return false }
        return !wanted.contains { name in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(name))
        }
    }

    private func generate(_ starter: StarterFile, for template: ProfileTemplate) {
        do {
            _ = try starter.write(into: folder, profile: draftProfile(from: template), overwrite: false)
            if template.settings.engine == .nodeScript,
               ["js", "cjs", "mjs"].contains(URL(fileURLWithPath: starter.fileName).pathExtension.lowercased()) {
                entryFile = starter.fileName
            }
            problem = starter.afterNote ?? String(localized: "Created \(starter.fileName).")
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Flow

    private func begin(_ template: ProfileTemplate) {
        step = 0
        problem = nil
        folder = ""
        name = template.title
        port = suggestedPort()
        phpVersion = template.makeProfile(name: template.title, port: port, root: "").phpVersion
        createDatabase = template.needsDatabase
        databaseName = suggestedDatabaseName(for: template)
        databasePassword = DatabaseAdminPanel.generatedPassword(length: 16)
        showDatabasePassword = false
        preparation = NewProfilePreparation()
        httpsEnabled = template.settings.httpsEnabled
        command = template.settings.customCommand
        entryFile = template.settings.nodeEntryFile
        stage = .questions(template)
    }

    private func advance(asked: [TemplateQuestion], template: ProfileTemplate) {
        guard !preparingProfile, asked.indices.contains(step) else { return }
        problem = nil

        // Checked as the person moves on, not after everything is filled in:
        // a taken port found at the end means re-reading three screens.
        if asked[step] == .port, !model.isProfilePortAvailable(port) {
            problem = String(localized: "Port \(String(port)) is already in use. Pick another one.")
            return
        }
        if asked[step] == .folder, !FileManager.default.fileExists(atPath: AppPaths.expand(folder)) {
            problem = String(localized: "That folder does not exist.")
            return
        }

        guard step == asked.count - 1 else {
            step += 1
            return
        }
        preparingProfile = true
        Task {
            defer { preparingProfile = false }
            await finish(template)
        }
    }

    private func finish(_ template: ProfileTemplate) async {
        var profile = draftProfile(from: template)
        guard model.isProfilePortAvailable(profile.port, host: profile.host) else {
            problem = String(localized: "Port \(String(profile.port)) is already in use. Pick another one.")
            return
        }
        guard !createDatabase || !databasePassword.isEmpty else {
            problem = String(localized: "Enter a database password or generate one.")
            return
        }

        // Templates carry TLS intent but never machine-specific private keys.
        // Fulfil the wizard's certificate promise before adding the profile.
        if profile.httpsEnabled && profile.engine.supportsHTTPS {
            do {
                let certificateName = "profile-\(profile.id.uuidString)"
                let domains = "localhost,127.0.0.1,::1"
                let pair: CertificatePair
                if model.certificates.mkcert.trustedInSystem {
                    pair = try await model.certificates.generateWithMkcert(name: certificateName, domains: domains)
                } else {
                    pair = try await model.certificates.generateSelfSigned(
                        name: certificateName, domains: domains,
                        days: model.settings.certificateDefaultDays)
                }
                profile.certificatePath = pair.certificatePath
                profile.privateKeyPath = pair.privateKeyPath
            } catch {
                problem = error.localizedDescription
                return
            }
        }

        guard model.addProfile(profile, completingFirstSetup: false) else {
            problem = String(localized: "The profile could not be saved. Check the data folder permissions.")
            return
        }
        model.selectedProfileID = profile.id

        stage = .created(profile.id)
        defer { databasePassword = "" }
        let wanted = createDatabase ? databaseName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        await preparation.prepare(profileID: profile.id, template: template,
                                  databaseName: wanted.isEmpty ? nil : wanted,
                                  password: createDatabase ? databasePassword : nil, using: model)
    }

    private func completion(for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Profile saved", systemImage: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(.green)
            Text(model.profile(with: id)?.name ?? "")
                .font(.title3).fontWeight(.semibold)
            switch preparation.phase {
            case .idle, .preparing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.recipePreparations[id].map { operation in
                        if case .preparing(let step) = operation.phase { return step.title }
                        return String(localized: "Preparing the project…")
                    } ?? String(localized: "Preparing the project…"))
                }
            case .ready:
                Text("Ready. Start the server now or return to it later.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Profile saved, but preparation did not finish. Open its profile to retry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = preparation.startFailure {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button("Open profile") {
                    model.selectedProfileID = id
                    model.section = .profiles
                    closeWizard()
                }
                .disabled(preparingProfile || preparation.isStarting)
                Button("Done") { closeWizard() }
                    .disabled(preparingProfile || preparation.isStarting)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if preparation.canStart {
                    Button(startTitle(for: id)) {
                        Task {
                            if await preparation.start(using: model) { closeWizard() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if preparation.isStarting { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func startTitle(for id: UUID) -> LocalizedStringKey {
        (model.profile(with: id)?.openBrowserOnStart == true || model.settings.openBrowserOnStart)
            ? "Start and open" : "Start server"
    }

    private func closeWizard() {
        if model.needsFirstSetup { model.completeFirstSetup() }
        dismiss()
    }

    private func createEmpty() {
        var profile = ServerProfile()
        profile.name = String(localized: "Profile \(String(model.profiles.count + 1))")
        guard let port = model.suggestedProfilePort() else {
            model.notify(String(localized: "No free profile port was found. Release a port and try again."), isError: true)
            return
        }
        profile.port = port
        guard model.addProfile(profile) else {
            problem = String(localized: "The profile could not be saved. Check the data folder permissions.")
            return
        }
        model.selectedProfileID = profile.id
        dismiss()
    }

    // MARK: - Helpers

    private func suggestedPort() -> Int { model.suggestedProfilePort() ?? 0 }

    private func suggestedDatabaseName(for template: ProfileTemplate) -> String {
        guard template.needsDatabase else { return "" }
        let base = template.id.replacingOccurrences(of: "-", with: "_")
                              .replacingOccurrences(of: ".", with: "_")
        var candidate = base
        var counter = 2
        let taken = Set(model.database.databases.map(\.name))
        while taken.contains(candidate) {
            candidate = "\(base)_\(String(counter))"
            counter += 1
        }
        return candidate
    }

    private func chooseFolder(hint: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let hint {
            panel.message = String(localized: "If the project has a “\(hint)” subfolder, choose that one.")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path

        // A quiet nudge rather than a correction: the person may know better.
        if let hint, FileManager.default.fileExists(atPath: url.appendingPathComponent(hint).path) {
            problem = String(localized: "This folder contains a “\(hint)” subfolder — that is usually the one to serve.")
        } else {
            problem = nil
        }
    }

    private func importTemplates() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: TemplateStore.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importTemplates(from: url)
            model.notify(String(localized: "Imported templates: \(String(added.count))."))
        } catch {
            model.notify(error.localizedDescription, isError: true)
        }
    }

    private func export(_ templates: [ProfileTemplate]) {
        guard !templates.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (templates.count == 1 ? templates[0].id : "templates")
            + "." + TemplateStore.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: TemplateStore.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(templates, to: url)
            model.notify(templates.count == 1
                         ? String(localized: "Template saved.")
                         : String(localized: "Saved templates: \(String(templates.count))."))
        } catch {
            model.notify(error.localizedDescription, isError: true)
        }
    }
}
