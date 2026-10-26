using System.Net;
using System.Net.Sockets;
using System.IO.Compression;
using System.Formats.Tar;
using System.Text;
using ServerMaster.Windows.Services;

internal static class DatabaseSmokeTests
{
    public static async Task Run()
    {
        if (!DatabaseService.Detect().Installed) { Console.WriteLine("SKIP Database: MariaDB is not installed"); return; }
        using (var probe = new TcpListener(IPAddress.Loopback, DatabaseService.Port))
        {
            try { probe.Start(); }
            catch (SocketException) { Console.WriteLine("SKIP Database: port 3307 belongs to another process; not touched"); return; }
        }
        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-db-tests-" + Guid.NewGuid().ToString("N"));
        DatabaseService.TestRoot = root;
        try
        {
            var state = await DatabaseService.StartAsync(Console.WriteLine);
            Check(state.Running && state.Version.Contains("MariaDB"), "isolated instance initialized and authenticated");
            await DatabaseService.CreateDatabaseAsync("fixture", "fixtureuser", "fixture'password\\withslash");
            Check((await DatabaseService.ListDatabasesAsync()).Any(d => d.Name == "fixture"), "create and list database");
            var account = new DatabaseAccount("fixture_reader", "localhost");
            await DatabaseAccountService.CreateAsync("fixture", account.Name, account.Host, "initial'password\\safe");
            Check((await DatabaseAccountService.ListAsync("fixture")).Contains(account), "account editor lists a created user");
            await DatabaseAccountService.GrantAsync("fixture", account, true);
            Check((await DatabaseAccountService.GrantsAsync("fixture", account)).Any(grant => grant.Contains("SELECT") && grant.Contains("fixture")),
                "account editor grants read-only database access");
            await DatabaseAccountService.GrantAsync("fixture", account, false);
            await DatabaseAccountService.GrantAsync("fixture", account, true);
            Check(!(await DatabaseAccountService.GrantsAsync("fixture", account)).Any(grant => grant.Contains("ALL PRIVILEGES") && grant.Contains("fixture")),
                "switching to read-only removes full database access");
            await DatabaseAccountService.ChangePasswordAsync("fixture", account, "changed'password\\safe");
            await DatabaseAccountService.RevokeAsync("fixture", account);
            Check(!(await DatabaseAccountService.GrantsAsync("fixture", account)).Any(grant => grant.Contains("SELECT") && grant.Contains("fixture")),
                "account editor revokes only the selected database access");
            try { await DatabaseAccountService.DropAsync("fixture", new DatabaseAccount("root", "localhost")); throw new Exception("Root deletion accepted"); }
            catch (InvalidOperationException) { Check(true, "account editor protects the root user"); }
            await DatabaseAccountService.DropAsync("fixture", account);
            Check(!(await DatabaseAccountService.ListAsync("fixture")).Contains(account), "account editor removes a selected user");
            if (AdminerService.IsInstalled && PhpRuntime.Find("") is not null)
            {
                try
                {
                    await AdminerService.StartAsync();
                    using var http = new HttpClient(new HttpClientHandler { UseProxy = false, CookieContainer = new CookieContainer() });
                    var denied = await http.GetAsync($"http://127.0.0.1:{AdminerService.Port}/login.php");
                    Check(denied.StatusCode == HttpStatusCode.Forbidden, "Adminer credentials require the launch token");
                    var wrapper = await http.GetStringAsync(AdminerService.LoginAddress);
                    var password = System.Text.RegularExpressions.Regex.Match(wrapper, "name=\"auth\\[password\\]\" value=\"([^\"]+)\"").Groups[1].Value;
                    var page = await http.GetStringAsync(AdminerService.Address);
                    var token = System.Text.RegularExpressions.Regex.Match(page, "name=['\"]token['\"]\\s+value=['\"]([^'\"]*)['\"]").Groups[1].Value;
                    Check(password.Length > 0 && token.Length > 0, "Adminer login page supplies credentials and CSRF token");
                    using var response = await http.PostAsync(AdminerService.Address, new FormUrlEncodedContent(new Dictionary<string, string>
                    {
                        ["auth[driver]"] = "server", ["auth[server]"] = "127.0.0.1:3307", ["auth[username]"] = "servermaster_panel", ["auth[password]"] = password, ["token"] = token
                    }));
                    var loggedIn = await response.Content.ReadAsStringAsync();
                    if (!loggedIn.Contains("fixture")) Console.WriteLine("Adminer response: " + response.StatusCode + " " + System.Text.RegularExpressions.Regex.Replace(loggedIn, "<[^>]+>", " ").Replace(password, "[redacted]")[..Math.Min(2500, System.Text.RegularExpressions.Regex.Replace(loggedIn, "<[^>]+>", " ").Replace(password, "[redacted]").Length)]);
                    Check(response.IsSuccessStatusCode && loggedIn.Contains("fixture") && loggedIn.Contains("logout", StringComparison.OrdinalIgnoreCase), "Adminer authenticates with the generated account and lists the database");
                }
                finally { AdminerService.Stop(); }
            }
            await DatabaseService.RunQueryAsync("fixture", "CREATE TABLE rows_test (id INT PRIMARY KEY, title VARCHAR(100)); INSERT INTO rows_test VALUES (1, 'Hello');");
            Check((await DatabaseService.ListTablesAsync("fixture")).Contains("rows_test"), "list tables");
            Check((await DatabaseService.RunQueryAsync("fixture", "SELECT title FROM rows_test;")).Contains("Hello"), "execute query");
            await DatabaseSchemaService.CreateTableAsync("fixture", "order");
            await DatabaseSchemaService.AddColumnAsync("fixture", "order", "print_name", "VARCHAR(255)", true);
            var schemaColumns = await DatabaseSchemaService.ColumnsAsync("fixture", "order");
            Check(schemaColumns.Any(column => column.Name == "id" && column.Key == "PRI") &&
                  schemaColumns.Any(column => column.Name == "print_name" && column.Nullable), "schema editor creates a keyed table and adds a nullable column");
            await DatabaseSchemaService.AddColumnAsync("fixture", "order", "temporary_edit", "VARCHAR(64)", true);
            await DatabaseSchemaService.ChangeColumnAsync("fixture", "order", "temporary_edit", "renamed_edit", "VARCHAR(255)", false);
            Check((await DatabaseSchemaService.ColumnsAsync("fixture", "order")).Any(column => column.Name == "renamed_edit" &&
                  column.Type.Equals("varchar(255)", StringComparison.OrdinalIgnoreCase) && !column.Nullable),
                "schema editor changes name, type and nullability of a selected column");
            try { await DatabaseSchemaService.ChangeColumnAsync("fixture", "order", "temporary_edit", "unsafe", "INT", true); throw new Exception("Stale column edit accepted"); }
            catch (InvalidOperationException) { Check(true, "schema editor rejects a stale column edit"); }
            await DatabaseSchemaService.DropColumnAsync("fixture", "order", "renamed_edit");
            Check((await DatabaseSchemaService.CreateStatementAsync("fixture", "order")).Contains("print_name"), "schema editor reads the complete CREATE TABLE statement");
            Check((await DatabaseSchemaService.IndexesAsync("fixture", "order")).Any(index => index.IsPrimary && index.Columns.SequenceEqual(["id"])),
                "schema editor reads the primary index");
            await DatabaseSchemaService.AddIndexAsync("fixture", "order", "ix_print_name", ["print_name"], false);
            Check((await DatabaseSchemaService.IndexesAsync("fixture", "order")).Any(index => index.Name == "ix_print_name" &&
                  index.Columns.SequenceEqual(["print_name"]) && !index.IsUnique), "schema editor adds an index on an existing column");
            try { await DatabaseSchemaService.AddIndexAsync("fixture", "order", "ix_bad", ["absent"], true); throw new Exception("Missing index column accepted"); }
            catch (InvalidOperationException) { Check(!(await DatabaseSchemaService.IndexesAsync("fixture", "order")).Any(index => index.Name == "ix_bad"),
                "schema editor refuses an index on a missing column"); }
            await DatabaseSchemaService.DropIndexAsync("fixture", "order", "ix_print_name");
            Check(!(await DatabaseSchemaService.IndexesAsync("fixture", "order")).Any(index => index.Name == "ix_print_name"),
                "schema editor drops the selected index");
            try { await DatabaseSchemaService.AddColumnAsync("fixture", "order", "unsafe", "INT); DROP TABLE rows_test; --", false); throw new Exception("Unsafe type accepted"); }
            catch (InvalidOperationException) { Check((await DatabaseService.ListTablesAsync("fixture")).Contains("rows_test"), "schema editor rejects arbitrary SQL types"); }
            await DatabaseSchemaService.AddColumnAsync("fixture", "order", "temporary_note", "TEXT", true);
            await DatabaseService.RunQueryAsync("fixture", "INSERT INTO `order` (temporary_note) VALUES ('discard me');");
            await DatabaseSchemaService.DropColumnAsync("fixture", "order", "temporary_note");
            Check(!(await DatabaseSchemaService.ColumnsAsync("fixture", "order")).Any(column => column.Name == "temporary_note"),
                "schema editor drops only the selected column");
            await DatabaseService.RunQueryAsync("fixture", "DELETE FROM `order`;");
            try { await DatabaseSchemaService.DropColumnAsync("fixture", "order", "absent"); throw new Exception("Missing column accepted"); }
            catch (InvalidOperationException) { Check((await DatabaseSchemaService.ColumnsAsync("fixture", "order")).Any(column => column.Name == "print_name"),
                "schema editor refuses a stale column selection"); }
            var data = await DatabaseService.BrowseTableAsync("fixture", "rows_test");
            Check(data.Columns.SequenceEqual(new[] { "id", "title" }) && data.Rows[0].Values[1] == "Hello", "native table result preserves columns and values");
            await DatabaseService.RunQueryAsync("fixture", "INSERT INTO rows_test VALUES (4, 'Edit me');");
            data = await DatabaseService.BrowseTableAsync("fixture", "rows_test");
            var editable = data.Rows.Single(row => row.Values[0] == "4");
            var editColumns = await DatabaseSchemaService.ColumnsAsync("fixture", "rows_test");
            const string special = "O'Reilly \\ test; DROP TABLE rows_test;";
            await DatabaseRowService.UpdateCellAsync("fixture", "rows_test", data, editable, editColumns, "title", special);
            Check((await DatabaseService.BrowseTableAsync("fixture", "rows_test")).Rows.Single(row => row.Values[0] == "4").Values[1] == special,
                "row editor preserves quotes and SQL-looking text as data");
            await DatabaseRowService.UpdateCellAsync("fixture", "rows_test", data, editable, editColumns, "title", null);
            Check((await DatabaseService.BrowseTableAsync("fixture", "rows_test")).Rows.Single(row => row.Values[0] == "4").Values[1] is null,
                "row editor distinguishes NULL from text");
            await DatabaseRowService.DeleteRowAsync("fixture", "rows_test", data, editable, editColumns);
            Check((await DatabaseService.BrowseTableAsync("fixture", "rows_test")).Rows.All(row => row.Values[0] != "4") &&
                  (await DatabaseService.ListTablesAsync("fixture")).Contains("rows_test"), "row deletion only removes the keyed row");
            await DatabaseRowService.InsertEmptyRowAsync("fixture", "order", schemaColumns);
            Check((await DatabaseService.BrowseTableAsync("fixture", "order")).Rows.Count == 1, "row editor inserts a row with generated key and nullable default");
            await DatabaseSchemaService.RenameTableAsync("fixture", "order", "print_orders");
            Check((await DatabaseService.ListTablesAsync("fixture")).Contains("print_orders") &&
                  !(await DatabaseService.ListTablesAsync("fixture")).Contains("order"), "schema editor renames the selected table");
            await DatabaseSchemaService.EmptyTableAsync("fixture", "print_orders");
            Check((await DatabaseService.BrowseTableAsync("fixture", "print_orders")).Rows.Count == 0,
                "empty table removes rows but preserves its structure");
            try { await DatabaseSchemaService.RenameTableAsync("fixture", "print_orders", "bad\0name"); throw new Exception("Invalid table name accepted"); }
            catch (InvalidOperationException) { Check((await DatabaseService.ListTablesAsync("fixture")).Contains("print_orders"), "invalid table names do not mutate schema"); }
            await DatabaseSchemaService.DropTableAsync("fixture", "print_orders");
            Check(!(await DatabaseService.ListTablesAsync("fixture")).Contains("print_orders"), "schema editor drops only the selected table");
            await DatabaseService.RunQueryAsync("fixture", "CREATE TABLE no_key (title VARCHAR(20)); INSERT INTO no_key VALUES ('keep');");
            var noKey = await DatabaseService.BrowseTableAsync("fixture", "no_key");
            try { await DatabaseRowService.DeleteRowAsync("fixture", "no_key", noKey, noKey.Rows[0], await DatabaseSchemaService.ColumnsAsync("fixture", "no_key")); throw new Exception("Unkeyed delete was accepted"); }
            catch (InvalidOperationException) { Check((await DatabaseService.BrowseTableAsync("fixture", "no_key")).Rows.Count == 1, "row editor refuses to delete without a primary key"); }
            var structure = await DatabaseService.BrowseTableAsync("fixture", "rows_test", structure: true);
            Check(structure.Columns.Contains("Type") && structure.Rows.Count == 2, "structure is a distinct schema result");
            await DatabaseService.RunQueryAsync("fixture", "INSERT INTO rows_test VALUES (2, NULL), (3, '<a>&\\tvalue');");
            data = await DatabaseService.BrowseTableAsync("fixture", "rows_test");
            Check(data.Rows[1].Values[1] is null && data.Rows[2].Values[1] == "<a>&\tvalue", "XML decoding preserves NULL, tabs and special characters");
            var empty = await DatabaseService.BrowseTableAsync("fixture", "rows_test", 100);
            Check(empty.Rows.Count == 0 && empty.Columns.Count == 2, "empty pages retain their column headers");
            var dump = Path.Combine(root, "fixture.sql");
            await DatabaseService.DumpDatabaseAsync("fixture", dump);
            await DatabaseService.RunQueryAsync("fixture", "UPDATE rows_test SET title='Changed' WHERE id=1;");
            await DatabaseService.LoadDatabaseAsync("fixture", dump);
            Check((await DatabaseService.RunQueryAsync("fixture", "SELECT title FROM rows_test WHERE id=1;")).Contains("Hello"), "database snapshot restores the dumped data");
            var archivePath = Path.Combine(root, "joomla-backup.zip");
            using (var archive = new ZipArchive(File.Create(archivePath), ZipArchiveMode.Create))
            {
                using (var small = new StreamWriter(archive.CreateEntry("installer.sql").Open())) await small.WriteAsync("-- no tables");
                using (var sql = new StreamWriter(archive.CreateEntry("site/data.sql").Open()))
                    await sql.WriteAsync("CREATE TABLE imported_rows (id INT PRIMARY KEY, title VARCHAR(100)); INSERT INTO imported_rows VALUES (1, 'Imported archive');");
            }
            await DatabaseService.ImportDatabaseAsync("importfixture", "importuser", "pass", archivePath);
            Check((await DatabaseService.RunQueryAsync("importfixture", "SELECT title FROM imported_rows;")).Contains("Imported archive"), "ZIP import selects the largest SQL dump and loads it into the chosen database");
            var existingDump = Path.Combine(root, "existing.sql");
            await File.WriteAllTextAsync(existingDump, "INSERT INTO imported_rows VALUES (42, 'Existing target');");
            await DatabaseService.ImportDatabaseAsync("importfixture", "", "", existingDump);
            Check((await DatabaseService.RunQueryAsync("importfixture", "SELECT title FROM imported_rows WHERE id = 42;")).Contains("Existing target"),
                "existing database import needs no new user credentials");
            var gzipPath = Path.Combine(root, "plain.sql.gz");
            await using (var output = File.Create(gzipPath))
            await using (var gzip = new GZipStream(output, CompressionMode.Compress))
            await using (var writer = new StreamWriter(gzip))
                await writer.WriteAsync("CREATE TABLE compressed_rows (id INT); INSERT INTO compressed_rows VALUES (2);");
            await DatabaseService.ImportDatabaseAsync("gzipfixture", "gzipuser", "pass", gzipPath);
            Check((await DatabaseService.RunQueryAsync("gzipfixture", "SELECT id FROM compressed_rows;")).Trim() == "2", "GZip SQL import succeeds");
            var tarPath = Path.Combine(root, "site.tar.gz");
            await using (var tarFile = File.Create(tarPath))
            await using (var compressed = new GZipStream(tarFile, CompressionMode.Compress))
            using (var archive = new TarWriter(compressed))
            {
                using var sqlStream = new MemoryStream(Encoding.UTF8.GetBytes("CREATE TABLE tar_rows (id INT); INSERT INTO tar_rows VALUES (3);"));
                archive.WriteEntry(new PaxTarEntry(TarEntryType.RegularFile, "backup/site.sql") { DataStream = sqlStream });
            }
            await DatabaseService.ImportDatabaseAsync("tarfixture", "taruser", "pass", tarPath);
            Check((await DatabaseService.RunQueryAsync("tarfixture", "SELECT id FROM tar_rows;")).Trim() == "3", "Tar/GZip SQL import succeeds");
            var malicious = Path.Combine(root, "outside.sql");
            await File.WriteAllTextAsync(malicious, "CREATE DATABASE foreign_import_test;");
            try { await DatabaseService.ImportDatabaseAsync("blocked", "blockeduser", "pass", malicious); throw new Exception("Cross-database import was accepted"); }
            catch (InvalidOperationException) { }
            Check(!(await DatabaseService.ListDatabasesAsync()).Any(item => item.Name == "foreign_import_test"), "import account cannot create another database");
            await DatabaseService.StopAsync();
            Check(!DatabaseService.Detect().Running, "graceful shutdown releases the instance");
            await DatabaseService.StartAsync(Console.WriteLine);
            Check((await DatabaseService.RunQueryAsync("fixture", "SELECT title FROM rows_test;")).Contains("Hello"), "data survives restart");
            await DatabaseService.DropDatabaseAsync("fixture");
            Check(!(await DatabaseService.ListDatabasesAsync()).Any(d => d.Name == "fixture"), "delete fixture database only");
        }
        finally
        {
            await DatabaseService.StopAsync();
            DatabaseService.TestRoot = null;
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); Console.WriteLine("PASS Database: " + message); }
}
