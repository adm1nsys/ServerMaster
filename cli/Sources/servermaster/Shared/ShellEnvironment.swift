//
//  ShellEnvironment.swift
//  ServerMaster
//
//  A GUI application starts with a stripped PATH, so node/nginx/php from
//  Homebrew or nvm are not found. Here the PATH is pulled from the login
//  shell once and used for every process afterwards.
//

import Foundation

nonisolated final class ShellEnvironment: @unchecked Sendable {

    static let shared = ShellEnvironment()

    private let lock = NSLock()
    private var cachedPath: String?
    private var extraEntries: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Paths that are always added — in case the login shell is unavailable.
    private static let fallbackEntries = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.npm-global/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.cargo/bin"
    ]

    func setExtraEntries(_ entries: [String]) {
        lock.lock()
        extraEntries = entries.map { AppPaths.expand($0) }.filter { !$0.isEmpty }
        cachedPath = nil
        lock.unlock()
    }

    func invalidate() {
        lock.lock(); cachedPath = nil; lock.unlock()
    }

    /// The PATH for child processes.
    var path: String {
        lock.lock()
        if let cached = cachedPath { lock.unlock(); return cached }
        let extras = extraEntries
        lock.unlock()

        var entries: [String] = extras
        entries.append(contentsOf: loginShellPath())
        entries.append(contentsOf: ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        entries.append(contentsOf: Self.fallbackEntries)

        var seen = Set<String>()
        let unique = entries.filter { !$0.isEmpty && seen.insert($0).inserted }
        let result = unique.joined(separator: ":")

        lock.lock(); cachedPath = result; lock.unlock()
        return result
    }

    /// The full environment for a process: system + PATH + the user's variables.
    func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Disable buffering and pagers where they get in the way of reading output.
        env["PYTHONUNBUFFERED"] = "1"
        env["NODE_NO_WARNINGS"] = env["NODE_NO_WARNINGS"] ?? "1"
        env["PAGER"] = "cat"
        env["TERM"] = "dumb"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// The full path to an executable, or nil.
    func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Private

    private func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ["HOME": NSHomeDirectory(), "TERM": "dumb"]

        do { try process.run() } catch { return [] }

        let data: Data = ((try? pipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
    }
}
