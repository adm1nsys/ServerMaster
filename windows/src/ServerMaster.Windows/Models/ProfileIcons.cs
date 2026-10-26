namespace ServerMaster.Windows.Models;

/// <summary>One choosable profile icon: a Segoe Fluent/MDL2 glyph with words to find it by.</summary>
public sealed record ProfileIcon(string Name, string Glyph, string Keywords = "")
{
    public bool Matches(string needle) =>
        needle.Length == 0 || $"{Name} {Keywords}".Contains(needle, StringComparison.OrdinalIgnoreCase);
}

public sealed record ProfileIconGroup(string Title, IReadOnlyList<ProfileIcon> Icons);

/// <summary>
/// The icons offered for a profile, grouped like macOS <c>ProfileIcons.swift</c>. The glyphs
/// exist in both Segoe MDL2 Assets (Windows 10) and Segoe Fluent Icons (Windows 11).
/// </summary>
public static class ProfileIcons
{
    public static IReadOnlyList<ProfileIconGroup> Groups { get; } =
    [
        new("Servers",
        [
            new("Server", "", "network rack host"), new("Package", "", "box shipping container"),
            new("Home", "", "house start"), new("Monitor", "", "screen display"),
            new("Puzzle", "", "plugin extension module"), new("Administrator", "", "admin shield"),
            new("Diagnostics", "", "health pulse")
        ]),
        new("Development",
        [
            new("Code", "", "html source brackets"), new("Terminal", "", "command prompt shell console"),
            new("Settings", "", "gear cog configuration"), new("Repair", "", "wrench tool fix"),
            new("Bug", "", "debug ladybug"), new("Developer tools", "", "hammer build"),
            new("Document", "", "file text")
        ]),
        new("Sites",
        [
            new("Website", "", "globe web internet"), new("Library", "", "books archive"),
            new("Book", "", "dictionary docs guide"), new("Picture", "", "photo image gallery"),
            new("Shop", "", "cart store commerce"), new("Page", "", "news article blog"),
            new("People", "", "community forum users")
        ]),
        new("Status",
        [
            new("Lightning", "", "bolt fast"), new("Star", "", "favourite favorite"),
            new("Heart", "", "love like"), new("Flag", "", "mark"),
            new("Pin", "", "pinned"), new("Bookmark", "", "saved"),
            new("Tag", "", "label")
        ]),
        new("Other",
        [
            new("Folder", "", "directory"), new("New folder", "", "directory add"),
            new("Lock", "", "secure private https"), new("Game", "", "controller play"),
            new("Moon", "", "night quiet"), new("Sun", "", "day brightness"),
            new("Permissions", "", "key access")
        ])
    ];

    public static IEnumerable<ProfileIcon> All => Groups.SelectMany(group => group.Icons);

    /// <summary>Groups with the icons whose name or keywords contain the search text; empty groups are dropped.</summary>
    public static IReadOnlyList<ProfileIconGroup> Search(string text)
    {
        var needle = (text ?? "").Trim();
        return Groups.Select(group => new ProfileIconGroup(group.Title, group.Icons.Where(icon => icon.Matches(needle)).ToArray()))
            .Where(group => group.Icons.Count > 0).ToArray();
    }
}
