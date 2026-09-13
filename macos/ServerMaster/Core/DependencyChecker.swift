//
//  DependencyChecker.swift
//  ServerMaster
//

import Foundation
import Observation

nonisolated enum DependencyKind: String, Sendable, CaseIterable {
    case runtime
    case server
    case tooling

    var title: String {
        switch self {
        case .runtime: return String(localized: "Runtimes")
        case .server:  return String(localized: "Servers")
        case .tooling: return String(localized: "Tools")
        }
    }

    var symbol: String {
        switch self {
        case .runtime: return "cpu"
        case .server:  return "server.rack"
        case .tooling: return "wrench.and.screwdriver"
        }
    }
}

nonisolated struct Dependency: Identifiable, Sendable, Hashable {
    var id: String { command }
    var command: String
    var title: String
    var summary: String
    var kind: DependencyKind
    var versionArguments: [String]
    var installCommand: String
    var required: Bool          // needed by at least one standard profile
    var website: String

    static let catalog: [Dependency] = [
        Dependency(command: "node", title: "Node.js", summary: String(localized: "Runtime for http-server and your own servers"),
                   kind: .runtime, versionArguments: ["--version"],
                   installCommand: "brew install node", required: true,
                   website: "https://nodejs.org"),
        Dependency(command: "npm", title: "npm", summary: String(localized: "The Node.js package manager"),
                   kind: .runtime, versionArguments: ["--version"],
                   installCommand: "brew install node", required: true,
                   website: "https://npmjs.com"),
        Dependency(command: "http-server", title: "http-server", summary: String(localized: "The main static serving engine"),
                   kind: .server, versionArguments: ["--version"],
                   installCommand: "npm install --global http-server", required: true,
                   website: "https://github.com/http-party/http-server"),
        Dependency(command: "python3", title: "Python 3", summary: String(localized: "The python -m http.server engine"),
                   kind: .runtime, versionArguments: ["--version"],
                   installCommand: "brew install python", required: false,
                   website: "https://python.org"),
        Dependency(command: "php", title: "PHP", summary: String(localized: "PHP built-in server"),
                   kind: .runtime, versionArguments: ["--version"],
                   installCommand: "brew install php", required: false,
                   website: "https://php.net"),
        Dependency(command: "php-fpm", title: "PHP-FPM",
                   summary: String(localized: "Runs PHP behind Nginx — required for Joomla and WordPress"),
                   kind: .server, versionArguments: ["-v"],
                   installCommand: "brew install php", required: false,
                   website: "https://php.net"),
        Dependency(command: "mariadbd", title: "MariaDB",
                   summary: String(localized: "Database for CMSes: Joomla, WordPress and others"),
                   kind: .server, versionArguments: ["--version"],
                   installCommand: "brew install mariadb", required: false,
                   website: "https://mariadb.org"),
        Dependency(command: "nginx", title: "Nginx", summary: String(localized: "A full web server and proxy"),
                   kind: .server, versionArguments: ["-v"],
                   installCommand: "brew install nginx", required: false,
                   website: "https://nginx.org"),
        Dependency(command: "httpd", title: "Apache",
                   summary: String(localized: "Reads .htaccess. macOS carries a copy, but only the Homebrew one can serve a site kept in Documents, Desktop or Downloads."),
                   kind: .server, versionArguments: ["-v"],
                   installCommand: "brew install httpd", required: true,
                   website: "https://httpd.apache.org"),
        Dependency(command: "caddy", title: "Caddy", summary: String(localized: "Web server with automatic HTTPS"),
                   kind: .server, versionArguments: ["version"],
                   installCommand: "brew install caddy", required: false,
                   website: "https://caddyserver.com"),
        Dependency(command: "openssl", title: "OpenSSL", summary: String(localized: "Generating self-signed certificates"),
                   kind: .tooling, versionArguments: ["version"],
                   installCommand: "brew install openssl", required: true,
                   website: "https://openssl.org"),
        Dependency(command: "mkcert", title: "mkcert", summary: String(localized: "Local certificates the system trusts"),
                   kind: .tooling, versionArguments: ["-version"],
                   installCommand: "brew install mkcert nss", required: false,
                   website: "https://github.com/FiloSottile/mkcert"),
        Dependency(command: "lsof", title: "lsof", summary: String(localized: "Viewing busy ports"),
                   kind: .tooling, versionArguments: ["-v"],
                   installCommand: String(localized: "Ships with macOS"), required: true,
                   website: "https://apple.com"),
        Dependency(command: "brew", title: "Homebrew", summary: String(localized: "Installing the other dependencies"),
                   kind: .tooling, versionArguments: ["--version"],
                   installCommand: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
                   required: false, website: "https://brew.sh")
    ]

    static func byCommand(_ command: String) -> Dependency? {
        catalog.first { $0.command == command }
    }
}

nonisolated struct DependencyStatus: Sendable, Hashable {
    var installed: Bool = false
    var path: String?
    var version: String?
    var checking: Bool = false
}

/// The PHP extensions without which a typical CMS will not install.
/// PHP versions installed through Homebrew.
nonisolated enum PHPVersions {

    nonisolated struct Installed: Identifiable, Sendable, Hashable {
        var id: String { version }
        var version: String        // 8.3
        var binary: String         // path to php-fpm
        var isDefault: Bool        // this is the php that is in PATH
    }

    /// The versions Homebrew is able to install.
    static let known = ["8.1", "8.2", "8.3", "8.4", "8.5"]

    static func scan() -> [Installed] {
        let defaultBinary = ShellEnvironment.shared.which("php-fpm")
        var found: [Installed] = []
        for version in known {
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                let path = "\(prefix)/php@\(version)/sbin/php-fpm"
                if FileManager.default.isExecutableFile(atPath: path) {
                    found.append(Installed(version: version, binary: path,
                                           isDefault: path == defaultBinary))
                    break
                }
            }
        }
        // The plain `php` formula, which has no version in its path. It is very
        // often the same version as one already found through php@X.Y — listing
        // it again would show one version twice, each with its own buttons.
        if let defaultBinary, !found.contains(where: \.isDefault) {
            let version = defaultVersion() ?? "?"
            if let index = found.firstIndex(where: { $0.version == version }) {
                found[index].isDefault = true
            } else {
                found.append(Installed(version: version, binary: defaultBinary, isDefault: true))
            }
        }
        return found.sorted { $0.version < $1.version }
    }

    /// Whether a specific binary's version matches the expected one.
    static func matches(binary: String, version: String) -> Bool {
        // Does php-fpm understand -r too? No, so ask the php next to it.
        let php = binary.replacingOccurrences(of: "/sbin/php-fpm", with: "/bin/php")
        guard let actual = quickVersion(php) else { return false }
        return actual == version
    }

    /// The version of the php currently in PATH.
    static func defaultVersion() -> String? {
        guard let php = ShellEnvironment.shared.which("php") else { return nil }
        return quickVersion(php)
    }

    private static func quickVersion(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-r", "echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ShellEnvironment.shared.environment()
        guard (try? process.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
        process.waitUntilExit()
        let text = String(decoding: data ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

nonisolated enum PHPExtensions {
    static let required = ["mysqli", "pdo_mysql", "gd", "zip", "intl",
                           "mbstring", "curl", "xml", "json", "openssl", "fileinfo"]

    /// Returns the list of installed extensions (lower-cased).
    static func installed(phpBinary: String? = nil) async -> Set<String> {
        let binary = phpBinary ?? ShellEnvironment.shared.which("php")
        guard let binary else { return [] }
        let result = await ProcessRunner.run(binary, ["-m"], timeout: 20)
        guard result.succeeded else { return [] }
        return Set(result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") })
    }
}

@Observable
final class DependencyChecker {

    private(set) var statuses: [String: DependencyStatus] = [:]
    private(set) var isChecking = false
    private(set) var lastCheck: Date?
    private(set) var phpExtensions: Set<String> = []
    private(set) var phpVersions: [PHPVersions.Installed] = []
    /// Versions being installed or removed right now, so the UI can show it.
    private(set) var installingPHP: Set<String> = []

    func status(for command: String) -> DependencyStatus {
        statuses[command] ?? DependencyStatus()
    }

    /// Which PHP extensions are missing for a typical CMS.
    var missingPHPExtensions: [String] {
        guard !phpExtensions.isEmpty else { return [] }
        return PHPExtensions.required.filter { !phpExtensions.contains($0) }
    }

    func isSatisfied(_ engine: ServerEngine) -> Bool {
        engine.requiredTools.allSatisfy { status(for: $0).installed }
    }

    func missingTools(for engine: ServerEngine) -> [String] {
        engine.requiredTools.filter { !status(for: $0).installed }
    }

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        ShellEnvironment.shared.invalidate()

        for dependency in Dependency.catalog {
            statuses[dependency.command, default: DependencyStatus()].checking = true
        }

        await withTaskGroup(of: (String, DependencyStatus).self) { group in
            for dependency in Dependency.catalog {
                group.addTask {
                    (dependency.command, await Self.check(dependency))
                }
            }
            for await (command, status) in group {
                statuses[command] = status
            }
        }

        phpExtensions = await PHPExtensions.installed()
        phpVersions = PHPVersions.scan()
        lastCheck = Date()
        isChecking = false
    }

    func check(command: String) async {
        guard let dependency = Dependency.byCommand(command) else { return }
        statuses[command, default: DependencyStatus()].checking = true
        statuses[command] = await Self.check(dependency)
    }

    private nonisolated static func check(_ dependency: Dependency) async -> DependencyStatus {
        guard let path = ShellEnvironment.shared.which(dependency.command) else {
            return DependencyStatus(installed: false, path: nil, version: nil, checking: false)
        }
        let result = await ProcessRunner.run(path, dependency.versionArguments, timeout: 15)
        let raw = result.combined
        let version = raw
            .split(separator: "\n")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return DependencyStatus(installed: true, path: path, version: version, checking: false)
    }

    /// Installing a dependency — progress goes to the console that was passed in.
    /// Installs a PHP version through Homebrew. Picking a version the profile
    /// needs and being told to go and type a brew command is a poor answer when
    /// the app already knows how to run brew.
    func installPHP(version: String, log: ConsoleLog) async -> Bool {
        let wanted = version.trimmingCharacters(in: .whitespaces)
        guard PHPVersions.known.contains(wanted) else {
            log.append(String(localized: "PHP \(wanted) is not a version Homebrew offers."), stream: .stderr)
            return false
        }
        guard ShellEnvironment.shared.which("brew") != nil else {
            log.append(String(localized: "Homebrew is not installed — see the Dependencies screen."), stream: .stderr)
            return false
        }

        installingPHP.insert(wanted)
        defer { installingPHP.remove(wanted) }

        log.system(String(localized: "Installing PHP \(wanted). This takes a few minutes."))
        let result = await ProcessRunner.shell("brew install php@\(wanted)", timeout: 1800)
        if !result.stdout.isEmpty { log.append(result.stdout, stream: .stdout) }
        if !result.stderr.isEmpty { log.append(result.stderr, stream: .stderr) }

        phpVersions = PHPVersions.scan()
        let ok = phpVersions.contains { $0.version == wanted }
        log.system(ok
                   ? String(localized: "PHP \(wanted) is ready.")
                   : String(localized: "PHP \(wanted) did not install. The log above says why."))
        return ok
    }

    /// Removes a version. Never touches the plain `php` formula: that is the one
    /// the rest of the system is probably using.
    func uninstallPHP(version: String, log: ConsoleLog) async -> Bool {
        let wanted = version.trimmingCharacters(in: .whitespaces)
        guard PHPVersions.known.contains(wanted) else { return false }
        installingPHP.insert(wanted)
        defer { installingPHP.remove(wanted) }

        log.system(String(localized: "Removing PHP \(wanted)…"))
        let result = await ProcessRunner.shell("brew uninstall --ignore-dependencies php@\(wanted)", timeout: 900)
        if !result.combined.isEmpty { log.append(result.combined, stream: .stdout) }
        phpVersions = PHPVersions.scan()
        return !phpVersions.contains { $0.version == wanted }
    }

    func install(_ dependency: Dependency, log: ConsoleLog) async {
        log.system(String(localized: "Installing \(dependency.title): \(dependency.installCommand)"))
        let result = await ProcessRunner.shell(dependency.installCommand, timeout: 900)
        if !result.stdout.isEmpty { log.append(result.stdout, stream: .stdout) }
        if !result.stderr.isEmpty { log.append(result.stderr, stream: .stderr) }
        log.system(result.succeeded
                   ? String(localized: "Done: \(dependency.title) installed.")
                   : String(localized: "Installation finished with code \(String(result.exitCode))."))
        await check(command: dependency.command)
    }
}
