//
//  UpdateCommands.swift
//  servermaster
//
//  The CLI update path is intentionally plain: a tiny text file says which
//  version is latest, and a GitHub Release carries the zipped executable.
//  Nothing is hidden behind the app bundle, so the command can update itself
//  even when ServerMaster.app is not installed.
//

import Foundation

struct CLIUpdateSettings: Codable {
    var automaticChecks: Bool = true
    var lastCheckedAt: Date?
}

enum CLIUpdateManager {

    static let repository = "adm1nsys/ServerMaster"
    static let defaultVersionURL = "https://raw.githubusercontent.com/\(repository)/main/updates/clilastversion.txt"

    private static var settingsURL: URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".servermaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cli-settings.json")
    }

    static func loadSettings() -> CLIUpdateSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(CLIUpdateSettings.self, from: data) else {
            return CLIUpdateSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: CLIUpdateSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    static func latestVersion() async throws -> String {
        let rawURL = ProcessInfo.processInfo.environment["SERVERMASTER_CLI_VERSION_URL"] ?? defaultVersionURL
        guard let url = URL(string: rawURL) else { throw CLIUpdateError.badURL(rawURL) }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (received, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw CLIUpdateError.githubStatus(http.statusCode)
            }
            data = received
        }
        let raw = String(decoding: data, as: UTF8.self)
        guard let version = UpdateChecker.parseVersion(raw) else {
            throw CLIUpdateError.noVersion(rawURL)
        }
        return version
    }

    static func noticeIfDue(now: Date = Date()) async -> String? {
        var settings = loadSettings()
        guard settings.automaticChecks else { return nil }
        if let last = settings.lastCheckedAt,
           now.timeIntervalSince(last) < 24 * 60 * 60 {
            return nil
        }
        settings.lastCheckedAt = now
        try? saveSettings(settings)
        guard let latest = try? await latestVersion(),
              UpdateChecker.isNewer(latest, than: CLIVersion.version) else {
            return nil
        }
        return "servermaster \(latest) is available. Run: servermaster update install --yes"
    }

    static var releaseAssetName: String {
        #if os(macOS)
        return "servermaster-macos-universal.zip"
        #elseif os(Linux)
        #if canImport(Glibc)
        return "servermaster-linux-glibc.tar.gz"
        #else
        return "servermaster-linux-musl.tar.gz"
        #endif
        #else
        return "servermaster.zip"
        #endif
    }

    static func releaseAssetURL(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/cli-v\(version)/\(releaseAssetName)")!
    }

    static func runningExecutablePath() -> String? {
        let argv0 = CommandLine.arguments.first ?? "servermaster"
        let candidate: String
        if argv0.contains("/") {
            let url = URL(fileURLWithPath: argv0,
                          relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            candidate = url.standardizedFileURL.path
        } else if let found = ShellEnvironment.shared.which(argv0) {
            candidate = found
        } else if let bundle = Bundle.main.executablePath {
            candidate = bundle
        } else {
            return nil
        }
        return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
    }
}

enum CLIUpdateError: LocalizedError {
    case badURL(String)
    case githubStatus(Int)
    case noVersion(String)
    case missingExecutable
    case appBundleExecutable(String)
    case archiveDidNotContainBinary
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let url): return "Bad update URL: \(url)"
        case .githubStatus(let code): return "GitHub responded with HTTP \(code)."
        case .noVersion(let url): return "No version number found in \(url)."
        case .missingExecutable: return "Could not locate the running servermaster executable."
        case .appBundleExecutable(let path):
            return "This command points into ServerMaster.app (\(path)). Update the app, or install the standalone CLI."
        case .archiveDidNotContainBinary: return "The downloaded archive did not contain a servermaster executable."
        case .permission(let path): return "No permission to replace \(path)."
        }
    }
}

extension Commands {

    func update() async -> ExitCode {
        let subcommand = options.first ?? "check"
        switch subcommand {
        case "check": return await updateCheck()
        case "install", "self": return await updateInstall()
        case "auto": return updateAuto()
        default:
            printer.error("Unknown update command. Try: servermaster update check")
            return .usage
        }
    }

    private func updateCheck() async -> ExitCode {
        do {
            let latest = try await CLIUpdateManager.latestVersion()
            let available = UpdateChecker.isNewer(latest, than: CLIVersion.version)
            if options.json {
                printer.json([
                    "current": CLIVersion.version,
                    "latest": latest,
                    "available": available,
                    "versionFile": CLIUpdateManager.defaultVersionURL,
                    "release": CLIUpdateManager.releaseAssetURL(version: latest).absoluteString
                ])
            } else if available {
                printer.line("servermaster \(latest) is available.")
                printer.line("Install it with: servermaster update install --yes")
            } else {
                printer.line("servermaster \(CLIVersion.version) is up to date.")
            }
            return .ok
        } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
    }

    private func updateAuto() -> ExitCode {
        let value = options.arguments.dropFirst().first ?? "status"
        var settings = CLIUpdateManager.loadSettings()
        switch value.lowercased() {
        case "on", "enable", "enabled":
            settings.automaticChecks = true
        case "off", "disable", "disabled":
            settings.automaticChecks = false
        case "status":
            break
        default:
            printer.error("Use: servermaster update auto on|off|status")
            return .usage
        }
        do {
            try CLIUpdateManager.saveSettings(settings)
        } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
        if options.json {
            printer.json([
                "automaticChecks": settings.automaticChecks,
                "lastCheckedAt": settings.lastCheckedAt.map { ISO8601DateFormatter().string(from: $0) } as Any
            ].compactMapValues { $0 })
        } else {
            printer.line("Automatic CLI update checks are \(settings.automaticChecks ? "on" : "off").")
        }
        return .ok
    }

    private func updateInstall() async -> ExitCode {
        guard options.flags["yes"] != nil else {
            printer.error("This replaces the installed servermaster binary. Re-run with --yes.")
            return .usage
        }
        do {
            let latest = try await CLIUpdateManager.latestVersion()
            guard UpdateChecker.isNewer(latest, than: CLIVersion.version) else {
                printer.line("servermaster \(CLIVersion.version) is already current.")
                return .ok
            }

            guard let current = CLIUpdateManager.runningExecutablePath() else {
                throw CLIUpdateError.missingExecutable
            }
            if current.contains(".app/Contents/") {
                throw CLIUpdateError.appBundleExecutable(current)
            }

            let downloaded = try await downloadReleaseBinary(version: latest)
            try replaceExecutable(current, with: downloaded, version: latest)
            printer.line("Updated servermaster from \(CLIVersion.version) to \(latest).")
            return .ok
        } catch {
            printer.result(false, error.localizedDescription)
            return .failed
        }
    }

    private func downloadReleaseBinary(version: String) async throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("servermaster-cli-\(version)-\(UUID().uuidString).zip")
        let extract = FileManager.default.temporaryDirectory
            .appendingPathComponent("servermaster-cli-\(version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)

        let (data, response) = try await URLSession.shared.data(from: CLIUpdateManager.releaseAssetURL(version: version))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CLIUpdateError.githubStatus(http.statusCode)
        }
        try data.write(to: archive, options: .atomic)

        let unzip = await ProcessRunner.run("/usr/bin/unzip", ["-q", archive.path, "-d", extract.path])
        guard unzip.succeeded else {
            throw CLIUpdateError.archiveDidNotContainBinary
        }

        let contents = FileManager.default.enumerator(at: extract, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        guard let binary = contents.first(where: {
            $0.lastPathComponent == "servermaster" && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CLIUpdateError.archiveDidNotContainBinary
        }
        return binary
    }

    private func replaceExecutable(_ current: String, with downloaded: URL, version: String) throws {
        let destination = URL(fileURLWithPath: current)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent("servermaster-\(CLIVersion.version).backup")

        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw CLIUpdateError.permission(destination.path)
        }

        if FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: destination, to: backup)
        do {
            try FileManager.default.copyItem(at: downloaded, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: destination)
            throw error
        }
    }
}
