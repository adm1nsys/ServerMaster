namespace ServerMaster.Windows.Models;

public sealed record PortEntry
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => $"{Protocol} {Port} {Description}";

    public int Port { get; init; }
    public int ProcessId { get; init; }
    public string ProcessName { get; init; } = "Unknown";
    public string Address { get; init; } = "*";
    public string Protocol { get; init; } = "TCP";
    public bool IsSystemProcess => ProcessId <= 4 || new[] { "System", "Idle", "svchost", "services", "lsass", "wininit", "winlogon", "csrss", "smss", "Protected process" }
        .Contains(ProcessName, StringComparer.OrdinalIgnoreCase);
    public bool CanOpenInBrowser => Protocol == "TCP";
    public bool CanTerminate => !IsSystemProcess && ProcessId != Environment.ProcessId;
    public string DisplayAddress => Address is "0.0.0.0" or "::" ? "all interfaces" : Address;
    public string Description => $"{ProcessName} (PID {ProcessId})";
    public string LocalUrl => $"http://{(Address.Contains(':') ? "[" + Address + "]" : Address is "0.0.0.0" ? "127.0.0.1" : Address)}:{Port}";
}
