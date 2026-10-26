using System.Collections.ObjectModel;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed partial class ConsoleLog
{
    private readonly DispatcherQueue _dispatcher;
    private readonly object _fileLock = new();
    private StreamWriter? _fileWriter;
    private int _writtenBytes;
    private int _limit = 5000;

    public ConsoleLog(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public ObservableCollection<LogLine> Lines { get; } = [];
    public int Limit
    {
        get => _limit;
        set
        {
            _limit = Math.Max(1, value);
            void Trim() { while (Lines.Count > _limit) Lines.RemoveAt(0); }
            if (_dispatcher.HasThreadAccess) Trim(); else _dispatcher.TryEnqueue(Trim);
        }
    }
    public int FileSizeLimit { get; set; } = 20 * 1024 * 1024;
    public string PlainText => string.Join(Environment.NewLine, Lines.Select(line => line.Text));
    public string TimestampedText => string.Join(Environment.NewLine, Lines.Select(line => $"[{line.Date:HH:mm:ss}] {line.Text}"));

    /// <summary>Clears what the console shows; the log file on disk keeps everything.</summary>
    public void Clear()
    {
        if (_dispatcher.HasThreadAccess) Lines.Clear(); else _dispatcher.TryEnqueue(Lines.Clear);
    }
    public string? FilePath { get; private set; }
    public bool IsFileLogging { get { lock (_fileLock) return _fileWriter is not null; } }

    public void StartFileLogging(string name)
    {
        string? error = null;
        lock (_fileLock)
        {
            StopFileLoggingCore();
            try
            {
                var safeName = string.Join("-", name.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
                if (safeName.Length == 0) safeName = "server";
                if (safeName.Length > 100) safeName = safeName[..100];
                var path = Path.Combine(AppPaths.Logs, $"{safeName}_{DateTime.Now:yyyy-MM-dd_HH-mm-ss}_{Guid.NewGuid():N}.log");
                _fileWriter = new StreamWriter(new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read), Encoding.UTF8);
                FilePath = path;
                _writtenBytes = 0;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            { error = "Could not start file logging. Console output is still available. " + ex.Message; }
        }
        if (error is not null) AddLines(error, LogStream.Stderr);
    }

    public void StopFileLogging()
    {
        lock (_fileLock) StopFileLoggingCore();
    }

    private void StopFileLoggingCore()
    {
        var writer = _fileWriter;
        _fileWriter = null;
        try { writer?.Dispose(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { AddLines("Could not finish the log file: " + ex.Message, LogStream.Stderr); }
    }

    public void System(string text) => Append(text, LogStream.System);

    public void Append(string text, LogStream stream = LogStream.Stdout)
    {
        var cleaned = AnsiRegex().Replace(text, "");
        if (string.IsNullOrEmpty(cleaned))
        {
            return;
        }

        AddLines(cleaned, stream);
        WriteToFile(cleaned);
    }

    private void AddLines(string text, LogStream stream)
    {
        void Add()
        {
            foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
            {
                Lines.Add(new LogLine { Stream = stream, Text = line.Contains('\r') ? line.Split('\r').Last() : line });
            }

            while (Lines.Count > Limit)
            {
                Lines.RemoveAt(0);
            }
        }

        if (_dispatcher.HasThreadAccess)
        {
            Add();
        }
        else
        {
            _dispatcher.TryEnqueue(Add);
        }
    }

    private void WriteToFile(string text)
    {
        string? error = null;
        lock (_fileLock)
        {
            if (_fileWriter is null) return;
            try
            {
                var payload = text.EndsWith(Environment.NewLine, StringComparison.Ordinal) ? text : text + Environment.NewLine;
                var bytes = Encoding.UTF8.GetByteCount(payload);
                if ((long)_writtenBytes + bytes > FileSizeLimit)
                {
                    error = "Log file reached its limit; disk recording stopped. Console output is still available.";
                    StopFileLoggingCore();
                }
                else
                {
                    _fileWriter.Write(payload);
                    _fileWriter.Flush();
                    _writtenBytes += bytes;
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                StopFileLoggingCore();
                error = "File logging stopped. Console output is still available. " + ex.Message;
            }
        }
        if (error is not null) AddLines(error, LogStream.Stderr);
    }

    [GeneratedRegex(@"\x1B\[[0-?]*[ -/]*[@-~]")]
    private static partial Regex AnsiRegex();
}
