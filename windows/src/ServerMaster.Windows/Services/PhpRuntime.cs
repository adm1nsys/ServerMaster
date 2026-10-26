using System.IO.Compression;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class PhpRuntime
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(15) };
    private const string ReleaseBase = "https://downloads.php.net/~windows/releases/";
    public static string DirectoryFor(string branch)
    {
        if (!Dependency.PhpBranches.Contains(branch)) throw new InvalidOperationException("Choose a supported PHP version.");
        return AppPaths.RuntimeRoots.Select(root => Path.Combine(root, "php", branch))
            .FirstOrDefault(directory => File.Exists(Path.Combine(directory, "php.exe")))
            ?? Path.Combine(AppPaths.Runtime, "php", branch);
    }

    public static string? Find(string branch)
    {
        if (string.IsNullOrWhiteSpace(branch))
            return ShellEnvironment.Shared.Which("php") ?? Dependency.PhpBranches.Reverse().Select(Find).FirstOrDefault(path => path is not null);
        var executable = Path.Combine(DirectoryFor(branch), "php.exe");
        return File.Exists(executable) ? executable : null;
    }

    public static string Require(string branch)
    {
        var path = Find(branch) ?? throw new FileNotFoundException(
            $"PHP{(branch.Length > 0 ? " " + branch : "")} is not installed. Open Dependencies and install the PHP version selected in this profile.");
        ValidateFiles(Path.GetDirectoryName(path)!);
        return path;
    }

    public static void ValidateFiles(string directory)
    {
        var missing = new[] { "php.exe", "php8.dll" }.Where(file => !File.Exists(Path.Combine(directory, file))).ToList();
        if (missing.Count > 0) throw new InvalidDataException(
            $"PHP installation is incomplete: missing {string.Join(", ", missing)} in {directory}. Select Retry in Dependencies to download the complete PHP package. These are PHP files, not Visual C++ Runtime files.");
    }

    public static async Task InstallAsync(string branch, Action<string, double> progress)
    {
        var destination = DirectoryFor(branch);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(15));
        var token = timeout.Token;
        progress("Finding the latest PHP " + branch + " release...", 0);
        using var manifest = JsonDocument.Parse(await Client.GetStringAsync(ReleaseBase + "releases.json", token));
        if (!manifest.RootElement.TryGetProperty(branch, out var release))
            throw new InvalidOperationException($"PHP {branch} is not currently available from php.net.");
        var arch = Environment.Is64BitOperatingSystem ? "x64" : "x86";
        var build = release.EnumerateObject().FirstOrDefault(item => item.Name.StartsWith("nts-", StringComparison.Ordinal) && item.Name.EndsWith("-" + arch, StringComparison.Ordinal));
        if (build.Value.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("No PHP build is available for this Windows architecture.");
        var zip = build.Value.GetProperty("zip");
        var fileName = zip.GetProperty("path").GetString()!;
        if (Path.GetFileName(fileName) != fileName) throw new InvalidDataException("The PHP download manifest contains an invalid filename.");
        var expectedHash = zip.GetProperty("sha256").GetString()!;
        var staging = Path.Combine(AppPaths.Runtime, "php-staging-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        var archive = Path.Combine(staging, "php.zip");
        var unpacked = Path.Combine(staging, "unpacked");
        var preserveBackup = false;
        try
        {
            using (var response = await Client.GetAsync(ReleaseBase + fileName, HttpCompletionOption.ResponseHeadersRead, token))
            {
                response.EnsureSuccessStatusCode();
                var total = response.Content.Headers.ContentLength;
                await using var input = await response.Content.ReadAsStreamAsync(token);
                await using var output = File.Create(archive);
                var buffer = new byte[81920];
                long received = 0;
                int count;
                while ((count = await input.ReadAsync(buffer.AsMemory(), token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, count), token);
                    received += count;
                    var percent = total > 0 ? received * 100d / total.Value : 0;
                    progress($"Downloading PHP {branch}: {received / 1048576d:F1} MB" + (total > 0 ? $" / {total.Value / 1048576d:F1} MB" : ""), percent * .8);
                }
            }
            progress("Verifying SHA-256...", 82);
            await using (var stream = File.OpenRead(archive))
            {
                var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, token));
                if (!hash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("PHP download verification failed. Retry the download.");
            }
            progress("Extracting PHP...", 88);
            await Task.Run(() => ZipFile.ExtractToDirectory(archive, unpacked));
            ValidateFiles(unpacked);
            await File.WriteAllTextAsync(Path.Combine(unpacked, "php.ini"), Configuration(unpacked));
            progress("Checking PHP and CMS extensions...", 93);
            await VerifyAsync(unpacked, branch);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var backup = Path.Combine(staging, "previous");
            if (Directory.Exists(destination)) Directory.Move(destination, backup);
            try
            {
                Directory.Move(unpacked, destination);
                await File.WriteAllTextAsync(Path.Combine(destination, "php.ini"), Configuration(destination));
                progress("Checking installed PHP...", 97);
                await VerifyAsync(destination, branch);
            }
            catch (Exception replacementError)
            {
                try
                {
                    if (Directory.Exists(destination)) Directory.Move(destination, Path.Combine(staging, "failed"));
                    if (Directory.Exists(backup)) Directory.Move(backup, destination);
                }
                catch (Exception rollbackError)
                {
                    preserveBackup = true;
                    throw new IOException($"PHP installation failed. The previous copy is preserved at {backup}.",
                        new AggregateException(replacementError, rollbackError));
                }
                throw;
            }
        }
        finally
        {
            if (!preserveBackup && Directory.Exists(staging)) Directory.Delete(staging, true);
        }
    }

    private static string Configuration(string directory)
    {
        var ini = "extension_dir=\"" + Path.Combine(directory, "ext").Replace('\\', '/') + "\"\nmemory_limit=512M\nupload_max_filesize=128M\npost_max_size=128M\nmax_execution_time=300\ndate.timezone=UTC\n";
        foreach (var extension in new[] { "curl", "fileinfo", "gd", "intl", "mbstring", "mysqli", "openssl", "pdo_mysql", "zip" })
            if (File.Exists(Path.Combine(directory, "ext", "php_" + extension + ".dll"))) ini += "extension=" + extension + "\n";
        return ini;
    }

    private static async Task VerifyAsync(string directory, string branch)
    {
        var info = new ProcessStartInfo(Path.Combine(directory, "php.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(directory);
        info.ArgumentList.Add("-r");
        info.ArgumentList.Add("$missing = array_filter(['mysqli','pdo_mysql','gd','zip','intl','mbstring','curl','xml','json','openssl','fileinfo'], fn($ext) => !extension_loaded($ext)); if ($missing) { fwrite(STDERR, 'Missing PHP extensions: '.implode(', ', $missing)); exit(2); } echo PHP_VERSION;");
        using var process = Process.Start(info) ?? throw new IOException("Windows could not start the downloaded PHP runtime.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
        catch (TimeoutException) { process.Kill(true); throw new IOException("The downloaded PHP runtime did not respond within 20 seconds."); }
        var actual = (await output).Trim();
        if (process.ExitCode != 0 || !actual.StartsWith(branch + ".", StringComparison.Ordinal))
            throw new IOException($"PHP {branch} cannot run with its CMS extensions (code 0x{unchecked((uint)process.ExitCode):X8}). {((await error).Trim())}");
    }

    public static void Remove(string branch)
    {
        var directory = DirectoryFor(branch);
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }
}
