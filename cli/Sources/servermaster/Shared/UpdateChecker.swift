//
//  UpdateChecker.swift
//  ServerMaster
//
//  Update checking on a simple scheme:
//    lastversion.txt in the repository root holds the latest version number,
//    next to it a mac/<version> folder holds the build.
//  If the version in the file is greater than the installed one — show a banner
//  linking to that folder. Nothing is downloaded and nothing is executed.
//

import Foundation
import Observation
import AppKit

nonisolated struct ReleaseInfo: Sendable, Equatable {
    var version: String
    var name: String
    var notes: String
    var pageURL: String
    var publishedAt: Date?
    /// The branch the version was found in.
    var branch: String = ""
    /// The build folder exists — the link works.
    var buildFolderExists: Bool = true
}

nonisolated enum UpdateState: Equatable, Sendable {
    case notConfigured
    case idle
    case checking
    case upToDate(Date)
    case available(ReleaseInfo)
    case failed(String)

    var isChecking: Bool { self == .checking }
}

@Observable
final class UpdateChecker {

    private(set) var state: UpdateState = .notConfigured

    /// “owner/repo” or the full repository address.
    var repository: String = "" {
        didSet { if state == .notConfigured && !normalizedRepository.isEmpty { state = .idle } }
    }

    /// The file in the repository root holding the latest version number.
    var versionFile: String = "lastversion.txt"

    /// The builds folder: a subfolder named after the version is expected inside it.
    var buildsFolder: String = "mac"

    /// The installed version. A separate property so it can be checked in tests.
    var currentVersion: String = AppInfo.version

    /// Branches to look for the version file in. The first one found wins.
    var branches: [String] = ["main", "master"]

    /// Substituted in tests so they do not reach GitHub.
    var rawBaseURL = "https://raw.githubusercontent.com"
    var siteBaseURL = "https://github.com"
    var apiBaseURL = "https://api.github.com"

    /// Normalise to “owner/repo” — both a link and the short form are accepted.
    var normalizedRepository: String {
        var value = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] {
            if value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { return "" }
        return "\(parts[0])/\(parts[1])"
    }

    var isConfigured: Bool { !normalizedRepository.isEmpty }

    /// The address of the version file — shown in settings so it is clear where we look.
    var versionFileURL: String {
        let repo = normalizedRepository
        guard !repo.isEmpty else { return "" }
        return "\(rawBaseURL)/\(repo)/\(branches.first ?? "main")/\(versionFile)"
    }

    // MARK: - Checking

    func check(silently: Bool = false) async {
        let repo = normalizedRepository
        guard !repo.isEmpty else {
            state = .notConfigured
            return
        }
        state = .checking

        var lastError: String?

        for branch in branches {
            let path = "\(rawBaseURL)/\(repo)/\(branch)/\(versionFile)"
            guard let url = URL(string: path) else { continue }

            do {
                let (data, response) = try await fetch(url)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 404 {
                    lastError = String(localized: "File \(versionFile) was not found in branch \(branch).")
                    continue
                }
                guard http.statusCode == 200 else {
                    lastError = String(localized: "GitHub responded with code \(String(http.statusCode)).")
                    continue
                }

                let raw = String(decoding: data, as: UTF8.self)
                guard let latest = Self.parseVersion(raw) else {
                    lastError = String(localized: "There is no version number in \(versionFile).")
                    continue
                }

                guard Self.isNewer(latest, than: currentVersion) else {
                    state = .upToDate(Date())
                    return
                }

                let folder = "\(buildsFolder)/\(latest)"
                let exists = await buildFolderExists(repo: repo, branch: branch, folder: folder)
                let pageURL = exists
                    ? "\(siteBaseURL)/\(repo)/tree/\(branch)/\(folder)"
                    : "\(siteBaseURL)/\(repo)"

                state = .available(ReleaseInfo(
                    version: latest,
                    name: String(localized: "Version \(latest)"),
                    notes: "",
                    pageURL: pageURL,
                    publishedAt: nil,
                    branch: branch,
                    buildFolderExists: exists))
                return

            } catch {
                lastError = error.localizedDescription
            }
        }

        if silently {
            state = .idle
        } else {
            state = .failed(lastError ?? String(localized: "Could not check for updates."))
        }
    }

    /// Does the mac/<version> folder exist — otherwise the link would lead nowhere.
    private func buildFolderExists(repo: String, branch: String, folder: String) async -> Bool {
        let encoded = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder
        guard let url = URL(string: "\(apiBaseURL)/repos/\(repo)/contents/\(encoded)?ref=\(branch)") else {
            return false
        }
        guard let (_, response) = try? await fetch(url),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // raw.githubusercontent caches responses on its CDN — ask for a fresh one.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("ServerMaster/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }

    // MARK: - Links

    func openReleasePage() {
        guard case .available(let release) = state,
              let url = URL(string: release.pageURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func openRepository() {
        let repo = normalizedRepository
        guard !repo.isEmpty, let url = URL(string: "\(siteBaseURL)/\(repo)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Parsing and comparison

    /// Extract the version number from the contents of lastversion.txt.
    /// Tolerates stray spaces, a newline, a BOM and a “v” prefix.
    nonisolated static func parseVersion(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard var value = cleaned else { return nil }

        value = value.trimmingCharacters(in: .whitespaces)
        while let first = value.first, !first.isNumber { value.removeFirst() }
        // Cut off everything after the number: “1.2.3 (beta)” → “1.2.3”
        value = String(value.prefix { $0.isNumber || $0 == "." })
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !value.isEmpty, value.contains(where: \.isNumber) else { return nil }
        return value
    }

    /// Comparison of the form 1.10.0 > 1.9.3.
    ///
    /// If the installed version cannot be parsed, assume there is no update:
    /// better to stay quiet than to nag about updating on every check.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateVersion = parseVersion(candidate),
              let currentVersion = parseVersion(current) else { return false }
        let lhs = candidateVersion.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = currentVersion.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
