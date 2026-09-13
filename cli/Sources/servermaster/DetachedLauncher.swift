//
//  DetachedLauncher.swift
//  servermaster
//
//  Starting a server that outlives the command that started it.
//
//  `Process` is not enough here. A child started that way stays in the caller's
//  process group, so closing the terminal sends it SIGHUP and the server dies
//  with the window — which makes `servermaster start --no-wait` a promise the
//  tool could not keep.
//
//  posix_spawn with POSIX_SPAWN_SETSID puts the server in a session of its own.
//  Its output goes to the same log file the app writes, so `servermaster logs`
//  and the app's console show the same thing regardless of who started it.
//

import Foundation

enum DetachedLauncher {

    enum LaunchError: LocalizedError {
        case spawnFailed(Int32)
        case logUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let code):
                return "Could not start the process: \(String(cString: strerror(code)))"
            case .logUnavailable(let path):
                return "Could not open the log file at \(path)"
            }
        }
    }

    /// Runs `plan` detached and returns its pid.
    static func launch(_ plan: LaunchPlan, logPath: String) throws -> Int32 {
        AppPaths.ensure(URL(fileURLWithPath: logPath).deletingLastPathComponent())
        FileManager.default.createFile(atPath: logPath, contents: nil)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session: no controlling terminal, so no SIGHUP when the window
        // closes, and no stray signals from the shell that started it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Everything the engine says goes to the log rather than to a terminal
        // that is about to disappear.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let arguments = [plan.executable] + plan.arguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer { for pointer in cArguments where pointer != nil { free(pointer) } }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(plan.environment) { _, new in new }
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer { for pointer in cEnvironment where pointer != nil { free(pointer) } }

        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(plan.workingDirectory)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, plan.executable, &actions, &attributes,
                                 &cArguments, &cEnvironment)
        guard status == 0 else { throw LaunchError.spawnFailed(status) }
        return pid
    }

    /// Writes the files an engine needs before it can start — the generated
    /// config, the error pages, a php-fpm pool — exactly as the app does.
    static func prepare(_ plan: LaunchPlan, profile: ServerProfile) throws {
        if let config = plan.generatedConfig {
            AppPaths.ensure(URL(fileURLWithPath: config.path).deletingLastPathComponent())
            try config.contents.write(toFile: config.path, atomically: true, encoding: .utf8)
        }
        for file in plan.extraFiles {
            AppPaths.ensure(URL(fileURLWithPath: file.path).deletingLastPathComponent())
            try file.contents.write(toFile: file.path, atomically: true, encoding: .utf8)
        }
        if let directory = plan.errorPagesDirectory {
            _ = try? ErrorPages.write(for: profile, into: directory)
        }
    }

    /// Sidecars such as php-fpm, which have to be up before the engine is.
    static func launchSidecars(_ plan: LaunchPlan, logPath: String) throws -> [Int32] {
        var pids: [Int32] = []
        for sidecar in plan.sidecars {
            let helper = LaunchPlan(executable: sidecar.executable,
                                    arguments: sidecar.arguments,
                                    workingDirectory: sidecar.workingDirectory,
                                    environment: sidecar.environment,
                                    generatedConfig: nil)
            pids.append(try launch(helper, logPath: logPath))
            if sidecar.warmup > 0 { Thread.sleep(forTimeInterval: sidecar.warmup) }
        }
        return pids
    }
}
