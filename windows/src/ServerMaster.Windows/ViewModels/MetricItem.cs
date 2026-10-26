using Microsoft.UI.Xaml.Media;

namespace ServerMaster.Windows.ViewModels;

public sealed class MetricItem
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => $"{Value} {Caption}";

    public string Value { get; init; } = "";
    public string Caption { get; init; } = "";
    public string Glyph { get; init; } = "\uE946";
    public Brush? Tint { get; init; }
}
