using System.Net;
using System.Reflection;
using System.Text.RegularExpressions;

namespace ServerMaster.Windows.Services;

public enum UpdateCheckKind { NotConfigured, UpToDate, Available, Failed }

public sealed record UpdateCheckResult(UpdateCheckKind Kind, string Message, string Version = "", string ReleaseUrl = "");

public sealed class UpdateChecker(HttpClient? client = null)
{
    private readonly HttpClient _client = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
    public string RawBaseUrl { get; set; } = "https://raw.githubusercontent.com";
    public string SiteBaseUrl { get; set; } = "https://github.com";
    public IReadOnlyList<string> Branches { get; set; } = ["main", "master"];

    public static string CurrentVersion
    {
        get
        {
            var version = Assembly.GetEntryAssembly()?.GetName().Version;
            return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{Math.Max(0, version.Build)}";
        }
    }

    public static string NormalizeRepository(string value)
    {
        value = (value ?? "").Trim();
        foreach (var prefix in new[] { "https://github.com/", "http://github.com/", "github.com/", "git@github.com:" })
            if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) value = value[prefix.Length..];
        if (value.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) value = value[..^4];
        value = value.Trim('/');
        return Regex.IsMatch(value, @"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") ? value : "";
    }

    public static string? ParseVersion(string raw)
    {
        var line = (raw ?? "").Replace("\uFEFF", "").Split('\n')
            .Select(item => item.Trim()).FirstOrDefault(item => item.Length > 0 && !item.StartsWith('#'));
        if (line is null) return null;
        var match = Regex.Match(line, @"\d+(?:\.\d+)*");
        return match.Success ? match.Value : null;
    }

    public static bool IsNewer(string candidate, string current)
    {
        var left = Components(candidate);
        var right = Components(current);
        if (left is null || right is null) return false;
        for (var index = 0; index < Math.Max(left.Length, right.Length); index++)
        {
            var l = index < left.Length ? left[index] : 0;
            var r = index < right.Length ? right[index] : 0;
            if (l != r) return l > r;
        }
        return false;
    }

    public string VersionFileUrl(string repository, string versionFile, string branch = "main")
    {
        var repo = NormalizeRepository(repository);
        var path = NormalizePath(versionFile);
        var encodedPath = string.Join('/', path.Split('/').Select(Uri.EscapeDataString));
        return repo.Length == 0 || path.Length == 0 ? "" : $"{RawBaseUrl.TrimEnd('/')}/{repo}/{Uri.EscapeDataString(branch)}/{encodedPath}";
    }

    public async Task<UpdateCheckResult> CheckAsync(string repository, string versionFile, string buildsFolder,
        string currentVersion, CancellationToken cancellationToken = default)
    {
        var repo = NormalizeRepository(repository);
        var path = NormalizePath(versionFile);
        if (repo.Length == 0 || path.Length == 0)
            return new(UpdateCheckKind.NotConfigured, "Enter a GitHub repository and a valid version-file path.");

        string lastError = "Could not check for updates.";
        foreach (var branch in Branches)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, VersionFileUrl(repo, path, branch));
                request.Headers.UserAgent.ParseAdd("ServerMaster/" + currentVersion);
                request.Headers.CacheControl = new() { NoCache = true };
                using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellationToken);
                if (response.StatusCode == HttpStatusCode.NotFound)
                {
                    lastError = $"File {path} was not found in branch {branch}.";
                    continue;
                }
                if (!response.IsSuccessStatusCode)
                {
                    lastError = $"GitHub responded with code {(int)response.StatusCode}.";
                    continue;
                }
                var latest = ParseVersion(await response.Content.ReadAsStringAsync(cancellationToken));
                if (latest is null)
                {
                    lastError = $"There is no version number in {path}.";
                    continue;
                }
                if (!IsNewer(latest, currentVersion))
                    return new(UpdateCheckKind.UpToDate, $"ServerMaster {currentVersion} is up to date.", latest);

                var release = $"{SiteBaseUrl.TrimEnd('/')}/{repo}/releases/tag/windows-v{latest}";
                var folder = NormalizePath(buildsFolder);
                var where = folder.Length == 0 ? "the release page" : $"{folder}/{latest} or the release page";
                return new(UpdateCheckKind.Available, $"ServerMaster {latest} is available. The Windows build is expected in {where}.", latest, release);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                lastError = "The update check timed out.";
            }
            catch (HttpRequestException ex) { lastError = ex.Message; }
        }
        return new(UpdateCheckKind.Failed, lastError);
    }

    private static string NormalizePath(string value)
    {
        var path = (value ?? "").Trim().Replace('\\', '/').Trim('/');
        if (path.Length == 0 || path.Split('/').Any(part => part is "" or "." or "..")) return "";
        return path;
    }

    private static long[]? Components(string value)
    {
        var parsed = ParseVersion(value);
        if (parsed is null) return null;
        var result = new List<long>();
        foreach (var part in parsed.Split('.'))
        {
            if (!long.TryParse(part, out var number)) return null;
            result.Add(number);
        }
        return result.ToArray();
    }
}
