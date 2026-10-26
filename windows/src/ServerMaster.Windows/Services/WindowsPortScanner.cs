using System.Diagnostics;
using System.Text.RegularExpressions;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static partial class WindowsPortScanner
{
    public static async Task<IReadOnlyList<PortEntry>> ScanAsync(bool includeUdp = false)
    {
        var output = await RunNetstatAsync("tcp");
        if (includeUdp) output += Environment.NewLine + await RunNetstatAsync("udp");
        return Parse(output);
    }

    internal static IReadOnlyList<PortEntry> Parse(string output)
    {
        var entries = new List<PortEntry>();
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var tcp = TcpLine().Match(line);
            var udp = tcp.Success ? Match.Empty : UdpLine().Match(line);
            var match = tcp.Success ? tcp : udp;
            if (!match.Success) continue;
            if (!TryEndpoint(match.Groups[1].Value, out var address, out var port)) continue;
            if (!int.TryParse(match.Groups[2].Value, out var pid) || pid <= 0) continue;
            var name = "Unknown";
            try { using var process = Process.GetProcessById(pid); name = process.ProcessName; }
            catch (ArgumentException) { }
            catch (System.ComponentModel.Win32Exception) { name = "Protected process"; }
            entries.Add(new PortEntry { Port = port, ProcessId = pid, ProcessName = name, Address = address, Protocol = tcp.Success ? "TCP" : "UDP" });
        }
        return entries.GroupBy(item => $"{item.Protocol}:{item.ProcessId}:{item.Address}:{item.Port}").Select(group => group.First()).OrderBy(item => item.Port).ThenBy(item => item.ProcessId).ToList();
    }

    public static void Terminate(PortEntry entry)
    {
        if (!entry.CanTerminate) throw new InvalidOperationException("Windows system processes and ServerMaster cannot be terminated here.");
        using var process = Process.GetProcessById(entry.ProcessId);
        process.Kill(entireProcessTree: true);
    }

    public static async Task TerminateAsAdministratorAsync(PortEntry entry)
    {
        if (!entry.CanTerminate) throw new InvalidOperationException("Windows system processes and ServerMaster cannot be terminated here.");
        var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = true,
            Verb = "runas",
            Arguments = $"/PID {entry.ProcessId} /T /F",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Windows did not start the elevated termination request.");
        await process.WaitForExitAsync();
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"Windows could not terminate PID {entry.ProcessId} (exit code {process.ExitCode}).");
    }

    public static string Details(PortEntry entry)
    {
        var lines = new List<string> { $"{entry.ProcessName} (PID {entry.ProcessId})", $"{entry.Protocol} {entry.DisplayAddress}:{entry.Port}" };
        try
        {
            using var process = Process.GetProcessById(entry.ProcessId);
            try { lines.Add("Executable: " + (process.MainModule?.FileName ?? "Unavailable")); }
            catch (System.ComponentModel.Win32Exception) { lines.Add("Executable: Protected by Windows"); }
            try { lines.Add("Started: " + process.StartTime.ToString("g")); }
            catch (System.ComponentModel.Win32Exception) { }
        }
        catch (ArgumentException) { lines.Add("The process has exited."); }
        return string.Join(Environment.NewLine, lines);
    }

    private static async Task<string> RunNetstatAsync(string protocol)
    {
        using var process = Process.Start(new ProcessStartInfo("netstat.exe") { Arguments = "-ano -p " + protocol, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }) ?? throw new InvalidOperationException("Windows netstat could not be started.");
        var output = await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        return output;
    }

    private static bool TryEndpoint(string value, out string address, out int port)
    {
        address = ""; port = 0; value = value.Trim();
        if (value.StartsWith('[') && value.IndexOf("]:", StringComparison.Ordinal) is var close && close > 0) { address = value[1..close]; return int.TryParse(value[(close + 2)..], out port); }
        var separator = value.LastIndexOf(':');
        if (separator <= 0) return false;
        address = value[..separator];
        return int.TryParse(value[(separator + 1)..], out port);
    }

    [GeneratedRegex(@"^\s*TCP\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex TcpLine();

    [GeneratedRegex(@"^\s*UDP\s+(\S+)\s+\S+\s+(\d+)\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex UdpLine();
}
