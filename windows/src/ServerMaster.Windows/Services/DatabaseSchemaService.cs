using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed record DatabaseColumnInfo(string Name, string Type, bool Nullable, string Key, string Extra)
{
    public string Display => $"{Name}    {Type}    {(Nullable ? "NULL" : "NOT NULL")}    {Key} {Extra}".TrimEnd();
}

public sealed record DatabaseIndexInfo(string Name, IReadOnlyList<string> Columns, bool IsUnique)
{
    public bool IsPrimary => Name.Equals("PRIMARY", StringComparison.OrdinalIgnoreCase);
    public string Display => $"{Name}    {string.Join(", ", Columns)}    {(IsUnique ? "unique" : "index")}";
}

public static class DatabaseSchemaService
{
    public static readonly string[] CommonTypes =
    [
        "INT", "BIGINT", "SMALLINT", "TINYINT", "VARCHAR(255)", "VARCHAR(64)",
        "CHAR(36)", "TEXT", "MEDIUMTEXT", "LONGTEXT", "DECIMAL(10,2)",
        "FLOAT", "DOUBLE", "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR",
        "BOOLEAN", "JSON", "BLOB"
    ];

    public static async Task<IReadOnlyList<DatabaseColumnInfo>> ColumnsAsync(string database, string table)
    {
        var result = await DatabaseService.BrowseTableAsync(database, table, structure: true);
        var fields = result.Columns.Select((name, index) => (name, index))
            .ToDictionary(item => item.name, item => item.index, StringComparer.OrdinalIgnoreCase);
        string Cell(DatabaseRow row, string name) => fields.TryGetValue(name, out var index) && index < row.Values.Count
            ? row.Values[index] ?? "" : "";
        return result.Rows.Select(row => new DatabaseColumnInfo(
            Cell(row, "Field"), Cell(row, "Type"), Cell(row, "Null") == "YES",
            Cell(row, "Key"), Cell(row, "Extra"))).ToArray();
    }

    public static async Task<IReadOnlyList<DatabaseIndexInfo>> IndexesAsync(string database, string table)
    {
        var result = await DatabaseService.RunResultQueryAsync(database, "SHOW INDEX FROM " + QuoteIdentifier(table) + ";");
        var fields = result.Columns.Select((name, index) => (name, index))
            .ToDictionary(item => item.name, item => item.index, StringComparer.OrdinalIgnoreCase);
        string Cell(DatabaseRow row, string name) => fields.TryGetValue(name, out var index) && index < row.Values.Count
            ? row.Values[index] ?? "" : "";
        return result.Rows.GroupBy(row => Cell(row, "Key_name"), StringComparer.OrdinalIgnoreCase)
            .Select(group => new DatabaseIndexInfo(group.Key,
                group.OrderBy(row => int.TryParse(Cell(row, "Seq_in_index"), out var sequence) ? sequence : int.MaxValue)
                    .Select(row => Cell(row, "Column_name")).ToArray(),
                Cell(group.First(), "Non_unique") == "0"))
            .OrderByDescending(index => index.IsPrimary).ThenBy(index => index.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static async Task AddIndexAsync(string database, string table, string name, IReadOnlyList<string> columns, bool unique)
    {
        var quotedTable = QuoteIdentifier(table);
        var quotedName = QuoteIdentifier(name);
        if (name.Equals("PRIMARY", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Use the table's primary key for PRIMARY; choose another index name.");
        if (columns.Count == 0 || columns.Distinct(StringComparer.OrdinalIgnoreCase).Count() != columns.Count)
            throw new InvalidOperationException("Choose one or more distinct columns for the index.");
        var available = (await ColumnsAsync(database, table)).Select(column => column.Name)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (columns.Any(column => !available.Contains(column)))
            throw new InvalidOperationException("An index column does not exist in this table. Refresh the structure.");
        var quotedColumns = string.Join(", ", columns.Select(QuoteIdentifier));
        await DatabaseService.RunQueryAsync(database,
            $"ALTER TABLE {quotedTable} ADD {(unique ? "UNIQUE INDEX" : "INDEX")} {quotedName} ({quotedColumns});");
    }

    public static async Task DropIndexAsync(string database, string table, string name)
    {
        var quotedTable = QuoteIdentifier(table);
        var sql = name.Equals("PRIMARY", StringComparison.OrdinalIgnoreCase)
            ? $"ALTER TABLE {quotedTable} DROP PRIMARY KEY;"
            : $"ALTER TABLE {quotedTable} DROP INDEX {QuoteIdentifier(name)};";
        await DatabaseService.RunQueryAsync(database, sql);
    }

    public static async Task CreateTableAsync(string database, string table)
    {
        var quoted = QuoteIdentifier(table);
        await DatabaseService.RunQueryAsync(database,
            $"CREATE TABLE {quoted} (`id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;");
    }

    public static async Task AddColumnAsync(string database, string table, string name, string type, bool nullable)
    {
        var quotedTable = QuoteIdentifier(table);
        var quotedColumn = QuoteIdentifier(name);
        if (!CommonTypes.Contains(type, StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException("Choose a supported column type from the list.");
        await DatabaseService.RunQueryAsync(database,
            $"ALTER TABLE {quotedTable} ADD COLUMN {quotedColumn} {type} {(nullable ? "NULL" : "NOT NULL")};");
    }

    public static async Task ChangeColumnAsync(string database, string table, string existingName, string newName, string type, bool nullable)
    {
        var columns = await ColumnsAsync(database, table);
        if (!columns.Any(column => column.Name.Equals(existingName, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("This column no longer exists. Refresh the structure.");
        if (!existingName.Equals(newName, StringComparison.OrdinalIgnoreCase) &&
            columns.Any(column => column.Name.Equals(newName, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Another column already has that name.");
        if (!CommonTypes.Contains(type, StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException("Choose a supported column type from the list.");
        await DatabaseService.RunQueryAsync(database,
            $"ALTER TABLE {QuoteIdentifier(table)} CHANGE COLUMN {QuoteIdentifier(existingName)} {QuoteIdentifier(newName)} {type} {(nullable ? "NULL" : "NOT NULL")};");
    }

    public static async Task DropColumnAsync(string database, string table, string name)
    {
        var columns = await ColumnsAsync(database, table);
        if (!columns.Any(column => column.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("This column no longer exists. Refresh the structure.");
        if (columns.Count == 1)
            throw new InvalidOperationException("A table must retain at least one column. Drop the table instead.");
        await DatabaseService.RunQueryAsync(database,
            $"ALTER TABLE {QuoteIdentifier(table)} DROP COLUMN {QuoteIdentifier(name)};");
    }

    public static async Task RenameTableAsync(string database, string table, string newName)
    {
        await DatabaseService.RunQueryAsync(database,
            $"RENAME TABLE {QuoteIdentifier(table)} TO {QuoteIdentifier(newName)};");
    }

    public static async Task EmptyTableAsync(string database, string table)
    {
        await DatabaseService.RunQueryAsync(database, $"TRUNCATE TABLE {QuoteIdentifier(table)};");
    }

    public static async Task DropTableAsync(string database, string table)
    {
        await DatabaseService.RunQueryAsync(database, $"DROP TABLE {QuoteIdentifier(table)};");
    }

    public static async Task<string> CreateStatementAsync(string database, string table)
    {
        var output = await DatabaseService.RunQueryAsync(database, "SHOW CREATE TABLE " + QuoteIdentifier(table) + ";");
        var tab = output.IndexOf('\t');
        return (tab < 0 ? output : output[(tab + 1)..]).Replace("\\n", Environment.NewLine);
    }

    private static string QuoteIdentifier(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 64 || value.Contains('\0'))
            throw new InvalidOperationException("Names must be 1-64 characters and cannot contain a null character.");
        return "`" + value.Replace("`", "``") + "`";
    }
}
