using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ServerMaster.Windows.Services;

/// <summary>
/// Ctrl+C for a terminal tab, the Windows counterpart of the Mac PTY interrupt. A console
/// control event only reaches processes on the same console, and the app has none, so a short
/// helper launch of ServerMaster attaches to the shell's hidden console and raises it there.
/// The shell and the command it runs receive it; the app and other servers do not.
/// </summary>
public static class ConsoleInterrupt
{
    public const string Argument = "--console-interrupt";

    /// <summary>The executable that hosts the helper mode. Tests point it at their own runner.</summary>
    public static string? HelperPath { get; set; }

    public static async Task<bool> SendAsync(int processId)
    {
        var path = HelperPath ?? Environment.ProcessPath ?? throw new InvalidOperationException("Cannot find ServerMaster.exe.");
        using var helper = Process.Start(new ProcessStartInfo(path, [Argument, processId.ToString()])
        {
            UseShellExecute = false, CreateNoWindow = true
        }) ?? throw new InvalidOperationException("Windows could not start the interrupt helper.");
        try { await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); }
        catch (TimeoutException) { helper.Kill(); return false; }
        return helper.ExitCode == 0;
    }

    /// <summary>Helper entry point: exit 0 when the event was raised on the target's console.</summary>
    public static int Run(string[] args)
    {
        if (args.Length < 2 || !int.TryParse(args[1], out var processId)) return 2;
        FreeConsole();
        if (!AttachConsole((uint)processId)) return 3;
        try
        {
            // Ignore the event in this helper so it can report the result.
            SetConsoleCtrlHandler(IntPtr.Zero, true);
            return GenerateConsoleCtrlEvent(0, 0) ? 0 : 4;
        }
        finally { FreeConsole(); }
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint controlEvent, uint processGroupId);
}
