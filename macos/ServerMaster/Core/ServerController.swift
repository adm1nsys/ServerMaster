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
    private(set) var activeProfile: ServerProfile?
    private(set) var startedAt: Date?
    private(set) var processIdentifier: Int32?
    private(set) var detectedURLs: [String] = []
    private(set) var lastCommand: String = ""

    let log = ConsoleLog()

    /// Called when the process dies unexpectedly.
    var onUnexpectedExit: ((ServerProfile, Int32) -> Void)?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var intentionalStop = false
    private var recentStderr: [String] = []
    private var privileged: PrivilegedSession?
    private var logTail: Process?
    private var watchdog: Task<Void, Never>?
    private var sidecars: [(name: String, process: Process)] = []

    /// The server was started as root through the system password prompt.
    var isPrivileged: Bool { privileged != nil }

    var uptime: TimeInterval? {
        guard let startedAt, state == .running else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Startup

    func start(profile: ServerProfile, settings: AppSettings) async {
        guard !state.isActive else { return }

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

        // Port check
        if settings.checkPortBeforeStart {
            let occupants = await PortScanner.processesListening(onPort: profile.port)
            if !occupants.isEmpty {
                let summary = occupants.map { "\($0.command) (PID \($0.pid))" }.joined(separator: ", ")
                if settings.killPortOccupantOnStart {
                    log.system(String(localized: "Port \(String(profile.port)) is taken: \(summary). Freeing it…"))
                    for occupant in occupants {
                        _ = await PortScanner.kill(pid: occupant.pid, signal: .term)
                    }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                } else {
                    log.append(String(localized: "Port \(String(profile.port)) is already taken: \(summary)"), stream: .stderr)
                    state = .failed(String(localized: "Port \(String(profile.port)) is taken: \(summary)"))
                    log.stopFileLogging()
                    return
                }
            }
        }

        // Building the command
        let plan: LaunchPlan
        do {
            plan = try LaunchPlanBuilder.build(for: profile)
        } catch {
            log.append(error.localizedDescription, stream: .stderr)
            state = .failed(error.localizedDescription)
            log.stopFileLogging()
            return
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

        // Helper processes (php-fpm) are brought up before the main one.
        for sidecar in plan.sidecars {
            guard startSidecar(sidecar) else {
                stopSidecars()
                state = .failed(String(localized: "Could not start \(sidecar.name)."))
                log.stopFileLogging()
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(sidecar.warmup * 1_000_000_000))
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
            await startPrivileged(profile: profile, plan: plan, settings: settings)
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

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let controller = self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in controller.ingest(text, stream: .stdout) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let controller = self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in controller.ingest(text, stream: .stderr) }
        }

        process.terminationHandler = { [weak self] finished in
            guard let controller = self else { return }
            let code = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in controller.handleTermination(code: code, reason: reason) }
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
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        guard state == .starting else { return }

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

        let label = plan.name
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let controller = self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                // Tag the lines so the shared log shows who wrote them.
                let prefixed = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : "[\(label)] " + $0 }
                    .joined(separator: "\n")
                controller.ingest(prefixed, stream: .stdout)
            }
        }

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
                                 settings: AppSettings) async {
        let runtime = AppPaths.subdir("Runtime/root-\(profile.id.uuidString.prefix(8))").path
        log.system(String(localized: "Starting with administrator rights — a password is required."))

        let session: PrivilegedSession
        do {
            session = try await PrivilegedLauncher.start(plan: plan, runtimeDirectory: runtime)
        } catch {
            log.append(error.localizedDescription, stream: .stderr)
            state = .failed(error.localizedDescription)
            log.stopFileLogging()
            return
        }

        privileged = session
        processIdentifier = session.serverPID
        startedAt = Date()
        log.system(String(localized: "PID: \(String(session.serverPID))"))

        startLogTail(path: session.logPath)

        // Give the process a chance to fail immediately — because of a taken port, for example.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard state == .starting else { return }

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
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let controller = self else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in controller.ingest(text, stream: .stdout) }
        }
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

    func stop(settings: AppSettings) async {
        if let session = privileged {
            intentionalStop = true
            state = .stopping
            log.system(String(localized: "Stopping the server (PID \(String(session.serverPID)))…"))
            // Remove the sentinel: the root watchdog will stop the process, no password needed.
            PrivilegedLauncher.requestStop(session)
            for _ in 0..<40 {
                if !PrivilegedLauncher.isAlive(pid: session.serverPID) { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            cleanupPrivileged()
            detectedURLs = []
            state = .stopped
            log.system(String(localized: "Server stopped."))
            log.stopFileLogging()
            return
        }
        guard let process, state.isActive else { return }
        intentionalStop = true
        state = .stopping
        log.system(String(localized: "Stopping the server (PID \(String(process.processIdentifier)))…"))

        process.terminate()

        for _ in 0..<30 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            log.system(String(localized: "The process is not responding to SIGTERM, sending SIGKILL."))
            kill(process.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Clean up any “orphans” that are still holding the port.
        if let profile = activeProfile {
            let leftovers = await PortScanner.processesListening(onPort: profile.port)
            for leftover in leftovers where leftover.pid != process.processIdentifier {
                log.system(String(localized: "Port \(String(profile.port)) is still held by \(leftover.command) (PID \(String(leftover.pid)))."))
            }
        }

        finishStopped()
    }

    func restart(profile: ServerProfile, settings: AppSettings) async {
        await stop(settings: settings)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await start(profile: profile, settings: settings)
    }

    /// Synchronous shutdown when the application quits.
    func stopImmediately() {
        intentionalStop = true
        if let session = privileged {
            PrivilegedLauncher.requestStop(session)
            let deadline = Date().addingTimeInterval(4)
            while PrivilegedLauncher.isAlive(pid: session.serverPID) && Date() < deadline {
                usleep(100_000)
            }
            cleanupPrivileged()
            return
        }
        stopSidecars()
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
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

    private func ingest(_ text: String, stream: LogStream) {
        log.append(text, stream: stream)
        if stream == .stderr {
            for line in text.strippingANSI.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { recentStderr.append(trimmed) }
            }
            if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
        }
        for url in Self.extractURLs(from: text) where !detectedURLs.contains(url) {
            detectedURLs.append(url)
        }
    }

    private func handleTermination(code: Int32, reason: Process.TerminationReason) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if intentionalStop {
            finishStopped()
            return
        }

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
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        processIdentifier = nil
        startedAt = nil
        detectedURLs = []
        state = .stopped
        log.system(String(localized: "Server stopped."))
        log.stopFileLogging()
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
        let pattern = "https?://[A-Za-z0-9\\.\\-\\[\\]:]+(?::\\d+)?"
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
