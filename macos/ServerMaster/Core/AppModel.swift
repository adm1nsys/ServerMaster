//
//  AppModel.swift
//  ServerMaster
//

import Foundation
import Observation
import AppKit
import WidgetKit

nonisolated enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case control      = "control"
    case dependencies = "dependencies"
    case console      = "console"
    case profiles     = "profiles"
    case database     = "database"
    case ports        = "ports"
    case backups      = "backups"
    case diagnostics  = "diagnostics"
    case files        = "files"
    case commandLine  = "commandLine"
    case settings     = "settings"
    case about        = "about"

    var id: String { rawValue }

    /// Sections tied to a feature that has not been released yet are simply not
    /// there. See Features.swift for why finished work waits.
    static var visible: [SidebarSection] {
        allCases.filter { section in
            switch section {
            case .commandLine: return Features.isOn(.commandLineTool)
            default:           return true
            }
        }
    }

    var title: String {
        switch self {
        case .control:      return String(localized: "Control")
        case .dependencies: return String(localized: "Dependencies")
        case .console:      return String(localized: "Console")
        case .profiles:     return String(localized: "Profiles")
        case .database:     return String(localized: "Database")
        case .ports:        return String(localized: "Ports")
        case .backups:      return String(localized: "Backups")
        case .diagnostics:  return String(localized: "Diagnostics")
        case .files:        return String(localized: "Files")
        case .commandLine:  return String(localized: "Command line")
        case .settings:     return String(localized: "Settings")
        case .about:        return String(localized: "About")
        }
    }

    /// Which group in the sidebar this belongs to.
    ///
    /// Here rather than in the view on purpose: the sidebar used to be a
    /// hand-written list of rows, so a section could be added to this enum, be
    /// given a title, an icon and a screen, and still be unreachable because
    /// nobody remembered the one list that decides what is shown. Now the list
    /// is derived, and a new case cannot go missing.
    enum Group: String, CaseIterable {
        case server = "Server"
        case configuration = "Configuration"
    }

    var group: Group {
        switch self {
        case .control, .console, .database, .ports, .files:
            return .server
        case .profiles, .dependencies, .backups, .diagnostics, .commandLine, .settings, .about:
            return .configuration
        }
    }

    static func visible(in group: Group) -> [SidebarSection] {
        visible.filter { $0.group == group }
    }

    var symbol: String {
        switch self {
        case .control:      return "play.circle"
        case .dependencies: return "checklist"
        case .console:      return "terminal"
        case .profiles:     return "square.stack.3d.up"
        case .database:     return "cylinder.split.1x2"
        case .ports:        return "point.3.connected.trianglepath.dotted"
        case .backups:      return "clock.arrow.circlepath"
        case .diagnostics:  return "stethoscope"
        case .files:        return "doc.text.magnifyingglass"
        case .commandLine:  return "apple.terminal"
        case .settings:     return "gearshape"
        case .about:        return "info.circle"
        }
    }
}

@Observable
final class AppModel {

    // MARK: State
    var profiles: [ServerProfile] = []
    var settings = AppSettings()
    let diagnostics = Diagnostics()
    let trace = DomainTrace()
    let health = HealthCheck()
    let translations = TranslationStore()
    var section: SidebarSection = .control
    var selectedProfileID: UUID?

    // MARK: Services
    /// One controller per profile — servers run in parallel.
    private(set) var servers: [UUID: ServerController] = [:]
    /// Launch order, which sets the tab order in the console.
    private(set) var runningOrder: [UUID] = []

    let dependencies = DependencyChecker()
    let updates = UpdateChecker()
    let database = DatabaseService()
    let adminPanel = DatabaseAdminPanel()
    let templates = TemplateStore()
    /// Where installing something writes its output, wherever it was started from.
    let installLog = ConsoleLog()
    let commandLineTool = CommandLineTool()

    /// Bumped whenever a feature gate is switched. The gates themselves live in
    /// UserDefaults, which SwiftUI does not watch — without this the sidebar
    /// keeps its old sections and turning developer mode on looks like it did
    /// nothing at all.
    private(set) var featureRevision = 0

    func featuresChanged() { featureRevision += 1 }
    let certificates = CertificateManager()
    let reserver = PortReserver()
    let shell = ShellSession()

    /// Terminal tabs — each one has its own shell.
    private(set) var terminals: [TerminalTab] = []

    // MARK: Ports
    var portEntries: [PortEntry] = []
    var isScanningPorts = false
    var portsError: String?

    // MARK: Loading
    private(set) var isBootstrapping = true
    private(set) var bootstrapStage = String(localized: "Starting…")
    private(set) var bootstrapProgress: Double = 0

    // MARK: Shutdown
    nonisolated struct ShutdownItem: Identifiable, Sendable {
        enum Status: Sendable { case waiting, stopping, stopped, forced }
        let id: UUID
        var name: String
        var status: Status = .waiting
        var detail: String = ""
    }

    private(set) var isShuttingDown = false
    private(set) var shutdownItems: [ShutdownItem] = []
    private(set) var shutdownProgress: Double = 0
    private(set) var shutdownTookTooLong = false

    // MARK: Shared notifications for the UI
    var banner: Banner?

    nonisolated struct Banner: Identifiable, Sendable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    private var portTimer: Timer?
    private var profilesSaveTask: Task<Void, Never>?

    init() {
        load()
        ShellEnvironment.shared.setExtraEntries(settings.extraPATHEntries)

        if settings.restoreLastSection,
           let restored = SidebarSection(rawValue: settings.lastSection) {
            section = restored
        }
        selectedProfileID = settings.lastSelectedProfileID
            ?? settings.defaultProfileID
            ?? profiles.first?.id

        shell.setDirectory(selectedProfile?.effectiveWorkingDirectory ?? NSHomeDirectory())
        updates.repository = settings.updateRepository
        updates.versionFile = settings.updateVersionFile
        updates.buildsFolder = settings.updateBuildsFolder
    }

    /// The language is read from the settings file before the model is created.
    nonisolated static func storedLanguage() -> String {
        guard let data = try? Data(contentsOf: AppPaths.settingsFile),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppLanguage.systemCode
        }
        return decoded.language
    }

    // MARK: - Application launch

    /// The sequence of startup steps — the splash screen shows it.
    func bootstrap() async {
        func stage(_ text: String, _ progress: Double) async {
            bootstrapStage = text
            bootstrapProgress = progress
            // Let the frame draw, otherwise the steps flash by unnoticed.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        await stage(String(localized: "Reading the environment…"), 0.15)
        _ = ShellEnvironment.shared.path
        templates.load()
        commandLineTool.refresh()
        adoptExternalServers()
        startWatchingProfilesFile()
        startWatchingBrowserRequests()
        startBackupSchedule()
        publishStatus()

        if settings.checkDependenciesOnLaunch {
            await stage(String(localized: "Checking dependencies…"), 0.35)
            await dependencies.checkAll()
        }

        await stage(String(localized: "Looking for forgotten servers…"), 0.6)
        reclaimPrivilegedServers()

        pruneRuntimeDirectories()
        pruneOldLogs()

        await stage(String(localized: "Reading certificates…"), 0.7)
        await certificates.reload()
        await certificates.refreshMkcertStatus()

        if settings.checkUpdatesOnLaunch && updates.isConfigured {
            await stage(String(localized: "Checking for updates…"), 0.85)
            await checkForUpdates(silently: true)
        }

        await stage(String(localized: "Done"), 1.0)
        isBootstrapping = false

        if settings.autostartDefaultProfile, let profile = defaultProfile {
            await startServer(profile: profile)
        }
    }

    // MARK: - Profiles

    var selectedProfile: ServerProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    var defaultProfile: ServerProfile? {
        guard let id = settings.defaultProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    func profile(with id: UUID?) -> ServerProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func addProfile(_ profile: ServerProfile) {
        profiles.append(profile)
        selectedProfileID = profile.id
        saveProfiles()
    }

    func updateProfile(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        // The editor sends an edit on every keystroke — write to disk with a delay.
        scheduleProfilesSave()
    }

    private func scheduleProfilesSave() {
        profilesSaveTask?.cancel()
        profilesSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProfiles()
        }
    }

    /// Flushes the pending write immediately — before quitting and when changing section.
    func flushPendingSaves() {
        profilesSaveTask?.cancel()
        profilesSaveTask = nil
        saveProfiles()
    }

    func deleteProfile(_ profile: ServerProfile) {
        // Order matters. Stop the server first: otherwise the process is orphaned,
        // keeps holding the port, and the interface can no longer reach it.
        // Only then remove the working files — otherwise we would rip the config
        // out from under a still-running nginx.
        if let controller = servers[profile.id], controller.state.isActive {
            controller.stopImmediately()
        }
        runningOrder.removeAll { $0 == profile.id }
        publishStatus()
        servers[profile.id] = nil
        removeRuntimeArtifacts(for: profile)
        profiles.removeAll { $0.id == profile.id }
        if settings.defaultProfileID == profile.id { settings.defaultProfileID = nil }
        if selectedProfileID == profile.id { selectedProfileID = profiles.first?.id }
        saveProfiles()
        saveSettings()
    }

    /// Remove the profile's working folders: configs, logs, error pages.
    /// Otherwise Runtime accumulates junk from long-deleted profiles.
    private func removeRuntimeArtifacts(for profile: ServerProfile) {
        let key = String(profile.id.uuidString.prefix(8))
        let runtime = AppPaths.support.appendingPathComponent("Runtime", isDirectory: true)
        for prefix in ["nginx", "caddy", "php", "root"] {
            let path = runtime.appendingPathComponent("\(prefix)-\(key)", isDirectory: true)
            try? FileManager.default.removeItem(at: path)
        }
    }

    func duplicateProfile(_ profile: ServerProfile) {
        let copy = profile.duplicated()
        profiles.append(copy)
        selectedProfileID = copy.id
        saveProfiles()
    }

    func makeDefault(_ profile: ServerProfile) {
        settings.defaultProfileID = profile.id
        saveSettings()
        notify(String(localized: "Profile “\(profile.name)” is now the default."))
    }

    // MARK: - Servers

    /// The profile's controller. Created on first use.
    func controller(for profileID: UUID) -> ServerController {
        if let existing = servers[profileID] { return existing }
        let controller = ServerController()
        controller.onUnexpectedExit = { [weak self] profile, code in
            guard let self else { return }
            self.notify(String(localized: "Server “\(profile.name)” exited unexpectedly (code \(String(code)))."), isError: true)
            self.runningOrder.removeAll { $0 == profile.id }
            self.publishStatus()
            if self.settings.restartOnCrash {
                Task { await self.startServer(profile: profile) }
            }
        }
        servers[profileID] = controller
        return controller
    }

    func existingController(for profileID: UUID?) -> ServerController? {
        guard let profileID else { return nil }
        return servers[profileID]
    }

    func state(of profileID: UUID) -> ServerState {
        servers[profileID]?.state ?? .stopped
    }

    func isActive(_ profileID: UUID) -> Bool {
        servers[profileID]?.state.isActive ?? false
    }

    /// Profiles whose servers are running or starting right now.
    var activeProfiles: [ServerProfile] {
        runningOrder.compactMap { id in profiles.first { $0.id == id } }
    }

    var activeCount: Int {
        servers.values.filter { $0.state.isActive }.count
    }

    /// Leaves the current picture on disk for the widget, which runs in its own
    /// process and cannot see any of this otherwise. Called after every change
    /// that alters what someone would see at a glance.
    /// The last thing written, so a repeat publish costs nothing. `updated`
    /// changes every time and is left out of the comparison.
    private var lastPublished: [StatusSnapshot.Entry]?
    private var lastPublishedExtras: (database: Bool, panel: String?)?

    func publishStatus() {
        let entries = profiles.map { profile -> StatusSnapshot.Entry in
            let state = self.state(of: profile.id)
            var detail: String?
            var name = "stopped"
            switch state {
            case .running:  name = "running"
            case .starting: name = "starting"
            case .stopping: name = "starting"
            case .failed(let message):
                name = "failed"
                detail = message
            case .stopped:  name = "stopped"
            }
            return StatusSnapshot.Entry(id: profile.id.uuidString,
                                        name: profile.name,
                                        address: profile.address,
                                        state: name,
                                        detail: detail)
        }
        let extras = (database: database.state == .running,
                      panel: adminPanel.address?.absoluteString)
        guard entries != lastPublished
                || extras.database != lastPublishedExtras?.database
                || extras.panel != lastPublishedExtras?.panel else { return }
        lastPublished = entries
        lastPublishedExtras = extras

        StatusSnapshot(updated: Date(),
                       profiles: entries,
                       databaseRunning: extras.database,
                       adminPanelAddress: extras.panel).write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Staying in step with the terminal

    /// When the profiles file was last written, so a change made outside this
    /// window can be noticed.
    private var profilesFileStamp: Date?

    /// Watches the profiles file and reloads when something else writes it.
    ///
    /// The window and the command line tool are meant to be independent: either
    /// can be used without the other, and neither may block the other's work.
    /// That only holds if the one holding a list in memory notices when the file
    /// underneath it changes — otherwise the app would quietly write its stale
    /// copy back and the terminal's edit would vanish with no error anywhere.
    ///
    /// Polling the modification date rather than watching the file descriptor:
    /// the file is replaced atomically, which breaks a vnode watch on the first
    /// write, and one stat every couple of seconds costs nothing.
    // MARK: - Requests from the Safari extension

    /// Ids already carried out, so a request is never run twice — the file is
    /// removed after acting on it, but a failed removal must not turn into a
    /// server that restarts every two seconds.
    private var handledRequests: Set<String> = []

    /// The Safari extension cannot start a server itself: it is sandboxed, as
    /// every app extension on macOS must be. It leaves a request in the group
    /// container instead, and this picks it up.
    func startWatchingBrowserRequests() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.handleBrowserRequest()
            }
        }
    }

    // MARK: - Backups

    /// Built on first use rather than at init: the destination comes from
    /// settings, which are not read yet when the model is created.
    @ObservationIgnored private var snapshotStore: SnapshotStore?

    var snapshots: SnapshotStore {
        if let snapshotStore { return snapshotStore }
        let store = SnapshotStore(destination: settings.backupDestination.isEmpty
                                    ? SnapshotStore.defaultDestination()
                                    : settings.backupDestination,
                                  log: installLog)
        snapshotStore = store
        return store
    }

    /// Checked once a minute rather than scheduled to the second. A backup is
    /// not a deadline: being a minute late costs nothing, and a timer that fires
    /// exactly on the hour is a timer that fires while the machine is asleep and
    /// never catches up.
    func startBackupSchedule() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                await self.runScheduledBackupIfDue()
            }
        }
    }

    func runScheduledBackupIfDue() async {
        guard settings.backupsEnabled, settings.backupEvery > 0 else { return }
        let gap = Double(settings.backupEvery) * settings.backupUnit.seconds
        if let last = settings.lastBackup, Date().timeIntervalSince(last) < gap { return }

        let wanted = settings.backupProfileIDs.isEmpty
            ? profiles
            : profiles.filter { settings.backupProfileIDs.contains($0.id) }
        guard !wanted.isEmpty else { return }

        for profile in wanted {
            await snapshots.take(profile: profile,
                                 database: settings.backupIncludesDatabase ? database : nil,
                                 trigger: .scheduled)
        }
        if settings.backupAllDatabases, database.state == .running {
            for item in database.databases {
                await snapshots.takeDatabase(named: item.name, database: database, trigger: .scheduled)
            }
        }
        snapshots.prune(keep: settings.backupsToKeep)
        settings.lastBackup = Date()
        saveSettings()
    }

    private func handleBrowserRequest() async {
        // Publishing on this tick too, not only where a state change is noticed.
        // A server takes its time coming up — Joomla especially — and the state
        // it settles into is not always reached inside the call that started it.
        // Nothing is written unless something actually changed.
        publishStatus()


        let file = AppPaths.shared.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: file),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String,
              let action = request["action"] as? String,
              let profileID = request["profile"] as? String
        else { return }

        try? FileManager.default.removeItem(at: file)
        guard !handledRequests.contains(id) else { return }
        handledRequests.insert(id)

        // A request left behind by a crash should not fire hours later, when
        // whoever clicked it has long since moved on.
        if let at = request["at"] as? TimeInterval,
           Date().timeIntervalSinceReferenceDate - at > 60 { return }

        guard let profile = profiles.first(where: { $0.id.uuidString == profileID }) else { return }
        switch action {
        case "start":   await startServer(profile: profile)
        case "stop":    await stopServer(profileID: profile.id)
        case "restart": await restartServer(profile: profile)
        default:        break
        }
    }

    func startWatchingProfilesFile() {
        profilesFileStamp = profilesFileModified()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await MainActor.run { self.reloadProfilesIfChangedOutside() }
            }
        }
    }

    private func profilesFileModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppPaths.profilesFile.path))?[.modificationDate] as? Date
    }

    private func loadProfilesFromDisk() -> [ServerProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: AppPaths.profilesFile),
              let decoded = try? decoder.decode([ServerProfile].self, from: data)
        else { return profiles }
        return decoded
    }

    private func reloadProfilesIfChangedOutside() {
        guard let stamp = profilesFileModified() else { return }
        guard let previous = profilesFileStamp else {
            profilesFileStamp = stamp
            return
        }
        guard stamp > previous else { return }
        profilesFileStamp = stamp

        // Our own save moved the date too; only a real difference is worth acting on.
        let onDisk = loadProfilesFromDisk()
        guard onDisk != profiles else { return }

        let selected = selectedProfileID
        profiles = onDisk
        if let selected, !profiles.contains(where: { $0.id == selected }) {
            selectedProfileID = profiles.first?.id
        }
        adoptExternalServers()
        publishStatus()
        notify(String(localized: "Profiles were changed outside this window and have been reloaded."))
    }

    /// Servers the terminal started, which this window does not own but must
    /// still show — a running site missing from the list is the window lying.
    func adoptExternalServers() {
        for record in RunRegistry.all() where record.origin == .commandLine {
            guard let id = UUID(uuidString: record.id),
                  profiles.contains(where: { $0.id == id }),
                  !runningOrder.contains(id)
            else { continue }
            runningOrder.append(id)
        }
        // And drop anything whose process has gone since we last looked.
        let alive = Set(RunRegistry.all().map(\.id))
        runningOrder.removeAll { id in
            guard servers[id] == nil else { return false }   // ours, tracked properly
            return !alive.contains(id.uuidString)
        }
    }

    /// Combined state for the sidebar indicator.
    var aggregateState: ServerState {
        let states = servers.values.map(\.state)
        if states.contains(where: { $0 == .starting || $0 == .stopping }) { return .starting }
        if states.contains(where: { $0 == .running }) { return .running }
        if let failure = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failure
        }
        return .stopped
    }

    func startServer(profile: ServerProfile) async {
        if reserver.isReserved(profile.port) {
            notify(String(localized: "Port \(String(profile.port)) is reserved inside the app. Release the reservation before starting."), isError: true)
            return
        }
        // Do not let two profiles take the same port.
        if let conflict = activeProfiles.first(where: { $0.id != profile.id && $0.port == profile.port }) {
            notify(String(localized: "Port \(String(profile.port)) is already used by the profile “\(conflict.name)”."), isError: true)
            return
        }

        // A PHP site almost always needs a database — bring it up as well.
        if profile.engine.typicallyNeedsDatabase,
           database.isInstalled,
           !database.state.isActive {
            await database.start()
            if case .failed(let message) = database.state {
                notify(String(localized: "The database did not start: \(message)"), isError: true)
            }
        }

        let controller = controller(for: profile.id)
        guard !controller.state.isActive else { return }

        if !runningOrder.contains(profile.id) { runningOrder.append(profile.id) }
        await controller.start(profile: profile, settings: settings)

        if case .failed(let message) = controller.state {
            runningOrder.removeAll { $0 == profile.id }
            notify(message, isError: true)
        } else if let pid = controller.processIdentifier {
            // Written down where the command line tool can see it, so a server
            // started here can be stopped there and the two stay one system.
            RunRegistry.record(RunRecord(id: profile.id.uuidString,
                                         name: profile.name,
                                         address: profile.address,
                                         port: profile.port,
                                         pid: pid,
                                         origin: .app,
                                         startedAt: Date()))
        }
        // After the attempt either way: the widget and the command line tool read
        // this file, and a server that started without being written down here is
        // a server they would both report as stopped.
        publishStatus()
    }

    func stopServer(profileID: UUID) async {
        // A server the terminal started has no controller here, but it is still
        // ours to stop — the registry knows where it is.
        guard let controller = servers[profileID] else {
            if let record = RunRegistry.find(profileID: profileID) {
                _ = await RunRegistry.stop(record)
                runningOrder.removeAll { $0 == profileID }
                publishStatus()
            }
            return
        }
        await controller.stop(settings: settings)
        RunRegistry.forget(profileID)
        runningOrder.removeAll { $0 == profileID }
        publishStatus()
    }

    func restartServer(profile: ServerProfile) async {
        await stopServer(profileID: profile.id)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await startServer(profile: profile)
    }

    func stopAll() async {
        for id in runningOrder { await stopServer(profileID: id) }
    }

    /// Synchronous shutdown of every server when the application quits.
    func stopAllImmediately() {
        flushPendingSaves()
        for tab in terminals { tab.session.terminate() }
        for controller in servers.values { controller.stopImmediately() }
        for id in runningOrder { RunRegistry.forget(id) }
        adminPanel.stopSynchronously()
        database.stopImmediately()
        runningOrder.removeAll()
    }

    /// Takes back control of root-owned servers that outlived the application.
    /// Ours are adopted, someone else's or those of deleted profiles are stopped,
    /// otherwise the process stays stuck on its port with no way to stop it.
    private func reclaimPrivilegedServers() {
        let orphans = PrivilegedLauncher.findOrphans()
        guard !orphans.isEmpty else { return }

        var adopted: [String] = []
        var stopped = 0

        for orphan in orphans {
            let profile = profiles.first { $0.id.uuidString.hasPrefix(orphan.profileKey) }
            if let profile {
                controller(for: profile.id).adopt(session: orphan.session,
                                                  profile: profile,
                                                  settings: settings)
                if !runningOrder.contains(profile.id) { runningOrder.append(profile.id) }
                adopted.append(profile.name)
            } else {
                PrivilegedLauncher.requestStop(orphan.session)
                stopped += 1
            }
        }

        if !adopted.isEmpty {
            notify(String(localized: "Adopted servers that were running before the restart: \(adopted.joined(separator: ", "))"))
        } else if stopped > 0 {
            notify(String(localized: "Forgotten administrator servers stopped: \(stopped)"))
        }
    }

    /// Removes the working folders of profiles that no longer exist.
    /// Called after adopting servers, so a live session is not wiped out.
    private func pruneRuntimeDirectories() {
        let fm = FileManager.default
        let runtime = AppPaths.support.appendingPathComponent("Runtime", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: runtime.path) else { return }

        let known = Set(profiles.map { String($0.id.uuidString.prefix(8)) })
        var removed = 0

        for entry in entries {
            guard let dash = entry.firstIndex(of: "-") else { continue }
            let prefix = String(entry[entry.startIndex..<dash])
            guard ["nginx", "caddy", "php", "root"].contains(prefix) else { continue }

            let key = String(entry[entry.index(after: dash)...])
            guard !known.contains(key) else { continue }

            let path = runtime.appendingPathComponent(entry, isDirectory: true).path

            // Never touch a live administrator session, under any circumstances.
            let sentinel = (path as NSString).appendingPathComponent("running.lock")
            if fm.fileExists(atPath: sentinel) { continue }

            // And leave fresh folders alone: another instance of the application, or a
            // server running right now, may be using them. The cleanup is for stale
            // junk, not for taking working files away from someone.
            if let attributes = try? fm.attributesOfItem(atPath: path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < 3600 {
                continue
            }

            try? fm.removeItem(atPath: path)
            removed += 1
        }

        if removed > 0 {
            server_log_pruned(removed)
        }
    }

    private func server_log_pruned(_ count: Int) {
        shell.log.system(String(localized: "Runtime folders removed for deleted profiles: \(count)"))
    }

    // MARK: - Terminal

    /// A single terminal tab: its own shell and its own screen.
    @Observable
    final class TerminalTab: Identifiable {
        let id = UUID()
        var title: String
        let session: PTYSession

        init(title: String, rows: Int = 24, columns: Int = 80) {
            self.title = title
            self.session = PTYSession(rows: rows, columns: columns)
        }
    }

    /// Creates a tab and starts a shell in it.
    @discardableResult
    func newTerminal(directory: String? = nil) -> TerminalTab {
        let number = terminals.count + 1
        let tab = TerminalTab(title: String(localized: "Terminal \(String(number))"))
        let workingDirectory = directory
            ?? selectedProfile?.effectiveWorkingDirectory
            ?? NSHomeDirectory()
        _ = tab.session.start(shell: settings.shellPath.isEmpty ? nil : settings.shellPath,
                              arguments: ["-i", "-l"],
                              directory: workingDirectory)
        terminals.append(tab)
        return tab
    }

    /// Guarantees at least one tab — created when the console is first opened.
    @discardableResult
    func ensureTerminal() -> TerminalTab {
        if let first = terminals.first { return first }
        return newTerminal()
    }

    func closeTerminal(_ id: UUID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[index].session.terminate()
        terminals.remove(at: index)
    }

    func terminal(_ id: UUID) -> TerminalTab? {
        terminals.first { $0.id == id }
    }

    func restartTerminal(_ id: UUID) {
        guard let tab = terminal(id) else { return }
        let directory = selectedProfile?.effectiveWorkingDirectory ?? NSHomeDirectory()
        tab.session.terminate()
        tab.session.terminal.reset()
        _ = tab.session.start(shell: settings.shellPath.isEmpty ? nil : settings.shellPath,
                              arguments: ["-i", "-l"],
                              directory: directory)
    }

    /// Every server launch creates its own log file — without cleanup they pile
    /// up without limit. Prune by retention period, leaving alone the files
    /// being written to right now.
    private func pruneOldLogs() {
        let days = settings.logRetentionDays
        guard days > 0 else { return }

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let inUse = Set(servers.values.compactMap { $0.log.fileURL })
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.logs,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        var removed = 0
        for file in files where !inUse.contains(file) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            shell.log.system(String(localized: "Old log files removed: \(String(removed))"))
        }
    }

    // MARK: - Updates

    /// An update worth mentioning: found and not dismissed by the user.
    var pendingUpdate: ReleaseInfo? {
        guard case .available(let release) = updates.state else { return nil }
        guard release.version != settings.dismissedUpdateVersion else { return nil }
        return release
    }

    func dismissUpdate(_ version: String) {
        settings.dismissedUpdateVersion = version
        saveSettings()
    }

    func checkForUpdates(silently: Bool) async {
        // A newer version overrides an earlier “later”.
        if !settings.dismissedUpdateVersion.isEmpty {
            let hidden = settings.dismissedUpdateVersion
            await updates.check(silently: silently)
            if case .available(let release) = updates.state,
               UpdateChecker.isNewer(release.version, than: hidden) {
                settings.dismissedUpdateVersion = ""
            }
        } else {
            await updates.check(silently: silently)
        }
        settings.lastUpdateCheck = Date()
        saveSettings()
    }

    // MARK: - Database

    func startDatabase() async {
        await database.start()
        defer { publishStatus() }
        if case .failed(let message) = database.state {
            notify(message, isError: true)
        }
    }

    func stopDatabase() async {
        // The panel serves this database and must not outlive it.
        adminPanel.stop()
        await database.stop()
        publishStatus()
    }

    /// Brings the database up if needed and creates the database a new profile
    /// asked for, so the person can go straight to the CMS installer.
    func prepareDatabase(named name: String, for profile: ServerProfile) async {
        if database.state != .running {
            await database.start()
        }
        guard database.state == .running else {
            notify(String(localized: "The database did not start; create it later on the Database screen."),
                   isError: true)
            return
        }
        if database.databases.contains(where: { $0.name == name }) {
            notify(String(localized: "Database “\(name)” already exists — use it in the installer."))
            return
        }
        // One account per database, named after it: a CMS installer wants a user
        // and a password, and reusing root would tie every site together.
        let result = await database.createDatabase(name: name,
                                                   user: name,
                                                   password: DatabaseAdminPanel.generatedPassword(length: 16))
        if result.succeeded {
            notify(String(localized: "Database “\(name)” is ready for “\(profile.name)”."))
        } else {
            notify(result.stderr.isEmpty ? String(localized: "Could not create the database.") : result.stderr,
                   isError: true)
        }
    }

    /// Opens the web admin panel, starting it if it is not up yet.
    func openAdminPanel() async {
        if let url = adminPanel.address {
            NSWorkspace.shared.open(url)
            return
        }
        await adminPanel.start(tool: settings.databaseAdminTool,
                               database: database,
                               port: settings.databaseAdminPort)
        if case .failed(let message) = adminPanel.state {
            notify(message, isError: true)
        } else if let url = adminPanel.address {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shutdown

    /// Whether the waiting window should be shown before quitting.
    var needsGracefulShutdown: Bool {
        settings.stopServerOnQuit && (activeCount > 0 || database.state.isActive)
    }

    /// Stops the servers one by one, showing progress,
    /// and only then lets the application go.
    func beginShutdown(completion: @escaping () -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownTookTooLong = false

        let running = activeProfiles
        shutdownItems = running.map { ShutdownItem(id: $0.id, name: $0.name) }
        shutdownProgress = 0

        // If something hangs — offer to force quit.
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.isShuttingDown else { return }
            self.shutdownTookTooLong = true
        }

        Task { @MainActor in
            for (index, profile) in running.enumerated() {
                self.updateShutdown(profile.id, status: .stopping,
                                    detail: String(localized: "stopping…"))

                let controller = self.servers[profile.id]
                let wasPrivileged = controller?.isPrivileged ?? false
                await self.stopServer(profileID: profile.id)

                let stillAlive = controller?.state.isActive ?? false
                self.updateShutdown(profile.id,
                                    status: stillAlive ? .forced : .stopped,
                                    detail: stillAlive
                                            ? String(localized: "force stopped")
                                            : (wasPrivileged
                                               ? String(localized: "stopped (root)")
                                               : String(localized: "stopped")))
                self.shutdownProgress = Double(index + 1) / Double(max(1, running.count))
            }

            if self.database.state.isActive {
                self.shutdownItems.append(ShutdownItem(id: UUID(),
                                                       name: String(localized: "Database"),
                                                       status: .stopping,
                                                       detail: String(localized: "stopping…")))
                await self.database.stop()
                if let last = self.shutdownItems.indices.last {
                    self.shutdownItems[last].status = .stopped
                    self.shutdownItems[last].detail = String(localized: "stopped")
                }
            }

            self.flushPendingSaves()
            self.reserver.releaseAll()
            self.saveSettings()
            timeout.cancel()

            // A short pause so the checkmarks are visible.
            try? await Task.sleep(nanoseconds: 350_000_000)
            completion()
        }
    }

    private func updateShutdown(_ id: UUID, status: ShutdownItem.Status, detail: String) {
        guard let index = shutdownItems.firstIndex(where: { $0.id == id }) else { return }
        shutdownItems[index].status = status
        shutdownItems[index].detail = detail
    }

    /// The user gave up waiting for a stuck server.
    func forceQuit() {
        stopAllImmediately()
        reserver.releaseAll()
        saveSettings()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Ports

    /// Is the port taken by one of our own servers?
    func ownedProfile(forPID pid: Int32) -> ServerProfile? {
        for (id, controller) in servers where controller.processIdentifier == pid {
            return profiles.first { $0.id == id }
        }
        return nil
    }

    func refreshPorts() async {
        guard !isScanningPorts else { return }
        isScanningPorts = true
        portEntries = await PortScanner.scan(includeUDP: settings.portsIncludeUDP)
        isScanningPorts = false
    }

    func killPort(_ entry: PortEntry, signal: KillSignal) async {
        let result = await PortScanner.kill(pid: entry.pid, signal: signal)
        if result.succeeded {
            notify(String(localized: "Process \(entry.command) (PID \(String(entry.pid))) terminated."))
        } else {
            let needsAdmin = result.combined.lowercased().contains("not permitted")
            notify(needsAdmin
                   ? String(localized: "Not enough permissions to terminate \(entry.command) (PID \(String(entry.pid))). Try “Terminate as administrator”.")
                   : String(localized: "Could not terminate the process: \(result.combined)"),
                   isError: true)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshPorts()
    }

    func killPortAsAdmin(_ entry: PortEntry, signal: KillSignal) async {
        let result = await PortScanner.killAsAdmin(pid: entry.pid, signal: signal)
        notify(result.succeeded
               ? String(localized: "Process \(String(entry.pid)) terminated with administrator rights.")
               : String(localized: "Failed: \(result.combined)"),
               isError: !result.succeeded)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshPorts()
    }

    func startPortAutoRefresh() {
        portTimer?.invalidate()
        guard settings.portsAutoRefresh else { return }
        portTimer = Timer.scheduledTimer(withTimeInterval: max(2, settings.portsRefreshInterval),
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.section == .ports else { return }
                await self.refreshPorts()
            }
        }
    }

    func stopPortAutoRefresh() {
        portTimer?.invalidate()
        portTimer = nil
    }

    // MARK: - Notifications

    func notify(_ text: String, isError: Bool = false) {
        banner = Banner(text: text, isError: isError)
        let current = banner?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.banner?.id == current { self.banner = nil }
        }
    }

    // MARK: - Storage

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            settings = decoded
        }

        if let data = try? Data(contentsOf: AppPaths.profilesFile),
           let decoded = try? decoder.decode([ServerProfile].self, from: data) {
            profiles = decoded
        }

        // Settings saved before these fields existed arrive empty.
        let defaults = AppSettings()
        var migrated = false
        if settings.updateRepository.isEmpty { settings.updateRepository = defaults.updateRepository; migrated = true }
        if settings.updateVersionFile.isEmpty { settings.updateVersionFile = defaults.updateVersionFile; migrated = true }
        if settings.updateBuildsFolder.isEmpty { settings.updateBuildsFolder = defaults.updateBuildsFolder; migrated = true }
        if migrated { saveSettings() }

        if profiles.isEmpty {
            profiles = Self.seedProfiles()
            settings.defaultProfileID = profiles.first?.id
            saveProfiles()
            saveSettings()
        }
    }

    func saveProfiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: AppPaths.profilesFile, options: .atomic)
            // Remember our own write, or the watcher would read it back as a
            // change from outside and announce it.
            profilesFileStamp = profilesFileModified()
        }
    }

    func saveSettings() {
        settings.lastSection = section.rawValue
        settings.lastSelectedProfileID = selectedProfileID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(settings) {
            try? data.write(to: AppPaths.settingsFile, options: .atomic)
        }
        ShellEnvironment.shared.setExtraEntries(settings.extraPATHEntries)
        if updates.repository != settings.updateRepository {
            updates.repository = settings.updateRepository
        }
        updates.versionFile = settings.updateVersionFile
        updates.buildsFolder = settings.updateBuildsFolder
    }

    func revealSupportFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.support.path)
    }

    func resetSettings() {
        let keepDefault = settings.defaultProfileID
        settings = AppSettings()
        settings.defaultProfileID = keepDefault
        saveSettings()
        notify(String(localized: "Settings reset to defaults."))
    }

    // MARK: - Starter profiles

    /// One neutral profile so the application does not open empty.
    private static func seedProfiles() -> [ServerProfile] {
        var sites = ServerProfile()
        sites.name = String(localized: "Local static site")
        sites.engine = .httpServer
        sites.host = "127.0.0.1"
        sites.port = 8080
        sites.rootPath = NSHomeDirectory() + "/Sites"
        sites.enableCORS = true
        return [sites]
    }
}
