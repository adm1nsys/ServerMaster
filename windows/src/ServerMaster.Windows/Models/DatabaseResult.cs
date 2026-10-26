using System.Xml.Linq;

namespace ServerMaster.Windows.Models;

public sealed record DatabaseResult(IReadOnlyList<string> Columns, IReadOnlyList<DatabaseRow> Rows)
{
    public static DatabaseResult Parse(string xml)
    {
        if (string.IsNullOrWhiteSpace(xml)) return new([], []);
        var root = XDocument.Parse(xml).Root ?? throw new IOException("MariaDB returned an empty result.");
        var rows = root.Elements("row").ToArray();
        var columns = rows.FirstOrDefault()?.Elements("field").Select(f => (string?)f.Attribute("name") ?? "").ToArray() ?? [];
        XNamespace xsi = "http://www.w3.org/2001/XMLSchema-instance";
        return new(columns, rows.Select(row => new DatabaseRow(row.Elements("field")
            .Select(f => (string?)f.Attribute(xsi + "nil") == "true" ? null : f.Value).ToArray())).ToArray());
    }
}

public sealed record DatabaseRow(IReadOnlyList<string?> Values)
{
    public IReadOnlyList<string> Cells => Values.Select(value => value ?? "NULL").ToArray();

    // Grid rows are named after their cells for screen readers (records print their type otherwise).
    public override string ToString() => string.Join(", ", Cells);
}
