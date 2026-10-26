using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace ServerMaster.Windows.Services;

public static class AppDataDiagnostics
{
    public static async Task<IReadOnlyList<DiagnosticFinding>> CheckAsync(string support)
    {
        var findings = new List<DiagnosticFinding>();
        foreach (var (name, fileName, expected) in new[] { ("Profiles", "profiles.json", JsonValueKind.Array), ("Settings", "settings.json", JsonValueKind.Object) })
        {
            var path = Path.Combine(support, fileName);
            try
            {
                using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous);
                if (file.Length > 4 * 1024 * 1024) throw new IOException("The configuration file exceeds the 4 MB inspection limit.");
                using var json = await JsonDocument.ParseAsync(file);
                if (json.RootElement.ValueKind != expected) throw new JsonException("Unexpected configuration structure.");
                findings.Add(new("App data", name, $"{path}: valid JSON."));
            }
            catch (FileNotFoundException) { findings.Add(new("App data", name, "No saved file yet: " + path, Severity: DiagnosticLevel.Note)); }
            catch (DirectoryNotFoundException) { findings.Add(new("App data", name, "No saved folder yet: " + support, Severity: DiagnosticLevel.Note)); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
            {
                findings.Add(new("App data", name, ex.Message, "Back up this file before repairing it. Diagnostics has not replaced it.", Severity: DiagnosticLevel.Broken));
            }
        }
        var probe = Path.Combine(support, ".diagnostics-" + Guid.NewGuid().ToString("N") + ".tmp");
        var created = false;
        try
        {
            var payload = RandomNumberGenerator.GetBytes(512 * 1024);
            var timer = Stopwatch.StartNew();
            await using (var file = new FileStream(probe, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.DeleteOnClose))
            {
                created = true;
                await file.WriteAsync(payload);
                await file.FlushAsync();
                file.Position = 0;
                var read = new byte[payload.Length];
                await file.ReadExactlyAsync(read);
                if (!payload.AsSpan().SequenceEqual(read)) throw new IOException("The data read back does not match the write.");
            }
            findings.Add(new("App data", "Write test", $"512 KB written and read back in {timer.ElapsedMilliseconds} ms.",
                timer.Elapsed > TimeSpan.FromSeconds(2) ? "Storage or antivirus scanning is slowing writes to the app's folder." : "",
                Severity: timer.Elapsed > TimeSpan.FromSeconds(2) ? DiagnosticLevel.Warning : DiagnosticLevel.Fine));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            findings.Add(new("App data", "Write test", ex.Message, "The application cannot reliably save its data. Check free space and access to this folder: " + support, Severity: DiagnosticLevel.Broken));
        }
        finally
        {
            if (created && File.Exists(probe))
            {
                try { File.Delete(probe); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                { findings.Add(new("App data", "Probe cleanup", ex.Message, "Remove only the temporary diagnostic file: " + probe, Severity: DiagnosticLevel.Warning)); }
            }
        }
        return findings;
    }
}
