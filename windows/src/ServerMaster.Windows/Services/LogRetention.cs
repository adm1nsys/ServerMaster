namespace ServerMaster.Windows.Services;

public sealed record LogCleanupResult(int Removed, IReadOnlyList<string> Problems);

public static class LogRetention
{
    public static LogCleanupResult Clean(string directory, int days, IEnumerable<string> activePaths, DateTimeOffset? now = null)
    {
        if (days <= 0 || !Directory.Exists(directory)) return new(0, []);
        var active = activePaths.Select(Path.GetFullPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var cutoff = (now ?? DateTimeOffset.UtcNow).UtcDateTime.AddDays(-Math.Min(days, 36500));
        var removed = 0;
        var problems = new List<string>();
        try
        {
            foreach (var path in Directory.EnumerateFiles(directory, "*.log", SearchOption.TopDirectoryOnly))
            {
                if (active.Contains(Path.GetFullPath(path))) continue;
                try
                {
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || File.GetLastWriteTimeUtc(path) >= cutoff) continue;
                    File.Delete(path);
                    removed++;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                { if (problems.Count < 5) problems.Add(Path.GetFileName(path) + ": " + ex.Message); }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { problems.Add(ex.Message); }
        return new(removed, problems);
    }
}
