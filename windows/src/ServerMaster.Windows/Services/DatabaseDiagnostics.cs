using System.Globalization;
using System.Text;

namespace ServerMaster.Windows.Services;

public static class DatabaseDiagnostics
{
    public static IReadOnlyList<DiagnosticFinding> Check(DatabaseRuntimeStatus status, string root)
    {
        if (!status.Installed)
            return [new("Database", "MariaDB is not installed", "Sites that need a database cannot use it yet.", "Install MariaDB from Dependencies.", Severity: DiagnosticLevel.Note)];
        var findings = new List<DiagnosticFinding>
        {
            new("Database", "MariaDB", status.Running ? $"Running on 127.0.0.1:{DatabaseService.Port}; PID {status.ProcessId}; {status.Version}" : "Installed but stopped.",
                Severity: status.Running ? DiagnosticLevel.Fine : DiagnosticLevel.Note)
        };
        var data = Path.Combine(root, "data");
        try
        {
            if (!Directory.Exists(data) && !File.Exists(data))
                findings.Add(new("Database", "Not prepared yet", "The data directory will be prepared on the first start: " + data, Severity: DiagnosticLevel.Note));
            else if (Directory.Exists(Path.Combine(data, "mysql")))
                findings.Add(new("Database", "System tables", "The MariaDB system schema exists: " + data));
            else if (Directory.Exists(data) && !Directory.EnumerateFileSystemEntries(data).Any())
                findings.Add(new("Database", "Not prepared yet", "The data directory is empty. Start MariaDB to prepare it.", Severity: DiagnosticLevel.Note));
            else
                findings.Add(new("Database", "The data directory is incomplete", data + " has no MariaDB system schema.",
                    "Do not delete existing data. Back up this folder before repairing initialization in Database.", Severity: DiagnosticLevel.Broken));
            var log = Path.Combine(root, "error.log");
            if (File.Exists(log))
            {
                // Logs may grow indefinitely; only inspect the last 64 KiB, sharing with the running server.
                using var file = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var offset = Math.Max(0, file.Length - 65536);
                file.Seek(offset, SeekOrigin.Begin);
                using var reader = new StreamReader(file, Encoding.UTF8);
                if (offset > 0) reader.ReadLine();
                if (LogFinding(reader.ReadToEnd(), status.Running, DateTime.Now) is { } finding) findings.Add(finding);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            findings.Add(new("Database", "Data directory and log", "Could not inspect database files: " + ex.Message,
                "Check folder access in Database. Existing data has not been changed.", Severity: DiagnosticLevel.Warning));
        }
        return findings;
    }

    internal static DiagnosticFinding? LogFinding(string text, bool running, DateTime now)
    {
        var errors = text.Split('\n').Where(line => line.Contains("[ERROR]", StringComparison.OrdinalIgnoreCase)).TakeLast(3).Select(line => line.TrimEnd('\r')).ToArray();
        if (errors.Length == 0) return null;
        var last = errors[^1];
        var known = last.Length >= 19 && DateTime.TryParseExact(last[..19], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);
        var written = known ? DateTime.ParseExact(last[..19], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) : DateTime.MinValue;
        var recent = known && now >= written && now - written < TimeSpan.FromMinutes(10);
        return new("Database", "Errors in the database log", string.Join(Environment.NewLine, errors),
            running ? "MariaDB is running now. These logged errors do not show that it is currently broken."
                : recent ? "Recent errors may explain why MariaDB did not start. Check Database logs before retrying."
                : "These errors are old or have an unknown timestamp; they do not explain the current stopped state by themselves.",
            Severity: !running && recent ? DiagnosticLevel.Warning : DiagnosticLevel.Note);
    }
}
