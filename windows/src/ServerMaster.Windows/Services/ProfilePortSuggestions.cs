using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed record ProfilePortPreset(int Port, string Title, string Note);

public static class ProfilePortSuggestions
{
    public static IReadOnlyList<ProfilePortPreset> Http { get; } =
    [
        new(8080, "standard local", "A familiar port for a local server"),
        new(3000, "React, Next.js", "Common frontend development port"),
        new(5173, "Vite", "Vite and SvelteKit default"),
        new(4200, "Angular", "Angular development port"),
        new(8000, "Python, Django", "Python development port"),
        new(5000, "Flask, .NET", "Common application port"),
        new(1313, "Hugo", "Hugo development port"),
        new(4000, "Jekyll, Phoenix", "Common development port"),
        new(8888, "Jupyter", "Jupyter Notebook default"),
        new(9000, "spare", "Alternative to 8080")
    ];

    public static IReadOnlyList<ProfilePortPreset> Https { get; } =
    [
        new(8443, "standard local HTTPS", "Alternative to 443"),
        new(4443, "alternative HTTPS", "Use when 8443 is occupied"),
        new(9443, "spare HTTPS", "Another local HTTPS port"),
        new(3443, "HTTPS for frontend", "Convenient next to 3000")
    ];

    public static ProfilePortPreset? Find(int port) => Http.Concat(Https).FirstOrDefault(item => item.Port == port);

    public static async Task<bool> IsAvailableAsync(string host, int port, CancellationToken cancellationToken = default)
    {
        if (port is < 1 or > 65535) return false;
        try
        {
            await ServerReadiness.CheckPortAsync(new ServerProfile { Host = host, Port = port }, cancellationToken);
            return true;
        }
        catch (IOException) { return false; }
    }

    public static async Task<int?> NearestFreeAsync(string host, int start, CancellationToken cancellationToken = default)
    {
        for (var port = Math.Max(1024, start); port <= 65535; port++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (await IsAvailableAsync(host, port, cancellationToken)) return port;
        }
        return null;
    }
}
