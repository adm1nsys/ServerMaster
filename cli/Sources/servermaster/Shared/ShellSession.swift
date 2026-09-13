//
//  ShellSession.swift
//  ServerMaster
//
//  A simple console: every command runs in its own shell process,
//  the current directory is tracked between calls (so cd works).
//

import Foundation
import Observation
import AppKit

@Observable
final class ShellSession {

    let log = ConsoleLog()
    private(set) var currentDirectory: String = NSHomeDirectory()
    private(set) var isRunning = false
    private(set) var history: [String] = []
    private var historyIndex: Int?

    private var runningProcess: Process?

    var prompt: String { AppPaths.abbreviate(currentDirectory) + " %" }

    func setDirectory(_ path: String) {
        let expanded = AppPaths.expand(path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            currentDirectory = expanded
        }
    }

    func run(_ rawCommand: String) async {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }

        history.removeAll { $0 == command }
        history.append(command)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = nil

        log.append("\(prompt) \(command)", stream: .command)

        // Built-in commands there is no point in handing outside.
        if command == "clear" || command == "cls" {
            log.clear()
            return
        }
        if command == "pwd" {
            log.append(currentDirectory, stream: .stdout)
            return
        }

        isRunning = true
        defer { isRunning = false }

        // Run the command and print the resulting pwd after it, to catch `cd`.
        let marker = "__SM_PWD_\(UUID().uuidString.prefix(8))__"
        let wrapped = "\(command)\nprintf '\\n%s%s\\n' '\(marker)' \"$PWD\""

        let result = await ProcessRunner.shell(wrapped, cwd: currentDirectory, timeout: 600)

        var output = result.stdout
        if let range = output.range(of: marker) {
            let tail = output[range.upperBound...]
            let newDirectory = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newDirectory.isEmpty, FileManager.default.fileExists(atPath: newDirectory) {
                // The shell returns the physical path (/private/tmp instead of /tmp).
                // Overwrite only on a real directory change, otherwise the path in the
                // prompt “jumps” right after the very first command.
                let resolve = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                if resolve(newDirectory) != resolve(currentDirectory) {
                    currentDirectory = newDirectory
                }
            }
            output = String(output[output.startIndex..<range.lowerBound])
        }

        let trimmedOut = output.trimmingCharacters(in: .newlines)
        if !trimmedOut.isEmpty { log.append(trimmedOut, stream: .stdout) }
        if !result.stderr.trimmingCharacters(in: .newlines).isEmpty {
            log.append(result.stderr.trimmingCharacters(in: .newlines), stream: .stderr)
        }
        if result.exitCode != 0 {
            log.system(String(localized: "Exit code: \(String(result.exitCode))"))
        }
    }

    // MARK: History

    func previousCommand(current: String) -> String? {
        guard !history.isEmpty else { return nil }
        let index = historyIndex.map { max(0, $0 - 1) } ?? history.count - 1
        historyIndex = index
        return history[index]
    }

    func nextCommand() -> String? {
        guard let index = historyIndex, !history.isEmpty else { return nil }
        let next = index + 1
        if next >= history.count { historyIndex = nil; return "" }
        historyIndex = next
        return history[next]
    }

    // MARK: External terminal

    /// Open a real terminal in the current directory.
    static func openExternalTerminal(app: TerminalApp, directory: String, command: String? = nil) {
        var shellCommand = "cd " + ProcessRunner.shellQuote(directory)
        if let command, !command.isEmpty {
            shellCommand += "; " + command
        }
        let script = ProcessRunner.appleScriptQuote(shellCommand)

        let osa: String
        switch app {
        case .terminal:
            osa = """
            tell application "Terminal"
                activate
                do script \(script)
            end tell
            """
        case .iterm:
            osa = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text \(script)
            end tell
            """
        case .warp, .ghostty:
            // These terminals have no convenient AppleScript API — just open at the folder.
            NSWorkspace.shared.open([URL(fileURLWithPath: directory)],
                                    withApplicationAt: URL(fileURLWithPath: "/Applications/\(app.bundleName).app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", osa]
        try? process.run()
    }

}
