//
//  ProfileTemplate.swift
//  ServerMaster
//
//  What you are running, rather than how to run it. Someone told to get Joomla 5
//  working should be able to say “Joomla 5” and answer two questions, instead of
//  learning what PHP-FPM is first.
//
//  A template carries the settings that product needs — engine, PHP version,
//  limits, whether a database comes with it, where its document root usually
//  sits — and the list of questions worth asking. Everything else is a default
//  the person can change later in the editor.
//
//  Templates are also the simple interface: the wizard is the whole beginner
//  path, and the full editor stays where it always was for anyone who wants it.
//

import Foundation

nonisolated enum TemplateCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sites
    case cms
    case frameworks
    case runtimes
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sites:      return String(localized: "Sites and pages")
        case .cms:        return String(localized: "Content management")
        case .frameworks: return String(localized: "Frameworks")
        case .runtimes:   return String(localized: "Runtimes and tools")
        case .custom:     return String(localized: "Your own")
        }
    }

    var symbol: String {
        switch self {
        case .sites:      return "doc.richtext"
        case .cms:        return "square.grid.2x2"
        case .frameworks: return "cube"
        case .runtimes:   return "terminal"
        case .custom:     return "person.crop.square"
        }
    }
}

/// A question the wizard asks. Which ones appear depends on the template.
nonisolated enum TemplateQuestion: String, Codable, CaseIterable, Sendable {
    case folder          // always asked
    case name
    case port
    case phpVersion
    case database
    case https
    case command         // only for the custom-command engine
    case entryFile       // only for a Node.js script
}

nonisolated struct ProfileTemplate: Identifiable, Codable, Sendable, Equatable {

    var id: String
    var title: String
    var summary: String
    var symbol: String
    var category: TemplateCategory

    /// The guide that walks through this product.
    var guideAnchor: String
    /// The folder inside the project that is actually served, when it differs
    /// from the project root. Laravel serves `public`, composer Drupal `web`.
    var rootHint: String?
    /// Shown in the wizard before the folder is chosen.
    var folderAdvice: String?
    /// The product needs a database; the wizard offers to create one.
    var needsDatabase: Bool
    /// PHP this product wants. Empty means whatever is in PATH.
    var phpVersion: String
    var questions: [TemplateQuestion]

    /// The settings this template writes into a new profile.
    var settings: TemplateSettings

    /// Set by import: a template that came from a file rather than the app.
    var isUserDefined: Bool = false

    var guide: AppLinks.Guide { AppLinks.Guide(rawValue: guideAnchor) ?? .index }

    // MARK: - Building a profile

    func makeProfile(name: String, port: Int, root: String) -> ServerProfile {
        var profile = ServerProfile()
        profile.name = name
        profile.port = port
        profile.rootPath = root
        profile.engine = settings.engine
        profile.indexFile = settings.indexFile
        profile.directoryListing = settings.directoryListing
        profile.spaFallback = settings.spaFallback
        profile.hideDotfiles = settings.hideDotfiles
        profile.securityHeaders = settings.securityHeaders
        profile.customErrorPages = settings.customErrorPages
        profile.cacheSeconds = settings.cacheSeconds
        profile.phpMemoryLimit = settings.phpMemoryLimit
        profile.phpUploadMaxFilesize = settings.phpUploadMaxFilesize
        profile.phpMaxExecutionTime = settings.phpMaxExecutionTime
        profile.phpVersion = phpVersion
        if let icon = settings.iconName { profile.iconName = icon }
        return profile
    }

    /// A template describing a profile the user already built.
    static func from(profile: ServerProfile, title: String, summary: String) -> ProfileTemplate {
        ProfileTemplate(
            id: "user." + UUID().uuidString.prefix(8).lowercased(),
            title: title,
            summary: summary,
            symbol: profile.symbol,
            category: .custom,
            guideAnchor: AppLinks.guide(for: profile.engine).rawValue,
            rootHint: nil,
            folderAdvice: nil,
            needsDatabase: profile.engine.typicallyNeedsDatabase,
            phpVersion: profile.phpVersion,
            questions: [.folder, .name, .port],
            settings: TemplateSettings(profile: profile),
            isUserDefined: true)
    }
}

/// The part of a profile a template fixes. Deliberately a separate type: a
/// template must not carry a profile's identity, its paths or its certificates.
nonisolated struct TemplateSettings: Codable, Sendable, Equatable {
    var engine: ServerEngine = .httpServer
    var indexFile: String = "index.html"
    var directoryListing: Bool = true
    var spaFallback: Bool = false
    var hideDotfiles: Bool = true
    var securityHeaders: Bool = false
    var customErrorPages: Bool = false
    var cacheSeconds: Int = -1
    var phpMemoryLimit: String = "256M"
    var phpUploadMaxFilesize: String = "64M"
    var phpMaxExecutionTime: Int = 300
    var iconName: String?

    init() {}

    init(profile: ServerProfile) {
        engine = profile.engine
        indexFile = profile.indexFile
        directoryListing = profile.directoryListing
        spaFallback = profile.spaFallback
        hideDotfiles = profile.hideDotfiles
        securityHeaders = profile.securityHeaders
        customErrorPages = profile.customErrorPages
        cacheSeconds = profile.cacheSeconds
        phpMemoryLimit = profile.phpMemoryLimit
        phpUploadMaxFilesize = profile.phpUploadMaxFilesize
        phpMaxExecutionTime = profile.phpMaxExecutionTime
        iconName = profile.iconName.isEmpty ? nil : profile.iconName
    }

    // Older exported templates must keep loading when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TemplateSettings()
        engine = c.value(.engine, default: d.engine)
        indexFile = c.value(.indexFile, default: d.indexFile)
        directoryListing = c.value(.directoryListing, default: d.directoryListing)
        spaFallback = c.value(.spaFallback, default: d.spaFallback)
        hideDotfiles = c.value(.hideDotfiles, default: d.hideDotfiles)
        securityHeaders = c.value(.securityHeaders, default: d.securityHeaders)
        customErrorPages = c.value(.customErrorPages, default: d.customErrorPages)
        cacheSeconds = c.value(.cacheSeconds, default: d.cacheSeconds)
        phpMemoryLimit = c.value(.phpMemoryLimit, default: d.phpMemoryLimit)
        phpUploadMaxFilesize = c.value(.phpUploadMaxFilesize, default: d.phpUploadMaxFilesize)
        phpMaxExecutionTime = c.value(.phpMaxExecutionTime, default: d.phpMaxExecutionTime)
        iconName = c.value(.iconName, default: d.iconName)
    }
}

// MARK: - The built-in catalogue

nonisolated extension ProfileTemplate {

    /// A PHP site behind Apache, which is what most CMS projects expect because
    /// they ship their own .htaccess.
    private static func cmsSettings(errorPages: Bool = true) -> TemplateSettings {
        var s = TemplateSettings()
        s.engine = .apachePHP
        s.indexFile = "index.php"
        s.directoryListing = false
        s.hideDotfiles = true
        s.securityHeaders = true
        s.customErrorPages = errorPages
        // Stock PHP limits are the usual reason a CMS install dies halfway.
        s.phpMemoryLimit = "512M"
        s.phpUploadMaxFilesize = "128M"
        s.phpMaxExecutionTime = 300
        return s
    }

    private static func phpSettings(engine: ServerEngine = .phpFpm) -> TemplateSettings {
        var s = TemplateSettings()
        s.engine = engine
        s.indexFile = "index.php"
        s.directoryListing = false
        s.hideDotfiles = true
        s.securityHeaders = true
        return s
    }

    private static func staticSettings(spa: Bool = false, listing: Bool = true) -> TemplateSettings {
        var s = TemplateSettings()
        s.engine = .httpServer
        s.indexFile = "index.html"
        s.spaFallback = spa
        s.directoryListing = listing
        s.hideDotfiles = true
        return s
    }

    static let builtIn: [ProfileTemplate] = [

        // ── Sites and pages ──────────────────────────────────────────────
        ProfileTemplate(
            id: "static", title: String(localized: "Static site"),
            summary: String(localized: "HTML, CSS and JavaScript in a folder"),
            symbol: "doc.richtext", category: .sites,
            guideAnchor: "static", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder that contains index.html."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port],
            settings: staticSettings()),

        ProfileTemplate(
            id: "spa", title: String(localized: "Single-page app"),
            summary: String(localized: "React, Vue, Angular, Svelte — deep links go to index.html"),
            symbol: "square.stack.3d.up", category: .sites,
            guideAnchor: "static", rootHint: "dist",
            folderAdvice: String(localized: "Choose the built output — usually dist or build, not the source."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port],
            settings: staticSettings(spa: true, listing: false)),

        ProfileTemplate(
            id: "docs", title: String(localized: "Documentation site"),
            summary: String(localized: "Built output of Docusaurus, VitePress, MkDocs, Hugo, Jekyll"),
            symbol: "book.closed", category: .sites,
            guideAnchor: "static", rootHint: "public",
            folderAdvice: String(localized: "Choose the generated folder — public, site, dist or _site."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port],
            settings: staticSettings(listing: false)),

        ProfileTemplate(
            id: "static-https", title: String(localized: "Static site over HTTPS"),
            summary: String(localized: "For anything that refuses to work without a secure origin"),
            symbol: "lock.doc", category: .sites,
            guideAnchor: "https", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder that contains index.html."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .https],
            settings: staticSettings(listing: false)),

        // ── Content management ───────────────────────────────────────────
        ProfileTemplate(
            id: "joomla5", title: "Joomla 5",
            summary: String(localized: "Apache with .htaccess, a database and PHP 8.2"),
            symbol: "square.grid.2x2", category: .cms,
            guideAnchor: "joomla", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked Joomla folder — the one with installation inside."),
            needsDatabase: true, phpVersion: "8.2",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings()),

        ProfileTemplate(
            id: "joomla6", title: "Joomla 6",
            summary: String(localized: "Same as Joomla 5, but on PHP 8.3"),
            symbol: "square.grid.2x2", category: .cms,
            guideAnchor: "joomla", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked Joomla folder — the one with installation inside."),
            needsDatabase: true, phpVersion: "8.3",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings()),

        ProfileTemplate(
            id: "wordpress", title: "WordPress",
            summary: String(localized: "A database, generous upload limits, pretty permalinks"),
            symbol: "w.square", category: .cms,
            guideAnchor: "wordpress", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder with wp-config-sample.php in it."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: cmsSettings()),

        ProfileTemplate(
            id: "drupal", title: "Drupal",
            summary: String(localized: "Composer builds serve the web subfolder"),
            symbol: "drop", category: .cms,
            guideAnchor: "drupal", rootHint: "web",
            folderAdvice: String(localized: "In a Composer build choose the web subfolder, not the project root."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: cmsSettings()),

        ProfileTemplate(
            id: "typo3", title: "TYPO3",
            summary: String(localized: "Serves public, wants a lot of memory"),
            symbol: "t.square", category: .cms,
            guideAnchor: "php", rootHint: "public",
            folderAdvice: String(localized: "Choose the public subfolder of the project."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: {
                var s = cmsSettings()
                s.phpMemoryLimit = "768M"
                return s
            }()),

        ProfileTemplate(
            id: "prestashop", title: "PrestaShop",
            summary: String(localized: "A shop: big uploads, long installer"),
            symbol: "cart", category: .cms,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked shop folder."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: {
                var s = cmsSettings()
                s.phpUploadMaxFilesize = "256M"
                s.phpMaxExecutionTime = 600
                return s
            }()),

        ProfileTemplate(
            id: "moodle", title: "Moodle",
            summary: String(localized: "Course platform — long installs, large files"),
            symbol: "graduationcap", category: .cms,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked Moodle folder."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: {
                var s = cmsSettings()
                s.phpMemoryLimit = "768M"
                s.phpMaxExecutionTime = 600
                return s
            }()),

        ProfileTemplate(
            id: "mediawiki", title: "MediaWiki",
            summary: String(localized: "Wiki engine with a database"),
            symbol: "text.book.closed", category: .cms,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked MediaWiki folder."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: cmsSettings()),

        ProfileTemplate(
            id: "phpbb", title: "phpBB",
            summary: String(localized: "Forum software with a database"),
            symbol: "bubble.left.and.bubble.right", category: .cms,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked forum folder."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: cmsSettings()),

        // ── Frameworks ───────────────────────────────────────────────────
        ProfileTemplate(
            id: "laravel", title: "Laravel",
            summary: String(localized: "Serves public; the database goes in .env"),
            symbol: "l.square", category: .frameworks,
            guideAnchor: "laravel", rootHint: "public",
            folderAdvice: String(localized: "Choose the public subfolder — pointing at the project root exposes .env."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: phpSettings()),

        ProfileTemplate(
            id: "symfony", title: "Symfony",
            summary: String(localized: "Serves public, same shape as Laravel"),
            symbol: "s.square", category: .frameworks,
            guideAnchor: "php", rootHint: "public",
            folderAdvice: String(localized: "Choose the public subfolder of the project."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: phpSettings()),

        ProfileTemplate(
            id: "php-plain", title: String(localized: "PHP site"),
            summary: String(localized: "Your own PHP files, no database"),
            symbol: "curlybraces", category: .frameworks,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder with index.php."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .phpVersion],
            settings: phpSettings()),

        ProfileTemplate(
            id: "php-htaccess", title: String(localized: "PHP site with .htaccess"),
            summary: String(localized: "When the project brings its own Apache rules"),
            symbol: "building.columns", category: .frameworks,
            guideAnchor: "htaccess", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder with index.php and .htaccess."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .phpVersion],
            settings: phpSettings(engine: .apachePHP)),

        // ── Runtimes and tools ───────────────────────────────────────────
        ProfileTemplate(
            id: "node-script", title: String(localized: "Node.js server"),
            summary: String(localized: "Your own server.js or an npm entry point"),
            symbol: "shippingbox", category: .runtimes,
            guideAnchor: "static", rootHint: nil,
            folderAdvice: String(localized: "Choose the project folder; the entry file is asked for next."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .entryFile],
            settings: {
                var s = TemplateSettings()
                s.engine = .nodeScript
                return s
            }()),

        ProfileTemplate(
            id: "python", title: String(localized: "Python http.server"),
            summary: String(localized: "The quickest way to put a folder on a port"),
            symbol: "chevron.left.forwardslash.chevron.right", category: .runtimes,
            guideAnchor: "static", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder to serve."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port],
            settings: {
                var s = TemplateSettings()
                s.engine = .pythonHTTP
                return s
            }()),

        ProfileTemplate(
            id: "nginx", title: String(localized: "Nginx, full control"),
            summary: String(localized: "A generated config you can edit and keep"),
            symbol: "server.rack", category: .runtimes,
            guideAnchor: "index", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder to serve."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port],
            settings: {
                var s = TemplateSettings()
                s.engine = .nginx
                s.securityHeaders = true
                s.customErrorPages = true
                return s
            }()),

        ProfileTemplate(
            id: "caddy", title: String(localized: "Caddy"),
            summary: String(localized: "Automatic HTTPS, very little configuration"),
            symbol: "lock.shield", category: .runtimes,
            guideAnchor: "https", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder to serve."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .https],
            settings: {
                var s = TemplateSettings()
                s.engine = .caddy
                return s
            }()),

        ProfileTemplate(
            id: "custom", title: String(localized: "Custom command"),
            summary: String(localized: "Anything that serves on a port"),
            symbol: "terminal", category: .custom,
            guideAnchor: "index", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder the command should run in."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .command],
            settings: {
                var s = TemplateSettings()
                s.engine = .custom
                return s
            }())
    ]
}
