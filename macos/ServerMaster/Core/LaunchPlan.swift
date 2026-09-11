//
//  LaunchPlan.swift
//  ServerMaster
//
//  Turns a profile into a concrete launch command.
//

import Foundation

nonisolated struct LaunchPlan: Sendable {
    var executable: String            // name or full path
    var arguments: [String]
    var workingDirectory: String
    var environment: [String: String]
    /// The config file to generate before starting (path → contents).
    var generatedConfig: (path: String, contents: String)?
    /// Where to put the error pages before starting.
    var errorPagesDirectory: String?
    /// Processes to bring up before the main one (php-fpm, for example).
    var sidecars: [SidecarPlan] = []
    /// Additional files to write before starting.
    var extraFiles: [(path: String, contents: String)] = []

    var displayCommand: String {
        ([executable] + arguments).map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }
}

/// A helper process living alongside the main one.
nonisolated struct SidecarPlan: Sendable {
    var name: String
    var executable: String
    var arguments: [String]
    var workingDirectory: String
    var environment: [String: String]
    /// How long to wait after starting it before bringing up the main process.
    var warmup: TimeInterval = 1.0
}

nonisolated enum LaunchPlanBuilder {

    enum BuildError: LocalizedError {
        case toolNotFound(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .toolNotFound(let tool): return String(localized: "Executable “\(tool)” not found. Check the Dependencies tab.")
            case .invalid(let message):   return message
            }
        }
    }

    static func build(for profile: ServerProfile) throws -> LaunchPlan {
        let root = AppPaths.expand(profile.rootPath)
        let cwd = profile.effectiveWorkingDirectory
        let env = profile.environmentDictionary
        let extra = splitArguments(profile.extraArguments)
        let https = profile.httpsEnabled && profile.engine.supportsHTTPS

        switch profile.engine {

        case .httpServer:
            var args: [String] = [root, "-a", profile.host, "-p", String(profile.port)]
            if https {
                args += ["-S", "-C", AppPaths.expand(profile.certificatePath),
                         "-K", AppPaths.expand(profile.privateKeyPath)]
            }
            if profile.enableCORS { args.append("--cors") }
            if profile.enableGzip { args.append("-g") }
            if !profile.directoryListing { args.append("-d") ; args.append("false") }
            if profile.spaFallback { args += ["--proxy", "\(profile.scheme)://\(profile.displayHost):\(String(profile.port))?"] }
            if profile.cacheSeconds >= 0 { args.append("-c\(profile.cacheSeconds)") } else { args.append("-c-1") }
            if profile.hideDotfiles { args.append("--no-dotfiles") }
            if profile.basicAuthEnabled {
                args += ["--username", profile.basicAuthUser, "--password", profile.basicAuthPassword]
            }
            args += extra
            return LaunchPlan(executable: try require("http-server"), arguments: args,
                              workingDirectory: cwd, environment: env, generatedConfig: nil)

        case .nodeScript:
            var env2 = env
            env2["PORT"] = env2["PORT"] ?? String(profile.port)
            env2["HOST"] = env2["HOST"] ?? profile.host
            return LaunchPlan(executable: try require("node"),
                              arguments: [profile.resolvedNodeEntry] + extra,
                              workingDirectory: cwd, environment: env2, generatedConfig: nil)

        case .pythonHTTP:
            var args = ["-u", "-m", "http.server", String(profile.port),
                        "--bind", profile.host, "--directory", root]
            args += extra
            return LaunchPlan(executable: try require("python3"), arguments: args,
                              workingDirectory: cwd, environment: env, generatedConfig: nil)

        case .phpBuiltIn:
            var args = ["-S", "\(profile.host):\(String(profile.port))", "-t", root]
            args += extra
            return LaunchPlan(executable: try requirePHP(profile: profile), arguments: args,
                              workingDirectory: cwd, environment: env, generatedConfig: nil)

        case .nginx:
            let prefix = AppPaths.subdir("Runtime/nginx-\(profile.id.uuidString.prefix(8))").path
            AppPaths.ensure(URL(fileURLWithPath: prefix + "/logs"))
            var generated: (String, String)?
            let configPath: String
            if profile.configPath.trimmingCharacters(in: .whitespaces).isEmpty {
                configPath = prefix + "/nginx.conf"
                generated = (configPath, ConfigTemplates.nginx(for: profile, prefix: prefix))
            } else {
                configPath = AppPaths.expand(profile.configPath)
                guard FileManager.default.fileExists(atPath: configPath) else {
                    throw BuildError.invalid(String(localized: "nginx config not found: \(configPath)"))
                }
            }
            var args = ["-p", prefix, "-c", configPath, "-g", "daemon off;"]
            args += extra
            return LaunchPlan(executable: try require("nginx"), arguments: args,
                              workingDirectory: cwd, environment: env,
                              generatedConfig: generated.map { (path: $0.0, contents: $0.1) },
                              errorPagesDirectory: profile.customErrorPages ? prefix : nil)

        case .phpFpm:
            let prefix = AppPaths.subdir("Runtime/php-\(profile.id.uuidString.prefix(8))").path
            AppPaths.ensure(URL(fileURLWithPath: prefix + "/logs"))

            let phpFpmBinary = try requirePHPFPM(profile: profile)
            // A free port is chosen for nginx to talk to php-fpm —
            // so several PHP sites do not get in each other's way.
            let fpmPort = freePort(startingAt: 9000)
            let fpmConfigPath = prefix + "/php-fpm.conf"
            let fpmConfig = ConfigTemplates.phpFPM(for: profile, prefix: prefix, port: fpmPort)

            var generated: (String, String)?
            let configPath: String
            if profile.configPath.trimmingCharacters(in: .whitespaces).isEmpty {
                configPath = prefix + "/nginx.conf"
                generated = (configPath, ConfigTemplates.nginx(for: profile, prefix: prefix,
                                                               phpFpmPort: fpmPort))
            } else {
                configPath = AppPaths.expand(profile.configPath)
                guard FileManager.default.fileExists(atPath: configPath) else {
                    throw BuildError.invalid(String(localized: "nginx config not found: \(configPath)"))
                }
            }

            let sidecar = SidecarPlan(
                name: "php-fpm",
                executable: phpFpmBinary,
                arguments: ["--nodaemonize", "--fpm-config", fpmConfigPath],
                workingDirectory: cwd,
                environment: env,
                warmup: 1.2)

            var args = ["-p", prefix, "-c", configPath, "-g", "daemon off;"]
            args += extra
            return LaunchPlan(executable: try require("nginx"), arguments: args,
                              workingDirectory: cwd, environment: env,
                              generatedConfig: generated.map { (path: $0.0, contents: $0.1) },
                              errorPagesDirectory: profile.customErrorPages ? prefix : nil,
                              sidecars: [sidecar],
                              extraFiles: [(path: fpmConfigPath, contents: fpmConfig)])

        case .caddy:
            var generated: (String, String)?
            let caddyDirectory = AppPaths.subdir("Runtime/caddy-\(profile.id.uuidString.prefix(8))").path
            let errorDirectory = profile.customErrorPages
                ? (caddyDirectory as NSString).appendingPathComponent(ErrorPages.directoryName)
                : nil
            let configPath: String
            if profile.configPath.trimmingCharacters(in: .whitespaces).isEmpty {
                configPath = caddyDirectory + "/Caddyfile"
                generated = (configPath, ConfigTemplates.caddyfile(for: profile, errorDirectory: errorDirectory))
            } else {
                configPath = AppPaths.expand(profile.configPath)
                guard FileManager.default.fileExists(atPath: configPath) else {
                    throw BuildError.invalid(String(localized: "Caddyfile not found: \(configPath)"))
                }
            }
            var args = ["run", "--config", configPath, "--adapter", "caddyfile"]
            args += extra
            return LaunchPlan(executable: try require("caddy"), arguments: args,
                              workingDirectory: cwd, environment: env,
                              generatedConfig: generated.map { (path: $0.0, contents: $0.1) },
                              errorPagesDirectory: profile.customErrorPages ? caddyDirectory : nil)

        case .custom:
            let command = profile.customCommand.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw BuildError.invalid(String(localized: "No launch command specified.")) }
            let resolved = ShellEnvironment.shared.which(command)
            guard let resolved else { throw BuildError.toolNotFound(command) }
            var env2 = env
            env2["PORT"] = env2["PORT"] ?? String(profile.port)
            return LaunchPlan(executable: resolved,
                              arguments: splitArguments(profile.customArguments) + extra,
                              workingDirectory: cwd, environment: env2, generatedConfig: nil)
        }
    }

    /// The php interpreter of the chosen version — for the built-in server.
    private static func requirePHP(profile: ServerProfile) throws -> String {
        try requirePHPBinary(version: profile.phpVersion, name: "php", folder: "bin")
    }

    /// php-fpm of the chosen version: brew puts them in /opt/homebrew/opt/php@X.Y/sbin.
    private static func requirePHPFPM(profile: ServerProfile) throws -> String {
        try requirePHPBinary(version: profile.phpVersion, name: "php-fpm", folder: "sbin")
    }

    /// Finds php or php-fpm of the required version. An empty version — take what
    /// is in PATH; otherwise only the specific Homebrew build, or the profile
    /// would start on a version other than the one selected.
    private static func requirePHPBinary(version raw: String,
                                         name: String,
                                         folder: String) throws -> String {
        let version = raw.trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty else { return try require(name) }

        let candidates = [
            "/opt/homebrew/opt/php@\(version)/\(folder)/\(name)",
            "/usr/local/opt/php@\(version)/\(folder)/\(name)",
            // The main build may happen to be the required version.
            "/opt/homebrew/opt/php/\(folder)/\(name)",
            "/usr/local/opt/php/\(folder)/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            // For the main build, check that the version matches.
            if path.contains("/php/") && !PHPVersions.matches(binary: path, version: version) {
                continue
            }
            return path
        }
        throw BuildError.invalid(String(localized: "\(name) \(version) was not found. Install it: brew install php@\(version)"))
    }

    /// A free TCP port for nginx to talk to php-fpm.
    private static func freePort(startingAt start: Int) -> Int {
        var port = start
        while port < 65535 {
            if PortScanner.isPortFree(port, host: "127.0.0.1") { return port }
            port += 1
        }
        return start
    }

    private static func require(_ tool: String) throws -> String {
        guard let path = ShellEnvironment.shared.which(tool) else {
            throw BuildError.toolNotFound(tool)
        }
        return path
    }

    /// Parsing an argument string, respecting quotes.
    static func splitArguments(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in raw {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
