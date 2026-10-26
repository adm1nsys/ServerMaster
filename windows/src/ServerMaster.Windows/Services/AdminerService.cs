using System.Net.Http;
using System.Diagnostics;

namespace ServerMaster.Windows.Services;

public static class AdminerService
{
    private static readonly Uri DownloadUri = new("https://www.adminer.org/latest.php");
    private static Process? _process;
    private static readonly SemaphoreSlim Startup = new(1, 1);
    private static int _generation;
    private static readonly System.Collections.Concurrent.ConcurrentQueue<string> Errors = new();
    public static int Port { get; private set; } = 8036;
    public static string Tool { get; private set; } = "adminer";
    public static string ToolTitle => Tool == "phpmyadmin" ? "phpMyAdmin" : "Adminer";
    public static string Address => Tool == "phpmyadmin" ? $"http://127.0.0.1:{Port}/" : $"http://127.0.0.1:{Port}/adminer.php";
    public static string LoginAddress { get; private set; } = Address;
    public static bool IsRunning => _process is { HasExited: false };

    public static string DirectoryPath => NativeDirectory.Resolve(Path.Combine(AppPaths.LocalSupport, "Adminer"));

    public static string FilePath => Path.Combine(DirectoryPath, "adminer.php");

    public static bool IsInstalled => File.Exists(FilePath) && new FileInfo(FilePath).Length > 100_000;
    public static bool IsToolInstalled(string tool) => tool == "phpmyadmin" ? PhpMyAdminRuntime.IsInstalled : IsInstalled;

    public static void SetTool(string tool)
    {
        tool = tool == "phpmyadmin" ? tool : "adminer";
        if (Tool == tool) return;
        Stop();
        Tool = tool;
        LoginAddress = Address;
    }

    public static void SetPort(int port)
    {
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        if (IsRunning && Port != port) Stop();
        Port = port;
    }

    public static string Version => IsInstalled
        ? "Adminer " + (File.ReadLines(FilePath).Take(10).FirstOrDefault(line => line.Contains("@version "))?.Split("@version ")[1].Trim() ?? "(version unknown)")
        : "";
    public static string ToolVersion(string tool) => tool == "phpmyadmin"
        ? (PhpMyAdminRuntime.IsInstalled ? "phpMyAdmin " + PhpMyAdminRuntime.Version : "")
        : Version;

    public static async Task InstallAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(DirectoryPath);
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        using var response = await client.GetAsync(DownloadUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength;
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
        var temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".download";
        try
        {
            await using (var target = File.Create(temporary))
            {
                var buffer = new byte[128 * 1024];
                long read = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                    read += count;
                    if (total is > 0) progress?.Report(read * 100d / total.Value);
                }
            }
            var text = await File.ReadAllTextAsync(temporary, cancellationToken);
            if (new FileInfo(temporary).Length < 100_000 || !text.TrimStart().StartsWith("<?php", StringComparison.Ordinal))
                throw new IOException("The downloaded file is not a complete Adminer PHP package. The existing installation was kept.");
            File.Move(temporary, FilePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static void Remove()
    {
        Stop();
        if (File.Exists(FilePath)) File.Delete(FilePath);
    }

    public static async Task StartAsync()
    {
        var generation = _generation;
        await Startup.WaitAsync();
        try { if (generation != _generation) throw new OperationCanceledException("Adminer startup was cancelled."); await StartCoreAsync(); }
        finally { Startup.Release(); }
    }

    private static async Task StartCoreAsync()
    {
        if (IsRunning) return;
        var generation = _generation;
        if (!IsToolInstalled(Tool)) throw new InvalidOperationException($"{ToolTitle} is not installed. Install it from Dependencies first.");
        var php = Tool == "phpmyadmin"
            ? PhpRuntime.Find("8.3") ?? PhpRuntime.Find("8.2")
            : PhpRuntime.Find("") ?? ShellEnvironment.Shared.Which("php");
        if (php is null) throw new FileNotFoundException(Tool == "phpmyadmin"
            ? "phpMyAdmin needs managed PHP 8.2 or 8.3. Install PHP 8.3 from Dependencies first."
            : "Adminer needs PHP. Install a PHP version from Dependencies first.");
        PhpRuntime.ValidateFiles(Path.GetDirectoryName(php)!);
        await ServerReadiness.CheckPortAsync(new Models.ServerProfile { Host = "127.0.0.1", Port = Port }, CancellationToken.None);
        if (generation != _generation) throw new OperationCanceledException("Adminer startup was cancelled.");
        var info = new ProcessStartInfo(php)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Tool == "phpmyadmin" ? PhpMyAdminRuntime.DirectoryPath : DirectoryPath
        };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(Path.GetDirectoryName(php)!);
        info.ArgumentList.Add("-S");
        info.ArgumentList.Add($"127.0.0.1:{Port}");
        info.ArgumentList.Add("-t");
        info.ArgumentList.Add(Tool == "phpmyadmin" ? PhpMyAdminRuntime.DirectoryPath : DirectoryPath);
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor()) info.Environment[pair.Key] = pair.Value;
        LoginAddress = Address;
        if (DatabaseService.Detect().Running)
        {
            var password = await DatabaseService.PreparePanelAccountAsync();
            var key = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
            info.Environment["SERVERMASTER_PANEL_PASSWORD"] = password;
            info.Environment["SERVERMASTER_PANEL_KEY"] = key;
            if (Tool == "phpmyadmin")
            {
                info.Environment["SERVERMASTER_PANEL_BLOWFISH"] = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
                await File.WriteAllTextAsync(Path.Combine(PhpMyAdminRuntime.DirectoryPath, "config.inc.php"), PhpMyAdminConfig);
            }
            else
            {
                await File.WriteAllTextAsync(Path.Combine(DirectoryPath, "login.php"), LoginPage);
                LoginAddress = $"http://127.0.0.1:{Port}/login.php?key={key}";
            }
        }
        _process?.Dispose();
        if (generation != _generation) throw new OperationCanceledException("Adminer startup was cancelled.");
        Errors.Clear();
        var process = new Process { StartInfo = info };
        _process = process;
        process.OutputDataReceived += (_, _) => { };
        process.ErrorDataReceived += (sender, e) => { if (e.Data is not null) { Errors.Enqueue(e.Data); while (Errors.Count > 20) Errors.TryDequeue(out _); } };
        try
        {
            process.Start(); OwnedProcesses.Track(process); process.BeginOutputReadLine(); process.BeginErrorReadLine();
            using var client = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(1) };
            for (var attempt = 0; attempt < 30; attempt++)
            {
                await Task.Delay(100);
                if (generation != _generation) throw new OperationCanceledException("Adminer startup was cancelled.");
                if (process.HasExited) throw new IOException("PHP stopped before Adminer became ready. " + string.Join(Environment.NewLine, Errors));
                try
                {
                    using var response = await client.GetAsync(Address, HttpCompletionOption.ResponseHeadersRead);
                    if ((int)response.StatusCode < 400 && !process.HasExited) return;
                    if ((int)response.StatusCode >= 500) throw new IOException("Adminer returned an error. " + string.Join(Environment.NewLine, Errors));
                }
                catch (HttpRequestException) { }
                catch (TaskCanceledException) { }
            }
            throw new IOException($"{ToolTitle} did not answer on port {Port}. " + string.Join(Environment.NewLine, Errors));
        }
        catch { Stop(); throw; }
    }

    public static void Stop()
    {
        _generation++;
        var process = _process;
        _process = null;
        LoginAddress = Address;
        if (process is null) return;
        try { if (!process.HasExited) { process.Kill(entireProcessTree: true); process.WaitForExit(3000); } }
        catch (InvalidOperationException) { }
        finally { process.Dispose(); }
    }

    private const string LoginPage = """
        <?php
        header('Cache-Control: no-store');
        header('Referrer-Policy: no-referrer');
        header('X-Frame-Options: DENY');
        $key = getenv('SERVERMASTER_PANEL_KEY');
        if (!$key || !hash_equals($key, $_GET['key'] ?? '')) { http_response_code(403); exit('Open the panel from ServerMaster.'); }
        $password = getenv('SERVERMASTER_PANEL_PASSWORD');
        ?>
        <!doctype html><html lang="en"><meta charset="utf-8"><title>Adminer</title>
        <body><p id="status">Signing in to Adminer...</p>
        <details><summary>Manual login</summary><p>Server: 127.0.0.1:3307</p><p>User: servermaster_panel</p>
        <p>Password: <code><?= htmlspecialchars($password, ENT_QUOTES, 'UTF-8') ?></code></p><a href="adminer.php">Open login page</a></details>
        <form id="login" method="post" action="adminer.php" hidden>
        <input name="auth[driver]" value="server"><input name="auth[server]" value="127.0.0.1:3307">
        <input name="auth[username]" value="servermaster_panel"><input name="auth[password]" value="<?= htmlspecialchars($password, ENT_QUOTES, 'UTF-8') ?>">
        <input name="token" value=""></form>
        <script>
        fetch('adminer.php', {credentials:'same-origin'}).then(r => {if(!r.ok) throw new Error(); return r.text();}).then(html => {
            const page = new DOMParser().parseFromString(html, 'text/html');
            const token = page.querySelector('input[name="token"]');
            if (!token) throw new Error();
            const form = document.getElementById('login'); form.elements.token.value = token.value; form.submit();
        }).catch(() => {document.getElementById('status').textContent = 'Automatic login failed. Use Manual login below.'; document.querySelector('details').open = true;});
        </script></body></html>
        """;

    private const string PhpMyAdminConfig = """
        <?php
        // Generated by ServerMaster. Credentials stay in this process environment.
        $cfg['blowfish_secret'] = getenv('SERVERMASTER_PANEL_BLOWFISH');
        $i = 1;
        $cfg['Servers'][$i]['auth_type'] = 'config';
        $cfg['Servers'][$i]['host'] = '127.0.0.1';
        $cfg['Servers'][$i]['port'] = '3307';
        $cfg['Servers'][$i]['user'] = 'servermaster_panel';
        $cfg['Servers'][$i]['password'] = getenv('SERVERMASTER_PANEL_PASSWORD');
        $cfg['Servers'][$i]['AllowNoPassword'] = false;
        $cfg['Servers'][$i]['compress'] = false;
        $cfg['TempDir'] = sys_get_temp_dir();
        """;
}
