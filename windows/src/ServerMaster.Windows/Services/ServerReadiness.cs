using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class ServerReadiness
{
    public static async Task<bool> WaitPortReleasedAsync(ServerProfile profile, TimeSpan timeout)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < timeout)
        {
            try { await CheckPortAsync(profile, CancellationToken.None); return true; }
            catch (IOException) { await Task.Delay(100); }
        }
        try { await CheckPortAsync(profile, CancellationToken.None); return true; }
        catch (IOException) { return false; }
    }

    public static async Task CheckPortAsync(ServerProfile profile, CancellationToken cancellationToken)
    {
        var addresses = IPAddress.TryParse(profile.Host, out var ip)
            ? new[] { ip } : await Dns.GetHostAddressesAsync(profile.Host, cancellationToken);
        foreach (var address in addresses)
        {
            using var listener = new TcpListener(address, profile.Port);
            listener.Server.ExclusiveAddressUse = true;
            try { listener.Start(); }
            catch (SocketException ex)
            {
                throw new IOException($"Cannot listen on {profile.Host}:{profile.Port}. The port is occupied or this address is unavailable. Choose another port/host in Profiles or inspect Ports. No other process was stopped.", ex);
            }
        }
    }

    /// <summary>How long one accepted request may take to answer (a CMS builds its first page slowly).</summary>
    public static TimeSpan SlowResponse { get; set; } = TimeSpan.FromSeconds(60);

    public static async Task WaitHttpAsync(Process process, ServerProfile profile, CancellationToken cancellationToken, TimeSpan? timeout = null)
    {
        using var handler = new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var clock = Stopwatch.StartNew();
        // `timeout` bounds how long the server may take to accept connections. A refused connection
        // fails at once and is retried; an accepted request is never abandoned early, because
        // WordPress/WooCommerce needs seconds per page and PHP's built-in server answers one request
        // at a time, so abandoned probes only queue up behind each other.
        while (clock.Elapsed < (timeout ?? TimeSpan.FromSeconds(20)))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited) throw new IOException($"The server exited with code {process.ExitCode} before it answered HTTP requests.");
            using var attempt = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            attempt.CancelAfter(SlowResponse);
            try
            {
                using var response = await client.GetAsync(profile.Address, HttpCompletionOption.ResponseHeadersRead, attempt.Token);
                if (!process.HasExited) return;
            }
            catch (HttpRequestException) { }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new IOException($"The server accepted a connection at {profile.Address} but sent no HTTP response within {SlowResponse.TotalSeconds:0} seconds. See Console for errors.");
            }
            await Task.Delay(150, cancellationToken);
        }
        throw new IOException($"The process started but did not answer at {profile.Address}. Check that the code listens on the profile's HOST and PORT. See Console for startup errors.");
    }
}
