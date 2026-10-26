using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Data;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using ServerMaster.Windows.ViewModels;

namespace ServerMaster.Windows;

public sealed class CertificateDialog : ContentDialog
{
    private bool _busy;
    public CertificateDialog(MainWindow owner, MainViewModel model, ServerProfile profile, bool preferTrust = false)
    {
        Title = "Local HTTPS certificate";
        XamlRoot = owner.Content.XamlRoot;
        PrimaryButtonText = preferTrust ? "Generate trusted certificate" : "Generate certificate";
        CloseButtonText = "Cancel";
        var names = new TextBox { Header = "Host names and IP addresses", Text = "localhost 127.0.0.1 ::1" + (profile.Host is "0.0.0.0" or "::" ? "" : " " + profile.Host) };
        var trust = new CheckBox { Content = "Trust this certificate for my Windows account", IsChecked = preferTrust };
        var warning = new TextBlock { Text = "Trust adds this 90-day certificate to your Windows trusted certificates. Without trust, browsers show a certificate warning.", TextWrapping = TextWrapping.Wrap };
        var status = model.Dependencies.First(item => item.Dependency.Command == "caddy");
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        message.SetBinding(TextBlock.TextProperty, new Binding { Source = status, Path = new PropertyPath(nameof(status.Message)) });
        var progress = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = true };
        var install = new Button { Content = "Install HTTPS dependency (Caddy)" };
        var fields = new StackPanel { Spacing = 12, MaxWidth = 480 };
        foreach (var element in new UIElement[] { names, trust, warning, message, install, progress, error }) fields.Children.Add(element);
        Content = fields;
        Closing += (_, e) => { if (_busy) e.Cancel = true; };
        void Busy(bool value)
        {
            _busy = value; IsPrimaryButtonEnabled = !value; install.IsEnabled = !value; names.IsEnabled = !value; trust.IsEnabled = !value;
            progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
        install.Click += async (_, _) =>
        {
            if (_busy) return;
            Busy(true); error.IsOpen = false;
            try { await model.InstallDependencyAsync(status); }
            catch (Exception ex) { error.Message = ex.Message; error.IsOpen = true; }
            finally { Busy(false); }
        };
        PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            if (_busy) return;
            var deferral = e.GetDeferral();
            Busy(true); error.IsOpen = false;
            try
            {
                if (profile.IsActive || profile.IsBusy) throw new InvalidOperationException("Stop this profile before replacing its certificate.");
                if (!status.Installed || status.Busy) throw new InvalidOperationException("Install Caddy using the button above, then generate the certificate. Certificate generation itself needs no extra software.");
                var copy = new ServerProfile { Id = profile.Id };
                var domains = names.Text;
                var shouldTrust = trust.IsChecked == true;
                await Task.Run(() => LocalCertificates.Generate(copy, domains, shouldTrust));
                profile.CertificatePath = copy.CertificatePath;
                profile.PrivateKeyPath = copy.PrivateKeyPath;
                profile.HttpsEnabled = true;
                model.Save();
                e.Cancel = false;
            }
            catch (Exception ex) { error.Message = ex.Message; error.IsOpen = true; }
            finally { Busy(false); deferral.Complete(); }
        };
        Opened += async (_, _) =>
        {
            Busy(true);
            try { await model.CheckHttpsDependencyAsync(); }
            catch (Exception ex) { error.Message = ex.Message; error.IsOpen = true; }
            finally { Busy(false); }
        };
    }
}
