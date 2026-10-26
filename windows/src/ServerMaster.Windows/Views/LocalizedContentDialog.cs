using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Views;

/// <summary>Applies the same literal-string localization to code-built dialogs as to the main XAML tree.</summary>
public class LocalizedContentDialog : Microsoft.UI.Xaml.Controls.ContentDialog
{
    public LocalizedContentDialog()
    {
        Opened += (_, _) => XamlTranslator.Apply(this);
    }
}
