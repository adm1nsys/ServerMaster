using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class DomainTrace
{
    public static async Task RunAsync(SiteHealthTarget target, Action<DiagnosticFinding> report, CancellationToken cancellation = default)
    {
        if (!Uri.TryCreate(target.Address, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
        {
            report(new("Trace", "Address", "The address cannot be read.", Severity: DiagnosticLevel.Broken));
            return;
        }
        var host = uri.IdnHost.Trim('[', ']');
        if (!IPAddress.TryParse(host, out _))
            await Step("Hosts file", async token =>
            {
                var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc", "hosts");
                var text = await File.ReadAllTextAsync(path, token);
                return HostsEntry(text, host);
            }, DiagnosticLevel.Warning);
        await Step("Name", async token =>
        {
            var addresses = await Dns.GetHostAddressesAsync(host, token);
            return (addresses.Length == 0 ? DiagnosticLevel.Broken : DiagnosticLevel.Fine,
                addresses.Length == 0 ? $"{host} does not resolve to anything." : string.Join(", ", addresses.Select(address => address.ToString())));
        });
        await Step("Reachable", async token =>
        {
            using var ping = new Ping();
            var reply = await ping.SendPingAsync(host, TimeSpan.FromSeconds(2), cancellationToken: token);
            return (reply.Status == IPStatus.Success ? DiagnosticLevel.Fine : DiagnosticLevel.Warning,
                reply.Status == IPStatus.Success ? $"{host} answers." : $"No ping answer ({reply.Status}). A firewall may block ping even when the site works.");
        }, DiagnosticLevel.Warning);
        await Step($"Port {uri.Port}", async token =>
        {
            using var client = new TcpClient();
            await client.ConnectAsync(host, uri.Port, token);
            return (DiagnosticLevel.Fine, $"TCP connection to {host}:{uri.Port} succeeded.");
        });
        await Step("Request", async token =>
        {
            var result = await SiteHealthCheck.CheckAsync(target, TimeSpan.FromSeconds(8), token);
            return (result.Problem is not null ? DiagnosticLevel.Broken : result.IsGood ? DiagnosticLevel.Fine : DiagnosticLevel.Warning, result.Summary);
        });
        if (uri.Scheme == "https")
            await Step("Certificate", async token =>
            {
                if (string.IsNullOrWhiteSpace(target.CertificatePath))
                    return (DiagnosticLevel.Broken, "HTTPS is on but no certificate file is set.");
                using var certificate = X509Certificate2.CreateFromPem(await File.ReadAllTextAsync(target.CertificatePath, token));
                var valid = DateTime.UtcNow >= certificate.NotBefore.ToUniversalTime() && DateTime.UtcNow <= certificate.NotAfter.ToUniversalTime();
                return (valid ? DiagnosticLevel.Fine : DiagnosticLevel.Broken,
                    $"Subject: {certificate.Subject}\nIssuer: {certificate.Issuer}\nValid: {certificate.NotBefore:u} - {certificate.NotAfter:u}");
            });

        async Task Step(string title, Func<CancellationToken, Task<(DiagnosticLevel Level, string Detail)>> check, DiagnosticLevel failure = DiagnosticLevel.Broken)
        {
            cancellation.ThrowIfCancellationRequested();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            deadline.CancelAfter(TimeSpan.FromSeconds(10));
            var timer = Stopwatch.StartNew();
            DiagnosticLevel level;
            string detail;
            try { (level, detail) = await check(deadline.Token); }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
            catch (OperationCanceledException) { level = failure; detail = "No answer within 10 s."; }
            catch (Exception ex) when (ex is IOException or SocketException or PingException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
            { level = failure; detail = ex.Message; }
            report(new("Trace", title, $"{detail}\n{timer.ElapsedMilliseconds} ms", Severity: level));
        }
    }

    internal static (DiagnosticLevel Level, string Detail) HostsEntry(string text, string host)
    {
        var matches = text.Split('\n').Select(line => line.Split('#')[0].Trim())
            .Where(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Skip(1)
                .Any(alias => string.Equals(alias, host, StringComparison.OrdinalIgnoreCase))).ToArray();
        return (matches.Length > 1 ? DiagnosticLevel.Warning : DiagnosticLevel.Fine,
            matches.Length == 0 ? $"No entry for {host}; the name is resolved normally." : string.Join("\n", matches));
    }
}
