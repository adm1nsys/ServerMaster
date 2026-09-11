//
//  ProcessRunner.swift
//  ServerMaster
//

import Foundation

nonisolated struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
    var combined: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

nonisolated enum ProcessRunner {

    /// A one-off run of a binary, waiting for the result.
    static func run(_ executable: String,
                    _ arguments: [String] = [],
                    cwd: String? = nil,
                    env extra: [String: String] = [:],
                    stdin: String? = nil,
                    timeout: TimeInterval = 60) async -> CommandResult {

        let resolved = ShellEnvironment.shared.which(executable) ?? executable
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            return CommandResult(exitCode: 127, stdout: "", stderr: String(localized: "Executable not found: \(executable)"))
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(resolved, arguments,
                                                       cwd: cwd, extra: extra,
                                                       stdin: stdin, timeout: timeout))
            }
        }
    }

    /// A command through the shell — handy when pipes and substitutions are needed.
    static func shell(_ command: String,
                      cwd: String? = nil,
                      env extra: [String: String] = [:],
                      timeout: TimeInterval = 60) async -> CommandResult {
        await run("/bin/zsh", ["-lc", command], cwd: cwd, env: extra, timeout: timeout)
    }

    /// Running with administrator rights through the macOS system dialog.
    /// The password is typed into a system window — the application never sees it.
    static func runAsAdmin(_ command: String, prompt: String) async -> CommandResult {
        let script = "do shell script \(appleScriptQuote(command))"
            + " with prompt \(appleScriptQuote(prompt))"
            + " with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", script], timeout: 300)
    }

    // MARK: - Escaping

    /// Single quotes for the shell: inside them only the apostrophe itself is special.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal — escape the already-assembled command as a whole.
    static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    // MARK: - Synchronous implementation

    private static func runSync(_ executable: String,
                                _ arguments: [String],
                                cwd: String?,
                                extra: [String: String],
                                stdin: String?,
                                timeout: TimeInterval) -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ShellEnvironment.shared.environment(extra: extra)

        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        if stdin != nil {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 126, stdout: "", stderr: error.localizedDescription)
        }

        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        // Read both streams in parallel, otherwise a full buffer can deadlock.
        let group = DispatchGroup()
        let box = OutputBox()

        for (pipe, isError) in [(outPipe, false), (errPipe, true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.append(data, isError: isError)
                group.leave()
            }
        }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()

        let (out, err) = box.snapshot()
        return CommandResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: out,
            stderr: timedOut ? (err + String(localized: "\nTimed out after \(Int(timeout)) s.")) : err
        )
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func append(_ data: Data, isError: Bool) {
            lock.lock()
            if isError { err.append(data) } else { out.append(data) }
            lock.unlock()
        }

        func snapshot() -> (String, String) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }
    }
}

// MARK: - Helpers for output text

nonisolated extension String {
    /// Strips ANSI escape sequences so the output reads properly in SwiftUI.
    var strippingANSI: String {
        guard contains("\u{1B}") else { return self }
        let pattern = "\u{1B}\\[[0-9;?]*[a-zA-Z]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][A-Z0-9]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }
}
