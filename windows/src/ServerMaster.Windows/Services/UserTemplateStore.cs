using System.Text.Json;
using ServerMaster.Windows.Models;

namespace ServerMaster.Windows.Services;

public sealed class UserTemplateStore
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
    private static readonly HashSet<string> Engines = ["httpServer", "nodeScript", "pythonHTTP", "phpBuiltIn", "custom"];
    private readonly string _path;
    private readonly List<ProfileTemplate> _userTemplates = [];

    public UserTemplateStore(string path) => _path = path;
    public IReadOnlyList<ProfileTemplate> UserTemplates => _userTemplates;
    public bool LoadFailed { get; private set; }

    public void Load(IEnumerable<ProfileTemplate> builtIn)
    {
        if (!File.Exists(_path)) return;
        try
        {
            var imported = Read(File.ReadAllText(_path), builtIn.Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase));
            _userTemplates.Clear();
            _userTemplates.AddRange(imported);
            LoadFailed = false;
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException)
        {
            LoadFailed = true;
        }
    }

    public IReadOnlyList<ProfileTemplate> Import(string path, IEnumerable<ProfileTemplate> existing)
    {
        if (new FileInfo(path).Length > 1024 * 1024)
            throw new InvalidOperationException("Template file is too large.");
        var imported = Read(File.ReadAllText(path), existing.Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase));
        _userTemplates.AddRange(imported);
        Save();
        return imported;
    }

    public void Remove(ProfileTemplate template)
    {
        if (!template.IsUserDefined) return;
        _userTemplates.RemoveAll(item => item.Id == template.Id);
        Save();
    }

    public static void Export(IEnumerable<ProfileTemplate> templates, string path)
    {
        var files = templates.Select(ToFile).ToArray();
        if (files.Length == 0) throw new InvalidOperationException("Choose a template to export.");
        File.WriteAllText(path, JsonSerializer.Serialize(files, Json));
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var partial = _path + ".partial";
        try
        {
            File.WriteAllText(partial, JsonSerializer.Serialize(_userTemplates.Select(ToFile).ToArray(), Json));
            File.Move(partial, _path, true);
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
    }

    private static IReadOnlyList<ProfileTemplate> Read(string json, HashSet<string> ids)
    {
        using var document = JsonDocument.Parse(json);
        var elements = document.RootElement.ValueKind switch
        {
            JsonValueKind.Array => document.RootElement.EnumerateArray().ToArray(),
            JsonValueKind.Object => [document.RootElement],
            _ => throw new InvalidOperationException("This file does not contain a ServerMaster template.")
        };
        if (elements.Length == 0) throw new InvalidOperationException("This file contains no templates.");
        var result = new List<ProfileTemplate>();
        foreach (var element in elements)
        {
            var file = element.Deserialize<TemplateFile>(Json)
                ?? throw new InvalidOperationException("A template could not be read.");
            if (file.Settings is null || file.Questions is null || file.Summary is null ||
                string.IsNullOrWhiteSpace(file.Title) || file.Title.Length > 100 || file.Summary.Length > 400 ||
                string.IsNullOrWhiteSpace(file.Id) || file.Id.Length > 80 ||
                file.Id.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '_' or '-')))
                throw new InvalidOperationException("A template has an invalid name or identifier.");
            if (!Engines.Contains(file.Settings.Engine))
                throw new InvalidOperationException($"The {file.Settings.Engine} engine is not available on Windows.");
            var id = file.Id;
            while (!ids.Add(id)) id = file.Id + "." + Guid.NewGuid().ToString("N")[..4];
            result.Add(new ProfileTemplate
            {
                Id = id, Title = file.Title, Summary = file.Summary,
                Category = file.Category switch
                {
                    "sites" => "Sites and pages", "cms" => "Content management",
                    "frameworks" => "Frameworks", "runtimes" => "Runtimes and tools",
                    "custom" => "Your own", _ => "Your own"
                },
                Engine = file.Settings.Engine, RootHint = file.RootHint ?? "",
                FolderAdvice = file.FolderAdvice ?? "", NeedsDatabase = file.NeedsDatabase,
                PhpVersion = file.PhpVersion, IndexFile = file.Settings.IndexFile,
                DirectoryListing = file.Settings.DirectoryListing, SpaFallback = file.Settings.SpaFallback,
                HideDotfiles = file.Settings.HideDotfiles, SecurityHeaders = file.Settings.SecurityHeaders,
                CustomErrorPages = file.Settings.CustomErrorPages, CacheSeconds = file.Settings.CacheSeconds,
                PhpMemoryLimit = file.Settings.PhpMemoryLimit,
                PhpUploadMaxFilesize = file.Settings.PhpUploadMaxFilesize,
                PhpMaxExecutionTime = file.Settings.PhpMaxExecutionTime,
                Questions = file.Questions, IsUserDefined = true,
                NodeEntryFile = file.NodeEntryFile ?? "server.js",
                CustomCommand = file.CustomCommand ?? "", CustomArguments = file.CustomArguments ?? "",
                PackageKind = file.PackageKind ?? "", PackageSource = file.PackageSource ?? "",
                RecipeKind = file.RecipeKind ?? "", PluginPackages = file.PluginPackages ?? []
            });
        }
        return result;
    }

    private static TemplateFile ToFile(ProfileTemplate template) => new()
    {
        Id = template.Id, Title = template.Title, Summary = template.Summary,
        Symbol = "square.grid.2x2", Category = template.Category switch
        {
            "Sites and pages" => "sites", "Content management" => "cms",
            "Frameworks" => "frameworks", "Runtimes and tools" => "runtimes", _ => "custom"
        },
        GuideAnchor = "index", RootHint = string.IsNullOrEmpty(template.RootHint) ? null : template.RootHint,
        FolderAdvice = template.FolderAdvice, NeedsDatabase = template.NeedsDatabase,
        PhpVersion = template.PhpVersion,
        NodeEntryFile = template.NodeEntryFile,
        CustomCommand = template.CustomCommand, CustomArguments = template.CustomArguments,
        PackageKind = template.PackageKind, PackageSource = template.PackageSource,
        RecipeKind = template.RecipeKind, PluginPackages = template.PluginPackages,
        Questions = template.Questions.Length > 0 ? template.Questions :
            ["folder", "name", "port", ..(template.NeedsDatabase ? new[] { "database" } : []),
             ..(template.Engine == "phpBuiltIn" ? new[] { "phpVersion" } : []),
             ..(template.Engine == "nodeScript" ? new[] { "entryFile" } : []),
             ..(template.Engine == "custom" ? new[] { "command" } : []),
             ..(template.Id == "static-https" ? new[] { "https" } : [])],
        Settings = new TemplateSettings
        {
            Engine = template.Engine, IndexFile = template.IndexFile,
            DirectoryListing = template.DirectoryListing, SpaFallback = template.SpaFallback,
            HideDotfiles = template.HideDotfiles, SecurityHeaders = template.SecurityHeaders,
            CustomErrorPages = template.CustomErrorPages, CacheSeconds = template.CacheSeconds,
            PhpMemoryLimit = template.PhpMemoryLimit, PhpUploadMaxFilesize = template.PhpUploadMaxFilesize,
            PhpMaxExecutionTime = template.PhpMaxExecutionTime
        }
    };

    private sealed class TemplateFile
    {
        public string Id { get; set; } = "";
        public string Title { get; set; } = "";
        public string Summary { get; set; } = "";
        public string Symbol { get; set; } = "square.grid.2x2";
        public string Category { get; set; } = "custom";
        public string GuideAnchor { get; set; } = "index";
        public string? RootHint { get; set; }
        public string? FolderAdvice { get; set; }
        public bool NeedsDatabase { get; set; }
        public string PhpVersion { get; set; } = "";
        public string[] Questions { get; set; } = [];
        public TemplateSettings Settings { get; set; } = new();
        public bool IsUserDefined { get; set; }
        public string? PackageKind { get; set; }
        public string? PackageSource { get; set; }
        public string? RecipeKind { get; set; }
        public string[]? PluginPackages { get; set; }
        public string? NodeEntryFile { get; set; }
        public string? CustomCommand { get; set; }
        public string? CustomArguments { get; set; }
    }

    private sealed class TemplateSettings
    {
        public string Engine { get; set; } = "httpServer";
        public string IndexFile { get; set; } = "index.html";
        public bool DirectoryListing { get; set; } = true;
        public bool SpaFallback { get; set; }
        public bool HideDotfiles { get; set; } = true;
        public bool SecurityHeaders { get; set; }
        public bool CustomErrorPages { get; set; }
        public int CacheSeconds { get; set; } = -1;
        public string PhpMemoryLimit { get; set; } = "256M";
        public string PhpUploadMaxFilesize { get; set; } = "64M";
        public int PhpMaxExecutionTime { get; set; } = 300;
        public string? IconName { get; set; }
    }
}
