using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Runtime.InteropServices;

namespace ServerMaster.Windows.Services;

public static class SystemDiagnostics
{
    public static async Task<IReadOnlyList<DiagnosticFinding>> CheckAsync()
    {
        var findings = new List<DiagnosticFinding>();
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        findings.Add(GlobalMemoryStatusEx(ref memory)
            ? MemoryFinding(memory.TotalPhysical, memory.AvailablePhysical, memory.Load)
            : new("System", "Memory", "Windows could not return physical memory usage (code " + Marshal.GetLastWin32Error() + ").", Severity: DiagnosticLevel.Note));
        findings.Add(new("System", "Platform", $"Windows {Environment.OSVersion.Version} ({(Environment.Is64BitOperatingSystem ? "x64" : "x86")})."));

        var systemRoot = Path.GetPathRoot(Environment.SystemDirectory);
        if (systemRoot is not null)
        {
            var drive = new DriveInfo(systemRoot);
            if (drive.IsReady)
            {
                var freeGb = drive.AvailableFreeSpace / 1073741824d;
                findings.Add(new("System", "System drive", $"{freeGb:F1} GB free on {systemRoot}", freeGb < 5 ? "Free disk space before downloading runtimes or templates." : "", freeGb < 5,
                    freeGb < 2 ? DiagnosticLevel.Broken : freeGb < 5 ? DiagnosticLevel.Warning : DiagnosticLevel.Fine));
            }
        }

        try
        {
            const string script = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName,@{Name='HealthStatus';Expression={[string]$_.HealthStatus}},@{Name='OperationalStatus';Expression={@($_.OperationalStatus | ForEach-Object {[string]$_})}}) | ConvertTo-Json -Compress";
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            if (process is null) throw new InvalidOperationException("PowerShell could not be started.");
            using var group = OwnedProcesses.CreateGroup(process);
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            try { await process.WaitForExitAsync(deadline.Token); }
            catch (OperationCanceledException)
            {
                group.Dispose();
                using var stopDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await process.WaitForExitAsync(stopDeadline.Token);
                throw new TimeoutException("Windows did not return disk health within 8 seconds.");
            }
            findings.AddRange(ParsePhysicalDisks(await output, process.ExitCode, await error));
        }
        catch (Exception ex)
        {
            findings.Add(Unavailable(ex.Message));
        }

        return findings;
    }

    public static IReadOnlyList<DiagnosticFinding> ParsePhysicalDisks(string output, int exitCode = 0, string error = "")
    {
        if (exitCode != 0) return [Unavailable(string.IsNullOrWhiteSpace(error) ? $"Windows query exited with code {exitCode}." : error.Trim())];
        if (string.IsNullOrWhiteSpace(output)) return [Unavailable("The storage provider returned no disk health data.")];
        try
        {
            using var json = JsonDocument.Parse(output);
            JsonElement[] rows = json.RootElement.ValueKind == JsonValueKind.Array ? json.RootElement.EnumerateArray().ToArray() : [json.RootElement];
            var results = new List<DiagnosticFinding>();
            foreach (var row in rows)
            {
                if (row.ValueKind != JsonValueKind.Object) continue;
                var name = row.TryGetProperty("FriendlyName", out var friendly) ? friendly.ToString() : "Unnamed disk";
                var health = row.TryGetProperty("HealthStatus", out var status) ? status.ToString() : "Unknown";
                string[] operations = row.TryGetProperty("OperationalStatus", out var op)
                    ? op.ValueKind == JsonValueKind.Array ? op.EnumerateArray().Select(item => item.ToString()).ToArray() : [op.ToString()] : [];
                // MSFT_PhysicalDisk HealthStatus: 0 healthy, 1 warning, 2 unhealthy, 5 unknown.
                var level = health.ToLowerInvariant() switch
                {
                    "0" or "healthy" => DiagnosticLevel.Fine,
                    "1" or "warning" => DiagnosticLevel.Warning,
                    "2" or "unhealthy" => DiagnosticLevel.Broken,
                    _ => DiagnosticLevel.Note
                };
                if (level == DiagnosticLevel.Fine && operations.Any(item => item is not ("2" or "OK"))) level = DiagnosticLevel.Note;
                var label = health switch { "0" => "Healthy", "1" => "Warning", "2" => "Unhealthy", "5" => "Unknown", _ => health };
                var detail = $"Windows reports {label}." + (operations.Length == 0 ? "" : " Operational status: " + string.Join(", ", operations) + ".");
                var remedy = level >= DiagnosticLevel.Warning ? "Back up your sites and inspect this drive in Windows storage diagnostics."
                    : level == DiagnosticLevel.Note ? "The storage provider did not confirm a normal disk state. Inspect the drive with its manufacturer's tools if needed." : "";
                results.Add(new("System", "Physical disk: " + name, detail, remedy, level >= DiagnosticLevel.Warning, level));
            }
            return results.Count > 0 ? results : [Unavailable("The storage provider returned no disk health data.")];
        }
        catch (JsonException) { return [Unavailable("Windows returned an unreadable disk health result.")]; }
    }

    private static DiagnosticFinding Unavailable(string detail) => new("System", "Physical disks", "Disk health was not checked: " + detail,
        "Check Windows Storage or the drive manufacturer's diagnostics for this device.", Severity: DiagnosticLevel.Note);

    internal static DiagnosticFinding MemoryFinding(ulong total, ulong available, uint load)
    {
        if (total == 0 || available > total || load > 100)
            return new("System", "Memory", "Windows returned incomplete memory usage data.", Severity: DiagnosticLevel.Note);
        var level = load >= 95 ? DiagnosticLevel.Broken : load >= 85 ? DiagnosticLevel.Warning : DiagnosticLevel.Fine;
        return new("System", "Memory", $"{total / 1073741824d:F1} GB RAM; {available / 1073741824d:F1} GB available; {load}% in use.",
            level >= DiagnosticLevel.Warning ? "Close heavy applications before installing or running several servers." : "", Severity: level);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
