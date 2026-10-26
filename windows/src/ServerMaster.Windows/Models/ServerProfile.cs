using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class ServerProfile : INotifyPropertyChanged, IJsonOnDeserializing, IJsonOnDeserialized
{
    private bool _isDeserializing;
    private string _configPreset = "standard";
    private string _name = "New profile";
    private string _engine = "pythonHTTP";
    private string _host = "127.0.0.1";
    private int _port = 8080;
    private string _rootPath = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "Sites");
    private string _workingDirectory = "";
    private string _customCommand = "";
    private string _customArguments = "";
    private string _extraArguments = "";
    private string _nodeEntryFile = "server.js";
    private bool _openBrowserOnStart;
    private ServerState _state = ServerState.Stopped;
    private string _uptime = "";
    private string? _failure;
    private int? _processId;
    private DateTimeOffset? _startedAt;
    private string _lastCommand = "";
    private string _profileColor = "#3B82F6";
    private string _iconGlyph = "";
    private bool _isDefault;
    private bool _runAsAdministrator;
    private List<EnvVar> _environment = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>Lists without a template name their rows after this; screen readers read the profile name.</summary>
    public override string ToString() => Name;

    public string Name
    {
        get => _name;
        set => SetProperty(ref _name, value);
    }

    public string Engine
    {
        get => _engine;
        set
        {
            value = string.IsNullOrWhiteSpace(value) ? "pythonHTTP" : value;
            if (SetProperty(ref _engine, value))
            {
                if (value == "phpBuiltIn" && PhpVersion.Length == 0) PhpVersion = "8.3";
                NotifyComputed();
            }
        }
    }

    public string IconGlyph
    {
        get => _iconGlyph;
        set
        {
            if (SetProperty(ref _iconGlyph, value ?? "")) OnPropertyChanged(nameof(Symbol));
        }
    }
    public string ProfileColor
    {
        get => _profileColor;
        set => SetProperty(ref _profileColor, string.IsNullOrWhiteSpace(value) ? "#3B82F6" : value);
    }
    public string Host
    {
        get => _host;
        set
        {
            if (SetProperty(ref _host, value))
            {
                NotifyComputed();
            }
        }
    }

    public int Port
    {
        get => _port;
        set
        {
            if (SetProperty(ref _port, value))
            {
                NotifyComputed();
            }
        }
    }

    public string RootPath
    {
        get => _rootPath;
        set
        {
            if (SetProperty(ref _rootPath, value))
            {
                NotifyComputed();
            }
        }
    }

    public string WorkingDirectory
    {
        get => _workingDirectory;
        set
        {
            if (SetProperty(ref _workingDirectory, value))
            {
                NotifyComputed();
            }
        }
    }

    public string ConfigPath { get; set; } = "";
    public string DatabaseName { get; set; } = "";
    private string _phpVersion = "8.3";
    public string PhpVersion { get => _phpVersion; set => SetProperty(ref _phpVersion, string.IsNullOrWhiteSpace(value) ? "8.3" : value); }
    public string TemplateId { get; set; } = "";
    public bool NeedsDatabase { get; set; }
    private bool _httpsEnabled;
    private string _certificatePath = "";
    private string _privateKeyPath = "";
    public bool HttpsEnabled { get => _httpsEnabled; set { if (SetProperty(ref _httpsEnabled, value)) NotifyComputed(); } }
    public string CertificatePath { get => _certificatePath; set => SetProperty(ref _certificatePath, value); }
    public string PrivateKeyPath { get => _privateKeyPath; set => SetProperty(ref _privateKeyPath, value); }
    public bool EnableCors { get; set; }
    public bool EnableGzip { get; set; } = true;
    public bool DirectoryListing { get; set; } = true;
    public bool SpaFallback { get; set; }
    public string ConfigPreset
    {
        get => _configPreset;
        set
        {
            var chosen = string.IsNullOrWhiteSpace(value) ? "standard" : value;
            if (chosen == _configPreset) return;
            _configPreset = chosen;
            if (!_isDeserializing && Engine == "httpServer" && chosen == "spa")
            {
                SpaFallback = true;
                DirectoryListing = false;
            }
            OnPropertyChanged(nameof(ConfigPreset));
            OnPropertyChanged(nameof(SpaFallback));
            OnPropertyChanged(nameof(DirectoryListing));
        }
    }
    public int CacheSeconds { get; set; } = -1;
    public bool BasicAuthEnabled { get; set; }
    public string BasicAuthUser { get; set; } = "";
    public string BasicAuthPassword { get; set; } = "";
    public string IndexFile { get; set; } = "index.html";
    public string NodeEntryFile
    {
        get => _nodeEntryFile;
        set => SetProperty(ref _nodeEntryFile, value);
    }

    public string CustomCommand
    {
        get => _customCommand;
        set => SetProperty(ref _customCommand, value);
    }

    public string CustomArguments
    {
        get => _customArguments;
        set => SetProperty(ref _customArguments, value);
    }

    public bool RunAsAdministrator
    {
        get => _runAsAdministrator;
        set { if (SetProperty(ref _runAsAdministrator, value)) OnPropertyChanged(nameof(AdministratorGlyph)); }
    }
    [JsonIgnore]
    public bool IsDefault
    {
        get => _isDefault;
        set { if (SetProperty(ref _isDefault, value)) OnPropertyChanged(nameof(DefaultGlyph)); }
    }
    [JsonIgnore] public string DefaultGlyph => IsDefault ? "\uE735" : "";
    [JsonIgnore] public string AdministratorGlyph => RunAsAdministrator ? "\uE7EF" : "";
    public bool HideDotfiles { get; set; } = true;
    public bool SecurityHeaders { get; set; }
    public bool HstsEnabled { get; set; }
    public bool CustomErrorPages { get; set; }
    public string ErrorPageAccent { get; set; } = "#3B82F6";
    public string ErrorPageFooter { get; set; } = "";
    public string PhpMemoryLimit { get; set; } = "256M";
    public string PhpUploadMaxFilesize { get; set; } = "64M";
    public int PhpMaxExecutionTime { get; set; } = 300;
    public bool PhpDisplayErrors { get; set; } = true;
    public string ExtraArguments
    {
        get => _extraArguments;
        set => SetProperty(ref _extraArguments, value);
    }

    public List<EnvVar> Environment
    {
        get => _environment;
        set
        {
            if (SetProperty(ref _environment, value ?? [])) OnPropertyChanged(nameof(EnvironmentSummary));
        }
    }
    [JsonIgnore]
    public string EnvironmentSummary
    {
        get
        {
            var source = Environment.Count == 0 ? "No variables" : Environment.Count == 1 ? "1 variable" : $"{Environment.Count} variables";
            return Localization.TryTranslateDynamic(source, out var translated) ? translated : source;
        }
    }
    public bool OpenBrowserOnStart
    {
        get => _openBrowserOnStart;
        set => SetProperty(ref _openBrowserOnStart, value);
    }

    public string Notes { get; set; } = "";

    [JsonIgnore]
    public ServerState State
    {
        get => _state;
        set
        {
            if (SetProperty(ref _state, value))
            {
                OnPropertyChanged(nameof(StateText));
                OnPropertyChanged(nameof(StateTint));
                OnPropertyChanged(nameof(IsRunning));
                OnPropertyChanged(nameof(RunningVisibility));
                OnPropertyChanged(nameof(TransitionText));
                OnPropertyChanged(nameof(IsActive));
                OnPropertyChanged(nameof(IsBusy));
                OnPropertyChanged(nameof(CanToggle));
                OnPropertyChanged(nameof(PrimaryActionText));
                OnPropertyChanged(nameof(PrimaryActionGlyph));
            }
        }
    }

    [JsonIgnore]
    public string Uptime
    {
        get => _uptime;
        set => SetProperty(ref _uptime, value);
    }

    [JsonIgnore]
    public string? Failure
    {
        get => _failure;
        set
        {
            if (SetProperty(ref _failure, value))
            {
                OnPropertyChanged(nameof(HasFailure));
            }
        }
    }

    [JsonIgnore]
    public int? ProcessId
    {
        get => _processId;
        set => SetProperty(ref _processId, value);
    }

    [JsonIgnore]
    public DateTimeOffset? StartedAt
    {
        get => _startedAt;
        set => SetProperty(ref _startedAt, value);
    }

    [JsonIgnore]
    public string LastCommand
    {
        get => _lastCommand;
        set => SetProperty(ref _lastCommand, value);
    }

    public string EngineTitle => Engine switch
    {
        "httpServer" => "http-server (Node.js)",
        "nodeScript" => "Node.js script",
        "pythonHTTP" => "Python http.server",
        "phpBuiltIn" => "PHP built-in server",
        "nginx" => "Nginx",
        "phpFpm" => "PHP site (Nginx + PHP-FPM)",
        "apache" => "Apache",
        "apachePHP" => "PHP site (Apache + PHP-FPM)",
        "caddy" => "Caddy",
        "custom" => "Custom command",
        _ => Engine
    };

    public string Symbol => string.IsNullOrWhiteSpace(IconGlyph) ? EngineSymbol(Engine) : IconGlyph;

    /// <summary>The engine's own icon, used when the profile has none of its own.</summary>
    public static string EngineSymbol(string engine) => engine switch
    {
        "httpServer" or "nodeScript" => "\uE7B8",
        "pythonHTTP" or "phpBuiltIn" => "\uE943",
        "nginx" => "\uE968",
        "phpFpm" => "\uE80F",
        "apache" or "apachePHP" => "\uE825",
        "caddy" => "\uE72E",
        "custom" => "\uE756",
        _ => "\uE71B"
    };

    public string DisplayHost => string.IsNullOrWhiteSpace(Host) || Host == "0.0.0.0" ? "127.0.0.1" : Host == "::" ? "[::1]" : Host.Contains(':') && !Host.StartsWith('[') ? "[" + Host + "]" : Host;
    public string Scheme => HttpsEnabled && SupportsHttps ? "https" : "http";
    public string Address => $"{Scheme}://{DisplayHost}:{Port}";
    public string ExpandedRootPath => AppPaths.Expand(RootPath);
    public string EffectiveWorkingDirectory => string.IsNullOrWhiteSpace(WorkingDirectory) ? ExpandedRootPath : AppPaths.Expand(WorkingDirectory);
    public bool UsesRootDirectory => Engine != "custom";
    public bool SupportsHttps => Engine is "httpServer" or "nodeScript" or "pythonHTTP" or "phpBuiltIn";
    public bool IsRunning => State == ServerState.Running;
    /// <summary>Like the Mac row: Open and Restart appear only while the server runs.</summary>
    public Microsoft.UI.Xaml.Visibility RunningVisibility => IsRunning ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
    /// <summary>The state in words only when the dot and uptime do not already say it.</summary>
    public string TransitionText => State is ServerState.Stopped or ServerState.Running ? "" : StateText;
    public bool IsActive => State is ServerState.Running or ServerState.Starting;
    public bool IsBusy => State is ServerState.Starting or ServerState.Stopping;
    [JsonIgnore] public bool CanToggle => State != ServerState.Stopping;
    public bool HasFailure => !string.IsNullOrWhiteSpace(Failure);
    [JsonIgnore]
    public string StateTint => State switch
    {
        ServerState.Running => "#32B875",
        ServerState.Starting or ServerState.Stopping => "#E7BD57",
        ServerState.Failed => "#E66A72",
        _ => "#A6AAB4"
    };
    public string StateText => Localization.T(State switch
    {
        ServerState.Stopped => "Stopped",
        ServerState.Starting => "Starting...",
        ServerState.Running => "Running",
        ServerState.Stopping => "Stopping...",
        ServerState.Failed => "Error",
        _ => State.ToString()
    });
    public string PrimaryActionText => Localization.T(IsActive ? "Stop" : "Start");
    /// <summary>Segoe Fluent Stop or Play, as the Mac Start/Stop buttons carry stop.fill / play.fill.</summary>
    public string PrimaryActionGlyph => IsActive ? "\uE71A" : "\uE768";

    public IReadOnlyList<string> ValidationIssues()
    {
        var issues = new List<string>();
        if (string.IsNullOrWhiteSpace(Name))
        {
            issues.Add("Empty profile name.");
        }

        if (Port is < 1 or > 65535)
        {
            issues.Add("The port must be between 1 and 65535.");
        }

        if (UsesRootDirectory)
        {
            if (string.IsNullOrWhiteSpace(ExpandedRootPath))
            {
                issues.Add("No root directory specified.");
            }
            else if (!Directory.Exists(ExpandedRootPath))
            {
                issues.Add($"Directory does not exist: {ExpandedRootPath}");
            }
        }

        if (Engine == "custom" && string.IsNullOrWhiteSpace(CustomCommand))
        {
            issues.Add("No launch command specified.");
        }

        if (Engine == "phpBuiltIn")
        {
            if (!Dependency.PhpBranches.Contains(PhpVersion)) issues.Add("Choose a supported PHP version in the profile.");
            else if (TemplateId == "joomla6" && Version.Parse(PhpVersion) < new Version(8, 3))
                issues.Add("Joomla 6 requires PHP 8.3 or newer. Select another PHP version in this profile.");
            if (!IsValidPhpSize(PhpMemoryLimit)) issues.Add("PHP memory limit must be a number with optional K, M or G suffix, or -1.");
            if (!IsValidPhpSize(PhpUploadMaxFilesize)) issues.Add("PHP upload limit must be a number with optional K, M or G suffix.");
            if (PhpMaxExecutionTime is < 1 or > 86400) issues.Add("PHP execution time must be between 1 and 86400 seconds.");
        }

        if (Engine == "httpServer" && CacheSeconds < -1) issues.Add("Cache time must be -1 or more seconds.");
        if (Engine == "httpServer" && BasicAuthEnabled &&
            (string.IsNullOrWhiteSpace(BasicAuthUser) || string.IsNullOrEmpty(BasicAuthPassword)))
            issues.Add("Basic authentication needs a login and password.");

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var variable in Environment)
        {
            if (!IsValidEnvironmentKey(variable.Key)) issues.Add($"Invalid environment variable name: {variable.Key}");
            else if (!names.Add(variable.Key)) issues.Add($"Duplicate environment variable: {variable.Key}");
        }

        return issues;
    }

    public Dictionary<string, string> EnvironmentDictionary()
    {
        var issues = ValidationIssues().Where(issue => issue.StartsWith("Invalid environment variable", StringComparison.Ordinal) ||
            issue.StartsWith("Duplicate environment variable", StringComparison.Ordinal)).ToList();
        if (issues.Count > 0) throw new InvalidOperationException(string.Join(" ", issues));
        return Environment
            .ToDictionary(item => item.Key, item => item.Value, StringComparer.OrdinalIgnoreCase);
    }

    public static bool IsValidEnvironmentKey(string? key) =>
        !string.IsNullOrEmpty(key) && (char.IsAsciiLetter(key[0]) || key[0] == '_') &&
        key.Skip(1).All(character => char.IsAsciiLetterOrDigit(character) || character == '_');

    public static bool IsValidPhpSize(string? value) =>
        value == "-1" || (!string.IsNullOrWhiteSpace(value) &&
        System.Text.RegularExpressions.Regex.IsMatch(value.Trim(), @"^\d{1,9}[KMG]?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase));

    public void OnDeserializing() => _isDeserializing = true;
    public void OnDeserialized() => _isDeserializing = false;

    private bool SetProperty<T>(ref T storage, T value, [CallerMemberName] string propertyName = "")
    {
        if (EqualityComparer<T>.Default.Equals(storage, value))
        {
            return false;
        }

        storage = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string propertyName = "")
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private void NotifyComputed()
    {
        OnPropertyChanged(nameof(EngineTitle));
        OnPropertyChanged(nameof(Symbol));
        OnPropertyChanged(nameof(DisplayHost));
        OnPropertyChanged(nameof(Scheme));
        OnPropertyChanged(nameof(Address));
        OnPropertyChanged(nameof(ExpandedRootPath));
        OnPropertyChanged(nameof(EffectiveWorkingDirectory));
        OnPropertyChanged(nameof(UsesRootDirectory));
        OnPropertyChanged(nameof(SupportsHttps));
    }
}
