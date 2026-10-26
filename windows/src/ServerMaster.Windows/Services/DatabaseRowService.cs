using System.Text;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class DatabaseRowService
{
    public static async Task UpdateCellAsync(string database, string table, DatabaseResult result,
        DatabaseRow row, IReadOnlyList<DatabaseColumnInfo> schema, string columnName, string? value)
    {
        var column = schema.FirstOrDefault(item => item.Name.Equals(columnName, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException("The selected column no longer exists. Refresh the table.");
        if (value is null && !column.Nullable)
            throw new InvalidOperationException($"{column.Name} does not allow NULL.");
        var where = KeyCondition(result, row, schema);
        await DatabaseService.RunQueryAsync(database,
            $"UPDATE {QuoteIdentifier(table)} SET {QuoteIdentifier(column.Name)} = {SqlValue(value)} WHERE {where} LIMIT 1;");
    }

    public static async Task DeleteRowAsync(string database, string table, DatabaseResult result,
        DatabaseRow row, IReadOnlyList<DatabaseColumnInfo> schema)
    {
        var where = KeyCondition(result, row, schema);
        await DatabaseService.RunQueryAsync(database, $"DELETE FROM {QuoteIdentifier(table)} WHERE {where} LIMIT 1;");
    }

    public static async Task InsertEmptyRowAsync(string database, string table, IReadOnlyList<DatabaseColumnInfo> schema)
    {
        var fillable = schema.Where(column => !column.Extra.Contains("auto_increment", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (fillable.Length == 0)
        {
            await DatabaseService.RunQueryAsync(database, $"INSERT INTO {QuoteIdentifier(table)} () VALUES ();");
            return;
        }

        var names = string.Join(", ", fillable.Select(column => QuoteIdentifier(column.Name)));
        var values = string.Join(", ", fillable.Select(column => column.Nullable ? "NULL" : DefaultValue(column.Type)));
        await DatabaseService.RunQueryAsync(database, $"INSERT INTO {QuoteIdentifier(table)} ({names}) VALUES ({values});");
    }

    private static string KeyCondition(DatabaseResult result, DatabaseRow row, IReadOnlyList<DatabaseColumnInfo> schema)
    {
        var keys = schema.Where(column => column.Key == "PRI").ToArray();
        if (keys.Length == 0) throw new InvalidOperationException("This table has no primary key, so rows cannot be edited safely.");
        var conditions = new List<string>();
        foreach (var key in keys)
        {
            var index = -1;
            for (var candidate = 0; candidate < result.Columns.Count; candidate++)
                if (result.Columns[candidate].Equals(key.Name, StringComparison.OrdinalIgnoreCase)) { index = candidate; break; }
            if (index < 0 || index >= row.Values.Count || row.Values[index] is null)
                throw new InvalidOperationException("The primary key is missing from this row. Refresh the table.");
            conditions.Add($"{QuoteIdentifier(key.Name)} = {SqlValue(row.Values[index])}");
        }
        return string.Join(" AND ", conditions);
    }

    private static string DefaultValue(string type)
    {
        var lower = type.ToLowerInvariant();
        if (lower.StartsWith("int") || lower.StartsWith("bigint") || lower.StartsWith("smallint") ||
            lower.StartsWith("tinyint") || lower.StartsWith("decimal") || lower.StartsWith("float") || lower.StartsWith("double")) return "0";
        if (lower.StartsWith("date") || lower.StartsWith("timestamp")) return "NOW()";
        return "''";
    }

    private static string SqlValue(string? value)
    {
        if (value is null) return "NULL";
        if (value.Length == 0) return "''";
        return "CONVERT(0x" + Convert.ToHexString(Encoding.UTF8.GetBytes(value)) + " USING utf8mb4)";
    }

    private static string QuoteIdentifier(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 64 || value.Contains('\0'))
            throw new InvalidOperationException("Invalid table or column name.");
        return "`" + value.Replace("`", "``") + "`";
    }
}
