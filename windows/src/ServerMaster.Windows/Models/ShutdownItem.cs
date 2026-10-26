using System.ComponentModel;

namespace ServerMaster.Windows.Models;

public enum ShutdownItemStatus { Waiting, Stopping, Stopped, Failed }

/// <summary>One row of the quit progress panel, matching the macOS ShutdownView.</summary>
public sealed class ShutdownItem(string name) : INotifyPropertyChanged
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => $"{Name}: {Detail}";

    private ShutdownItemStatus _status;
    private string _detail = "waiting";

    public event PropertyChangedEventHandler? PropertyChanged;
    public string Name { get; } = name;
    public ShutdownItemStatus Status => _status;
    public string Detail => _detail;
    public string Glyph => _status switch
    {
        ShutdownItemStatus.Stopped => "",
        ShutdownItemStatus.Failed => "",
        ShutdownItemStatus.Stopping => "",
        _ => ""
    };
    public string Tint => _status switch
    {
        ShutdownItemStatus.Stopped => "#32B875",
        ShutdownItemStatus.Failed => "#E8A13A",
        _ => "#A6AAB4"
    };

    public void Update(ShutdownItemStatus status, string detail)
    {
        _status = status;
        _detail = detail;
        foreach (var property in new[] { nameof(Status), nameof(Detail), nameof(Glyph), nameof(Tint) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }
}
