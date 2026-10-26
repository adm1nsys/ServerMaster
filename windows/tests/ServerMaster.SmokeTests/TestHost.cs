namespace Microsoft.UI.Xaml
{
    public enum Visibility { Visible, Collapsed }
}
namespace Microsoft.UI.Dispatching
{
    public sealed class DispatcherQueue
    {
        public bool HasThreadAccess => true;
        public bool TryEnqueue(Action action) { action(); return true; }
    }
}
namespace ServerMaster.Windows.Models
{
    public enum LogStream { System, Stdout, Stderr }
}
namespace ServerMaster.Windows.Services
{
    public sealed class ConsoleLog
    {
        public ConsoleLog() { }
        public ConsoleLog(Microsoft.UI.Dispatching.DispatcherQueue dispatcher) { }
        public int Limit { get; set; }
        public void StartFileLogging(string name) { }
        public void StopFileLogging() { }
        public System.Collections.Concurrent.ConcurrentQueue<string> Lines { get; } = new();
        public void System(string text) => Lines.Enqueue(text);
        public void Append(string text, Models.LogStream stream) => Lines.Enqueue(text);
    }
    public static class AppPaths
    {
        public static string Ensure(string path) { Directory.CreateDirectory(path); return path; }
        // Same location the app uses without SERVERMASTER_DATA_DIR; database tests set their own TestRoot.
        public static string LocalSupport { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ServerMaster");
        public static string Runtime { get; } = Environment.GetCommandLineArgs()
            .FirstOrDefault(argument => argument.StartsWith("--runtime-root=", StringComparison.Ordinal))?[15..]
            ?? Path.Combine(Path.GetTempPath(), "ServerMaster-tests-" + Guid.NewGuid().ToString("N"));
        public static IEnumerable<string> RuntimeRoots => [Runtime];
        public static string Expand(string path) => Environment.ExpandEnvironmentVariables(path);
    }
}
