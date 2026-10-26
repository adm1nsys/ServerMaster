using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace ServerMaster.Windows.Services;

public sealed record ServerHostMessage(string Kind, string Text = "", int ProcessId = 0);

public static class ElevatedServerHost
{
    public static async Task<int> RunAsync(string pipeName, bool testMode = false)
    {
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try { await pipe.ConnectAsync(15000); }
        catch (TimeoutException) { return 2; }

        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        using var writeLock = new SemaphoreSlim(1, 1);

        async Task SendAsync(ServerHostMessage message)
        {
            await writeLock.WaitAsync();
            try { await writer.WriteLineAsync(JsonSerializer.Serialize(message)); }
            finally { writeLock.Release(); }
        }

        if (!testMode && !WindowsElevation.IsElevated)
        {
            await SendAsync(new("error", "The server helper did not receive administrator rights."));
            return 3;
        }

        Process? child = null;
        IDisposable? group = null;
        try
        {
            var request = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15));
            var plan = JsonSerializer.Deserialize<LaunchPlan>(request ?? "")
                ?? throw new InvalidOperationException("The server launch request was empty.");
            var info = new ProcessStartInfo(plan.Executable)
            {
                WorkingDirectory = plan.WorkingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            foreach (var argument in plan.Arguments) info.ArgumentList.Add(argument);
            info.Environment.Clear();
            foreach (var (key, value) in plan.Environment) info.Environment[key] = value;
            child = Process.Start(info) ?? throw new InvalidOperationException("Windows did not start the server process.");
            group = OwnedProcesses.CreateGroup(child);
            await SendAsync(new("ready", ProcessId: child.Id));

            async Task ForwardAsync(StreamReader source, string kind)
            {
                try
                {
                    while (await source.ReadLineAsync() is { } line)
                        await SendAsync(new(kind, line));
                }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
            }

            var output = ForwardAsync(child.StandardOutput, "stdout");
            var error = ForwardAsync(child.StandardError, "stderr");
            var command = reader.ReadLineAsync();
            var exited = child.WaitForExitAsync();
            if (await Task.WhenAny(command, exited) == exited)
            {
                await Task.WhenAll(output, error);
                await SendAsync(new("exit", ProcessId: child.ExitCode));
                return child.ExitCode;
            }

            // A closed pipe means the UI process died; closing the job also stops descendants.
            return 0;
        }
        catch (Exception ex)
        {
            try { await SendAsync(new("error", ex.Message)); }
            catch (IOException) { }
            return 4;
        }
        finally
        {
            group?.Dispose();
            if (child is { HasExited: false })
            {
                try { child.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            }
            child?.Dispose();
        }
    }
}
