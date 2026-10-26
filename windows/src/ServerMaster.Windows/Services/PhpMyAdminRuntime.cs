using System.IO.Compression;
using System.Security.Cryptography;

namespace ServerMaster.Windows.Services;

public static class PhpMyAdminRuntime
{
    public const string Version = "5.2.3";
    public const string ExpectedSha256 = "2D2E13C735366D318425C78E4EE2CC8FC648D77FABA3DDEA2CD516E43885733F";
    private static readonly Uri DownloadUri = new($"https://files.phpmyadmin.net/phpMyAdmin/{Version}/phpMyAdmin-{Version}-all-languages.zip");
    internal static string? DirectoryOverride { get; set; }

    public static string DirectoryPath => NativeDirectory.Resolve(DirectoryOverride ?? Path.Combine(AppPaths.LocalSupport, "phpMyAdmin"));
    public static string IndexPath => Path.Combine(DirectoryPath, "index.php");
    public static bool IsInstalled => Validate(DirectoryPath);

    public static async Task InstallAsync(IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        var parent = Path.GetDirectoryName(DirectoryPath)!;
        Directory.CreateDirectory(parent);
        var archivePath = Path.Combine(parent, $"phpmyadmin-{Guid.NewGuid():N}.download");
        var staging = Path.Combine(parent, $"phpmyadmin-{Guid.NewGuid():N}.staging");
        var backup = Path.Combine(parent, $"phpmyadmin-{Guid.NewGuid():N}.previous");
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            using var response = await client.GetAsync(DownloadUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength;
            await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken))
            await using (var target = new FileStream(archivePath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true))
            {
                var buffer = new byte[128 * 1024];
                long read = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                    read += count;
                    if (total is > 0) progress?.Report(read * 70d / total.Value);
                }
            }

            await using var hashSource = File.OpenRead(archivePath);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(hashSource, cancellationToken));
            if (!hash.Equals(ExpectedSha256, StringComparison.OrdinalIgnoreCase))
                throw new IOException("The phpMyAdmin download failed its SHA-256 verification. The existing installation was kept.");

            await ExtractVerifiedAsync(archivePath, staging, progress, cancellationToken);
            Replace(staging, backup);
            progress?.Report(100);
        }
        finally
        {
            TryDeleteFile(archivePath);
            TryDeleteDirectory(staging);
            TryDeleteDirectory(backup);
        }
    }

    internal static async Task ExtractVerifiedAsync(string archivePath, string destination,
        IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(destination);
        using var archive = ZipFile.OpenRead(archivePath);
        var entries = archive.Entries.Where(entry => entry.FullName.Length > 0).ToArray();
        var rootName = entries.Select(entry => entry.FullName.Replace('\\', '/').Split('/')[0]).FirstOrDefault()
            ?? throw new IOException("The phpMyAdmin archive is empty.");
        var destinationRoot = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
        for (var index = 0; index < entries.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var name = entries[index].FullName.Replace('\\', '/');
            var prefix = rootName + "/";
            if (!name.StartsWith(prefix, StringComparison.Ordinal) || name.Contains('\0'))
                throw new IOException("The phpMyAdmin archive has an unexpected directory layout.");
            var relative = name[prefix.Length..];
            if (relative.Length == 0) continue;
            var target = Path.GetFullPath(Path.Combine(destination, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!target.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase))
                throw new IOException("The phpMyAdmin archive contains an unsafe path.");
            if (name.EndsWith('/')) Directory.CreateDirectory(target);
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                await using var source = entries[index].Open();
                await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, true);
                await source.CopyToAsync(output, cancellationToken);
            }
            progress?.Report(70 + (index + 1) * 25d / Math.Max(1, entries.Length));
        }
        if (!Validate(destination)) throw new IOException("The phpMyAdmin archive is incomplete. The existing installation was kept.");
    }

    public static void Remove()
    {
        AdminerService.Stop();
        if (Directory.Exists(DirectoryPath)) Directory.Delete(DirectoryPath, true);
    }

    private static bool Validate(string directory) =>
        File.Exists(Path.Combine(directory, "index.php")) &&
        File.Exists(Path.Combine(directory, "libraries", "common.inc.php")) &&
        File.Exists(Path.Combine(directory, "vendor", "autoload.php"));

    private static void Replace(string staging, string backup)
    {
        var hadExisting = Directory.Exists(DirectoryPath);
        try
        {
            if (hadExisting) Directory.Move(DirectoryPath, backup);
            Directory.Move(staging, DirectoryPath);
            if (!Validate(DirectoryPath)) throw new IOException("phpMyAdmin verification failed after activation.");
        }
        catch
        {
            TryDeleteDirectory(DirectoryPath);
            if (hadExisting && Directory.Exists(backup)) Directory.Move(backup, DirectoryPath);
            throw;
        }
    }

    private static void TryDeleteFile(string path) { try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    private static void TryDeleteDirectory(string path) { try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
}
