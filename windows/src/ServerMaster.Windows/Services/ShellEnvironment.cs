using Microsoft.Win32;

namespace ServerMaster.Windows.Services;

public sealed class ShellEnvironment
{
    public static ShellEnvironment Shared { get; } = new();

    private readonly string[] _fallbackEntries =
    [
        @"C:\Program Files\nodejs",
        @"C:\Program Files\Git\cmd",
        @"C:\Program Files\Git\bin",
        @"C:\Program Files\PHP",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Links"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @"AppData\Roaming\npm"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".bun\bin"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".cargo\bin")
    ];

    public IReadOnlyList<string> ExtraEntries { get; private set; } = [];

    public void SetExtraEntries(IEnumerable<string> entries)
    {
        ExtraEntries = entries.Select(AppPaths.Expand).Where(entry => !string.IsNullOrWhiteSpace(entry)).ToList();
    }

    public string PathValue
    {
        get
        {
            var entries = new List<string>();
            if (NodeRuntime.ActiveDirectory is { } nodeDirectory) entries.Add(nodeDirectory);
            entries.AddRange(ExtraEntries);
            entries.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator));
            using var userEnvironment = Registry.CurrentUser.OpenSubKey("Environment");
            using var machineEnvironment = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment");
            entries.AddRange((userEnvironment?.GetValue("Path") as string ?? "")
                .Split(Path.PathSeparator).Select(Environment.ExpandEnvironmentVariables));
            entries.AddRange((machineEnvironment?.GetValue("Path") as string ?? "")
                .Split(Path.PathSeparator).Select(Environment.ExpandEnvironmentVariables));
            entries.AddRange(_fallbackEntries);
            entries.AddRange(InstalledDirectories());
            return string.Join(Path.PathSeparator, entries.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase));
        }
    }

    private static IEnumerable<string> InstalledDirectories()
    {
        var paths = new List<string>();
        foreach (var programFiles in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) }.Distinct())
        {
            AddMatches(programFiles, "MariaDB*", "bin");
            AddMatches(programFiles, "Python312", "");
            AddMatches(programFiles, "Python3*", "");
        }
        var python = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Python");
        AddMatches(python, "Python312", "");
        AddMatches(python, "Python3*", "");
        return paths;

        void AddMatches(string parent, string pattern, string subfolder)
        {
            if (!Directory.Exists(parent)) return;
            try
            {
                paths.AddRange(Directory.EnumerateDirectories(parent, pattern).OrderDescending().Select(directory => Path.Combine(directory, subfolder)));
            }
            catch (UnauthorizedAccessException) { }
            catch (IOException) { }
        }
    }

    public Dictionary<string, string> EnvironmentFor(Dictionary<string, string>? extra = null)
    {
        var result = Environment.GetEnvironmentVariables()
            .Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(entry => (string)entry.Key, entry => (string?)entry.Value ?? "", StringComparer.OrdinalIgnoreCase);

        result["PATH"] = PathValue;
        result["TERM"] = "dumb";
        result["PYTHONUNBUFFERED"] = "1";
        result["PYTHONIOENCODING"] = "utf-8";
        result["NODE_NO_WARNINGS"] = result.TryGetValue("NODE_NO_WARNINGS", out var existing) ? existing : "1";

        if (extra is not null)
        {
            foreach (var (key, value) in extra)
            {
                result[key] = value;
            }
        }

        return result;
    }

    public string? Which(string tool)
    {
        if (Path.IsPathFullyQualified(tool))
        {
            return File.Exists(tool) && !IsPythonStoreAlias(tool) ? tool : null;
        }

        var extensions = (Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        // npm ships a Unix script next to npm.cmd; only select Windows executable extensions.
        var names = Path.HasExtension(tool) ? [tool] : extensions.Select(ext => tool + ext);

        foreach (var directory in PathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var name in names)
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate) && !IsPythonStoreAlias(candidate))
                {
                    return candidate;
                }
            }
        }

        foreach (var candidate in KnownExecutablePaths(tool))
        {
            if (File.Exists(candidate) && !IsPythonStoreAlias(candidate)) return candidate;
        }

        return null;
    }

    private static IEnumerable<string> KnownExecutablePaths(string tool)
    {
        string[] names = Path.HasExtension(tool) ? [tool] : [tool + ".exe", tool + ".cmd", tool + ".bat"];
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        }.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase);
        foreach (var root in roots)
        {
            if (!Directory.Exists(root)) continue;
            string[] directories;
            try { directories = Directory.EnumerateDirectories(root, tool.Equals("mariadbd", StringComparison.OrdinalIgnoreCase) ? "MariaDB*" : tool.Equals("php", StringComparison.OrdinalIgnoreCase) ? "PHP*" : tool.Equals("node", StringComparison.OrdinalIgnoreCase) ? "nodejs" : "*", SearchOption.TopDirectoryOnly).ToArray(); }
            catch { continue; }
            foreach (var directory in directories)
                foreach (var name in names)
                {
                    yield return Path.Combine(directory, "bin", name);
                    yield return Path.Combine(directory, name);
                }
        }
    }

    public static bool IsPythonStoreAlias(string candidate)
    {
        var name = Path.GetFileNameWithoutExtension(candidate);
        return (name.Equals("python", StringComparison.OrdinalIgnoreCase) || name.Equals("python3", StringComparison.OrdinalIgnoreCase)) &&
            string.Equals(Path.GetDirectoryName(candidate)?.TrimEnd(Path.DirectorySeparatorChar),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps"), StringComparison.OrdinalIgnoreCase);
    }

    public string? FindPython()
    {
        var candidates = new List<string?> { Which("python"), Which("python3"), Which("py") };
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Python");
        var programFiles = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) };
        foreach (var root in new[] { local }.Concat(programFiles).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(root)) continue;
            try
            {
                candidates.AddRange(Directory.EnumerateDirectories(root, "Python*", SearchOption.TopDirectoryOnly)
                    .Select(directory => Path.Combine(directory, "python.exe")));
            }
            catch { }
        }
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe"));
        return candidates.Where(path => path is not null && File.Exists(path) && !IsPythonStoreAlias(path))
            .Select(path => path!).FirstOrDefault();
    }
}
