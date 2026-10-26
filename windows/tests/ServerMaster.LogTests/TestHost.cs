namespace Microsoft.UI.Dispatching
{
    public sealed class DispatcherQueue
    {
        private readonly object _sync = new();
        public bool HasThreadAccess => false;
        public bool TryEnqueue(Action action) { lock (_sync) action(); return true; }
    }
}

namespace ServerMaster.Windows.Services
{
    public static class AppPaths
    {
        public static string DirectoryPath { get; set; } = "";
        public static string Logs { get { Directory.CreateDirectory(DirectoryPath); return DirectoryPath; } }
    }
}
