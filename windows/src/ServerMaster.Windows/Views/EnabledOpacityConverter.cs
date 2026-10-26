using Microsoft.UI.Xaml.Data;

namespace ServerMaster.Windows.Views;

/// <summary>
/// Dims an accent-coloured icon when its button is disabled. An icon with its own Foreground
/// keeps that colour in the button's Disabled state, so without this it would look clickable.
/// </summary>
public sealed class EnabledOpacityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) => value is false ? 0.4 : 1.0;

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
