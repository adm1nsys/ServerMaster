using System.Globalization;
using System.Text;

namespace ServerMaster.Windows.Services;

public sealed record LanguageEntry(string Code, string NativeName, string EnglishName)
{
    public string Title => NativeName == EnglishName ? NativeName : $"{NativeName} — {EnglishName}";
}

/// <summary>
/// The macOS language model: English is the source language and the translation key is the
/// English text. Translations reuse the Mac <c>.lproj/Localizable.strings</c> files, embedded as
/// <c>ServerMaster.Strings.&lt;code&gt;</c>; a missing string falls back to English on its own.
/// The language is chosen once at launch, so a change applies after restarting the app.
/// </summary>
public static class Localization
{
    public const string SystemCode = "";
    private static readonly LanguageEntry[] Supported =
    [
        new("en", "English", "English"),
        new("uk", "Українська", "Ukrainian")
    ];
    private static IReadOnlyDictionary<string, string> _strings = new Dictionary<string, string>();

    /// <summary>English plus every language whose translation is bundled.</summary>
    public static IReadOnlyList<LanguageEntry> Available { get; } =
        Supported.Where(entry => entry.Code == "en" || BundledText(entry.Code) is not null).ToArray();

    public static LanguageEntry Effective { get; private set; } = Supported[0];

    public static bool IsAvailable(string code) => Available.Any(entry => entry.Code == code);

    public static LanguageEntry Entry(string code) => Available.FirstOrDefault(entry => entry.Code == code) ?? Supported[0];

    /// <param name="packFolder">Where imported translation packs live; a pack for the chosen
    /// language wins over the bundled translation, and an empty value in it is ignored.</param>
    public static void Initialize(string code, CultureInfo? system = null, string? packFolder = null)
    {
        Effective = Entry(Resolve(code, system ?? CultureInfo.CurrentUICulture));
        var strings = Effective.Code == "en"
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(BundledTranslation(Effective.Code), StringComparer.Ordinal);
        if (packFolder is not null && TranslationPacks.Load(packFolder, Effective.Code) is { } pack)
            // An English pack exported as a starting point maps most keys to themselves; those are not changes.
            foreach (var pair in pack.Strings.Where(pair => pair.Value.Length > 0 && (Effective.Code != "en" || pair.Value != pair.Key))) strings[pair.Key] = pair.Value;
        _strings = strings;
    }

    /// <summary>False while the source text is shown unchanged: English with no imported pack.</summary>
    public static bool Translates => _strings.Count > 0;

    /// <summary>
    /// Every key the app knows with its bundled translation for <paramref name="code"/>; for
    /// English (the source language) each key maps to itself, so an export is a full starting point.
    /// </summary>
    public static IReadOnlyDictionary<string, string> Bundled(string code)
    {
        if (code != "en") return BundledTranslation(code);
        var keys = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in Supported.Where(entry => entry.Code != "en"))
            foreach (var key in BundledTranslation(entry.Code).Keys) keys[key] = key;
        return keys;
    }

    private static Dictionary<string, string> BundledTranslation(string code)
    {
        var strings = new Dictionary<string, string>(Parse(BundledText(code) ?? ""), StringComparer.Ordinal);
        foreach (var pair in Parse(BundledWindows(code) ?? "")) strings[pair.Key] = pair.Value;
        return strings;
    }

    /// <summary>The saved choice when it is available, otherwise the Windows display language, otherwise English.</summary>
    public static string Resolve(string code, CultureInfo system)
    {
        if (!string.IsNullOrEmpty(code) && IsAvailable(code)) return code;
        for (var culture = system; !string.IsNullOrEmpty(culture.Name); culture = culture.Parent)
            if (IsAvailable(culture.TwoLetterISOLanguageName)) return culture.TwoLetterISOLanguageName;
        return "en";
    }

    public static string T(string english) =>
        _strings.TryGetValue(english, out var translated) && translated.Length > 0 ? translated : english;

    public static bool TryTranslate(string english, out string translated)
    {
        translated = T(english);
        return !ReferenceEquals(translated, english);
    }

    /// <summary>Translates authored text containing one value through a %@ template.</summary>
    public static bool TryTranslateDynamic(string english, out string translated)
    {
        if (TryTranslate(english, out translated)) return true;
        foreach (var pair in _strings)
        {
            var marker = pair.Key.IndexOf("%@", StringComparison.Ordinal);
            if (marker < 0 || pair.Key.IndexOf("%@", marker + 2, StringComparison.Ordinal) >= 0) continue;
            var prefix = pair.Key[..marker];
            var suffix = pair.Key[(marker + 2)..];
            if (!english.StartsWith(prefix, StringComparison.Ordinal) || !english.EndsWith(suffix, StringComparison.Ordinal) || english.Length < prefix.Length + suffix.Length) continue;
            var value = english.Substring(prefix.Length, english.Length - prefix.Length - suffix.Length);
            translated = pair.Value.Replace("%@", value, StringComparison.Ordinal);
            return true;
        }
        translated = english;
        return false;
    }

    private static string? BundledText(string code)
    {
        using var stream = typeof(Localization).Assembly.GetManifestResourceStream("ServerMaster.Strings." + code);
        if (stream is null) return null;
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static string? BundledWindows(string code)
    {
        using var stream = typeof(Localization).Assembly.GetManifestResourceStream("ServerMaster.Strings.Windows." + code);
        if (stream is null) return null;
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    /// <summary>Reads the Apple <c>"key" = "value";</c> format, skipping comments and malformed entries.</summary>
    public static IReadOnlyDictionary<string, string> Parse(string text)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var index = 0;
        while (true)
        {
            SkipTrivia(text, ref index);
            if (index >= text.Length) break;
            var key = ReadQuoted(text, ref index);
            SkipTrivia(text, ref index);
            if (key is null || index >= text.Length || text[index] != '=') { SkipLine(text, ref index); continue; }
            index++;
            SkipTrivia(text, ref index);
            var value = ReadQuoted(text, ref index);
            // An unterminated value stops at its line break; skipping trivia first would eat the next entry.
            if (value is null) { SkipLine(text, ref index); continue; }
            SkipTrivia(text, ref index);
            if (index >= text.Length || text[index] != ';') { SkipLine(text, ref index); continue; }
            index++;
            result[key] = value;
        }
        return result;
    }

    private static void SkipTrivia(string text, ref int index)
    {
        while (index < text.Length)
        {
            if (char.IsWhiteSpace(text[index])) index++;
            else if (string.CompareOrdinal(text, index, "/*", 0, 2) == 0)
            {
                var end = text.IndexOf("*/", index + 2, StringComparison.Ordinal);
                index = end < 0 ? text.Length : end + 2;
            }
            else if (string.CompareOrdinal(text, index, "//", 0, 2) == 0) SkipLine(text, ref index);
            else break;
        }
    }

    private static void SkipLine(string text, ref int index)
    {
        var end = text.IndexOf('\n', index);
        index = end < 0 ? text.Length : end + 1;
    }

    private static string? ReadQuoted(string text, ref int index)
    {
        if (index >= text.Length || text[index] != '"') return null;
        var value = new StringBuilder();
        for (index++; index < text.Length; index++)
        {
            var c = text[index];
            if (c == '"') { index++; return value.ToString(); }
            if (c == '\n') return null;
            if (c != '\\' || index + 1 >= text.Length) { value.Append(c); continue; }
            var escaped = text[++index];
            value.Append(escaped switch { 'n' => '\n', 't' => '\t', 'r' => '\r', _ => escaped });
        }
        return null;
    }
}
