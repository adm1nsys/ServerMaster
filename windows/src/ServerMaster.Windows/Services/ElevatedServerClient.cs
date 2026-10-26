using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class ElevatedServerClient
{
    private NamedPipeServerStream? _pipe;
    private Process? _helper;
    private StreamReader? _reader;
    private StreamWriter? _writer;
    private bool _stopping;

    public Process HelperProcess => _helper ?? throw new InvalidOperationException("The server helper has not started.");
    public int ServerProcessId { get; private set; }
    public bool IsAlive => _helper is { HasExited: false };
    public string LastError { get; private set; } = "";
    public string? HostPath { get; set; }
    public event Action<string, LogStream>? Output;
    public event Action<int>? Exited;

    public async Task StartAsync(LaunchPlan plan, CancellationToken cancellationToken, bool testMode = false)
    {
        var name = "ServerMaster-" + Guid.NewGuid().ToString("N");
        _pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var path = HostPath ?? Environment.ProcessPath ?? throw new InvalidOperationException("Cannot find ServerMaster.exe.");
        var info = new ProcessStartInfo(path) { UseShellExecute = true, Verb = testMode ? "" : "runas", WindowStyle = ProcessWindowStyle.Hidden };
        info.ArgumentList.Add("--server-host");
        info.ArgumentList.Add(name);
        if (testMode) info.ArgumentList.Add("--test-host");
        try
        {
            _helper = Process.Start(info) ?? throw new InvalidOperationException("Windows did not launch the server helper.");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            await _pipe.WaitForConnectionAsync(timeout.Token);
            if (!GetNamedPipeClientProcessId(_pipe.SafePipeHandle, out var connectedPid) || connectedPid != _helper.Id)
                throw new InvalidOperationException("The administrator helper could not be verified. The server was not started.");
            _reader = new StreamReader(_pipe, Encoding.UTF8, leaveOpen: true);
            _writer = new StreamWriter(_pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            var fullPlan = new LaunchPlan
            {
                Executable = plan.Executable,
                Arguments = plan.Arguments,
                WorkingDirectory = plan.WorkingDirectory,
                Environment = ShellEnvironment.Shared.EnvironmentFor(plan.Environment)
            };
            await _writer.WriteLineAsync(JsonSerializer.Serialize(fullPlan));
            var first = await _reader.ReadLineAsync().WaitAsync(timeout.Token);
            var message = JsonSerializer.Deserialize<ServerHostMessage>(first ?? "")
                ?? throw new InvalidOperationException("The administrator helper closed without a response.");
            if (message.Kind == "error") throw new InvalidOperationException(message.Text);
            if (message.Kind != "ready" || message.ProcessId <= 0)
                throw new InvalidOperationException("The administrator helper did not start the server.");
            ServerProcessId = message.ProcessId;
            _helper.EnableRaisingEvents = true;
            _helper.Exited += (_, _) => { if (!_stopping) Exited?.Invoke(_helper.ExitCode); };
            _ = ReadMessagesAsync();
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            await StopAsync();
            throw new InvalidOperationException("Administrator permission was cancelled. The profile was not started.", ex);
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            await StopAsync();
            throw new InvalidOperationException("The administrator helper did not connect. Use the current Windows account when approving UAC, then try again.", ex);
        }
        catch
        {
            await StopAsync();
            throw;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out int processId);

    private async Task ReadMessagesAsync()
    {
        try
        {
            while (_reader is not null && await _reader.ReadLineAsync() is { } line)
            {
                var message = JsonSerializer.Deserialize<ServerHostMessage>(line);
                if (message is null) continue;
                if (message.Kind == "stdout") Output?.Invoke(message.Text, LogStream.Stdout);
                else if (message.Kind == "stderr") Output?.Invoke(message.Text, LogStream.Stderr);
                else if (message.Kind == "error") { LastError = message.Text; Output?.Invoke(message.Text, LogStream.Stderr); }
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public async Task StopAsync()
    {
        _stopping = true;
        if (_writer is not null)
        {
            try { await _writer.WriteLineAsync("stop"); }
            catch (IOException) { _pipe?.Dispose(); }
            catch (ObjectDisposedException) { _pipe?.Dispose(); }
        }
        else _pipe?.Dispose();
        if (_helper is { HasExited: false } helper)
        {
            try { await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
            catch (TimeoutException)
            {
                try { helper.Kill(entireProcessTree: true); }
                catch (Win32Exception ex) { throw new InvalidOperationException("The administrator helper did not stop. Approve Windows permission or stop it in Task Manager. " + ex.Message, ex); }
                await helper.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
        try { _writer?.Dispose(); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        try { _reader?.Dispose(); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        _pipe?.Dispose();
        _helper?.Dispose();
        _reader = null;
        _writer = null;
        _helper = null;
        _pipe = null;
    }
}
