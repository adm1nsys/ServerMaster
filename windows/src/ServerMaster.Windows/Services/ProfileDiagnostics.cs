using System.Net;
using System.Net.Sockets;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public enum DiagnosticLevel { Fine, Note, Warning, Broken }

public sealed record DiagnosticFinding(string Group, string Title, string Detail, string Remedy = "", bool Problem = false, DiagnosticLevel? Severity = null)
{
    public DiagnosticLevel Level => Severity ?? (Problem ? DiagnosticLevel.Broken : DiagnosticLevel.Fine);
    public bool NeedsAttention => Level >= DiagnosticLevel.Warning;
    public string Status => Level switch { DiagnosticLevel.Broken => "Broken", DiagnosticLevel.Warning => "Worth a look", DiagnosticLevel.Note => "Information", _ => "OK" };
    public string Glyph => Level switch { DiagnosticLevel.Broken => "\uEA39", DiagnosticLevel.Warning => "\uE7BA", DiagnosticLevel.Note => "\uE946", _ => "\uE73E" };
    public string Tint => Level switch { DiagnosticLevel.Broken => "#E66A72", DiagnosticLevel.Warning => "#E7BD57", DiagnosticLevel.Note => "#A6AAB4", _ => "#32B875" };
}

public static class ProfileDiagnostics
{
    public static async Task<IReadOnlyList<DiagnosticFinding>> CheckAsync(ServerProfile profile)
    {
        var findings = new List<DiagnosticFinding>();
        void Add(string title, string detail, string remedy = "", bool problem = false) =>
            findings.Add(new(profile.Name, title, detail, remedy, problem));

        try
        {
            var folder = profile.EffectiveWorkingDirectory;
            if (profile.UsesRootDirectory) CheckFolder(profile.ExpandedRootPath, "Site folder");
            if (!profile.UsesRootDirectory || folder != profile.ExpandedRootPath) CheckFolder(folder, "Working folder");
            void CheckFolder(string path, string title)
            {
                try
                {
                    if (!Directory.Exists(path)) throw new DirectoryNotFoundException("Folder does not exist: " + path);
                    using var entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
                    entries.MoveNext();
                    Add(title, path);
                }
                catch (Exception ex) { Add(title, ex.Message, "Choose an existing, readable folder in Profiles.", true); }
            }

            var root = Path.GetPathRoot(Path.GetFullPath(folder));
            if (root is not null)
            {
                var disk = new DriveInfo(root);
                if (disk.IsReady)
                {
                    var low = disk.AvailableFreeSpace < 1024L * 1024 * 1024;
                    Add("Disk space", $"{disk.AvailableFreeSpace / 1073741824d:F1} GB available on {root}", low ? "Free disk space before downloading software or site files." : "", low);
                }
            }
        }
        catch (Exception ex) { Add("Folder settings", ex.Message, "Check the folder paths in Profiles.", true); }

        try
        {
            var plan = LaunchPlanBuilder.Build(profile);
            Add("Launch configuration", Path.GetFileName(plan.Executable));
        }
        catch (Exception ex) { Add("Launch configuration", ex.Message, "Check this profile's engine and install its required software in Dependencies.", true); }

        if (profile.TemplateId is "printshopcrm" or "web-to-print-store")
        {
            findings.AddRange(await TemplateRecipeService.HealthCheckAsync(profile));
        }

        if (profile.Port is < 1 or > 65535)
        {
            Add("Port", $"Invalid port: {profile.Port}", "Choose a port between 1 and 65535 in Profiles.", true);
            return findings;
        }
        if (profile.IsBusy)
        {
            findings.Add(new(profile.Name, "Server state", profile.StateText, "Run diagnostics again after the operation finishes.", Severity: DiagnosticLevel.Note));
            return findings;
        }
        if (!profile.IsRunning)
        {
            var host = string.IsNullOrWhiteSpace(profile.Host) ? "127.0.0.1" : profile.Host;
            if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase)) host = "127.0.0.1";
            if (!IPAddress.TryParse(host.Trim('[', ']'), out var address))
                Add("Listen address", host, "Use a local IP address or localhost so the port can be checked.", true);
            else
            {
                try
                {
                    using var listener = new TcpListener(address, profile.Port);
                    listener.Server.ExclusiveAddressUse = true;
                    listener.Start();
                    Add("Port", $"{host}:{profile.Port} is available.");
                }
                catch (SocketException ex)
                {
                    Add("Port", $"Cannot listen on {host}:{profile.Port}: {ex.Message}", "Choose another port or stop the application using it. Check that the listen address belongs to this computer.", true);
                }
            }
            return findings;
        }

        try
        {
            var host = profile.Host.Trim('[', ']');
            if (string.IsNullOrWhiteSpace(host) || host == "0.0.0.0") host = "127.0.0.1";
            if (host == "::") host = "::1";
            var uri = new UriBuilder(profile.Scheme, host, profile.Port).Uri;
            var result = await SiteHealthCheck.CheckAsync(new(profile.Id, profile.Name, uri.ToString(), profile.CertificatePath));
            Add("HTTP response", $"{uri}: {result.Summary}", result.IsGood ? "" : "Check the site's index file, HTTPS settings and server console.", !result.IsGood);
        }
        catch (Exception ex) { Add("HTTP response", ex.Message, "Check the server console, listen address and HTTPS settings.", true); }
        return findings;
    }

    public static string Report(IEnumerable<DiagnosticFinding> findings) =>
        "ServerMaster diagnostics - " + DateTimeOffset.Now.ToString("u") + Environment.NewLine +
        string.Join(Environment.NewLine + Environment.NewLine, findings.Select(item =>
            $"[{item.Status}] {item.Group} / {item.Title}\n{item.Detail}" + (item.Remedy.Length > 0 ? "\n" + item.Remedy : "")));
}
