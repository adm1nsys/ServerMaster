using System.Text;

namespace ServerMaster.Windows.Services;

/// <summary>
/// A translation taken out of the app, edited and put back, as on macOS. The file is the plain
/// <c>"key" = "value";</c> format with a comment header naming the language and the app version
/// it was made for; an imported pack wins over the bundled translation, and anything it leaves
/// out falls back to it.
/// </summary>
public sealed record TranslationPack(string Language, string AppVersion, string PackVersion, IReadOnlyDictionary<string, string> Strings)
{
    public bool MatchesApp(string appVersion) => AppVersion == appVersion;

    public string Summary => Localization.T("%lld strings · for ServerMaster %@")
        .Replace("%lld", Strings.Count.ToString(), StringComparison.Ordinal)
        .Replace("%@", AppVersion, StringComparison.Ordinal);

    public string Title => Localization.Entry(Language).Code == Language ? Localization.Entry(Language).NativeName : Language;

    public override string ToString() => $"{Title} {Summary}";
}

public enum TranslationImportKind { Installed, NotAStringsFile, CouldNotSave }

public sealed record TranslationImportResult(TranslationImportKind Kind, TranslationPack? Pack = null, string Message = "");

public static class TranslationPacks
{
    public const string Extension = ".strings";

    /// <summary>Imported packs in <paramref name="folder"/>, by language code.</summary>
    public static IReadOnlyDictionary<string, TranslationPack> Installed(string folder)
    {
        var found = new Dictionary<string, TranslationPack>(StringComparer.Ordinal);
        if (!Directory.Exists(folder)) return found;
        foreach (var file in Directory.EnumerateFiles(folder, "*" + Extension).OrderBy(path => path, StringComparer.Ordinal))
            if (Read(file) is { } pack) found[pack.Language] = pack;
        return found;
    }

    public static TranslationPack? Load(string folder, string language)
    {
        var path = Path.Combine(folder, language + Extension);
        return File.Exists(path) ? Read(path) : null;
    }

    public static TranslationPack? Read(string path)
    {
        string text;
        try { text = File.ReadAllText(path, Encoding.UTF8); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
        var strings = Localization.Parse(text);
        if (strings.Count == 0) return null;
        // A pack someone renamed to uk.strings still lands in the right place.
        var language = Field(text, "Language") ?? Path.GetFileNameWithoutExtension(path);
        return new TranslationPack(language, Field(text, "App version") ?? Localization.T("unknown"), Field(text, "Pack version") ?? "1", strings);
    }

    /// <summary>Writes every key the app knows with today's translation, so the file is a starting point.</summary>
    public static void Export(string language, string appVersion, string path)
    {
        var strings = Localization.Bundled(language);
        var text = new StringBuilder();
        text.Append("/* ServerMaster translation pack\n");
        text.Append($"   Language: {language}\n   App version: {appVersion}\n   Pack version: 1\n\n");
        text.Append("   Edit the right-hand side only. The left-hand side is the key the app\n");
        text.Append("   looks up — change it and the line stops being found.\n\n");
        text.Append("   Anything left out falls back to the bundled translation, and then to\n");
        text.Append("   English. A partial pack is fine. */\n\n");
        foreach (var key in strings.Keys.OrderBy(key => key, StringComparer.Ordinal))
            text.Append('"').Append(Escape(key)).Append("\" = \"").Append(Escape(strings[key])).Append("\";\n");
        File.WriteAllText(path, text.ToString(), new UTF8Encoding(false));
    }

    public static TranslationImportResult Import(string source, string folder)
    {
        if (Read(source) is not { } pack) return new(TranslationImportKind.NotAStringsFile);
        try
        {
            Directory.CreateDirectory(folder);
            File.Copy(source, Path.Combine(folder, pack.Language + Extension), overwrite: true);
            return new(TranslationImportKind.Installed, pack);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return new(TranslationImportKind.CouldNotSave, pack, ex.Message);
        }
    }

    public static void Remove(string folder, string language)
    {
        var path = Path.Combine(folder, language + Extension);
        if (File.Exists(path)) File.Delete(path);
    }

    private static string? Field(string text, string name)
    {
        var start = text.IndexOf(name + ": ", StringComparison.Ordinal);
        if (start < 0) return null;
        start += name.Length + 2;
        var end = text.IndexOfAny(['\r', '\n'], start);
        var value = end < 0 ? text[start..] : text[start..end];
        // The last header line ends the comment, so "2.0 */" arrives where "2.0" was meant.
        var close = value.IndexOf("*/", StringComparison.Ordinal);
        if (close >= 0) value = value[..close];
        value = value.Trim();
        return value.Length > 0 ? value : null;
    }

    private static string Escape(string text) =>
        text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal).Replace("\n", "\\n", StringComparison.Ordinal)
            .Replace("\r", "\\r", StringComparison.Ordinal).Replace("\t", "\\t", StringComparison.Ordinal);
}
