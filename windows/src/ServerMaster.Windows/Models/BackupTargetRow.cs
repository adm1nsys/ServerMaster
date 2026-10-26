namespace ServerMaster.Windows.Models;

public sealed class BackupTargetRow
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Name;

    public ServerProfile? Profile { get; init; }
    public DatabaseEntry? Database { get; init; }
    public string Name => Profile?.Name ?? Database?.Name ?? "";
    public string Details => Profile?.RootPath ?? Database?.TablesLabel ?? "";
    public string History { get; init; } = "never";
}
