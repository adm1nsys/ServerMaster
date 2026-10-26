using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class ProfileSnapshots
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static IReadOnlyList<BackupEntry> Load(string destination)
    {
        var index = Path.Combine(destination, "snapshots.json");
        if (!File.Exists(index)) return [];
        try
        {
            return (JsonSerializer.Deserialize<List<BackupEntry>>(File.ReadAllText(index), Json) ?? [])
                .Where(item => ValidSnapshotId(item.Id) && Directory.Exists(Path.Combine(destination, item.Id))
                    && !new DirectoryInfo(Path.Combine(destination, item.Id)).Attributes.HasFlag(FileAttributes.ReparsePoint))
                .Select(item => CopyWithPath(item, Path.Combine(destination, item.Id)))
                .OrderByDescending(item => item.Taken).ToArray();
        }
        catch (JsonException) { return []; }
    }

    public static async Task<BackupEntry> CreateProfileAsync(ServerProfile profile, string destination, bool includeDatabase, string trigger = "manual")
    {
        if (Directory.Exists(profile.ExpandedRootPath) && SiteFiles.IsWithin(profile.ExpandedRootPath, destination))
            throw new IOException("The snapshot folder must be outside the profile folder.");
        Directory.CreateDirectory(destination);
        var id = MakeId(profile.Name, false);
        var folder = Path.Combine(destination, id);
        Directory.CreateDirectory(folder);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(folder, "profile.json"), JsonSerializer.Serialize(profile, Json));
            var includesSite = Directory.Exists(profile.ExpandedRootPath);
            if (includesSite) await CreateArchiveAsync(profile.ExpandedRootPath, Path.Combine(folder, "site.zip"));
            var includesDatabase = false;
            string? note = null;
            if (includeDatabase && !string.IsNullOrWhiteSpace(profile.DatabaseName))
            {
                if (DatabaseService.Detect().Running)
                {
                    await DatabaseService.DumpDatabaseAsync(profile.DatabaseName, Path.Combine(folder, "database.sql"));
                    includesDatabase = true;
                }
                else note = "Database not included: MariaDB was stopped.";
            }
            var entry = new BackupEntry
            {
                Id = id, Kind = "profile", ProfileId = profile.Id, ProfileName = profile.Name,
                Taken = DateTime.UtcNow, Trigger = trigger, IncludesSite = includesSite,
                IncludesDatabase = includesDatabase, DatabaseName = includesDatabase ? profile.DatabaseName : null,
                Bytes = DirectorySize(folder), Note = note, FullPath = folder
            };
            WriteAdded(destination, entry);
            return entry;
        }
        catch { if (Directory.Exists(folder)) Directory.Delete(folder, true); throw; }
    }

    public static async Task<BackupEntry> CreateDatabaseAsync(string name, string destination, string trigger = "manual")
    {
        Directory.CreateDirectory(destination);
        var id = MakeId(name, true);
        var folder = Path.Combine(destination, id);
        Directory.CreateDirectory(folder);
        try
        {
            await DatabaseService.DumpDatabaseAsync(name, Path.Combine(folder, "database.sql"));
            var entry = new BackupEntry { Id = id, Kind = "database", ProfileName = name, Taken = DateTime.UtcNow, Trigger = trigger, IncludesDatabase = true, DatabaseName = name, Bytes = DirectorySize(folder), FullPath = folder };
            WriteAdded(destination, entry);
            return entry;
        }
        catch { if (Directory.Exists(folder)) Directory.Delete(folder, true); throw; }
    }

    public static ServerProfile ReadProfile(BackupEntry snapshot)
    {
        var path = Path.Combine(snapshot.FullPath, "profile.json");
        return JsonSerializer.Deserialize<ServerProfile>(File.ReadAllText(path), Json)
            ?? throw new InvalidDataException("The saved profile settings could not be read.");
    }

    public static Task<string?> RestoreSiteAsync(BackupEntry snapshot, string destination) =>
        RestoreAsync(Path.Combine(snapshot.FullPath, "site.zip"), destination);

    public static Task RestoreDatabaseAsync(BackupEntry snapshot) =>
        DatabaseService.LoadDatabaseAsync(snapshot.DatabaseName ?? throw new InvalidDataException("The snapshot has no database name."), Path.Combine(snapshot.FullPath, "database.sql"));

    public static void Delete(string destination, BackupEntry snapshot)
    {
        if (!ValidSnapshotId(snapshot.Id)) throw new IOException("The snapshot identifier is invalid.");
        var expected = Path.GetFullPath(Path.Combine(destination, snapshot.Id));
        if (!Path.GetFullPath(snapshot.FullPath).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The snapshot is outside the backup folder.");
        if (Directory.Exists(expected))
        {
            if (new DirectoryInfo(expected).Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new IOException("Linked snapshot folders cannot be deleted.");
            Directory.Delete(expected, true);
        }
        WriteIndex(destination, Load(destination).Where(item => item.Id != snapshot.Id));
    }

    public static void PruneScheduled(string destination, int keepPerItem)
    {
        var all = Load(destination).ToList();
        var remove = all.Where(item => item.Trigger == "scheduled")
            .GroupBy(item => item.Kind == "database" ? "database:" + item.DatabaseName : "profile:" + item.ProfileId)
            .SelectMany(group => group.OrderByDescending(item => item.Taken).Skip(Math.Max(1, keepPerItem))).ToArray();
        foreach (var item in remove) if (Directory.Exists(item.FullPath)) Directory.Delete(item.FullPath, true);
        if (remove.Length > 0) WriteIndex(destination, all.Except(remove));
    }

    public static Task<string?> RestoreAsync(string archivePath, string destination) => Task.Run(() =>
    {
        destination = Path.TrimEndingDirectorySeparator(Path.GetFullPath(destination));
        var parent = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(parent) || destination.Equals(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase))
            throw new IOException("Choose a project folder, not a drive or your home directory.");
        if (SiteFiles.IsWithin(destination, Path.GetFullPath(archivePath))) throw new IOException("The archive must be outside the folder being restored.");
        for (var current = new DirectoryInfo(destination); current is not null; current = current.Parent)
            if (current.Exists && current.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Restore does not support linked destination folders.");
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, ".servermaster-restore-" + Guid.NewGuid().ToString("N"));
        var previous = destination + ".before-restore-" + Guid.NewGuid().ToString("N")[..8];
        Directory.CreateDirectory(staging);
        try
        {
            using (var archive = ZipFile.OpenRead(archivePath))
            {
                if (archive.Entries.Count == 0) throw new IOException("The snapshot is empty.");
                long total = 0;
                foreach (var entry in archive.Entries)
                {
                    total = checked(total + entry.Length);
                    if (total > 10L * 1024 * 1024 * 1024 || archive.Entries.Count > 200000) throw new IOException("The snapshot exceeds the restore limit (10 GB / 200,000 entries).");
                    var parts = entry.FullName.Replace('\\', '/').TrimEnd('/').Split('/');
                    if (parts.Any(part => string.IsNullOrWhiteSpace(part) || part is "." or ".." || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.EndsWith('.') || part.EndsWith(' ')))
                        throw new IOException("The snapshot contains an unsafe filename: " + entry.FullName);
                    if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new IOException("Symbolic links cannot be restored.");
                    var path = Path.GetFullPath(Path.Combine(staging, Path.Combine(parts)));
                    if (!SiteFiles.IsWithin(staging, path)) throw new IOException("Snapshot entry escapes the project folder.");
                    if (entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\')) Directory.CreateDirectory(path);
                    else { Directory.CreateDirectory(Path.GetDirectoryName(path)!); entry.ExtractToFile(path, false); }
                }
            }
            var existed = Directory.Exists(destination);
            if (existed) Directory.Move(destination, previous);
            try { Directory.Move(staging, destination); }
            catch { if (existed && !Directory.Exists(destination)) Directory.Move(previous, destination); throw; }
            return existed ? previous : null;
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    });

    public static Task<string> CreateAsync(string name, string root, string destinationFolder) => Task.Run(() =>
    {
        root = Path.GetFullPath(root);
        destinationFolder = Path.GetFullPath(destinationFolder);
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException("The profile folder does not exist: " + root);
        if (SiteFiles.IsWithin(root, destinationFolder)) throw new IOException("The snapshot folder must be outside the profile folder.");
        Directory.CreateDirectory(destinationFolder);
        var safeName = string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        if (string.IsNullOrWhiteSpace(safeName)) safeName = "profile";
        var id = Guid.NewGuid().ToString("N");
        var destination = Path.Combine(destinationFolder, $"{safeName}-{DateTime.Now:yyyyMMdd-HHmmss}-{id[..8]}.zip");
        var temporary = Path.Combine(destinationFolder, id + ".partial");
        try
        {
            using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
            {
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = 0 };
                foreach (var item in new DirectoryInfo(root).EnumerateFileSystemInfos("*", options))
                {
                    if (item.Attributes.HasFlag(FileAttributes.ReparsePoint))
                        throw new IOException("Snapshot contains a linked file or folder: " + item.FullName + ". Copy its contents into the profile before taking a snapshot.");
                    if (item is FileInfo && SiteFiles.IsEditorTemporary(item.Name)) continue; // interrupted editor save
                    var relative = Path.GetRelativePath(root, item.FullName).Replace('\\', '/');
                    if (item is DirectoryInfo) archive.CreateEntry(relative + "/");
                    else archive.CreateEntryFromFile(item.FullName, relative);
                }
            }
            File.Move(temporary, destination);
            return destination;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    });

    private static Task CreateArchiveAsync(string root, string destination) => Task.Run(() =>
    {
        root = Path.GetFullPath(root);
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException("The profile folder does not exist: " + root);
        var temporary = destination + ".partial";
        try
        {
            using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
            {
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = 0 };
                foreach (var item in new DirectoryInfo(root).EnumerateFileSystemInfos("*", options))
                {
                    if (item.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Snapshot contains a linked file or folder: " + item.FullName);
                    if (item is FileInfo && SiteFiles.IsEditorTemporary(item.Name)) continue; // interrupted editor save
                    var relative = Path.GetRelativePath(root, item.FullName).Replace('\\', '/');
                    if (item is DirectoryInfo) archive.CreateEntry(relative + "/");
                    else archive.CreateEntryFromFile(item.FullName, relative);
                }
            }
            File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    });

    private static void WriteAdded(string destination, BackupEntry entry) => WriteIndex(destination, new[] { entry }.Concat(Load(destination)));

    private static void WriteIndex(string destination, IEnumerable<BackupEntry> entries)
    {
        Directory.CreateDirectory(destination);
        var path = Path.Combine(destination, "snapshots.json");
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(entries.Select(item => new BackupEntry
        {
            Id = item.Id, Kind = item.Kind, ProfileId = item.ProfileId, ProfileName = item.ProfileName,
            Taken = item.Taken, Trigger = item.Trigger, IncludesSite = item.IncludesSite,
            IncludesDatabase = item.IncludesDatabase, DatabaseName = item.DatabaseName,
            Bytes = item.Bytes, Note = item.Note
        }).ToArray(), Json));
        File.Move(temporary, path, true);
    }

    private static BackupEntry CopyWithPath(BackupEntry item, string path) => new()
    {
        Id = item.Id, Kind = item.Kind, ProfileId = item.ProfileId, ProfileName = item.ProfileName,
        Taken = item.Taken, Trigger = item.Trigger, IncludesSite = item.IncludesSite,
        IncludesDatabase = item.IncludesDatabase, DatabaseName = item.DatabaseName, Bytes = item.Bytes,
        Note = item.Note, FullPath = path
    };

    private static bool ValidSnapshotId(string? id) => !string.IsNullOrWhiteSpace(id)
        && id is not "." and not ".."
        && id.IndexOfAny(Path.GetInvalidFileNameChars()) < 0
        && !id.Contains('/') && !id.Contains('\\')
        && Path.GetFileName(id) == id;

    private static string MakeId(string name, bool database)
    {
        var slug = new string(name.ToLowerInvariant().Select(character => char.IsLetterOrDigit(character) ? character : '-').ToArray()).Trim('-');
        while (slug.Contains("--")) slug = slug.Replace("--", "-");
        if (slug.Length == 0) slug = database ? "database" : "profile";
        return (database ? "db-" : "") + slug + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6];
    }

    private static long DirectorySize(string folder) => Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Sum(file => new FileInfo(file).Length);
}
