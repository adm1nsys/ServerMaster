using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class HttpsSmokeTests
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS " + message);
    }

    public static async Task Run(bool online)
    {
        Directory.CreateDirectory(AppPaths.Runtime);
        try
        {
            foreach (var template in ProfileTemplate.BuiltIn)
            {
                var profile = template.CreateProfile(Path.Combine(AppPaths.Runtime, template.Id), 8080);
                var commands = ProfileRequirements.CommandsFor(profile);
                Check(template.Engine == "custom" || commands.Count > 0, template.Title + " has declared runtime dependencies");
                Check(!template.NeedsDatabase || commands.Contains("mariadbd"), template.Title + " preserves database requirement");
                if (template.Id is "static" or "spa" or "node-api" or "node-script" or "php" or "python")
                {
                    var starter = StarterTemplate.DefaultFor(profile);
                    StarterTemplate.Write(profile, starter);
                    try { StarterTemplate.Write(profile, starter); throw new Exception("Existing file overwritten"); }
                    catch (IOException) { }
                    Check(File.ReadAllText(Path.Combine(profile.RootPath, starter.FileName)) == starter.Content, template.Title + " starter created without overwriting files");
                    if (profile.Engine == "nodeScript" && ShellEnvironment.Shared.Which("node") is not null)
                    {
                        using (var portProbe = new TcpListener(IPAddress.Loopback, 0)) { portProbe.Start(); profile.Port = ((IPEndPoint)portProbe.LocalEndpoint).Port; }
                        var plan = LaunchPlanBuilder.Build(profile);
                        var start = new ProcessStartInfo(plan.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = plan.WorkingDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
                        foreach (var argument in plan.Arguments) start.ArgumentList.Add(argument);
                        foreach (var pair in plan.Environment) start.Environment[pair.Key] = pair.Value;
                        using var node = Process.Start(start)!;
                        var output = node.StandardOutput.ReadToEndAsync();
                        var error = node.StandardError.ReadToEndAsync();
                        try
                        {
                            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
                            string? body = null;
                            for (var attempt = 0; attempt < 30; attempt++)
                            {
                                try { body = await client.GetStringAsync(profile.Address); break; }
                                catch (HttpRequestException) { await Task.Delay(100); }
                            }
                            Check(body is not null && (template.Id == "node-api" ? body.Contains("\"ok\":true") : body.Contains("Hello")), template.Title + " starts and serves its generated response");
                        }
                        finally { if (!node.HasExited) { node.Kill(true); await node.WaitForExitAsync(); } await Task.WhenAll(output, error); }
                    }
                }
            }
            var site = new ServerProfile { Engine = "phpBuiltIn", PhpVersion = "8.2", HttpsEnabled = true, Host = "127.0.0.1" };
            Check(ProfileRequirements.CommandsFor(site).Contains("php@8.2") && ProfileRequirements.CommandsFor(site).Contains("caddy"), "HTTPS profile requirements retain the selected PHP branch");
            LocalCertificates.Generate(site, "localhost 127.0.0.1 ::1", false);
            LocalCertificates.Validate(site);
            using var certificate = X509Certificate2.CreateFromPemFile(site.CertificatePath, site.PrivateKeyPath);
            var san = new X509SubjectAlternativeNameExtension(certificate.Extensions["2.5.29.17"]!.RawData);
            Check(san.EnumerateDnsNames().Contains("localhost") && san.EnumerateIPAddresses().Contains(IPAddress.Loopback), "Generated certificate includes DNS and IP SANs");
            Check(certificate.HasPrivateKey && certificate.NotAfter > DateTime.Now.AddDays(89), "Generated certificate has a matching key and 90-day validity");
            try { LocalCertificates.Names("https://localhost:8080"); throw new Exception("Invalid certificate host accepted"); }
            catch (InvalidOperationException) { }
            using var config = JsonDocument.Parse(HttpsProxy.Configuration(site, 12345));
            Check(config.RootElement.GetProperty("admin").GetProperty("disabled").GetBoolean(), "HTTPS proxy has no admin listener");
            var backend = HttpsProxy.Backend(site);
            Check(backend.Host == "127.0.0.1" && !backend.HttpsEnabled && backend.PhpVersion == "8.2", "HTTPS backend stays on loopback and preserves PHP version");
            if (!online) return;

            using var download = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            download.DefaultRequestHeaders.UserAgent.ParseAdd("ServerMaster-SmokeTests");
            using var release = JsonDocument.Parse(await download.GetStringAsync("https://api.github.com/repos/caddyserver/caddy/releases/latest"));
            var assets = release.RootElement.GetProperty("assets").EnumerateArray().ToArray();
            var asset = assets.First(item => item.GetProperty("name").GetString()!.EndsWith("windows_amd64.zip"));
            var checksumAsset = assets.First(item => item.GetProperty("name").GetString()!.EndsWith("checksums.txt"));
            var checksumText = await download.GetStringAsync(checksumAsset.GetProperty("browser_download_url").GetString());
            var name = asset.GetProperty("name").GetString()!;
            var expected = checksumText.Split('\n').First(line => line.TrimEnd().EndsWith(name)).Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
            var bytes = await download.GetByteArrayAsync(asset.GetProperty("browser_download_url").GetString());
            Check(Convert.ToHexString(SHA512.HashData(bytes)).Equals(expected, StringComparison.OrdinalIgnoreCase), "Portable Caddy download matches official SHA-512");
            var tools = Path.Combine(AppPaths.Runtime, "tools");
            using (var zip = new ZipArchive(new MemoryStream(bytes))) zip.ExtractToDirectory(tools);
            ShellEnvironment.Shared.SetExtraEntries([tools]);
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var backendPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); site.Port = ((IPEndPoint)probe.LocalEndpoint).Port; }
            using var stop = new CancellationTokenSource();
            var forwardedHttps = false;
            var serve = Task.Run(async () =>
            {
                try
                {
                    while (!stop.IsCancellationRequested)
                    {
                        using var connection = await listener.AcceptTcpClientAsync(stop.Token);
                        await using var stream = connection.GetStream();
                        using var reader = new StreamReader(stream, leaveOpen: true);
                        while (await reader.ReadLineAsync(stop.Token) is { Length: > 0 } line)
                            if (line.Equals("X-Forwarded-Proto: https", StringComparison.OrdinalIgnoreCase)) forwardedHttps = true;
                        await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsecure"), stop.Token);
                    }
                }
                catch (OperationCanceledException) { }
            });
            try
            {
                using var proxy = new HttpsProxy(site, backendPort, Console.WriteLine);
                await proxy.WaitReadyAsync(site);
                using var handler = new HttpClientHandler { UseProxy = false, ServerCertificateCustomValidationCallback = (_, peer, _, _) => peer?.Thumbprint == certificate.Thumbprint };
                using var client = new HttpClient(handler);
                Check(await client.GetStringAsync(site.Address) == "secure", "Real HTTPS request reaches the HTTP backend using the generated certificate");
                Check(forwardedHttps, "Proxy forwards HTTPS scheme to application");
            }
            finally { stop.Cancel(); await serve; }
        }
        finally
        {
            ShellEnvironment.Shared.SetExtraEntries([]);
            if (Directory.Exists(AppPaths.Runtime))
            {
                try { Directory.Delete(AppPaths.Runtime, true); }
                catch (UnauthorizedAccessException) { Thread.Sleep(250); Directory.Delete(AppPaths.Runtime, true); }
            }
        }
    }
}
