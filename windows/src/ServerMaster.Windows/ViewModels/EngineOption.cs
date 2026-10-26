namespace ServerMaster.Windows.ViewModels;

public sealed class EngineOption
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Title;

    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Subtitle { get; init; }
}
