using System.Security.Cryptography;
using System.Text;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class SiteFiles
{
    public const int MaxEditorBytes = 4_000_000;
    private static readonly HashSet<string> ConfigNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "configuration.php", "wp-config.php", "settings.php", "config.php", "nginx.conf",
        "caddyfile", "package.json", "composer.json", "docker-compose.yml", "index.php",
        "web.config", "php.ini", "htaccess.txt",
        // The printing templates' notes with the store admin address and login.
        "servermaster-demo.md"
    };

    public static bool IsWithin(string root, string path)
    {
        var relative = Path.GetRelativePath(Path.GetFullPath(root), Path.GetFullPath(path));
        return !Path.IsPathRooted(relative) && relative != ".." &&
            !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }

    public static bool IsWithinWithoutLinks(string root, string path)
    {
        if (!IsWithin(root, path)) return false;
        var current = Path.GetFullPath(root);
        var relative = Path.GetRelativePath(current, Path.GetFullPath(path));
        if (relative == ".") return true;
        try
        {
            foreach (var part in relative.Split(Path.DirectorySeparatorChar))
            {
                current = Path.Combine(current, part);
                if (File.GetAttributes(current).HasFlag(FileAttributes.ReparsePoint)) return false;
            }
            return true;
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    public static IReadOnlyList<FileEntry> Read(string root, string folder)
    {
        if (!IsWithinWithoutLinks(root, folder)) throw new IOException("This folder is outside the profile or passes through a Windows link. Open it in Explorer instead.");
        return new DirectoryInfo(folder).EnumerateFileSystemInfos().Where(info => !IsEditorTemporary(info.Name)).Select(info => new FileEntry
        {
            Name = info.Name, FullPath = info.FullName,
            IsDirectory = info is DirectoryInfo,
            IsLink = info.Attributes.HasFlag(FileAttributes.ReparsePoint),
            IsHidden = info.Name.StartsWith('.') || info.Attributes.HasFlag(FileAttributes.Hidden),
            IsConfig = ConfigNames.Contains(info.Name),
            Size = info is FileInfo file && !info.Attributes.HasFlag(FileAttributes.ReparsePoint) ? file.Length : 0,
            LastWriteTime = info.LastWriteTime
        }).OrderByDescending(item => item.IsDirectory).ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// The text of a RichEditBox document as the file holds it. RichEdit ends every document with
    /// one extra paragraph mark; only that one is removed, so a file's own final line break
    /// survives (trimming all of them made every newline-terminated file look edited and lose
    /// its last line break on save).
    /// </summary>
    /// <summary>The editor's own atomic-save file; never the user's content.</summary>
    public const string TemporarySuffix = ".servermaster-tmp";

    /// <summary>A leftover of an interrupted save; hidden from Files and left out of snapshots.</summary>
    public static bool IsEditorTemporary(string name) => name.EndsWith(TemporarySuffix, StringComparison.OrdinalIgnoreCase);

    public static string FromRichEditText(string value) => value.EndsWith('\r') ? value[..^1] : value;

    public static string? DottedName(string name)
    {
        if (name.StartsWith('.')) return null;
        foreach (var basename in new[] { "htaccess", "env", "gitignore", "user.ini", "htpasswd", "editorconfig" })
            foreach (var suffix in new[] { ".txt", ".dist", ".example", ".sample", ".default", "" })
                if (!(basename == "env" && suffix.Length == 0) && name.Equals(basename + suffix, StringComparison.OrdinalIgnoreCase))
                    return "." + basename;
        return name.Length > 4 && (name.StartsWith("dot.", StringComparison.OrdinalIgnoreCase) || name.StartsWith("dot-", StringComparison.OrdinalIgnoreCase))
            ? "." + name[4..] : null;
    }

    public static string Rename(string root, FileEntry entry, string name)
    {
        if (!IsWithinWithoutLinks(root, entry.FullPath) || Path.GetFullPath(root).Equals(Path.GetFullPath(entry.FullPath), StringComparison.OrdinalIgnoreCase))
            throw new IOException("Choose a file inside the profile folder.");
        name = name.Trim();
        var stem = name.Split('.')[0].ToUpperInvariant();
        if (name.Length == 0 || name is "." or ".." || name.EndsWith('.') || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            stem is "CON" or "PRN" or "AUX" or "NUL" ||
            (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && stem[3] is >= '1' and <= '9'))
            throw new IOException("Enter a valid Windows file name, without a folder path.");
        if (name == entry.Name) return entry.FullPath;
        var target = Path.Combine(Path.GetDirectoryName(entry.FullPath)!, name);
        if (File.Exists(target) || Directory.Exists(target)) throw new IOException($"'{name}' already exists in this folder.");
        if (entry.IsDirectory) Directory.Move(entry.FullPath, target);
        else File.Move(entry.FullPath, target);
        return target;
    }

    public static async Task<SiteTextDocument> LoadTextAsync(string path)
    {
        await using var stream = File.OpenRead(path);
        if (stream.Length > MaxEditorBytes) throw new IOException("This file is too large for the built-in editor (4 MB maximum).");
        var bytes = new byte[(int)stream.Length];
        await stream.ReadExactlyAsync(bytes);
        Encoding encoding = new UTF8Encoding(false, true);
        var preamble = 0;
        if (bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) { encoding = new UTF8Encoding(true, true); preamble = 3; }
        else if (bytes.AsSpan().StartsWith(new byte[] { 0xFF, 0xFE })) { encoding = new UnicodeEncoding(false, true, true); preamble = 2; }
        else if (bytes.AsSpan().StartsWith(new byte[] { 0xFE, 0xFF })) { encoding = new UnicodeEncoding(true, true, true); preamble = 2; }
        string text;
        try { text = encoding.GetString(bytes, preamble, bytes.Length - preamble); }
        catch (DecoderFallbackException ex) { throw new IOException("This file is not valid UTF-8 or UTF-16 text. Use Open with to edit it in another application.", ex); }
        if (text.Any(c => c == '\0' || (char.IsControl(c) && c is not '\r' and not '\n' and not '\t')))
            throw new IOException("This is not a text file. Open it in another application.");
        return new(path, text, encoding, Convert.ToHexString(SHA256.HashData(bytes)));
    }
}

public sealed class SiteTextDocument(string path, string text, Encoding encoding, string hash)
{
    public string Text { get; private set; } = text;
    public string EncodingName => encoding.WebName;
    private string _hash = hash;

    public async Task SaveAsync(string content)
    {
        // Keep the original intact when an external editor changed it after loading. Checked before
        // anything is written, so a refused save leaves no temporary file behind.
        var current = await File.ReadAllBytesAsync(path);
        if (Convert.ToHexString(SHA256.HashData(current)) != _hash)
            throw new IOException("This file changed outside ServerMaster. Close and reopen it before saving.");
        var temporary = path + "." + Guid.NewGuid().ToString("N") + SiteFiles.TemporarySuffix;
        try
        {
            await File.WriteAllTextAsync(temporary, content, encoding);
            File.Replace(temporary, path, null);
            _hash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(path)));
            Text = content;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
