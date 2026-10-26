using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace ServerMaster.Windows.Services;

public sealed partial class TerminalSession : IDisposable
{
    private const string CommandFinished = "__SERVERMASTER_COMMAND_FINISHED__";
    private Process? _process;
    private bool _disposed;
    private readonly List<string> _history = [];
    private int? _historyIndex;
    private string _historyDraft = "";
    public string ShellKind { get; }
    public string WorkingDirectory { get; }
    public event Action<string>? Output;
    public bool IsRunning => _process is { HasExited: false };

    public TerminalSession(string shellKind, string workingDirectory)
    {
        ShellKind = shellKind;
        WorkingDirectory = Directory.Exists(workingDirectory) ? workingDirectory : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    public void Start()
    {
        if (_disposed || IsRunning) return;
        var powershell = ShellKind.Equals("PowerShell", StringComparison.OrdinalIgnoreCase);
        var info = new ProcessStartInfo(powershell ? "powershell.exe" : "cmd.exe")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            // Read bytes as Latin-1 (one char per byte) and decode each line in ConsoleText.
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.Latin1, StandardErrorEncoding = Encoding.Latin1,
            WorkingDirectory = WorkingDirectory,
            Arguments = powershell
                ? "-NoLogo -NoExit -ExecutionPolicy Bypass -Command \"chcp 65001 | Out-Null; $utf8=[Text.UTF8Encoding]::new($false); $OutputEncoding=$utf8; [Console]::OutputEncoding=$utf8\""
                : "/D /Q /K \"chcp 65001>nul\""
        };
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor()) info.Environment[pair.Key] = pair.Value;
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => HandleOutput(e.Data);
        process.ErrorDataReceived += (_, e) => HandleOutput(e.Data);
        process.Exited += (_, _) => Output?.Invoke(Environment.NewLine + $"[{ShellKind} stopped]" + Environment.NewLine);
        if (!process.Start()) throw new InvalidOperationException("Windows could not start the shell.");
        OwnedProcesses.Track(process);
        _process = process;
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
        Output?.Invoke($"ServerMaster {ShellKind}{Environment.NewLine}{WorkingDirectory}{Environment.NewLine}> ");
    }

    public void WriteLine(string command)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(TerminalSession));
        if (!IsRunning) Start();
        var remembered = command.Trim();
        if (remembered.Length > 0)
        {
            _history.RemoveAll(item => item == remembered);
            _history.Add(remembered);
            if (_history.Count > 200) _history.RemoveRange(0, _history.Count - 200);
        }
        _historyIndex = null;
        _historyDraft = "";
        var powershell = ShellKind.Equals("PowerShell", StringComparison.OrdinalIgnoreCase);
        var wrapped = powershell
            ? $"& {{ {command} }}; Write-Output '{CommandFinished}'"
            : $"{command} & echo {CommandFinished}";
        _process!.StandardInput.WriteLine(wrapped);
        _process.StandardInput.Flush();
    }

    public string? PreviousCommand(string current)
    {
        if (_history.Count == 0) return null;
        if (_historyIndex is null)
        {
            _historyDraft = current;
            _historyIndex = _history.Count - 1;
        }
        else _historyIndex = Math.Max(0, _historyIndex.Value - 1);
        return _history[_historyIndex.Value];
    }

    public string? NextCommand()
    {
        if (_historyIndex is null || _history.Count == 0) return null;
        var next = _historyIndex.Value + 1;
        if (next >= _history.Count)
        {
            _historyIndex = null;
            return _historyDraft;
        }
        _historyIndex = next;
        return _history[next];
    }

    private void HandleOutput(string? raw)
    {
        if (raw is null) return;
        var line = ConsoleText.Decode(raw);
        if (line.Trim().Equals(CommandFinished, StringComparison.Ordinal)) Output?.Invoke("> ");
        // After Ctrl+C PowerShell starts echoing its own prompt and each wrapped command line;
        // neither is output of the user's command.
        else if (line.Contains(CommandFinished, StringComparison.Ordinal) || PowerShellPrompt().IsMatch(line)) return;
        else Output?.Invoke(line + Environment.NewLine);
    }

    public void Stop()
    {
        var process = _process; _process = null;
        if (process is null) return;
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        finally { process.Dispose(); }
    }

    /// <summary>Sends Ctrl+C to the shell's console, stopping the command it is running.</summary>
    public Task<bool> InterruptAsync() =>
        _process is { HasExited: false } process ? ConsoleInterrupt.SendAsync(process.Id) : Task.FromResult(false);

    public void Restart() { Stop(); Start(); }
    public void Dispose() { _disposed = true; Stop(); }

    [GeneratedRegex(@"^PS [^>]*>\s*$")]
    private static partial Regex PowerShellPrompt();
}

/// <summary>
/// Shells run with code page 65001, but older console tools may still write the OEM code page.
/// Each line is read as raw bytes and decoded as UTF-8 when it is valid UTF-8, otherwise in the
/// system OEM code page, so such output does not turn into replacement characters. (A tool that
/// itself writes "?" under 65001, like ping's Ctrl+C summary on a Russian Windows, stays as it is.)
/// </summary>
public static class ConsoleText
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, throwOnInvalidBytes: true);
    private static readonly Lazy<Encoding> Oem = new(() =>
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        try { return Encoding.GetEncoding((int)GetOEMCP()); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException) { return Encoding.UTF8; }
    });

    /// <param name="latin1Line">A line read with <see cref="Encoding.Latin1"/>, so each char is one byte.</param>
    public static string Decode(string latin1Line, Encoding? fallback = null)
    {
        if (latin1Line.All(c => c < 0x80)) return latin1Line;
        var bytes = Encoding.Latin1.GetBytes(latin1Line);
        try { return StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException) { return (fallback ?? Oem.Value).GetString(bytes); }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern uint GetOEMCP();
}
