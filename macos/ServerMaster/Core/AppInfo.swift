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

    /// The oldest macOS this build declares it can run on. Read from the bundle
    /// rather than written by hand, so it cannot drift from the deployment target.
    static var minimumSystemVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
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

    /// Build provenance, separate from the application version and minimum OS.
    ///
    ///     <host>.m<macOS>[b].x<Xcode>[b<iteration>].<target>
    ///     arm   .m27.3b   .x27.3b1              .uni
    ///
    /// Host `arm` describes the build machine; target `uni` describes the binary.
    /// Released tools omit the beta suffix. Older labels remain readable.
    static var buildIdentifier: BuildIdentifier { BuildIdentifier(build) }


}

nonisolated struct BuildIdentifier: Sendable, Equatable {

    var raw: String
    var host: String?
    var system: String?
    var systemIsBeta = false
    /// The beta number in the legacy Xcode-beta convention, not a macOS version.
    var beta: Int?
    var xcodeRelease: String?
    var xcodeVersion: String?
    var xcodeBeta: Int?
    var target: String?

    init(_ raw: String) {
        self.raw = raw
        if let fields = Self.fields(in: raw, pattern: #"^([a-z0-9_]+)\.m([0-9]+\.[0-9]+(?:\.[0-9]+)?)(b?)\.x([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:b([1-9][0-9]*))?\.([a-z0-9_-]+)$"#) {
            host = fields[0]?.lowercased()
            system = fields[1]
            systemIsBeta = fields[2]?.lowercased() == "b"
            xcodeVersion = fields[3]
            xcodeBeta = fields[4].flatMap(Int.init)
            if xcodeBeta == nil { xcodeRelease = xcodeVersion }
            target = fields[5]?.lowercased()
        } else if let fields = Self.fields(in: raw, pattern: #"^([a-z0-9_]+)\.(b?)([0-9]+\.[0-9]+(?:\.[0-9]+)?)\.xr([0-9]+\.[0-9]+(?:\.[0-9]+)?)\.([a-z0-9_]+)$"#) {
            host = fields[0]?.lowercased()
            systemIsBeta = fields[1]?.lowercased() == "b"
            system = fields[2]
            xcodeRelease = fields[3]
            target = fields[4]?.lowercased()
        } else if let fields = Self.fields(in: raw, pattern: #"^([a-z0-9_]+)\.([0-9]+\.[0-9]+(?:\.[0-9]+)?)(?:\.b([0-9]+))?\.([a-z0-9_]+)$"#) {
            host = fields[0]?.lowercased()
            system = fields[1]
            beta = fields[2].flatMap(Int.init)
            target = fields[3]?.lowercased()
        }
    }

    private static func fields(in raw: String, pattern: String) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.range == NSRange(raw.startIndex..., in: raw) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: raw).map { String(raw[$0]) }
        }
    }

    /// The architecture of the shipped binary, rather than the build machine.
    var targetName: String? {
        switch target {
        case "arm", "arm64": String(localized: "Apple Silicon")
        case "uni", "universal": String(localized: "Universal")
        case "int", "x86", "x86_64", "intel": String(localized: "Intel")
        default: nil
        }
    }

    var systemName: String? {
        guard let system else { return nil }
        return systemIsBeta ? String(localized: "macOS \(system) developer beta") : "macOS \(system)"
    }

    var toolchainName: String? {
        if let xcodeVersion, let xcodeBeta {
            return String(localized: "Xcode \(xcodeVersion) beta \(String(xcodeBeta))")
        }
        if let xcodeRelease { return String(localized: "Xcode \(xcodeRelease) release") }
        if let beta { return String(localized: "Xcode developer beta \(String(beta))") }
        return nil
    }

    /// Build-host OS, toolchain and binary target; never a minimum-OS claim.
    var summary: String? {
        let parts = [systemName, toolchainName, targetName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
