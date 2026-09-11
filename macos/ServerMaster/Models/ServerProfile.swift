//
//  ServerProfile.swift
//  ServerMaster
//

import Foundation

nonisolated struct EnvVar: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String = ""
    var value: String = ""
}

/// A launch profile — everything needed to start one server precisely.
nonisolated struct ServerProfile: Codable, Identifiable, Hashable, Sendable {

    var id = UUID()
    var name: String = String(localized: "New profile")
    var engine: ServerEngine = .httpServer
    /// The profile's own icon. Empty — the engine's icon is used.
    var iconName: String = ""

    // MARK: Network
    var host: String = "127.0.0.1"
    var port: Int = 8080

    // MARK: Files
    /// The document root.
    var rootPath: String = NSHomeDirectory() + "/Sites"
    /// The process working directory. Empty → rootPath is used.
    var workingDirectory: String = ""
    /// Path to the config (nginx.conf / Caddyfile). Empty → generate one.
    var configPath: String = ""

    // MARK: HTTPS
    var httpsEnabled: Bool = false
    var certificatePath: String = ""
    var privateKeyPath: String = ""

    // MARK: Static options
    var enableCORS: Bool = false
    var enableGzip: Bool = true
    var directoryListing: Bool = true
    var spaFallback: Bool = false          // every 404 → index.html
    var cacheSeconds: Int = -1             // -1 = no-cache
    var basicAuthEnabled: Bool = false
    var basicAuthUser: String = ""
    var basicAuthPassword: String = ""
    var indexFile: String = "index.html"

    // MARK: Node / custom
    var nodeEntryFile: String = "server.js"
    var customCommand: String = ""
    var customArguments: String = ""

    /// Run the server as root — needed for ports below 1024.
    /// The password is asked for once at startup by a system window.
    var runAsAdministrator: Bool = false

    // MARK: Protection
    /// Do not serve files starting with a dot (.env, .git and the like).
    var hideDotfiles: Bool = true
    /// Basic protective headers: nosniff, frame denial, referrer-policy.
    var securityHeaders: Bool = false
    /// HSTS — the browser will remember that this host is HTTPS only.
    var hstsEnabled: Bool = false

    // MARK: Error pages
    /// Custom pages for 404, 403, 500 and the other codes.
    var customErrorPages: Bool = false
    /// Accent colour of the error pages, in HEX.
    var errorPageAccent: String = "#3B82F6"
    /// Caption at the bottom of an error page. Empty — the profile name is used.
    var errorPageFooter: String = ""

    // MARK: PHP
    /// PHP limits — on a local bench the defaults are usually not enough.
    var phpMemoryLimit: String = "256M"
    var phpUploadMaxFilesize: String = "64M"
    var phpMaxExecutionTime: Int = 300
    var phpDisplayErrors: Bool = true
    /// An empty value — take php-fpm from PATH. Otherwise a specific brew version.
    var phpVersion: String = ""

    // MARK: Miscellaneous
    var extraArguments: String = ""
    var environment: [EnvVar] = []
    var openBrowserOnStart: Bool = false
    var notes: String = ""

    // MARK: - Tolerant decoding
    //
    // The synthesized Decodable fails on any missing key, even when the field has
    // a default value. Because of that, a file written by an earlier version of
    // the application stopped being readable as a whole and the settings reset.
    // So every field is read separately, falling back to its default.

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerProfile()
        id = container.value(.id, default: defaults.id)
        name = container.value(.name, default: defaults.name)
        engine = container.value(.engine, default: defaults.engine)
        iconName = container.value(.iconName, default: defaults.iconName)
        host = container.value(.host, default: defaults.host)
        port = container.value(.port, default: defaults.port)
        rootPath = container.value(.rootPath, default: defaults.rootPath)
        workingDirectory = container.value(.workingDirectory, default: defaults.workingDirectory)
        configPath = container.value(.configPath, default: defaults.configPath)
        httpsEnabled = container.value(.httpsEnabled, default: defaults.httpsEnabled)
        certificatePath = container.value(.certificatePath, default: defaults.certificatePath)
        privateKeyPath = container.value(.privateKeyPath, default: defaults.privateKeyPath)
        enableCORS = container.value(.enableCORS, default: defaults.enableCORS)
        enableGzip = container.value(.enableGzip, default: defaults.enableGzip)
        directoryListing = container.value(.directoryListing, default: defaults.directoryListing)
        spaFallback = container.value(.spaFallback, default: defaults.spaFallback)
        cacheSeconds = container.value(.cacheSeconds, default: defaults.cacheSeconds)
        basicAuthEnabled = container.value(.basicAuthEnabled, default: defaults.basicAuthEnabled)
        basicAuthUser = container.value(.basicAuthUser, default: defaults.basicAuthUser)
        basicAuthPassword = container.value(.basicAuthPassword, default: defaults.basicAuthPassword)
        indexFile = container.value(.indexFile, default: defaults.indexFile)
        nodeEntryFile = container.value(.nodeEntryFile, default: defaults.nodeEntryFile)
        customCommand = container.value(.customCommand, default: defaults.customCommand)
        customArguments = container.value(.customArguments, default: defaults.customArguments)
        runAsAdministrator = container.value(.runAsAdministrator, default: defaults.runAsAdministrator)
        hideDotfiles = container.value(.hideDotfiles, default: defaults.hideDotfiles)
        securityHeaders = container.value(.securityHeaders, default: defaults.securityHeaders)
        hstsEnabled = container.value(.hstsEnabled, default: defaults.hstsEnabled)
        customErrorPages = container.value(.customErrorPages, default: defaults.customErrorPages)
        errorPageAccent = container.value(.errorPageAccent, default: defaults.errorPageAccent)
        errorPageFooter = container.value(.errorPageFooter, default: defaults.errorPageFooter)
        phpMemoryLimit = container.value(.phpMemoryLimit, default: defaults.phpMemoryLimit)
        phpUploadMaxFilesize = container.value(.phpUploadMaxFilesize, default: defaults.phpUploadMaxFilesize)
        phpMaxExecutionTime = container.value(.phpMaxExecutionTime, default: defaults.phpMaxExecutionTime)
        phpDisplayErrors = container.value(.phpDisplayErrors, default: defaults.phpDisplayErrors)
        phpVersion = container.value(.phpVersion, default: defaults.phpVersion)
        extraArguments = container.value(.extraArguments, default: defaults.extraArguments)
        environment = container.value(.environment, default: defaults.environment)
        openBrowserOnStart = container.value(.openBrowserOnStart, default: defaults.openBrowserOnStart)
        notes = container.value(.notes, default: defaults.notes)
    }
    // MARK: Computed

    var effectiveWorkingDirectory: String {
        let wd = workingDirectory.trimmingCharacters(in: .whitespaces)
        if !wd.isEmpty { return AppPaths.expand(wd) }
        if engine.usesRootDirectory { return AppPaths.expand(rootPath) }
        return NSHomeDirectory()
    }

    /// Icon for lists: the profile's own if set, otherwise the engine's.
    var symbol: String {
        iconName.isEmpty ? engine.symbol : iconName
    }

    var scheme: String { (httpsEnabled && engine.supportsHTTPS) ? "https" : "http" }

    var displayHost: String {
        (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
    }

    /// The single place where the address is assembled. Every screen takes it from
    /// here, otherwise it is easy to forget String(port) and get “8.080” from the locale.
    var address: String {
        "\(scheme)://\(displayHost):\(String(port))"
    }

    var primaryURL: URL? {
        URL(string: address)
    }

    /// Configuration problems that must be shown to the user before starting.
    var validationIssues: [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "Empty profile name."))
        }
        if port < 1 || port > 65535 {
            issues.append(String(localized: "The port must be between 1 and 65535."))
        }
        if port < 1024 && !runAsAdministrator {
            issues.append(String(localized: "Port \(String(port)) is privileged and usually requires root."))
        }
        if engine.usesRootDirectory {
            let root = AppPaths.expand(rootPath)
            var isDir: ObjCBool = false
            if root.isEmpty {
                issues.append(String(localized: "No root directory specified."))
            } else if !FileManager.default.fileExists(atPath: root, isDirectory: &isDir) {
                issues.append(String(localized: "Directory does not exist: \(root)"))
            } else if !isDir.boolValue {
                issues.append(String(localized: "This is a file, not a directory: \(root)"))
            }
        }
        // Serving a PHP site as static files is dangerous: the engine does not execute
        // the code, and the browser receives the source along with the database password.
        if engine.usesRootDirectory && !engine.runsPHP {
            let root = AppPaths.expand(rootPath)
            let fm = FileManager.default
            let markers = ["index.php", "wp-config.php", "configuration.php",
                           "composer.json", "artisan"]
            if markers.contains(where: {
                fm.fileExists(atPath: (root as NSString).appendingPathComponent($0))
            }) {
                issues.append(String(localized: "The folder contains PHP files, but the selected engine does not execute them — the browser would receive the source code. Pick “PHP site (Nginx + PHP-FPM)”."))
            }
        }

        // A common mistake: pointing at the project root instead of the folder with
        // index.php. That is how Laravel and Symfony (public) and composer-built Drupal (web) work.
        if engine.usesRootDirectory {
            let root = AppPaths.expand(rootPath)
            let fm = FileManager.default
            let hasIndexHere = ["index.php", "index.html"].contains {
                fm.fileExists(atPath: (root as NSString).appendingPathComponent($0))
            }
            if !hasIndexHere {
                for folder in ["public", "web", "dist", "build"] {
                    let candidate = (root as NSString).appendingPathComponent(folder)
                    let hasIndexThere = ["index.php", "index.html"].contains {
                        fm.fileExists(atPath: (candidate as NSString).appendingPathComponent($0))
                    }
                    if hasIndexThere {
                        issues.append(String(localized: "There is no index file in the root, but there is one in “\(folder)”. That folder is probably the real site root."))
                        break
                    }
                }
            }
        }
        if engine == .custom && customCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "No launch command specified."))
        }
        if engine == .nodeScript {
            let entry = resolvedNodeEntry
            if !FileManager.default.fileExists(atPath: entry) {
                issues.append(String(localized: "Entry file not found: \(entry)"))
            }
        }
        if httpsEnabled && engine.supportsHTTPS {
            if certificatePath.isEmpty || privateKeyPath.isEmpty {
                issues.append(String(localized: "HTTPS is on, but no certificate or key is selected."))
            } else {
                if !FileManager.default.fileExists(atPath: AppPaths.expand(certificatePath)) {
                    issues.append(String(localized: "Certificate not found: \(certificatePath)"))
                }
                if !FileManager.default.fileExists(atPath: AppPaths.expand(privateKeyPath)) {
                    issues.append(String(localized: "Private key not found: \(privateKeyPath)"))
                }
            }
        }
        if httpsEnabled && !engine.supportsHTTPS {
            issues.append(String(localized: "\(engine.title) does not support HTTPS — the setting will be ignored."))
        }
        if basicAuthEnabled && (basicAuthUser.isEmpty || basicAuthPassword.isEmpty) {
            issues.append(String(localized: "Basic authentication is on, but no login and password are set."))
        }
        if hstsEnabled && !(httpsEnabled && engine.supportsHTTPS) {
            issues.append(String(localized: "HSTS is on without HTTPS — the header will have no effect."))
        }
        if engine == .phpFpm && !phpVersion.trimmingCharacters(in: .whitespaces).isEmpty {
            let version = phpVersion.trimmingCharacters(in: .whitespaces)
            let candidates = ["/opt/homebrew/opt/php@\(version)/sbin/php-fpm",
                              "/usr/local/opt/php@\(version)/sbin/php-fpm"]
            if !candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                issues.append(String(localized: "PHP \(version) is not installed. Run: brew install php@\(version)"))
            }
        }
        if customErrorPages && !engine.supportsErrorPages {
            issues.append(String(localized: "\(engine.title) cannot serve custom error pages."))
        }
        if host == "0.0.0.0" {
            issues.append(String(localized: "The server will be reachable by everyone on the local network, not just this Mac."))
        }
        return issues
    }

    var resolvedNodeEntry: String {
        let entry = nodeEntryFile.trimmingCharacters(in: .whitespaces)
        if entry.hasPrefix("/") || entry.hasPrefix("~") { return AppPaths.expand(entry) }
        return (effectiveWorkingDirectory as NSString).appendingPathComponent(entry)
    }

    var environmentDictionary: [String: String] {
        var dict: [String: String] = [:]
        for item in environment where !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
            dict[item.key.trimmingCharacters(in: .whitespaces)] = item.value
        }
        return dict
    }

    /// A copy for duplicating a profile.
    func duplicated() -> ServerProfile {
        var copy = self
        copy.id = UUID()
        copy.name = name + String(localized: " (copy)")
        copy.environment = environment.map { EnvVar(id: UUID(), key: $0.key, value: $0.value) }
        return copy
    }
}
