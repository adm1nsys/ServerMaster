//
//  AppLinks.swift
//  ServerMaster
//
//  Every address the app can send someone to, in one place. The guides live on
//  the website rather than inside the app so they can be fixed without shipping
//  a build — but that also means a moved page breaks every link at once, which
//  is exactly why they are all written down here.
//

import Foundation
import AppKit

nonisolated enum AppLinks {

    static let site = URL(string: "https://adm1nsys.github.io/ServerMaster/web/")!
    static let repository = URL(string: "https://github.com/adm1nsys/ServerMaster")!
    static let issues = URL(string: "https://github.com/adm1nsys/ServerMaster/issues")!

    /// A section of the guides. The raw value is the anchor on the page.
    enum Guide: String {
        case index        = ""
        case install      = "install"
        case staticSite   = "static"
        case php          = "php"
        case joomla       = "joomla"
        case wordpress    = "wordpress"
        case drupal       = "drupal"
        case laravel      = "laravel"
        case database     = "database"
        case phpVersion   = "phpversion"
        case https        = "https"
        case ports        = "ports"
        case htaccess     = "htaccess"
        case errors       = "errors"

        var url: URL {
            let base = "https://adm1nsys.github.io/ServerMaster/web/wiki.html"
            return URL(string: rawValue.isEmpty ? base : base + "#" + rawValue)!
        }
    }

    /// The guide worth offering for a given engine.
    static func guide(for engine: ServerEngine) -> Guide {
        switch engine {
        case .httpServer, .pythonHTTP, .nodeScript: return .staticSite
        case .phpBuiltIn:                           return .php
        case .phpFpm, .apachePHP:                   return .joomla
        case .apache:                               return .htaccess
        case .nginx, .caddy, .custom:               return .index
        }
    }

    /// The guide that explains a start-up failure, chosen from the message the
    /// engine produced. Everything unrecognised goes to the list of errors.
    static func guide(forFailure message: String) -> Guide {
        let text = message.lowercased()
        if text.contains("eacces") || text.contains("permission denied") { return .ports }
        if text.contains("port") && text.contains("taken")               { return .ports }
        if text.contains("certificate") || text.contains("ssl")          { return .https }
        if text.contains("php")                                          { return .php }
        return .errors
    }

    @MainActor
    static func open(_ guide: Guide) {
        NSWorkspace.shared.open(guide.url)
    }
}
