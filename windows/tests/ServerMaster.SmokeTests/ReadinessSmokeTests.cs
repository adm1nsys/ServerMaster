using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class ReadinessSmokeTests
{
    // Local loopback listeners stand in for a slow CMS; nothing else is touched.
    public static async Task Run()
    {
        using var self = Process.GetCurrentProcess();

        var slow = Listen(out var slowPort);
        var slowServer = Serve(slow, TimeSpan.FromSeconds(3), answer: true);
        var clock = Stopwatch.StartNew();
        await ServerReadiness.WaitHttpAsync(self, Profile(slowPort), CancellationToken.None, TimeSpan.FromSeconds(10));
        Check(clock.Elapsed >= TimeSpan.FromSeconds(2.5), "a page that takes 3 seconds counts as ready instead of timing out after 1 second");
        slow.Stop();

        var silent = Listen(out var silentPort);
        var silentServer = Serve(silent, TimeSpan.FromSeconds(30), answer: false);
        var previous = ServerReadiness.SlowResponse;
        ServerReadiness.SlowResponse = TimeSpan.FromSeconds(2);
        try
        {
            await ServerReadiness.WaitHttpAsync(self, Profile(silentPort), CancellationToken.None, TimeSpan.FromSeconds(10));
            Check(false, "a server that never answers is reported");
        }
        catch (IOException ex) { Check(ex.Message.Contains("sent no HTTP response"), "an accepted connection without an answer gets its own clear error"); }
        finally { ServerReadiness.SlowResponse = previous; silent.Stop(); }

        var closedPort = FreePort();
        clock.Restart();
        try
        {
            await ServerReadiness.WaitHttpAsync(self, Profile(closedPort), CancellationToken.None, TimeSpan.FromSeconds(2));
            Check(false, "a closed port is reported");
        }
        catch (IOException ex) { Check(ex.Message.Contains("did not answer") && clock.Elapsed < TimeSpan.FromSeconds(6), "a port nobody listens on still fails within the start timeout"); }
        _ = slowServer; _ = silentServer;
    }

    private static ServerProfile Profile(int port) => new() { Host = "127.0.0.1", Port = port, Engine = "custom" };

    private static int FreePort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop(); return port;
    }

    private static TcpListener Listen(out int port)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        port = ((IPEndPoint)listener.LocalEndpoint).Port; return listener;
    }

    // Accepts every connection and answers each request after `delay` (or never), one at a time like php -S.
    private static async Task Serve(TcpListener listener, TimeSpan delay, bool answer)
    {
        try
        {
            while (true)
            {
                using var client = await listener.AcceptTcpClientAsync();
                var stream = client.GetStream();
                var buffer = new byte[4096];
                _ = await stream.ReadAsync(buffer);
                await Task.Delay(delay);
                if (!answer) continue;
                var body = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                await stream.WriteAsync(body);
            }
        }
        catch (Exception) { } // listener stopped
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Readiness: " + description);
    }
}
