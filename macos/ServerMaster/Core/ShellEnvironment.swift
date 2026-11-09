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
    private var loginEntries: [String] = []
    private var refreshTask: Task<[String], Never>?
    private var refreshID: UUID?
    private var refreshedAt: Date?
    private let loginProbe: @Sendable () -> [String]

    init(loginProbe: (@Sendable () -> [String])? = nil) {
        self.loginProbe = loginProbe ?? { Self.loginShellPath() }
    }
    private var extraEntries: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    private var managedNodeDirectory: String?

    func setManagedNodeDirectory(_ directory: String?) {
        lock.lock()
        managedNodeDirectory = directory
        lock.unlock()
    }

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
        refreshedAt = nil
        lock.unlock()
    }

    func invalidate() {
        lock.lock(); refreshedAt = nil; lock.unlock()
    }

    /// Always a fast cached/fallback snapshot; never launches a shell on a UI read.
    var path: String {
        lock.lock()
        let entries = (managedNodeDirectory.map { [$0] } ?? []) + extraEntries + loginEntries
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
            + Self.fallbackEntries
        lock.unlock()
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private func beginRefresh() -> (UUID, Task<[String], Never>)? {
        lock.lock(); defer { lock.unlock() }
        if let refreshID, let refreshTask { return (refreshID, refreshTask) }
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < 30 { return nil }
        let id = UUID()
        let probe = loginProbe
        let task = Task.detached(priority: .utility) { probe() }
        refreshID = id; refreshTask = task
        return (id, task)
    }

    private func applyRefresh(_ entries: [String], id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard refreshID == id else { return }
        loginEntries = entries
        refreshedAt = Date()
        refreshID = nil; refreshTask = nil
    }

    func refresh() async {
        guard let (id, task) = beginRefresh() else { return }
        applyRefresh(await task.value, id: id)
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
        lock.lock()
        let nodeDirectory = managedNodeDirectory
        lock.unlock()
        if ["node", "npm", "npx"].contains(tool), let nodeDirectory {
            let candidate = (nodeDirectory as NSString).appendingPathComponent(tool)
            // A missing selected copy must not silently become another version.
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Private

    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let result = ExecutableProbe.run(shell, arguments: ["-lc", "printf %s \"$PATH\""],
            environment: ["HOME": NSHomeDirectory(), "TERM": "dumb", "PATH": fallbackEntries.joined(separator: ":")], timeout: 2)
        guard result.succeeded else { return [] }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
    }
}
