using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32;

namespace ServerMaster.Windows.Services;

public static class VcRuntime
{
    public static string Architecture => Environment.Is64BitOperatingSystem ? "x64" : "x86";
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(10) };
    private static Package? _cached;
    public sealed record Package(string Path, Version Version, DateTimeOffset FetchedAt);

    public static Version? InstalledVersion()
    {
        var found = new List<Version>();
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
            using var key = machine.OpenSubKey(@"SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\" + Architecture);
            if (key?.GetValue("Installed") is int installed && installed == 1 &&
                Version.TryParse((key.GetValue("Version") as string)?.TrimStart('v', 'V'), out var version)) found.Add(version);
        }
        return found.OrderDescending().FirstOrDefault();
    }

    public static async Task<Package> FetchAsync(Action<string, double> progress, bool refresh = false)
    {
        if (!refresh && _cached is { } cached && File.Exists(cached.Path) && DateTimeOffset.UtcNow - cached.FetchedAt < TimeSpan.FromHours(1)) return cached;
        var folder = Path.Combine(AppPaths.Runtime, "installers");
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, $"vc_redist.{Architecture}.exe");
        var partial = target + "." + Guid.NewGuid().ToString("N") + ".download.exe";
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        try
        {
            using var response = await Client.GetAsync($"https://aka.ms/vc14/vc_redist.{Architecture}.exe", HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength;
            await using (var input = await response.Content.ReadAsStreamAsync(deadline.Token))
            await using (var output = File.Create(partial))
            {
                var buffer = new byte[81920];
                long received = 0;
                int count;
                while ((count = await input.ReadAsync(buffer.AsMemory(), deadline.Token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, count), deadline.Token);
                    received += count;
                    progress($"Downloading Visual C++ Runtime ({Architecture}): {received / 1048576d:F1} MB", total > 0 ? received * 85d / total.Value : 0);
                }
            }
            progress("Verifying Microsoft's digital signature...", 90);
            await VerifyAsync(partial);
            var info = FileVersionInfo.GetVersionInfo(partial);
            var version = new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
            if (version.Major != 14) throw new InvalidDataException("The downloaded installer is not Visual C++ v14 Runtime.");
            File.Move(partial, target, true);
            _cached = new Package(target, version, DateTimeOffset.UtcNow);
            return _cached;
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
    }

    private static async Task VerifyAsync(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("The downloaded Visual C++ installer is missing. Retry the download and check Windows Security protection history.", path);
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-Command",
            @"$ErrorActionPreference = 'Stop'; [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); if (!(Test-Path -LiteralPath $env:SERVERMASTER_INSTALLER -PathType Leaf)) { exit 2 }; Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'); $s = Get-AuthenticodeSignature -LiteralPath $env:SERVERMASTER_INSTALLER; if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { Write-Output $s.Status; Write-Output $s.StatusMessage; Write-Output $s.SignerCertificate.Subject; exit 1 }" }) info.ArgumentList.Add(arg);
        info.Environment["SERVERMASTER_INSTALLER"] = path;
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not verify the Microsoft installer.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60)); }
        catch (TimeoutException) { process.Kill(true); throw new InvalidOperationException("Microsoft signature verification timed out. Check your connection and retry."); }
        await Task.WhenAll(stdout, stderr);
        if (process.ExitCode == 2) throw new InvalidDataException("Windows could not access the downloaded Visual C++ installer. Retry the download. If this repeats, check Windows Security protection history. Installer path: " + path);
        if (process.ExitCode != 0) throw new InvalidDataException("Could not verify Microsoft's installer signature. Installation was stopped. Retry the download. " + (await stdout).Trim(),
            new InvalidOperationException((await stderr).Trim()));
    }

    public static async Task<bool> InstallAsync(Package package, Action<string, double> progress, bool repair = false)
    {
        await VerifyAsync(package.Path);
        var current = InstalledVersion();
        if (current > package.Version || (current == package.Version && !repair)) return false;
        var action = current == package.Version ? "/repair" : "/install";
        var logPath = Path.Combine(AppPaths.Runtime, "vc-runtime-install.log");
        progress($"Installing Visual C++ {package.Version} ({Architecture}). Confirm the Windows permission prompt if it appears.", 95);
        try
        {
            using var process = Process.Start(new ProcessStartInfo(package.Path)
            {
                Arguments = $"{action} /quiet /norestart /log \"{logPath}\"",
                UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden
            }) ?? throw new InvalidOperationException("Could not start the Visual C++ installer.");
            await process.WaitForExitAsync();
            if (process.ExitCode is not (0 or 3010 or 1638))
                throw new InvalidOperationException($"Visual C++ installation failed (code {process.ExitCode}). Details: {logPath}");
            if (InstalledVersion() is not { } installed || installed < package.Version)
                throw new InvalidOperationException("Visual C++ installation could not be confirmed. Restart Windows, then check dependencies again.");
            return process.ExitCode == 3010;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            throw new InvalidOperationException("Visual C++ installation was cancelled in the Windows permission prompt. Select Install to try again.");
        }
    }
}
