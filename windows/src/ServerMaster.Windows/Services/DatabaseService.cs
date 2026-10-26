using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed record DatabaseRuntimeStatus(bool Installed, bool Running, string Executable, string Version, string Message, int? ProcessId = null);

// UI-independent database boundary. A standalone database tool can reuse this service.
public static class DatabaseService
{
    private static Process? _process;
    private static readonly SemaphoreSlim Lifecycle = new(1, 1);
    private static string _version = "";
    private static string? _executable;
    private static DateTime _lastDetection;
    internal static string? TestRoot { get; set; }
    public const int Port = 3307;
    public static string DatabaseRootDirectory => NativeDirectory.Resolve(TestRoot ?? Path.Combine(AppPaths.LocalSupport, "Database"));
    public static string RuntimeDirectory => AppPaths.Ensure(DatabaseRootDirectory);
    public static string DataDirectory => AppPaths.Ensure(Path.Combine(DatabaseRootDirectory, "data"));
    public static string ErrorLogPath => Path.Combine(RuntimeDirectory, "error.log");

    public static IReadOnlyList<DiagnosticFinding> Diagnostics()
    {
        try
        {
            var root = TestRoot ?? Path.Combine(AppPaths.LocalSupport, "Database");
            // Resolve existing MSIX redirects without creating a database as a side effect of diagnostics.
            if (Directory.Exists(root)) root = NativeDirectory.Resolve(root);
            return DatabaseDiagnostics.Check(Detect(), root);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return [new("Database", "Database diagnostics unavailable", ex.Message, "Check access to the database folder.", Severity: DiagnosticLevel.Warning)];
        }
    }

    public static DatabaseRuntimeStatus Detect(bool refresh = false)
    {
        if (refresh || DateTime.UtcNow - _lastDetection > TimeSpan.FromSeconds(5))
        {
            _executable = ShellEnvironment.Shared.Which("mariadbd");
            _lastDetection = DateTime.UtcNow;
        }
        var executable = _executable;
        if (executable is null) return new(false, false, "", "", "MariaDB server is not installed.");
        var running = _process is { HasExited: false };
        return new(true, running, executable, _version, running ? $"MariaDB is running on 127.0.0.1:{Port}." : "MariaDB is installed but stopped.", running ? _process!.Id : null);
    }

    public static async Task<DatabaseRuntimeStatus> StartAsync(Action<string>? log = null)
    {
        await Lifecycle.WaitAsync();
        try { return await StartCoreAsync(log); }
        finally { Lifecycle.Release(); }
    }

    private static async Task<DatabaseRuntimeStatus> StartCoreAsync(Action<string>? log)
    {
        var current = Detect(true);
        if (!current.Installed) throw new InvalidOperationException("MariaDB is not installed. Install it from Dependencies first.");
        if (current.Running) return current;
        await ServerReadiness.CheckPortAsync(new ServerProfile { Host = "127.0.0.1", Port = Port }, CancellationToken.None);

        var databaseDirectory = Path.GetFullPath(DatabaseRootDirectory);
        var dataDirectory = Path.GetFullPath(Path.Combine(databaseDirectory, "data"));
        Directory.CreateDirectory(databaseDirectory);
        Directory.CreateDirectory(dataDirectory);
        log?.Invoke($"MariaDB data directory: {dataDirectory}");
        if (!Directory.Exists(dataDirectory))
            throw new IOException($"MariaDB data directory could not be created: {dataDirectory}");
        var probe = Path.Combine(dataDirectory, ".servermaster-write-test");
        try { File.WriteAllText(probe, "ok"); File.Delete(probe); }
        catch (Exception ex) { throw new UnauthorizedAccessException($"MariaDB data directory is not writable: {dataDirectory}. {ex.Message}", ex); }
        if (!Directory.Exists(Path.Combine(dataDirectory, "mysql")))
        {
            log?.Invoke("Preparing MariaDB data directory...");
            var binDirectory = Path.GetDirectoryName(current.Executable)!;
            var installer = Path.Combine(binDirectory, "mariadb-install-db.exe");
            if (!File.Exists(installer)) installer = Path.Combine(binDirectory, "mysql_install_db.exe");
            if (!File.Exists(installer)) throw new FileNotFoundException("MariaDB is installed, but its database initializer was not found.", installer);
            var arguments = new[] { "-d", dataDirectory, "-P", Port.ToString() };
            var init = await RunAsync(installer, arguments, databaseDirectory);
            if (init.ExitCode != 0) throw new InvalidOperationException("MariaDB could not initialize its data directory: " + init.Output.Trim());
        }

        var startInfo = new ProcessStartInfo(current.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = RuntimeDirectory
        };
        startInfo.ArgumentList.Add("--no-defaults");
        var baseDirectory = Directory.GetParent(Path.GetDirectoryName(current.Executable)!)?.FullName ?? Path.GetDirectoryName(current.Executable)!;
        startInfo.ArgumentList.Add($"--basedir={baseDirectory}");
        startInfo.ArgumentList.Add($"--datadir={dataDirectory}");
        startInfo.ArgumentList.Add($"--port={Port}");
        startInfo.ArgumentList.Add("--bind-address=127.0.0.1");
        startInfo.ArgumentList.Add("--skip-name-resolve");
        startInfo.ArgumentList.Add($"--log-error={ErrorLogPath}");
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor()) startInfo.Environment[pair.Key] = pair.Value;
        _process?.Dispose();
        _process = new Process { StartInfo = startInfo };
        _process.OutputDataReceived += (_, e) => { if (e.Data is not null) log?.Invoke(e.Data); };
        _process.ErrorDataReceived += (_, e) => { if (e.Data is not null) log?.Invoke(e.Data); };
        try { _process.Start(); OwnedProcesses.Track(_process); }
        catch { _process.Dispose(); _process = null; throw; }
        _process.BeginOutputReadLine();
        _process.BeginErrorReadLine();
        log?.Invoke($"Starting MariaDB on 127.0.0.1:{Port}...");
        for (var i = 0; i < 30; i++)
        {
            await Task.Delay(250);
            if (_process.HasExited) break;
            if (await CanConnectAsync())
            {
                try
                {
                    var ready = await RunClientAsync("SELECT VERSION();");
                    if (ready.ExitCode == 0 && !string.IsNullOrWhiteSpace(ready.Output)) { _version = ready.Output.Trim(); return Detect(); }
                    log?.Invoke("MariaDB is listening but SQL login failed: " + ready.Output.Trim());
                    break;
                }
                catch (Exception ex) { log?.Invoke(ex.Message); break; }
            }
        }
        var error = File.Exists(ErrorLogPath) ? File.ReadAllText(ErrorLogPath) : "No MariaDB error log was produced.";
        await StopCoreAsync();
        throw new InvalidOperationException("MariaDB did not become ready. " + error.Trim());
    }

    public static async Task StopAsync()
    {
        await Lifecycle.WaitAsync();
        try { await StopCoreAsync(); }
        finally { Lifecycle.Release(); }
    }

    private static async Task StopCoreAsync()
    {
        if (_process is null) return;
        if (!_process.HasExited)
        {
            try { await RunClientAsync("SHUTDOWN;"); await _process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); }
            catch
            {
                if (!_process.HasExited) _process.Kill(entireProcessTree: true);
                await _process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
        _process.Dispose();
        _process = null;
    }

    public static async Task<IReadOnlyList<DatabaseEntry>> ListDatabasesAsync()
    {
        var output = await RunClientAsync("SHOW DATABASES;");
        if (output.ExitCode != 0) throw new InvalidOperationException(output.Output.Trim());
        var system = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "information_schema", "mysql", "performance_schema", "sys", "test" };
        var result = new List<DatabaseEntry>();
        foreach (var name in output.Output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (!system.Contains(name) && name.All(character => char.IsLetterOrDigit(character) || character is '_' or '-'))
            {
                var tables = await RunClientAsync($"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{name.Replace("'", "''")}';");
                _ = int.TryParse(tables.Output.Trim(), out var count);
                result.Add(new DatabaseEntry { Name = name, Tables = count });
            }
        }
        return result;
    }

    public static async Task CreateDatabaseAsync(string name, string user, string password)
    {
        ValidateIdentifier(name, "database");
        ValidateIdentifier(user, "user");
        var escapedPassword = password.Replace("\\", "\\\\").Replace("'", "''");
        var sql = $"CREATE DATABASE IF NOT EXISTS `{name}`; " +
            $"CREATE USER IF NOT EXISTS '{user}'@'localhost' IDENTIFIED BY '{escapedPassword}'; " +
            $"ALTER USER '{user}'@'localhost' IDENTIFIED BY '{escapedPassword}'; " +
            $"GRANT ALL PRIVILEGES ON `{name}`.* TO '{user}'@'localhost'; " +
            $"CREATE USER IF NOT EXISTS '{user}'@'127.0.0.1' IDENTIFIED BY '{escapedPassword}'; " +
            $"ALTER USER '{user}'@'127.0.0.1' IDENTIFIED BY '{escapedPassword}'; " +
            $"GRANT ALL PRIVILEGES ON `{name}`.* TO '{user}'@'127.0.0.1'; FLUSH PRIVILEGES;";
        var result = await RunClientAsync(sql);
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
    }

    public static async Task DropDatabaseAsync(string name)
    {
        ValidateIdentifier(name, "database");
        var result = await RunClientAsync($"DROP DATABASE IF EXISTS `{name}`;");
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
    }

    public static async Task DumpDatabaseAsync(string name, string destination)
    {
        ValidateIdentifier(name, "database");
        if (!Detect().Running) throw new InvalidOperationException("Start MariaDB before taking a database snapshot.");
        var executable = ShellEnvironment.Shared.Which("mariadb-dump") ?? ShellEnvironment.Shared.Which("mysqldump");
        if (executable is null) throw new FileNotFoundException("MariaDB dump utility was not found.");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = destination + ".partial";
        var arguments = new[] { "--no-defaults", "--default-character-set=utf8mb4", "--protocol=tcp", "-h", "127.0.0.1", "-P", Port.ToString(), "-u", "root", "--databases", name, "--add-drop-database", $"--result-file={temporary}" };
        try
        {
            var result = await RunAsync(executable, arguments, RuntimeDirectory);
            if (result.ExitCode != 0) throw new InvalidOperationException("Could not snapshot database: " + result.Output.Trim());
            File.Move(temporary, destination, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static async Task LoadDatabaseAsync(string name, string source)
        => await LoadDatabaseAsAsync(name, source, "root", null);

    public static async Task ImportDatabaseAsync(string name, string user, string password, string source)
    {
        ValidateIdentifier(name, "database");
        if (!Detect().Running) throw new InvalidOperationException("Start MariaDB before importing a database.");
        if (!File.Exists(source)) throw new FileNotFoundException("The selected dump is missing.", source);
        var prepared = await PrepareImportSqlAsync(source);
        var temporaryUser = "smi_" + Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        var temporaryPassword = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        try
        {
            if (!(await ListDatabasesAsync()).Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            {
                ValidateIdentifier(user, "user");
                if (string.IsNullOrEmpty(password)) throw new InvalidOperationException("Enter a password for the new database user.");
                await CreateDatabaseAsync(name, user, password);
            }
            var grant = await RunClientAsync($"CREATE USER '{temporaryUser}'@'127.0.0.1' IDENTIFIED BY '{temporaryPassword}'; GRANT ALL PRIVILEGES ON `{name}`.* TO '{temporaryUser}'@'127.0.0.1';");
            if (grant.ExitCode != 0) throw new InvalidOperationException("Could not prepare the database import: " + grant.Output.Trim());
            await LoadDatabaseAsAsync(name, prepared, temporaryUser, temporaryPassword);
        }
        finally
        {
            try { await RunClientAsync($"DROP USER IF EXISTS '{temporaryUser}'@'127.0.0.1';"); } catch { }
            if (!string.Equals(prepared, source, StringComparison.OrdinalIgnoreCase) && File.Exists(prepared)) File.Delete(prepared);
        }
    }

    private static async Task<string> PrepareImportSqlAsync(string source)
    {
        var lower = source.ToLowerInvariant();
        if (lower.EndsWith(".sql")) return source;
        var output = Path.Combine(Path.GetTempPath(), "servermaster-import-" + Guid.NewGuid().ToString("N") + ".sql");
        try
        {
            if (lower.EndsWith(".zip"))
            {
                using var archive = ZipFile.OpenRead(source);
                var entry = archive.Entries.Where(item => item.FullName.EndsWith(".sql", StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(item => item.Length).FirstOrDefault()
                    ?? throw new InvalidDataException("No .sql file was found inside the archive.");
                using var stream = entry.Open();
                await CopySqlAsync(stream, output);
            }
            else if (lower.EndsWith(".tar") || lower.EndsWith(".tar.gz") || lower.EndsWith(".tgz"))
            {
                using var file = File.OpenRead(source);
                using Stream stream = lower.EndsWith(".tar") ? file : new GZipStream(file, CompressionMode.Decompress);
                using var archive = new TarReader(stream);
                long best = -1;
                TarEntry? entry;
                while ((entry = await archive.GetNextEntryAsync()) is not null)
                {
                    if (entry.DataStream is null || !entry.Name.EndsWith(".sql", StringComparison.OrdinalIgnoreCase) || entry.Length <= best) continue;
                    await CopySqlAsync(entry.DataStream, output);
                    best = entry.Length;
                }
                if (best < 0) throw new InvalidDataException("No .sql file was found inside the archive.");
            }
            else if (lower.EndsWith(".gz"))
            {
                using var file = File.OpenRead(source);
                using var stream = new GZipStream(file, CompressionMode.Decompress);
                await CopySqlAsync(stream, output);
            }
            else throw new InvalidDataException("Choose a .sql, .gz, .zip, .tar or .tar.gz database dump.");
            return output;
        }
        catch
        {
            if (File.Exists(output)) File.Delete(output);
            throw;
        }
    }

    private static async Task CopySqlAsync(Stream source, string destination)
    {
        const long maxBytes = 4L * 1024 * 1024 * 1024;
        await using var output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.Asynchronous);
        var buffer = new byte[128 * 1024];
        long total = 0;
        int count;
        while ((count = await source.ReadAsync(buffer)) > 0)
        {
            total += count;
            if (total > maxBytes) throw new InvalidDataException("The SQL dump exceeds the 4 GB import limit.");
            await output.WriteAsync(buffer.AsMemory(0, count));
        }
        if (total == 0) throw new InvalidDataException("The selected SQL dump is empty.");
    }

    private static async Task LoadDatabaseAsAsync(string name, string source, string user, string? password)
    {
        ValidateIdentifier(name, "database");
        if (!Detect().Running) throw new InvalidOperationException("Start MariaDB before restoring a database snapshot.");
        if (!File.Exists(source)) throw new FileNotFoundException("The database dump is missing.", source);
        var client = ShellEnvironment.Shared.Which("mariadb") ?? ShellEnvironment.Shared.Which("mysql");
        if (client is null) throw new FileNotFoundException("MariaDB client was not found.");
        var info = new ProcessStartInfo(client)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = RuntimeDirectory
        };
        foreach (var argument in new[] { "--no-defaults", "--default-character-set=utf8mb4", "--protocol=tcp", "-h", "127.0.0.1", "-P", Port.ToString(), "-u", user, "-D", name }) info.ArgumentList.Add(argument);
        if (password is not null) info.Environment["MYSQL_PWD"] = password;
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not start the MariaDB client.");
        OwnedProcesses.Track(process);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await using (var input = File.OpenRead(source)) await input.CopyToAsync(process.StandardInput.BaseStream);
        process.StandardInput.Close();
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(30));
            var output = await stdout + await stderr;
            if (process.ExitCode != 0) throw new InvalidOperationException("Could not restore database: " + output.Trim());
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }

    public static async Task<string> PreparePanelAccountAsync()
    {
        var password = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        var result = await RunClientAsync($"CREATE USER IF NOT EXISTS 'servermaster_panel'@'127.0.0.1' IDENTIFIED BY '{password}'; ALTER USER 'servermaster_panel'@'127.0.0.1' IDENTIFIED BY '{password}'; GRANT ALL PRIVILEGES ON *.* TO 'servermaster_panel'@'127.0.0.1';");
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
        return password;
    }

    public static async Task<IReadOnlyList<string>> ListTablesAsync(string database)
    {
        ValidateIdentifier(database, "database");
        var result = await RunClientAsync($"SHOW TABLES FROM `{database}`;");
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
        return result.Output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    public static async Task<string> RunQueryAsync(string database, string sql)
    {
        ValidateIdentifier(database, "database");
        if (string.IsNullOrWhiteSpace(sql)) throw new InvalidOperationException("Enter an SQL query first.");
        var result = await RunClientAsync(sql, database);
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
        return string.IsNullOrWhiteSpace(result.Output) ? "Query completed successfully." : result.Output.Trim();
    }

    public static async Task<DatabaseResult> RunResultQueryAsync(string database, string sql)
    {
        ValidateIdentifier(database, "database");
        if (string.IsNullOrWhiteSpace(sql)) throw new InvalidOperationException("Enter an SQL query first.");
        var result = await RunClientAsync(sql, database, true);
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
        return DatabaseResult.Parse(result.Output);
    }

    public static async Task<DatabaseResult> BrowseTableAsync(string database, string table, int offset = 0, bool structure = false)
    {
        ValidateIdentifier(database, "database");
        if (string.IsNullOrEmpty(table) || table.Length > 64 || table.Contains('\0')) throw new InvalidOperationException("Invalid table name.");
        if (offset < 0) throw new ArgumentOutOfRangeException(nameof(offset));
        var quoted = "`" + table.Replace("`", "``") + "`";
        var query = structure ? $"SHOW FULL COLUMNS FROM {quoted};" : $"SELECT * FROM {quoted} LIMIT 101 OFFSET {offset};";
        var result = await RunClientAsync(query, database, true);
        if (result.ExitCode != 0) throw new InvalidOperationException(result.Output.Trim());
        var parsed = DatabaseResult.Parse(result.Output);
        if (parsed.Columns.Count == 0 && !structure)
        {
            var schema = await BrowseTableAsync(database, table, structure: true);
            return new(schema.Rows.Select(row => row.Values[0] ?? "").ToArray(), []);
        }
        return parsed;
    }

    private static async Task<bool> CanConnectAsync()
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            await client.ConnectAsync("127.0.0.1", Port);
            return client.Connected;
        }
        catch { return false; }
    }

    private static async Task<(int ExitCode, string Output)> RunClientAsync(string sql, string? database = null, bool xml = false)
    {
        var client = ShellEnvironment.Shared.Which("mariadb") ?? ShellEnvironment.Shared.Which("mysql");
        if (client is null) throw new FileNotFoundException("MariaDB client was not found. Install MariaDB client tools first.");
        var startInfo = new ProcessStartInfo(client)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8,
            StandardInputEncoding = new System.Text.UTF8Encoding(false),
            WorkingDirectory = RuntimeDirectory
        };
        foreach (var argument in new[] { "--no-defaults", "--default-character-set=utf8mb4", "--connect-timeout=3", "--protocol=tcp", "-h", "127.0.0.1", "-P", Port.ToString(), "-u", "root", "--batch", "--skip-column-names" }) startInfo.ArgumentList.Add(argument);
        if (xml) startInfo.ArgumentList.Add("--xml");
        if (!string.IsNullOrWhiteSpace(database)) { startInfo.ArgumentList.Add("-D"); startInfo.ArgumentList.Add(database); }
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start the MariaDB client.");
        OwnedProcesses.Track(process);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try
        {
            await process.StandardInput.WriteLineAsync(sql);
            process.StandardInput.Close();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            var output = await stdout;
            var error = await stderr;
            return (process.ExitCode, process.ExitCode == 0 ? output : output + error);
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }

    public static bool IsValidName(string value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 64 &&
        value.All(character => char.IsLetterOrDigit(character) || character == '_');

    private static void ValidateIdentifier(string value, string kind)
    {
        if (!IsValidName(value))
            throw new InvalidOperationException($"The {kind} name may contain only letters, digits and underscores.");
    }

    private static async Task<(int ExitCode, string Output)> RunAsync(string fileName, IReadOnlyList<string> arguments, string? workingDirectory = null)
    {
        var startInfo = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start MariaDB installer.");
        OwnedProcesses.Track(process);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(2));
            return (process.ExitCode, await stdout + await stderr);
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }

}
