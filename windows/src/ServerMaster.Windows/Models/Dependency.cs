namespace ServerMaster.Windows.Models;

public enum DependencyKind
{
    Runtime,
    Server,
    Tooling
}

public sealed class Dependency
{
    public required string Command { get; init; }
    public required string Title { get; init; }
    public required string Summary { get; init; }
    public DependencyKind Kind { get; init; }
    public string[] VersionArguments { get; init; } = ["--version"];
    public string? WingetId { get; init; }
    public string? InstallCommand { get; init; }
    public string? UninstallCommand { get; init; }
    public bool Required { get; init; }
    public string Website { get; init; } = "";
    public string PhpVersion { get; init; } = "";
    public string StatusKey => Command;

    public static IReadOnlyList<string> PhpBranches { get; } = ["8.2", "8.3", "8.4", "8.5"];
    public static IEnumerable<Dependency> PhpPackages => PhpBranches.Select(version => new Dependency
    {
        Command = "php@" + version, Title = "PHP " + version, PhpVersion = version,
        Summary = "Separate runtime for profiles using PHP " + version,
        Kind = DependencyKind.Runtime, Website = "https://www.php.net/downloads.php?os=windows"
    });

    public static IReadOnlyList<Dependency> Catalog { get; } =
    [
        new Dependency
        {
            Command = "vcredist", Title = "Microsoft Visual C++ Runtime (" + (Environment.Is64BitOperatingSystem ? "x64" : "x86") + ")",
            Summary = "Required to run PHP on Windows", Kind = DependencyKind.Runtime,
            Website = "https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist"
        },
        new Dependency
        {
            Command = "winget",
            Title = "Windows Package Manager",
            Summary = "Installs the boring parts quietly under the hood",
            Kind = DependencyKind.Tooling,
            VersionArguments = ["--version"],
            Required = true,
            Website = "https://learn.microsoft.com/windows/package-manager/winget/"
        },
        new Dependency
        {
            Command = "node",
            Title = "Node.js LTS",
            Summary = "Runtime for http-server and Node profiles",
            Kind = DependencyKind.Runtime,
            VersionArguments = ["--version"],
            WingetId = "OpenJS.NodeJS.LTS",
            Required = true,
            Website = "https://nodejs.org"
        },
        new Dependency
        {
            Command = "npm",
            Title = "npm",
            Summary = "Installs http-server",
            Kind = DependencyKind.Runtime,
            VersionArguments = ["--version"],
            WingetId = "OpenJS.NodeJS.LTS",
            Required = true,
            Website = "https://npmjs.com"
        },
        new Dependency
        {
            Command = "http-server",
            Title = "http-server",
            Summary = "Friendly static server for SPA and HTTPS-style profiles",
            Kind = DependencyKind.Server,
            VersionArguments = ["--version"],
            InstallCommand = "npm install --global http-server",
            UninstallCommand = "npm uninstall --global http-server",
            Required = true,
            Website = "https://github.com/http-party/http-server"
        },
        new Dependency
        {
            Command = "python",
            Title = "Python",
            Summary = "Runs Python http.server",
            Kind = DependencyKind.Runtime,
            VersionArguments = ["--version"],
            WingetId = "Python.Python.3.12",
            Required = false,
            Website = "https://python.org"
        },
        new Dependency
        {
            Command = "php",
            Title = "PHP",
            Summary = "Runs PHP built-in server and CMS templates",
            Kind = DependencyKind.Runtime,
            VersionArguments = ["--version"],
            WingetId = "PHP.PHP",
            Required = false,
            Website = "https://php.net"
        },
        new Dependency
        {
            Command = "mariadbd",
            Title = "MariaDB",
            Summary = "Database for Joomla, WordPress, Laravel and similar projects",
            Kind = DependencyKind.Server,
            VersionArguments = ["--version"],
            WingetId = "MariaDB.Server",
            Required = false,
            Website = "https://mariadb.org"
        },
        new Dependency
        {
            Command = "adminer",
            Title = "Adminer",
            Summary = "Small web database panel for MariaDB",
            Kind = DependencyKind.Tooling,
            Required = false,
            Website = "https://www.adminer.org"
        },
        new Dependency
        {
            Command = "phpmyadmin",
            Title = "phpMyAdmin",
            Summary = "The familiar browser database panel used by MAMP",
            Kind = DependencyKind.Tooling,
            Required = false,
            Website = "https://www.phpmyadmin.net"
        },
        new Dependency
        {
            Command = "caddy",
            Title = "Caddy",
            Summary = "A Windows-friendly web server with simple config",
            Kind = DependencyKind.Server,
            VersionArguments = ["version"],
            WingetId = "CaddyServer.Caddy",
            Required = false,
            Website = "https://caddyserver.com"
        }
    ];
}
