using ServerMaster.Windows.Models;

internal static class ProfileIconsSmokeTests
{
    public static void Run()
    {
        var all = ProfileIcons.All.ToArray();
        Check(ProfileIcons.Groups.Select(group => group.Title).SequenceEqual(["Servers", "Development", "Sites", "Status", "Other"]), "groups follow the macOS order");
        Check(all.Length == all.Select(icon => icon.Glyph).Distinct().Count() && all.All(icon => icon.Glyph.Length == 1), "every icon is one distinct glyph");
        // Glyphs the old Windows rename dialog offered must still show as selected for saved profiles.
        Check(new[] { "", "", "", "", "" }.All(glyph => all.Any(icon => icon.Glyph == glyph)), "icons chosen with the previous dialog stay in the catalogue");
        Check(ProfileIcons.Search("").Sum(group => group.Icons.Count) == all.Length, "an empty search shows everything");
        var shop = ProfileIcons.Search("  CART ");
        Check(shop.Count == 1 && shop[0].Title == "Sites" && shop[0].Icons.Single().Name == "Shop", "search matches keywords, ignores case and spaces, and drops empty groups");
        Check(ProfileIcons.Search("no-such-icon").Count == 0, "a search without matches returns no groups");
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Profile icons: " + description);
    }
}
