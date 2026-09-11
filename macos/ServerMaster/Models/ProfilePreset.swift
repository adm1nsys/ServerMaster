//
//  ProfilePreset.swift
//  ServerMaster
//
//  A new profile used to arrive empty, which meant a newcomer met eleven fields
//  before seeing anything work. A preset fills in everything except the folder,
//  so the path from “new profile” to “it runs” is one choice long.
//
//  These are also the backbone of the simplified interface mode: the same three
//  answers to “what are you serving?”.
//

import Foundation

nonisolated struct ProfilePreset: Identifiable, Sendable {

    var id: String
    var title: String
    var summary: String
    var symbol: String
    /// The guide that walks through this kind of project.
    var guide: AppLinks.Guide
    /// Applied on top of a fresh profile.
    var apply: @Sendable (inout ServerProfile) -> Void

    // MARK: - The catalogue

    static var all: [ProfilePreset] {
        [
            ProfilePreset(
                id: "static",
                title: String(localized: "Static site"),
                summary: String(localized: "HTML, CSS and JavaScript in a folder"),
                symbol: "doc.richtext",
                guide: .staticSite) { profile in
                    profile.engine = .httpServer
                    profile.indexFile = "index.html"
                    profile.directoryListing = true
                    profile.hideDotfiles = true
                },

            ProfilePreset(
                id: "spa",
                title: String(localized: "Single-page app"),
                summary: String(localized: "React, Vue and the like — deep links go to index.html"),
                symbol: "square.stack.3d.up",
                guide: .staticSite) { profile in
                    profile.engine = .httpServer
                    profile.indexFile = "index.html"
                    profile.spaFallback = true
                    profile.directoryListing = false
                    profile.hideDotfiles = true
                    profile.cacheSeconds = -1
                },

            ProfilePreset(
                id: "php",
                title: String(localized: "PHP site"),
                summary: String(localized: "PHP files, no database"),
                symbol: "curlybraces",
                guide: .php) { profile in
                    profile.engine = .phpFpm
                    profile.indexFile = "index.php"
                    profile.hideDotfiles = true
                    profile.securityHeaders = true
                },

            ProfilePreset(
                id: "cms",
                title: String(localized: "CMS with a database"),
                summary: String(localized: "Joomla, WordPress, Drupal — Apache, so .htaccess works"),
                symbol: "cylinder.split.1x2",
                guide: .joomla) { profile in
                    profile.engine = .apachePHP
                    profile.indexFile = "index.php"
                    profile.hideDotfiles = true
                    profile.securityHeaders = true
                    profile.customErrorPages = true
                    // A CMS uploads media and runs long installers; the stock PHP
                    // limits are the usual reason an install dies halfway.
                    profile.phpMemoryLimit = "512M"
                    profile.phpUploadMaxFilesize = "128M"
                    profile.phpMaxExecutionTime = 300
                }
        ]
    }

    /// Builds the profile this preset describes, ready to start once a folder is set.
    func makeProfile(name: String, port: Int) -> ServerProfile {
        var profile = ServerProfile()
        profile.name = name
        profile.port = port
        apply(&profile)
        return profile
    }
}
