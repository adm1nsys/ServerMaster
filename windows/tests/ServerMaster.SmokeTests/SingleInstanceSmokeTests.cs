using System.Diagnostics;
using ServerMaster.Windows.Services;

internal static class SingleInstanceSmokeTests
{
    // A unique name keeps the test away from a ServerMaster instance the user may be running.
    public static async Task Run()
    {
        var name = @"Local\ServerMaster.SmokeTest." + Guid.NewGuid().ToString("N");
        Check(SingleInstance.TryClaim(name), "the first launch claims the instance");
        using var activated = new SemaphoreSlim(0);
        SingleInstance.Listen(() => activated.Release());
        Check(await LaunchAsync(name) == 0, "a second process does not start another instance");
        Check(await activated.WaitAsync(TimeSpan.FromSeconds(5)), "the second launch asks the running instance to show its window");
        Check(await LaunchAsync(name) == 0 && await activated.WaitAsync(TimeSpan.FromSeconds(5)), "every later launch reopens the running window");
        SingleInstance.Release();
        Check(await LaunchAsync(name) == 1, "a launch after quitting claims the instance again");
    }

    /// <summary>Child entry point: exit 1 when it claimed the instance, 0 when it signalled the owner.</summary>
    public static int Child(string name)
    {
        var claimed = SingleInstance.TryClaim(name);
        SingleInstance.Release();
        return claimed ? 1 : 0;
    }

    private static async Task<int> LaunchAsync(string name)
    {
        using var process = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, ["--single-instance-child", name]) { UseShellExecute = false })
            ?? throw new InvalidOperationException("Could not start the test process.");
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
        return process.ExitCode;
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Single instance: " + description);
    }
}
