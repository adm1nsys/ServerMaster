using System.ComponentModel;
using System.Runtime.CompilerServices;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class DependencyStatus : INotifyPropertyChanged
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => $"{Dependency.Title}: {StatusText}";

    private bool _installed;
    private bool _checking;
    private bool _busy;
    private string _version = "";
    private string _path = "";
    private string _message = "";
    private string _error = "";
    private double _progress;
    private bool _checked;
    private string _removalBlockedReason = "";
    private string _availableVersion = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    public required Dependency Dependency { get; init; }

    public bool Installed
    {
        get => _installed;
        set
        {
            if (SetProperty(ref _installed, value))
            {
                NotifyState();
            }
        }
    }

    public bool Checking
    {
        get => _checking;
        set { if (SetProperty(ref _checking, value)) NotifyState(); }
    }

    public bool Busy
    {
        get => _busy;
        set { if (SetProperty(ref _busy, value)) NotifyState(); }
    }

    public string Version
    {
        get => _version;
        set { if (SetProperty(ref _version, value)) OnPropertyChanged(nameof(DisplayMessage)); }
    }

    public string Path
    {
        get => _path;
        set => SetProperty(ref _path, value);
    }

    public string Message
    {
        get => _message;
        set { if (SetProperty(ref _message, value)) OnPropertyChanged(nameof(DisplayMessage)); }
    }

    /// <summary>The message, unless it only repeats the version shown on the line above.</summary>
    public string DisplayMessage => _message.Trim() == _version.Trim() ? "" : _message;

    public bool Checked { get => _checked; set { if (SetProperty(ref _checked, value)) NotifyState(); } }
    public string Error { get => _error; set { if (SetProperty(ref _error, value)) NotifyState(); } }
    public double Progress { get => _progress; set => SetProperty(ref _progress, value); }
    public bool IsIndeterminate => Dependency.PhpVersion.Length == 0 || Checking;
    public string AvailableVersion { get => _availableVersion; set => SetProperty(ref _availableVersion, value); }
    public Microsoft.UI.Xaml.Visibility VersionSelectionVisibility => Dependency.Command == "http-server" ||
        Dependency.WingetId is not null && Dependency.Command is not ("npm" or "vcredist" or "winget")
        ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public Microsoft.UI.Xaml.Visibility UpdateCheckVisibility => Dependency.Command != "npm" &&
        (Dependency.Command is "vcredist" or "http-server" || Dependency.PhpVersion.Length > 0 || Dependency.WingetId is not null)
        ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    // The Visual C++ runtime's own action is already "Update / repair".
    public Microsoft.UI.Xaml.Visibility UpdateActionVisibility => Installed && Dependency.Command != "vcredist" && UpdateCheckVisibility == Microsoft.UI.Xaml.Visibility.Visible
        ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public string RemovalBlockedReason { get => _removalBlockedReason; set { if (SetProperty(ref _removalBlockedReason, value)) NotifyState(); } }
    public bool CanAct => !Busy && !Checking && !(Installed && Dependency.Command == "npm") && (!Installed || RemovalBlockedReason.Length == 0) && (Dependency.Command is "vcredist" or "adminer" or "phpmyadmin" || Dependency.PhpVersion.Length > 0 || Dependency.WingetId is not null || Dependency.InstallCommand is not null);
    public Microsoft.UI.Xaml.Visibility ActivityVisibility => Busy || Checking ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public Microsoft.UI.Xaml.Visibility ErrorVisibility => Error.Length > 0 ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    public string StatusText => Localization.T(Busy ? "In progress" : Checking ? "Checking" : Error.Length > 0 ? "Failed" : !Checked ? "Not checked" : Installed ? "Installed" : "Missing");
    public string ActionText => Localization.T(Busy ? "Please wait..." : Installed && Dependency.Command == "npm" ? "Included with Node.js" : Error.Length > 0 && !Installed ? "Retry" : !Checked ? "Check" : Installed ? Dependency.Command == "vcredist" ? "Update / repair" : "Remove" : "Install");

    private void NotifyState()
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(ActionText));
        OnPropertyChanged(nameof(CanAct));
        OnPropertyChanged(nameof(ActivityVisibility));
        OnPropertyChanged(nameof(ErrorVisibility));
        OnPropertyChanged(nameof(IsIndeterminate));
        OnPropertyChanged(nameof(UpdateActionVisibility));
    }

    private bool SetProperty<T>(ref T storage, T value, [CallerMemberName] string propertyName = "")
    {
        if (EqualityComparer<T>.Default.Equals(storage, value))
        {
            return false;
        }

        storage = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string propertyName = "")
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
