namespace ServerMaster.Windows.Services;

public static class AppPaths
{
    /// <summary>
    /// Test aid: when set, every per-user ServerMaster folder (settings, profiles, logs, runtimes,
    /// database, admin panels) lives under this directory, so a first run can be exercised without
    /// touching the user's real data. Unset in normal use.
    /// </summary>
    public const string DataDirectoryVariable = "SERVERMASTER_DATA_DIR";
    public static string? DataOverride { get; } = Environment.GetEnvironmentVariable(DataDirectoryVariable) is { Length: > 0 } value
        ? Path.GetFullPath(value) : null;

    public static string Support { get; } = Ensure(DataOverride is { } root ? Path.Combine(root, "Roaming") : Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ServerMaster"));

    /// <summary>
    /// Where default snapshots and suggested site folders go: the user's Documents, or a
    /// Documents folder inside the isolated test data so tests never write to the real one.
    /// </summary>
    public static string Documents => DataOverride is { } root ? Path.Combine(root, "Documents")
        : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    /// <summary>The machine-local ServerMaster folder (database, Adminer, phpMyAdmin).</summary>
    public static string LocalSupport { get; } = DataOverride is { } root ? Path.Combine(root, "Local")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ServerMaster");

    public static string ProfilesFile => Path.Combine(Support, "profiles.json");
    public static string SettingsFile => Path.Combine(Support, "settings.json");
    public static string Logs => Ensure(Path.Combine(Support, "Logs"));
    public static string Backups => Ensure(Path.Combine(Support, "Backups"));
    public static string Runtime => Ensure(Path.Combine(RuntimeSupport, "Runtime"));
    public static IEnumerable<string> RuntimeRoots
    {
        get
        {
            yield return Runtime;
            yield return Path.Combine(Support, "Runtime");
            if (DataOverride is not null) yield break; // an isolated run never borrows the user's runtimes
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            yield return Path.Combine(local, "ServerMaster", "Runtime");
            var packages = Path.Combine(local, "Packages");
            string[] folders;
            try { folders = Directory.Exists(packages) ? Directory.GetDirectories(packages, "6cf87e26-f98e-4c56-826d-a59346801099_*") : []; }
            catch (UnauthorizedAccessException) { folders = []; }
            foreach (var folder in folders)
                yield return Path.Combine(folder, "LocalState", "ServerMaster", "Runtime");
        }
    }
    private static string RuntimeSupport { get; } = ResolveRuntimeSupport();

    private static string ResolveRuntimeSupport()
    {
        // An explicit package-local path is also visible to native DLL loading and elevated installers.
        // A logical Roaming AppData path may be redirected only for the app's file APIs.
        if (DataOverride is not null) return Support;
        try { return Path.Combine(global::Windows.Storage.ApplicationData.Current.LocalFolder.Path, "ServerMaster"); }
        catch (InvalidOperationException) { return Support; }
        catch (System.Runtime.InteropServices.COMException ex) when (ex.HResult == unchecked((int)0x80073D54)) { return Support; }
    }

    public static string Ensure(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }

    public static string Subdir(string name)
    {
        return Ensure(Path.Combine(Support, name));
    }

    public static string Expand(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return "";
        }

        var expanded = Environment.ExpandEnvironmentVariables(path);
        if (expanded == "~")
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        if (expanded.StartsWith("~" + Path.DirectorySeparatorChar) || expanded.StartsWith("~" + Path.AltDirectorySeparatorChar))
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), expanded[2..]);
        }

        return expanded;
    }
}
