namespace ServerMaster.Windows.Models;

public sealed record AdminToolOption(string Id, string Title, string Subtitle)
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Title;
}
