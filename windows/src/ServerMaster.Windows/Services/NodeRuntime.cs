using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ServerMaster.Windows.Services;

public static class NodeRuntime
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(10) };
    private static string Root => Path.Combine(AppPaths.Runtime, "node");
    private static string Selection => Path.Combine(Root, "active.txt");
    private static string Architecture => Environment.Is64BitProcess ? "x64" : "x86";
    public static bool ValidVersion(string version) => Regex.IsMatch(version, @"^v[0-9]+\.[0-9]+\.[0-9]+$");
    public static string? ActiveDirectory
    {
        get
        {
            if (!File.Exists(Selection)) return null;
            var version = File.ReadAllText(Selection).Trim();
            if (!ValidVersion(version)) return null;
            var path = Path.Combine(Root, version);
            return File.Exists(Path.Combine(path, "node.exe")) ? path : null;
        }
    }

    public static async Task<IReadOnlyList<string>> VersionsAsync()
    {
        using var manifest = JsonDocument.Parse(await Client.GetStringAsync("https://nodejs.org/dist/index.json"));
        return manifest.RootElement.EnumerateArray()
            .Where(release => release.GetProperty("files").EnumerateArray().Any(file => file.GetString() == $"win-{Architecture}-zip"))
            .Select(release => release.GetProperty("version").GetString()!).Where(ValidVersion).ToArray();
    }

    public static void RemoveActive()
    {
        var directory = ActiveDirectory;
        if (directory is null) return;
        for (var attempt = 0; ; attempt++)
        {
            try { Directory.Delete(directory, true); break; }
            catch (IOException) when (attempt < 5) { Thread.Sleep(300); }
            catch (UnauthorizedAccessException) when (attempt < 5) { Thread.Sleep(300); }
        }
        if (File.Exists(Selection)) File.Delete(Selection);
    }

    public static async Task SelectAsync(string version, Action<string> progress)
    {
        Directory.CreateDirectory(Root);
        if (version == "System") { if (File.Exists(Selection)) File.Delete(Selection); return; }
        if (!ValidVersion(version)) throw new InvalidOperationException("Choose a Node.js release from the list.");
        var target = Path.Combine(Root, version);
        var needsDownload = !File.Exists(Path.Combine(target, "node.exe"));
        if (!needsDownload)
        {
            try { await VerifyAsync(Path.Combine(target, "node.exe"), version); }
            catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or TimeoutException or UnauthorizedAccessException)
            {
                needsDownload = true;
                progress("The saved Node.js copy cannot run. Downloading a clean copy...");
            }
        }
        if (needsDownload)
        {
            var staging = Path.Combine(Root, ".download-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(staging);
            var preserveBackup = false;
            try
            {
                var name = $"node-{version}-win-{Architecture}";
                var filename = name + ".zip";
                var baseUrl = $"https://nodejs.org/dist/{version}/";
                progress("Reading official SHA-256 checksum...");
                var sums = await Client.GetStringAsync(baseUrl + "SHASUMS256.txt");
                var hash = sums.Split('\n').Select(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
                    .FirstOrDefault(parts => parts.Length == 2 && parts[1] == filename)?[0]
                    ?? throw new IOException("No checksum is available for this Windows release.");
                var zip = Path.Combine(staging, filename);
                using (var response = await Client.GetAsync(baseUrl + filename, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();
                    await using var input = await response.Content.ReadAsStreamAsync();
                    await using var output = File.Create(zip);
                    var buffer = new byte[81920]; long received = 0; int count;
                    while ((count = await input.ReadAsync(buffer)) != 0)
                    {
                        await output.WriteAsync(buffer.AsMemory(0, count)); received += count;
                        progress($"Downloading Node.js {version}: {received / 1048576d:F1} MB");
                    }
                }
                await using (var input = File.OpenRead(zip))
                    if (!Convert.ToHexString(await SHA256.HashDataAsync(input)).Equals(hash, StringComparison.OrdinalIgnoreCase)) throw new IOException("Node.js checksum mismatch. The active version was not changed.");
                progress("Extracting Node.js and npm...");
                await Task.Run(() => ZipFile.ExtractToDirectory(zip, staging));
                await VerifyAsync(Path.Combine(staging, name, "node.exe"), version);
                var backup = Path.Combine(staging, "previous");
                if (Directory.Exists(target)) Directory.Move(target, backup);
                try
                {
                    Directory.Move(Path.Combine(staging, name), target);
                    await VerifyAsync(Path.Combine(target, "node.exe"), version);
                }
                catch (Exception replacementError)
                {
                    try
                    {
                        if (Directory.Exists(target)) Directory.Move(target, Path.Combine(staging, "failed"));
                        if (Directory.Exists(backup)) Directory.Move(backup, target);
                    }
                    catch (Exception rollbackError)
                    {
                        preserveBackup = true;
                        throw new IOException($"Node.js replacement failed. The previous copy is preserved at {backup}.",
                            new AggregateException(replacementError, rollbackError));
                    }
                    throw;
                }
            }
            finally { if (!preserveBackup && Directory.Exists(staging)) Directory.Delete(staging, true); }
        }
        await VerifyAsync(Path.Combine(target, "node.exe"), version);
        var temporary = Selection + ".tmp";
        await File.WriteAllTextAsync(temporary, version);
        File.Move(temporary, Selection, true);
        progress("Active Node.js: " + version);
    }

    private static async Task VerifyAsync(string executable, string version)
    {
        using var process = Process.Start(new ProcessStartInfo(executable, "--version") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })!;
        OwnedProcesses.Track(process);
        var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            if (process.ExitCode != 0 || (await stdout).Trim() != version) throw new IOException("Node.js could not run: " + await stderr);
        }
        finally { if (!process.HasExited) process.Kill(true); }
    }
}
