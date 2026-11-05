namespace ServerMaster.Windows.Services;

public static class NativeDirectory
{
    public static string Resolve(string path) => Path.GetFullPath(path);
}

public static class AdminerService
{
    public static void Stop() { }
}

public static class AppPaths
{
    public static string LocalSupport { get; } = Path.Combine(Path.GetTempPath(), "ServerMaster-admin-panel-tests");
}
