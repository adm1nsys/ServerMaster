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

    let dependencies: DependencyChecker
    let updates = UpdateChecker()
    let database: DatabaseService
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
    /// Mirrors the Windows first-run choice. It is calculated before `load()`
    /// writes the harmless starter profile, so an entirely new installation
    /// still gets a useful choice instead of silently receiving a preset.
    private(set) var needsFirstSetup = false

    // MARK: Shutdown
    nonisolated struct ShutdownItem: Identifiable, Sendable {
        enum Status: Equatable, Sendable { case waiting, stopping, stopped, forced, failed }
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
    /// A crashing process must not turn “restart on crash” into an infinite
    /// launch loop. This mirrors the Windows policy: 1/2/4 second backoff and
    /// at most three automatic attempts in one minute.
    private var crashRestartTasks: [UUID: Task<Void, Never>] = [:]
    private var crashRestartAttempts: [UUID: [Date]] = [:]
    private var startRequests: [UUID: UUID] = [:]
    private(set) var recipePreparations: [UUID: RecipePreparation] = [:]
    @ObservationIgnored private var recipeTasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private let recipeRunner: RecipePreparation.Runner
    var isPreparingProjects: Bool { recipePreparations.values.contains { $0.isWorking } }
    private(set) var isCleaningLogs = false
    @ObservationIgnored private var logCleanupTask: Task<LogRetention.Result, Never>?
    var logsDirectory: URL { applicationStore.directory.appendingPathComponent("Logs", isDirectory: true) }
    private(set) var stoppingAll = false
    private(set) var stopAllErrors: [String] = []
    private(set) var scheduledBackupInProgress = false
    private(set) var restoreInProgress = false

    var backupOperationInProgress: Bool {
        restoreInProgress || scheduledBackupInProgress || (snapshotStore?.isWorking ?? false)
    }

    var canStopAllServers: Bool {
        activeCount > 0 || !crashRestartTasks.isEmpty || !startRequests.isEmpty || servers.values.contains { $0.state.isActive || $0.state == .stopping || $0.stopFailure != nil }
    }

    /// Reserve the restore barrier before awaiting stop; all launch entry points
    /// use startServer, including menu bar, widget and automatic recovery.
    func restoreSnapshot(_ snapshot: Snapshot, parts: Set<SnapshotStore.RestoreOption>,
                         into profile: ServerProfile) async -> (profile: ServerProfile, problems: [String]) {
        guard !backupOperationInProgress, !isShuttingDown, !stoppingAll else {
            return (profile, [String(localized: "Wait for the current backup operation to finish.")])
        }
        guard let batch = snapshots.beginBatch() else {
            return (profile, [String(localized: "Wait for the current backup operation to finish.")])
        }
        restoreInProgress = true
        defer { restoreInProgress = false; snapshots.endBatch(batch) }
        let stopErrors = await stopAll()
        guard stopErrors.isEmpty else { return (profile, stopErrors) }
        guard !isShuttingDown, !Task.isCancelled else {
            return (profile, [String(localized: "The operation was cancelled.")])
        }
        return await snapshots.restore(snapshot, parts: parts, into: profile, database: database, batch: batch)
    }

    func restoreDatabaseSnapshot(_ snapshot: Snapshot) async -> String? {
        guard !backupOperationInProgress, !isShuttingDown, !stoppingAll else {
            return String(localized: "Wait for the current backup operation to finish.")
        }
        guard let batch = snapshots.beginBatch() else {
            return String(localized: "Wait for the current backup operation to finish.")
        }
        restoreInProgress = true
        defer { restoreInProgress = false; snapshots.endBatch(batch) }
        let stopErrors = await stopAll()
        guard stopErrors.isEmpty else { return stopErrors.joined(separator: "\n") }
        guard !isShuttingDown, !Task.isCancelled else { return String(localized: "The operation was cancelled.") }
        return await snapshots.restoreDatabase(snapshot, database: database, batch: batch)
    }

    @discardableResult
    func setBackupDestination(_ path: String) -> Bool {
        let previousDestination = snapshots.destinationPath
        guard !backupOperationInProgress, !stoppingAll, !isShuttingDown, snapshots.setDestination(path) else {
            notify(String(localized: "Wait for the current backup operation to finish."), isError: true)
            return false
        }
        var updated = settings
        updated.backupDestination = path
        do { try applicationStore.save(updated, to: applicationStore.settingsFile) }
        catch {
            _ = snapshots.setDestination(previousDestination)
            notify(error.localizedDescription, isError: true)
            return false
        }
        settings.backupDestination = path
        return true
    }

    private let applicationStore: ApplicationStore
    private let integrationsEnabled: Bool
    private var bootstrapTask: Task<Void, Never>?
    private let environmentStartup = StartupWork()
    private let dependencyStartup = StartupWork()
    private let certificateStartup = StartupWork()
    private let updateStartup = StartupWork()

    /// A supplied storage directory is an isolated workspace: no shared widget /
    /// CLI registry or process environment writes. Used by lifecycle regression tests.
    init(applicationDirectory: URL? = nil, dependencies: DependencyChecker? = nil, database: DatabaseService? = nil,
         recipeRunner: RecipePreparation.Runner? = nil) {
        self.recipeRunner = recipeRunner ?? { template, profile, database, log, runtime in
            try await WebToPrintRecipe.prepare(template: template, profile: profile, database: database, log: log, runtime: runtime)
        }
        self.dependencies = dependencies ?? DependencyChecker()
        self.database = database ?? DatabaseService()
        applicationStore = ApplicationStore(directory: applicationDirectory ?? AppPaths.support)
        integrationsEnabled = applicationDirectory == nil
        load()
        if integrationsEnabled {
            ShellEnvironment.shared.setExtraEntries(settings.extraPATHEntries)
            applyNodeEnvironment()
        } else if let applicationDirectory {
            snapshotStore = SnapshotStore(destination: settings.backupDestination.isEmpty
                ? applicationDirectory.appendingPathComponent("Backups").path : settings.backupDestination)
        }

        if settings.restoreLastSection,
           let restored = SidebarSection(rawValue: settings.lastSection) {
            section = restored
        }
        selectedProfileID = [settings.lastSelectedProfileID, settings.defaultProfileID, profiles.first?.id]
            .compactMap { $0 }.first { id in profiles.contains { $0.id == id } }

        shell.setDirectory(selectedProfile?.effectiveWorkingDirectory ?? NSHomeDirectory())
        updates.repository = settings.updateRepository
        updates.versionFile = settings.updateVersionFile
    }

    func completeFirstSetup() {
        do {
            try applicationStore.finishFirstSetup()
        } catch { notify(error.localizedDescription, isError: true) }
        needsFirstSetup = false
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
        if let bootstrapTask { await bootstrapTask.value; return }
        let task = Task { @MainActor in await self.performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        let budget = StartupBudget()
        func stage(_ text: String, _ progress: Double) async {
            bootstrapStage = text
            bootstrapProgress = progress
            // Let the frame draw, otherwise the steps flash by unnoticed.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        await stage(String(localized: "Reading the environment…"), 0.15)
        _ = await environmentStartup.run(wait: budget.remaining(upTo: 3)) { await ShellEnvironment.shared.refresh() }
        templates.load()
        commandLineTool.refresh()
        adoptExternalServers()
        startWatchingProfilesFile()
        startWatchingBrowserRequests()
        startBackupSchedule()
        publishStatus()

        if settings.checkDependenciesOnLaunch {
            await stage(String(localized: "Checking dependencies…"), 0.35)
            _ = await dependencyStartup.run(wait: budget.remaining(upTo: 30)) { await self.dependencies.checkAll() }
        }

        await stage(String(localized: "Looking for forgotten servers…"), 0.6)
        reclaimPrivilegedServers()

        pruneRuntimeDirectories()
        await cleanOldLogs()

        await stage(String(localized: "Reading certificates…"), 0.7)
        _ = await certificateStartup.run(wait: budget.remaining(upTo: 10)) {
            await self.certificates.reload()
            await self.certificates.refreshMkcertStatus()
        }

        if settings.checkUpdatesOnLaunch && updates.isConfigured {
            await stage(String(localized: "Checking for updates…"), 0.85)
            _ = await updateStartup.run(wait: budget.remaining(upTo: 20)) { await self.checkForUpdates(silently: true) }
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

    @discardableResult
    func addProfile(_ profile: ServerProfile, completingFirstSetup: Bool = true) -> Bool {
        let previousSelection = selectedProfileID
        profiles.append(profile)
        selectedProfileID = profile.id
        guard saveProfiles() else {
            profiles.removeAll { $0.id == profile.id }
            selectedProfileID = previousSelection
            return false
        }
        if completingFirstSetup && needsFirstSetup { completeFirstSetup() }
        return true
    }

    func updateProfile(_ profile: ServerProfile) {
        guard recipeTasks[profile.id] == nil else {
            notify(String(localized: "Wait for project preparation to finish."), isError: true)
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        // The editor sends an edit on every keystroke — write to disk with a delay.
        scheduleProfilesSave()
    }

    func importProfiles(from url: URL) {
        do {
            let incoming = ProfileTransfer.appending(try ProfileTransfer.read(url), to: profiles)
            let previous = profiles
            let previousSelection = selectedProfileID
            profiles.append(contentsOf: incoming)
            selectedProfileID = incoming.first?.id
            guard saveProfiles() else {
                profiles = previous; selectedProfileID = previousSelection
                return
            }
            if needsFirstSetup { completeFirstSetup() }
            notify(String(localized: "Imported \(incoming.count) profiles. Review paths and commands before starting."))
        } catch { notify(error.localizedDescription, isError: true) }
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
        guard recipeTasks[profile.id] == nil else {
            notify(String(localized: "Wait for project preparation to finish."), isError: true)
            return
        }
        cancelCrashRestart(for: profile.id)
        startRequests.removeValue(forKey: profile.id)
        // Order matters. Stop the server first: otherwise the process is orphaned,
        // keeps holding the port, and the interface can no longer reach it.
        // Only then remove the working files — otherwise we would rip the config
        // out from under a still-running nginx.
        if let controller = servers[profile.id] {
            controller.stopImmediately()
            guard controller.processIdentifier == nil, !controller.isPrivileged else {
                notify(controller.stopFailure ?? String(localized: "Could not stop the server. Check Console and Ports."), isError: true)
                return
            }
        }
        runningOrder.removeAll { $0 == profile.id }
        publishStatus()
        servers[profile.id] = nil
        recipePreparations.removeValue(forKey: profile.id)
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
        let runtime = applicationStore.directory.appendingPathComponent("Runtime", isDirectory: true)
        for prefix in ["nginx", "caddy", "php", "root"] {
            let path = runtime.appendingPathComponent("\(prefix)-\(key)", isDirectory: true)
            try? FileManager.default.removeItem(at: path)
        }
    }

    func suggestedProfilePort(startingAt preferred: Int = 8080, host: String = "127.0.0.1") -> Int? {
        var excluded = Set(profiles.map(\.port) + reserver.reservations.map(\.port))
        excluded.formUnion([database.port, settings.databaseAdminPort])
        if integrationsEnabled { excluded.formUnion(RunRegistry.all().map(\.port)) }
        return PortScanner.availablePort(startingAt: preferred, excluding: excluded, host: host)
    }

    func isProfilePortAvailable(_ port: Int, host: String = "127.0.0.1") -> Bool {
        !profiles.contains { $0.port == port } && !reserver.isReserved(port)
            && port != database.port && port != settings.databaseAdminPort
            && PortScanner.isPortFree(port, host: host)
    }

    @discardableResult
    func duplicateProfile(_ profile: ServerProfile) -> Bool {
        var copy = profile.duplicated()
        let preferred = (1024..<65535).contains(profile.port) ? profile.port + 1 : 8080
        guard let port = suggestedProfilePort(startingAt: preferred, host: profile.host) else {
            notify(String(localized: "No free profile port was found. Release a port and try again."), isError: true)
            return false
        }
        copy.port = port
        return addProfile(copy)
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
        let controller = ServerController(runtimeRoot: integrationsEnabled ? nil : applicationStore.directory.appendingPathComponent("Runtime"))
        controller.onUnexpectedExit = { [weak self] profile, code in
            guard let self else { return }
            self.notify(String(localized: "Server “\(profile.name)” exited unexpectedly (code \(String(code)))."), isError: true)
            self.runningOrder.removeAll { $0 == profile.id }
            self.publishStatus()
            self.scheduleCrashRestart(for: profile)
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

    /// A stop error still needs an accessible Stop action, even after the
    /// original process exited and another listener took its endpoint.
    func canStopServer(_ profileID: UUID) -> Bool {
        guard let controller = servers[profileID] else { return false }
        return controller.state.isActive || controller.state.isBusy || controller.processIdentifier != nil || controller.stopFailure != nil
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
        guard integrationsEnabled else { return }
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
        guard settings.backupsEnabled, settings.backupEvery > 0,
              !backupOperationInProgress, !isShuttingDown else { return }
        guard let batch = snapshots.beginBatch() else { return }
        scheduledBackupInProgress = true
        defer { scheduledBackupInProgress = false; snapshots.endBatch(batch) }
        let gap = Double(settings.backupEvery) * settings.backupUnit.seconds
        if let last = settings.lastBackup, Date().timeIntervalSince(last) < gap { return }

        let wanted = settings.backupProfileIDs.isEmpty
            ? profiles
            : profiles.filter { settings.backupProfileIDs.contains($0.id) }
        guard !wanted.isEmpty || settings.backupAllDatabases else { return }

        var completed = true
        var created = false
        for profile in wanted {
            let snapshot = await snapshots.take(profile: profile,
                                                database: settings.backupIncludesDatabase ? database : nil,
                                                trigger: .scheduled, batch: batch)
            created = created || snapshot != nil
            completed = completed && snapshot != nil && snapshots.lastError == nil
        }
        if settings.backupAllDatabases {
            guard database.state == .running else {
                notify(String(localized: "Database not included: MariaDB was stopped."), isError: true)
                return
            }
            guard await database.reloadDatabases() else { return }
            for item in database.databases {
                let snapshot = await snapshots.takeDatabase(named: item.name, database: database, trigger: .scheduled, batch: batch)
                created = created || snapshot != nil
                completed = completed && snapshot != nil && snapshots.lastError == nil
            }
        }
        // A failed batch must not prune good backups or move the success time.
        guard completed, created, !Task.isCancelled, !isShuttingDown else { return }
        snapshots.endBatch(batch)
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
        guard !isShuttingDown, !stoppingAll, !Task.isCancelled,
              profiles.contains(where: { $0.id == profile.id }),
              startRequests[profile.id] == nil else { return }
        guard !isPreparingProjects else {
            notify(String(localized: "Wait for project preparation to finish."), isError: true)
            return
        }
        guard !backupOperationInProgress else {
            notify(String(localized: "Wait for the current backup operation to finish."), isError: true)
            return
        }
        let request = UUID()
        startRequests[profile.id] = request
        defer {
            if startRequests[profile.id] == request { startRequests.removeValue(forKey: profile.id) }
        }
        if !profile.validationErrors.isEmpty {
            let controller = controller(for: profile.id)
            await controller.start(profile: profile, settings: settings)
            if case .failed(let message) = controller.state { notify(message, isError: true) }
            return
        }
        guard !dependencies.isManagingPackages else {
            notify(String(localized: "Wait for the current dependency operation to finish."), isError: true)
            return
        }
        if reserver.isReserved(profile.port) {
            notify(String(localized: "Port \(String(profile.port)) is reserved inside the app. Release the reservation before starting."), isError: true)
            return
        }
        // Do not let two profiles take the same port.
        if let conflict = activeProfiles.first(where: { $0.id != profile.id && $0.port == profile.port }) {
            notify(String(localized: "Port \(String(profile.port)) is already used by the profile “\(conflict.name)”."), isError: true)
            return
        }

        if profile.needsDatabase, database.state != .running {
            while database.state.isBusy {
                guard startRequests[profile.id] == request, !isShuttingDown, !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard startRequests[profile.id] == request, !isShuttingDown, !Task.isCancelled else { return }
            if database.state != .running { await database.start() }
            guard startRequests[profile.id] == request, !isShuttingDown, !Task.isCancelled else { return }
            guard database.state == .running else {
                let detail: String
                if case .failed(let message) = database.state { detail = message }
                else { detail = String(localized: "The database server is not running.") }
                let message = String(localized: "The database did not start: \(detail)")
                controller(for: profile.id).failToStart(profile: profile, message: message)
                notify(message, isError: true)
                publishStatus()
                return
            }
        }

        guard startRequests[profile.id] == request, !isShuttingDown,
              !backupOperationInProgress, !Task.isCancelled,
              profiles.contains(where: { $0.id == profile.id }) else { return }
        let controller = controller(for: profile.id)
        guard !controller.state.isActive, controller.state != .stopping else { return }

        if !runningOrder.contains(profile.id) { runningOrder.append(profile.id) }
        await controller.start(profile: profile, settings: settings)

        guard startRequests[profile.id] == request, !isShuttingDown,
              profiles.contains(where: { $0.id == profile.id }) else { return }
        if case .failed(let message) = controller.state {
            runningOrder.removeAll { $0 == profile.id }
            notify(message, isError: true)
        } else if integrationsEnabled, let pid = controller.processIdentifier {
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

    @discardableResult
    func stopServer(profileID: UUID) async -> Bool {
        startRequests.removeValue(forKey: profileID)
        cancelCrashRestart(for: profileID)
        guard let controller = servers[profileID],
              controller.state.isActive || controller.state.isBusy || controller.processIdentifier != nil || controller.stopFailure != nil else {
            if integrationsEnabled, let record = RunRegistry.find(profileID: profileID) {
                let result = await RunRegistry.stop(record)
                if case .refused(let message) = result {
                    if !stoppingAll { notify(message, isError: true) }
                    return false
                }
                runningOrder.removeAll { $0 == profileID }
                publishStatus()
            }
            return true
        }
        let stopped = await controller.stop(settings: settings)
        if stopped || controller.processIdentifier == nil {
            if integrationsEnabled { RunRegistry.forget(profileID) }
            runningOrder.removeAll { $0 == profileID }
        }
        if !stopped, !stoppingAll, let message = controller.stopFailure { notify(message, isError: true) }
        publishStatus()
        return stopped
    }

    func restartServer(profile: ServerProfile) async {
        cancelCrashRestart(for: profile.id)
        guard await stopServer(profileID: profile.id), !stoppingAll, !isShuttingDown else { return }
        let request = UUID()
        startRequests[profile.id] = request
        try? await Task.sleep(for: .milliseconds(400))
        guard startRequests[profile.id] == request, !Task.isCancelled else { return }
        startRequests.removeValue(forKey: profile.id)
        await startServer(profile: profile)
    }

    @discardableResult
    func stopAll() async -> [String] {
        if stoppingAll {
            while stoppingAll {
                guard !Task.isCancelled else { return [String(localized: "The operation was cancelled.")] }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return stopAllErrors
        }
        stoppingAll = true
        stopAllErrors = []
        defer { stoppingAll = false }
        cancelAllCrashRestarts()
        let ids = Set(runningOrder + Array(startRequests.keys) + Array(servers.keys))
        startRequests.removeAll()
        for id in ids {
            if !(await stopServer(profileID: id)) {
                let name = profiles.first { $0.id == id }?.name ?? id.uuidString
                let message = servers[id]?.stopFailure ?? String(localized: "Could not stop the server. Check Console and Ports.")
                stopAllErrors.append("\(name): \(message)")
            }
        }
        if !stopAllErrors.isEmpty { notify(stopAllErrors.joined(separator: "\n"), isError: true) }
        return stopAllErrors
    }

    private func cancelAllCrashRestarts() {
        for task in crashRestartTasks.values { task.cancel() }
        crashRestartTasks.removeAll()
        crashRestartAttempts.removeAll()
    }

    private func scheduleCrashRestart(for profile: ServerProfile) {
        guard !isShuttingDown, !backupOperationInProgress,
              profiles.contains(where: { $0.id == profile.id }),
              settings.restartOnCrash, crashRestartTasks[profile.id] == nil else { return }
        let now = Date()
        let recent = (crashRestartAttempts[profile.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 3 else {
            crashRestartAttempts[profile.id] = recent
            notify(String(localized: "Automatic restart paused for “\(profile.name)” after 3 crashes in one minute. Check Console and start it manually."), isError: true)
            return
        }
        let delay = TimeInterval(1 << recent.count)
        crashRestartAttempts[profile.id] = recent + [now]
        notify(String(localized: "Server “\(profile.name)” exited unexpectedly. Restarting in \(String(Int(delay))) seconds…"), isError: true)
        crashRestartTasks[profile.id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            self.crashRestartTasks.removeValue(forKey: profile.id)
            guard !Task.isCancelled, !self.isShuttingDown, !self.backupOperationInProgress,
                  self.profiles.contains(where: { $0.id == profile.id }),
                  self.settings.restartOnCrash,
                  self.state(of: profile.id) == .stopped || {
                      if case .failed = self.state(of: profile.id) { return true }
                      return false
                  }()
            else { return }
            await self.startServer(profile: profile)
        }
    }

    private func cancelCrashRestart(for profileID: UUID) {
        crashRestartTasks.removeValue(forKey: profileID)?.cancel()
        crashRestartAttempts.removeValue(forKey: profileID)
    }

    /// Synchronous shutdown of every server when the application quits.
    func stopAllImmediately() {
        isShuttingDown = true
        cancelAllCrashRestarts()
        startRequests.removeAll()
        flushPendingSaves()
        for tab in terminals { tab.session.terminate() }
        for controller in servers.values { controller.stopImmediately() }
        if integrationsEnabled { for id in runningOrder { RunRegistry.forget(id) } }
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
        let runtime = applicationStore.directory.appendingPathComponent("Runtime", isDirectory: true)
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

    /// Shared by startup and Settings. Disk traversal runs away from the UI;
    /// concurrent callers join the same cleanup rather than racing deletions.
    @discardableResult
    func cleanOldLogs(showNotification: Bool = false) async -> LogRetention.Result {
        let result: LogRetention.Result
        if let logCleanupTask {
            result = await logCleanupTask.value
        } else {
            isCleaningLogs = true
            let directory = logsDirectory
            let days = settings.logRetentionDays
            let logs = Array(servers.values.map(\.log)) + [shell.log, installLog, database.log]
                + recipePreparations.values.map(\.log)
            let active = Set(logs.filter(\.isFileLogging).compactMap(\.fileURL))
            let task = Task.detached(priority: .utility) {
                LogRetention.clean(directory: directory, days: days, activeFiles: active)
            }
            logCleanupTask = task
            result = await task.value
            logCleanupTask = nil
            isCleaningLogs = false
            if result.removed > 0 {
                shell.log.system(String(localized: "Old log files removed: \(String(result.removed))"))
            }
            if result.failureCount > 0 {
                shell.log.system(String(localized: "Log cleanup failures: \(String(result.failureCount))"))
                for problem in result.problems { shell.log.system(problem) }
            }
        }
        if result.failureCount > 0 {
            notify(String(localized: "Logs removed: \(String(result.removed)). Cleanup failures: \(String(result.failureCount)). See the console for details."), isError: true)
        } else if showNotification {
            if result.disabled { notify(String(localized: "Log cleanup is disabled. Set a retention period above zero.")) }
            else if result.removed == 0 { notify(String(localized: "No old logs found.")) }
            else { notify(String(localized: "Old log files removed: \(String(result.removed))")) }
        }
        return result
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
        guard !updates.state.isChecking else { return }
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
        guard !dependencies.isManagingPackages else {
            notify(String(localized: "Wait for the current dependency operation to finish."), isError: true)
            return
        }
        await database.start()
        defer { publishStatus() }
        if case .failed(let message) = database.state {
            notify(message, isError: true)
        }
    }

    func stopDatabase() async {
        guard !isPreparingProjects else {
            notify(String(localized: "Wait for project preparation to finish."), isError: true)
            return
        }
        // The panel serves this database and must not outlive it.
        adminPanel.stop()
        await database.stop()
        publishStatus()
    }

    /// Brings the database up if needed and creates the database a new profile
    /// asked for, so the person can go straight to the CMS installer.
    @discardableResult
    func prepareDatabase(named name: String, for profile: ServerProfile, password: String? = nil) async -> Bool {
        guard !Task.isCancelled, !isShuttingDown else { return false }
        if let password, password.isEmpty {
            notify(String(localized: "Enter a database password or generate one."), isError: true)
            return false
        }
        guard !dependencies.isManagingPackages else {
            notify(String(localized: "Wait for the current dependency operation to finish."), isError: true)
            return false
        }
        while database.state.isBusy {
            guard !Task.isCancelled, !isShuttingDown else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, !isShuttingDown else { return false }
        if database.state != .running { await database.start() }
        guard database.state == .running else {
            notify(String(localized: "The database did not start; create it later on the Database screen."),
                   isError: true)
            return false
        }
        if database.databases.contains(where: { $0.name == name }) {
            notify(String(localized: "Database “\(name)” already exists — use it in the installer."))
            return true
        }
        // One account per database, named after it: a CMS installer wants a user
        // and a password, and reusing root would tie every site together.
        let result = await database.createDatabase(name: name,
                                                   user: name,
                                                   password: password ?? DatabaseAdminPanel.generatedPassword(length: 16))
        if result.succeeded {
            notify(String(localized: "Database “\(name)” is ready for “\(profile.name)”."))
        } else {
            notify(result.stderr.isEmpty ? String(localized: "Could not create the database.") : result.stderr,
                   isError: true)
        }
        return result.succeeded
    }

    func recipeTemplate(for profile: ServerProfile) -> ProfileTemplate? {
        if let template = templates.all.first(where: { $0.id == profile.templateId && RecipePreparation.supports($0) }) { return template }
        if let previous = recipePreparations[profile.id]?.template,
           previous.id == profile.templateId { return previous }
        return nil
    }

    private func projectHasRunningServer(_ profile: ServerProfile) -> Bool {
        let root = URL(fileURLWithPath: AppPaths.expand(profile.rootPath)).resolvingSymlinksInPath().path
        let isSameProject: (ServerProfile) -> Bool = {
            let path = $0.rootPath.isEmpty ? $0.effectiveWorkingDirectory : AppPaths.expand($0.rootPath)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == root
        }
        if servers.values.contains(where: { server in
            (server.state.isActive || server.state.isBusy || server.processIdentifier != nil)
                && server.activeProfile.map(isSameProject) == true
        }) { return true }
        if integrationsEnabled {
            let running = Set(RunRegistry.all().map(\.id))
            return profiles.contains { running.contains($0.id.uuidString) && isSameProject($0) }
        }
        return false
    }

    /// One task per saved profile; repeated UI requests join the same attempt.
    @discardableResult
    func prepareProjectRecipe(_ template: ProfileTemplate, profileID: UUID, databasePassword: String? = nil) async -> Bool {
        if let existing = recipeTasks[profileID] { return await existing.value }
        guard let profile = profiles.first(where: { $0.id == profileID }),
              RecipePreparation.supports(template), template.id == profile.templateId else { return false }
        guard !isShuttingDown, !stoppingAll, startRequests.isEmpty,
              !backupOperationInProgress, !dependencies.isManagingPackages, !dependencies.isChecking else {
            notify(String(localized: "Wait for the current operation before preparing this project."), isError: true)
            return false
        }
        guard !projectHasRunningServer(profile) else {
            notify(String(localized: "Stop all servers using this project folder before preparing it."), isError: true)
            return false
        }
        let operation = recipePreparations[profileID] ?? RecipePreparation(template: template)
        recipePreparations[profileID] = operation
        operation.log.limit = settings.consoleBufferLines
        operation.begin(template: template)
        let task = Task { @MainActor in
            defer { self.recipeTasks.removeValue(forKey: profileID) }
            do {
                try await self.dependencies.managePackages {
                    guard !self.isShuttingDown, !self.projectHasRunningServer(profile),
                          let batch = self.snapshots.beginBatch() else {
                        throw RuntimePackages.Failure(message: String(localized: "Wait for the current operation before preparing this project."))
                    }
                    defer { self.snapshots.endBatch(batch) }
                    var runtime = WebToPrintRecipe.Runtime()
                    runtime.toolsDirectory = self.applicationStore.directory.appendingPathComponent("Tools")
                    runtime.privateDirectory = self.applicationStore.directory.appendingPathComponent("RecipeCredentials")
                    runtime.databasePassword = databasePassword
                    runtime.progress = { step in operation.advance(step) }
                    let outcome = try await self.recipeRunner(template, profile, self.database, operation.log, runtime)
                    guard let index = self.profiles.firstIndex(where: { $0.id == profileID }),
                          self.profiles[index] == profile else {
                        throw RuntimePackages.Failure(message: String(localized: "The profile changed during preparation. Project files were kept; review the saved profile before retrying."))
                    }
                    if let name = outcome.databaseName {
                        self.profiles[index].databaseName = name
                        guard self.saveProfiles() else {
                            self.profiles[index] = profile
                            throw RuntimePackages.Failure(message: String(localized: "The project was prepared, but its profile could not be saved. Fix the data folder permissions and retry."))
                        }
                    }
                }
                operation.finish()
                let message = String(localized: "Project “\(profile.name)” is prepared. Open its profile to start it.")
                self.installLog.system(message)
                self.notify(message)
                return true
            } catch {
                operation.fail(error.localizedDescription)
                self.installLog.append("\(profile.name): \(error.localizedDescription)", stream: .stderr)
                self.notify(String(localized: "Project preparation did not finish: \(error.localizedDescription)"), isError: true)
                return false
            }
        }
        recipeTasks[profileID] = task
        return await task.value
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
        isPreparingProjects || (settings.stopServerOnQuit && (canStopAllServers || database.state.isActive))
    }

    /// Stops the servers one by one, showing progress,
    /// and only then lets the application go.
    func beginShutdown(completion: @escaping () -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelAllCrashRestarts()
        startRequests.removeAll()
        shutdownTookTooLong = false

        let running = profiles.filter { profile in
            isActive(profile.id) || servers[profile.id]?.state == .stopping || servers[profile.id]?.stopFailure != nil
        }
        shutdownItems = running.map { ShutdownItem(id: $0.id, name: $0.name) }
        shutdownProgress = 0

        // If something hangs — offer to force quit.
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.isShuttingDown else { return }
            self.shutdownTookTooLong = true
        }

        Task { @MainActor in
            let preparations = Array(self.recipeTasks.values)
            for preparation in preparations { _ = await preparation.value }
            if !self.settings.stopServerOnQuit {
                self.flushPendingSaves()
                self.saveSettings()
                timeout.cancel()
                completion()
                return
            }
            self.adminPanel.stop()
            for (index, profile) in running.enumerated() {
                self.updateShutdown(profile.id, status: .stopping,
                                    detail: String(localized: "stopping…"))

                let controller = self.servers[profile.id]
                let wasPrivileged = controller?.isPrivileged ?? false
                let stopped = await self.stopServer(profileID: profile.id)
                self.updateShutdown(profile.id,
                                    status: stopped ? .stopped : .failed,
                                    detail: stopped
                                        ? (wasPrivileged ? String(localized: "stopped (root)") : String(localized: "stopped"))
                                        : (controller?.stopFailure ?? String(localized: "Could not stop the server. Check Console and Ports.")))
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

            if self.shutdownItems.contains(where: { $0.status == .failed }) {
                self.shutdownTookTooLong = true
                return
            }

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
        let result = await PortScanner.terminate(entry, signal: signal)
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
        let result = await PortScanner.terminate(entry, signal: signal, asAdministrator: true)
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
        let loaded = applicationStore.load(starter: Self.seedProfiles)
        settings = loaded.settings
        profiles = loaded.profiles
        needsFirstSetup = loaded.needsFirstSetup
        if !loaded.errors.isEmpty { banner = Banner(text: loaded.errors.joined(separator: "\n"), isError: true) }
    }

    @discardableResult
    func saveProfiles() -> Bool {
        do {
            try applicationStore.save(profiles, to: applicationStore.profilesFile)
            profilesFileStamp = profilesFileModified()
            return true
        } catch { notify(error.localizedDescription, isError: true); return false }
    }

    func saveSettings() {
        settings.lastSection = section.rawValue
        settings.lastSelectedProfileID = selectedProfileID
        do { try applicationStore.save(settings, to: applicationStore.settingsFile) }
        catch { notify(error.localizedDescription, isError: true) }
        if integrationsEnabled {
            ShellEnvironment.shared.setExtraEntries(settings.extraPATHEntries)
            applyNodeEnvironment()
        }
        if updates.repository != settings.updateRepository {
            updates.repository = settings.updateRepository
        }
        updates.versionFile = settings.updateVersionFile
    }

    private func applyNodeEnvironment() {
        let version = settings.managedNodeVersion
        let directory = NodeReleases.validVersion(version)
            ? NodeReleases.defaultRoot.appendingPathComponent(version + "/bin").path : nil
        ShellEnvironment.shared.setManagedNodeDirectory(directory)
    }

    func installMissingRequirements(for profile: ServerProfile, template: ProfileTemplate? = nil) async throws {
        try await dependencies.installMissing(for: profile,
            template: template ?? templates.all.first { $0.id == profile.templateId },
            log: installLog, canChange: { self.runtimeChangesAllowed })
    }

    var runtimeChangesAllowed: Bool {
        !isPreparingProjects && !backupOperationInProgress && !isShuttingDown && activeCount == 0 && !servers.values.contains { $0.state == .stopping || $0.processIdentifier != nil }
            && !database.state.isActive && !database.state.isBusy
            && !adminPanel.isRunning && adminPanel.state != .starting
    }

    func selectNodeRelease(_ version: String) async throws {
        try await dependencies.managePackages {
            try await dependencies.nodeReleases.select(version, canChange: { self.runtimeChangesAllowed }, commit: { selected, directory in
                var updated = self.settings
                updated.managedNodeVersion = selected
                // Persist successfully before changing the in-memory selection or PATH.
                try self.applicationStore.save(updated, to: self.applicationStore.settingsFile)
                self.settings = updated
                ShellEnvironment.shared.setManagedNodeDirectory(directory)
            }, log: installLog)
        }
    }

    func removeNodeRelease(_ version: String) async throws {
        try await dependencies.managePackages {
            try dependencies.nodeReleases.remove(version, activeVersion: settings.managedNodeVersion,
                                                   canChange: { self.runtimeChangesAllowed })
        }
    }

    func revealSupportFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.support.path)
    }

    func resetSettings() {
        let keepDefault = settings.defaultProfileID
        let keepNode = settings.managedNodeVersion
        settings = AppSettings()
        if !runtimeChangesAllowed || dependencies.isManagingPackages { settings.managedNodeVersion = keepNode }
        settings.defaultProfileID = keepDefault
        saveSettings()
        notify(String(localized: "Settings reset to defaults."))
    }

    // MARK: - Starter profiles

    /// One neutral profile so the application does not open empty.
    nonisolated private static func seedProfiles() -> [ServerProfile] {
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
