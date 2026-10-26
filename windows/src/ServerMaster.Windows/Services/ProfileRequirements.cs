using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class ProfileRequirements
{
    public static IReadOnlyList<string> CommandsFor(ServerProfile profile)
    {
        string[] commands = profile.Engine switch
        {
            "phpBuiltIn" => ["vcredist", "php@" + (profile.PhpVersion.Length > 0 ? profile.PhpVersion : "8.3")],
            "httpServer" => ["node", "npm", "http-server"],
            "nodeScript" => profile.TemplateId == "printshopcrm" ? ["node", "npm"] : ["node"],
            "pythonHTTP" => ["python"],
            _ => []
        };
        return commands.Concat(profile.NeedsDatabase ? ["mariadbd"] : Array.Empty<string>())
            .Concat(profile.HttpsEnabled ? ["caddy"] : Array.Empty<string>()).Distinct().ToList();
    }
}
