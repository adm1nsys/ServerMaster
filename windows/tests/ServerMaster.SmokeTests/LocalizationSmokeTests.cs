using System.Globalization;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class LocalizationSmokeTests
{
    public static void Run()
    {
        var parsed = Localization.Parse("/* header \"x\" = \"y\"; */\n\"A \\\"quoted\\\" key\" = \"Line\\nnext\";\n// \"Comment\" = \"no\";\n\"Broken\" = \"no end\n\"Kept\" = \"yes\";");
        Check(parsed["A \"quoted\" key"] == "Line\nnext" && parsed["Kept"] == "yes", "the macOS strings format keeps escapes and survives a malformed line");
        Check(!parsed.ContainsKey("Comment") && !parsed.ContainsKey("Broken") && !parsed.ContainsKey("x"), "comments and unterminated entries are not translations");

        Check(Localization.Available.Select(entry => entry.Code).SequenceEqual(["en", "uk"]), "English and the bundled Mac Ukrainian translation are offered");
        Check(Localization.Resolve("", new CultureInfo("uk-UA")) == "uk", "matching the system picks Ukrainian on a Ukrainian Windows");
        Check(Localization.Resolve("", new CultureInfo("de-DE")) == "en", "an untranslated system language falls back to English");
        Check(Localization.Resolve("ru", new CultureInfo("uk-UA")) == "uk" && Localization.Resolve("ru", new CultureInfo("fr-FR")) == "en", "a code saved by an older build behaves like matching the system");
        Check(Localization.Resolve("en", new CultureInfo("uk-UA")) == "en", "an explicit choice outranks the system language");

        Localization.Initialize("uk");
        Check(Localization.T("Interface language") == "Мова інтерфейсу" && Localization.T("Match the system") == "Як у системі", "the Ukrainian Mac strings translate the same English keys on Windows");
        Check(Localization.T("Keep running in the notification area when the window is closed") == "Продовжувати роботу в області сповіщень після закриття вікна",
            "the separate Windows supplement translates Windows-only text");
        Check(Localization.T("Root folder") == "Коренева папка" &&
            Localization.T("No configuration files found") == "Конфігураційних файлів не знайдено" &&
            Localization.T("Port 3307 speaks the MySQL protocol, not HTTP. A browser cannot open it.").StartsWith("Порт 3307", StringComparison.Ordinal),
            "the Windows supplement covers profile, Files and Database UI");
        Check(Localization.T("PHP, Node.js, Python, MariaDB and the other tools are installed from the Dependencies tab — through WinGet or verified downloads. It shows what you have, what is missing, and installs the rest.").StartsWith("PHP, Node.js, Python, MariaDB", StringComparison.Ordinal),
            "long Windows help text is available in Ukrainian");
        Check(Localization.TryTranslateDynamic("Delete database joomla6?", out var dynamicTitle) && dynamicTitle == "Видалити базу даних joomla6?" &&
            Localization.TryTranslateDynamic("Could not open site: access denied", out var dynamicError) && dynamicError == "Не вдалося відкрити сайт: access denied",
            "parameterized dialog titles and notifications preserve their runtime values");
        Check(Localization.TryTranslateDynamic("5 variables", out var variables) && variables == "5 змінних" &&
            Localization.TryTranslateDynamic("12 tables", out var tables) && tables == "12 таблиць",
            "dynamic model counters are localized without changing their values");
        Check(ProfileTemplate.BuiltIn.First(template => template.Id == "php").LocalizedSummary == "Вхідна сторінка PHP" &&
            new ServerProfile { Environment = [] }.EnvironmentSummary == "Немає змінних",
            "bound template and profile model text uses the active language");
        Check(StarterTemplate.For(new ServerProfile { Engine = "static" }).Single().LocalizedTitle == "Проста HTML-сторінка",
            "starter-file choices use the active language");
        var dependency = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "node"), Checked = true };
        Check(dependency.StatusText == "Відсутня" && dependency.ActionText == "Встановити",
            "dependency status and action text use the active language");
        Check(Localization.TryTranslate("Interface language", out _) && !Localization.TryTranslate("Мова інтерфейсу", out _), "translated text is never translated again");
        TranslationPacksRoundTrip();
        Localization.Initialize("en");
        Check(Localization.Effective.Code == "en" && Localization.T("Interface language") == "Interface language", "English uses the source text unchanged");
    }

    private static void TranslationPacksRoundTrip()
    {
        var root = Path.Combine(Path.GetTempPath(), "sm-translation-packs-" + Guid.NewGuid().ToString("N"));
        var folder = Path.Combine(root, "Translations");
        Directory.CreateDirectory(root);
        try
        {
            var exported = Path.Combine(root, "exported.strings");
            TranslationPacks.Export("uk", "2.0", exported);
            var pack = TranslationPacks.Read(exported);
            Check(pack is { Language: "uk", AppVersion: "2.0", PackVersion: "1" } && pack.Strings["Interface language"] == "Мова інтерфейсу" &&
                pack.Strings.ContainsKey("Keep running in the notification area when the window is closed"),
                "an exported pack carries its header and both the Mac and Windows strings");
            var english = Path.Combine(root, "en.strings");
            TranslationPacks.Export("en", "2.0", english);
            Check(TranslationPacks.Read(english) is { Language: "en" } en && en.Strings.Count == pack!.Strings.Count && en.Strings["Interface language"] == "Interface language",
                "an English export lists every key mapped to itself as a starting point");

            var edited = File.ReadAllText(exported).Replace("\"Interface language\" = \"Мова інтерфейсу\";", "\"Interface language\" = \"Мова програми\";", StringComparison.Ordinal)
                .Replace("\"Match the system\" = \"Як у системі\";", "\"Match the system\" = \"\";", StringComparison.Ordinal);
            var renamed = Path.Combine(root, "my-edit.strings");
            File.WriteAllText(renamed, edited);
            var result = TranslationPacks.Import(renamed, folder);
            Check(result.Kind == TranslationImportKind.Installed && File.Exists(Path.Combine(folder, "uk.strings")) && TranslationPacks.Installed(folder).Keys.SequenceEqual(["uk"]),
                "an imported pack is stored under its language from the header, whatever the file was called");
            Localization.Initialize("uk", packFolder: folder);
            Check(Localization.T("Interface language") == "Мова програми" && Localization.T("Match the system") == "Як у системі" && Localization.T("Root folder") == "Коренева папка",
                "an imported pack wins, while its empty and missing lines fall back to the bundled translation");
            Check(!TranslationPacks.Installed(folder)["uk"].MatchesApp("2.1") && TranslationPacks.Installed(folder)["uk"].MatchesApp("2.0"),
                "a pack made for another app version is recognised as mismatched");

            TranslationPacks.Import(english, folder);
            Localization.Initialize("en", packFolder: folder);
            Check(!Localization.Translates, "an unedited English pack changes nothing and keeps English on its fast path");
            File.WriteAllText(Path.Combine(folder, "en.strings"), File.ReadAllText(english).Replace("\"Interface language\" = \"Interface language\";", "\"Interface language\" = \"Language of the interface\";", StringComparison.Ordinal));
            Localization.Initialize("en", packFolder: folder);
            Check(Localization.Translates && Localization.T("Interface language") == "Language of the interface" && Localization.T("Root folder") == "Root folder",
                "an edited English pack rewords only the lines it changes");
            TranslationPacks.Remove(folder, "en");

            var junk = Path.Combine(root, "notes.txt");
            File.WriteAllText(junk, "just some notes");
            Check(TranslationPacks.Import(junk, folder).Kind == TranslationImportKind.NotAStringsFile && TranslationPacks.Installed(folder).Count == 1,
                "a file that is not a strings table is refused and changes nothing");
            TranslationPacks.Remove(folder, "uk");
            Localization.Initialize("uk", packFolder: folder);
            Check(TranslationPacks.Installed(folder).Count == 0 && Localization.T("Interface language") == "Мова інтерфейсу",
                "removing a pack returns to the bundled translation");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Localization: " + description);
    }
}
