//
//  ServerController.swift
//  ServerMaster
//

import Foundation
import Observation
import AppKit

nonisolated enum ServerState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .stopped:  return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .running:  return String(localized: "Running")
        case .stopping: return String(localized: "Stopping…")
        case .failed:   return String(localized: "Error")
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping }
    var isActive: Bool { self == .running || self == .starting }
}

@Observable
final class ServerController {

    private(set) var state: ServerState = .stopped
    private(set) var stopFailure: String?
    private(set) var activeProfile: ServerProfile?
    private(set) var startedAt: Date?
    private(set) var processIdentifier: Int32?
    private(set) var detectedURLs: [String] = []
    private(set) var lastCommand: String = ""

    let log = ConsoleLog()

    /// Called when the process dies unexpectedly.
    var onUnexpectedExit: ((ServerProfile, Int32) -> Void)?

    private var runID = UUID()
    private var stopInProgress = false
    private var startInProgress = false
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var intentionalStop = false
    private var recentStderr: [String] = []
    private var privileged: PrivilegedSession?
    private var logTail: Process?
    private var watchdog: Task<Void, Never>?
    private var sidecars: [(name: String, process: Process)] = []
    private let runtimeRoot: URL?
    private let startupTimeout: TimeInterval
    private let responseTimeout: TimeInterval
    private var readinessProbe: Task<HTTPStartup.Result, Never>?

    init(runtimeRoot: URL? = nil, startupTimeout: TimeInterval = 20, responseTimeout: TimeInterval = 60) {
        self.runtimeRoot = runtimeRoot
        self.startupTimeout = max(0.1, startupTimeout)
        self.responseTimeout = max(0.1, responseTimeout)
    }

    /// The server was started as root through the system password prompt.
    var isPrivileged: Bool { privileged != nil }

    var uptime: TimeInterval? {
        guard let startedAt, state == .running else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    func failToStart(profile: ServerProfile, message: String) {
        guard !state.isActive, !state.isBusy, processIdentifier == nil else { return }
        activeProfile = profile
        state = .failed(message)
        log.append(message, stream: .stderr)
    }

    // MARK: - Startup

    func start(profile: ServerProfile, settings: AppSettings) async {
        guard !state.isActive, !stopInProgress, !startInProgress, state != .stopping, !Task.isCancelled else { return }
        // A failed stop must retain control of its live process or supervisor.
        guard process?.isRunning != true, privileged == nil else { return }
        stopFailure = nil
        startInProgress = true
        let run = UUID()
        runID = run
        defer {
            startInProgress = false
            if Task.isCancelled, runID == run { stopImmediately() }
        }

        intentionalStop = false
        recentStderr = []
        activeProfile = profile
        detectedURLs = []
        state = .starting
        log.limit = settings.consoleBufferLines

        if settings.writeLogsToFile {
            log.startFileLogging(name: profile.name)
        }

        log.system(String(localized: "──────── Starting profile “\(profile.name)” ────────"))
        log.system(String(localized: "Engine: \(profile.engine.title)"))

        let errors = profile.validationErrors
        guard errors.isEmpty else {
            let message = errors.joined(separator: "\n")
            state = .failed(message)
            log.append(message, stream: .stderr)
            log.stopFileLogging()
            return
        }

        // Port check
        if settings.checkPortBeforeStart {
            let occupants = await PortScanner.processesListening(onPort: profile.port)
            guard runID == run, state == .starting, !Task.isCancelled else { return }
            if !occupants.isEmpty {
                let summary = occupants.map { "\($0.command) (PID \($0.pid))" }.joined(separator: ", ")
                if settings.killPortOccupantOnStart {
                    log.system(String(localized: "Port \(String(profile.port)) is taken: \(summary). Freeing it…"))
                    for occupant in occupants {
                        guard occupant.pid > 0 else { continue }
                        _ = await PortScanner.terminate(occupant, signal: .term)
                        guard runID == run, state == .starting, !Task.isCancelled else { return }
                    }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard runID == run, state == .starting, !Task.isCancelled else { return }
                    guard PortScanner.isPortFree(profile.port, host: profile.host) else {
                        let message = String(localized: "Port \(String(profile.port)) is still occupied. Its owner may require administrator rights; stop that profile or free the port from Ports.")
                        log.append(message, stream: .stderr)
                        state = .failed(message)
                        log.stopFileLogging()
                        return
                    }
                } else {
                    log.append(String(localized: "Port \(String(profile.port)) is already taken: \(summary)"), stream: .stderr)
                    state = .failed(String(localized: "Port \(String(profile.port)) is taken: \(summary)"))
                    log.stopFileLogging()
                    return
                }
            }
        }

        // A readiness probe must not mistake a pre-existing listener for ours,
        // even when the optional interactive occupant check is disabled.
        if profile.engine != .custom, !PortScanner.isPortFree(profile.port, host: profile.host) {
            let message = String(localized: "Port \(String(profile.port)) is already occupied.")
            state = .failed(message)
            log.append(message, stream: .stderr)
            log.stopFileLogging()
            return
        }

        // Building the command
        guard runID == run, state == .starting, !Task.isCancelled else { return }
        let plan: LaunchPlan
        do {
            plan = try LaunchPlanBuilder.build(for: profile, runtimeRoot: runtimeRoot)
        } catch {
            log.append(error.localizedDescription, stream: .stderr)
            state = .failed(error.localizedDescription)
            log.stopFileLogging()
            return
        }

        if let ready = plan.readinessFile {
            try? FileManager.default.removeItem(atPath: ready)
            try? FileManager.default.removeItem(atPath: ready + ".stop")
        }

        // The config, if it is generated
        if let generated = plan.generatedConfig {
            do {
                let url = URL(fileURLWithPath: generated.path)
                AppPaths.ensure(url.deletingLastPathComponent())
                try generated.contents.write(to: url, atomically: true, encoding: .utf8)
                log.system(String(localized: "Config generated: \(generated.path)"))
            } catch {
                log.append(String(localized: "Could not write the config: \(error.localizedDescription)"), stream: .stderr)
                state = .failed(error.localizedDescription)
                log.stopFileLogging()
                return
            }
        }

        // Additional configs (php-fpm, for example) — before the engine starts.
        for file in plan.extraFiles {
            do {
                let url = URL(fileURLWithPath: file.path)
                AppPaths.ensure(url.deletingLastPathComponent())
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
                log.system(String(localized: "Config generated: \(file.path)"))
            } catch {
                log.append(String(localized: "Could not write the config: \(error.localizedDescription)"),
                           stream: .stderr)
                state = .failed(error.localizedDescription)
                log.stopFileLogging()
                return
            }
        }

        // Error pages go next to the config, before the engine starts.
        if let errorDirectory = plan.errorPagesDirectory {
            do {
                let written = try ErrorPages.write(for: profile, into: errorDirectory)
                log.system(String(localized: "Error pages generated: \(written)"))
            } catch {
                log.append(String(localized: "Could not create the error pages: \(error.localizedDescription)"),
                           stream: .stderr)
            }
        }

        lastCommand = plan.displayCommand
        log.system(String(localized: "Command: \(plan.displayCommand)"))
        log.system(String(localized: "Working directory: \(plan.workingDirectory)"))

        // Retain logical reservations until readiness, releasing sockets for children to bind.
        for lease in plan.portLeases { lease.allowChildBind() }

        // Helper processes (php-fpm) are brought up before the main one.
        for sidecar in plan.sidecars {
            guard startSidecar(sidecar) else {
                stopSidecars()
                state = .failed(String(localized: "Could not start \(sidecar.name)."))
                log.stopFileLogging()
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(sidecar.warmup * 1_000_000_000))
            guard runID == run, state == .starting, !Task.isCancelled else { return }
            if let running = sidecars.last?.process, !running.isRunning {
                let message = String(localized: "\(sidecar.name) exited right after start.")
                log.append(message, stream: .stderr)
                stopSidecars()
                state = .failed(Self.explain(base: message, stderr: recentStderr, profile: profile))
                log.stopFileLogging()
                return
            }
        }

        // Ports below 1024 require uid 0 — launch through the system password prompt.
        if profile.runAsAdministrator {
            await startPrivileged(profile: profile, plan: plan, settings: settings, run: run)
            return
        }

        // The process itself
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = ShellEnvironment.shared.environment(extra: plan.environment)
        if FileManager.default.fileExists(atPath: plan.workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory, isDirectory: true)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        attachOutput(outPipe, stream: .stdout, run: run)
        attachOutput(errPipe, stream: .stderr, run: run)

        process.terminationHandler = { [weak self] finished in
            guard let controller = self else { return }
            let code = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in
                guard controller.runID == run, controller.process === finished else { return }
                controller.handleTermination(code: code, reason: reason)
            }
        }

        do {
            try process.run()
        } catch {
            log.append(String(localized: "Could not start the process: \(error.localizedDescription)"), stream: .stderr)
            state = .failed(error.localizedDescription)
            log.stopFileLogging()
            return
        }

        self.process = process
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.processIdentifier = process.processIdentifier
        self.startedAt = Date()

        log.system("PID: \(String(process.processIdentifier))")

        // Give the process a chance to fail immediately (port taken, broken config and so on).
        let ready = await waitForReadiness(plan: plan, profile: profile, run: run) { process.isRunning }

        guard runID == run, state == .starting, !Task.isCancelled else { return }

        if !ready && process.isRunning {
            await stop(settings: settings)
            state = .failed(String(localized: "Server did not become ready. Check the server and backend log."))
            return
        }

        if process.isRunning {
            state = .running
            if detectedURLs.isEmpty, let url = profile.primaryURL {
                detectedURLs = [url.absoluteString]
            }
            log.system(String(localized: "Server is up: \(detectedURLs.joined(separator: ", "))"))
            if profile.openBrowserOnStart || settings.openBrowserOnStart {
                openInBrowser()
            }
        }
    }

    // MARK: - Helper processes

    private func waitForReadiness(plan: LaunchPlan, profile: ServerProfile, run: UUID,
                                  isAlive: () -> Bool) async -> Bool {
        if let path = plan.readinessFile {
            let deadline = Date().addingTimeInterval(startupTimeout)
            while runID == run && state == .starting && !Task.isCancelled && Date() < deadline {
                guard isAlive() else { return false }
                if FileManager.default.fileExists(atPath: path) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: path) else { return false }
        }
        guard runID == run, state == .starting, !Task.isCancelled, isAlive() else { return false }
        if profile.engine == .custom {
            try? await Task.sleep(for: .milliseconds(200))
            return runID == run && !Task.isCancelled && isAlive()
        }
        guard let url = HTTPStartup.address(for: profile) else { return false }
        let deadline = Date().addingTimeInterval(startupTimeout)
        while runID == run && state == .starting && !Task.isCancelled && Date() < deadline {
            guard isAlive() else { return false }
            let probe = Task { await HTTPStartup.headers(url: url,
                certificatePath: profile.scheme == "https" ? AppPaths.expand(profile.certificatePath) : nil,
                timeout: responseTimeout) }
            readinessProbe = probe
            let result = await withTaskCancellationHandler {
                await probe.value
            } onCancel: { probe.cancel() }
            guard runID == run, state == .starting, !Task.isCancelled else { return false }
            readinessProbe = nil
            if result == .response {
                let owned = await ownsListeningEndpoint(profile: profile)
                guard runID == run, state == .starting, !Task.isCancelled, isAlive() else { return false }
                if owned { return true }
            }
            if result == .timedOut { return false } // never queue new requests behind a slow accepted one
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private func ownsListeningEndpoint(profile: ServerProfile) async -> Bool {
        guard let owner = processIdentifier else { return false }
        let host = HTTPStartup.address(for: profile)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? profile.host
        let entries = await PortScanner.processesListening(onPort: profile.port)
        for entry in entries {
            let matches = ["*", "0.0.0.0", "::", host].contains(entry.address)
                || (host == "localhost" && ["127.0.0.1", "::1"].contains(entry.address))
            guard matches else { continue }
            // Root listeners may be hidden by macOS; the privileged launcher
            // owns its live session and supervised readiness sentinel instead.
            if entry.pid == 0, let session = privileged,
               PrivilegedLauncher.isAlive(pid: session.serverPID) { return true }
            var pid = entry.pid
            var seen = Set<Int32>()
            for _ in 0..<16 {
                if pid == owner { return true }
                guard pid > 1, seen.insert(pid).inserted else { break }
                let parent = await ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "ppid="], timeout: 2)
                guard parent.succeeded, let next = Int32(parent.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { break }
                pid = next
            }
        }
        return false
    }

    @discardableResult
    private func startSidecar(_ plan: SidecarPlan) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = ShellEnvironment.shared.environment(extra: plan.environment)
        if FileManager.default.fileExists(atPath: plan.workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory, isDirectory: true)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        attachOutput(pipe, stream: .stdout, run: runID, label: plan.name)

        do {
            try process.run()
        } catch {
            log.append(String(localized: "Could not start \(plan.name): \(error.localizedDescription)"),
                       stream: .stderr)
            return false
        }

        log.system(String(localized: "Started \(plan.name) (PID \(String(process.processIdentifier)))"))
        sidecars.append((name: plan.name, process: process))
        return true
    }

    private func stopSidecars() {
        for item in sidecars.reversed() {
            guard item.process.isRunning else { continue }
            item.process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while item.process.isRunning && Date() < deadline { usleep(100_000) }
            if item.process.isRunning { kill(item.process.processIdentifier, SIGKILL) }
            log.system(String(localized: "Stopped \(item.name)"))
        }
        sidecars.removeAll()
    }

    /// Adopts a root-owned server that outlived a restart of the application:
    /// takes control back without asking for the password again.
    func adopt(session: PrivilegedSession, profile: ServerProfile, settings: AppSettings) {
        guard state == .stopped else { return }
        runID = UUID()
        activeProfile = profile
        privileged = session
        processIdentifier = session.serverPID
        startedAt = Date()
        state = .running
        intentionalStop = false
        log.limit = settings.consoleBufferLines
        log.system(String(localized: "Adopted an administrator server started earlier (PID \(String(session.serverPID)))."))
        if let url = profile.primaryURL { detectedURLs = [url.absoluteString] }
        startLogTail(path: session.logPath)
        startWatchdog()
    }

    // MARK: - Launching as administrator

    private func startPrivileged(profile: ServerProfile,
                                 plan: LaunchPlan,
                                 settings: AppSettings, run: UUID) async {
        let runtime = AppPaths.subdir("Runtime/root-\(profile.id.uuidString.prefix(8))").path
        log.system(String(localized: "Starting with administrator rights — a password is required."))

        let session: PrivilegedSession
        do {
            session = try await PrivilegedLauncher.start(plan: plan, runtimeDirectory: runtime)
        } catch {
            guard runID == run, state == .starting else { return }
            log.append(error.localizedDescription, stream: .stderr)
            state = .failed(error.localizedDescription)
            log.stopFileLogging()
            return
        }

        guard runID == run, state == .starting, !Task.isCancelled else {
            PrivilegedLauncher.requestStop(session)
            return
        }
        privileged = session
        processIdentifier = session.serverPID
        startedAt = Date()
        log.system(String(localized: "PID: \(String(session.serverPID))"))

        startLogTail(path: session.logPath)

        // Give the process a chance to fail immediately — because of a taken port, for example.
        let ready = await waitForReadiness(plan: plan, profile: profile, run: run) { PrivilegedLauncher.isAlive(pid: session.serverPID) }

        guard runID == run, state == .starting, !Task.isCancelled else { return }

        if !ready && PrivilegedLauncher.isAlive(pid: session.serverPID) {
            await stop(settings: settings)
            state = .failed(String(localized: "Server did not become ready. Check the server and backend log."))
            return
        }

        if PrivilegedLauncher.isAlive(pid: session.serverPID) {
            state = .running
            if detectedURLs.isEmpty, let url = profile.primaryURL {
                detectedURLs = [url.absoluteString]
            }
            log.system(String(localized: "Server is up: \(detectedURLs.joined(separator: ", "))"))
            if profile.openBrowserOnStart || settings.openBrowserOnStart {
                openInBrowser()
            }
            startWatchdog()
        } else {
            let text = (try? String(contentsOfFile: session.logPath, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            let message = Self.explain(base: String(localized: "The process exited right after start."),
                                       stderr: lines, profile: profile)
            log.append(message, stream: .stderr)
            state = .failed(message)
            cleanupPrivileged()
            log.stopFileLogging()
        }
    }

    /// Read the root process's log through tail — the process is not ours.
    private func startLogTail(path: String) {
        stopLogTail()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "+1", "-F", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        attachOutput(pipe, stream: .stdout, run: runID)

        try? process.run()
        logTail = process
    }

    private func stopLogTail() {
        logTail?.terminate()
        logTail = nil
    }

    /// A root process has no terminationHandler — watch it by polling.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let session = self.privileged else { return }
                if self.state != .running { return }
                if !PrivilegedLauncher.isAlive(pid: session.serverPID) {
                    self.handlePrivilegedExit()
                    return
                }
            }
        }
    }

    private func handlePrivilegedExit() {
        readinessProbe?.cancel()
        readinessProbe = nil
        let profile = activeProfile
        let message = Self.explain(base: String(localized: "The process started with administrator rights has exited."),
                                   stderr: recentStderr, profile: profile)
        log.append(message, stream: .stderr)
        state = .failed(message)
        cleanupPrivileged()
        log.stopFileLogging()
        if let profile { onUnexpectedExit?(profile, -1) }
    }

    private func cleanupPrivileged() {
        stopSidecars()
        watchdog?.cancel()
        watchdog = nil
        stopLogTail()
        if let session = privileged {
            PrivilegedLauncher.requestStop(session)
        }
        privileged = nil
        processIdentifier = nil
        startedAt = nil
    }

    // MARK: - Stopping

    @discardableResult
    func stop(settings: AppSettings) async -> Bool {
        // All callers observe the result of the same cleanup operation.
        if stopInProgress {
            while stopInProgress {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return state == .stopped
        }
        readinessProbe?.cancel()
        readinessProbe = nil
        stopInProgress = true
        defer { stopInProgress = false }
        runID = UUID() // invalidates pending starts, output and exit callbacks
        intentionalStop = true
        if state == .starting && process == nil && privileged == nil {
            finishStopped()
            return true
        }
        if let session = privileged {
            state = .stopping
            watchdog?.cancel()
            watchdog = nil
            log.system(String(localized: "Stopping the server (PID \(String(session.serverPID)))…"))
            PrivilegedLauncher.requestStop(session)
            for _ in 0..<60 {
                if PrivilegedLauncher.hasStopped(session) { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard PrivilegedLauncher.hasStopped(session) else {
                failStop(String(localized: "The administrator server has not confirmed shutdown. Try Stop again; check Console and Ports."))
                return false
            }
            cleanupPrivileged()
            return await completeStop()
        }
        guard let process else {
            if stopFailure != nil { return await completeStop() }
            finishStopped()
            return true
        }
        state = .stopping
        log.system(String(localized: "Stopping the server (PID \(String(process.processIdentifier)))…"))
        if process.isRunning { process.terminate() }
        for _ in 0..<30 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            log.system(String(localized: "The process is not responding to SIGTERM, sending SIGKILL."))
            kill(process.processIdentifier, SIGKILL)
            for _ in 0..<10 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !process.isRunning else {
            failStop(String(localized: "The server process is still running. Try Stop again; check Console and Ports."))
            return false
        }
        return await completeStop()
    }

    /// Check listeners after owned children have stopped. A failed bind alone
    /// can be TIME_WAIT or a permission error, especially on privileged ports.
    private func completeStop() async -> Bool {
        stopSidecars()
        if let profile = activeProfile, profile.engine != .custom {
            let deadline = Date().addingTimeInterval(2)
            var leftovers: [PortEntry]
            repeat {
                leftovers = await PortScanner.processesListening(onPort: profile.port)
                    .filter { PortScanner.listener($0, matchesHost: profile.host) }
                if leftovers.isEmpty { break }
                if Date() >= deadline || Task.isCancelled {
                    let owners = leftovers.map { "\($0.command) (PID \(String($0.pid)))" }.joined(separator: ", ")
                    log.system(String(localized: "Port \(String(profile.port)) is still held by \(owners)."))
                    failStop(String(localized: "The server stopped, but \(profile.host):\(String(profile.port)) is still occupied. Check Ports before restarting; another process may be listening."))
                    return false
                }
                try? await Task.sleep(for: .milliseconds(100))
            } while true
        }
        finishStopped()
        return true
    }

    private func failStop(_ message: String) {
        stopSidecars()
        watchdog?.cancel()
        watchdog = nil
        stopLogTail()
        // Keep live owned handles for a later Stop. Never adopt or kill a
        // replacement listener merely because it has taken the old port.
        if process?.isRunning != true { releaseProcessHandles() }
        processIdentifier = privileged?.serverPID ?? process?.processIdentifier
        startedAt = nil
        detectedURLs = []
        stopFailure = message
        state = .failed(message)
        log.append(message, stream: .stderr)
        log.stopFileLogging()
    }

    func restart(profile: ServerProfile, settings: AppSettings) async {
        guard await stop(settings: settings) else { return }
        let stoppedRun = runID
        try? await Task.sleep(for: .milliseconds(400))
        guard runID == stoppedRun, state == .stopped, !Task.isCancelled else { return }
        await start(profile: profile, settings: settings)
    }

    /// Synchronous shutdown when the application quits.
    func stopImmediately() {
        readinessProbe?.cancel()
        readinessProbe = nil
        defer {
            if let session = privileged, !PrivilegedLauncher.hasStopped(session) {
                failStop(String(localized: "The administrator server has not confirmed shutdown. Try Stop again; check Console and Ports."))
            } else if process?.isRunning == true {
                failStop(String(localized: "The server process is still running. Try Stop again; check Console and Ports."))
            } else {
                finishStopped()
            }
        }
        runID = UUID()
        intentionalStop = true
        if let session = privileged {
            PrivilegedLauncher.requestStop(session)
            let deadline = Date().addingTimeInterval(8)
            while !PrivilegedLauncher.hasStopped(session) && Date() < deadline {
                usleep(100_000)
            }
            if PrivilegedLauncher.hasStopped(session) { cleanupPrivileged() }
            return
        }
        stopSidecars()
        guard let process, process.isRunning else { return }
        process.terminate()
        let needsProxyCleanup = activeProfile.map {
            ($0.httpsEnabled && $0.engine.requiresHTTPSProxy) || $0.engine == .apachePHP || $0.engine == .phpFpm
        } ?? false
        let deadline = Date().addingTimeInterval(needsProxyCleanup ? 4 : 2)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: - Actions

    func openInBrowser(_ urlString: String? = nil) {
        let target = urlString ?? detectedURLs.first ?? activeProfile?.primaryURL?.absoluteString
        guard let target, let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private func attachOutput(_ pipe: Pipe, stream: LogStream, run: UUID, label: String? = nil) {
        let reader = ProcessOutputLines()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let lines = reader.consume(data, endOfFile: data.isEmpty)
            if data.isEmpty { handle.readabilityHandler = nil }
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.runID == run else { return }
                for line in lines {
                    let text = label.map { "[\($0)] " + line.text } ?? line.text
                    self.ingest(text, stream: stream, detectURLs: line.complete)
                }
            }
        }
    }

    private func ingest(_ text: String, stream: LogStream, detectURLs: Bool = true) {
        log.append(text, stream: stream)
        if stream == .stderr {
            for line in text.strippingANSI.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { recentStderr.append(trimmed) }
            }
            if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
        }
        if let profile = activeProfile, profile.httpsEnabled && profile.engine.requiresHTTPSProxy { return }
        guard detectURLs else { return }
        for url in Self.extractURLs(from: text.strippingANSI) where !detectedURLs.contains(url) {
            detectedURLs.append(url)
        }
    }

    private func handleTermination(code: Int32, reason: Process.TerminationReason) {
        readinessProbe?.cancel()
        readinessProbe = nil
        if intentionalStop { return } // stop owns the cleanup barrier

        let profile = activeProfile
        let base = reason == .uncaughtSignal
            ? String(localized: "The process was terminated by a signal (code \(String(code))).")
            : String(localized: "The process exited with code \(String(code)).")
        let message = Self.explain(base: base, stderr: recentStderr, profile: profile)
        log.append(message, stream: .stderr)
        state = .failed(message)
        stopSidecars()
        processIdentifier = nil
        startedAt = nil
        process = nil
        log.stopFileLogging()

        if let profile { onUnexpectedExit?(profile, code) }
    }

    private func finishStopped() {
        stopSidecars()
        stopLogTail()
        releaseProcessHandles()
        processIdentifier = nil
        startedAt = nil
        detectedURLs = []
        stopFailure = nil
        state = .stopped
        log.system(String(localized: "Server stopped."))
        log.stopFileLogging()
    }

    private func releaseProcessHandles() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// The exit code alone is useless — pull the reason out of stderr
    /// and add a hint for the common errors.
    nonisolated static func explain(base: String, stderr: [String], profile: ServerProfile?) -> String {
        let candidates = stderr.filter { !isStackNoise($0) }
        let best = candidates.first { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("fatal") || lower.contains("cannot")
        } ?? candidates.first

        let haystack = stderr.joined(separator: " ").lowercased()
        var hint: String?

        if haystack.contains("eacces") || haystack.contains("permission denied") {
            if let port = profile?.port, port < 1024 {
                hint = String(localized: "Port \(String(port)) requires root — pick a port of 1024 or above.")
            } else {
                hint = String(localized: "No permission to access the file or port.")
            }
        } else if haystack.contains("eaddrinuse") || haystack.contains("address already in use") {
            hint = String(localized: "The port is already taken by another process — check the Ports section.")
        } else if haystack.contains("enoent") || haystack.contains("no such file") {
            hint = String(localized: "A file or directory from the profile settings was not found.")
        } else if haystack.contains("cannot find module") {
            hint = String(localized: "Project dependencies are missing — run npm install.")
        }

        var parts = [base]
        if var best, !best.isEmpty {
            if best.count > 200 { best = String(best.prefix(200)) + "…" }
            parts.append(best)
        }
        if let hint { parts.append(hint) }
        return parts.joined(separator: " ")
    }

    /// Stack frames and background noise that do not explain the failure.
    private nonisolated static func isStackNoise(_ line: String) -> Bool {
        if line.count < 4 { return true }
        if line.allSatisfy({ !$0.isLetter }) { return true }
        for prefix in ["at ", "node:", "Node.js v", "throw ", "Emitted ", "#", "--"] where line.hasPrefix(prefix) {
            return true
        }
        // Fields of a Node error object: "code: 'EACCES',"
        if line.contains(": '") && line.hasSuffix(",") { return true }
        return false
    }

    nonisolated static func extractURLs(from text: String) -> [String] {
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let value = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            if !found.contains(value) { found.append(value) }
        }
        return found
    }
}
