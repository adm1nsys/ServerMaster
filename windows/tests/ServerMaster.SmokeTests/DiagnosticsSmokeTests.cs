using System.Text.Json;
using ServerMaster.Windows.Services;

internal static class DiagnosticsSmokeTests
{
    public static async Task Run()
    {
        const ulong gb = 1073741824;
        Check(SystemDiagnostics.MemoryFinding(4 * gb, 2 * gb, 50).Level == DiagnosticLevel.Fine, "small RAM capacity is not confused with memory pressure");
        Check(SystemDiagnostics.MemoryFinding(16 * gb, gb, 90).Level == DiagnosticLevel.Warning, "high physical memory usage is a warning");
        Check(SystemDiagnostics.MemoryFinding(16 * gb, gb / 2, 97).Level == DiagnosticLevel.Broken, "critical memory usage needs attention");
        Check(SystemDiagnostics.MemoryFinding(0, 0, 0).Level == DiagnosticLevel.Note, "missing RAM measurements are not healthy");
        var now = new DateTime(2026, 10, 14, 12, 0, 0);
        Check(DatabaseDiagnostics.LogFinding("2026-10-14 11:59:00 0 [ERROR] start failed", false, now)?.Level == DiagnosticLevel.Warning, "recent stopped-database error needs attention");
        Check(DatabaseDiagnostics.LogFinding("2026-10-01 11:59:00 0 [ERROR] old error", false, now)?.Level == DiagnosticLevel.Note, "old error does not imply a current failure");
        Check(DatabaseDiagnostics.LogFinding("2026-10-14 11:59:00 0 [ERROR] start failed", true, now)?.Level == DiagnosticLevel.Note, "running database is not marked broken for an earlier error");
        Check(DatabaseDiagnostics.LogFinding("[ERROR] unknown timestamp", false, now)?.Level == DiagnosticLevel.Note, "unknown error age is not guessed from file modification time");
        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-diagnostics-" + Guid.NewGuid().ToString("N"));
        var installed = new DatabaseRuntimeStatus(true, false, "fixture", "", "Stopped");
        try
        {
            Check(DatabaseDiagnostics.Check(installed, root).Any(item => item.Title == "Not prepared yet") && !Directory.Exists(root), "diagnostics does not create a missing database folder");
            var data = Path.Combine(root, "data");
            Directory.CreateDirectory(data);
            Check(DatabaseDiagnostics.Check(installed, root).Any(item => item.Title == "Not prepared yet"), "empty initial directory is not declared corrupted");
            await File.WriteAllTextAsync(Path.Combine(data, "partial"), "preserve me");
            Check(DatabaseDiagnostics.Check(installed, root).Any(item => item.Level == DiagnosticLevel.Broken), "partial initialization is reported without deleting data");
            Directory.CreateDirectory(Path.Combine(data, "mysql"));
            Check(DatabaseDiagnostics.Check(installed, root).Any(item => item.Title == "System tables" && item.Level == DiagnosticLevel.Fine), "existing system schema is recognized");
            await File.WriteAllTextAsync(Path.Combine(root, "error.log"), "2026-10-01 11:59:00 0 [ERROR] old error\n" + new string('x', 70000));
            Check(DatabaseDiagnostics.Check(installed, root).All(item => item.Title != "Errors in the database log"), "log inspection is bounded to its tail");
            Check(File.ReadAllText(Path.Combine(data, "partial")) == "preserve me", "diagnostics preserves existing database contents");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        var output = JsonSerializer.Serialize(new[]
        {
            new { FriendlyName = "Healthy disk named Unhealthy", HealthStatus = 0, OperationalStatus = new[] { 2 } },
            new { FriendlyName = "Warning disk", HealthStatus = 1, OperationalStatus = new[] { 2 } },
            new { FriendlyName = "Broken disk", HealthStatus = 2, OperationalStatus = new[] { 2 } },
            new { FriendlyName = "Unknown disk", HealthStatus = 5, OperationalStatus = new[] { 0 } }
        });
        var environment = WindowsEnvironmentDiagnostics.Parse("""
            {"Battery":{"Rows":[]},"Crashes":{"Rows":[]},"Firewall":{"Rows":[{"Name":"Public","Enabled":"True","Inbound":"Block"}]},"Proxy":{"Rows":[{"ProxyEnable":1,"ProxyServer":"proxy.test:8080","ProxyOverride":"<local>"}]}}
            """);
        Check(environment.Any(item => item.Title == "Battery and power" && item.Level == DiagnosticLevel.Note), "no battery is information, not a hardware failure");
        Check(environment.Any(item => item.Title == "Unexpected shutdowns" && item.Level == DiagnosticLevel.Fine), "successful empty event query reports no recent unexpected shutdowns");
        Check(environment.Any(item => item.Title.StartsWith("Firewall:") && item.Level == DiagnosticLevel.Note), "firewall configuration alone is not a failed connectivity test");
        Check(environment.Any(item => item.Title == "User proxy settings" && item.Level == DiagnosticLevel.Note && item.Detail.Contains("proxy.test")), "proxy settings are surfaced without guessing browser bypass rules");
        var failure = WindowsEnvironmentDiagnostics.Parse("{\"Crashes\":{\"Error\":\"Access denied\"}}");
        Check(failure.Count >= 4 && failure.All(item => item.Level == DiagnosticLevel.Note) && failure.Any(item => item.Detail.Contains("Access denied")), "denied and missing system checks never become healthy results");
        var lowBattery = WindowsEnvironmentDiagnostics.Parse("{\"Battery\":{\"Rows\":[{\"Name\":\"Battery\",\"Status\":\"OK\",\"BatteryStatus\":5,\"EstimatedChargeRemaining\":3}]}}");
        Check(lowBattery.Any(item => item.Title == "Battery and power" && item.Level == DiagnosticLevel.Warning && item.Detail.Contains("Critical")), "critical battery charge has a readable warning");
        Check(WindowsEnvironmentDiagnostics.Parse("broken").All(item => item.Level == DiagnosticLevel.Note), "invalid environment JSON remains unavailable");
        Check(WindowsEnvironmentDiagnostics.Parse("{}", 1, "Failed").All(item => item.Detail.Contains("Failed")), "failed query does not parse stale successful output");
        var appRoot = Path.Combine(Path.GetTempPath(), "ServerMaster-app-diagnostics-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appRoot);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(appRoot, "profiles.json"), "[]");
            await File.WriteAllTextAsync(Path.Combine(appRoot, "settings.json"), "{}");
            var appFindings = await AppDataDiagnostics.CheckAsync(appRoot);
            Check(appFindings.Where(item => item.Title is "Profiles" or "Settings").All(item => item.Level == DiagnosticLevel.Fine), "saved profile and settings JSON is inspected");
            Check(appFindings.Any(item => item.Title == "Write test" && item.Level != DiagnosticLevel.Broken) && !Directory.EnumerateFiles(appRoot, ".diagnostics-*").Any(), "write probe reads back data and removes only its own file");
            await File.WriteAllTextAsync(Path.Combine(appRoot, "settings.json"), "[]");
            var wrong = await AppDataDiagnostics.CheckAsync(appRoot);
            Check(wrong.Any(item => item.Title == "Settings" && item.Level == DiagnosticLevel.Broken), "valid JSON with the wrong settings shape is not accepted");
            Check(await File.ReadAllTextAsync(Path.Combine(appRoot, "settings.json")) == "[]", "diagnostics does not repair or overwrite saved settings");
            File.Delete(Path.Combine(appRoot, "profiles.json"));
            Check((await AppDataDiagnostics.CheckAsync(appRoot)).Any(item => item.Title == "Profiles" && item.Level == DiagnosticLevel.Note), "no saved profiles is a first-run state, not damaged data");
        }
        finally { Directory.Delete(appRoot, true); }
        var findings = SystemDiagnostics.ParsePhysicalDisks(output);
        Check(findings.Select(item => item.Level).SequenceEqual(new[] { DiagnosticLevel.Fine, DiagnosticLevel.Warning, DiagnosticLevel.Broken, DiagnosticLevel.Note }),
            "numeric Windows disk states preserve severity without matching disk names");
        var single = SystemDiagnostics.ParsePhysicalDisks(JsonSerializer.Serialize(new
        {
            FriendlyName = "\u0414\u0438\u0441\u043a", HealthStatus = "Healthy", OperationalStatus = new[] { "OK" }
        }));
        Check(single.Count == 1 && single[0].Level == DiagnosticLevel.Fine && single[0].Title.Contains("\u0414\u0438\u0441\u043a"),
            "single-object JSON and Cyrillic disk names are retained");
        var denied = SystemDiagnostics.ParsePhysicalDisks(output, 1, "Access denied");
        Check(denied.Count == 1 && denied[0].Level == DiagnosticLevel.Note && denied[0].Detail.Contains("Access denied") && denied[0].Status != "OK",
            "failed query cannot reuse healthy-looking output as a pass");
        foreach (var empty in new[] { "", "[]", "null", "broken JSON" })
            Check(SystemDiagnostics.ParsePhysicalDisks(empty).All(item => item.Level == DiagnosticLevel.Note), "unavailable disk data is reported: " + empty);
        Check(findings.Where(item => item.NeedsAttention).Select(item => item.Level).SequenceEqual(new[] { DiagnosticLevel.Warning, DiagnosticLevel.Broken }),
            "warnings and broken findings need attention; unknown data is informational");
        var report = ProfileDiagnostics.Report(findings);
        Check(report.Contains("[Broken]") && report.Contains("[Worth a look]") && report.Contains("[Information]"),
            "copied report retains each diagnostic level");
        var live = await SystemDiagnostics.CheckAsync();
        Check(live.Any(item => item.Title.StartsWith("Physical disk", StringComparison.Ordinal)) && live.Any(item => item.Title == "Platform"),
            "live read-only Windows checks return disk results or an explicit unavailable result");
        var liveEnvironment = await WindowsEnvironmentDiagnostics.CheckAsync();
        foreach (var finding in liveEnvironment) Console.WriteLine($"Windows context: {finding.Title}: {finding.Detail.Split('\n')[0]}");
        Check(liveEnvironment.Any(item => item.Title == "Battery and power") && liveEnvironment.Any(item => item.Title == "Unexpected shutdowns") && liveEnvironment.Any(item => item.Group == "Network"),
            "live Windows context query returns each section or explains its unavailability");
    }

    private static void Check(bool success, string message)
    {
        if (!success) throw new Exception(message);
        Console.WriteLine("PASS Diagnostics: " + message);
    }
}
