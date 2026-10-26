using System.Text;
using System.Text.Json;
using System.IO.Compression;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class SiteFilesSmokeTests
{
    public static async Task Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-files-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "nested"));
            await File.WriteAllTextAsync(Path.Combine(root, "configuration.php"), "<?php\r\n");
            await File.WriteAllTextAsync(Path.Combine(root, "htaccess.txt"), "Options -Indexes\r\n");
            await File.WriteAllTextAsync(Path.Combine(root, ".env"), "KEY=value\r\n");
            var files = SiteFiles.Read(root, root);
            Check(files[0].IsDirectory && files.Count(f => f.IsHiddenOrConfig) == 3, "config grouping and directories first");
            Check(SiteFiles.IsWithin(root, Path.Combine(root, "nested")) && !SiteFiles.IsWithin(root, root + "-other"), "folder containment excludes sibling prefix");
            var linkedFolder = Path.Combine(root, "nested", "linked-root");
            try
            {
                Directory.CreateSymbolicLink(linkedFolder, root);
                Check(!SiteFiles.IsWithinWithoutLinks(Path.Combine(root, "nested"), linkedFolder), "linked folder is not a browsable site path");
                await Reject(() => Task.FromResult(SiteFiles.Read(Path.Combine(root, "nested"), linkedFolder)), "linked folder cannot be browsed");
                Check(SiteFiles.Read(Path.Combine(root, "nested"), Path.Combine(root, "nested")).Single().IsLink, "linked folder is labeled in Files");
            }
            catch (UnauthorizedAccessException) { Console.WriteLine("SKIP Files: symbolic link creation needs Windows permission"); }
            finally { if (Directory.Exists(linkedFolder)) Directory.Delete(linkedFolder); }
            Check(SiteFiles.DottedName("htaccess.txt") == ".htaccess" && SiteFiles.DottedName("env.example") == ".env" && SiteFiles.DottedName(".env") is null, "dotfile suggestions");
            // RichEdit returns the file's text plus one paragraph mark of its own (\r).
            Check(SiteFiles.FromRichEditText("APP_ENV=local\r\r") == "APP_ENV=local\r" && SiteFiles.FromRichEditText("no newline\r") == "no newline"
                && SiteFiles.FromRichEditText("a\rb\r\r\r") == "a\rb\r\r" && SiteFiles.FromRichEditText("") == "",
                "editor keeps a file's own final line breaks and drops only RichEdit's extra mark");
            var entry = files.Single(f => f.Name == "htaccess.txt");
            foreach (var invalid in new[] { "../outside", "CON.txt", ".env", "bad." })
                await Reject(() => Task.FromResult(SiteFiles.Rename(root, entry, invalid)), "rename rejects " + invalid);
            var renamed = SiteFiles.Rename(root, entry, ".htaccess");
            Check(File.Exists(renamed) && !File.Exists(entry.FullPath), "dotfile rename preserves content");
            foreach (var encoding in new Encoding[] { new UTF8Encoding(false), new UTF8Encoding(true), new UnicodeEncoding(false, true), new UnicodeEncoding(true, true) })
            {
                var path = Path.Combine(root, "encoded.txt");
                var original = "Hello \u041c\u0438\u0440\r\nsecond line\r\n";
                await File.WriteAllTextAsync(path, original, encoding);
                var document = await SiteFiles.LoadTextAsync(path);
                Check(document.Text == original, "read " + encoding.WebName);
                var updated = original.Replace("second", "third");
                await document.SaveAsync(updated);
                var expected = encoding.GetPreamble().Concat(encoding.GetBytes(updated));
                Check((await File.ReadAllBytesAsync(path)).SequenceEqual(expected), "preserve BOM, encoding and CRLF " + encoding.WebName);
                await File.WriteAllTextAsync(path, "external change", encoding);
                await Reject(() => document.SaveAsync("do not overwrite"), "external modification protected");
                Check((await File.ReadAllTextAsync(path)) == "external change", "external content intact");
            }
            var binary = Path.Combine(root, "binary.dat");
            await File.WriteAllBytesAsync(binary, new byte[] { 0, 1, 2, 3 });
            await Reject(() => SiteFiles.LoadTextAsync(binary), "binary file rejected");
            using (var large = File.Create(binary)) large.SetLength(SiteFiles.MaxEditorBytes + 1);
            await Reject(() => SiteFiles.LoadTextAsync(binary), "oversize file rejected");
            Check(!Directory.EnumerateFiles(root, "*.servermaster-tmp").Any(), "save temporary files cleaned");
            var sites = Path.Combine(root, "sites");
            var snapshots = Path.Combine(root, "snapshots");
            Directory.CreateDirectory(sites);
            Directory.CreateDirectory(Path.Combine(sites, "empty"));
            await File.WriteAllTextAsync(Path.Combine(sites, ".env"), "test-only=value");
            // Left behind by a save that was interrupted (the app was killed mid-write).
            await File.WriteAllTextAsync(Path.Combine(sites, ".env.0123abcd" + SiteFiles.TemporarySuffix), "half-written");
            Check(SiteFiles.Read(sites, sites).All(entry => !SiteFiles.IsEditorTemporary(entry.Name)), "Files hides leftovers of interrupted editor saves");
            var first = await ProfileSnapshots.CreateAsync("Test", sites, snapshots);
            var second = await ProfileSnapshots.CreateAsync("Test", sites, snapshots);
            Check(first != second, "rapid snapshots have unique names");
            using (var archive = ZipFile.OpenRead(first))
            {
                Check(archive.GetEntry(".env") is not null && archive.GetEntry("empty/") is not null, "snapshots include dotfiles and empty directories");
                Check(archive.Entries.All(entry => !SiteFiles.IsEditorTemporary(entry.Name)), "snapshots leave out editor temporary files");
            }
            await Reject(() => ProfileSnapshots.CreateAsync("Missing", Path.Combine(root, "absent"), snapshots), "missing site never produces empty success archive");
            await Reject(() => ProfileSnapshots.CreateAsync("Nested", sites, Path.Combine(sites, "snapshots")), "snapshot destination cannot recurse into itself");
            Check(!Directory.EnumerateFiles(snapshots, "*.partial").Any(), "snapshot staging files cleaned");
            await File.WriteAllTextAsync(Path.Combine(sites, ".env"), "new content");
            var previous = await ProfileSnapshots.RestoreAsync(first, sites);
            Check(await File.ReadAllTextAsync(Path.Combine(sites, ".env")) == "test-only=value", "restore replaces profile files from archive");
            Check(previous is not null && await File.ReadAllTextAsync(Path.Combine(previous, ".env")) == "new content", "restore preserves original folder for rollback");
            var malicious = Path.Combine(snapshots, "unsafe.zip");
            using (var archive = ZipFile.Open(malicious, ZipArchiveMode.Create)) archive.CreateEntry("../escape.txt");
            await Reject(() => ProfileSnapshots.RestoreAsync(malicious, sites), "restore rejects archive traversal");
            await Reject(() => ProfileSnapshots.RestoreAsync(Path.Combine(snapshots, "missing.zip"), sites), "missing archive does not start restore");
            Check(await File.ReadAllTextAsync(Path.Combine(sites, ".env")) == "test-only=value", "failed archive preflight leaves site unchanged");

            var profile = new ServerProfile { Name = "Snapshot profile", RootPath = sites };
            await Reject(() => ProfileSnapshots.CreateProfileAsync(profile, Path.Combine(sites, "snapshots"), includeDatabase: false),
                "profile snapshot destination cannot recurse into site");
            var macStyle = await ProfileSnapshots.CreateProfileAsync(profile, snapshots, includeDatabase: false);
            Check(File.Exists(Path.Combine(macStyle.FullPath, "profile.json")), "snapshot stores profile settings");
            Check(File.Exists(Path.Combine(macStyle.FullPath, "site.zip")), "snapshot stores site archive");
            Check(profile.Id == ProfileSnapshots.Load(snapshots).First(item => item.Id == macStyle.Id).ProfileId, "snapshot index preserves profile identity");
            Check(new BackupEntry { Note = "Database not included: MariaDB was stopped." }.ContentsLabel.Contains("Database not included"),
                "snapshot list shows omitted database warning");
            var outside = Path.Combine(root, "outside");
            Directory.CreateDirectory(outside);
            await File.WriteAllTextAsync(Path.Combine(outside, "keep.txt"), "keep");
            var index = Path.Combine(snapshots, "snapshots.json");
            await File.WriteAllTextAsync(index, JsonSerializer.Serialize(new[] { new { id = "../outside", kind = "profile", profileName = "Unsafe" } }));
            Check(ProfileSnapshots.Load(snapshots).Count == 0, "snapshot index ignores paths outside backup folder");
            await Reject(() => Task.Run(() => ProfileSnapshots.Delete(snapshots,
                new BackupEntry { Id = "../outside", FullPath = outside })), "snapshot deletion rejects an escaped path");
            Check(await File.ReadAllTextAsync(Path.Combine(outside, "keep.txt")) == "keep", "rejected snapshot deletion leaves other folders intact");
            Check(await File.ReadAllTextAsync(Path.Combine(sites, ".env")) == "test-only=value", "failed restore leaves destination unchanged");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void Check(bool success, string message)
    {
        if (!success) throw new Exception(message);
        Console.WriteLine("PASS Files: " + message);
    }

    private static async Task Reject(Func<Task> action, string message)
    {
        try { await action(); }
        catch (IOException) { Check(true, message); return; }
        throw new Exception("Expected rejection: " + message);
    }
}
