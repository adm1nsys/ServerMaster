using ServerMaster.Windows.Services;

namespace ServerMaster.Windows;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--server-host")
        {
            Environment.ExitCode = ElevatedServerHost.RunAsync(args[1], args.Contains("--test-host")).GetAwaiter().GetResult();
            return;
        }

        if (args.Length >= 1 && args[0] == ConsoleInterrupt.Argument)
        {
            Environment.ExitCode = ConsoleInterrupt.Run(args);
            return;
        }

        // An isolated test data folder is its own instance, so it can run beside the user's app.
        var instance = AppPaths.DataOverride is { } data
            ? @"Local\ServerMaster.Windows." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(data.ToUpperInvariant())))[..16]
            : @"Local\ServerMaster.Windows";
        if (!SingleInstance.TryClaim(instance)) return;
        try { XamlGeneratedProgram.XamlGeneratedMain(); }
        finally { SingleInstance.Release(); }
    }
}
