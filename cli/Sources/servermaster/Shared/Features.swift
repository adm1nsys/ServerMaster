//
//  Features.swift
//  ServerMaster
//
//  Deliberate, version-gated staging of finished work.
//
//  Why finished code is hidden. This project is written in long sessions and
//  released in short ones. Several features reach “builds, tested, works on my
//  machine” well before anyone else has ever touched them. Shipping all of them
//  in one release means every one of them meets its first real user at the same
//  moment, and a bug in any of them lands on top of the others.
//
//  So a feature is written when there is time to write it, and published when it
//  has had time to settle. The version it is tied to is not a guess at how long
//  that takes — it is a deadline. Without one, “not yet” quietly becomes never,
//  and the branch of code nobody reaches rots where it stands.
//
//  The part that makes this honest rather than merely tidy: `overrides`. Hiding
//  a feature from users must not mean hiding it from ourselves. Anything gated
//  can be switched on locally, and it is expected to be — a feature that has sat
//  behind a gate unexercised is not seasoned, it is only late. Use it, then let
//  the version release it.
//
//  Removing a gate is one line: delete the case. Nothing else refers to it.
//

import Foundation

nonisolated enum Feature: String, CaseIterable, Identifiable, Sendable {
    case commandLineTool
    case desktopWidgets
    case projectDownloads
    case templateSharing

    var id: String { rawValue }

    /// The release this becomes visible to everyone in.
    ///
    /// All of it is 2.0. The staggered dates were a way of holding finished work
    /// back until it had been used in anger, and that has now happened: the tool
    /// ships inside the bundle, the widget registers, downloads and templates
    /// have been through a real project. Nothing is gated at the moment — the
    /// machinery stays because the next unfinished thing will want it.
    var availableFrom: String {
        switch self {
        case .templateSharing:  return "2.0"
        case .projectDownloads: return "2.0"
        case .commandLineTool:  return "2.0"
        case .desktopWidgets:   return "2.0"
        }
    }

    var title: String {
        switch self {
        case .commandLineTool:  return String(localized: "Command line tool")
        case .desktopWidgets:   return String(localized: "Desktop widgets")
        case .projectDownloads: return String(localized: "Downloading a CMS")
        case .templateSharing:  return String(localized: "Importing and exporting templates")
        }
    }

    /// What is still worth watching before this goes out, in plain terms.
    var settlingNote: String {
        switch self {
        case .commandLineTool:
            return String(localized: "Shipped in 2.0. The binary lives in the bundle and the app links it onto the PATH.")
        case .desktopWidgets:
            return String(localized: "Shipped in 2.0. Extensions have to be sandboxed or macOS silently refuses to register them.")
        case .projectDownloads:
            return String(localized: "Shipped in 2.0. Verified against Joomla; other projects need their own release source.")
        case .templateSharing:
            return String(localized: "Shipped in 2.0. The exported format is one we will have to keep reading.")
        }
    }
}

nonisolated enum Features {

    /// Locally switched-on features, by raw value. Kept in UserDefaults rather
    /// than in the settings file so it never travels to anyone else.
    private static let overrideKey = "ServerMaster.enabledEarly"
    private static let developerKey = "ServerMaster.developerMode"

    /// One switch above all the others. With it off the app behaves exactly as
    /// it will for everyone else — which is the state worth being able to return
    /// to in one action, rather than by remembering which gates were opened.
    static var developerMode: Bool {
        get { UserDefaults.standard.bool(forKey: developerKey) }
        set { UserDefaults.standard.set(newValue, forKey: developerKey) }
    }

    static func isOn(_ feature: Feature) -> Bool {
        if developerMode, overrides.contains(feature.rawValue) { return true }
        return isReleased(feature)
    }

    /// Whether the running version has reached the release this belongs to.
    static func isReleased(_ feature: Feature) -> Bool {
        compare(AppInfo.version, feature.availableFrom) >= 0
    }

    /// True when the feature is only visible because it was switched on here.
    static func isEarly(_ feature: Feature) -> Bool {
        developerMode && overrides.contains(feature.rawValue) && !isReleased(feature)
    }

    // MARK: - Local overrides

    static var overrides: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: overrideKey) ?? [])
    }

    static func setOverride(_ feature: Feature, on: Bool) {
        var current = overrides
        if on { current.insert(feature.rawValue) } else { current.remove(feature.rawValue) }
        UserDefaults.standard.set(Array(current).sorted(), forKey: overrideKey)
    }

    /// Everything still waiting for its release, so it can be listed somewhere
    /// rather than only living in this file.
    static var pending: [Feature] {
        Feature.allCases.filter { !isReleased($0) }
    }

    // MARK: - Version comparison

    /// “1.10” is newer than “1.9”, which string comparison gets wrong. A version
    /// that cannot be read counts as older, so a feature stays hidden rather
    /// than appearing by accident.
    static func compare(_ left: String, _ right: String) -> Int {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }
        let b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let one = index < a.count ? a[index] : 0
            let two = index < b.count ? b[index] : 0
            if one != two { return one < two ? -1 : 1 }
        }
        return 0
    }
}
