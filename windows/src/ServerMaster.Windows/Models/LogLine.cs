namespace ServerMaster.Windows.Models;

public enum LogStream
{
    Stdout,
    Stderr,
    System,
    Command
}

public sealed class LogLine
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Text;

    public DateTimeOffset Date { get; init; } = DateTimeOffset.Now;
    public LogStream Stream { get; init; }
    public string Text { get; init; } = "";
}
