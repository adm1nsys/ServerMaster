using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed record DatabaseAccount(string Name, string Host)
{
    public string Display => $"{Name}@{Host}";
    public bool IsManaged => Name.Equals("root", StringComparison.OrdinalIgnoreCase) ||
        Name.StartsWith("mysql.", StringComparison.OrdinalIgnoreCase) ||
        Name.Equals("servermaster_panel", StringComparison.OrdinalIgnoreCase);
}

public static class DatabaseAccountService
{
    public static async Task<IReadOnlyList<DatabaseAccount>> ListAsync(string database)
    {
        var result = await DatabaseService.RunResultQueryAsync(database,
            "SELECT User, Host FROM mysql.user WHERE User <> '' ORDER BY User, Host;");
        return result.Rows.Where(row => row.Values.Count >= 2 && !string.IsNullOrEmpty(row.Values[0]))
            .Select(row => new DatabaseAccount(row.Values[0]!, row.Values[1] ?? ""))
            .ToArray();
    }

    public static async Task<IReadOnlyList<string>> GrantsAsync(string database, DatabaseAccount account)
    {
        var result = await DatabaseService.RunResultQueryAsync(database, $"SHOW GRANTS FOR {AccountSql(account)};");
        return result.Rows.Select(row => row.Values.FirstOrDefault() ?? "").ToArray();
    }

    public static Task CreateAsync(string database, string name, string host, string password)
    {
        var account = new DatabaseAccount(name.Trim(), string.IsNullOrWhiteSpace(host) ? "localhost" : host.Trim());
        EnsureEditable(account);
        ValidatePassword(password);
        return DatabaseService.RunQueryAsync(database,
            $"CREATE USER {AccountSql(account)} IDENTIFIED BY {Quote(password)};");
    }

    public static Task ChangePasswordAsync(string database, DatabaseAccount account, string password)
    {
        EnsureEditable(account);
        ValidatePassword(password);
        return DatabaseService.RunQueryAsync(database,
            $"ALTER USER {AccountSql(account)} IDENTIFIED BY {Quote(password)};");
    }

    public static async Task GrantAsync(string database, DatabaseAccount account, bool readOnly)
    {
        EnsureEditable(account);
        var scope = DatabaseSql(database);
        var existing = await GrantsAsync(database, account);
        if (existing.Any(grant => grant.Contains($"ON {scope}.* TO", StringComparison.OrdinalIgnoreCase)))
            await DatabaseService.RunQueryAsync(database,
                $"REVOKE ALL PRIVILEGES ON {scope}.* FROM {AccountSql(account)};");
        await DatabaseService.RunQueryAsync(database,
            $"GRANT {(readOnly ? "SELECT" : "ALL PRIVILEGES")} ON {scope}.* TO {AccountSql(account)};");
    }

    public static Task RevokeAsync(string database, DatabaseAccount account)
    {
        EnsureEditable(account);
        return DatabaseService.RunQueryAsync(database,
            $"REVOKE ALL PRIVILEGES ON {DatabaseSql(database)}.* FROM {AccountSql(account)};");
    }

    public static Task DropAsync(string database, DatabaseAccount account)
    {
        EnsureEditable(account);
        return DatabaseService.RunQueryAsync(database, $"DROP USER {AccountSql(account)};");
    }

    private static string DatabaseSql(string database)
    {
        if (!DatabaseService.IsValidName(database)) throw new InvalidOperationException("Invalid database name.");
        return $"`{database}`";
    }

    private static string AccountSql(DatabaseAccount account)
    {
        if (!DatabaseService.IsValidName(account.Name) || account.Name.Length > 32 ||
            account.Host.Length is < 1 or > 255 ||
            !account.Host.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' or '%' or ':'))
            throw new InvalidOperationException("Account names must be 1-32 letters, digits or underscores; check the host.");
        return $"{Quote(account.Name)}@{Quote(account.Host)}";
    }

    private static void EnsureEditable(DatabaseAccount account)
    {
        if (account.IsManaged) throw new InvalidOperationException("This system or ServerMaster account cannot be changed here.");
        _ = AccountSql(account);
    }

    private static void ValidatePassword(string password)
    {
        if (string.IsNullOrEmpty(password) || password.Contains('\0'))
            throw new InvalidOperationException("Enter a nonempty password.");
    }

    private static string Quote(string value) => "'" + value.Replace("\\", "\\\\").Replace("'", "''") + "'";
}
