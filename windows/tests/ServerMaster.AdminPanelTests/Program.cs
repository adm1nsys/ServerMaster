using System.IO.Compression;
using ServerMaster.Windows.Services;

var root = Path.Combine(Path.GetTempPath(), "ServerMaster-admin-panel-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var passed = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + name);
    passed++;
    Console.WriteLine("PASS: " + name);
}

try
{
    var validArchive = Path.Combine(root, "valid.zip");
    CreateArchive(validArchive, false, true);
    var extracted = Path.Combine(root, "extracted");
    await PhpMyAdminRuntime.ExtractVerifiedAsync(validArchive, extracted);
    Check(File.Exists(Path.Combine(extracted, "index.php")), "verified archive extracts without wrapper folder");
    Check(File.Exists(Path.Combine(extracted, "vendor", "autoload.php")), "runtime files are preserved");

    var unsafeArchive = Path.Combine(root, "unsafe.zip");
    CreateArchive(unsafeArchive, true, true);
    var outside = Path.Combine(root, "escaped.txt");
    try
    {
        await PhpMyAdminRuntime.ExtractVerifiedAsync(unsafeArchive, Path.Combine(root, "unsafe-output"));
        Check(false, "unsafe path rejected");
    }
    catch (IOException) { Check(true, "unsafe path rejected"); }
    Check(!File.Exists(outside), "unsafe archive cannot write outside staging");

    var incompleteArchive = Path.Combine(root, "incomplete.zip");
    CreateArchive(incompleteArchive, false, false);
    try
    {
        await PhpMyAdminRuntime.ExtractVerifiedAsync(incompleteArchive, Path.Combine(root, "incomplete-output"));
        Check(false, "incomplete package rejected");
    }
    catch (IOException) { Check(true, "incomplete package rejected"); }

    Check(PhpMyAdminRuntime.ExpectedSha256.Length == 64 && PhpMyAdminRuntime.Version == "5.2.3", "pinned release metadata");
    Console.WriteLine($"{passed} admin-panel checks passed.");
}
finally
{
    try { Directory.Delete(root, true); } catch (IOException) { }
}

static void CreateArchive(string path, bool unsafePath, bool complete)
{
    using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
    Write(archive, "phpMyAdmin-5.2.3/index.php", "<?php");
    if (complete)
    {
        Write(archive, "phpMyAdmin-5.2.3/libraries/common.inc.php", "<?php");
        Write(archive, "phpMyAdmin-5.2.3/vendor/autoload.php", "<?php");
    }
    if (unsafePath) Write(archive, "phpMyAdmin-5.2.3/../../escaped.txt", "escape");
}

static void Write(ZipArchive archive, string name, string content)
{
    using var writer = new StreamWriter(archive.CreateEntry(name).Open());
    writer.Write(content);
}
