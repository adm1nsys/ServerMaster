using System.Diagnostics;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class SiteHealthCheck
{
    public static async Task<IReadOnlyList<SiteHealthResult>> RunAsync(IEnumerable<SiteHealthTarget> targets) =>
        await Task.WhenAll(targets.Select(target => CheckAsync(target)));

    public static async Task<SiteHealthResult> CheckAsync(SiteHealthTarget target, TimeSpan? timeout = null, CancellationToken cancellation = default)
    {
        var deadline = timeout ?? TimeSpan.FromSeconds(6);
        var timer = Stopwatch.StartNew();
        try
        {
            if (!Uri.TryCreate(target.Address, UriKind.Absolute, out var address) || address.Scheme is not ("http" or "https"))
                return Result(null, null, "The address cannot be read.");
            using var expected = address.Scheme == "https" && !string.IsNullOrWhiteSpace(target.CertificatePath)
                ? X509Certificate2.CreateFromPem(File.ReadAllText(target.CertificatePath)) : null;
            using var handler = new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false };
            if (expected is not null)
                handler.ServerCertificateCustomValidationCallback = (_, presented, _, errors) =>
                    errors == SslPolicyErrors.None || (presented is not null
                        && !errors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch)
                        && DateTime.UtcNow >= presented.NotBefore.ToUniversalTime()
                        && DateTime.UtcNow <= presented.NotAfter.ToUniversalTime()
                        && presented.RawData.AsSpan().SequenceEqual(expected.RawData));
            using var client = new HttpClient(handler) { Timeout = deadline };
            using var request = new HttpRequestMessage(HttpMethod.Get, address);
            request.Headers.CacheControl = new() { NoCache = true, NoStore = true };
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            return Result((int)response.StatusCode, response.Headers.Server.ToString(), null);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { return Result(null, null, $"No answer within {deadline.TotalSeconds:0.#} s."); }
        catch (Exception ex) when (ex is HttpRequestException or IOException or CryptographicException or UnauthorizedAccessException)
        {
            return Result(null, null, ex.InnerException is { } inner ? ex.Message + " " + inner.Message : ex.Message);
        }

        SiteHealthResult Result(int? status, string? server, string? problem) =>
            new(target.Id, target.Name, target.Address, status, timer.ElapsedMilliseconds, server, problem);
    }
}
