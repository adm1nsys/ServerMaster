using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class SiteHealthSmokeTests
{
    public static async Task Run()
    {
        await using var good = new Fixture("200 OK", 100);
        await using var bad = new Fixture("500 Internal Server Error");
        await using var redirect = new Fixture("302 Found");
        var targets = new[] { good.Target("Good"), bad.Target("Broken"), redirect.Target("Redirect") };
        var results = await SiteHealthCheck.RunAsync(targets);
        Check(results.Select(result => result.Id).SequenceEqual(targets.Select(target => target.Id)), "parallel results preserve profile order");
        Check(results[0].IsGood && results[0].Status == 200 && results[0].Server == "Fixture", "HTTP status and server header are recorded without downloading the body");
        Check(!results[1].IsGood && results[1].Status == 500 && results[1].Problem is null, "HTTP errors remain distinct from connection failures");
        Check(results[2].IsGood && results[2].Status == 302, "redirect response is recorded at the configured endpoint");
        await using var slow = new Fixture("200 OK", 1000);
        var timeout = await SiteHealthCheck.CheckAsync(slow.Target("Slow"), TimeSpan.FromMilliseconds(100));
        Check(!timeout.IsGood && timeout.Status is null && timeout.Problem!.Contains("within"), "unresponsive site returns a bounded timeout");
        var invalid = await SiteHealthCheck.CheckAsync(new(Guid.NewGuid(), "Invalid", "not a URI"));
        Check(!invalid.IsGood && invalid.Problem is not null, "invalid address becomes a result instead of aborting the run");

        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-health-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            using var key = RSA.Create(2048);
            var request = new CertificateRequest("CN=127.0.0.1", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            var names = new SubjectAlternativeNameBuilder(); names.AddIpAddress(IPAddress.Loopback);
            request.CertificateExtensions.Add(names.Build());
            using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
            // Schannel needs an imported key for the temporary TLS server.
            using var certificate = new X509Certificate2(generated.Export(X509ContentType.Pfx));
            var path = Path.Combine(root, "site.pem");
            await File.WriteAllTextAsync(path, certificate.ExportCertificatePem());
            await using var tls = new Fixture("200 OK", certificate: certificate);
            var trusted = await SiteHealthCheck.CheckAsync(tls.Target("Pinned") with { CertificatePath = path });
            Check(trusted.IsGood, "configured self-signed profile certificate is accepted" + (trusted.Problem is null ? "" : ": " + trusted.Problem + " " + tls.Failure));
            await using var unknownTls = new Fixture("200 OK", certificate: certificate);
            var unknown = await SiteHealthCheck.CheckAsync(unknownTls.Target("Unknown"));
            Check(!unknown.IsGood && unknown.Status is null, "unconfigured self-signed certificate is not silently trusted");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void Check(bool success, string message)
    {
        if (!success) throw new Exception(message);
        Console.WriteLine("PASS Health: " + message);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        private readonly Task _server;
        private readonly bool _tls;
        private readonly int _port;

        public Fixture(string status, int delay = 0, X509Certificate2? certificate = null)
        {
            _listener.Start();
            _port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _tls = certificate is not null;
            _server = ServeAsync(status, delay, certificate);
        }

        public SiteHealthTarget Target(string name) => new(Guid.NewGuid(), name, $"{(_tls ? "https" : "http")}://127.0.0.1:{_port}/");
        public string? Failure => _server.Exception?.GetBaseException().Message;

        private async Task ServeAsync(string status, int delay, X509Certificate2? certificate)
        {
            using var client = await _listener.AcceptTcpClientAsync(_stop.Token);
            await using Stream stream = certificate is null ? client.GetStream() : new SslStream(client.GetStream());
            if (stream is SslStream ssl)
                await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, _stop.Token);
            using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
            while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 }) { }
            await Task.Delay(delay, _stop.Token);
            var response = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nServer: Fixture\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(response, _stop.Token);
        }

        public async ValueTask DisposeAsync()
        {
            _stop.Cancel(); _listener.Stop();
            try { await _server; }
            catch (Exception ex) when (ex is OperationCanceledException or IOException or AuthenticationException or SocketException) { }
            _stop.Dispose();
        }
    }
}
