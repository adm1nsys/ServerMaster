using System.Text.Json;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class SettingsBehavior
{
    public static AppSettings Reset(AppSettings current) => new()
    {
        DefaultProfileId = current.DefaultProfileId,
        FirstSetupCompleted = current.FirstSetupCompleted,
        LastSection = current.LastSection,
        LastSelectedProfileId = current.LastSelectedProfileId
    };

    public static AppSettings Read(string json)
    {
        var settings = new AppSettings();
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object) return settings;
        var properties = typeof(AppSettings).GetProperties().Where(property => property.CanWrite)
            .ToDictionary(property => property.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var field in document.RootElement.EnumerateObject())
        {
            if (!properties.TryGetValue(field.Name, out var property)) continue;
            try
            {
                var value = JsonSerializer.Deserialize(field.Value.GetRawText(), property.PropertyType);
                if (value is not null || Nullable.GetUnderlyingType(property.PropertyType) is not null) property.SetValue(settings, value);
            }
            catch (JsonException) { } // Keep this field's default without discarding valid sibling fields.
        }
        settings.ExtraPathEntries = settings.ExtraPathEntries.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        settings.BackupProfileIds = settings.BackupProfileIds.Distinct().ToList();
        return settings;
    }

    public static string StartupSection(AppSettings settings)
    {
        string[] sections = ["Control", "Console", "Database", "Ports", "Files", "Profiles", "Dependencies", "Backups", "Diagnostics", "Settings", "About"];
        return settings.RestoreLastSection ? sections.FirstOrDefault(section => section.Equals(settings.LastSection, StringComparison.OrdinalIgnoreCase)) ?? "Control" : "Control";
    }

    public static Guid? StartupProfile(AppSettings settings, IEnumerable<Guid> profileIds)
    {
        var ids = profileIds.ToArray();
        if (settings.LastSelectedProfileId is { } last && ids.Contains(last)) return last;
        if (settings.DefaultProfileId is { } preferred && ids.Contains(preferred)) return preferred;
        return ids.Length > 0 ? ids[0] : null;
    }

    public static IReadOnlyList<ServerProfile> ScheduledProfiles(AppSettings settings, IEnumerable<ServerProfile> profiles) =>
        profiles.Where(profile => settings.BackupProfileIds.Count == 0 || settings.BackupProfileIds.Contains(profile.Id)).ToArray();
}
