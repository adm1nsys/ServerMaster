using System.Text.Json;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class SettingsSmokeTests
{
    public static void Run()
    {
        var settings = SettingsBehavior.Read("{\"consoleFontSize\":16,\"backupsEnabled\":true,\"consoleBufferLines\":\"wrong\",\"backupProfileIds\":null,\"extraPathEntries\":[null,\"C:\\\\Tools\",\"c:\\\\tools\"]}");
        Check(settings.ConsoleFontSize == 16 && settings.BackupsEnabled && settings.ConsoleBufferLines == 5000, "one invalid field preserves valid sibling settings");
        Check(settings.BackupProfileIds.Count == 0 && settings.ExtraPathEntries.Count == 1, "null collections and invalid PATH entries retain safe defaults");
        var first = Guid.NewGuid(); var last = Guid.NewGuid(); var removed = Guid.NewGuid();
        settings.DefaultProfileId = first;
        settings.LastSelectedProfileId = last;
        Check(SettingsBehavior.StartupProfile(settings, [first, last]) == last, "last selected profile takes precedence over default selection");
        settings.LastSelectedProfileId = removed;
        Check(SettingsBehavior.StartupProfile(settings, [first, last]) == first, "deleted last profile falls back to default");
        settings.DefaultProfileId = removed;
        Check(SettingsBehavior.StartupProfile(settings, [first, last]) == first && SettingsBehavior.StartupProfile(settings, []) is null, "missing default falls back to first profile or empty state");
        settings.LastSection = "profiles";
        Check(SettingsBehavior.StartupSection(settings) == "Profiles", "saved section names are canonicalized");
        settings.LastSection = "removed-feature";
        Check(SettingsBehavior.StartupSection(settings) == "Control", "unavailable saved section cannot produce a blank screen");
        settings.RestoreLastSection = false; settings.LastSection = "Database";
        Check(SettingsBehavior.StartupSection(settings) == "Control", "restore-section preference is respected");
        var profiles = new[] { new ServerProfile { Id = first }, new ServerProfile { Id = last } };
        Check(SettingsBehavior.ScheduledProfiles(settings, profiles).Count == 2, "empty schedule selection means all profiles like macOS");
        settings.BackupProfileIds = [last];
        Check(SettingsBehavior.ScheduledProfiles(settings, profiles).Select(profile => profile.Id).SequenceEqual([last]), "automatic snapshots select only configured profiles");
        settings.BackupProfileIds = [removed];
        Check(SettingsBehavior.ScheduledProfiles(settings, profiles).Count == 0, "deleted schedule targets never silently expand to all profiles");
        settings.LastSelectedProfileId = last;
        var serialized = JsonSerializer.Serialize(settings, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        var restored = SettingsBehavior.Read(serialized);
        Check(restored.LastSelectedProfileId == last && restored.BackupProfileIds.SequenceEqual([removed]), "profile selection and schedule targets survive a settings round trip");
        var legacy = SettingsBehavior.Read("{}");
        Check(legacy.RestoreLastSection && legacy.BackupProfileIds.Count == 0 && legacy.ConsoleFontSize == 12 && legacy.DatabaseAdminTool == "adminer", "older settings retain current defaults");
        settings.FirstSetupCompleted = true;
        settings.DefaultProfileId = first;
        settings.ConsoleFontSize = 21;
        settings.ExtraPathEntries = ["C:\\CustomTools"];
        settings.DatabaseAdminPort = 9000;
        settings.DatabaseAdminTool = "phpmyadmin";
        settings.PortReservationsEnabled = true;
        var reset = SettingsBehavior.Reset(settings);
        Check(reset.DefaultProfileId == first && reset.FirstSetupCompleted, "reset preserves the default profile and completed first setup");
        Check(reset.LastSelectedProfileId == settings.LastSelectedProfileId && reset.LastSection == settings.LastSection, "reset preserves current navigation context like macOS saveSettings");
        Check(reset.ConsoleFontSize == 12 && reset.ExtraPathEntries.Count == 0 && reset.DatabaseAdminPort == 8036 && reset.DatabaseAdminTool == "adminer" && !reset.PortReservationsEnabled, "reset restores console, environment, panel and port defaults");
        Check(!reset.BackupsEnabled && reset.BackupProfileIds.Count == 0 && reset.LastBackup is null, "reset disables scheduling without changing existing snapshot storage");
        Check(settings.ConsoleFontSize == 21 && settings.BackupProfileIds.SequenceEqual([removed]), "reset creates separate preferences without mutating the old instance");
        Check(SettingsBehavior.Read(JsonSerializer.Serialize(reset)).DefaultProfileId == first, "reset preferences remain readable after saving");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Settings: " + description);
    }
}
