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
        let defaultPath = defaultBinary.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var found: [Installed] = []
        for version in known {
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                let path = "\(prefix)/php@\(version)/sbin/php-fpm"
                if FileManager.default.isExecutableFile(atPath: path) {
                    found.append(Installed(version: version, binary: path,
                                           isDefault: URL(fileURLWithPath: path).resolvingSymlinksInPath().path == defaultPath))
                    break
                }
            }
        }
        // The plain `php` formula, which has no version in its path. It is very
        // often the same version as one already found through php@X.Y — listing
        // it again would show one version twice, each with its own buttons.
        if let defaultBinary, !found.contains(where: \.isDefault) {
            let resolved = URL(fileURLWithPath: defaultBinary).resolvingSymlinksInPath().path
            let version = quickVersion(resolved.replacingOccurrences(of: "/sbin/php-fpm", with: "/bin/php")) ?? "?"
            if let index = found.firstIndex(where: { $0.version == version }) {
                found[index].isDefault = true
            } else {
                found.append(Installed(version: version, binary: defaultBinary, isDefault: true))
            }
        }
        return found.sorted { $0.version < $1.version }
    }

    /// A fast check for validation in SwiftUI: inspect Homebrew's resolved
    /// version path instead of running PHP on each edit of the profile.
    static func matchesHomebrewPath(_ path: String, version: String,
                                   canonical: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> Bool {
        let parts = canonical(path).split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "Cellar"), parts.indices.contains(index + 2),
              parts[index + 1] == "php" || parts[index + 1] == "php@" + version else { return false }
        return parts[index + 2].split(separator: ".").prefix(2).joined(separator: ".") == version
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

    static func versionProbe(_ binary: String) -> ExecutableProbe.Result {
        ExecutableProbe.run(binary, arguments: ["-r", "echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;"],
                            environment: ShellEnvironment.shared.environment(), timeout: 2)
    }

    private static func quickVersion(_ binary: String) -> String? {
        let result = versionProbe(binary)
        guard result.succeeded else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let result = await Task.detached(priority: .utility) {
            ExecutableProbe.run(binary, arguments: ["-m"], environment: ShellEnvironment.shared.environment(), timeout: 20)
        }.value
        guard result.succeeded else { return [] }
        return Set(result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") })
    }
}

@Observable
final class DependencyChecker {

    struct Probes {
        var refreshEnvironment: () async -> Void = { await ShellEnvironment.shared.refresh() }
        var dependency: @Sendable (Dependency) async -> DependencyStatus = { await DependencyChecker.check($0) }
        var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        var canonical: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var run: @MainActor (String, [String], TimeInterval) async -> CommandResult = {
            await ProcessRunner.run($0, $1, timeout: $2)
        }
        var extensions: () async -> Set<String> = { await PHPExtensions.installed() }
        var versions: () async -> [PHPVersions.Installed] = {
            await Task.detached(priority: .utility) { PHPVersions.scan() }.value
        }
    }
    private let probes: Probes
    init(probes: Probes? = nil, runtimePackages: RuntimePackages? = nil) {
        self.probes = probes ?? Probes()
        self.runtimePackages = runtimePackages ?? RuntimePackages()
    }

    let runtimePackages: RuntimePackages
    let nodeReleases = NodeReleases()
    private(set) var isManagingPackages = false

    func managePackages(_ operation: () async throws -> Void) async throws {
        guard !isManagingPackages, !isChecking, installingPHP.isEmpty else {
            throw RuntimePackages.Failure(message: String(localized: "Wait for the current dependency operation to finish."))
        }
        isManagingPackages = true
        defer { isManagingPackages = false }
        try await operation()
    }

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

    func missingTools(for profile: ServerProfile) -> [String] {
        missingRequirements(for: profile).map(\.title)
    }

    func missingRequirements(for profile: ServerProfile, template: ProfileTemplate? = nil) -> [ProfileRequirement] {
        ProfileRequirement.list(for: profile, template: template).filter { requirement in
            if !requirement.phpVersion.isEmpty { return phpPath(for: requirement) == nil }
            return !status(for: requirement.command).installed
        }
    }

    private func phpPath(for requirement: ProfileRequirement) -> String? {
        let command = requirement.command
        let version = requirement.phpVersion
        if version.isEmpty {
            if let path = status(for: command).path { return path }
            guard let item = phpVersions.first(where: \.isDefault) else { return nil }
            return command == "php-fpm" ? item.binary : item.binary.replacingOccurrences(of: "/sbin/php-fpm", with: "/bin/php")
        }
        let folder = command == "php-fpm" ? "sbin" : "bin"
        let candidates = ["/opt/homebrew/opt/php@\(version)/\(folder)/\(command)",
                          "/usr/local/opt/php@\(version)/\(folder)/\(command)"]
        if let path = candidates.first(where: probes.isExecutable) { return path }
        // scan() has already checked the version of the unversioned formula.
        for item in phpVersions where item.version == version {
            let path = command == "php-fpm" ? item.binary : item.binary.replacingOccurrences(of: "/sbin/php-fpm", with: "/bin/php")
            if probes.isExecutable(path) { return path }
        }
        return nil
    }

    func profilesUsingPHP(formula: String, profiles: [ServerProfile]) -> [ServerProfile] {
        guard formula == "php" || formula.hasPrefix("php@") else { return [] }
        return profiles.filter { profile in
            guard profile.engine.runsPHP else { return false }
            let version = profile.phpVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty, formula == "php@" + version { return true }
            let command = profile.engine == .phpBuiltIn ? "php" : "php-fpm"
            guard let path = phpPath(for: .init(command: command, phpVersion: version)) else {
                return version.isEmpty && formula == "php"
            }
            let parts = probes.canonical(path).split(separator: "/").map(String.init)
            if let index = parts.firstIndex(of: "Cellar"), parts.indices.contains(index + 1) {
                return parts[index + 1] == formula
            }
            return path.contains("/opt/" + formula + "/")
        }
    }

    func checkPHPRemoval(formula: String, profiles: [ServerProfile]) throws {
        let users = profilesUsingPHP(formula: formula, profiles: profiles)
        guard users.isEmpty else {
            throw RuntimePackages.Failure(message: String(localized: "This PHP package is used by: \(users.map(\.name).joined(separator: ", ")). Change their PHP selection before removing it."))
        }
    }

    func installMissing(for profile: ServerProfile, template: ProfileTemplate? = nil,
                        log: ConsoleLog, canChange: () -> Bool) async throws {
        try await managePackages {
            guard canChange() else { throw RuntimePackages.Failure(message: String(localized: "Stop servers and the database before changing packages.")) }
            await checkAll()
            var missing = missingRequirements(for: profile, template: template)
            // npm is needed to install http-server even if an imported template
            // did not list the package manager itself.
            if missing.contains(where: { $0.command == "http-server" }), !status(for: "npm").installed,
               !missing.contains(where: { $0.command == "npm" }) { missing.insert(.init(command: "npm"), at: 0) }
            let order = ["node", "npm", "php", "php-fpm", "python3", "mariadbd", "nginx", "httpd", "caddy", "http-server"]
            missing.sort { (order.firstIndex(of: $0.command) ?? 99) < (order.firstIndex(of: $1.command) ?? 99) }
            for requirement in missing {
                try Task.checkCancellation()
                guard canChange() else { throw RuntimePackages.Failure(message: String(localized: "Stop servers and the database before changing packages.")) }
                // Recheck after each install: one package may provide multiple tools.
                guard missingRequirements(for: profile, template: template).contains(requirement)
                        || (requirement.command == "npm" && !status(for: "npm").installed) else { continue }
                if !requirement.phpVersion.isEmpty {
                    guard await installPHPUnlocked(version: requirement.phpVersion, log: log) else {
                        throw RuntimePackages.Failure(message: String(localized: "PHP \(requirement.phpVersion) did not install. The log above says why."))
                    }
                } else {
                    _ = try await runtimePackages.perform(command: requirement.command, action: .install, log: log)
                }
                await checkAll()
            }
            let remaining = missingRequirements(for: profile, template: template)
            guard remaining.isEmpty else {
                throw RuntimePackages.Failure(message: String(localized: "Not installed: \(remaining.map(\.title).joined(separator: ", "))"))
            }
        }
    }

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        await probes.refreshEnvironment()

        for dependency in Dependency.catalog {
            statuses[dependency.command, default: DependencyStatus()].checking = true
        }

        let probe = probes.dependency
        await withTaskGroup(of: (String, DependencyStatus).self) { group in
            for dependency in Dependency.catalog {
                group.addTask {
                    (dependency.command, await probe(dependency))
                }
            }
            for await (command, status) in group {
                statuses[command] = status
            }
        }

        phpExtensions = await probes.extensions()
        phpVersions = await probes.versions()
        lastCheck = Date()
        isChecking = false
    }

    func check(command: String) async {
        guard !isChecking, !status(for: command).checking else { return }
        guard let dependency = Dependency.byCommand(command) else { return }
        statuses[command, default: DependencyStatus()].checking = true
        statuses[command] = await probes.dependency(dependency)
    }

    private nonisolated static func check(_ dependency: Dependency) async -> DependencyStatus {
        guard let path = ShellEnvironment.shared.which(dependency.command) else {
            return DependencyStatus(installed: false, path: nil, version: nil, checking: false)
        }
        let result = await Task.detached(priority: .utility) {
            ExecutableProbe.run(path, arguments: dependency.versionArguments,
                                environment: ShellEnvironment.shared.environment(), timeout: 15, includeStandardError: true)
        }.value
        let raw = result.succeeded ? result.output : ""
        let version = raw
            .split(separator: "\n")
            .first
            .map { String($0.prefix(256)).trimmingCharacters(in: .whitespaces) }
        return DependencyStatus(installed: true, path: path, version: version, checking: false)
    }

    /// Installing a dependency — progress goes to the console that was passed in.
    /// Installs a PHP version through Homebrew. Picking a version the profile
    /// needs and being told to go and type a brew command is a poor answer when
    /// the app already knows how to run brew.
    func installPHP(version: String, log: ConsoleLog) async -> Bool {
        guard !isManagingPackages, installingPHP.isEmpty else { return false }
        isManagingPackages = true
        defer { isManagingPackages = false }
        return await installPHPUnlocked(version: version, log: log)
    }

    private func installPHPUnlocked(version: String, log: ConsoleLog) async -> Bool {
        let wanted = version.trimmingCharacters(in: .whitespaces)
        guard PHPVersions.known.contains(wanted) else {
            log.append(String(localized: "PHP \(wanted) is not a version Homebrew offers."), stream: .stderr)
            return false
        }
        guard status(for: "brew").installed || ShellEnvironment.shared.which("brew") != nil else {
            log.append(String(localized: "Homebrew is not installed — see the Dependencies screen."), stream: .stderr)
            return false
        }

        installingPHP.insert(wanted)
        defer { installingPHP.remove(wanted) }

        log.system(String(localized: "Installing PHP \(wanted). This takes a few minutes."))
        let result = await probes.run("brew", ["install", "--formula", "php@\(wanted)"], 1800)
        if !result.stdout.isEmpty { log.append(result.stdout, stream: .stdout) }
        if !result.stderr.isEmpty { log.append(result.stderr, stream: .stderr) }

        phpVersions = await probes.versions()
        let ok = result.succeeded && phpVersions.contains { $0.version == wanted }
        log.system(ok
                   ? String(localized: "PHP \(wanted) is ready.")
                   : String(localized: "PHP \(wanted) did not install. The log above says why."))
        return ok
    }

    /// Removes a version. Never touches the plain `php` formula: that is the one
    /// the rest of the system is probably using.
    func uninstallPHP(version: String, profiles: [ServerProfile], log: ConsoleLog, canChange: () -> Bool) async -> Bool {
        guard !isManagingPackages, installingPHP.isEmpty else { return false }
        isManagingPackages = true
        defer { isManagingPackages = false }
        let wanted = version.trimmingCharacters(in: .whitespaces)
        guard PHPVersions.known.contains(wanted), canChange() else { return false }
        do { try checkPHPRemoval(formula: "php@" + wanted, profiles: profiles) }
        catch { log.append(error.localizedDescription, stream: .stderr); return false }
        installingPHP.insert(wanted)
        defer { installingPHP.remove(wanted) }

        log.system(String(localized: "Removing PHP \(wanted)…"))
        let result = await probes.run("brew", ["uninstall", "--formula", "php@\(wanted)"], 900)
        if !result.combined.isEmpty { log.append(result.combined, stream: .stdout) }
        phpVersions = await probes.versions()
        return result.succeeded && !phpVersions.contains { $0.version == wanted }
    }

    func install(_ dependency: Dependency, log: ConsoleLog) async {
        guard !isManagingPackages, installingPHP.isEmpty else { return }
        isManagingPackages = true
        defer { isManagingPackages = false }
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
