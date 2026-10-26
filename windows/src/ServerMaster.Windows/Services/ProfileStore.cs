using System.Text.Json;
using System.Text.Json.Serialization;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class ProfileStore
{
    private readonly JsonSerializerOptions _options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public AppSettings LoadSettings()
    {
        try { return SettingsBehavior.Read(File.ReadAllText(AppPaths.SettingsFile)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return new AppSettings(); }
    }

    public List<ServerProfile> LoadProfiles()
    {
        var profiles = Read<List<ServerProfile>>(AppPaths.ProfilesFile);
        if (profiles is { Count: > 0 })
        {
            foreach (var profile in profiles)
            {
                profile.State = ServerState.Stopped;
                profile.Failure = null;
                profile.ProcessId = null;
                profile.StartedAt = null;
                profile.Uptime = "";
            }

            return profiles;
        }

        var seeded = SeedProfiles();
        SaveProfiles(seeded);
        return seeded;
    }

    public void SaveSettings(AppSettings settings)
    {
        Write(AppPaths.SettingsFile, settings);
    }

    public void SaveProfiles(IEnumerable<ServerProfile> profiles)
    {
        Write(AppPaths.ProfilesFile, profiles.ToList());
    }

    private static List<ServerProfile> SeedProfiles()
    {
        var sites = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Sites");
        Directory.CreateDirectory(sites);
        return
        [
            new ServerProfile
            {
                Name = "Local static site",
                Engine = "pythonHTTP",
                Host = "127.0.0.1",
                Port = 8080,
                RootPath = sites,
                EnableCors = true
            }
        ];
    }

    private T? Read<T>(string path)
    {
        if (!File.Exists(path))
        {
            return default;
        }

        try
        {
            return JsonSerializer.Deserialize<T>(File.ReadAllText(path), _options);
        }
        catch
        {
            return default;
        }
    }

    private void Write<T>(string path, T value)
    {
        AppPaths.Ensure(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, _options));
        File.Move(temp, path, overwrite: true);
    }
}
