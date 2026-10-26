namespace ServerMaster.Windows.Models;

public sealed class FileEntry
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => Name;

    public string Name { get; init; } = "";
    public string FullPath { get; init; } = "";
    public bool IsDirectory { get; init; }
    public bool IsLink { get; init; }
    public bool IsHidden { get; init; }
    public bool IsConfig { get; init; }
    public bool IsHiddenOrConfig => IsHidden || IsConfig;
    public long Size { get; init; }
    public DateTime LastWriteTime { get; init; }
    public string TypeLabel => IsLink ? "Windows link" : IsDirectory ? "Folder" : Path.GetExtension(Name).TrimStart('.').ToUpperInvariant() switch
    {
        "" => "File",
        var extension => extension + " file"
    };
    public string SizeLabel => IsDirectory ? "" : Size < 1024 ? $"{Size} B" : $"{Size / 1024d:0.#} KB";
    public string ModifiedLabel => LastWriteTime.ToString("g");
    public string Glyph => IsDirectory ? "\uE8B7" : IsHidden ? "\uED1A" : "\uE8A5";
    public bool CanEdit => !IsDirectory && !IsLink && Size <= Services.SiteFiles.MaxEditorBytes;
}
