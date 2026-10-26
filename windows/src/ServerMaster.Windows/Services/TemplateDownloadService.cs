using System.IO.Compression;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class TemplateDownloadService
{
    private const string PreparationMarker = ".servermaster-template";
    private sealed record PreparationState(string TemplateId, int Port, string DatabaseName);
    private static readonly HttpClient Client = new()
    {
        Timeout = TimeSpan.FromMinutes(10)
    };

    public async Task DownloadAndExtractAsync(ProfileTemplate template, ServerProfile profile, ConsoleLog log)
    {
        if (!template.CanDownloadPackage)
        {
            throw new InvalidOperationException($"{template.Title} does not have a downloadable package.");
        }

        var targetRoot = profile.ExpandedRootPath;
        if (Directory.Exists(targetRoot) && Directory.EnumerateFileSystemEntries(targetRoot).Any())
        {
            var marker = Path.Combine(targetRoot, PreparationMarker);
            if (File.Exists(marker))
            {
                PreparationState? saved;
                try { saved = JsonSerializer.Deserialize<PreparationState>(await File.ReadAllTextAsync(marker)); }
                catch (JsonException) { throw new InvalidDataException("This project has an invalid ServerMaster setup marker. Its files were not changed; choose a new empty folder or restore the marker from a backup."); }
                if (saved is null || saved.TemplateId != template.Id)
                    throw new InvalidOperationException("This folder was prepared for another template. Choose its original template or a new empty folder.");
                if (saved.Port != profile.Port)
                    throw new InvalidOperationException($"This project was prepared for port {saved.Port}. Use that port to resume setup; its files were not changed.");
                profile.DatabaseName = saved.DatabaseName;
                log.System($"Resuming {template.Title} setup in {targetRoot}");
                await TemplateRecipeService.ApplyAsync(template, profile, log);
                log.System($"{template.Title} is ready in {targetRoot}");
                return;
            }
            throw new InvalidOperationException("Choose an empty folder for the download. If this is a partially prepared project, ServerMaster left the files in place; either create the profile with Download project files turned off, or choose a new empty folder and retry.");
        }

        var downloads = Path.Combine(AppPaths.Runtime, "downloads");
        Directory.CreateDirectory(downloads);
        var zipPath = Path.Combine(downloads, CacheFileName(template));
        var stagingRoot = Path.Combine(downloads, Guid.NewGuid().ToString("N"));

        try
        {
            if (!File.Exists(zipPath))
            {
                var url = await ResolvePackageUrlAsync(template);
                log.System($"Downloading {template.Title}");
                log.System(url);
                await DownloadAsync(url, zipPath);
            }
            else
            {
                log.System($"Using cached {template.Title} package: {zipPath}");
            }

            log.System($"Extracting to {targetRoot}");
            try
            {
                ZipFile.ExtractToDirectory(zipPath, stagingRoot, overwriteFiles: false);
            }
            catch (InvalidDataException) when (File.Exists(zipPath))
            {
                log.System("Cached package is not a valid ZIP. Downloading a fresh copy.");
                File.Delete(zipPath);
                var url = await ResolvePackageUrlAsync(template);
                await DownloadAsync(url, zipPath);
                ZipFile.ExtractToDirectory(zipPath, stagingRoot, overwriteFiles: false);
            }
            NormalizeSingleFolderExtract(stagingRoot, template.PackageKind);
            if (Directory.Exists(targetRoot) && Directory.EnumerateFileSystemEntries(targetRoot).Any())
                throw new InvalidOperationException("The destination folder changed during the download. ServerMaster did not remove any files; choose an empty folder and retry.");
            Directory.CreateDirectory(targetRoot);
            foreach (var path in Directory.EnumerateFileSystemEntries(stagingRoot))
            {
                var destination = Path.Combine(targetRoot, Path.GetFileName(path));
                if (Directory.Exists(path)) Directory.Move(path, destination);
                else File.Move(path, destination);
            }
            await File.WriteAllTextAsync(Path.Combine(targetRoot, PreparationMarker),
                JsonSerializer.Serialize(new PreparationState(template.Id, profile.Port, profile.DatabaseName)));
            await TemplateRecipeService.ApplyAsync(template, profile, log);
            log.System($"{template.Title} is ready in {targetRoot}");
        }
        finally
        {
            if (Directory.Exists(stagingRoot)) Directory.Delete(stagingRoot, recursive: true);
        }
    }

    private static async Task DownloadAsync(string url, string destination)
    {
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync();
                await using var output = File.Create(temporary);
                await input.CopyToAsync(output);
            }
            File.Move(temporary, destination, overwrite: true);
        }
        catch (HttpRequestException ex)
        {
            throw new InvalidOperationException("Could not download the template package. Check your internet connection, then retry. Existing project files were not removed. " + ex.Message, ex);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static string CacheFileName(ProfileTemplate template) => template.PackageKind switch
    {
        "printshopcrm" => "printshopcrm-main.zip",
        "wordpress" => "wordpress-latest.zip",
        "wordpress-w2p" => "wordpress-latest.zip",
        _ => template.Id + ".zip"
    };

    private static async Task<string> ResolvePackageUrlAsync(ProfileTemplate template)
    {
        return template.PackageKind switch
        {
            "wordpress" => "https://wordpress.org/latest.zip",
            "wordpress-w2p" => "https://wordpress.org/latest.zip",
            "printshopcrm" => "https://github.com/ColeLundstrom/printshopcrm/archive/refs/heads/main.zip",
            "joomla5" or "joomla6" => await ResolveJoomlaUrlAsync(template.PackageKind),
            _ => throw new InvalidOperationException($"No package resolver for {template.PackageKind}.")
        };
    }

    private static async Task<string> ResolveJoomlaUrlAsync(string packageKind)
    {
        var html = await Client.GetStringAsync("https://downloads.joomla.org/latest");
        var family = packageKind == "joomla5" ? "joomla5" : "joomla6";
        var match = JoomlaZipRegex(family).Match(html);
        if (match.Success)
        {
            var url = WebUtility.HtmlDecode(match.Groups["url"].Value);
            return url.StartsWith("http", StringComparison.OrdinalIgnoreCase)
                ? url
                : "https://downloads.joomla.org" + url;
        }

        throw new InvalidOperationException("Could not find the latest Joomla full package zip.");
    }

    private static void NormalizeSingleFolderExtract(string targetRoot, string packageKind)
    {
        if (packageKind == "printshopcrm")
        {
            NormalizeFirstDirectory(targetRoot);
            return;
        }

        if (packageKind != "wordpress" && packageKind != "wordpress-w2p")
        {
            return;
        }

        var wordpressFolder = Path.Combine(targetRoot, "wordpress");
        if (!Directory.Exists(wordpressFolder))
        {
            return;
        }

        foreach (var path in Directory.EnumerateFileSystemEntries(wordpressFolder))
        {
            var destination = Path.Combine(targetRoot, Path.GetFileName(path));
            if (Directory.Exists(path))
            {
                Directory.Move(path, destination);
            }
            else
            {
                File.Move(path, destination);
            }
        }

        Directory.Delete(wordpressFolder);
    }

    private static void NormalizeFirstDirectory(string targetRoot)
    {
        var entries = Directory.EnumerateFileSystemEntries(targetRoot).ToList();
        if (entries.Count != 1 || !Directory.Exists(entries[0]))
        {
            return;
        }

        var folder = entries[0];
        foreach (var path in Directory.EnumerateFileSystemEntries(folder))
        {
            var destination = Path.Combine(targetRoot, Path.GetFileName(path));
            if (Directory.Exists(path)) Directory.Move(path, destination);
            else File.Move(path, destination);
        }

        Directory.Delete(folder);
    }

    private static Regex JoomlaZipRegex(string family)
    {
        var pattern = $@"href\s*=\s*[""'](?<url>(?:https://downloads\.joomla\.org)?/cms/{Regex.Escape(family)}/[^""']+Full_Package\.zip\?format=zip)[""']";
        return new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }
}
