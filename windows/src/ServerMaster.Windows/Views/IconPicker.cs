using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Views;

/// <summary>
/// Choosing a profile icon by looking at it, as in macOS <c>IconPickerSheet.swift</c>: the engine's
/// own icon first, then a searchable grid per group. An empty selection means "same as the engine".
/// </summary>
public sealed class IconPicker : StackPanel
{
    private readonly string _engineGlyph;
    private readonly string? _customGlyph;
    private readonly StackPanel _groups = new() { Spacing = 12 };
    private readonly List<ToggleButton> _cells = [];
    public string SelectedGlyph { get; private set; }

    public IconPicker(string engineGlyph, string currentGlyph)
    {
        _engineGlyph = engineGlyph;
        SelectedGlyph = currentGlyph ?? "";
        // A glyph saved by an older build that is not in the catalogue stays choosable.
        _customGlyph = SelectedGlyph.Length > 0 && ProfileIcons.All.All(icon => icon.Glyph != SelectedGlyph) ? SelectedGlyph : null;
        Spacing = 10;
        var search = new TextBox { PlaceholderText = Localization.T("Search icons") };
        search.TextChanged += (_, _) => Build(search.Text);
        Children.Add(search);
        Children.Add(new ScrollViewer { Content = _groups, MaxHeight = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Build("");
    }

    private void Build(string text)
    {
        _groups.Children.Clear();
        _cells.Clear();
        var defaults = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 52, ItemHeight = 46 };
        defaults.Children.Add(Cell(_engineGlyph, "", Localization.T("Same as the engine")));
        if (_customGlyph is not null) defaults.Children.Add(Cell(_customGlyph, _customGlyph, Localization.T("Current icon")));
        _groups.Children.Add(Section(Localization.T("Default"), defaults));
        var groups = ProfileIcons.Search(text);
        foreach (var group in groups)
        {
            var grid = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 52, ItemHeight = 46 };
            foreach (var icon in group.Icons) grid.Children.Add(Cell(icon.Glyph, icon.Glyph, Localization.T(icon.Name)));
            _groups.Children.Add(Section(Localization.T(group.Title), grid));
        }
        if (groups.Count == 0)
            _groups.Children.Add(new TextBlock { Text = Localization.T("No icons match the search."), Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
    }

    private static StackPanel Section(string title, UIElement content)
    {
        var section = new StackPanel { Spacing = 6 };
        section.Children.Add(new TextBlock { Text = title, FontSize = 12, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        section.Children.Add(content);
        return section;
    }

    private ToggleButton Cell(string glyph, string value, string name)
    {
        var cell = new ToggleButton
        {
            Width = 46, Height = 40, Padding = new Thickness(0), Tag = value,
            IsChecked = value == SelectedGlyph,
            Content = new FontIcon { Glyph = glyph, FontSize = 20 }
        };
        ToolTipService.SetToolTip(cell, name);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, name);
        cell.Click += (_, _) =>
        {
            SelectedGlyph = value;
            foreach (var other in _cells) other.IsChecked = (string)other.Tag == value;
        };
        _cells.Add(cell);
        return cell;
    }
}
