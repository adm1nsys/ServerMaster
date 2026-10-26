using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

static void Assert(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    Console.WriteLine("PASS " + message);
}

if (args.Contains("--emit-utf8"))
{
    Console.OutputEncoding = System.Text.Encoding.UTF8;
    Console.WriteLine("\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u0430");
    return;
}
if (args.Contains("--php-probe"))
{
    Console.WriteLine("Runtime: " + AppPaths.Runtime);
    foreach (var root in AppPaths.RuntimeRoots)
        Console.WriteLine($"Candidate: {root} | PHP 8.3: {File.Exists(Path.Combine(root, "php", "8.3", "php.exe"))}");
    Console.WriteLine("Selected PHP 8.3: " + (PhpRuntime.Find("8.3") ?? "missing"));
    return;
}
if (args.Contains("--ports-only"))
{
    var parsed = WindowsPortScanner.Parse($"TCP    127.0.0.1:8080    0.0.0.0:0    LISTENING    {Environment.ProcessId}\n" +
        $"UDP    0.0.0.0:5353    *:*    {Environment.ProcessId}\n" +
        $"TCP    127.0.0.1:8081    127.0.0.1:50000    ESTABLISHED    {Environment.ProcessId}");
    Assert(parsed.Count == 2 && parsed.Any(entry => entry.Port == 8080 && entry.Protocol == "TCP" && entry.CanOpenInBrowser) &&
        parsed.Any(entry => entry.Port == 5353 && entry.Protocol == "UDP" && !entry.CanOpenInBrowser),
        "port scanner distinguishes TCP listeners from UDP sockets and ignores established connections");
    var protectedEntry = new PortEntry { Port = 445, ProcessId = 4, ProcessName = "System" };
    Assert(!protectedEntry.CanTerminate && !new PortEntry { Port = 8080, ProcessId = Environment.ProcessId, ProcessName = "ServerMaster" }.CanTerminate,
        "system and application processes cannot be terminated from Ports");
    try { WindowsPortScanner.Terminate(protectedEntry); throw new Exception("Protected process termination accepted"); }
    catch (InvalidOperationException) { Assert(true, "termination service enforces the protected-process guard"); }
    var livePorts = await WindowsPortScanner.ScanAsync(includeUdp: true);
    Assert(livePorts.All(entry => entry.Port is > 0 and <= 65535 && entry.Protocol is "TCP" or "UDP"),
        "live TCP and UDP scan returns valid endpoints");
    int port;
    using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
    using var reserver = new PortReserver();
    var reservation = reserver.Reserve(port, "test profile");
    Assert(reservation.Port == port && reserver.IsReserved(port) && reserver.Reservations.Single().Note == "test profile",
        "port reservation records the held TCP port");
    try { reserver.Reserve(port, "duplicate"); throw new Exception("Duplicate reservation accepted"); }
    catch (InvalidOperationException) { Assert(true, "duplicate reservation is rejected"); }
    using (var competing = new TcpListener(IPAddress.Loopback, port))
    {
        try { competing.Start(); throw new Exception("Reserved port was bound by another listener"); }
        catch (SocketException) { Assert(true, "reservation prevents another listener from taking the port"); }
    }
    reserver.Release(port);
    Assert(!reserver.IsReserved(port) && reserver.Reservations.Count == 0, "release clears the reservation");
    using (var available = new TcpListener(IPAddress.Loopback, port)) { available.Start(); Assert(true, "released port can be bound again"); }
    return;
}
if (args.Contains("--health-only")) { await SiteHealthSmokeTests.Run(); return; }
if (args.Length >= 1 && args[0] == ConsoleInterrupt.Argument) { Environment.ExitCode = ConsoleInterrupt.Run(args); return; }
if (args.Contains("--settings-only")) { SettingsSmokeTests.Run(); return; }
if (args.Contains("--readiness-only")) { await ReadinessSmokeTests.Run(); return; }
if (args.Contains("--icons-only")) { ProfileIconsSmokeTests.Run(); return; }
if (args.Contains("--terminal-interrupt-only")) { await TerminalInterruptSmokeTests.Run(); return; }
if (args.Contains("--localization-only")) { LocalizationSmokeTests.Run(); return; }
if (args.Contains("--screen-states-only")) { ScreenStateSmokeTests.Run(); return; }
if (args.Length >= 2 && args[0] == "--single-instance-child") { Environment.ExitCode = SingleInstanceSmokeTests.Child(args[1]); return; }
if (args.Contains("--single-instance-only")) { await SingleInstanceSmokeTests.Run(); return; }
if (args.Contains("--recovery-logs-only")) { await RecoveryLogSmokeTests.Run(); return; }
if (args.Contains("--trace-only")) { await TraceSmokeTests.Run(); return; }
if (args.Contains("--diagnostics-only")) { await DiagnosticsSmokeTests.Run(); return; }
if (args.Contains("--dependency-status-only"))
{
    var node = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "node") };
    Assert(node.UpdateActionVisibility == Microsoft.UI.Xaml.Visibility.Collapsed,
        "missing runtime does not offer Update");
    node.Installed = true;
    Assert(node.UpdateActionVisibility == Microsoft.UI.Xaml.Visibility.Visible,
        "installed runtime offers Update");
    var absentProbe = new DependencyStatus { Dependency = new Dependency
    {
        Command = "servermaster-absent-runtime-test", Title = "Absent runtime", Summary = ""
    } };
    absentProbe.Error = "Previous installation failed";
    await new DependencyManager(new DispatcherQueue()).CheckAsync(absentProbe);
    Assert(!absentProbe.Installed && absentProbe.Error.Length == 0 && absentProbe.StatusText == "Missing",
        "a fresh missing-runtime check clears an obsolete installation error");
    var httpServer = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "http-server") };
    Assert(httpServer.VersionSelectionVisibility == Microsoft.UI.Xaml.Visibility.Visible,
        "http-server offers explicit version selection");
    var releases = DependencyManager.ParseNpmVersions("[\"1.2.3\",\"2.0.0\",\"not-a-version\"]");
    Assert(releases.SequenceEqual(["2.0.0", "1.2.3"]),
        "npm release list is parsed and newest versions are shown first");
    return;
}
if (args.Contains("--dependency-versions-online"))
{
    var httpServerStatus = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "http-server") };
    var versions = await new DependencyManager(new DispatcherQueue()).PackageVersionsAsync(httpServerStatus);
    Assert(versions.Count > 0 && Version.TryParse(versions[0], out _),
        "http-server versions load from npm through the Windows command shim");
    return;
}
if (args.Contains("--certificates-only"))
{
    var profile = new ServerProfile { Host = "127.0.0.1", HttpsEnabled = true };
    Assert(LocalCertificates.Status(profile).State == CertificateTrustState.Missing,
        "profile without a certificate shows missing state");
    try
    {
        LocalCertificates.Generate(profile, "localhost 127.0.0.1", false);
        Assert(LocalCertificates.Status(profile).State == CertificateTrustState.Untrusted,
            "new self-signed certificate is reported untrusted without changing the Windows trust store");
        profile.Host = "other.example";
        Assert(LocalCertificates.Status(profile).State == CertificateTrustState.Invalid,
            "certificate for a different host reports an actionable invalid state");
    }
    finally
    {
        if (!string.IsNullOrWhiteSpace(profile.CertificatePath))
        {
            var folder = Path.GetDirectoryName(profile.CertificatePath)!;
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
        }
    }
    return;
}
if (args.Contains("--templates-only"))
{
    var root = Path.Combine(Path.GetTempPath(), "ServerMaster-template-tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
        var exported = Path.Combine(root, "php.smtemplate");
        UserTemplateStore.Export([ProfileTemplate.BuiltIn.First(template => template.Id == "php")], exported);
        var json = await File.ReadAllTextAsync(exported);
        Assert(json.Contains("\"settings\"") && !json.Contains("rootPath") && !json.Contains("password"),
            "portable template includes settings but no path or password");
        var store = new UserTemplateStore(Path.Combine(root, "templates.json"));
        var imported = store.Import(exported, ProfileTemplate.BuiltIn);
        Assert(imported.Count == 1 && imported[0].IsUserDefined && imported[0].Engine == "phpBuiltIn" &&
            imported[0].Id != "php", "Mac-format template imports with a distinct identifier");
        var reloaded = new UserTemplateStore(Path.Combine(root, "templates.json"));
        reloaded.Load(ProfileTemplate.BuiltIn);
        Assert(reloaded.UserTemplates.Count == 1 && reloaded.UserTemplates[0].Title == "PHP site",
            "imported template survives restart");
        var unsupported = System.Text.Json.Nodes.JsonNode.Parse(json)!.AsArray();
        unsupported[0]!["settings"]!["engine"] = "nginx";
        await File.WriteAllTextAsync(exported, unsupported.ToJsonString());
        try { store.Import(exported, ProfileTemplate.BuiltIn); throw new Exception("Unsupported engine accepted"); }
        catch (InvalidOperationException) { Assert(store.UserTemplates.Count == 1, "unsupported Mac engine does not alter saved templates"); }
        Assert(DatabaseService.IsValidName("joomla_6") && !DatabaseService.IsValidName("bad-name"),
            "wizard database-name validation matches the service");
        var printing = ProfileTemplate.BuiltIn.First(template => template.Id == "web-to-print-store");
        UserTemplateStore.Export([printing], exported);
        var restoredPrinting = store.Import(exported, ProfileTemplate.BuiltIn.Concat(store.UserTemplates));
        Assert(restoredPrinting.Count == 1 && restoredPrinting[0].PackageKind == printing.PackageKind &&
            restoredPrinting[0].RecipeKind == printing.RecipeKind &&
            restoredPrinting[0].PluginPackages.SequenceEqual(printing.PluginPackages),
            "printing template keeps its Windows download and recipe metadata");
        Assert(restoredPrinting[0].CreateProfile(root, 8080).TemplateId == "web-to-print-store",
            "imported printing template retains its database and startup recipe identity");
        var showcase = ProfileTemplate.BuiltIn.First(template => template.Id == "web-to-print-showcase");
        var showcaseProfile = showcase.CreateProfile(root, 8090);
        Assert(showcase.Category == "Printing & Publishing" && showcase.QuickSetup && showcase.RecipeKind == "wordpress-w2p-showcase" &&
            showcase.PackageKind == "wordpress-w2p" && showcaseProfile.TemplateId == "web-to-print-store" &&
            showcaseProfile.DatabaseName == "servermaster_w2p_8090" && showcaseProfile.OpenBrowserOnStart,
            "the Web-to-Print Showcase is a one-click printing template that opens the browser on start");
        var taken = new HashSet<string>(["servermaster_w2p_8080", "servermaster_w2p_8080_2"], StringComparer.OrdinalIgnoreCase);
        Assert(TemplateRecipeService.FreeDatabaseName("servermaster_w2p_8081", taken) == "servermaster_w2p_8081" &&
            TemplateRecipeService.FreeDatabaseName("servermaster_w2p_8080", taken) == "servermaster_w2p_8080_3" &&
            TemplateRecipeService.FreeDatabaseName(new string('a', 64), new HashSet<string>([new string('a', 64)])).Length == 64,
            "a new store on a port another store used gets its own database, never the old one");
    }
    finally { Directory.Delete(root, true); }
    return;
}
if (args.Contains("--credentials-only"))
{
    var name = "smoke_" + Guid.NewGuid().ToString("N");
    try
    {
        DatabaseCredentialStore.Save(name, "site_user", "test-password-123");
        var saved = DatabaseCredentialStore.Read(name);
        Assert(saved is { User: "site_user", Password: "test-password-123" }, "database credential round trip in Windows Credential Manager");
    }
    finally { DatabaseCredentialStore.Delete(name); }
    Assert(DatabaseCredentialStore.Read(name) is null, "database credential is removed");
    return;
}
if (args.Contains("--profiles-only"))
{
    var phpSyntax = FileSyntax.ForFile("configuration.php").Highlight("public $port = 8080;\n// local server");
    Assert(phpSyntax.Any(span => span.Kind == FileSyntaxKind.Keyword) &&
        phpSyntax.Any(span => span.Kind == FileSyntaxKind.Number) &&
        phpSyntax.Any(span => span.Kind == FileSyntaxKind.Comment),
        "file editor highlights PHP keywords, numbers and comments");
    var jsonSyntax = FileSyntax.ForFile("package.json").Highlight("{ \"enabled\": true }");
    Assert(jsonSyntax.Any(span => span.Kind == FileSyntaxKind.String) &&
        jsonSyntax.Any(span => span.Kind == FileSyntaxKind.Keyword),
        "file editor highlights JSON strings and literals");
    var profile = new ServerProfile { Engine = "custom", CustomCommand = "cmd.exe",
        Environment = [new EnvVar { Key = "SITE_MODE", Value = "local" }] };
    Assert(profile.EnvironmentDictionary()["SITE_MODE"] == "local", "profile environment reaches launch plan");
    var restored = JsonSerializer.Deserialize<ServerProfile>(JsonSerializer.Serialize(profile))!;
    Assert(restored.EnvironmentDictionary()["SITE_MODE"] == "local", "profile environment survives persistence");
    restored.Environment.Add(new EnvVar { Key = "site_mode", Value = "other" });
    Assert(restored.ValidationIssues().Any(issue => issue.Contains("Duplicate environment variable")),
        "duplicate environment keys are rejected before start");
    Assert(!ServerProfile.IsValidEnvironmentKey("bad=key") && ServerProfile.IsValidEnvironmentKey("_KEY2"),
        "environment key validation matches Windows process rules");
    var originalSymbol = restored.Symbol;
    restored.Name = "Renamed site";
    restored.IconGlyph = "\uE774";
    Assert(restored.Symbol == "\uE774" && restored.Symbol != originalSymbol, "profile icon overrides engine icon");
    var renamed = JsonSerializer.Deserialize<ServerProfile>(JsonSerializer.Serialize(restored))!;
    Assert(renamed.Name == "Renamed site" && renamed.IconGlyph == "\uE774", "confirmed profile identity survives persistence");
    var site = Path.Combine(Path.GetTempPath(), "ServerMaster-config-tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(site);
    try
    {
        await File.WriteAllTextAsync(Path.Combine(site, ".env"), "SITE_MODE=local");
        await File.WriteAllTextAsync(Path.Combine(site, "package.json"), "{}");
        await File.WriteAllTextAsync(Path.Combine(site, "random.txt"), "ignore");
        var configProfile = new ServerProfile { Engine = "nodeScript", RootPath = site };
        var configFiles = ProfileConfigInventory.Collect(configProfile);
        Assert(configFiles.Select(file => file.Title).SequenceEqual([".env", "package.json"]),
            "profile config inventory shows only existing relevant site files");
        Assert(configFiles.All(file => file.CanEdit) && Directory.GetFileSystemEntries(site).Length == 3,
            "opening config inventory does not modify the project folder");
        var phpProfile = new ServerProfile { Engine = "phpBuiltIn", RootPath = site,
            PhpMemoryLimit = "768M", PhpUploadMaxFilesize = "128M", PhpMaxExecutionTime = 600,
            PhpDisplayErrors = false };
        var phpArguments = LaunchPlanBuilder.PhpConfigurationArguments(phpProfile);
        Assert(phpArguments.Contains("memory_limit=768M") && phpArguments.Contains("upload_max_filesize=128M") &&
            phpArguments.Contains("post_max_size=128M") && phpArguments.Contains("max_execution_time=600") &&
            phpArguments.Contains("display_errors=0"), "PHP profile settings become runtime directives");
        Assert(phpProfile.ValidationIssues().Count == 0, "valid PHP limits pass profile validation");
        phpProfile.PhpMemoryLimit = "not a PHP size";
        Assert(phpProfile.ValidationIssues().Any(issue => issue.Contains("memory limit")), "invalid PHP size is rejected before start");
        var staticProfile = new ServerProfile { Engine = "httpServer", RootPath = site };
        staticProfile.ConfigPreset = "spa";
        Assert(staticProfile.SpaFallback && !staticProfile.DirectoryListing,
            "SPA preset applies its serving switches when selected");
        staticProfile.DirectoryListing = true;
        var restoredStatic = JsonSerializer.Deserialize<ServerProfile>(JsonSerializer.Serialize(staticProfile))!;
        Assert(restoredStatic.ConfigPreset == "spa" && restoredStatic.DirectoryListing,
            "loading a profile preserves manual changes made after choosing a preset");
        staticProfile.BasicAuthEnabled = true;
        Assert(staticProfile.ValidationIssues().Any(issue => issue.Contains("login and password")),
            "basic authentication requires both credentials");
        staticProfile.BasicAuthUser = "local";
        staticProfile.BasicAuthPassword = "profile-secret-test";
        Assert(staticProfile.ValidationIssues().Count == 0, "complete basic authentication credentials pass validation");
        var secretPlan = new LaunchPlan { Executable = "http-server", WorkingDirectory = site,
            Arguments = ["--username", staticProfile.BasicAuthUser, "--password", staticProfile.BasicAuthPassword] };
        Assert(!secretPlan.DisplayCommand.Contains(staticProfile.BasicAuthPassword) &&
            secretPlan.DisplayCommand.Contains("********"), "launch command display redacts basic-auth password");
        var writable = Path.Combine(site, "cache");
        Directory.CreateDirectory(writable);
        var readOnly = Path.Combine(site, "settings.ini");
        File.WriteAllText(readOnly, "test");
        File.SetAttributes(readOnly, FileAttributes.ReadOnly);
        try
        {
            var permissions = SitePermissions.Check(site);
            Assert(permissions.CheckedCount >= 3 && !permissions.Truncated &&
                permissions.Problems.Count == 1 && permissions.Problems[0].Path == readOnly,
                "permission check probes CMS folders and reports read-only files");
            Assert(Directory.GetFiles(writable).Length == 0 &&
                Directory.GetFiles(site, ".servermaster-check-*").Length == 0,
                "permission probes leave no files behind");
        }
        finally { File.SetAttributes(readOnly, FileAttributes.Normal); }
        using var occupiedPort = new TcpListener(IPAddress.Loopback, 0);
        occupiedPort.Start();
        var blockedPort = ((IPEndPoint)occupiedPort.LocalEndpoint).Port;
        Assert(!await ProfilePortSuggestions.IsAvailableAsync("127.0.0.1", blockedPort),
            "profile port picker identifies an occupied listener");
        var nextPort = await ProfilePortSuggestions.NearestFreeAsync("127.0.0.1", blockedPort);
        Assert(nextPort > blockedPort && await ProfilePortSuggestions.IsAvailableAsync("127.0.0.1", nextPort.Value),
            "profile port picker skips occupied port and finds the next available one");
        Assert(ProfilePortSuggestions.Find(8443)?.Title == "standard local HTTPS" &&
            ProfilePortSuggestions.Find(8080)?.Title == "standard local", "profile port presets include HTTP and HTTPS choices");
    }
    finally { Directory.Delete(site, true); }
    return;
}
if (args.Contains("--host-owner-child"))
{
    var port = int.Parse(args[1]);
    var hostExe = Path.GetFullPath("windows/src/ServerMaster.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ServerMaster.exe");
    var client = new ElevatedServerClient { HostPath = hostExe };
    var plan = new LaunchPlan
    {
        Executable = ShellEnvironment.Shared.Which("node")!,
        WorkingDirectory = Environment.CurrentDirectory,
        Arguments = ["-e", $"require('net').createServer(s=>s.end('ok')).listen({port},'127.0.0.1')"]
    };
    await client.StartAsync(plan, CancellationToken.None, testMode: true);
    var ready = false;
    for (var attempt = 0; attempt < 50 && !ready; attempt++)
    {
        try { using var probe = new TcpClient(); await probe.ConnectAsync(IPAddress.Loopback, port); ready = true; }
        catch (SocketException) { await Task.Delay(100); }
    }
    if (!ready) throw new Exception("The helper's child did not listen.");
    Console.WriteLine($"READY {client.HelperProcess.Id} {client.ServerProcessId}");
    Console.Out.Flush();
    await Task.Delay(Timeout.InfiniteTimeSpan);
}
if (args.Contains("--lifecycle-only")) { await ServerLifecycleSmokeTests.Run(); return; }
if (args.Contains("--terminal-only"))
{
    var output = new System.Text.StringBuilder();
    using var session = new TerminalSession("CMD", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    session.Output += text => { lock (output) output.Append(text); };
    session.Start();
    session.WriteLine("set SERVERMASTER_TERMINAL_TEST=alive");
    for (var attempt = 0; attempt < 50 && output.ToString().Count(character => character == '>') < 2; attempt++) await Task.Delay(100);
    session.WriteLine("echo %SERVERMASTER_TERMINAL_TEST%");
    for (var attempt = 0; attempt < 50 && !output.ToString().Contains("alive", StringComparison.Ordinal); attempt++) await Task.Delay(100);
    Assert(output.ToString().Contains("alive", StringComparison.Ordinal), "Terminal tab keeps a persistent writable shell session");
    var newest = session.PreviousCommand("unfinished command");
    var older = session.PreviousCommand("");
    var forward = session.NextCommand();
    var draft = session.NextCommand();
    Assert(newest == "echo %SERVERMASTER_TERMINAL_TEST%" && older == "set SERVERMASTER_TERMINAL_TEST=alive" &&
        forward == newest && draft == "unfinished command", "Terminal history moves backward and forward without losing the draft");
    return;
}
if (args.Contains("--node-online"))
{
    var original = ShellEnvironment.Shared.Which("node");
    try
    {
        var version = (await NodeRuntime.VersionsAsync()).First(item => item.StartsWith("v20."));
        await NodeRuntime.SelectAsync(version, _ => { });
        Assert(NodeRuntime.ActiveDirectory is not null && ShellEnvironment.Shared.Which("node")!.StartsWith(NodeRuntime.ActiveDirectory), "Selected old Node.js takes precedence only inside ServerMaster");
        var npmStatus = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "npm") };
        await new DependencyManager(new DispatcherQueue()).CheckAsync(npmStatus);
        Assert(npmStatus.Installed, "Older Node.js includes working npm");
        await NodeRuntime.SelectAsync("System", _ => { });
        Assert(ShellEnvironment.Shared.Which("node") == original, "System selection restores the original runtime");
    }
    finally
    {
        for (var attempt = 0; Directory.Exists(AppPaths.Runtime); attempt++)
        {
            try { Directory.Delete(AppPaths.Runtime, true); }
            catch (UnauthorizedAccessException) when (attempt < 5) { await Task.Delay(1000); }
            catch (IOException) when (attempt < 5) { await Task.Delay(1000); }
        }
    }
    return;
}
if (args.Contains("--npm-only"))
{
    var npm = new DependencyStatus { Dependency = Dependency.Catalog.First(item => item.Command == "npm") };
    await new DependencyManager(new DispatcherQueue()).CheckAsync(npm);
    Assert(npm.Installed, "Installed npm runs through dependency detection: " + npm.Message);
    return;
}
if (args.Contains("--printshopcrm-online"))
{
    var root = Path.Combine(Path.GetTempPath(), "servermaster-printshopcrm-" + Guid.NewGuid().ToString("N"));
    var template = ProfileTemplate.BuiltIn.First(item => item.Id == "printshopcrm");
    int port;
    using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
    var profile = template.CreateProfile(root, port);
    try
    {
        await new TemplateDownloadService().DownloadAndExtractAsync(template, profile, new ConsoleLog());
        var crmConfig = await File.ReadAllTextAsync(Path.Combine(root, ".env"));
        try
        {
            await new TemplateDownloadService().DownloadAndExtractAsync(template,
                template.CreateProfile(root, port == 65535 ? port - 1 : port + 1), new ConsoleLog());
            throw new Exception("Changed-port retry was accepted");
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("port", StringComparison.OrdinalIgnoreCase))
        {
            Assert(await File.ReadAllTextAsync(Path.Combine(root, ".env")) == crmConfig,
                "printing setup rejects a changed port without touching project credentials");
        }
        await new TemplateDownloadService().DownloadAndExtractAsync(template, profile, new ConsoleLog());
        Assert(await File.ReadAllTextAsync(Path.Combine(root, ".env")) == crmConfig,
            "PrintShopCRM setup resumes without replacing its local credentials");
        var plan = LaunchPlanBuilder.Build(profile);
        var info = new ProcessStartInfo(plan.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = plan.WorkingDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in plan.Arguments) info.ArgumentList.Add(argument);
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor(plan.Environment)) info.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(info) ?? throw new Exception("Could not start PrintShopCRM.");
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
            string? body = null;
            for (var attempt = 0; attempt < 40; attempt++)
            {
                try { body = await client.GetStringAsync(profile.Address); break; }
                catch (HttpRequestException) { await Task.Delay(250); }
            }
            Assert(body is not null && body.Contains("PrintShopCRM", StringComparison.OrdinalIgnoreCase), "PrintShopCRM template reaches localhost");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
        }
    }
    finally
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }
    return;
}
if (args.Contains("--web-to-print-online"))
{
    if (!DatabaseService.Detect(true).Installed)
    {
        Console.WriteLine("SKIP Web-to-Print: install MariaDB first");
        return;
    }
    if (PhpRuntime.Find("8.3") is null)
    {
        var lastPercent = -1;
        await PhpRuntime.InstallAsync("8.3", (message, percent) =>
        {
            var currentPercent = (int)percent;
            if (currentPercent == lastPercent) return;
            lastPercent = currentPercent;
            Console.WriteLine($"{currentPercent}% {message}");
        });
    }
    Assert(File.Exists(PhpRuntime.Require("8.3")), "PHP 8.3 is ready for Web-to-Print integration test");
    var root = Path.Combine(Path.GetTempPath(), "servermaster-w2p-" + Guid.NewGuid().ToString("N"));
    var databaseRoot = Path.Combine(Path.GetTempPath(), "servermaster-w2p-db-" + Guid.NewGuid().ToString("N"));
    DatabaseService.TestRoot = databaseRoot;
    var template = ProfileTemplate.BuiltIn.First(item => item.Id == "web-to-print-store");
    int port;
    using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
    var profile = template.CreateProfile(root, port);
    try
    {
        await new TemplateDownloadService().DownloadAndExtractAsync(template, profile, new ConsoleLog());
        Assert(File.Exists(Path.Combine(root, "servermaster-demo.md")), "Web-to-Print writes local demo credentials");
        var wordpressConfig = await File.ReadAllTextAsync(Path.Combine(root, "wp-config.php"));
        var demoCredentials = await File.ReadAllTextAsync(Path.Combine(root, "servermaster-demo.md"));
        await new TemplateDownloadService().DownloadAndExtractAsync(template, profile, new ConsoleLog());
        Assert(await File.ReadAllTextAsync(Path.Combine(root, "wp-config.php")) == wordpressConfig &&
               await File.ReadAllTextAsync(Path.Combine(root, "servermaster-demo.md")) == demoCredentials,
            "Web-to-Print setup resumes without replacing WordPress salts or admin credentials");
        Assert(File.Exists(Path.Combine(root, "wp-content", "plugins", "woocommerce", "woocommerce.php")), "Web-to-Print installs WooCommerce locally");
        Assert(File.Exists(Path.Combine(root, "wp-content", "plugins", "printcart-integration", "nbdesigner.php")), "Web-to-Print installs Printcart locally");
        var activePlugins = await DatabaseService.RunQueryAsync(profile.DatabaseName,
            "SELECT option_value FROM wp_options WHERE option_name='active_plugins';");
        Assert(activePlugins.Contains("woocommerce/woocommerce.php", StringComparison.Ordinal) &&
            activePlugins.Contains("printcart-integration/nbdesigner.php", StringComparison.Ordinal),
            "Web-to-Print activates WooCommerce and Printcart");
        var plan = LaunchPlanBuilder.Build(profile);
        var info = new ProcessStartInfo(plan.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = plan.WorkingDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in plan.Arguments) info.ArgumentList.Add(argument);
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor(plan.Environment)) info.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(info) ?? throw new Exception("Could not start Web-to-Print profile.");
        try
        {
            using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true, UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
            string? body = null;
            for (var attempt = 0; attempt < 40; attempt++)
            {
                try { body = await client.GetStringAsync(profile.Address); break; }
                catch (HttpRequestException) { await Task.Delay(250); }
            }
            Assert(body is not null && body.Contains("ServerMaster Web-to-Print Demo", StringComparison.OrdinalIgnoreCase), "Web-to-Print template reaches installed WordPress localhost");
            var login = await client.GetStringAsync(profile.Address.TrimEnd('/') + "/wp-login.php");
            Assert(login.Contains("user_login", StringComparison.Ordinal), "Web-to-Print admin login page is reachable");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
        }
    }
    finally
    {
        await DatabaseService.StopAsync();
        DatabaseService.TestRoot = null;
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        if (Directory.Exists(databaseRoot)) Directory.Delete(databaseRoot, recursive: true);
    }
    return;
}
if (args.Contains("--job-child"))
{
    using var child = Process.Start(new ProcessStartInfo("cmd.exe", "/d /c ping -n 120 127.0.0.1 >nul") { UseShellExecute = false, CreateNoWindow = true })!;
    OwnedProcesses.Track(child);
    Console.WriteLine(child.Id);
    return;
}
if (args.Contains("--job-only"))
{
    using var parent = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--job-child") { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true })!;
    var id = int.Parse((await parent.StandardOutput.ReadToEndAsync()).Trim());
    await parent.WaitForExitAsync();
    await Task.Delay(1000);
    bool exited;
    try { using var child = Process.GetProcessById(id); exited = child.HasExited; }
    catch (ArgumentException) { exited = true; }
    Assert(exited, "Owned server exits when its parent application exits");
    return;
}
if (args.Contains("--job-port-child"))
{
    var port = int.Parse(args[1]);
    var node = ShellEnvironment.Shared.Which("node") ?? throw new Exception("Node.js is required for job port test.");
    var start = new ProcessStartInfo(node) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
    start.ArgumentList.Add("-e");
    start.ArgumentList.Add("require('net').createServer(s=>s.end()).listen(" + port + ",'127.0.0.1',()=>console.log('READY'))");
    using var child = Process.Start(start) ?? throw new Exception("Could not start job port child.");
    OwnedProcesses.Track(child);
    if (await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)) != "READY")
        throw new Exception("Job port child was not ready.");
    Console.WriteLine(child.Id);
    Console.Out.Flush();
    await Task.Delay(Timeout.InfiniteTimeSpan);
}
if (args.Contains("--job-port-only"))
{
    using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
    listener.Start();
    var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
    listener.Stop();
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
    start.ArgumentList.Add("--job-port-child");
    start.ArgumentList.Add(port.ToString());
    using var parent = Process.Start(start) ?? throw new Exception("Could not start job owner.");
    try
    {
        var childPid = int.Parse((await parent.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15)))!);
        using var connection = new System.Net.Sockets.TcpClient();
        await connection.ConnectAsync(System.Net.IPAddress.Loopback, port).WaitAsync(TimeSpan.FromSeconds(5));
        parent.Kill();
        await parent.WaitForExitAsync();
        var released = false;
        for (var attempt = 0; attempt < 30; attempt++)
        {
            using var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
            try { probe.Start(); released = true; break; }
            catch (System.Net.Sockets.SocketException) { await Task.Delay(100); }
        }
        Assert(released, "Forced app exit releases a child-owned port");
        var childExited = false;
        try { using var child = Process.GetProcessById(childPid); childExited = child.HasExited; }
        catch (ArgumentException) { childExited = true; }
        Assert(childExited, "Forced app exit kills the child server");
    }
    finally { if (!parent.HasExited) { parent.Kill(true); await parent.WaitForExitAsync(); } }
    return;
}
if (args.Contains("--database-only")) { await DatabaseSmokeTests.Run(); return; }
if (args.Contains("--adminer-only"))
{
    if (!AdminerService.IsInstalled || (PhpRuntime.Find("") ?? ShellEnvironment.Shared.Which("php")) is null)
    { Console.WriteLine("SKIP Adminer: install Adminer and PHP first"); return; }
    try
    {
        await Task.WhenAll(AdminerService.StartAsync(), AdminerService.StartAsync());
        using var client = new HttpClient(new HttpClientHandler { UseProxy = false });
        var html = await client.GetStringAsync(AdminerService.Address);
        Assert(AdminerService.IsRunning && html.Contains("Adminer", StringComparison.OrdinalIgnoreCase), "Adminer serves its actual page and handles duplicate Start");
    }
    finally { AdminerService.Stop(); }
    Assert(!AdminerService.IsRunning, "Adminer stop releases its PHP process");
    return;
}
await SiteFilesSmokeTests.Run();
if (args.Contains("--files-only")) return;
await ServerLifecycleSmokeTests.Run();
var manager = new DependencyManager(new DispatcherQueue());
var ports = await WindowsPortScanner.ScanAsync();
Assert(ports.All(entry => entry.Port is > 0 and <= 65535 && entry.ProcessId > 0 && entry.ProcessName.Length > 0), "Windows port scanner returns valid listening sockets and process owners");
await HttpsSmokeTests.Run(args.Contains("--https-online"));
var shimFolder = Path.Combine(AppPaths.Runtime, "tool folder with spaces");
Directory.CreateDirectory(shimFolder);
var shimPath = Path.Combine(shimFolder, "test-runtime.cmd");
await File.WriteAllTextAsync(shimPath, "@echo off\r\necho 1.2.3\r\n");
try
{
    await File.WriteAllTextAsync(Path.Combine(shimFolder, "test-runtime"), "#!/bin/sh\necho wrong\n");
    ShellEnvironment.Shared.SetExtraEntries([shimFolder]);
    Assert(string.Equals(ShellEnvironment.Shared.Which("test-runtime"), shimPath, StringComparison.OrdinalIgnoreCase), "Windows shim wins over adjacent extensionless Unix script");
    ShellEnvironment.Shared.SetExtraEntries([]);
    var shim = new DependencyStatus { Dependency = new Dependency { Command = shimPath, Title = "Command shim", Summary = "" } };
    await manager.CheckAsync(shim);
    Assert(shim.Installed && shim.Version == "1.2.3", "Windows command shims are checked from paths with spaces");
}
finally { Directory.Delete(AppPaths.Runtime, true); }
var absent = new DependencyStatus { Dependency = new Dependency { Command = "servermaster-nonexistent-test-tool", Title = "Missing test runtime", Summary = "" } };
var check1 = manager.CheckAsync(absent);
await Task.WhenAll(check1, manager.CheckAsync(absent));
Assert(absent.Checked && !absent.Checking && !absent.Installed && absent.Message.Length > 0, "Missing runtime has a completed, readable result");
var status = new DependencyStatus { Dependency = Dependency.PhpPackages.First() };
var changes = new HashSet<string>();
status.PropertyChanged += (_, e) => changes.Add(e.PropertyName!);
status.Busy = true;
Assert(!status.CanAct && status.ActivityVisibility == Microsoft.UI.Xaml.Visibility.Visible, "Installation disables repeated actions and exposes progress");
status.Error = "Download failed";
status.Busy = false;
Assert(status.StatusText == "Failed" && status.ActionText == "Retry" && changes.Contains("ActivityVisibility"), "Failures remain visible and offer retry");
status.Installed = true;
status.RemovalBlockedReason = "Used by: Test site";
Assert(!status.CanAct, "PHP removal is disabled when profiles use it");
var failing = new DependencyStatus { Dependency = new Dependency
{
    Command = "servermaster-failing-installer-test", Title = "Failing test runtime", Summary = "",
    InstallCommand = "Write-Output 'phase one'; Start-Sleep -Milliseconds 1000; exit 7"
} };
var clock = Stopwatch.StartNew();
long firstOutput = -1;
failing.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(failing.Message) && failing.Message == "phase one") firstOutput = clock.ElapsedMilliseconds; };
try { await manager.InstallAsync(failing, new ConsoleLog()); throw new Exception("Failed installer accepted"); }
catch (InvalidOperationException)
{
    Assert(firstOutput >= 0 && clock.ElapsedMilliseconds - firstOutput >= 700, "Installer output arrives before the process exits");
    Assert(!failing.Busy && failing.CanAct && failing.Error.Contains("Failing test runtime") && failing.Error.Contains("7"), "Nonzero installer exit retains a named error and allows retry");
}
try { PhpRuntime.DirectoryFor("../../outside"); throw new Exception("Invalid branch accepted"); }
catch (InvalidOperationException) { Console.WriteLine("PASS Invalid PHP branch rejected"); }
var joomla = ProfileTemplate.BuiltIn.First(template => template.Id == "joomla5").CreateProfile(AppPaths.Runtime, 8080);
Assert(JsonSerializer.Deserialize<ServerProfile>(JsonSerializer.Serialize(joomla))!.PhpVersion == "8.2", "Template PHP pin survives serialization");
try { PhpRuntime.Require("8.2"); throw new Exception("Missing PHP accepted"); }
catch (FileNotFoundException ex) { Assert(ex.Message.Contains("8.2"), "Missing PHP error identifies the pinned version"); }
var printingTemplates = ProfileTemplate.BuiltIn.Where(template => template.Category == "Printing & Publishing").ToArray();
Assert(printingTemplates.Length >= 2, "Printing & Publishing category exposes diploma templates");
var printShopCrm = ProfileTemplate.BuiltIn.First(template => template.Id == "printshopcrm");
Assert(printShopCrm.CanDownloadPackage && printShopCrm.Engine == "nodeScript" && printShopCrm.NodeEntryFile == "server.mjs", "PrintShopCRM template downloads and launches as a Node.js server");
Assert(ProfileRequirements.CommandsFor(printShopCrm.CreateProfile(AppPaths.Runtime, 3333)).Contains("npm"), "PrintShopCRM wizard checks npm before downloading the project");
var webToPrint = ProfileTemplate.BuiltIn.First(template => template.Id == "web-to-print-store");
Assert(webToPrint.CanDownloadPackage && webToPrint.NeedsDatabase && webToPrint.PluginPackages.Contains("woocommerce") && webToPrint.PluginPackages.Contains("printcart-integration"), "Web-to-Print template declares WordPress database and plugins");
Assert(webToPrint.CreateProfile(AppPaths.Runtime, 8088).DatabaseName != webToPrint.CreateProfile(AppPaths.Runtime, 8089).DatabaseName, "Web-to-Print profiles do not share a database by default");

var unicode = "\u0423\u0441\u0442\u0430\u043d\u043e\u0432\u043a\u0430 \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u0430";
var encoded = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(unicode));
var unicodeStatus = new DependencyStatus { Dependency = new Dependency
{
    Command = "servermaster-encoding-test", Title = "Encoding test", Summary = "",
    InstallCommand = "$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')); Write-Output $text; & '" + Environment.ProcessPath!.Replace("'", "''") + "' --emit-utf8; exit 7"
} };
var unicodeLog = new ConsoleLog();
try { await manager.InstallAsync(unicodeStatus, unicodeLog); }
catch (InvalidOperationException) { }
Assert(unicodeLog.Lines.Count(line => line == unicode) == 2, "PowerShell and native Cyrillic output survive UTF-8 decoding");
var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "python.exe");
Assert(ShellEnvironment.IsPythonStoreAlias(alias) && !ShellEnvironment.IsPythonStoreAlias(Path.Combine(AppPaths.Runtime, "python.exe")), "Python Store placeholder is distinguished from a real interpreter");
Directory.CreateDirectory(PhpRuntime.DirectoryFor("8.2"));
try
{
    await File.WriteAllTextAsync(Path.Combine(PhpRuntime.DirectoryFor("8.2"), "php.exe"), "not executable");
    var incomplete = new DependencyStatus { Dependency = Dependency.PhpPackages.First(item => item.PhpVersion == "8.2") };
    await manager.CheckAsync(incomplete);
    Assert(!incomplete.Installed && incomplete.Error.Contains("php8.dll") && !incomplete.Checking, "Incomplete PHP is rejected before executing it, with the missing DLL named");
}
finally { Directory.Delete(AppPaths.Runtime, true); }

Directory.CreateDirectory(AppPaths.Runtime);
try
{
    var diagnosticProfile = new ServerProfile
    {
        Name = "Diagnostic test", Engine = "custom", WorkingDirectory = AppPaths.Runtime,
        CustomCommand = Environment.ProcessPath!, BasicAuthPassword = "do-not-export-this"
    };
    using var occupied = new TcpListener(IPAddress.Loopback, 0);
    occupied.Start();
    diagnosticProfile.Port = ((IPEndPoint)occupied.LocalEndpoint).Port;
    var findings = await ProfileDiagnostics.CheckAsync(diagnosticProfile);
    Assert(findings.Any(item => item.Title == "Port" && item.Problem && item.Remedy.Length > 0), "Diagnostics explains a busy port without stopping its owner");
    occupied.Stop();
    findings = await ProfileDiagnostics.CheckAsync(diagnosticProfile);
    Assert(findings.Any(item => item.Title == "Port" && !item.Problem), "Diagnostics recognizes and releases a free port");
    diagnosticProfile.Port = 70000;
    diagnosticProfile.WorkingDirectory = Path.Combine(AppPaths.Runtime, "absent");
    findings = await ProfileDiagnostics.CheckAsync(diagnosticProfile);
    Assert(findings.Any(item => item.Title == "Port" && item.Problem) && findings.Any(item => item.Title == "Working folder" && item.Problem), "Diagnostics reports invalid port and missing folder independently");
    diagnosticProfile.WorkingDirectory = AppPaths.Runtime;
    diagnosticProfile.State = ServerState.Running;
    foreach (var code in new[] { 200, 503 })
    {
        using var server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        diagnosticProfile.Port = ((IPEndPoint)server.LocalEndpoint).Port;
        var respond = Task.Run(async () =>
        {
            using var connection = await server.AcceptTcpClientAsync().WaitAsync(TimeSpan.FromSeconds(10));
            await using var stream = connection.GetStream();
            using var reader = new StreamReader(stream, leaveOpen: true);
            while (await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)) is { Length: > 0 }) { }
            await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes($"HTTP/1.1 {code} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
        });
        findings = await ProfileDiagnostics.CheckAsync(diagnosticProfile);
        await respond;
        Assert(findings.Any(item => item.Title == "HTTP response" && item.Problem == (code >= 400) && item.Detail.Contains(code.ToString())), $"Diagnostics classifies HTTP {code}");
    }
    Assert(!ProfileDiagnostics.Report(findings).Contains(diagnosticProfile.BasicAuthPassword), "Diagnostic report does not serialize profile credentials");
}
finally { Directory.Delete(AppPaths.Runtime, true); }

var joomlaArgument = Array.IndexOf(args, "--joomla-root");
if (joomlaArgument >= 0)
{
    var root = args[joomlaArgument + 1];
    var php = args[Array.IndexOf(args, "--php") + 1];
    Assert(PhpSiteCompatibility.IsJoomla(root), "Existing Joomla site is detected without changing its files");
    var router = PhpSiteCompatibility.EnsureJoomlaRouter();
    int port;
    using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
    var info = new ProcessStartInfo(php) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var arg in new[] { "-c", Path.GetDirectoryName(php)!, "-S", "127.0.0.1:" + port, "-t", root, router }) info.ArgumentList.Add(arg);
    using var process = Process.Start(info)!;
    var stdout = process.StandardOutput.ReadToEndAsync();
    var stderr = process.StandardError.ReadToEndAsync();
    try
    {
        using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:" + port), Timeout = TimeSpan.FromSeconds(10) };
        string? html = null;
        for (var attempt = 0; attempt < 30; attempt++)
        {
            try { html = await client.GetStringAsync("/installation/index.php"); break; }
            catch (HttpRequestException) { await Task.Delay(100); }
        }
        Assert(html is not null && !html.Contains("/installation/media/") && !html.Contains("/installation/installation/"), "Joomla installer uses correct asset base paths");
        var assets = System.Text.RegularExpressions.Regex.Matches(html!, "(?:href|src)=\"([^\"]+\\.(?:css|js)(?:\\?[^\"]*)?)\"")
            .Select(match => WebUtility.HtmlDecode(match.Groups[1].Value)).Where(path => path.StartsWith('/')).Distinct().ToList();
        Assert(assets.Count >= 10, "Joomla installer exposes its CSS and JavaScript assets");
        foreach (var asset in assets)
        {
            using var response = await client.GetAsync(asset);
            Assert(response.IsSuccessStatusCode, "Joomla asset HTTP 200: " + asset.Split('?')[0]);
            Assert(response.Content.Headers.ContentType?.MediaType != "text/html", "Asset is not an HTML fallback");
        }
        using var noRedirect = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { BaseAddress = client.BaseAddress };
        using var post = await noRedirect.PostAsync("/installation/index.php?task=test", new StringContent("probe=1"));
        Assert((int)post.StatusCode == 307 && post.Headers.Location?.OriginalString == "/installation/?task=test", "Joomla canonical redirect preserves POST semantics and query string");
        using var absentAsset = await client.GetAsync("/media/servermaster-not-present.js");
        Assert(absentAsset.StatusCode == HttpStatusCode.NotFound, "Missing assets remain 404 instead of being disguised");
    }
    finally
    {
        if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
        await Task.WhenAll(stdout, stderr);
        Directory.Delete(AppPaths.Runtime, true);
    }
}

if (!args.Contains("--online")) return;
Directory.CreateDirectory(AppPaths.Runtime);
try
{
    var vc = await VcRuntime.FetchAsync((_, _) => { }, refresh: true);
    Assert(vc.Version.Major == 14 && File.Exists(vc.Path), "Official Visual C++ installer version and Microsoft signature verified without installing");
    foreach (var branch in new[] { "8.2", "8.3" })
    {
        var runtime = new DependencyStatus { Dependency = Dependency.PhpPackages.First(item => item.PhpVersion == branch) };
        var ticks = 0;
        runtime.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(runtime.Progress)) ticks++; };
        await manager.InstallAsync(runtime, new ConsoleLog());
        Assert(runtime.Installed && !runtime.Busy && ticks > 3, $"PHP {branch} download, hash verification, extensions and progress");
    }
    var first = PhpRuntime.Require("8.2");
    var second = PhpRuntime.Require("8.3");
    Assert(first != second && File.Exists(first) && File.Exists(second), "PHP branches coexist at independent executable paths");
    var project = Path.Combine(AppPaths.Runtime, "project with spaces");
    Directory.CreateDirectory(project);
    await File.WriteAllTextAsync(Path.Combine(project, "index.php"), "<?php echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;");
    foreach (var branch in new[] { "8.2", "8.3" })
    {
        int port;
        using (var probe = new TcpListener(IPAddress.Loopback, 0)) { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; }
        var profile = new ServerProfile { Engine = "phpBuiltIn", PhpVersion = branch, RootPath = project, Port = port };
        var plan = LaunchPlanBuilder.Build(profile);
        Assert(plan.Executable == PhpRuntime.Require(branch), $"Launch plan uses PHP {branch}");
        var info = new ProcessStartInfo(plan.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = plan.WorkingDirectory };
        foreach (var argument in plan.Arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            string? body = null;
            for (var attempt = 0; attempt < 20; attempt++)
            {
                try { body = await client.GetStringAsync(profile.Address); break; }
                catch (HttpRequestException) { await Task.Delay(150); }
            }
            Assert(body == branch, $"HTTP response executes PHP {branch} from a folder with spaces");
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }
    PhpRuntime.Remove("8.2");
    Assert(PhpRuntime.Find("8.2") is null && PhpRuntime.Find("8.3") is not null, "Removing one PHP version preserves the other");
}
finally
{
    if (Directory.Exists(AppPaths.Runtime)) Directory.Delete(AppPaths.Runtime, true);
}
