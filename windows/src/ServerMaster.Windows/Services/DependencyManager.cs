using System.Diagnostics;
using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class DependencyManager
{
    private readonly DispatcherQueue _dispatcher;
    private readonly SemaphoreSlim _operations = new(1, 1);
    private readonly Dictionary<DependencyStatus, Task> _checks = [];

    public DependencyManager(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public async Task CheckAllAsync(IEnumerable<DependencyStatus> statuses)
    {
        // Materialize first: one row failing to start must not stop the rows after it.
        await Task.WhenAll(statuses.ToArray().Select(CheckAsync).ToArray());
    }

    public Task CheckAsync(DependencyStatus status)
    {
        if (status.Busy) return Task.CompletedTask;
        try { return RefreshAsync(status); }
        catch (Exception ex) { RecordFailure(status, ex); return Task.CompletedTask; }
    }

    private async Task RefreshAsync(DependencyStatus status)
    {
        Task task;
        lock (_checks)
        {
            if (_checks.TryGetValue(status, out var pending)) task = pending;
            else { task = CheckCoreAsync(status); _checks[status] = task; }
        }
        try { await task; }
        catch (Exception ex) { RecordFailure(status, ex); }
        finally
        {
            lock (_checks) { if (_checks.TryGetValue(status, out var current) && current == task) _checks.Remove(status); }
            RunOnUi(() => { status.Checking = false; status.Checked = true; });
        }
    }

    private void RecordFailure(DependencyStatus status, Exception ex) => RunOnUi(() =>
    {
        status.Installed = false;
        status.Version = "";
        status.Error = $"Could not check {status.Dependency.Title}: {ex.Message}";
        status.Message = status.Error;
        status.Checking = false;
        status.Checked = true;
    });

    private async Task CheckCoreAsync(DependencyStatus status)
    {
        RunOnUi(() =>
        {
            status.Checking = true;
            status.Message = "Checking...";
        });

        var dependency = status.Dependency;
        if (dependency.Command == "adminer")
        {
            var installed = AdminerService.IsInstalled;
            status.Installed = installed;
            status.Path = installed ? AdminerService.FilePath : "";
            status.Version = installed ? AdminerService.Version : "";
            status.Message = installed ? $"Adminer is installed at {AdminerService.FilePath}." : MissingMessage(dependency);
            status.Error = "";
            status.Checked = true;
            status.Checking = false;
            return;
        }
        if (dependency.Command == "phpmyadmin")
        {
            var installed = PhpMyAdminRuntime.IsInstalled;
            status.Installed = installed;
            status.Path = installed ? PhpMyAdminRuntime.DirectoryPath : "";
            status.Version = installed ? "phpMyAdmin " + PhpMyAdminRuntime.Version : "";
            status.Message = installed ? $"phpMyAdmin {PhpMyAdminRuntime.Version} is installed at {PhpMyAdminRuntime.DirectoryPath}." : MissingMessage(dependency);
            status.Error = "";
            status.Checked = true;
            status.Checking = false;
            return;
        }
        if (dependency.Command == "vcredist")
        {
            var installedRuntimeVersion = VcRuntime.InstalledVersion();
            status.Installed = installedRuntimeVersion is not null;
            status.Path = "";
            status.Version = installedRuntimeVersion?.ToString() ?? "";
            status.Message = status.Installed ? $"Visual C++ {installedRuntimeVersion} ({VcRuntime.Architecture}) is installed." : $"Microsoft Visual C++ Runtime ({VcRuntime.Architecture}) is missing. PHP needs it to start.";
            status.Error = "";
            status.Checked = true;
            status.Checking = false;
            return;
        }
        var path = dependency.PhpVersion.Length > 0 ? PhpRuntime.Find(dependency.PhpVersion) :
            dependency.Command == "python" ? ShellEnvironment.Shared.FindPython() :
            dependency.Command == "php" ? PhpRuntime.Find("") ?? ShellEnvironment.Shared.Which("php") : ShellEnvironment.Shared.Which(dependency.Command);
        if (path is null)
        {
            RunOnUi(() =>
            {
                status.Installed = false;
                status.Path = "";
                status.Version = "";
                status.Message = MissingMessage(dependency);
                status.Error = "";
                status.Checking = false;
                status.Checked = true;
            });
            return;
        }

        if (dependency.PhpVersion.Length > 0) PhpRuntime.ValidateFiles(Path.GetDirectoryName(path)!);
        var arguments = dependency.PhpVersion.Length > 0 ? new[] { "-c", Path.GetDirectoryName(path)!, "-r", "echo PHP_VERSION;" } : dependency.VersionArguments;
        var result = await RunProcessAsync(path, arguments, TimeSpan.FromSeconds(15));
        if (result.ExitCode != 0)
        {
            RunOnUi(() =>
            {
                status.Installed = false;
                status.Path = path;
                status.Version = "";
                status.Message = dependency.PhpVersion.Length > 0
                    ? $"PHP {dependency.PhpVersion} cannot start (code 0x{unchecked((uint)result.ExitCode):X8}). " +
                      (unchecked((uint)result.ExitCode) == 0xC0000135 ? "A required DLL could not be loaded. Repair Microsoft Visual C++ Runtime and retry the PHP installation." : "Check the details below and retry the PHP installation.") +
                      (string.IsNullOrWhiteSpace(result.Combined) ? "" : " " + result.Combined.Trim())
                    : $"{dependency.Title} could not run (code {result.ExitCode}): {result.Combined.Trim()}";
                status.Error = status.Message;
                status.Checking = false;
                status.Checked = true;
            });
            return;
        }
        var version = result.Combined.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        if (dependency.PhpVersion.Length > 0)
        {
            var actual = result.Stdout.Trim();
            var modules = await RunProcessAsync(path, ["-c", Path.GetDirectoryName(path)!, "-m"], TimeSpan.FromSeconds(15));
            var installedModules = modules.Stdout.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var missing = new[] { "mysqli", "pdo_mysql", "gd", "zip", "intl", "mbstring", "curl", "xml", "json", "openssl", "fileinfo" }.Where(module => !installedModules.Contains(module)).ToList();
            if (!actual.StartsWith(dependency.PhpVersion + ".", StringComparison.Ordinal) || missing.Count > 0 || modules.ExitCode != 0)
            {
                status.Installed = false;
                status.Checked = true;
                status.Checking = false;
                status.Path = path;
                status.Error = !actual.StartsWith(dependency.PhpVersion + ".", StringComparison.Ordinal)
                    ? $"Expected PHP {dependency.PhpVersion}, but found {actual}. Reinstall this version."
                    : $"PHP {dependency.PhpVersion} is missing required extensions: {string.Join(", ", missing)}. Reinstall this version.";
                status.Message = status.Error;
                return;
            }
            version = "PHP " + actual;
        }
        RunOnUi(() =>
        {
            status.Installed = true;
            status.Path = path;
            status.Version = version;
            status.Message = version;
            status.Checking = false;
            status.Checked = true;
            status.Error = "";
        });
    }

    public async Task InstallOrRemoveAsync(DependencyStatus status, ConsoleLog log)
    {
        if (status.Installed)
        {
            await RemoveAsync(status, log);
        }
        else
        {
            await InstallAsync(status, log);
        }
    }

    public async Task InstallAsync(DependencyStatus status, ConsoleLog log, bool update = false)
    {
        if (status.Checking) await RefreshAsync(status);
        if (status.Busy) throw new InvalidOperationException($"An operation for {status.Dependency.Title} is already running. Wait for it to finish.");
        var dependency = status.Dependency;
        RunOnUi(() =>
        {
            status.Busy = true;
            status.Message = "Installing...";
            status.Error = "";
            status.Progress = 0;
        });
        await _operations.WaitAsync();
        try
        {
            await RefreshAsync(status);
            if (status.Installed && !update && dependency.Command != "vcredist") return;
            status.Error = "";
            status.Message = "Installing " + dependency.Title + "...";
            if (dependency.Command == "node" && NodeRuntime.ActiveDirectory is { } activeNode)
            {
                var current = Path.GetFileName(activeNode);
                var prefix = current.Split('.')[0] + ".";
                var latest = (await NodeRuntime.VersionsAsync()).First(version => version.StartsWith(prefix, StringComparison.Ordinal));
                await NodeRuntime.SelectAsync(latest, message => RunOnUi(() => status.Message = message));
                await RefreshAsync(status);
                return;
            }
            if (dependency.Command == "vcredist")
            {
                void Progress(string message, double percent) => RunOnUi(() => { status.Message = message; status.Progress = percent; });
                var package = await VcRuntime.FetchAsync(Progress);
                status.AvailableVersion = "Latest available: " + package.Version;
                var restart = await VcRuntime.InstallAsync(package, Progress, repair: update);
                await RefreshAsync(status);
                status.Progress = 100;
                status.Message = restart ? "Visual C++ installed. Restart Windows before starting PHP." : $"Visual C++ {status.Version} is ready.";
                log.System(status.Message);
                return;
            }
            if (dependency.PhpVersion.Length > 0)
            {
                if (VcRuntime.InstalledVersion() is null)
                    throw new InvalidOperationException("Microsoft Visual C++ Runtime is required before installing PHP. Install or repair it in Dependencies, then retry PHP.");
                if (!status.Installed || update)
                    await PhpRuntime.InstallAsync(dependency.PhpVersion, (message, percent) => RunOnUi(() =>
                    {
                        status.Message = message;
                        status.Progress = percent;
                    }));
                await RefreshAsync(status);
                if (!status.Installed) throw new InvalidOperationException(status.Message);
                status.Progress = 100;
                log.System($"PHP {dependency.PhpVersion} is ready: {status.Path}");
                return;
            }
            if (dependency.Command == "adminer")
            {
                await AdminerService.InstallAsync(new Progress<double>(value => RunOnUi(() => status.Progress = value)));
                await RefreshAsync(status);
                if (!status.Installed) throw new InvalidOperationException("Adminer was downloaded but could not be verified.");
                status.Progress = 100;
                log.System($"Adminer is ready: {status.Path}");
                return;
            }
            if (dependency.Command == "phpmyadmin")
            {
                await PhpMyAdminRuntime.InstallAsync(new Progress<double>(value => RunOnUi(() => status.Progress = value)));
                await RefreshAsync(status);
                if (!status.Installed) throw new InvalidOperationException("phpMyAdmin was downloaded but could not be verified.");
                status.Progress = 100;
                log.System($"phpMyAdmin is ready: {status.Path}");
                return;
            }
            var command = InstallCommand(dependency);
            if (update && dependency.WingetId is not null)
                command = new DependencyCommand($"winget upgrade --id {dependency.WingetId} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity", "Update " + dependency.Title);
            if (command is null)
            {
                throw new InvalidOperationException($"{dependency.Title} needs App Installer from Microsoft Store.");
            }
            if (dependency.WingetId is not null && ShellEnvironment.Shared.Which("winget") is null)
                throw new InvalidOperationException("Windows Package Manager is missing. Install App Installer from Microsoft Store, then try again.");
            if (dependency.Command == "http-server" && ShellEnvironment.Shared.Which("npm") is null)
                throw new InvalidOperationException("npm is missing. Install Node.js first, then try again.");

            log.System($"Installing {dependency.Title}");
            log.System(command.Display);
            var result = await RunShellAsync(command.Command, TimeSpan.FromMinutes(30), line =>
            {
                log.Append(line, LogStream.Stdout);
                RunOnUi(() => status.Message = line);
            });
            log.System(result.ExitCode == 0
                ? $"{dependency.Title} installer finished."
                : $"{dependency.Title} installer finished with code {result.ExitCode}.");
            if (result.ExitCode != 0 && !(update && unchecked((uint)result.ExitCode) == 0x8A15002B))
                throw new InvalidOperationException($"{dependency.Title} was not installed (code 0x{unchecked((uint)result.ExitCode):X8}). {result.Combined.Trim()}");
            await RefreshAsync(status);
            if (!status.Installed)
                throw new InvalidOperationException($"{dependency.Title} was not found after installation. {status.Message}");
        }
        catch (Exception ex)
        {
            var message = ex switch
            {
                HttpRequestException => $"Could not download {dependency.Title}. Check your internet connection and retry.",
                OperationCanceledException => $"Installing {dependency.Title} timed out. Check your connection and retry.",
                UnauthorizedAccessException => $"Windows denied access while installing {dependency.Title}. Close programs using it and retry.",
                _ => ex.Message
            };
            RunOnUi(() => { status.Error = message; status.Message = message; });
            log.Append(ex.ToString(), LogStream.Stderr);
            throw new InvalidOperationException(message, ex);
        }
        finally
        {
            RunOnUi(() => status.Busy = false);
            _operations.Release();
        }
    }

    public async Task RemoveAsync(DependencyStatus status, ConsoleLog log)
    {
        if (status.Checking) await RefreshAsync(status);
        if (status.Busy) throw new InvalidOperationException($"An operation for {status.Dependency.Title} is already running. Wait for it to finish.");
        var dependency = status.Dependency;
        RunOnUi(() =>
        {
            status.Busy = true;
            status.Message = "Removing...";
            status.Error = "";
        });

        await _operations.WaitAsync();
        try
        {
            if (dependency.Command == "npm")
                throw new InvalidOperationException("npm is part of Node.js. Remove Node.js to remove both; npm cannot be removed separately.");
            if (dependency.Command == "node" && NodeRuntime.ActiveDirectory is not null)
            {
                await Task.Run(NodeRuntime.RemoveActive);
                await RefreshAsync(status);
                status.Message = "Managed Node.js removed. " + (status.Installed ? "Using system Node.js: " + status.Version : "No system Node.js found.");
                return;
            }
            if (dependency.PhpVersion.Length > 0)
            {
                await Task.Run(() => PhpRuntime.Remove(dependency.PhpVersion));
                await RefreshAsync(status);
                status.Message = $"PHP {dependency.PhpVersion} removed.";
                return;
            }
            if (dependency.Command == "adminer")
            {
                AdminerService.Remove();
                await RefreshAsync(status);
                status.Message = "Adminer removed.";
                return;
            }
            if (dependency.Command == "phpmyadmin")
            {
                PhpMyAdminRuntime.Remove();
                await RefreshAsync(status);
                status.Message = "phpMyAdmin removed.";
                return;
            }
            var command = RemoveCommand(dependency);
            if (command is null)
            {
                log.Append($"{dependency.Title} cannot be removed automatically yet.", LogStream.Stderr);
                RunOnUi(() => status.Message = "Manual removal needed");
                return;
            }

            if (dependency.WingetId is { } packageId)
            {
                var winget = ShellEnvironment.Shared.Which("winget")
                    ?? throw new InvalidOperationException("Windows Package Manager is missing. Reinstall App Installer before removing this package.");
                var listed = await RunProcessAsync(winget,
                    ["list", "--id", packageId, "--exact", "--disable-interactivity"], TimeSpan.FromMinutes(2));
                if (listed.ExitCode != 0)
                    throw new InvalidOperationException($"{dependency.Title} runs from {status.Path}, but Windows Package Manager cannot find its installed package. Remove it with its original installer or Windows Apps settings. No files were changed.");
            }

            log.System($"Removing {dependency.Title}");
            log.System(command.Display);
            var result = dependency.WingetId is not null
                ? await RunElevatedUninstallAsync(dependency)
                : await RunShellAsync(command.Command, TimeSpan.FromMinutes(20), line =>
            {
                log.Append(line, LogStream.Stdout);
                RunOnUi(() => status.Message = line);
            });
            if (result.ExitCode != 0) throw new InvalidOperationException($"Could not remove {dependency.Title} (code 0x{unchecked((uint)result.ExitCode):X8}). {result.Combined} Close applications using it and retry. Your files have not been deleted by ServerMaster.");
            await RefreshAsync(status);
            if (status.Installed) throw new InvalidOperationException($"The uninstaller finished, but {dependency.Title} is still available at {status.Path}. Another installation may exist.");
        }
        catch (Exception ex)
        {
            RunOnUi(() => { status.Error = ex.Message; status.Message = ex.Message; });
            log.Append(ex.Message, LogStream.Stderr);
            throw;
        }
        finally
        {
            RunOnUi(() => status.Busy = false);
            _operations.Release();
        }
    }

    public async Task CheckRuntimeUpdateAsync(DependencyStatus status)
    {
        await CheckUpdateCoreAsync(status);
    }

    public async Task<IReadOnlyList<string>> PackageVersionsAsync(DependencyStatus status)
    {
        if (status.Dependency.Command == "http-server")
        {
            var npm = ShellEnvironment.Shared.Which("npm")
                ?? throw new InvalidOperationException("npm is missing. Install Node.js before choosing an http-server version.");
            var registry = await RunProcessAsync(npm, ["view", "http-server", "versions", "--json"], TimeSpan.FromMinutes(2));
            if (registry.ExitCode != 0) throw new IOException("Could not load http-server releases from npm: " + registry.Combined);
            return ParseNpmVersions(registry.Stdout);
        }
        var id = status.Dependency.WingetId ?? throw new InvalidOperationException("This dependency does not have a Windows package catalog.");
        var winget = ShellEnvironment.Shared.Which("winget")
            ?? throw new InvalidOperationException("Windows Package Manager is missing. Install App Installer before choosing a package version.");
        var result = await RunProcessAsync(winget, ["show", "--id", id, "--exact", "--versions", "--source", "winget", "--accept-source-agreements", "--disable-interactivity"], TimeSpan.FromSeconds(60));
        if (result.ExitCode != 0) throw new IOException(result.Combined);
        var versions = result.Stdout.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(line => line.Trim())
            .Where(line => System.Text.RegularExpressions.Regex.IsMatch(line, @"^v?\d+(\.\d+){1,4}([-+][a-zA-Z0-9.]+)?$")).Distinct().ToArray();
        if (versions.Length == 0) throw new IOException("The Windows package catalog did not return any installable versions.");
        return versions;
    }

    internal static IReadOnlyList<string> ParseNpmVersions(string json)
    {
        using var document = System.Text.Json.JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array)
            throw new IOException("The npm registry returned an invalid version list.");
        var versions = document.RootElement.EnumerateArray()
            .Where(item => item.ValueKind == System.Text.Json.JsonValueKind.String)
            .Select(item => item.GetString()!)
            .Where(version => System.Text.RegularExpressions.Regex.IsMatch(version, @"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"))
            .Distinct().Reverse().ToArray();
        if (versions.Length == 0) throw new IOException("The npm registry did not return any installable http-server versions.");
        return versions;
    }

    public async Task InstallVersionAsync(DependencyStatus status, string version)
    {
        if (status.Busy || status.Checking) throw new InvalidOperationException("Wait for the current dependency operation.");
        status.Busy = true; status.Error = "";
        await _operations.WaitAsync();
        try
        {
            if (!(await PackageVersionsAsync(status)).Contains(version)) throw new IOException("The selected release is no longer in the package catalog.");
            status.Message = "Installing version " + version;
            var result = status.Dependency.Command == "http-server"
                ? await RunProcessAsync(ShellEnvironment.Shared.Which("npm")!,
                    ["install", "--global", "http-server@" + version, "--no-audit", "--no-fund"],
                    TimeSpan.FromMinutes(30), line => RunOnUi(() => status.Message = line))
                : await RunProcessAsync(ShellEnvironment.Shared.Which("winget") ?? "winget.exe",
                    ["install", "--id", status.Dependency.WingetId!, "--exact", "--version", version, "--source", "winget", "--force", "--no-upgrade", "--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"],
                    TimeSpan.FromMinutes(30), line => RunOnUi(() => status.Message = line));
            if (result.ExitCode != 0) throw new IOException("The package installer rejected this version. Some packages require removing the current version first. " + result.Combined);
            await RefreshAsync(status);
            if (!status.Installed || !System.Text.RegularExpressions.Regex.IsMatch(status.Version, @"(?<![\d.])" + System.Text.RegularExpressions.Regex.Escape(version.TrimStart('v')) + @"(?![\d.])"))
                throw new IOException("The requested version was not activated. Detected: " + status.Version + " at " + status.Path);
        }
        catch (Exception ex) { status.Error = ex.Message; throw; }
        finally { status.Busy = false; _operations.Release(); }
    }

    private async Task CheckUpdateCoreAsync(DependencyStatus status)
    {
        if (status.Busy || status.Checking) return;
        status.Busy = true;
        status.Error = "";
        await _operations.WaitAsync();
        try
        {
            if (status.Dependency.Command != "vcredist")
            {
                await RefreshAsync(status);
                if (status.Dependency.PhpVersion.Length > 0)
                {
                    using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
                    using var manifest = System.Text.Json.JsonDocument.Parse(await client.GetStringAsync("https://downloads.php.net/~windows/releases/releases.json"));
                    status.AvailableVersion = "Latest PHP: " + manifest.RootElement.GetProperty(status.Dependency.PhpVersion).GetProperty("version").GetString();
                }
                else if (status.Dependency.WingetId is not null)
                {
                    var versions = await PackageVersionsAsync(status);
                    status.AvailableVersion = "Latest available: " + versions[0];
                }
                else if (status.Dependency.Command == "http-server")
                {
                    var versions = await PackageVersionsAsync(status);
                    status.AvailableVersion = "Latest available: " + versions[0];
                }
                status.Message = "Version check completed. Installed: " + status.Version;
                return;
            }
            var package = await VcRuntime.FetchAsync((message, percent) => RunOnUi(() => { status.Message = message; status.Progress = percent; }), refresh: true);
            status.AvailableVersion = "Latest available: " + package.Version;
            await RefreshAsync(status);
            var current = VcRuntime.InstalledVersion();
            status.Message = current is null ? "Visual C++ Runtime is missing. Select Install." : current < package.Version ? $"Update available: {current} to {package.Version}." : $"Visual C++ {current} is up to date.";
        }
        catch (Exception ex) { status.Error = "Could not check the update: " + ex.Message; status.Message = status.Error; }
        finally { status.Busy = false; _operations.Release(); }
    }

    private static DependencyCommand? InstallCommand(Dependency dependency)
    {
        if (!string.IsNullOrWhiteSpace(dependency.InstallCommand))
        {
            return new DependencyCommand(dependency.InstallCommand, dependency.InstallCommand);
        }

        if (!string.IsNullOrWhiteSpace(dependency.WingetId))
        {
            var command = $"winget install --id {dependency.WingetId} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity";
            return new DependencyCommand(command, $"Install {dependency.Title} with Windows Package Manager");
        }

        return null;
    }

    private static DependencyCommand? RemoveCommand(Dependency dependency)
    {
        if (dependency.Command == "winget")
        {
            return null;
        }

        if (!string.IsNullOrWhiteSpace(dependency.UninstallCommand))
        {
            return new DependencyCommand(dependency.UninstallCommand, dependency.UninstallCommand);
        }

        if (!string.IsNullOrWhiteSpace(dependency.WingetId))
        {
            var command = $"winget uninstall --id {dependency.WingetId} --exact --source winget --silent --accept-source-agreements --disable-interactivity";
            return new DependencyCommand(command, $"Remove {dependency.Title} with Windows Package Manager");
        }

        return null;
    }

    private static async Task<ProcessResult> RunElevatedUninstallAsync(Dependency dependency)
    {
        var info = new ProcessStartInfo
        {
            FileName = ShellEnvironment.Shared.Which("winget") ?? "winget.exe",
            Arguments = $"uninstall --id {dependency.WingetId} --exact --source winget --silent --accept-source-agreements --disable-interactivity",
            UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden
        };
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Windows could not start the uninstaller.");
        await process.WaitForExitAsync();
        return new ProcessResult(process.ExitCode, "", process.ExitCode == 0 ? "" : "The Windows package uninstaller failed. Details are in the WinGet installation logs.");
    }

    private static string MissingMessage(Dependency dependency)
    {
        if (dependency.Command == "adminer") return "Adminer is not installed. Select Install to download the database panel.";
        if (dependency.Command == "phpmyadmin") return "phpMyAdmin is not installed. Select Install to download and verify the official stable package.";
        if (dependency.PhpVersion.Length > 0) return $"PHP {dependency.PhpVersion} is not installed. Select Install to download this version.";
        if (dependency.Command == "winget")
        {
            return "Install App Installer from Microsoft Store to enable one-click installs.";
        }

        return dependency.WingetId is null && dependency.InstallCommand is null
            ? "Manual install needed"
            : $"{dependency.Title} is not installed. Select Install to prepare it.";
    }

    private static async Task<ProcessResult> RunShellAsync(string command, TimeSpan timeout, Action<string>? output = null)
    {
        return await RunProcessAsync("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
            "$ErrorActionPreference = 'Stop'; $OutputEncoding = [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false); " + command + "; exit $LASTEXITCODE"], timeout, output);
    }

    private static async Task<ProcessResult> RunProcessAsync(string executable, IEnumerable<string> arguments, TimeSpan timeout, Action<string>? output = null)
    {
        var args = arguments.ToList();
        string? shellArguments = null;
        if (Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
            Path.GetExtension(executable).Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            // cmd /s /c needs an outer quote pair around the entire command.
            shellArguments = "/d /s /c \"\"" + executable + "\" " +
                string.Join(" ", args.Select(argument => "\"" + argument.Replace("\"", "\"\"") + "\"")) + "\"";
            executable = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
        }
        var info = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            CreateNoWindow = true
        };

        if (shellArguments is not null) info.Arguments = shellArguments;
        else foreach (var argument in args) info.ArgumentList.Add(argument);

        foreach (var (key, value) in ShellEnvironment.Shared.EnvironmentFor())
        {
            info.Environment[key] = value;
        }

        using var process = new Process { StartInfo = info };
        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            output?.Invoke(ex.Message);
            return new ProcessResult(-1, "", ex.Message);
        }

        var stdout = ReadOutputAsync(process.StandardOutput, output);
        var stderr = ReadOutputAsync(process.StandardError, output);
        try
        {
            await process.WaitForExitAsync().WaitAsync(timeout);
        }
        catch (TimeoutException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch
            {
                // Nothing useful to do here; the caller gets the timeout text.
            }

            return new ProcessResult(-1, await stdout, (await stderr) + Environment.NewLine + "Timed out.");
        }

        return new ProcessResult(process.ExitCode, await stdout, await stderr);
    }

    private static async Task<string> ReadOutputAsync(StreamReader reader, Action<string>? output)
    {
        var lines = new List<string>();
        while (await reader.ReadLineAsync() is { } line)
        {
            lines.Add(line);
            if (!string.IsNullOrWhiteSpace(line)) output?.Invoke(line);
        }
        return string.Join(Environment.NewLine, lines);
    }

    private void RunOnUi(Action action)
    {
        if (_dispatcher.HasThreadAccess)
        {
            action();
        }
        else
        {
            _dispatcher.TryEnqueue(() => action());
        }
    }

    private sealed record DependencyCommand(string Command, string Display);
    private sealed record ProcessResult(int ExitCode, string Stdout, string Stderr)
    {
        public string Combined => string.Join(Environment.NewLine, new[] { Stdout, Stderr }.Where(part => !string.IsNullOrWhiteSpace(part)));
    }
}
