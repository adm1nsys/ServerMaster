using System.Text;
using ServerMaster.Windows.Services;

internal static class TerminalInterruptSmokeTests
{
    // Real CMD and PowerShell sessions in a temporary folder; nothing outside it is touched.
    public static async Task Run()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var cp866 = Encoding.GetEncoding(866);
        string AsRead(byte[] bytes) => Encoding.Latin1.GetString(bytes);
        if (ConsoleText.Decode(AsRead(Encoding.UTF8.GetBytes("Пакетов: отправлено = 3")), cp866) != "Пакетов: отправлено = 3" ||
            ConsoleText.Decode(AsRead(cp866.GetBytes("Статистика Ping для 127.0.0.1:")), cp866) != "Статистика Ping для 127.0.0.1:" ||
            ConsoleText.Decode("plain ascii", cp866) != "plain ascii")
            throw new Exception("terminal output decodes UTF-8 lines as UTF-8 and OEM-only lines in the OEM code page");
        Console.WriteLine("PASS Terminal: UTF-8 and OEM code page output both decode without question marks");
        ConsoleInterrupt.HelperPath = Environment.ProcessPath;
        var folder = Directory.CreateTempSubdirectory("ServerMaster-interrupt-").FullName;
        try
        {
            await Check("CMD", "ping -n 60 127.0.0.1", folder);
            await Check("PowerShell", "Start-Sleep -Seconds 60", folder);
        }
        finally { Directory.Delete(folder, true); }
    }

    private static async Task Check(string shell, string longCommand, string folder)
    {
        var output = new StringBuilder();
        using var session = new TerminalSession(shell, folder);
        session.Output += text => { lock (output) output.Append(text); };
        session.Start();
        await WaitFor(() => Text(output).Contains("> "), "the shell prompt appears", shell);
        session.WriteLine("echo ready-1");
        await WaitFor(() => Text(output).Contains("ready-1"), "a command runs", shell);
        session.WriteLine(longCommand);
        await Task.Delay(1500);
        var before = Text(output).Length;
        var started = DateTime.UtcNow;
        Assert(await session.InterruptAsync(), "Ctrl+C reaches the shell console", shell);
        session.WriteLine("echo after-interrupt");
        await WaitFor(() => Text(output)[before..].Contains("after-interrupt"), "the shell accepts the next command after Ctrl+C", shell, 15);
        Assert(DateTime.UtcNow - started < TimeSpan.FromSeconds(20) && session.IsRunning, "the long command stopped early and the shell stayed open", shell);
        session.WriteLine("echo second-after");
        await WaitFor(() => Text(output)[before..].Contains("second-after"), "later commands keep working", shell);
        await Task.Delay(500);
        var tail = Text(output)[before..];
        Assert(!tail.Contains("__SERVERMASTER_COMMAND_FINISHED__") && !tail.Split('\n').Any(line => line.TrimStart().StartsWith("PS ") && line.TrimEnd().EndsWith('>')),
            "the command wrapper and shell prompt are not shown after Ctrl+C", shell);
        Assert(!Text(output).Contains('\uFFFD'), "the output has no undecodable characters, including the Ctrl+C summary", shell);
    }

    private static string Text(StringBuilder output) { lock (output) return output.ToString(); }

    private static async Task WaitFor(Func<bool> condition, string description, string shell, int seconds = 10)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < deadline) { if (condition()) { Assert(true, description, shell); return; } await Task.Delay(100); }
        Assert(false, description, shell);
    }

    private static void Assert(bool condition, string description, string shell)
    {
        if (!condition) throw new Exception($"{shell}: {description}");
        Console.WriteLine($"PASS Terminal interrupt ({shell}): {description}");
    }
}
