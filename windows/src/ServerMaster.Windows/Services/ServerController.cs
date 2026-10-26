using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed partial class ServerController
{
    private readonly DispatcherQueue _dispatcher;
    private Process? _process;
    private IDisposable? _ownedGroup;
    private ElevatedServerClient? _elevated;
    private HttpsProxy? _httpsProxy;
    private bool _listenedPort;
    private bool _intentionalStop;
    private readonly List<string> _recentStderr = [];
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private CancellationTokenSource? _startup;
    private int _stopVersion;

    public ServerController(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        Log = new ConsoleLog(dispatcher);
    }

    public ConsoleLog Log { get; }
    public ServerProfile? ActiveProfile { get; private set; }
    public bool HasOwnedProcess => _ownedGroup is not null || _elevated is not null || _httpsProxy is not null || _process is { HasExited: false };
    public List<string> DetectedUrls { get; } = [];
    public event Action<ServerProfile, int>? UnexpectedExit;

    public async Task StartAsync(ServerProfile profile, AppSettings settings)
    {
        var stopVersion = Volatile.Read(ref _stopVersion);
        await _lifecycle.WaitAsync();
        try
        {
            if (stopVersion != Volatile.Read(ref _stopVersion)) return;
            if (_process is { HasExited: false }) return;
            if (_elevated is { } previous)
            {
                await previous.StopAsync();
                _elevated = null;
            }
            _ownedGroup?.Dispose();
            _ownedGroup = null;
            _process?.Dispose();
            _process = null;
            _startup = new CancellationTokenSource();
            await StartCoreAsync(profile, settings, _startup.Token);
        }
        catch (OperationCanceledException) { await StopCoreAsync(profile); }
        catch (Exception ex)
        {
            var message = Explain(ex.Message, profile);
            await StopCoreAsync(profile);
            Fail(profile, message);
        }
        finally { _startup?.Dispose(); _startup = null; _lifecycle.Release(); }
    }

    private async Task StartCoreAsync(ServerProfile profile, AppSettings settings, CancellationToken cancellationToken)
    {
        if (profile.IsActive)
        {
            return;
        }

        _intentionalStop = false;
        _listenedPort = false;
        _recentStderr.Clear();
        DetectedUrls.Clear();
        ActiveProfile = profile;
        SetProfileState(profile, ServerState.Starting);
        Log.Limit = settings.ConsoleBufferLines;

        if (settings.WriteLogsToFile)
        {
            Log.StartFileLogging(profile.Name);
        }

        Log.System($"Starting profile \"{profile.Name}\"");
        Log.System($"Engine: {profile.EngineTitle}");

        LaunchPlan plan;
        ServerProfile launchProfile = profile;
        try
        {
            if (profile.HttpsEnabled)
            {
                if (!profile.SupportsHttps) throw new InvalidOperationException("HTTPS is not supported for this engine.");
                LocalCertificates.Validate(profile);
                launchProfile = HttpsProxy.Backend(profile);
                launchProfile.Environment.Add(new EnvVar { Key = "SERVERMASTER_HTTPS_PORT", Value = profile.Port.ToString() });
            }
            plan = LaunchPlanBuilder.Build(launchProfile);
            if (profile.Engine != "custom" && settings.CheckPortBeforeStart)
            {
                try { await ServerReadiness.CheckPortAsync(profile, cancellationToken); }
                catch (IOException) when (settings.KillPortOccupantOnStart)
                {
                    var occupant = (await WindowsPortScanner.ScanAsync()).FirstOrDefault(item => item.Port == profile.Port);
                    if (occupant is null) throw;
                    WindowsPortScanner.Terminate(occupant);
                    await Task.Delay(250, cancellationToken);
                    await ServerReadiness.CheckPortAsync(profile, cancellationToken);
                }
            }
        }
        catch (Exception ex)
        {
            Fail(profile, ex.Message);
            return;
        }

        profile.LastCommand = plan.DisplayCommand;
        Log.System($"Command: {plan.DisplayCommand}");
        Log.System($"Working directory: {plan.WorkingDirectory}");

        Process process;
        if (profile.RunAsAdministrator && !WindowsElevation.IsElevated)
        {
            var elevated = new ElevatedServerClient();
            _elevated = elevated;
            elevated.Output += Ingest;
            await elevated.StartAsync(plan, cancellationToken);
            process = elevated.HelperProcess;
            elevated.Exited += code => HandleExit(profile, process, code);
            Log.System($"Administrator helper PID: {process.Id}");
            profile.ProcessId = elevated.ServerProcessId;
        }
        else
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = plan.Executable,
                WorkingDirectory = plan.WorkingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8,
                CreateNoWindow = true
            };
            foreach (var argument in plan.Arguments) startInfo.ArgumentList.Add(argument);
            foreach (var (key, value) in ShellEnvironment.Shared.EnvironmentFor(plan.Environment)) startInfo.Environment[key] = value;
            process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, args) => Ingest(args.Data, LogStream.Stdout);
            process.ErrorDataReceived += (_, args) => Ingest(args.Data, LogStream.Stderr);
            process.Exited += (_, _) => HandleExit(profile, process, process.ExitCode);
            _process = process;
            try
            {
                if (!process.Start()) throw new InvalidOperationException("Could not start the process.");
                _ownedGroup = OwnedProcesses.CreateGroup(process);
            }
            catch (Exception ex)
            {
                _process = null;
                process.Dispose();
                throw new InvalidOperationException($"Could not start the process: {ex.Message}", ex);
            }
            profile.ProcessId = process.Id;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }

        _process = process;
        profile.StartedAt = DateTimeOffset.Now;
        Log.System($"PID: {profile.ProcessId}");

        if (profile.Engine == "custom") await Task.Delay(300, cancellationToken);
        else await ServerReadiness.WaitHttpAsync(process, launchProfile, cancellationToken);
        if (profile.State != ServerState.Starting)
        {
            return;
        }

        if (!process.HasExited)
        {
            if (profile.HttpsEnabled)
            {
                try
                {
                    var proxy = new HttpsProxy(profile, launchProfile.Port, line => Log.Append(line, LogStream.System));
                    _httpsProxy = proxy;
                    proxy.Exited += () => _dispatcher.TryEnqueue(() =>
                    {
                        if (ReferenceEquals(_httpsProxy, proxy) && !_intentionalStop && profile.IsActive)
                        {
                            Fail(profile, "The HTTPS listener stopped. Check the console for certificate or port errors.");
                            if (_process is { HasExited: false }) _process.Kill(true);
                        }
                    });
                    await proxy.WaitReadyAsync(profile, cancellationToken);
                    DetectedUrls.Clear();
                }
                catch (Exception ex)
                {
                    await StopCoreAsync(profile);
                    cancellationToken.ThrowIfCancellationRequested();
                    Fail(profile, ex.Message);
                    return;
                }
            }
            if (DetectedUrls.Count == 0)
            {
                DetectedUrls.Add(profile.Address);
            }

            SetProfileState(profile, ServerState.Running);
            _listenedPort = true;
            Log.System($"Server is up: {string.Join(", ", DetectedUrls)}");

            if (profile.OpenBrowserOnStart || settings.OpenBrowserOnStart)
            {
                OpenInBrowser(profile.Address);
            }
        }
    }

    public async Task StopAsync(ServerProfile profile)
    {
        Interlocked.Increment(ref _stopVersion);
        _startup?.Cancel();
        await _lifecycle.WaitAsync();
        try { await StopCoreAsync(profile); }
        finally { _lifecycle.Release(); }
    }

    private async Task StopCoreAsync(ServerProfile profile)
    {
        _intentionalStop = true;
        _httpsProxy?.Dispose();
        _httpsProxy = null;
        SetProfileState(profile, ServerState.Stopping);
        if (_process is not null) Log.System($"Stopping the server (PID {_process.Id})...");

        try
        {
            var process = _process;
            var elevated = _elevated;
            if (elevated is not null)
            {
                await elevated.StopAsync();
                _elevated = null;
            }
            // Closing this job terminates the server and its descendants, even if the root already exited.
            _ownedGroup?.Dispose();
            _ownedGroup = null;
            if (elevated is null && process is { HasExited: false })
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
        catch (Exception ex)
        {
            Log.Append($"Could not stop the process cleanly: {ex.Message}", LogStream.Stderr);
            if (_process is { HasExited: false })
            {
                SetProfileState(profile, ServerState.Failed, "The process is still running. Try Stop again. " + ex.Message);
                return;
            }
        }

        if (_listenedPort && !await ServerReadiness.WaitPortReleasedAsync(profile, TimeSpan.FromSeconds(5)))
        {
            var message = $"The server process exited, but {profile.Host}:{profile.Port} is still occupied. Check Ports before restarting; another process may be listening.";
            Log.Append(message, LogStream.Stderr);
            profile.ProcessId = null;
            SetProfileState(profile, ServerState.Failed, message);
            return;
        }

        FinishStopped(profile);
    }

    public async Task RestartAsync(ServerProfile profile, AppSettings settings)
    {
        await StopAsync(profile);
        if (profile.State == ServerState.Stopped) await StartAsync(profile, settings);
    }

    public void OpenInBrowser(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Append($"Could not open browser: {ex.Message}", LogStream.Stderr);
        }
    }

    public void RefreshUptime(ServerProfile profile)
    {
        if (profile.State != ServerState.Running || profile.StartedAt is null)
        {
            profile.Uptime = "";
            return;
        }

        var elapsed = DateTimeOffset.Now - profile.StartedAt.Value;
        profile.Uptime = $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}";
    }

    private void Ingest(string? text, LogStream stream)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        if (!_dispatcher.HasThreadAccess) { _dispatcher.TryEnqueue(() => Ingest(text, stream)); return; }
        Log.Append(text, stream);
        if (stream == LogStream.Stderr)
        {
            _recentStderr.Add(text);
            if (_recentStderr.Count > 40)
            {
                _recentStderr.RemoveRange(0, _recentStderr.Count - 40);
            }
        }

        foreach (var url in ExtractUrls(text))
        {
            if (!DetectedUrls.Contains(url))
            {
                DetectedUrls.Add(url);
            }
        }
    }

    private void HandleExit(ServerProfile profile, Process process, int exitCode)
    {
        _dispatcher.TryEnqueue(async () =>
        {
            await _lifecycle.WaitAsync();
            try
            {
            if (!ReferenceEquals(_process, process)) return;
            var proxy = _httpsProxy;
            _httpsProxy = null;
            proxy?.Dispose();
            if (_intentionalStop)
            {
                return;
            }

            _ownedGroup?.Dispose();
            _ownedGroup = null;
            if (_elevated is { } elevated)
            {
                try { await elevated.StopAsync(); }
                catch (Exception ex) { Log.Append("Could not clean up the administrator helper: " + ex.Message, LogStream.Stderr); }
                _elevated = null;
            }

            var message = Explain($"The process exited with code {exitCode}.", profile);
            Log.Append(message, LogStream.Stderr);
            profile.ProcessId = null;
            profile.StartedAt = null;
            SetProfileState(profile, ServerState.Failed, message);
            Log.StopFileLogging();
            _process = null;
            process.Dispose();
            UnexpectedExit?.Invoke(profile, exitCode);
            }
            finally { _lifecycle.Release(); }
        });
    }

    private void Fail(ServerProfile profile, string message)
    {
        Log.Append(message, LogStream.Stderr);
        SetProfileState(profile, ServerState.Failed, message);
        Log.StopFileLogging();
    }

    private void FinishStopped(ServerProfile profile)
    {
        _process?.Dispose();
        _process = null;
        _ownedGroup?.Dispose();
        _ownedGroup = null;
        _listenedPort = false;
        profile.ProcessId = null;
        profile.StartedAt = null;
        profile.Uptime = "";
        DetectedUrls.Clear();
        SetProfileState(profile, ServerState.Stopped);
        Log.System("Server stopped.");
        Log.StopFileLogging();
    }

    private void SetProfileState(ServerProfile profile, ServerState state, string? failure = null)
    {
        profile.State = state;
        profile.Failure = failure;
    }

    private string Explain(string baseMessage, ServerProfile profile)
    {
        var stderr = string.Join(" ", _recentStderr).ToLowerInvariant();
        var hint = "";
        if (stderr.Contains("eacces") || stderr.Contains("permission denied"))
        {
            hint = profile.Port < 1024
                ? " Port requires administrator rights; use 1024 or above."
                : " Permission denied.";
        }
        else if (stderr.Contains("eaddrinuse") || stderr.Contains("address already in use"))
        {
            hint = " The port is already taken by another process.";
        }
        else if (stderr.Contains("cannot find module"))
        {
            hint = " Project dependencies are missing; run npm install.";
        }

        var bestLine = _recentStderr.LastOrDefault(line => !string.IsNullOrWhiteSpace(line));
        return string.IsNullOrWhiteSpace(bestLine) ? baseMessage + hint : $"{baseMessage} {bestLine}{hint}";
    }

    private static IEnumerable<string> ExtractUrls(string text)
    {
        foreach (Match match in UrlRegex().Matches(text))
        {
            yield return match.Value.TrimEnd('.', ',', ';');
        }
    }

    [GeneratedRegex(@"https?://[A-Za-z0-9\.\-\[\]:]+(?::\d+)?")]
    private static partial Regex UrlRegex();
}
