//
//  AppInfo.swift
//  ServerMaster
//

import Foundation

nonisolated enum AppInfo {

    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ServerMaster"
    }

    /// The version shown to the user
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// The build number
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    static var versionLine: String { String(localized: "Version \(version) (build \(build))") }

    /// The version as numbers — for comparing with the release on GitHub
    static var versionComponents: [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "—"
        #endif
    }

    /// The build number is not a counter — it records where the build came from.
    ///
    ///     <host>.<macOS>.b<beta>.<target>
    ///     arm    .27.0   .b6    .arm
    ///
    /// `host` is the architecture the build was made on, `macOS` the system it
    /// was built against, `b<n>` that system's developer beta (absent on a
    /// released system), and `target` what the binary runs on: `arm` for Apple
    /// Silicon only, `uni` for a universal build.
    static var buildIdentifier: BuildIdentifier { BuildIdentifier(build) }
}

nonisolated struct BuildIdentifier: Sendable, Equatable {

    var raw: String
    var host: String?
    var system: String?
    var beta: Int?
    var target: String?

    init(_ raw: String) {
        self.raw = raw
        var digits: [String] = []
        var archs: [String] = []
        for part in raw.split(separator: ".").map(String.init) {
            let token = part.lowercased()
            if token.first == "b", let n = Int(token.dropFirst()) {
                beta = n
            } else if !part.isEmpty, part.allSatisfy(\.isNumber) {
                digits.append(part)
            } else {
                archs.append(token)
            }
        }
        // The first two numbers are the system version; anything after is noise.
        // A single number is a plain build counter, not a version — leave it alone.
        if digits.count >= 2 { system = digits.prefix(2).joined(separator: ".") }
        host = archs.first
        target = archs.last
    }

    /// What the binary runs on.
    var targetName: String? {
        switch target {
        case "arm", "arm64": String(localized: "Apple Silicon")
        case "uni", "universal": String(localized: "Universal")
        case "x86", "x86_64", "intel": String(localized: "Intel")
        default: nil
        }
    }

    /// The system the build was made against.
    var systemName: String? {
        guard let system else { return nil }
        guard let beta else { return "macOS \(system)" }
        return String(localized: "macOS \(system) developer beta \(String(beta))")
    }

    /// One readable line, e.g. “macOS 27.0 developer beta 6 · Apple Silicon”.
    /// Returns nil when the build number does not follow the scheme.
    var summary: String? {
        let parts = [systemName, targetName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
