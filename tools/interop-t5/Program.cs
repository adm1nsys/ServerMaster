using System.Text.Json;
using System.Text.Json.Nodes;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

if (args.Length is < 1 or > 2) throw new ArgumentException("Supply an isolated fixture directory and optional verify-return mode.");
var root = Path.GetFullPath(args[0]);
Directory.CreateDirectory(root);
Environment.SetEnvironmentVariable("SERVERMASTER_DATA_DIR", Path.Combine(root, "dotnet-data"));
var json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
void Write(string name, object value) => File.WriteAllText(Path.Combine(root, name), JsonSerializer.Serialize(value, json));
void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }

if (args.Length == 2 && args[1] == "verify-return")
{
    var original = TranslationPacks.Read(Path.Combine(root, "windows-uk.strings"))!;
    var back = TranslationPacks.Read(Path.Combine(root, "uk-again.strings"))!;
    Require(original.Strings.Count == back.Strings.Count && original.Strings.All(p => back.Strings.TryGetValue(p.Key, out var v) && v == p.Value), "Windows → Mac → Windows translation data changed");
    Require(original.Language == back.Language && original.AppVersion == back.AppVersion && original.PackVersion == back.PackVersion, "Translation header changed");
    var returnedProfiles = JsonSerializer.Deserialize<ServerProfile[]>(File.ReadAllText(Path.Combine(root, "windows-via-mac.json")), json);
    Require(returnedProfiles is { Length: > 0 }, "Mac re-exported invalid Windows profiles");
    File.Copy(Path.Combine(root, "windows-via-mac.json"), AppPaths.ProfilesFile, true);
    var verifyStore = new ProfileStore();
    var verified = verifyStore.LoadProfiles();
    Require(verified.Count == 3, "Windows profile reload failed");
    verifyStore.SaveProfiles(verified);
    var originalJson = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "windows-profiles.json")));
    var returnedJson = JsonNode.Parse(File.ReadAllText(AppPaths.ProfilesFile));
    Require(JsonNode.DeepEquals(originalJson, returnedJson), "Windows → Mac → Windows profile data changed");
    Console.WriteLine("T5 return trip verified by C# production codecs.");
    return;
}

var store = new ProfileStore();
var source = new[] { "server.cjs", "server.mjs", "php" }.Select((entry, index) => new ServerProfile
{
    Name = "Windows → Mac «демо» " + entry, Engine = entry == "php" ? "phpBuiltIn" : "nodeScript",
    RootPath = @"C:\Projects\Демо with spaces", WorkingDirectory = @"C:\Projects\Демо with spaces",
    NodeEntryFile = entry == "php" ? "server.js" : entry, Port = 9100 + index,
    ProfileColor = "#14B8A6", ErrorPageAccent = "#EF4444", ErrorPageFooter = "Український підпис",
    TemplateId = "portable-template", NeedsDatabase = true, DatabaseName = "t5_demo",
    EnableCors = true, EnableGzip = false, ConfigPreset = "spa", SpaFallback = false, DirectoryListing = true,
    BasicAuthEnabled = true, BasicAuthUser = "demo", BasicAuthPassword = "test-only-\"\\пароль",
    PhpVersion = "8.3", PhpMemoryLimit = "768M", PhpUploadMaxFilesize = "256M", PhpMaxExecutionTime = 600,
    PhpDisplayErrors = false, HttpsEnabled = true, CertificatePath = @"C:\certs\demo.pem", PrivateKeyPath = @"C:\certs\demo.key",
    Notes = "Тест\nline\tend", OpenBrowserOnStart = false,
    Environment = [new EnvVar { Key = "MODE", Value = "демо" }, new EnvVar { Key = "EMPTY", Value = "" }]
}).ToArray();
store.SaveProfiles(source);
File.Copy(AppPaths.ProfilesFile, Path.Combine(root, "windows-profiles.json"), true);
// Do not exercise ProfileStore's empty/error fallback: it intentionally creates
// a starter Sites directory. This harness only tests valid, non-empty transfers.
var preflight = JsonSerializer.Deserialize<ServerProfile[]>(File.ReadAllText(Path.Combine(root, "mac-profiles.json")), json);
Require(preflight is { Length: > 0 }, "Supply valid non-empty Mac profiles");
File.Copy(Path.Combine(root, "mac-profiles.json"), AppPaths.ProfilesFile, true);
var loaded = store.LoadProfiles();
using var mac = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "mac-profiles.json")));
Require(loaded.Count == mac.RootElement.GetArrayLength(), "Windows ProfileStore failed to load Mac profiles");
store.SaveProfiles(loaded);
File.Copy(AppPaths.ProfilesFile, Path.Combine(root, "mac-via-windows.json"), true);

var templateStore = new UserTemplateStore(Path.Combine(root, "dotnet-templates/store.json"));
var templates = templateStore.Import(Path.Combine(root, "mac-templates.smtemplate"), Array.Empty<ProfileTemplate>());
UserTemplateStore.Export(templates, Path.Combine(root, "mac-via-windows.smtemplate"));
Write("windows-template-profiles.json", templates.Select(t => t.CreateProfile(@"C:\Templates\Демо", 9200)).ToArray());

var nativeRejection = "";
try { templateStore.Import(Path.Combine(root, "mac-native.smtemplate"), templates); }
catch (InvalidOperationException ex) { nativeRejection = ex.Message; }
Require(nativeRejection.Contains("not available on Windows"), "Native Mac engine must not silently become a different engine");

var incoming = TranslationPacks.Import(Path.Combine(root, "mac-uk.strings"), Path.Combine(root, "packs"));
Require(incoming.Kind == TranslationImportKind.Installed && incoming.Pack != null, "Windows rejected Mac translation pack");
Write("mac-translation-read.json", incoming.Pack!);
Localization.Initialize("uk", packFolder: Path.Combine(root, "packs"));
Require(Localization.T("T5 test") == "Перенесення працює", "Imported override did not reach Windows localization lookup");
TranslationPacks.Export("uk", "2.1.0", Path.Combine(root, "windows-uk.strings"));

var differences = new List<string>();
var beforeTemplates = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "mac-templates.smtemplate")))!.AsArray();
var afterTemplates = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "mac-via-windows.smtemplate")))!.AsArray();
for (var index = 0; index < beforeTemplates.Count; index++)
{
    foreach (var field in beforeTemplates[index]!.AsObject())
        if (field.Key != "settings" && !JsonNode.DeepEquals(field.Value, afterTemplates[index]?[field.Key])) differences.Add($"{index}:{field.Key}");
    foreach (var field in beforeTemplates[index]!["settings"]!.AsObject())
        if (!JsonNode.DeepEquals(field.Value, afterTemplates[index]?["settings"]?[field.Key])) differences.Add($"{index}:settings.{field.Key}");
}
Write("report.json", new { nativeRejection, templateDifferences = differences, profileCount = loaded.Count, translationCount = incoming.Pack!.Strings.Count });
Console.WriteLine("T5 C# production codecs completed.");
