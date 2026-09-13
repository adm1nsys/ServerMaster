//
//  ConfigPresets.swift
//  ServerMaster
//
//  Ready-made shapes for a generated config.
//
//  The templates already read the profile — index file, listing, SPA fallback,
//  PHP, TLS — so a preset is two things: a set of those switches thrown together
//  in a way that makes sense, and a block of directives the template appends.
//
//  Presets rather than a config each: what people actually need is “this is a
//  single-page app” or “this is a CMS with pretty URLs”, and translating that
//  into try_files and a disabled directory listing is the part worth not doing
//  by hand. Anyone who wants something else still has the generated file, and
//  the editor to change it in.
//

import Foundation

nonisolated struct ConfigPreset: Identifiable, Sendable, Hashable {

    var id: String
    var title: String
    var summary: String
    /// Engines this makes sense for. A preset offered to an engine that cannot
    /// honour it is worse than one that is missing.
    var engines: Set<ServerEngine>

    static func == (a: ConfigPreset, b: ConfigPreset) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [ConfigPreset] = [
        ConfigPreset(
            id: "standard",
            title: String(localized: "Files as they are"),
            summary: String(localized: "Serve the folder. Nothing rewritten, nothing hidden."),
            engines: Set(ServerEngine.allCases)),

        ConfigPreset(
            id: "spa",
            title: String(localized: "Single-page app"),
            summary: String(localized: "Every path that is not a file goes to the index — React, Vue, Svelte routing."),
            engines: [.nginx, .apache, .caddy, .httpServer]),

        ConfigPreset(
            id: "cms",
            title: String(localized: "CMS with pretty URLs"),
            summary: String(localized: "Unknown paths go to index.php with the query kept — Joomla, WordPress, Drupal."),
            engines: [.nginx, .apache, .apachePHP, .caddy, .phpFpm]),

        ConfigPreset(
            id: "hardened",
            title: String(localized: "Locked down"),
            summary: String(localized: "No directory listing, dotfiles and sources refused, the usual headers set."),
            engines: [.nginx, .apache, .apachePHP, .caddy]),

        ConfigPreset(
            id: "cached",
            title: String(localized: "Static with caching"),
            summary: String(localized: "Long cache on assets, none on HTML — closer to how it will be served for real."),
            engines: [.nginx, .apache, .caddy])
    ]

    static func available(for engine: ServerEngine) -> [ConfigPreset] {
        all.filter { $0.engines.contains(engine) }
    }

    static func named(_ id: String, for engine: ServerEngine) -> ConfigPreset {
        available(for: engine).first { $0.id == id } ?? all[0]
    }

    /// Switches on the profile this preset implies. Applied when it is chosen,
    /// and never afterwards — the person can still change any of them.
    func apply(to profile: inout ServerProfile) {
        switch id {
        case "spa":
            profile.spaFallback = true
            profile.directoryListing = false
        case "cms":
            profile.spaFallback = false
            profile.directoryListing = false
            if profile.indexFile.isEmpty || profile.indexFile == "index.html" {
                profile.indexFile = "index.php"
            }
        case "hardened", "cached":
            profile.directoryListing = false
        default:
            break
        }
    }

    // MARK: - What gets appended

    /// Directives for inside an nginx `server` block.
    func nginxBlock(index: String) -> String {
        switch id {
        case "cms":
            return """

                    location / {
                        try_files $uri $uri/ /\(index)?$query_string;
                    }
            """
        case "hardened":
            return """

                    location ~ /\\. { deny all; }
                    location ~* \\.(sql|log|ini|bak|swp|env)$ { deny all; }
                    add_header X-Content-Type-Options nosniff always;
                    add_header X-Frame-Options SAMEORIGIN always;
                    add_header Referrer-Policy no-referrer-when-downgrade always;
            """
        case "cached":
            return """

                    location ~* \\.(css|js|png|jpe?g|gif|svg|webp|woff2?|ico)$ {
                        expires 30d;
                        add_header Cache-Control "public, immutable";
                    }
                    location ~* \\.html?$ {
                        add_header Cache-Control "no-cache";
                    }
            """
        default:
            return ""
        }
    }

    /// Directives for inside an Apache `Directory` block or a VirtualHost.
    func apacheBlock(index: String) -> String {
        switch id {
        case "cms":
            return """

                <IfModule mod_rewrite.c>
                    RewriteEngine On
                    RewriteCond %{REQUEST_FILENAME} !-f
                    RewriteCond %{REQUEST_FILENAME} !-d
                    RewriteRule ^ \(index) [L]
                </IfModule>
            """
        case "hardened":
            return """

                <FilesMatch "^\\.|\\.(sql|log|ini|bak|swp|env)$">
                    Require all denied
                </FilesMatch>
                <IfModule mod_headers.c>
                    Header always set X-Content-Type-Options "nosniff"
                    Header always set X-Frame-Options "SAMEORIGIN"
                </IfModule>
            """
        case "cached":
            return """

                <IfModule mod_expires.c>
                    ExpiresActive On
                    ExpiresByType image/jpeg "access plus 30 days"
                    ExpiresByType image/png "access plus 30 days"
                    ExpiresByType image/svg+xml "access plus 30 days"
                    ExpiresByType text/css "access plus 30 days"
                    ExpiresByType application/javascript "access plus 30 days"
                    ExpiresByType text/html "access plus 0 seconds"
                </IfModule>
            """
        default:
            return ""
        }
    }

    /// Directives for a Caddyfile site block.
    func caddyBlock(index: String) -> String {
        switch id {
        case "cms":
            return "\n\ttry_files {path} {path}/ /\(index)?{query}\n"
        case "hardened":
            return """

            \t@forbidden {
            \t\tpath /.* /*.sql /*.log /*.ini /*.bak /*.env
            \t}
            \trespond @forbidden 403
            \theader {
            \t\tX-Content-Type-Options nosniff
            \t\tX-Frame-Options SAMEORIGIN
            \t}

            """
        case "cached":
            return """

            \t@assets path *.css *.js *.png *.jpg *.jpeg *.gif *.svg *.webp *.woff *.woff2 *.ico
            \theader @assets Cache-Control "public, max-age=2592000, immutable"
            \t@pages path *.html *.htm
            \theader @pages Cache-Control "no-cache"

            """
        default:
            return ""
        }
    }
}
