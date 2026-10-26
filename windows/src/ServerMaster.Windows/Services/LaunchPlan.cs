using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class LaunchPlan
{
    public required string Executable { get; init; }
    public List<string> Arguments { get; init; } = [];
    public required string WorkingDirectory { get; init; }
    public Dictionary<string, string> Environment { get; init; } = [];
    public string DisplayCommand => string.Join(" ", new[] { Executable }.Concat(
        Arguments.Select((argument, index) => index > 0 && Arguments[index - 1] == "--password"
            ? "********" : argument.StartsWith("--password=", StringComparison.Ordinal) ? "--password=********" : argument)).Select(Quote));

    private static string Quote(string value) => value.Contains(' ') ? "\"" + value.Replace("\"", "\\\"") + "\"" : value;
}

public static class LaunchPlanBuilder
{
    public static LaunchPlan Build(ServerProfile profile)
    {
        var issues = profile.ValidationIssues();
        if (issues.Count > 0)
        {
            throw new InvalidOperationException(string.Join(" ", issues));
        }

        var root = profile.ExpandedRootPath;
        var cwd = Directory.Exists(profile.EffectiveWorkingDirectory)
            ? profile.EffectiveWorkingDirectory
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var env = profile.EnvironmentDictionary();
        var extra = SplitArguments(profile.ExtraArguments);

        return profile.Engine switch
        {
            "httpServer" => BuildHttpServer(profile, root, cwd, env, extra),
            "nodeScript" => new LaunchPlan
            {
                Executable = Require("node"),
                WorkingDirectory = cwd,
                Environment = WithPortEnv(env, profile),
                Arguments = [ResolveNodeEntry(profile), .. extra]
            },
            "pythonHTTP" => new LaunchPlan
            {
                Executable = RequirePython(),
                WorkingDirectory = cwd,
                Environment = env,
                Arguments = ["-u", "-m", "http.server", profile.Port.ToString(), "--bind", profile.Host, "--directory", root, .. extra]
            },
            "phpBuiltIn" => BuildPhp(profile, root, cwd, env, extra),
            "custom" => BuildCustom(profile, cwd, env, extra),
            _ => throw new NotSupportedException($"{profile.EngineTitle} is not wired on Windows yet.")
        };
    }

    private static LaunchPlan BuildPhp(ServerProfile profile, string root, string cwd, Dictionary<string, string> env, List<string> extra)
    {
        var executable = PhpRuntime.Require(profile.PhpVersion);
        var args = new List<string> { "-c", Path.GetDirectoryName(executable)! };
        args.AddRange(PhpConfigurationArguments(profile));
        args.AddRange(["-S", $"{profile.Host}:{profile.Port}", "-t", root]);
        if (env.TryGetValue("SERVERMASTER_HTTPS_PORT", out var publicPort) && int.TryParse(publicPort, out _))
        {
            var prepend = Path.Combine(AppPaths.Runtime, "https-prepend.php");
            File.WriteAllText(prepend, "<?php $_SERVER['HTTPS'] = 'on'; $_SERVER['SERVER_PORT'] = getenv('SERVERMASTER_HTTPS_PORT');");
            args.InsertRange(0, ["-d", "auto_prepend_file=" + prepend]);
        }
        args.AddRange(extra);
        if (PhpSiteCompatibility.IsJoomla(root)) args.Add(PhpSiteCompatibility.EnsureJoomlaRouter());
        return new LaunchPlan { Executable = executable, WorkingDirectory = cwd, Environment = env, Arguments = args };
    }

    public static List<string> PhpConfigurationArguments(ServerProfile profile) =>
    [
        "-d", "memory_limit=" + profile.PhpMemoryLimit.Trim(),
        "-d", "upload_max_filesize=" + profile.PhpUploadMaxFilesize.Trim(),
        "-d", "post_max_size=" + profile.PhpUploadMaxFilesize.Trim(),
        "-d", "max_execution_time=" + profile.PhpMaxExecutionTime,
        "-d", "display_errors=" + (profile.PhpDisplayErrors ? "1" : "0"),
        "-d", "log_errors=1"
    ];

    public static List<string> SplitArguments(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return [];
        var pointer = CommandLineToArgvW("ServerMaster " + raw, out var count);
        if (pointer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        try
        {
            return Enumerable.Range(1, count - 1).Select(index =>
                System.Runtime.InteropServices.Marshal.PtrToStringUni(System.Runtime.InteropServices.Marshal.ReadIntPtr(pointer, index * IntPtr.Size)) ?? "").ToList();
        }
        finally { LocalFree(pointer); }
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    private static LaunchPlan BuildCustom(ServerProfile profile, string cwd, Dictionary<string, string> env, List<string> extra)
    {
        var command = profile.CustomCommand.Trim();
        if (string.IsNullOrWhiteSpace(command))
        {
            throw new InvalidOperationException("No launch command specified.");
        }

        env = WithPortEnv(env, profile);
        return new LaunchPlan
        {
            Executable = Require(command),
            WorkingDirectory = cwd,
            Environment = env,
            Arguments = [.. SplitArguments(profile.CustomArguments), .. extra]
        };
    }

    private static LaunchPlan BuildHttpServer(ServerProfile profile, string root, string cwd,
        Dictionary<string, string> env, List<string> extra)
    {
        var shim = Require("http-server");
        var script = Path.Combine(Path.GetDirectoryName(shim)!, "node_modules", "http-server", "bin", "http-server");
        if (!File.Exists(script)) throw new FileNotFoundException("http-server is installed, but its script is missing. Reinstall it from Dependencies.");
        return new LaunchPlan
        {
            Executable = Require("node"),
            WorkingDirectory = cwd,
            Environment = env,
            Arguments = [script, .. BuildHttpServerArgs(profile, root, extra)]
        };
    }

    private static List<string> BuildHttpServerArgs(ServerProfile profile, string root, List<string> extra)
    {
        var args = new List<string> { root, "-a", profile.Host, "-p", profile.Port.ToString() };
        if (profile.SpaFallback) args.AddRange(["--proxy", $"http://{profile.DisplayHost}:{profile.Port}?"]);
        if (profile.EnableCors)
        {
            args.Add("--cors");
        }

        if (profile.EnableGzip)
        {
            args.Add("-g");
        }

        if (!profile.DirectoryListing)
        {
            args.Add("-d");
            args.Add("false");
        }

        if (profile.CacheSeconds >= 0)
        {
            args.Add("-c" + profile.CacheSeconds);
        }
        else
        {
            args.Add("-c-1");
        }

        if (profile.HideDotfiles)
        {
            args.Add("--no-dotfiles");
        }

        if (profile.BasicAuthEnabled)
        {
            args.Add("--username");
            args.Add(profile.BasicAuthUser);
            args.Add("--password");
            args.Add(profile.BasicAuthPassword);
        }

        args.AddRange(extra);
        return args;
    }

    private static Dictionary<string, string> WithPortEnv(Dictionary<string, string> env, ServerProfile profile)
    {
        var result = new Dictionary<string, string>(env, StringComparer.OrdinalIgnoreCase)
        {
            ["PORT"] = env.TryGetValue("PORT", out var port) ? port : profile.Port.ToString(),
            ["HOST"] = env.TryGetValue("HOST", out var host) ? host : profile.Host
        };
        return result;
    }

    private static string ResolveNodeEntry(ServerProfile profile)
    {
        var entry = AppPaths.Expand(profile.NodeEntryFile.Trim());
        return Path.IsPathFullyQualified(entry) ? entry : Path.Combine(profile.EffectiveWorkingDirectory, entry);
    }

    private static string RequirePython()
    {
        return ShellEnvironment.Shared.FindPython()
            ?? throw new FileNotFoundException("Executable python was not found. Install Python or add it to PATH.");
    }

    private static string Require(string tool)
    {
        return ShellEnvironment.Shared.Which(tool)
            ?? throw new FileNotFoundException($"Executable {tool} was not found. Install it or add it to PATH.");
    }
}
