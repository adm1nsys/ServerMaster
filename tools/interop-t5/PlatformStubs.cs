// Only UI-only types needed to compile unchanged production codecs on macOS.
// ProfileStore/UserTemplateStore/translation parsing and JSON options are real.
namespace Microsoft.UI.Xaml { public enum Visibility { Visible, Collapsed } }
namespace Windows.Storage
{
    public sealed class ApplicationData
    {
        public static ApplicationData Current => throw new InvalidOperationException("T5 must use SERVERMASTER_DATA_DIR, never WinRT storage.");
        public StorageFolder LocalFolder => throw new InvalidOperationException();
    }
    public sealed class StorageFolder { public string Path => throw new InvalidOperationException(); }
}
