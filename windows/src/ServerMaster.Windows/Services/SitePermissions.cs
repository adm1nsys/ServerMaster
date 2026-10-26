namespace ServerMaster.Windows.Services;

public sealed record SitePermissionProblem(string Path, string Reason);

public sealed record SitePermissionReport(int CheckedCount, bool Truncated, IReadOnlyList<SitePermissionProblem> Problems);

public static class SitePermissions
{
    private static readonly string[] WritableFolders =
    [
        "administrator/cache", "administrator/logs", "cache", "images", "logs", "tmp",
        "media", "plugins", "templates", "modules", "wp-content", "wp-content/uploads",
        "storage", "bootstrap/cache"
    ];

    public static SitePermissionReport Check(string root, int limit = 4000)
    {
        var problems = new List<SitePermissionProblem>();
        if (!Directory.Exists(root))
            return new(0, false, [new(root, "Site folder does not exist.")]);

        var queue = new Queue<string>();
        queue.Enqueue(root);
        foreach (var relative in WritableFolders)
        {
            var path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            if (Directory.Exists(path)) queue.Enqueue(path);
        }

        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var checkedCount = 0;
        var truncated = false;
        while (queue.Count > 0)
        {
            if (checkedCount >= limit) { truncated = true; break; }
            var path = queue.Dequeue();
            if (!visited.Add(Path.GetFullPath(path))) continue;
            checkedCount++;
            try
            {
                var attributes = File.GetAttributes(path);
                if (attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                if (!attributes.HasFlag(FileAttributes.Directory))
                {
                    if (attributes.HasFlag(FileAttributes.ReadOnly))
                        problems.Add(new(path, "File is read-only."));
                    continue;
                }

                if (path == root || WritableFolders.Any(relative =>
                    path.Equals(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)), StringComparison.OrdinalIgnoreCase)))
                    ProbeWrite(path, problems);

                foreach (var child in Directory.EnumerateFileSystemEntries(path))
                {
                    if (Path.GetFileName(child).Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                    queue.Enqueue(child);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                problems.Add(new(path, ex is UnauthorizedAccessException ? "Access denied." : "Cannot inspect: " + ex.Message));
            }
        }
        return new(checkedCount, truncated, problems);
    }

    private static void ProbeWrite(string directory, List<SitePermissionProblem> problems)
    {
        var probe = Path.Combine(directory, ".servermaster-check-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1,
                FileOptions.DeleteOnClose);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            problems.Add(new(directory, "Cannot create and remove a file here: " + ex.Message));
        }
        finally
        {
            if (File.Exists(probe))
            {
                try { File.Delete(probe); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    problems.Add(new(directory, "Could not remove permission-check file: " + ex.Message));
                }
            }
        }
    }
}
