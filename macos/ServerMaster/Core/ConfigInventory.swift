//
//  ConfigInventory.swift
//  ServerMaster
//
//  Collects every file belonging to a profile: engine configs, PHP settings,
//  the site's own files and the logs. So they need not be hunted for by hand.
//

import Foundation

nonisolated struct ConfigFile: Identifiable, Sendable, Hashable {

    enum Kind: String, Sendable, CaseIterable {
        case engine     // engine config (nginx.conf, Caddyfile)
        case runtime    // php-fpm.conf and the like
        case interpreter // php.ini
        case site       // files inside the site folder
        case log        // logs

        var title: String {
            switch self {
            case .engine:      return String(localized: "Engine config")
            case .runtime:     return String(localized: "Service configs")
            case .interpreter: return String(localized: "PHP settings")
            case .site:        return String(localized: "Site files")
            case .log:         return String(localized: "Logs")
            }
        }

        var symbol: String {
            switch self {
            case .engine:      return "gearshape.2"
            case .runtime:     return "wrench.adjustable"
            case .interpreter: return "curlybraces"
            case .site:        return "folder"
            case .log:         return "text.alignleft"
            }
        }
    }

    /// What to check the syntax with before saving.
    enum Validator: Sendable, Hashable {
        case none
        case nginx
        case apache
        case caddyfile
        case php
        case phpFpm
        case ini
    }

    var id: String { path }
    var title: String
    var path: String
    var kind: Kind
    var note: String = ""
    var validator: Validator = .none
    /// The file is overwritten by the application on every launch.
    var isGenerated: Bool = false
    var isReadOnly: Bool = false

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var sizeText: String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return "" }
        let bytes = size.doubleValue
        if bytes < 1024 { return "\(Int(bytes)) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / 1048576)
    }
}

nonisolated enum ConfigInventory {

    /// Every file worth showing for a profile.
    static func files(for profile: ServerProfile, databaseLogPath: String? = nil) -> [ConfigFile] {
        var result: [ConfigFile] = []
        let fm = FileManager.default

        // ── Engine config ─────────────────────────────────
        let userConfig = AppPaths.expand(profile.configPath.trimmingCharacters(in: .whitespaces))
        if !userConfig.isEmpty {
            result.append(ConfigFile(
                title: (userConfig as NSString).lastPathComponent,
                path: userConfig,
                kind: .engine,
                note: String(localized: "Your own file — the app never overwrites it."),
                validator: validator(for: profile.engine)))
        }

        switch profile.engine {
        case .nginx:
            let prefix = runtimePrefix("nginx", profile)
            if userConfig.isEmpty {
                result.append(generated(prefix + "/nginx.conf", .engine, .nginx,
                                        String(localized: "Generated from the profile settings on every start.")))
            }
            result.append(contentsOf: nginxLogs(prefix))

        case .phpFpm:
            let prefix = runtimePrefix("php", profile)
            if userConfig.isEmpty {
                result.append(generated(prefix + "/nginx.conf", .engine, .nginx,
                                        String(localized: "Generated from the profile settings on every start.")))
            }
            result.append(generated(prefix + "/php-fpm.conf", .runtime, .phpFpm,
                                    String(localized: "The PHP-FPM pool: memory, upload and execution time limits.")))
            result.append(contentsOf: nginxLogs(prefix))
            result.append(ConfigFile(title: "php-fpm.log", path: prefix + "/logs/php-fpm.log",
                                     kind: .log, isReadOnly: true))
            result.append(ConfigFile(title: "php-error.log", path: prefix + "/logs/php-error.log",
                                     kind: .log,
                                     note: String(localized: "PHP errors — look here when the page is blank."),
                                     isReadOnly: true))

        case .apache, .apachePHP:
            let prefix = runtimePrefix("apache", profile)
            if userConfig.isEmpty {
                result.append(generated(prefix + "/httpd.conf", .engine, .apache,
                                        String(localized: "Generated from the profile settings on every start.")))
            }
            if profile.engine == .apachePHP {
                result.append(generated(prefix + "/php-fpm.conf", .runtime, .phpFpm,
                                        String(localized: "The PHP-FPM pool: memory, upload and execution time limits.")))
                result.append(ConfigFile(title: "php-fpm.log", path: prefix + "/logs/php-fpm.log",
                                         kind: .log, isReadOnly: true))
                result.append(ConfigFile(title: "php-error.log", path: prefix + "/logs/php-error.log",
                                         kind: .log,
                                         note: String(localized: "PHP errors — look here when the page is blank."),
                                         isReadOnly: true))
            }
            result.append(contentsOf: nginxLogs(prefix))

        case .caddy:
            let prefix = runtimePrefix("caddy", profile)
            if userConfig.isEmpty {
                result.append(generated(prefix + "/Caddyfile", .engine, .caddyfile,
                                        String(localized: "Generated from the profile settings on every start.")))
            }

        case .httpServer, .nodeScript, .pythonHTTP, .phpBuiltIn, .custom:
            break
        }

        // A profile running as root keeps its log separately.
        if profile.runAsAdministrator {
            let prefix = runtimePrefix("root", profile)
            result.append(ConfigFile(title: String(localized: "Administrator start log"),
                                     path: prefix + "/privileged.log",
                                     kind: .log, isReadOnly: true))
        }

        // ── Interpreter settings ──────────────────────────
        if profile.engine.runsPHP, let ini = phpIniPath(version: profile.phpVersion) {
            result.append(ConfigFile(
                title: "php.ini",
                path: ini,
                kind: .interpreter,
                note: String(localized: "Global PHP settings. The profile limits are applied on top and win."),
                validator: .ini))
        }

        // ── Site files ────────────────────────────────────
        if profile.engine.usesRootDirectory {
            let root = AppPaths.expand(profile.rootPath)
            for candidate in siteCandidates {
                let path = (root as NSString).appendingPathComponent(candidate.name)
                guard fm.fileExists(atPath: path) else { continue }
                result.append(ConfigFile(title: candidate.name, path: path, kind: .site,
                                         note: candidate.note, validator: candidate.validator))
            }
        }

        // ── Database ──────────────────────────────────────
        if profile.engine.typicallyNeedsDatabase, let databaseLogPath {
            result.append(ConfigFile(title: String(localized: "Database log"),
                                     path: databaseLogPath,
                                     kind: .log, isReadOnly: true))
        }

        return result
    }

    /// The files inside the site folder that most often need editing.
    private static let siteCandidates: [(name: String, note: String, validator: ConfigFile.Validator)] = [
        ("configuration.php", String(localized: "Joomla configuration: database, paths, debugging."), .php),
        ("wp-config.php", String(localized: "WordPress configuration."), .php),
        (".env", String(localized: "Project environment variables."), .none),
        (".htaccess", String(localized: "Apache rules. Nginx does not read them — the rules you need are moved into its config."), .none),
        ("htaccess.txt", String(localized: "The .htaccess template shipped with Joomla."), .none),
        ("web.config", String(localized: "IIS configuration, unused on macOS."), .none),
        ("composer.json", String(localized: "PHP dependencies."), .none),
        ("package.json", String(localized: "Node.js dependencies."), .none),
        ("index.php", String(localized: "The site entry point."), .php),
        ("index.html", String(localized: "Start page."), .none)
    ]

    // MARK: - Helpers

    /// Only computes the path. This used to call subdir, which created the folder
    /// as soon as the editor was opened — simply looking at the file list littered
    /// Runtime with empty directories.
    private static func runtimePrefix(_ kind: String, _ profile: ServerProfile) -> String {
        AppPaths.support
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("\(kind)-\(profile.id.uuidString.prefix(8))", isDirectory: true)
            .path
    }

    private static func generated(_ path: String, _ kind: ConfigFile.Kind,
                                  _ validator: ConfigFile.Validator, _ note: String) -> ConfigFile {
        ConfigFile(title: (path as NSString).lastPathComponent, path: path, kind: kind,
                   note: note, validator: validator, isGenerated: true)
    }

    private static func nginxLogs(_ prefix: String) -> [ConfigFile] {
        [
            ConfigFile(title: "nginx error.log", path: prefix + "/logs/error.log",
                       kind: .log, isReadOnly: true),
            ConfigFile(title: "nginx access.log", path: prefix + "/logs/access.log",
                       kind: .log, isReadOnly: true)
        ]
    }

    private static func validator(for engine: ServerEngine) -> ConfigFile.Validator {
        switch engine {
        case .nginx, .phpFpm:     return .nginx
        case .apache, .apachePHP: return .apache
        case .caddy:              return .caddyfile
        default:              return .none
        }
    }

    /// Path to the php.ini of the chosen version.
    static func phpIniPath(version: String) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            for base in ["/opt/homebrew/etc/php/\(trimmed)/php.ini",
                         "/usr/local/etc/php/\(trimmed)/php.ini"]
            where FileManager.default.fileExists(atPath: base) {
                return base
            }
        }
        for candidate in ["/opt/homebrew/etc/php/8.5/php.ini",
                          "/opt/homebrew/etc/php/8.4/php.ini",
                          "/opt/homebrew/etc/php/8.3/php.ini",
                          "/usr/local/etc/php/php.ini",
                          "/etc/php.ini"]
        where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Syntax checking

    nonisolated struct ValidationResult: Sendable {
        var ok: Bool
        var message: String
        var skipped: Bool = false
    }

    /// Checks the file before saving, so a broken config does not bring the server down.
    static func validate(_ file: ConfigFile, contents: String) async -> ValidationResult {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-validate-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension((file.path as NSString).pathExtension.isEmpty
                                    ? "conf" : (file.path as NSString).pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
        } catch {
            return ValidationResult(ok: false, message: error.localizedDescription)
        }

        switch file.validator {
        case .none:
            return ValidationResult(ok: true, message: "", skipped: true)

        case .nginx:
            guard ShellEnvironment.shared.which("nginx") != nil else {
                return ValidationResult(ok: true, message: "", skipped: true)
            }
            let prefix = (file.path as NSString).deletingLastPathComponent
            let result = await ProcessRunner.run("nginx", ["-t", "-p", prefix, "-c", temporary.path],
                                                 timeout: 30)
            return ValidationResult(ok: result.succeeded,
                                    message: clean(result.combined, temporary: temporary.path, as: file.title))

        case .apache:
            let binary = ["/usr/sbin/httpd",
                          "/opt/homebrew/opt/httpd/bin/httpd",
                          "/usr/local/opt/httpd/bin/httpd"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                ?? ShellEnvironment.shared.which("httpd")
            guard let binary else {
                return ValidationResult(ok: true, message: "", skipped: true)
            }
            let apache = await ProcessRunner.run(binary, ["-f", temporary.path, "-t"], timeout: 30)
            return ValidationResult(ok: apache.succeeded,
                                    message: clean(apache.combined, temporary: temporary.path, as: file.title))

        case .caddyfile:
            guard ShellEnvironment.shared.which("caddy") != nil else {
                return ValidationResult(ok: true, message: "", skipped: true)
            }
            let result = await ProcessRunner.run("caddy",
                                                 ["validate", "--config", temporary.path,
                                                  "--adapter", "caddyfile"],
                                                 timeout: 40)
            return ValidationResult(ok: result.succeeded,
                                    message: clean(result.combined, temporary: temporary.path, as: file.title))

        case .php:
            guard ShellEnvironment.shared.which("php") != nil else {
                return ValidationResult(ok: true, message: "", skipped: true)
            }
            let result = await ProcessRunner.run("php", ["-l", temporary.path], timeout: 30)
            return ValidationResult(ok: result.succeeded,
                                    message: clean(result.combined, temporary: temporary.path, as: file.title))

        case .phpFpm:
            guard let binary = ShellEnvironment.shared.which("php-fpm") else {
                return ValidationResult(ok: true, message: "", skipped: true)
            }
            let result = await ProcessRunner.run(binary, ["-t", "-y", temporary.path], timeout: 30)
            return ValidationResult(ok: result.succeeded,
                                    message: clean(result.combined, temporary: temporary.path, as: file.title))

        case .ini:
            // There is no real validator for ini — check for gross format errors.
            var problems: [String] = []
            for (index, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    if !line.hasSuffix("]") { problems.append("\(index + 1): unclosed section") }
                    continue
                }
                if !line.contains("=") { problems.append("\(index + 1): line without “=”") }
            }
            return ValidationResult(ok: problems.isEmpty,
                                    message: problems.prefix(5).joined(separator: "\n"))
        }
    }

    /// The tools check a temporary copy and write its path into the error.
    /// Substitute the real file name, otherwise the message is confusing.
    private static func clean(_ text: String, temporary: String, as displayName: String) -> String {
        let temporaryDirectory = (temporary as NSString).deletingLastPathComponent
        return text
            .replacingOccurrences(of: temporary, with: displayName)
            .replacingOccurrences(of: temporaryDirectory, with: displayName)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
