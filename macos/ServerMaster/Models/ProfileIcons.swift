//
//  ProfileIcons.swift
//  ServerMaster
//

import Foundation

/// The icons available to choose from for a profile.
nonisolated enum ProfileIcons {

    nonisolated struct Group: Identifiable, Sendable {
        var id: String { title }
        var title: String
        var symbols: [String]
    }

    static let groups: [Group] = [
        Group(title: String(localized: "Servers"),
              symbols: ["server.rack", "externaldrive.connected.to.line.below", "network",
                        "cylinder.split.1x2", "shippingbox", "cube", "square.stack.3d.up"]),
        Group(title: String(localized: "Development"),
              symbols: ["chevron.left.forwardslash.chevron.right", "curlybraces", "terminal",
                        "hammer", "wrench.and.screwdriver", "ladybug", "function"]),
        Group(title: String(localized: "Sites"),
              symbols: ["globe", "safari", "doc.richtext", "photo.stack", "cart",
                        "newspaper", "book"]),
        Group(title: String(localized: "Status"),
              symbols: ["flame", "bolt", "star", "heart", "flag", "pin", "bookmark"]),
        Group(title: String(localized: "Other"),
              symbols: ["folder", "tray.full", "gearshape", "lock", "leaf", "moon", "sun.max"])
    ]

    static let all: [String] = groups.flatMap(\.symbols)
}
