using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public static class TemplateRecipeService
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(10) };

    public static async Task ApplyAsync(ProfileTemplate template, ServerProfile profile, ConsoleLog log)
    {
        switch (template.PackageKind)
        {
            case "printshopcrm":
                await PreparePrintShopCrmAsync(profile, log);
                break;
            case "wordpress-w2p":
                await PrepareWordPressWebToPrintAsync(template, profile, log);
                break;
        }

        CheckProjectDirectory(profile);
    }

    private static async Task PreparePrintShopCrmAsync(ServerProfile profile, ConsoleLog log)
    {
        var root = profile.ExpandedRootPath;
        RequireFile(root, "package.json", "PrintShopCRM package.json was not found after extraction.");
        RequireFile(root, profile.NodeEntryFile, "PrintShopCRM server entry was not found after extraction.");

        var data = Path.Combine(root, "data");
        Directory.CreateDirectory(data);
        Directory.CreateDirectory(Path.Combine(data, "uploads"));
        var envPath = Path.Combine(root, ".env");
        if (!File.Exists(envPath))
        {
            await File.WriteAllTextAsync(envPath, string.Join(Environment.NewLine,
            [
                "PORT=" + profile.Port,
                "PSC_HOST=127.0.0.1",
                "PSC_AUTH=0",
                "PSC_DB=" + Path.Combine(data, "printshop.db").Replace("\\", "/"),
                "PSC_UPLOADS=" + Path.Combine(data, "uploads").Replace("\\", "/"),
                "PSC_SECRET=" + Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant(),
                ""
            ]));
            log.System("Created local PrintShopCRM .env with SQLite data under the project folder.");
        }

        await RunAsync("npm", ["install"], root, log, TimeSpan.FromMinutes(10));
        await RunAsync("npm", ["run", "seed"], root, log, TimeSpan.FromMinutes(5), allowFailure: true);
        if (!Directory.Exists(Path.Combine(root, "node_modules")))
            throw new InvalidOperationException("npm install finished but node_modules was not created.");
    }

    private static async Task PrepareWordPressWebToPrintAsync(ProfileTemplate template, ServerProfile profile, ConsoleLog log)
    {
        var root = profile.ExpandedRootPath;
        RequireFile(root, "wp-config-sample.php", "WordPress package did not contain wp-config-sample.php.");

        var databaseName = string.IsNullOrWhiteSpace(profile.DatabaseName) ? SafeDatabaseName(profile.Name) : profile.DatabaseName;
        profile.DatabaseName = databaseName;
        await DatabaseService.StartAsync(message => log.System(message));
        // A new folder never takes over another store's database. The name comes from the port, so
        // a second store on the same port used to land in the first one's WordPress and keep its old
        // admin password. Only a re-run in this folder, whose wp-config.php names its database,
        // keeps it.
        if (!File.Exists(Path.Combine(root, "wp-config.php")))
        {
            var taken = (await DatabaseService.ListDatabasesAsync()).Select(database => database.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var free = FreeDatabaseName(databaseName, taken);
            if (free != databaseName) log.System($"Database {databaseName} already belongs to another project; using {free}.");
            databaseName = profile.DatabaseName = free;
        }
        await DatabaseService.CreateDatabaseAsync(databaseName, "servermaster_w2p", "servermaster_w2p");
        log.System($"Prepared MariaDB database {databaseName} on 127.0.0.1:{DatabaseService.Port}.");

        var showcase = template.RecipeKind == "wordpress-w2p-showcase";
        await WriteWordPressConfigAsync(root, databaseName, showcase);
        foreach (var plugin in template.PluginPackages)
        {
            await DownloadPluginAsync(plugin, root, log);
        }

        WriteWebToPrintHelper(root);
        var credentials = await InstallWordPressAsync(profile, root, log);
        await ActivateWebToPrintPluginsAsync(profile, root, log);
        if (showcase)
        {
            await ShowcaseStore.PrepareAsync(profile, root, log,
                (arguments, timeout) => RunWpCliAsync(profile, arguments, root, log, timeout, allowFailure: true));
            await ShowcaseStore.WriteNotesAsync(Path.Combine(root, "servermaster-demo.md"), profile, credentials.User, credentials.Password, credentials.ExistingInstall);
            RequireFile(root, "wp-content/plugins/woocommerce/woocommerce.php", "WooCommerce was not installed.");
            return;
        }
        await ConfigureDemoStoreAsync(profile, root, log);
        var demoPath = Path.Combine(root, "servermaster-demo.md");
        if (!credentials.ExistingInstall || !File.Exists(demoPath))
        {
            await File.WriteAllTextAsync(demoPath, """
        # ServerMaster Web-to-Print Store

        Open the local URL. WordPress, WooCommerce and Printcart Integration were installed automatically.

        Admin URL: {{ADMIN_URL}}
        Admin user: {{ADMIN_USER}}
        Admin password: {{ADMIN_PASSWORD}}

        WordPress and WooCommerce run locally. Printcart's product designer requires a separate
        Printcart Dashboard connection and cloud services; it is not available fully offline.
        For an offline demo, use local WooCommerce products and orders instead.
        """.Replace("{{ADMIN_URL}}", profile.Address.TrimEnd('/') + "/wp-admin/")
            .Replace("{{ADMIN_USER}}", credentials.User)
            .Replace("{{ADMIN_PASSWORD}}", credentials.Password));
        }
        RequireFile(root, "wp-content/plugins/woocommerce/woocommerce.php", "WooCommerce was not installed.");
        RequireFile(root, "wp-content/plugins/printcart-integration/nbdesigner.php", "Printcart Integration was not installed.");
    }

    /// <summary>The name itself when it is free, otherwise the first free "name_2", "name_3"...</summary>
    public static string FreeDatabaseName(string name, ISet<string> taken)
    {
        if (!taken.Contains(name)) return name;
        for (var number = 2; ; number++)
        {
            var suffix = "_" + number;
            var candidate = (name.Length + suffix.Length > 64 ? name[..(64 - suffix.Length)] : name) + suffix;
            if (!taken.Contains(candidate)) return candidate;
        }
    }

    private static async Task WriteWordPressConfigAsync(string root, string databaseName, bool showcase = false)
    {
        var configPath = Path.Combine(root, "wp-config.php");
        if (File.Exists(configPath)) return;
        var sample = await File.ReadAllTextAsync(Path.Combine(root, "wp-config-sample.php"));
        var config = sample
            .Replace("database_name_here", databaseName)
            .Replace("username_here", "servermaster_w2p")
            .Replace("password_here", "servermaster_w2p")
            .Replace("localhost", "127.0.0.1:" + DatabaseService.Port);
        config = config.Replace("put your unique phrase here", Convert.ToHexString(RandomNumberGenerator.GetBytes(32)));
        config = config.Replace("$table_prefix = 'wp_';", "$table_prefix = 'wp_';" + Environment.NewLine +
            "define('WP_ENVIRONMENT_TYPE', 'local');" + Environment.NewLine +
            "define('DISALLOW_FILE_EDIT', true);" +
            // A presentation store needs no background jobs: WP-Cron would run WooCommerce's
            // scheduled imports on page loads and make the first minutes slow on a weak laptop.
            (showcase ? Environment.NewLine + "define('DISABLE_WP_CRON', true);" : ""));
        var temporary = configPath + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            await File.WriteAllTextAsync(temporary, config);
            File.Move(temporary, configPath, overwrite: false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static async Task DownloadPluginAsync(string slug, string root, ConsoleLog log)
    {
        var plugins = Path.Combine(root, "wp-content", "plugins");
        Directory.CreateDirectory(plugins);
        var zip = Path.Combine(AppPaths.Runtime, "downloads", slug + ".latest-stable.zip");
        var staging = Path.Combine(AppPaths.Runtime, "downloads", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.GetDirectoryName(zip)!);
        var destination = Path.Combine(plugins, slug);
        if (Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any())
        {
            log.System("WordPress plugin already installed: " + slug);
            return;
        }

        try
        {
            if (!File.Exists(zip))
            {
                var url = $"https://downloads.wordpress.org/plugin/{slug}.latest-stable.zip";
                log.System("Downloading WordPress plugin " + slug);
                await DownloadAsync(url, zip);
            }
            else
            {
                log.System("Using cached WordPress plugin package: " + zip);
            }

            try
            {
                ZipFile.ExtractToDirectory(zip, staging);
            }
            catch (InvalidDataException)
            {
                File.Delete(zip);
                var url = $"https://downloads.wordpress.org/plugin/{slug}.latest-stable.zip";
                log.System("Cached plugin ZIP is damaged. Downloading a fresh copy.");
                await DownloadAsync(url, zip);
                ZipFile.ExtractToDirectory(zip, staging);
            }
            var folder = Directory.EnumerateDirectories(staging).SingleOrDefault() ?? staging;
            Directory.Move(folder, Path.Combine(plugins, Path.GetFileName(folder)));
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private static async Task<WordPressCredentials> InstallWordPressAsync(ServerProfile profile, string root, ConsoleLog log)
    {
        var installed = await RunWpCliAsync(profile, ["core", "is-installed"], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
        if (installed.ExitCode == 0)
        {
            log.System("WordPress is already installed; keeping the existing database and admin account.");
            return new WordPressCredentials("servermaster", "(existing password)", ExistingInstall: true);
        }

        var credentials = new WordPressCredentials("servermaster", Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant(), ExistingInstall: false);
        await RunWpCliAsync(profile,
            ["core", "install", "--url=" + profile.Address, "--title=ServerMaster Web-to-Print Demo", "--admin_user=" + credentials.User,
                "--admin_password=" + credentials.Password, "--admin_email=servermaster@example.local", "--skip-email"],
            root, log, TimeSpan.FromMinutes(3));
        return credentials;
    }

    private static async Task ActivateWebToPrintPluginsAsync(ServerProfile profile, string root, ConsoleLog log)
    {
        // One WP-CLI run for both: every run boots WordPress again, which is slow on a weak PC.
        await RunWpCliAsync(profile, ["plugin", "activate", "woocommerce", "printcart-integration"], root, log, TimeSpan.FromMinutes(4));
    }

    private static async Task ConfigureDemoStoreAsync(ServerProfile profile, string root, ConsoleLog log)
    {
        await RunWpCliAsync(profile, ["option", "update", "blogdescription", "Local Web-to-Print demo powered by ServerMaster"], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
        await RunWpCliAsync(profile, ["option", "update", "woocommerce_allow_tracking", "no"], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
        await RunWpCliAsync(profile, ["option", "update", "woocommerce_currency", "USD"], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
        await RunWpCliAsync(profile, ["option", "update", "woocommerce_default_country", "US:CA"], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
        var code = """
        $existing = get_page_by_path('demo-business-cards', OBJECT, 'product');
        if (!$existing) {
            $id = wp_insert_post(array(
                'post_title' => 'Demo Business Cards',
                'post_name' => 'demo-business-cards',
                'post_type' => 'product',
                'post_status' => 'publish',
                'post_content' => 'A local demo product for the ServerMaster Web-to-Print workflow.'
            ));
            if (!is_wp_error($id)) {
                update_post_meta($id, '_regular_price', '49.00');
                update_post_meta($id, '_price', '49.00');
                update_post_meta($id, '_stock_status', 'instock');
                update_post_meta($id, '_virtual', 'yes');
            }
        }
        """;
        await RunWpCliAsync(profile, ["eval", code], root, log, TimeSpan.FromMinutes(1), allowFailure: true);
    }

    private static void WriteWebToPrintHelper(string root)
    {
        var mu = Path.Combine(root, "wp-content", "mu-plugins");
        Directory.CreateDirectory(mu);
        File.WriteAllText(Path.Combine(mu, "servermaster-web-to-print-demo.php"), """
        <?php
        /*
         * Plugin Name: ServerMaster Web-to-Print Demo Helper
         */
        // The emoji script fetches images from s.w.org; offline it only slows every page down.
        remove_action('wp_head', 'print_emoji_detection_script', 7);
        remove_action('admin_print_scripts', 'print_emoji_detection_script');
        add_action('admin_init', function () {
            if (!function_exists('is_plugin_active') && file_exists(ABSPATH . 'wp-admin/includes/plugin.php')) {
                require_once ABSPATH . 'wp-admin/includes/plugin.php';
            }
            foreach (array('woocommerce/woocommerce.php', 'printcart-integration/nbdesigner.php') as $plugin) {
                if (function_exists('is_plugin_active') && !is_plugin_active($plugin) && file_exists(WP_PLUGIN_DIR . '/' . $plugin)) {
                    activate_plugin($plugin);
                }
            }
            if (function_exists('update_option')) {
                update_option('woocommerce_allow_tracking', 'no');
                update_option('woocommerce_default_country', 'US:CA');
                update_option('woocommerce_currency', 'USD');
            }
        });
        """);
    }

    public static async Task<IReadOnlyList<DiagnosticFinding>> HealthCheckAsync(ServerProfile profile)
    {
        var findings = new List<DiagnosticFinding>();
        void Add(string title, string detail, string remedy = "", bool problem = false, DiagnosticLevel? level = null) =>
            findings.Add(new(profile.Name, title, detail, remedy, problem, level));

        try { CheckProjectDirectory(profile); Add("Project directory", profile.ExpandedRootPath); }
        catch (Exception ex) { Add("Project directory", ex.Message, "Choose an existing project folder or recreate the template.", true); }

        if (profile.IsRunning && profile.ProcessId is { } pid)
        {
            try { using var process = Process.GetProcessById(pid); Add("Process", $"{process.ProcessName} ({pid}) is running."); }
            catch (Exception ex) { Add("Process", ex.Message, "Restart the profile from Control.", true); }
        }
        // A profile that is simply stopped is not broken (macOS reports a stopped database as
        // information too); its runtime checks wait until it runs.
        else if (profile.State == ServerState.Failed) Add("Process", profile.Failure ?? profile.StateText, "See Console for the start error.", true);
        else Add("Process", profile.StateText, "Start the profile to complete the runtime health check.", level: DiagnosticLevel.Note);

        if (profile.NeedsDatabase)
        {
            var database = DatabaseService.Detect();
            if (database.Running) Add("Database", database.Message);
            else Add("Database", database.Message, "Start MariaDB from Database before using this template.",
                profile.IsRunning, profile.IsRunning ? null : DiagnosticLevel.Note);
        }

        if (!profile.IsRunning)
        {
            Add("Localhost", $"{profile.Address} is checked while the profile runs.", level: DiagnosticLevel.Note);
            return findings;
        }
        try
        {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false };
            // WordPress/WooCommerce can take several seconds per page; see ServerReadiness.
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
            using var response = await client.GetAsync(profile.Address, HttpCompletionOption.ResponseHeadersRead);
            Add("Localhost", $"{profile.Address} returned {(int)response.StatusCode} {response.ReasonPhrase}.", ((int)response.StatusCode >= 500) ? "Check the profile console." : "", (int)response.StatusCode >= 500);
        }
        catch (Exception ex) { Add("Localhost", ex.Message, "Start the server and check that the selected port is reachable.", true); }

        return findings;
    }

    private static void CheckProjectDirectory(ServerProfile profile)
    {
        if (!Directory.Exists(profile.ExpandedRootPath)) throw new DirectoryNotFoundException("Project directory does not exist: " + profile.ExpandedRootPath);
        if (profile.TemplateId == "printshopcrm")
        {
            RequireFile(profile.ExpandedRootPath, "package.json", "PrintShopCRM package.json is missing.");
            RequireFile(profile.ExpandedRootPath, profile.NodeEntryFile, "PrintShopCRM server entry is missing.");
        }
        if (profile.TemplateId == "web-to-print-store")
        {
            RequireFile(profile.ExpandedRootPath, "wp-config.php", "WordPress wp-config.php is missing.");
            RequireFile(profile.ExpandedRootPath, "wp-content/plugins/woocommerce/woocommerce.php", "WooCommerce plugin is missing.");
            RequireFile(profile.ExpandedRootPath, "wp-content/plugins/printcart-integration/nbdesigner.php", "Printcart plugin is missing.");
            RequireFile(profile.ExpandedRootPath, "wp-admin/install.php", "WordPress admin files are missing.");
        }
    }

    private static void RequireFile(string root, string relativePath, string message)
    {
        var path = Path.GetFullPath(Path.Combine(root, relativePath));
        var fullRoot = Path.GetFullPath(root);
        if (!path.StartsWith(Path.TrimEndingDirectorySeparator(fullRoot) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Template path escapes the project folder.");
        if (!File.Exists(path)) throw new FileNotFoundException(message, path);
    }

    private static string SafeDatabaseName(string name)
    {
        var safe = new string(name.ToLowerInvariant().Select(character => char.IsLetterOrDigit(character) ? character : '_').ToArray()).Trim('_');
        return string.IsNullOrWhiteSpace(safe) ? "servermaster_w2p" : safe[..Math.Min(40, safe.Length)];
    }

    private static async Task RunAsync(string command, IReadOnlyList<string> arguments, string workingDirectory, ConsoleLog log, TimeSpan timeout, bool allowFailure = false)
    {
        _ = await RunProcessAsync(ShellEnvironment.Shared.Which(command) ?? command, arguments, workingDirectory, log, timeout, allowFailure);
    }

    private static async Task<ProcessRunResult> RunWpCliAsync(ServerProfile profile, IReadOnlyList<string> arguments, string workingDirectory, ConsoleLog log, TimeSpan timeout, bool allowFailure = false)
    {
        var php = PhpRuntime.Require(profile.PhpVersion);
        var wpCli = await EnsureWpCliAsync(log);
        return await RunProcessAsync(php, [wpCli, "--no-color", .. arguments], workingDirectory, log, timeout, allowFailure);
    }

    private static async Task<string> EnsureWpCliAsync(ConsoleLog log)
    {
        var path = Path.Combine(AppPaths.Runtime, "downloads", "wp-cli.phar");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (!File.Exists(path))
        {
            log.System("Downloading WP-CLI");
            await DownloadAsync("https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar", path);
        }
        else
        {
            log.System("Using cached WP-CLI: " + path);
        }
        return path;
    }

    private static async Task DownloadAsync(string url, string destination)
    {
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using (var response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync();
                await using var output = File.Create(temporary);
                await input.CopyToAsync(output);
            }
            File.Move(temporary, destination, overwrite: true);
        }
        catch (HttpRequestException ex)
        {
            throw new InvalidOperationException("Could not download a Printing & Publishing component. Check your internet connection, then retry. Existing project files were not removed. " + ex.Message, ex);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static async Task<ProcessRunResult> RunProcessAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, ConsoleLog log, TimeSpan timeout, bool allowFailure = false)
    {
        log.System(Path.GetFileName(executable) + " " + string.Join(" ", arguments.Select(Redact)));
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        if (Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
            Path.GetExtension(executable).Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            info.Arguments = "/d /s /c \"\"" + executable + "\" " + string.Join(" ", arguments.Select(QuoteForCmd)) + "\"";
        }
        else
        {
            foreach (var argument in arguments) info.ArgumentList.Add(argument);
        }
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor()) info.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not start " + Path.GetFileName(executable) + ".");
        OwnedProcesses.Track(process);
        var lines = new List<string>();
        var stdout = PipeAsync(process.StandardOutput, log, lines);
        var stderr = PipeAsync(process.StandardError, log, lines);
        try { await process.WaitForExitAsync().WaitAsync(timeout); }
        catch (TimeoutException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            throw new TimeoutException(Path.GetFileName(executable) + " timed out.");
        }
        await Task.WhenAll(stdout, stderr);
        if (process.ExitCode != 0 && !allowFailure)
            throw new InvalidOperationException($"{Path.GetFileName(executable)} exited with code {process.ExitCode}. {string.Join(Environment.NewLine, lines.TakeLast(12))}");
        if (process.ExitCode != 0) log.System($"{Path.GetFileName(executable)} exited with code {process.ExitCode}; continuing because this step is optional.");
        return new ProcessRunResult(process.ExitCode, lines);
    }

    private static async Task PipeAsync(StreamReader reader, ConsoleLog log, List<string> lines)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            if (!string.IsNullOrWhiteSpace(line)) log.System(WebUtility.HtmlDecode(line));
            lock (lines)
            {
                if (!string.IsNullOrWhiteSpace(line)) lines.Add(WebUtility.HtmlDecode(line));
                if (lines.Count > 40) lines.RemoveRange(0, lines.Count - 40);
            }
        }
    }

    private static string QuoteForCmd(string value) => "\"" + value.Replace("\"", "\"\"") + "\"";
    private static string Redact(string value) => value.StartsWith("--admin_password=", StringComparison.Ordinal) ? "--admin_password=(generated)" : value;
    private sealed record ProcessRunResult(int ExitCode, IReadOnlyList<string> Lines);
    private sealed record WordPressCredentials(string User, string Password, bool ExistingInstall);
}
