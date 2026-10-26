namespace ServerMaster.Windows.Models;

public sealed class ProfileConfigFile
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Title;

    public required string Title { get; init; }
    public required string Path { get; init; }
    public required string Kind { get; init; }
    public string Note { get; init; } = "";
    public bool CanEdit { get; init; }
    public string SizeLabel { get; init; } = "";
}
