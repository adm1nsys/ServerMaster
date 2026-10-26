namespace ServerMaster.Windows.Services;

public static class NativeDirectory
{
    public static string Resolve(string path) => Path.GetFullPath(path);
}

public static class AdminerService
{
    public static void Stop() { }
}
