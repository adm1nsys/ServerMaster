import Foundation

/// Only named Homebrew formulae and the global http-server npm package are
/// managed. No shell interpolation, sudo, force-uninstall or forced linking.
@MainActor
final class RuntimePackages {
    struct Package: Equatable {
        let formula: String
        let latest: String
        let installed: [String]
        let prefix: String
        let activePath: String?
        let isManaged: Bool
        let outdated: Bool
    }

    enum Action: Equatable { case install, update, remove }
    typealias Runner = @MainActor (String, [String], TimeInterval) async -> CommandResult
    private let run: Runner
    private let which: (String) -> String?
    private let canonical: (String) -> String

    init(run: @escaping Runner = { await ProcessRunner.run($0, $1, timeout: $2) },
         which: @escaping (String) -> String? = { ShellEnvironment.shared.which($0) },
         canonical: @escaping (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
        self.run = run
        self.which = which
        self.canonical = canonical
    }

    static let formulae = ["node": "node", "npm": "node", "python3": "python", "php": "php", "php-fpm": "php", "mariadbd": "mariadb", "nginx": "nginx", "httpd": "httpd", "caddy": "caddy", "openssl": "openssl@3", "mkcert": "mkcert"]

    static func supports(_ command: String) -> Bool { formulae[command] != nil || command == "http-server" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func execute(_ executable: String, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        let result = await run(executable, args, timeout)
        guard result.succeeded else {
            throw Failure(message: result.combined.isEmpty ? String(localized: "The package manager could not complete the operation.") : result.combined)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validNodeFormula(_ value: String) -> Bool {
        value.range(of: #"^node(?:@[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func npmVersions(_ json: String) throws -> [String] {
        let values = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        let versions = Set(values.filter { $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil })
        guard !versions.isEmpty else { throw Failure(message: String(localized: "The package catalogue returned no supported versions.")) }
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Resolve versioned Cellar formulae from the detected binary so updating
    /// node@22 never accidentally upgrades a different default node formula.
    private func formula(for command: String) throws -> String {
        guard let fallback = Self.formulae[command] else {
            throw Failure(message: String(localized: "This tool is not managed here."))
        }
        if let path = which(command) {
            let components = canonical(path).split(separator: "/").map(String.init)
            if let index = components.firstIndex(of: "Cellar"), components.indices.contains(index + 1) {
                let candidate = components[index + 1]
                let stem = fallback.components(separatedBy: "@")[0]
                if candidate == stem || candidate.range(of: "^\(stem)@[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil {
                    return candidate
                }
            }
        }
        return fallback
    }

    func inspect(command: String) async throws -> Package {
        if command == "http-server" { return try await inspectNpm() }
        return try await inspectFormula(try formula(for: command), command: command)
    }

    private func inspectFormula(_ formula: String, command: String) async throws -> Package {
        let raw = try await execute("brew", ["info", "--json=v2", "--formula", formula])
        struct Info: Decodable {
            struct Formula: Decodable {
                struct Versions: Decodable { let stable: String? }
                struct Installed: Decodable { let version: String }
                let name: String
                let aliases: [String]?
                let versions: Versions
                let installed: [Installed]
                let outdated: Bool
            }
            let formulae: [Formula]
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(raw.utf8))
        guard let entry = info.formulae.first,
              entry.name == formula || entry.aliases?.contains(formula) == true,
              let latest = entry.versions.stable else {
            throw Failure(message: String(localized: "The package catalogue returned an unexpected result."))
        }
        let prefix = try await execute("brew", ["--prefix", formula])
        guard prefix.hasPrefix("/"), prefix != "/" else {
            throw Failure(message: String(localized: "The package manager returned an invalid installation path."))
        }
        let path = which(command)
        let managed = path.map { canonical($0).hasPrefix(canonical(prefix) + "/") } ?? false
        return Package(formula: entry.name, latest: latest, installed: entry.installed.map(\.version),
                       prefix: prefix, activePath: path, isManaged: managed, outdated: entry.outdated)
    }

    private func inspectNpm() async throws -> Package {
        let prefix = try await execute("npm", ["prefix", "--global"])
        guard prefix.hasPrefix("/"), prefix != "/" else {
            throw Failure(message: String(localized: "The package manager returned an invalid installation path."))
        }
        let raw = try await execute("npm", ["list", "--global", "--depth=0", "--json"])
        struct Installed: Decodable {
            struct Entry: Decodable { let version: String }
            let dependencies: [String: Entry]?
        }
        let version = try JSONDecoder().decode(Installed.self, from: Data(raw.utf8)).dependencies?["http-server"]?.version
        let latestRaw = try await execute("npm", ["view", "http-server", "version", "--json"])
        let latest = try JSONDecoder().decode(String.self, from: Data(latestRaw.utf8))
        guard latest.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw Failure(message: String(localized: "The package catalogue returned an unexpected result."))
        }
        let path = which("http-server")
        let managed = path.map { canonical($0).hasPrefix(canonical(prefix) + "/") } ?? false
        return Package(formula: "http-server", latest: latest, installed: version.map { [$0] } ?? [],
                       prefix: prefix, activePath: path, isManaged: managed,
                       outdated: version.map { $0.compare(latest, options: .numeric) == .orderedAscending } ?? false)
    }

    func versions(command: String) async throws -> [String] {
        if command == "http-server" {
            return try Self.npmVersions(await execute("npm", ["view", "http-server", "versions", "--json"]))
        }
        guard command == "node" || command == "npm" else { return [] }
        let output = try await execute("brew", ["search", "--formula", "/^node(@[0-9]+)?$/"])
        let values = Set(output.components(separatedBy: .whitespacesAndNewlines).filter(Self.validNodeFormula))
        guard !values.isEmpty else { throw Failure(message: String(localized: "The package catalogue returned no supported versions.")) }
        return values.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Returns the selected Node bin directory; the UI persists it as a PATH
    /// preference only after successful installation and executable verification.
    func perform(command: String, action: Action, selectedVersion: String? = nil,
                 log: ConsoleLog, beforeRemoval: (Package) throws -> Void = { _ in }) async throws -> String? {
        if let selectedVersion {
            guard action == .install else {
                throw Failure(message: String(localized: "Choose Install to select a package version."))
            }
            let offered = try await versions(command: command)
            guard offered.contains(selectedVersion) else {
                throw Failure(message: String(localized: "That version is not offered by the package manager."))
            }
        }
        let current = try await inspect(command: command)
        if action != .install || selectedVersion == nil && current.activePath != nil {
            guard current.isManaged else {
                throw Failure(message: String(localized: "The active executable is outside this package manager. It has not been changed."))
            }
        }
        let formula = selectedVersion != nil && command != "http-server" ? selectedVersion! : current.formula
        var arguments: [String]
        let executable: String
        if command == "http-server" {
            executable = "npm"
            switch action {
            case .remove: arguments = ["uninstall", "--global", "http-server"]
            case .update, .install: arguments = ["install", "--global", "http-server@\(selectedVersion ?? current.latest)"]
            }
        } else {
            executable = "brew"
            arguments = [action == .remove ? "uninstall" : action == .update ? "upgrade" : "install", "--formula", formula]
        }
        if action == .remove { try beforeRemoval(current) }
        log.system(([executable] + arguments).joined(separator: " "))
        let result = await run(executable, arguments, 1800)
        if !result.combined.isEmpty { log.append(result.combined, stream: result.succeeded ? .stdout : .stderr) }
        guard result.succeeded else { throw Failure(message: result.combined) }
        ShellEnvironment.shared.invalidate()

        if command != "http-server", let selectedVersion {
            let selected = try await inspectFormula(selectedVersion, command: "node")
            let bin = selected.prefix + "/bin"
            let checked = await run(bin + "/node", ["--version"], 15)
            let actual = checked.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedMajor = selectedVersion.components(separatedBy: "@").last!
            guard checked.succeeded, !selected.installed.isEmpty,
                  actual.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  selected.installed.contains(where: { $0 == String(actual.dropFirst()) || $0.hasPrefix(String(actual.dropFirst()) + "_") }),
                  selectedVersion == "node" || actual.hasPrefix("v\(expectedMajor).") else {
                throw Failure(message: String(localized: "The requested Node version was not activated."))
            }
            return bin
        }
        let after = command == "http-server" ? try await inspectNpm() : try await inspectFormula(current.formula, command: command)
        if action == .remove {
            guard after.installed.isEmpty else { throw Failure(message: String(localized: "The package is still installed. See the log for details.")) }
        } else {
            guard after.isManaged, !after.installed.isEmpty else {
                throw Failure(message: String(localized: "The installed package is not active in PATH. Review the detected executable path."))
            }
            if action == .update && after.outdated {
                throw Failure(message: String(localized: "The package manager still reports an older version. See the log for details."))
            }
            guard let path = after.activePath, let dependency = Dependency.byCommand(command) else {
                throw Failure(message: String(localized: "The installed executable could not be verified."))
            }
            let verified = await run(path, dependency.versionArguments, 15)
            guard verified.succeeded else { throw Failure(message: verified.combined) }
            if command == "http-server", let wanted = selectedVersion ?? (action == .update ? current.latest : nil) {
                let detected = verified.combined.trimmingCharacters(in: .whitespacesAndNewlines)
                guard after.installed.contains(wanted), detected == wanted || detected == "v" + wanted else {
                    throw Failure(message: String(localized: "The requested package version was not activated."))
                }
            }
        }
        return nil
    }
}
