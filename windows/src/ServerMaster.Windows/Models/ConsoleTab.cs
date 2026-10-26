using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class ConsoleTab : INotifyPropertyChanged
{
    private bool _isSelected;
    private string _shellKind = "PowerShell";
    private string _terminalText = "";
    private string _title = "Terminal";
    private readonly ServerProfile? _profile;
    public event PropertyChangedEventHandler? PropertyChanged;
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Title { get => _title; set { SetProperty(ref _title, value); PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CloseName))); } }
    /// <summary>Names each tab's close button after its tab, so screen readers can tell them apart.</summary>
    public string CloseName => Localization.T("Close %@").Replace("%@", Localization.T(Title), StringComparison.Ordinal);
    public bool IsTerminal { get; init; }
    public Guid? ProfileId => _profile?.Id;

    /// <summary>The server whose log this tab shows; null for a terminal tab.</summary>
    public ServerProfile? Profile
    {
        get => _profile;
        init
        {
            _profile = value;
            if (value is null) return;
            _title = value.Name;
            value.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(ServerProfile.Name)) Title = value.Name;
                if (e.PropertyName is nameof(ServerProfile.State) or nameof(ServerProfile.StateTint))
                {
                    OnPropertyChanged(nameof(StopVisibility));
                    OnPropertyChanged(nameof(StateTint));
                }
            };
        }
    }

    public bool IsSelected { get => _isSelected; set => SetProperty(ref _isSelected, value); }
    public string ShellKind { get => _shellKind; set => SetProperty(ref _shellKind, value); }
    public ObservableCollection<LogLine> Lines { get; } = [];
    public TerminalSession? Session { get; set; }
    public string TerminalText { get => _terminalText; set => SetProperty(ref _terminalText, value); }

    // Terminal tabs carry a close button; server tabs a status dot and, while active, Stop.
    public Visibility CloseVisibility => IsTerminal ? Visibility.Visible : Visibility.Collapsed;
    public Visibility StateVisibility => IsTerminal ? Visibility.Collapsed : Visibility.Visible;
    public Visibility StopVisibility => _profile?.IsActive == true ? Visibility.Visible : Visibility.Collapsed;
    public string StateTint => _profile?.StateTint ?? "#A6AAB4";
    public string Glyph => IsTerminal ? "" : "";

    private void SetProperty<T>(ref T storage, T value, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(storage, value)) return;
        storage = value;
        OnPropertyChanged(name);
    }

    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
