using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class HttpsProxy : IDisposable
{
    private readonly Process _process;
    public bool HasExited => _process.HasExited;
    public event Action? Exited;

    public async Task WaitReadyAsync(ServerProfile profile, CancellationToken cancellationToken = default)
    {
        using var expected = System.Security.Cryptography.X509Certificates.X509Certificate2.CreateFromPem(File.ReadAllText(profile.CertificatePath));
        using var handler = new HttpClientHandler
        {
            UseProxy = false, AllowAutoRedirect = false,
            ServerCertificateCustomValidationCallback = (_, cert, _, _) => cert?.Thumbprint == expected.Thumbprint
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
        for (var attempt = 0; attempt < 20; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (HasExited) throw new InvalidOperationException("Caddy stopped before HTTPS was ready. See the console for details.");
            try
            {
                using var response = await client.GetAsync(profile.Address, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
                if ((int)response.StatusCode != 502 && (int)response.StatusCode != 503) return;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
            await Task.Delay(100, cancellationToken);
        }
        throw new InvalidOperationException("HTTPS did not become ready. Check the listen host, certificate and backend console.");
    }

    public static ServerProfile Backend(ServerProfile profile)
    {
        var copy = JsonSerializer.Deserialize<ServerProfile>(JsonSerializer.Serialize(profile))!;
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        copy.Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        copy.Host = "127.0.0.1";
        copy.HttpsEnabled = false;
        copy.Environment.RemoveAll(item => item.Key is "PORT" or "HOST");
        return copy;
    }

    public static string Configuration(ServerProfile profile, int backendPort)
    {
        if (!IPAddress.TryParse(profile.Host, out var address) && profile.Host != "localhost")
            throw new InvalidOperationException("HTTPS listen host must be localhost or a local IP address. Add domain names in Certificates.");
        var listen = new IPEndPoint(address ?? IPAddress.Loopback, profile.Port).ToString();
        return JsonSerializer.Serialize(new
        {
            admin = new { disabled = true, config = new { persist = false } },
            apps = new
            {
                tls = new { certificates = new { load_files = new[] { new { certificate = profile.CertificatePath, key = profile.PrivateKeyPath } } } },
                http = new { servers = new { site = new
                {
                    listen = new[] { listen },
                    automatic_https = new { disable = true },
                    tls_connection_policies = new object[] { new { } },
                    routes = new[] { new { handle = new[] { new { handler = "reverse_proxy", upstreams = new[] { new { dial = "127.0.0.1:" + backendPort } } } } } }
                } } }
            }
        }, new JsonSerializerOptions { WriteIndented = true });
    }

    public HttpsProxy(ServerProfile profile, int backendPort, Action<string> log)
    {
        LocalCertificates.Validate(profile);
        var executable = ShellEnvironment.Shared.Which("caddy") ?? throw new FileNotFoundException("HTTPS needs Caddy. Select Install missing software in Profiles or Certificates.");
        var folder = Path.Combine(AppPaths.Runtime, "https", profile.Id.ToString("N"));
        Directory.CreateDirectory(folder);
        var config = Path.Combine(folder, "caddy.json");
        File.WriteAllText(config, Configuration(profile, backendPort));
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        foreach (var arg in new[] { "run", "--config", config }) info.ArgumentList.Add(arg);
        _process = new Process { StartInfo = info, EnableRaisingEvents = true };
        _process.OutputDataReceived += (_, e) => { if (e.Data is not null) log(e.Data); };
        _process.ErrorDataReceived += (_, e) => { if (e.Data is not null) log(e.Data); };
        _process.Exited += (_, _) => Exited?.Invoke();
        try { _process.Start(); OwnedProcesses.Track(_process); _process.BeginOutputReadLine(); _process.BeginErrorReadLine(); }
        catch { _process.Dispose(); throw; }
    }

    public void Dispose()
    {
        if (!_process.HasExited)
        {
            try { _process.Kill(true); } catch (InvalidOperationException) { }
            try { _process.WaitForExit(10000); } catch (InvalidOperationException) { }
        }
        _process.Dispose();
    }
}
