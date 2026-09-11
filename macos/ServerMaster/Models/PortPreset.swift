//
//  PortPreset.swift
//  ServerMaster
//
//  Ready-made ports, so they need no thought when a page just has to be debugged.
//

import Foundation

nonisolated struct PortPreset: Identifiable, Hashable, Sendable {
    var id: Int { port }
    var port: Int
    var title: String
    var note: String
    var isSecure: Bool = false

    var label: String { "\(String(port)) — \(title)" }
}

nonisolated enum PortPresets {

    static let http: [PortPreset] = [
        PortPreset(port: 8080, title: String(localized: "standard local"), note: String(localized: "The most familiar port for a local server")),
        PortPreset(port: 3000, title: "React, Next.js", note: String(localized: "The create-react-app and Next.js default")),
        PortPreset(port: 5173, title: "Vite", note: String(localized: "The Vite and SvelteKit default")),
        PortPreset(port: 4200, title: "Angular", note: String(localized: "The Angular CLI default")),
        PortPreset(port: 8000, title: "Python, Django", note: String(localized: "The python -m http.server and Django default")),
        PortPreset(port: 5000, title: "Flask, .NET", note: String(localized: "May conflict with AirPlay on macOS")),
        PortPreset(port: 1313, title: "Hugo", note: String(localized: "The Hugo static generator default")),
        PortPreset(port: 4000, title: "Jekyll, Phoenix", note: String(localized: "The Jekyll and Phoenix default")),
        PortPreset(port: 8888, title: "Jupyter", note: String(localized: "The Jupyter Notebook default")),
        PortPreset(port: 9000, title: String(localized: "spare"), note: String(localized: "A free alternative if 8080 is taken"))
    ]

    static let https: [PortPreset] = [
        PortPreset(port: 8443, title: String(localized: "standard local HTTPS"), note: String(localized: "Local replacement for 443, no root needed"), isSecure: true),
        PortPreset(port: 4443, title: String(localized: "alternative HTTPS"), note: String(localized: "If 8443 is already taken"), isSecure: true),
        PortPreset(port: 9443, title: String(localized: "spare HTTPS"), note: String(localized: "One more free alternative"), isSecure: true),
        PortPreset(port: 3443, title: String(localized: "HTTPS for frontend"), note: String(localized: "Convenient next to 3000"), isSecure: true)
    ]

    static func list(secure: Bool) -> [PortPreset] { secure ? https : http }

    static func preset(for port: Int) -> PortPreset? {
        (http + https).first { $0.port == port }
    }

    /// A port from the presets that is free right now.
    static func firstFree(secure: Bool, host: String) -> Int? {
        list(secure: secure).first { PortScanner.isPortFree($0.port, host: host) }?.port
    }

    /// The privileged ports a beginner tries out of habit,
    /// and the local replacement for each.
    static func localReplacement(for port: Int) -> Int? {
        switch port {
        case 443: return 8443
        case 80:  return 8080
        case 8:   return 8080
        default:  return port < 1024 ? 8080 : nil
        }
    }
}
