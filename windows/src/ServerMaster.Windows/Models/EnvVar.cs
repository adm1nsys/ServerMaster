namespace ServerMaster.Windows.Models;

public sealed class EnvVar
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Key;

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Key { get; set; } = "";
    public string Value { get; set; } = "";
}
