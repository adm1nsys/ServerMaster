using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class DatabaseEntry
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Name;

    public string Name { get; init; } = "";
    public int Tables { get; init; }
    public string TablesLabel
    {
        get
        {
            var source = Tables == 0 ? "No tables" : Tables == 1 ? "1 table" : $"{Tables} tables";
            return Localization.TryTranslateDynamic(source, out var translated) ? translated : source;
        }
    }
}
