using Microsoft.UI.Xaml.Media;

namespace ServerMaster.Windows.ViewModels;

public sealed class ColorOption
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => ServerMaster.Windows.Services.Localization.T(Title);

    public required string Id { get; init; }
    public required string Title { get; init; }
    public SolidColorBrush Brush => new(Microsoft.UI.ColorHelper.FromArgb(
        255,
        Convert.ToByte(Id[1..3], 16),
        Convert.ToByte(Id[3..5], 16),
        Convert.ToByte(Id[5..7], 16)));
}
