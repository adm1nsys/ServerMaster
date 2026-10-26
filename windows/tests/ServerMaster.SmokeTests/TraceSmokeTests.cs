using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class TraceSmokeTests
{
    public static async Task Run()
    {
        Check(DomainTrace.HostsEntry("127.0.0.1 site.test # old.test", "old.test").Detail.StartsWith("No entry"), "hosts comments are ignored");
        Check(DomainTrace.HostsEntry("127.0.0.1 SITE.test\n::1 site.test", "site.test").Level == DiagnosticLevel.Warning, "duplicate aliases are detected case-insensitively");
        var invalid = new List<DiagnosticFinding>();
        await DomainTrace.RunAsync(new(Guid.NewGuid(), "bad", "not a URL"), invalid.Add);
        Check(invalid.Count == 1 && invalid[0].Level == DiagnosticLevel.Broken, "invalid address is reported");

        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var server = Serve();
        var results = new List<DiagnosticFinding>();
        try
        {
            await DomainTrace.RunAsync(new(Guid.NewGuid(), "fixture", $"http://127.0.0.1:{port}"), results.Add, cancellation.Token);
            Check(results.Any(step => step.Title == $"Port {port}" && step.Level == DiagnosticLevel.Fine), "actual TCP endpoint is reachable");
            Check(results.Any(step => step.Title == "Request" && step.Level == DiagnosticLevel.Warning && step.Detail.Contains("503")), "HTTP errors remain distinct from connection failures");
            Check(results.All(step => step.Title != "Certificate"), "plain HTTP does not request a certificate");
        }
        finally { cancellation.Cancel(); listener.Stop(); await server; }
        var stopped = new List<DiagnosticFinding>();
        await DomainTrace.RunAsync(new(Guid.NewGuid(), "stopped", $"http://127.0.0.1:{port}"), stopped.Add);
        Check(stopped.Any(step => step.Title == $"Port {port}" && step.Level == DiagnosticLevel.Broken), "closed port is identified");
        var certificatePath = Path.Combine(Path.GetTempPath(), "ServerMaster-trace-" + Guid.NewGuid().ToString("N") + ".pem");
        try
        {
            using var key = RSA.Create(2048);
            var request = new CertificateRequest("CN=127.0.0.1", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-2), DateTimeOffset.UtcNow.AddDays(-1));
            await File.WriteAllTextAsync(certificatePath, certificate.ExportCertificatePem());
            var expired = new List<DiagnosticFinding>();
            await DomainTrace.RunAsync(new(Guid.NewGuid(), "expired", $"https://127.0.0.1:{port}", certificatePath), expired.Add);
            Check(expired.Any(step => step.Title == "Certificate" && step.Level == DiagnosticLevel.Broken && step.Detail.Contains("Issuer:")), "expired certificate is inspected even when the server is stopped");
            var missing = new List<DiagnosticFinding>();
            await DomainTrace.RunAsync(new(Guid.NewGuid(), "missing", $"https://127.0.0.1:{port}"), missing.Add);
            Check(missing.Any(step => step.Title == "Certificate" && step.Detail.Contains("no certificate")), "missing HTTPS certificate has an explicit explanation");
        }
        finally { File.Delete(certificatePath); }
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try { await DomainTrace.RunAsync(new(Guid.NewGuid(), "cancelled", "http://127.0.0.1:1"), _ => { }, cancelled.Token); throw new Exception("Cancellation was ignored."); }
        catch (OperationCanceledException) { Console.WriteLine("PASS trace cancellation"); }

        async Task Serve()
        {
            try
            {
                // The first connection is the TCP probe; the second is the HTTP request.
                using (var probe = await listener.AcceptTcpClientAsync(cancellation.Token)) { }
                using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                await using var stream = client.GetStream();
                using var reader = new StreamReader(stream, leaveOpen: true);
                while (await reader.ReadLineAsync(cancellation.Token) is { Length: > 0 }) { }
                await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 503 Service Unavailable\r\nServer: TraceFixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), cancellation.Token);
            }
            catch (OperationCanceledException) { }
            catch (SocketException) when (cancellation.IsCancellationRequested) { }
        }
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS " + description);
    }
}
