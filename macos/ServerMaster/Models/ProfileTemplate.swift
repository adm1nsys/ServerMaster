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
    case publishing
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sites:      return String(localized: "Sites and pages")
        case .cms:        return String(localized: "Content management")
        case .frameworks: return String(localized: "Frameworks")
        case .runtimes:   return String(localized: "Runtimes and tools")
        case .publishing: return String(localized: "Printing & publishing")
        case .custom:     return String(localized: "Your own")
        }
    }

    var symbol: String {
        switch self {
        case .sites:      return "doc.richtext"
        case .cms:        return "square.grid.2x2"
        case .frameworks: return "cube"
        case .runtimes:   return "terminal"
        case .publishing: return "printer"
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

    // MARK: Cross-platform package contract
    // These values mirror the Windows template file. macOS retains them even
    // when a recipe is not yet runnable here, so sharing a template never
    // erases the other platform's setup instructions.
    var packageKind: String = ""
    var packageSource: String = ""
    var recipeKind: String = ""
    var pluginPackages: [String] = []
    var quickSetup: Bool = false

    /// Set by import: a template that came from a file rather than the app.
    var isUserDefined: Bool = false

    var guide: AppLinks.Guide { AppLinks.Guide(rawValue: guideAnchor) ?? .index }

    /// Quick setup already has a name, free port and recipe defaults.
    var setupQuestions: [TemplateQuestion] { quickSetup ? [.folder] : questions }

    // MARK: - Building a profile

    func makeProfile(name: String, port: Int, root: String) -> ServerProfile {
        var profile = ServerProfile()
        profile.name = name
        profile.port = port
        profile.rootPath = root
        profile.templateId = id
        profile.needsDatabase = needsDatabase
        profile.engine = settings.engine
        profile.httpsEnabled = settings.httpsEnabled
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
        profile.phpDisplayErrors = settings.phpDisplayErrors
        profile.phpVersion = phpVersion.isEmpty && settings.engine.runsPHP ? "8.3" : phpVersion
        profile.nodeEntryFile = settings.nodeEntryFile
        profile.customCommand = settings.customCommand
        profile.customArguments = settings.customArguments
        // The Windows catalogue opens a newly started template in the browser.
        // Keep the shared starter behaviour rather than making a transferred
        // project feel different on the other platform.
        profile.openBrowserOnStart = true
        if packageKind == "printshopcrm" {
            profile.workingDirectory = root
            profile.environment = [EnvVar(key: "PSC_HOST", value: "127.0.0.1"),
                                   EnvVar(key: "PSC_AUTH", value: "0")]
        }
        if packageKind == "wordpress-w2p" {
            profile.databaseName = "servermaster_w2p_\(port)"
        }
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
            needsDatabase: profile.needsDatabase,
            phpVersion: profile.phpVersion,
            questions: [.folder, .name, .port],
            settings: TemplateSettings(profile: profile),
            isUserDefined: true)
    }
}

// MARK: - Portable template decoding

nonisolated extension ProfileTemplate {
    private enum CodingKeys: String, CodingKey {
        case id, title, summary, symbol, category, guideAnchor, rootHint, folderAdvice
        case needsDatabase, phpVersion, questions, settings, isUserDefined
        case packageKind, packageSource, recipeKind, pluginPackages, quickSetup
    }

    /// Template files are exchanged with Windows and outlive individual app
    /// builds. Every newer field therefore has a default on read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        symbol = c.value(.symbol, default: "square.grid.2x2")
        let savedCategory = c.value(.category, default: TemplateCategory.custom.rawValue)
        category = TemplateCategory(rawValue: savedCategory) ?? .custom
        guideAnchor = c.value(.guideAnchor, default: AppLinks.Guide.index.rawValue)
        rootHint = c.value(.rootHint, default: nil)
        folderAdvice = c.value(.folderAdvice, default: nil)
        needsDatabase = c.value(.needsDatabase, default: false)
        phpVersion = c.value(.phpVersion, default: "")
        questions = c.value(.questions, default: [])
        settings = c.contains(.settings) ? try c.decode(TemplateSettings.self, forKey: .settings) : TemplateSettings()
        isUserDefined = c.value(.isUserDefined, default: false)
        packageKind = c.value(.packageKind, default: "")
        packageSource = c.value(.packageSource, default: "")
        recipeKind = c.value(.recipeKind, default: "")
        pluginPackages = c.value(.pluginPackages, default: [])
        quickSetup = c.value(.quickSetup, default: false)
    }
}

/// The part of a profile a template fixes. Deliberately a separate type: a
/// template must not carry a profile's identity, its paths or its certificates.
nonisolated struct TemplateSettings: Codable, Sendable, Equatable {
    var engine: ServerEngine = .httpServer
    var httpsEnabled: Bool = false
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
    var phpDisplayErrors: Bool = true
    var nodeEntryFile: String = "server.js"
    var customCommand: String = ""
    var customArguments: String = ""
    var iconName: String?

    init() {}

    init(profile: ServerProfile) {
        engine = profile.engine
        httpsEnabled = profile.httpsEnabled
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
        phpDisplayErrors = profile.phpDisplayErrors
        nodeEntryFile = profile.nodeEntryFile
        customCommand = profile.customCommand
        customArguments = profile.customArguments
        iconName = profile.iconName.isEmpty ? nil : profile.iconName
    }

    // Older exported templates must keep loading when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TemplateSettings()
        engine = c.contains(.engine) ? try c.decode(ServerEngine.self, forKey: .engine) : d.engine
        httpsEnabled = c.value(.httpsEnabled, default: d.httpsEnabled)
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
        phpDisplayErrors = c.value(.phpDisplayErrors, default: d.phpDisplayErrors)
        nodeEntryFile = c.value(.nodeEntryFile, default: d.nodeEntryFile)
        customCommand = c.value(.customCommand, default: d.customCommand)
        customArguments = c.value(.customArguments, default: d.customArguments)
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
            settings: {
                var s = staticSettings(listing: false)
                s.httpsEnabled = true
                return s
            }()),

        // ── Printing & publishing ───────────────────────────────────────
        // These use the same stable identifiers and recipe metadata as the
        // Windows catalogue. The metadata stays with an exported template even
        // when the receiving platform needs its own runner for a recipe.
        ProfileTemplate(
            id: "printshopcrm", title: "Print Shop CRM",
            summary: String(localized: "Self-hosted print shop CRM on Node.js and SQLite"),
            symbol: "printer", category: .publishing,
            guideAnchor: "index", rootHint: nil,
            folderAdvice: String(localized: "Choose the Print Shop CRM project folder."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .entryFile],
            settings: {
                var s = TemplateSettings()
                s.engine = .nodeScript
                s.nodeEntryFile = "server.mjs"
                s.directoryListing = false
                return s
            }(),
            packageKind: "printshopcrm",
            packageSource: "https://github.com/ColeLundstrom/printshopcrm"),

        ProfileTemplate(
            id: "web-to-print-store", title: "Web-to-Print Store",
            summary: String(localized: "WordPress, WooCommerce and a local database"),
            symbol: "printer.fill", category: .publishing,
            guideAnchor: "wordpress", rootHint: nil,
            folderAdvice: String(localized: "Choose the WordPress project folder."),
            needsDatabase: true, phpVersion: "8.3",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings(),
            packageKind: "wordpress-w2p",
            packageSource: "https://wordpress.org/latest.zip",
            recipeKind: "wordpress-w2p",
            pluginPackages: ["woocommerce", "printcart-integration"]),

        ProfileTemplate(
            id: "web-to-print-showcase", title: "Web-to-Print Showcase",
            summary: String(localized: "A WordPress print-shop showcase with local database settings"),
            symbol: "printer.fill", category: .publishing,
            guideAnchor: "wordpress", rootHint: nil,
            folderAdvice: String(localized: "Choose the prepared showcase project folder."),
            needsDatabase: true, phpVersion: "8.3",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings(),
            packageKind: "wordpress-w2p",
            packageSource: "https://wordpress.org/latest.zip",
            recipeKind: "wordpress-w2p-showcase",
            pluginPackages: ["woocommerce", "printcart-integration"],
            quickSetup: true),

        // ── Content management ───────────────────────────────────────────
        ProfileTemplate(
            id: "joomla5", title: "Joomla 5",
            summary: String(localized: "Apache with .htaccess, a database and PHP 8.2"),
            symbol: "square.grid.2x2", category: .cms,
            guideAnchor: "joomla", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked Joomla folder — the one with installation inside."),
            needsDatabase: true, phpVersion: "8.2",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings(),
            packageKind: "joomla5", packageSource: "https://downloads.joomla.org/latest"),

        ProfileTemplate(
            id: "joomla6", title: "Joomla 6",
            summary: String(localized: "Same as Joomla 5, but on PHP 8.3"),
            symbol: "square.grid.2x2", category: .cms,
            guideAnchor: "joomla", rootHint: nil,
            folderAdvice: String(localized: "Choose the unpacked Joomla folder — the one with installation inside."),
            needsDatabase: true, phpVersion: "8.3",
            questions: [.folder, .name, .port, .database, .phpVersion],
            settings: cmsSettings(),
            packageKind: "joomla6", packageSource: "https://downloads.joomla.org/latest"),

        ProfileTemplate(
            id: "wordpress", title: "WordPress",
            summary: String(localized: "A database, generous upload limits, pretty permalinks"),
            symbol: "w.square", category: .cms,
            guideAnchor: "wordpress", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder with wp-config-sample.php in it."),
            needsDatabase: true, phpVersion: "",
            questions: [.folder, .name, .port, .database],
            settings: cmsSettings(),
            packageKind: "wordpress", packageSource: "https://wordpress.org/latest.zip"),

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
            id: "php", title: String(localized: "PHP site"),
            summary: String(localized: "PHP entry page"),
            symbol: "curlybraces", category: .runtimes,
            guideAnchor: "php", rootHint: nil,
            folderAdvice: String(localized: "Choose the folder with index.php."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .phpVersion],
            settings: phpSettings(engine: .phpBuiltIn)),

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
                s.nodeEntryFile = "server.cjs"
                return s
            }()),

        ProfileTemplate(
            id: "node-api", title: String(localized: "Node.js JSON API"),
            summary: String(localized: "JSON endpoints without npm dependencies"),
            symbol: "arrow.left.arrow.right.circle", category: .runtimes,
            guideAnchor: "static", rootHint: nil,
            folderAdvice: String(localized: "Choose the project folder."),
            needsDatabase: false, phpVersion: "",
            questions: [.folder, .name, .port, .entryFile],
            settings: {
                var s = TemplateSettings()
                s.engine = .nodeScript
                s.nodeEntryFile = "server.cjs"
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
