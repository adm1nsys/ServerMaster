using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace ServerMaster.Windows.Services;

public static class WindowsEnvironmentDiagnostics
{
    public static async Task<IReadOnlyList<DiagnosticFinding>> CheckAsync()
    {
        const string script = """
            $ErrorActionPreference='Stop'
            [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
            function Read-Section($action) { try { @{ Rows=@(& $action) } } catch { @{ Error=$_.Exception.Message } } }
            $result=@{
                Battery=Read-Section { Get-CimInstance Win32_Battery | Select-Object Name,Status,BatteryStatus,EstimatedChargeRemaining }
                Firewall=Read-Section { Get-NetFirewallProfile | Select-Object Name,@{Name='Enabled';Expression={[string]$_.Enabled}},@{Name='Inbound';Expression={[string]$_.DefaultInboundAction}} }
                Crashes=Read-Section {
                    $query="*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=41) and TimeCreated[timediff(@SystemTime) <= 604800000]]]"
                    $raw=& "$env:SystemRoot\System32\wevtutil.exe" qe System ("/q:"+$query) /c:5 /rd:true /f:xml /e:Events 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ($raw -join ' ') }
                    $events=[xml]($raw -join "`n")
                    @($events.Events.Event) | Where-Object { $null -ne $_ } | ForEach-Object {
                        @{ Id=[string]$_.System.EventID; Time=[string]$_.System.TimeCreated.SystemTime; Message='Windows recorded an unclean shutdown.' }
                    }
                }
                Proxy=Read-Section { Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable,ProxyServer,ProxyOverride,AutoConfigURL }
            }
            $result | ConvertTo-Json -Depth 5 -Compress
            """;
        try
        {
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new IOException("PowerShell could not be started.");
            using var group = OwnedProcesses.CreateGroup(process);
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(16)); }
            catch (TimeoutException)
            {
                group.Dispose();
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
                throw new TimeoutException("Windows did not return system diagnostics within 16 seconds.");
            }
            return Parse(await output, process.ExitCode, await error);
        }
        catch (Exception ex) { return Unavailable(ex.Message); }
    }

    internal static IReadOnlyList<DiagnosticFinding> Parse(string output, int exitCode = 0, string error = "")
    {
        if (exitCode != 0) return Unavailable(string.IsNullOrWhiteSpace(error) ? $"Query exited with code {exitCode}." : error.Trim());
        try
        {
            using var document = JsonDocument.Parse(output);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return Unavailable("Windows returned incomplete diagnostics.");
            var findings = new List<DiagnosticFinding>();
            foreach (var (key, group, title) in Sections)
            {
                if (!document.RootElement.TryGetProperty(key, out var section) || section.ValueKind != JsonValueKind.Object)
                { findings.Add(Unknown(group, title, "No result was returned.")); continue; }
                if (section.TryGetProperty("Error", out var failure))
                { findings.Add(Unknown(group, title, failure.ToString())); continue; }
                if (!section.TryGetProperty("Rows", out var rows) || rows.ValueKind != JsonValueKind.Array)
                { findings.Add(Unknown(group, title, "Unreadable result.")); continue; }
                var items = rows.EnumerateArray().ToArray();
                if (items.Any(item => item.ValueKind != JsonValueKind.Object))
                { findings.Add(Unknown(group, title, "Unreadable result.")); continue; }
                if (key == "Battery")
                {
                    if (items.Length == 0) findings.Add(new(group, title, "Windows reports no battery. This is normal on a desktop or a computer with the battery removed.", Severity: DiagnosticLevel.Note));
                    foreach (var item in items)
                    {
                        var status = Value(item, "Status");
                        var charge = Value(item, "EstimatedChargeRemaining");
                        var batteryState = Value(item, "BatteryStatus");
                        var low = batteryState is "4" or "5" or "8" or "9";
                        var label = batteryState switch
                        {
                            "1" => "Discharging", "2" => "AC power available", "3" => "Fully charged",
                            "4" => "Low", "5" => "Critical", "6" => "Charging", "7" => "Charging, high",
                            "8" => "Charging, low", "9" => "Charging, critical", "11" => "Partially charged", _ => "Not reported"
                        };
                        var level = low || status is "Error" or "Degraded" or "Pred Fail" ? DiagnosticLevel.Warning : DiagnosticLevel.Note;
                        findings.Add(new(group, title, $"{Value(item, "Name")}: {status}; charge {(charge == "Not reported" ? charge : charge + "%")}; {label}.",
                            low ? "The battery is low. Connect a suitable power adapter before running servers or installing software."
                                : level == DiagnosticLevel.Warning ? "Windows reports a battery problem. Check the battery and power adapter." : "Battery status is not a capacity or cycle-count test.", Severity: level));
                    }
                }
                else if (key == "Crashes")
                    findings.Add(new(group, title, items.Length == 0 ? "No unexpected-shutdown events recorded in the last 7 days."
                        : string.Join("\n\n", items.Select(item => $"{Value(item, "Time")} - event {Value(item, "Id")}\n{Value(item, "Message")}")),
                        items.Length > 0 ? "These events record an unclean shutdown, not its cause. If repeated, inspect Windows Event Viewer, drivers and power supply." : "",
                        Severity: items.Length > 0 ? DiagnosticLevel.Warning : DiagnosticLevel.Fine));
                else if (key == "Firewall")
                {
                    if (items.Length == 0) findings.Add(Unknown(group, title, "No firewall profiles were returned."));
                    foreach (var item in items)
                        findings.Add(new(group, title + ": " + Value(item, "Name"), $"Enabled: {Value(item, "Enabled")}; default inbound: {Value(item, "Inbound")}.",
                            "This does not test per-application rules. Localhost can work while another device is blocked.", Severity: DiagnosticLevel.Note));
                }
                else
                {
                    if (items.Length == 0) findings.Add(Unknown(group, title, "No proxy settings were returned."));
                    foreach (var item in items)
                    {
                        var enabled = Value(item, "ProxyEnable") == "1";
                        var automatic = Value(item, "AutoConfigURL");
                        findings.Add(new(group, title, $"Manual proxy: {(enabled ? Value(item, "ProxyServer") : "off")}; bypass: {Value(item, "ProxyOverride")}; configuration script: {automatic}.",
                            "Browsers and environment variables may use other proxy settings. Profile health checks connect directly without a proxy.",
                            Severity: enabled || automatic != "Not reported" ? DiagnosticLevel.Note : DiagnosticLevel.Fine));
                    }
                }
            }
            findings.Add(new("Hardware", "Temperature and battery wear", "CPU temperature, thermal throttling, battery capacity and cycle count were not checked. They require device-specific telemetry.", Severity: DiagnosticLevel.Note));
            return findings;
        }
        catch (JsonException) { return Unavailable("Windows returned unreadable diagnostics."); }
    }

    private static readonly (string Key, string Group, string Title)[] Sections =
        [("Battery", "Hardware", "Battery and power"), ("Crashes", "Hardware", "Unexpected shutdowns"), ("Firewall", "Network", "Firewall"), ("Proxy", "Network", "User proxy settings")];
    private static string Value(JsonElement row, string name) => row.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null && value.ToString().Length > 0 ? value.ToString() : "Not reported";
    private static DiagnosticFinding Unknown(string group, string title, string reason) => new(group, title, "Not checked: " + reason, Severity: DiagnosticLevel.Note);
    private static IReadOnlyList<DiagnosticFinding> Unavailable(string reason) => Sections.Select(section => Unknown(section.Group, section.Title, reason)).ToArray();
}
