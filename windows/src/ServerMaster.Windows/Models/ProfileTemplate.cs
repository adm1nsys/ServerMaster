using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class ProfileTemplate
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => ChoiceTitle;

    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Summary { get; init; }
    public required string Category { get; init; }
    public string LocalizedTitle => Localization.T(Title);
    public string LocalizedSummary => Localization.T(Summary);
    /// <summary>Title plus summary, for lists that show one line per template (two templates share "PHP site").</summary>
    public string ChoiceTitle => $"{LocalizedTitle} — {LocalizedSummary}";
    public string LocalizedFolderAdvice => Localization.T(FolderAdvice);
    public string Symbol { get; init; } = "\uE71B";
    public string Engine { get; init; } = "pythonHTTP";
    public string RootHint { get; init; } = "";
    public string FolderAdvice { get; init; } = "";
    public bool NeedsDatabase { get; init; }
    public string PhpVersion { get; init; } = "";
    public string IndexFile { get; init; } = "index.html";
    public bool DirectoryListing { get; init; } = true;
    public bool SpaFallback { get; init; }
    public bool HideDotfiles { get; init; } = true;
    public bool EnableCors { get; init; }
    public bool EnableGzip { get; init; } = true;
    public bool OpenBrowserOnStart { get; init; } = true;
    public bool SecurityHeaders { get; init; }
    public bool CustomErrorPages { get; init; }
    public int CacheSeconds { get; init; } = -1;
    public string PhpMemoryLimit { get; init; } = "256M";
    public string PhpUploadMaxFilesize { get; init; } = "64M";
    public int PhpMaxExecutionTime { get; init; } = 300;
    public string[] Questions { get; init; } = [];
    /// <summary>Asks only for the folder: name and a free port are filled in, for a one-click setup.</summary>
    public bool QuickSetup { get; init; }
    public bool IsUserDefined { get; init; }
    public string NodeEntryFile { get; init; } = "server.js";
    public string CustomCommand { get; init; } = "";
    public string CustomArguments { get; init; } = "";
    public string PackageKind { get; init; } = "";
    public string PackageSource { get; init; } = "";
    public string RecipeKind { get; init; } = "";
    public string[] PluginPackages { get; init; } = [];
    public string DownloadLabel => string.IsNullOrWhiteSpace(PackageKind) ? "No package" : $"Download {Title}";
    public bool CanDownloadPackage => !string.IsNullOrWhiteSpace(PackageKind);

    public ServerProfile CreateProfile(string root, int port)
    {
        var profile = new ServerProfile
        {
            Name = Title,
            TemplateId = PackageKind switch
            {
                "printshopcrm" => "printshopcrm",
                "wordpress-w2p" => "web-to-print-store",
                _ => Id
            },
            NeedsDatabase = NeedsDatabase,
            Engine = Engine,
            PhpVersion = string.IsNullOrWhiteSpace(PhpVersion) && Engine == "phpBuiltIn" ? "8.3" : PhpVersion,
            Host = "127.0.0.1",
            Port = port,
            RootPath = root,
            IndexFile = IndexFile,
            DirectoryListing = DirectoryListing,
            SpaFallback = SpaFallback,
            HideDotfiles = HideDotfiles,
            EnableCors = EnableCors,
            EnableGzip = EnableGzip,
            OpenBrowserOnStart = OpenBrowserOnStart,
            SecurityHeaders = SecurityHeaders,
            CustomErrorPages = CustomErrorPages,
            CacheSeconds = CacheSeconds,
            PhpMemoryLimit = PhpMemoryLimit,
            PhpUploadMaxFilesize = PhpUploadMaxFilesize,
            PhpMaxExecutionTime = PhpMaxExecutionTime,
            NodeEntryFile = NodeEntryFile,
            CustomCommand = CustomCommand,
            CustomArguments = CustomArguments,
            Notes = NeedsDatabase ? "A database is required for this project." : ""
        };
        if (Id == "static-https") profile.HttpsEnabled = true;
        if (Id == "typo3" || Id == "moodle") profile.PhpMemoryLimit = "768M";
        if (Id == "prestashop") { profile.PhpUploadMaxFilesize = "256M"; profile.PhpMaxExecutionTime = 600; }
        if (Id == "moodle") profile.PhpMaxExecutionTime = 600;
        if (Id == "php-htaccess") profile.ConfigPreset = "apache";
        if (PackageKind == "printshopcrm")
        {
            profile.WorkingDirectory = root;
            profile.Environment.Add(new EnvVar { Key = "PSC_HOST", Value = "127.0.0.1" });
            profile.Environment.Add(new EnvVar { Key = "PSC_AUTH", Value = "0" });
        }
        if (PackageKind == "wordpress-w2p")
        {
            profile.DatabaseName = "servermaster_w2p_" + port;
            profile.PhpUploadMaxFilesize = "128M";
            profile.PhpMaxExecutionTime = 300;
        }
        return profile;
    }

    public static IReadOnlyList<ProfileTemplate> BuiltIn { get; } =
    [
        new ProfileTemplate { Id = "php", Title = "PHP site", Summary = "PHP entry page", Category = "Runtimes and tools", Engine = "phpBuiltIn", IndexFile = "index.php", DirectoryListing = false, FolderAdvice = "Choose the folder with index.php." },
        new ProfileTemplate { Id = "python", Title = "Python static site", Summary = "Static files with Python", Category = "Runtimes and tools", Engine = "pythonHTTP", FolderAdvice = "Choose the folder with index.html." },
        new ProfileTemplate { Id = "node-api", Title = "Node.js JSON API", Summary = "JSON endpoints without npm dependencies", Category = "Runtimes and tools", Engine = "nodeScript", NodeEntryFile = "server.cjs", FolderAdvice = "Choose the project folder." },
        new ProfileTemplate
        {
            Id = "static",
            Title = "Static site",
            Summary = "HTML, CSS and JavaScript in a folder",
            Category = "Sites and pages",
            Symbol = "\uE7C3",
            Engine = "httpServer",
            FolderAdvice = "Choose the folder that contains index.html."
        },
        new ProfileTemplate
        {
            Id = "spa",
            Title = "Single-page app",
            Summary = "React, Vue, Angular, Svelte; deep links go to index.html",
            Category = "Sites and pages",
            Symbol = "\uE8FD",
            Engine = "httpServer",
            RootHint = "dist",
            FolderAdvice = "Choose the built output: usually dist or build.",
            DirectoryListing = false,
            SpaFallback = true
        },
        new ProfileTemplate
        {
            Id = "docs",
            Title = "Documentation site",
            Summary = "Built output from Docusaurus, VitePress, MkDocs or Hugo",
            Category = "Sites and pages",
            Symbol = "\uE82D",
            Engine = "httpServer",
            RootHint = "public",
            FolderAdvice = "Choose the generated folder: public, site, dist or _site.",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "static-https",
            Title = "Static site over HTTPS",
            Summary = "Static files with a local HTTPS certificate",
            Category = "Sites and pages",
            Symbol = "\uE72E",
            Engine = "httpServer",
            FolderAdvice = "Choose the folder that contains index.html.",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "printshopcrm",
            Title = "Print Shop CRM",
            Summary = "Self-hosted print shop CRM on Node.js and SQLite",
            Category = "Printing & Publishing",
            Symbol = "\uE8A5",
            Engine = "nodeScript",
            NodeEntryFile = "server.mjs",
            FolderAdvice = "Choose an empty folder. ServerMaster downloads PrintShopCRM, installs npm dependencies, seeds demo data and runs it locally.",
            DirectoryListing = false,
            PackageKind = "printshopcrm",
            PackageSource = "https://github.com/ColeLundstrom/printshopcrm"
        },
        new ProfileTemplate
        {
            Id = "web-to-print-store",
            Title = "Web-to-Print Store",
            Summary = "Local WordPress and WooCommerce; Printcart designer requires a separate cloud account",
            Category = "Printing & Publishing",
            Symbol = "\uE719",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose an empty folder. ServerMaster downloads WordPress and prepares WooCommerce plus Printcart for a local Web-to-Print demo.",
            NeedsDatabase = true,
            PhpVersion = "8.3",
            IndexFile = "index.php",
            DirectoryListing = false,
            PackageKind = "wordpress-w2p",
            PackageSource = "https://wordpress.org/latest.zip",
            RecipeKind = "wordpress-w2p",
            PluginPackages = ["woocommerce", "printcart-integration"]
        },
        // The same store, delivered ready to present: products with print options and prices,
        // delivery, payment and sample orders are seeded in one pass, so nothing is set up by hand.
        new ProfileTemplate
        {
            Id = "web-to-print-showcase",
            Title = "Web-to-Print Showcase",
            Summary = "A print shop ready to present: products with formats, paper and runs, prices and orders already in place",
            Category = "Printing & Publishing",
            Symbol = "\uE749",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose an empty folder. ServerMaster prepares a complete print shop to show: WordPress and WooCommerce in Ukrainian, print products with options and prices, delivery, payment and sample orders. The internet is needed once, while it is prepared.",
            NeedsDatabase = true,
            PhpVersion = "8.3",
            IndexFile = "index.php",
            DirectoryListing = false,
            PackageKind = "wordpress-w2p",
            PackageSource = "https://wordpress.org/latest.zip",
            RecipeKind = "wordpress-w2p-showcase",
            PluginPackages = ["woocommerce", "printcart-integration"],
            QuickSetup = true
        },
        new ProfileTemplate
        {
            Id = "joomla5",
            Title = "Joomla 5",
            Summary = "PHP 8.2, database, installer-friendly limits",
            Category = "Content management",
            Symbol = "\uE80F",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked Joomla folder, the one with installation inside.",
            NeedsDatabase = true,
            PhpVersion = "8.2",
            IndexFile = "index.php",
            DirectoryListing = false,
            EnableCors = false,
            PackageKind = "joomla5",
            PackageSource = "https://downloads.joomla.org/latest"
        },
        new ProfileTemplate
        {
            Id = "joomla6",
            Title = "Joomla 6",
            Summary = "PHP 8.3, database, installer-friendly limits",
            Category = "Content management",
            Symbol = "\uE80F",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked Joomla folder, the one with installation inside.",
            NeedsDatabase = true,
            PhpVersion = "8.3",
            IndexFile = "index.php",
            DirectoryListing = false,
            PackageKind = "joomla6",
            PackageSource = "https://downloads.joomla.org/latest"
        },
        new ProfileTemplate
        {
            Id = "wordpress",
            Title = "WordPress",
            Summary = "PHP site with a database and pretty URL defaults",
            Category = "Content management",
            Symbol = "\uE8A5",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the folder with wp-config-sample.php in it.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false,
            PackageKind = "wordpress",
            PackageSource = "https://wordpress.org/latest.zip"
        },
        new ProfileTemplate
        {
            Id = "drupal",
            Title = "Drupal",
            Summary = "Composer build with a web document root",
            Category = "Content management",
            Symbol = "\uE70F",
            Engine = "phpBuiltIn",
            RootHint = "web",
            FolderAdvice = "Choose the web subfolder, not the project root.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "typo3",
            Title = "TYPO3",
            Summary = "PHP CMS with a public document root",
            Category = "Content management",
            Symbol = "T",
            Engine = "phpBuiltIn",
            RootHint = "public",
            FolderAdvice = "Choose the public subfolder of the project.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "prestashop",
            Title = "PrestaShop",
            Summary = "PHP shop with large uploads and a database",
            Category = "Content management",
            Symbol = "\uE719",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked shop folder.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "moodle",
            Title = "Moodle",
            Summary = "Course platform with a database",
            Category = "Content management",
            Symbol = "\uE7BE",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked Moodle folder.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "mediawiki",
            Title = "MediaWiki",
            Summary = "Wiki engine with a database",
            Category = "Content management",
            Symbol = "\uE736",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked MediaWiki folder.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "phpbb",
            Title = "phpBB",
            Summary = "Forum software with a database",
            Category = "Content management",
            Symbol = "\uE8BD",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the unpacked forum folder.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "laravel",
            Title = "Laravel",
            Summary = "Serves public; protects the project root",
            Category = "Frameworks",
            Symbol = "\uE943",
            Engine = "phpBuiltIn",
            RootHint = "public",
            FolderAdvice = "Choose the public subfolder, not the project root.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "symfony",
            Title = "Symfony",
            Summary = "PHP framework served from its public folder",
            Category = "Frameworks",
            Symbol = "S",
            Engine = "phpBuiltIn",
            RootHint = "public",
            FolderAdvice = "Choose the public subfolder of the project.",
            NeedsDatabase = true,
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "php-plain",
            Title = "PHP site",
            Summary = "Your own PHP files without a database",
            Category = "Frameworks",
            Symbol = "{}",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the folder with index.php.",
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "php-htaccess",
            Title = "PHP site with .htaccess",
            Summary = "Pretty URLs reach index.php; other Apache rules in .htaccess are not applied on Windows",
            Category = "Frameworks",
            Symbol = "\uE7B8",
            Engine = "phpBuiltIn",
            FolderAdvice = "Choose the folder with index.php and .htaccess.",
            IndexFile = "index.php",
            DirectoryListing = false
        },
        new ProfileTemplate
        {
            Id = "node-script",
            Title = "Node.js server",
            Summary = "Run server.js with PORT and HOST environment variables",
            Category = "Runtimes and tools",
            Symbol = "\uE7B8",
            Engine = "nodeScript",
            FolderAdvice = "Choose the project folder.",
            NodeEntryFile = "server.cjs"
        },
        new ProfileTemplate
        {
            Id = "custom",
            Title = "Custom command",
            Summary = "Anything that serves on a port",
            Category = "Your own",
            Symbol = "\uE756",
            Engine = "custom",
            FolderAdvice = "Choose the folder the command should run in."
        }
    ];
}
