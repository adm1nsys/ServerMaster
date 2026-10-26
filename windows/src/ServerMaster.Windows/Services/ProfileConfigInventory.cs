using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class ProfileConfigInventory
{
    private static readonly (string Name, string Note)[] SiteCandidates =
    [
        ("configuration.php", "Joomla site configuration"),
        ("wp-config.php", "WordPress site configuration"),
        (".env", "Project environment file"),
        (".htaccess", "Apache rules; the Windows built-in servers do not read this file"),
        ("htaccess.txt", "Joomla Apache rules template"),
        ("web.config", "IIS configuration; the built-in servers do not read this file"),
        ("composer.json", "PHP package manifest"),
        ("package.json", "Node.js package manifest"),
        ("index.php", "PHP entry page"),
        ("index.html", "Site entry page")
    ];

    public static IReadOnlyList<ProfileConfigFile> Collect(ServerProfile profile)
    {
        var result = new List<ProfileConfigFile>();
        if (profile.Engine == "phpBuiltIn")
        {
            var executable = PhpRuntime.Find(profile.PhpVersion);
            var ini = executable is null ? null : System.IO.Path.Combine(System.IO.Path.GetDirectoryName(executable)!, "php.ini");
            if (ini is not null && File.Exists(ini))
            {
                var managed = AppPaths.RuntimeRoots.Any(root => SiteFiles.IsWithin(root, ini));
                result.Add(Entry("php.ini", ini, "PHP settings",
                    managed ? "Shared by profiles using this PHP installation" : "System PHP settings; open in your editor", managed));
            }
        }

        if (profile.UsesRootDirectory && Directory.Exists(profile.ExpandedRootPath))
        {
            var root = System.IO.Path.GetFullPath(profile.ExpandedRootPath);
            foreach (var (name, note) in SiteCandidates)
            {
                var path = System.IO.Path.Combine(root, name);
                if (File.Exists(path)) result.Add(Entry(name, path, "Site files", note, true));
            }
        }

        if (profile.NeedsDatabase && File.Exists(DatabaseService.ErrorLogPath))
            result.Add(Entry("MariaDB error.log", DatabaseService.ErrorLogPath, "Logs",
                "Database errors; read-only in ServerMaster", false));
        return result;
    }

    private static ProfileConfigFile Entry(string title, string path, string kind, string note, bool editable)
    {
        var file = new FileInfo(path);
        return new ProfileConfigFile
        {
            Title = title, Path = path, Kind = kind, Note = note,
            CanEdit = editable && file.Length <= SiteFiles.MaxEditorBytes && !file.IsReadOnly,
            SizeLabel = file.Length < 1024 ? $"{file.Length} B" : $"{file.Length / 1024d:0.#} KB"
        };
    }
}
