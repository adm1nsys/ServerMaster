using System.ComponentModel;
using System.Text.Json.Serialization;

namespace ServerMaster.Windows.Models;

public sealed class BackupEntry : INotifyPropertyChanged
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Name;

    private bool _canRestore;
    public event PropertyChangedEventHandler? PropertyChanged;
    [JsonIgnore]
    public bool CanRestore
    {
        get => _canRestore;
        set
        {
            if (_canRestore == value) return;
            _canRestore = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanRestore)));
        }
    }
    public string Id { get; init; } = "";
    public string Kind { get; init; } = "profile";
    public Guid? ProfileId { get; init; }
    public string ProfileName { get; init; } = "";
    public DateTime Taken { get; init; }
    public string Trigger { get; init; } = "manual";
    public bool IncludesSite { get; init; }
    public bool IncludesDatabase { get; init; }
    public string? DatabaseName { get; init; }
    public long Bytes { get; init; }
    public string? Note { get; init; }
    public string Name => ProfileName;
    public string FullPath { get; init; } = "";
    public DateTime CreatedAt => Taken;
    public long Size => Bytes;
    public string SizeLabel => Size < 1024 * 1024 ? $"{Size / 1024d:0.#} KB" : $"{Size / 1024d / 1024d:0.#} MB";
    public string ContentsLabel
    {
        get
        {
            if (Kind == "database") return "database only · " + SizeLabel;
            var parts = new List<string> { "settings" };
            if (IncludesSite) parts.Add("files");
            if (IncludesDatabase && !string.IsNullOrWhiteSpace(DatabaseName)) parts.Add(DatabaseName!);
            return string.Join(" · ", parts) + "  " + SizeLabel + (string.IsNullOrWhiteSpace(Note) ? "" : "  ·  " + Note);
        }
    }
}
