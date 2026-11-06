//
//  PrivilegedLauncher.swift
//  ServerMaster
//
//  Launching a server as root — needed for ports below 1024 (80, 443).
//
//  The password is asked for exactly once, at startup. Stopping the server needs
//  no password: alongside the server, root starts a watchdog that watches a
//  sentinel file. The application creates and removes the sentinel as the
//  user — as soon as it disappears, the watchdog stops the server.
//  Thanks to that, shutting down on quit happens without any dialogs.
//

import Foundation

nonisolated struct PrivilegedSession: Sendable {
    var serverPID: Int32
    var logPath: String
    var sentinelPath: String
    var pidPath: String
}

nonisolated enum PrivilegedLauncher {

    enum LaunchError: LocalizedError {
        case cancelled
        case failed(String)
        case noPID(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return String(localized: "Start with administrator rights was cancelled.")
            case .failed(let message):
                return message
            case .noPID(let log):
                return log.isEmpty
                    ? String(localized: "The process did not start. Check the command and the permissions.")
                    : log
            }
        }
    }

    static func start(plan: LaunchPlan, runtimeDirectory: String) async throws -> PrivilegedSession {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true)

        let logPath = (runtimeDirectory as NSString).appendingPathComponent("privileged.log")
        let sentinelPath = (runtimeDirectory as NSString).appendingPathComponent("running.lock")
        let pidPath = (runtimeDirectory as NSString).appendingPathComponent("server.pid")
        let scriptPath = (runtimeDirectory as NSString).appendingPathComponent("launch.sh")

        // The files are created by the user — so the application can read and delete them,
        // even when root is the one writing to the log.
        try? fm.removeItem(atPath: pidPath)
        fm.createFile(atPath: logPath, contents: Data())
        fm.createFile(atPath: sentinelPath, contents: Data())

        try script(plan: plan, logPath: logPath, sentinelPath: sentinelPath, pidPath: pidPath)
            .write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)

        // do shell script waits for completion, so the watchdog is sent to the background.
        let command = "/bin/sh " + ProcessRunner.shellQuote(scriptPath) + " >/dev/null 2>&1 &"
        let result = await ProcessRunner.runAsAdmin(
            command,
            prompt: String(localized: "ServerMaster wants to start the server with administrator rights."))

        if !result.succeeded {
            try? fm.removeItem(atPath: sentinelPath)
            let text = result.combined
            // −128 — the user pressed “Cancel” in the system window.
            if text.contains("-128") || text.lowercased().contains("user canceled") {
                throw LaunchError.cancelled
            }
            throw LaunchError.failed(text.isEmpty
                                     ? String(localized: "Could not obtain administrator rights.")
                                     : text)
        }

        // Wait until the watchdog writes down the server's PID.
        for _ in 0..<40 {
            if let pid = readPID(pidPath) {
                return PrivilegedSession(serverPID: pid, logPath: logPath,
                                         sentinelPath: sentinelPath, pidPath: pidPath)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        try? fm.removeItem(atPath: sentinelPath)
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        throw LaunchError.noPID(log.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stopping is simply removing the sentinel. The watchdog does the rest as root.
    static func requestStop(_ session: PrivilegedSession) {
        try? FileManager.default.removeItem(atPath: session.sentinelPath)
    }

    /// Root-owned servers left over from a previous run of the application.
    ///
    /// If the application was killed, the watchdog keeps holding the process and the
    /// sentinel stays on disk. Without this search a root server would keep the port
    /// with nothing in the interface able to stop it.
    static func findOrphans() -> [(profileKey: String, session: PrivilegedSession)] {
        let runtime = AppPaths.support.appendingPathComponent("Runtime", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: runtime.path) else {
            return []
        }

        var found: [(String, PrivilegedSession)] = []
        for entry in entries where entry.hasPrefix("root-") {
            let directory = runtime.appendingPathComponent(entry, isDirectory: true).path
            let session = PrivilegedSession(
                serverPID: 0,
                logPath: (directory as NSString).appendingPathComponent("privileged.log"),
                sentinelPath: (directory as NSString).appendingPathComponent("running.lock"),
                pidPath: (directory as NSString).appendingPathComponent("server.pid"))

            guard FileManager.default.fileExists(atPath: session.sentinelPath) else { continue }

            guard let pid = readPID(session.pidPath), isAlive(pid: pid) else {
                // A sentinel with no process behind it — just junk, remove it.
                try? FileManager.default.removeItem(atPath: session.sentinelPath)
                continue
            }

            var live = session
            live.serverPID = pid
            found.append((String(entry.dropFirst("root-".count)), live))
        }
        return found
    }

    static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0) does not kill, it only checks that the process exists.
        // EPERM means “exists, but someone else's” — for us that is also “alive”.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func readPID(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else { return nil }
        return pid
    }

    // MARK: - Launch script

    private static func script(plan: LaunchPlan,
                               logPath: String,
                               sentinelPath: String,
                               pidPath: String) -> String {
        let q = ProcessRunner.shellQuote

        var exports: [String] = []
        // Pass through only what the profile set, plus PATH: the root environment
        // differs from the user's, and without PATH the child processes
        // (node for http-server, for example) may not be found.
        var environment = plan.environment
        environment["PATH"] = ShellEnvironment.shared.path
        environment["HOME"] = NSHomeDirectory()
        for key in environment.keys.sorted() {
            exports.append("export \(key)=\(q(environment[key] ?? ""))")
        }

        let commandLine = ([plan.executable] + plan.arguments).map(q).joined(separator: " ")

        return """
        #!/bin/sh
        # Generated by ServerMaster. Run as root through the system password prompt.
        \(exports.joined(separator: "\n"))
        cd \(q(plan.workingDirectory)) 2>/dev/null || cd /

        \(commandLine) >> \(q(logPath)) 2>&1 &
        SERVER=$!
        echo "$SERVER" > \(q(pidPath))

        # Watchdog: the server lives as long as the sentinel exists.
        while kill -0 "$SERVER" 2>/dev/null; do
            if [ ! -e \(q(sentinelPath)) ]; then
                kill -TERM "$SERVER" 2>/dev/null
                i=0
                while kill -0 "$SERVER" 2>/dev/null && [ "$i" -lt 20 ]; do
                    sleep 0.25
                    i=$((i + 1))
                done
                kill -KILL "$SERVER" 2>/dev/null
                break
            fi
            sleep 0.4
        done

        rm -f \(q(pidPath))
        rm -f \(q(sentinelPath))
        """
    }
}
