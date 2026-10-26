using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO.Compression;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Net;
using System.Net.Sockets;
using System.Windows.Input;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using Windows.ApplicationModel.DataTransfer;

namespace ServerMaster.Windows.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly DispatcherQueue _dispatcher;
    private readonly ProfileStore _store = new();
    private readonly DependencyManager _dependencyManager;
    private readonly UpdateChecker _updateChecker = new();
    private readonly TemplateDownloadService _templateDownloadService = new();
    private readonly UserTemplateStore _userTemplateStore = new(Path.Combine(AppPaths.Support, "templates.json"));
    private readonly Dictionary<Guid, ServerController> _controllers = [];
    private readonly CrashRecovery _crashRecovery = new();
    private bool _shuttingDown;
    private bool _logCleanupBusy;
    private DateTimeOffset _lastLogCleanup;
    private readonly PortReserver _portReserver = new();
    private IReadOnlyList<PortEntry> _allPortEntries = [];
    private DateTime _lastPortRefresh = DateTime.MinValue;
    private readonly SolidColorBrush _green = new(Colors.LimeGreen);
    private readonly SolidColorBrush _red = new(Colors.IndianRed);
    private readonly SolidColorBrush _orange = new(Colors.Orange);
    private readonly SolidColorBrush _muted = new(ColorHelper.FromArgb(255, 166, 170, 180));
    private readonly DispatcherQueueTimer _uptimeTimer;
    private AppSettings _settings;
    private string _selectedSection = "Control";
    private ServerProfile? _selectedProfile;
    private Guid? _filesProfileId;
    private bool _isBannerOpen;
    private string _bannerText = "";
    private InfoBarSeverity _bannerSeverity;
    private bool _dependenciesLoaded;
    private bool _diagnosticsLoaded;
    private bool _portsLoaded;
    private int _profileCheckVersion;
    private string _shellKind = "PowerShell";
    private string _shellCommandText = "";
    private bool _shellBusy;
    private CancellationTokenSource? _shellCancellation;
    private Process? _shellProcess;
    private ConsoleTab? _selectedConsoleTab;
    private string _filesPath = "";
    private string _filesRoot = "";
    private string _filesProblem = "";
    private string _portsProblem = "";
    private string _databaseProblem = "";
    private string _backupProblem = "";
    private string _newPathEntry = "";
    private string _newDatabaseName = "";
    private string _newDatabaseUser = "smuser";
    private string _newDatabasePassword = "smpass";
    private bool _databaseLogExpanded = true;
    private bool _showAllFiles;
    private bool _scheduledBackupCheckBusy;
    private DateTime _lastScheduledBackupCheck;
    private string _backgroundProfileColor = "";
    private DatabaseEntry? _selectedDatabase;
    private string _databaseSql = "SELECT * FROM `table_name` LIMIT 100;";
    private string _databaseQueryOutput = "Select a database and run a query.";
    private bool _updateChecking;
    private string _updateStatus = "Not checked yet.";
    private string _updateReleaseUrl = "";
    private string _availableUpdateVersion = "";
    private string _availableUpdateBuildPath = "";
    public InfoBarSeverity BannerSeverity { get => _bannerSeverity; private set => SetProperty(ref _bannerSeverity, value); }

    public MainViewModel(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _dependencyManager = new DependencyManager(dispatcher);
        NeedsFirstSetup = !File.Exists(AppPaths.SettingsFile) && !File.Exists(AppPaths.ProfilesFile);
        _settings = _store.LoadSettings();
        _settings.DatabaseAdminTool = _settings.DatabaseAdminTool == "phpmyadmin" ? "phpmyadmin" : "adminer";
        AdminerService.SetPort(_settings.DatabaseAdminPort);
        AdminerService.SetTool(_settings.DatabaseAdminTool);
        _selectedSection = SettingsBehavior.StartupSection(_settings);
        foreach (var path in _settings.ExtraPathEntries) ExtraPathEntries.Add(path);
        ShellEnvironment.Shared.SetExtraEntries(_settings.ExtraPathEntries);

        foreach (var profile in _store.LoadProfiles())
        {
            if (profile.Engine == "phpBuiltIn" && string.IsNullOrWhiteSpace(profile.PhpVersion)) profile.PhpVersion = "8.3";
            if (profile.Notes == "A database is required for this project.") profile.NeedsDatabase = true;
            profile.PropertyChanged += Profile_PropertyChanged;
            Profiles.Add(profile);
        }

        foreach (var template in ProfileTemplate.BuiltIn)
        {
            ProfileTemplates.Add(template);
        }
        _userTemplateStore.Load(ProfileTemplate.BuiltIn);
        foreach (var template in _userTemplateStore.UserTemplates) ProfileTemplates.Add(template);

        SelectedTemplate = ProfileTemplates.FirstOrDefault();

        foreach (var dependency in Dependency.Catalog.Where(item => item.Command != "php").Concat(Dependency.PhpPackages))
        {
            Dependencies.Add(new DependencyStatus { Dependency = dependency });
        }
        foreach (var status in Dependencies) status.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(SelectedProfileSetupMessage));
            OnPropertyChanged(nameof(SelectedProfilePrepareVisibility));
            OnPropertyChanged(nameof(SelectedProfilePhpStatus));
            OnPropertyChanged(nameof(SelectedProfilePhpInstallVisibility));
            OnPropertyChanged(nameof(DatabaseStatus));
            OnPropertyChanged(nameof(DatabaseCanStart));
            OnPropertyChanged(nameof(DatabaseCanStop));
            OnPropertyChanged(nameof(DatabaseCanInstall));
            OnPropertyChanged(nameof(CanResetSettings));
            NotifyDependencyScreenState();
            NotifyControlDetails();
        };
        Profiles.CollectionChanged += (_, _) =>
        {
            UpdateDependencyUsage();
            OnPropertyChanged(nameof(FilesProfile));
            OnPropertyChanged(nameof(FilesProfileName));
            if (SelectedSection == "Files") RefreshFiles();
            NotifyBackupState();
            RefreshDefaultMarks();
            OnPropertyChanged(nameof(ControlProfilesEmptyVisibility));
            OnPropertyChanged(nameof(ProfilesEmptyVisibility));
            OnPropertyChanged(nameof(ProfilesEditorVisibility));
            OnPropertyChanged(nameof(TraceProfilesEmptyVisibility));
        };
        DatabaseEntries.CollectionChanged += (_, _) =>
        {
            NotifyBackupState();
            OnPropertyChanged(nameof(DatabaseEntriesEmptyVisibility));
        };
        DiagnosticFindings.CollectionChanged += (_, _) => NotifyDiagnosticResults();
        UpdateDependencyUsage();
        RefreshDefaultMarks();

        var startupProfile = SettingsBehavior.StartupProfile(_settings, Profiles.Select(profile => profile.Id));
        SelectedProfile = Profiles.FirstOrDefault(profile => profile.Id == startupProfile);
        RefreshConsoleTabs();

        ShowConsoleCommand = new RelayCommand(_ => SelectSection("Console"));
        ShowProfilesCommand = new RelayCommand(_ => SelectSection("Profiles"));
        ShowControlCommand = new RelayCommand(_ => SelectSection("Control"));
        StartStopProfileCommand = new RelayCommand(async parameter => await StartStopProfileAsync(parameter as ServerProfile ?? SelectedProfile));
        RestartProfileCommand = new RelayCommand(async parameter => await RestartProfileAsync(parameter as ServerProfile ?? SelectedProfile));
        OpenProfileCommand = new RelayCommand(parameter => OpenProfile(parameter as ServerProfile ?? SelectedProfile));
        OpenAllProfilesCommand = new RelayCommand(async _ => await OpenAllProfilesAsync());
        OpenSelectedRootCommand = new RelayCommand(_ => OpenSelectedRoot());
        CopyAddressesCommand = new RelayCommand(_ => CopyAddresses());
        HealthCheckCommand = new RelayCommand(async _ => await HealthCheckAsync());
        ClearHealthCheckCommand = new RelayCommand(_ => ClearHealthCheck());
        StopAllCommand = new RelayCommand(async _ => await StopAllAsync());
        DuplicateProfileCommand = new RelayCommand(_ => DuplicateProfile());
        DeleteProfileCommand = new RelayCommand(async _ => await DeleteProfileAsync());
        SaveProfilesCommand = new RelayCommand(_ => SaveProfiles());
        MakeDefaultProfileCommand = new RelayCommand(_ => MakeDefaultProfile());
        CreateStarterFileCommand = new RelayCommand(parameter => CreateStarterFile(parameter as StarterTemplate));
        CheckDependenciesCommand = new RelayCommand(async _ => await CheckDependenciesAsync());
        InstallOrRemoveDependencyCommand = new RelayCommand(async parameter => await InstallOrRemoveDependencyAsync(parameter as DependencyStatus));
        PrepareProfileCommand = new RelayCommand(async _ => await PrepareSelectedProfileAsync());
        RunDiagnosticsCommand = new RelayCommand(async _ => await RunDiagnosticsAsync());
        CopyDiagnosticsCommand = new RelayCommand(_ => CopyDiagnostics());
        ShowDependenciesCommand = new RelayCommand(_ => SelectSection("Dependencies"));
        RefreshPortsCommand = new RelayCommand(async _ => await RefreshPortsAsync());
        ReservePortCommand = new RelayCommand(async _ => await ReservePortAsync());
        ReleasePortCommand = new RelayCommand(async parameter => await ReleasePortAsync(parameter as PortReservation));
        OpenPortCommand = new RelayCommand(parameter => OpenPort(parameter as PortEntry));
        TerminatePortCommand = new RelayCommand(async parameter => await TerminatePortAsync(parameter as PortEntry));
        PortDetailsCommand = new RelayCommand(async parameter => await ShowPortDetailsAsync(parameter as PortEntry));
        InstallDatabaseCommand = new RelayCommand(async _ => await InstallDatabaseAsync());
        StartDatabaseCommand = new RelayCommand(async _ => await StartDatabaseAsync());
        StopDatabaseCommand = new RelayCommand(async _ => await StopDatabaseAsync());
        RefreshDatabaseCommand = new RelayCommand(async _ => await RefreshDatabaseAsync());
        CreateDatabaseCommand = new RelayCommand(async _ => await CreateDatabaseAsync());
        DeleteDatabaseCommand = new RelayCommand(async parameter => await DeleteDatabaseAsync(parameter as DatabaseEntry));
        CopyDatabaseValueCommand = new RelayCommand(parameter => CopyText(parameter as string));
        ClearDatabaseLogCommand = new RelayCommand(_ => DatabaseLogLines.Clear());
        ToggleDatabaseLogCommand = new RelayCommand(_ => DatabaseLogExpanded = !DatabaseLogExpanded);
        OpenDatabaseAdminCommand = new RelayCommand(async _ => await OpenDatabaseAdminAsync());
        StopDatabaseAdminCommand = new RelayCommand(_ => StopDatabaseAdmin());
        ShowBackupsCommand = new RelayCommand(_ => SelectSection("Backups"));
        OpenDatabaseBrowserCommand = new RelayCommand(async parameter => await OpenDatabaseBrowserAsync(parameter as DatabaseEntry));
        OpenDatabaseStructureCommand = new RelayCommand(async parameter => await OpenDatabaseBrowserAsync(parameter as DatabaseEntry, true));
        OpenDatabaseAccountsCommand = new RelayCommand(async parameter => await OpenDatabaseAccountsAsync(parameter as DatabaseEntry));
        CloseDatabaseBrowserCommand = new RelayCommand(_ => SelectedDatabase = null);
        RunDatabaseQueryCommand = new RelayCommand(async _ => await RunDatabaseQueryAsync());
        RunShellCommand = new RelayCommand(async _ => await RunShellCommandAsync());
        StopShellCommand = new RelayCommand(_ =>
        {
            if (SelectedConsoleTab?.Session is { } session) session.Stop();
        });
        ClearShellCommand = new RelayCommand(_ => { if (SelectedConsoleTab is { } tab) tab.TerminalText = "> "; });
        NewTerminalTabCommand = new RelayCommand(_ => SelectConsoleTab(NewTerminalTab()));
        SelectConsoleTabCommand = new RelayCommand(parameter =>
        {
            if (parameter is ConsoleTab tab) SelectConsoleTab(tab);
        });
        CloseConsoleTabCommand = new RelayCommand(parameter => CloseConsoleTab(parameter as ConsoleTab));
        OpenUrlCommand = new RelayCommand(parameter => OpenUrl(parameter as string));
        NotifyPlaceholderCommand = new RelayCommand(parameter => Notify($"{parameter} is not wired on Windows yet."));
        QuitCommand = new RelayCommand(_ => (SelectedWindow as MainWindow)?.RequestQuit());
        RefreshFilesCommand = new RelayCommand(_ => RefreshFiles());
        OpenFilesFolderCommand = new RelayCommand(_ => OpenFilesFolder());
        GoUpFilesCommand = new RelayCommand(_ => GoUpFiles());
        OpenFileCommand = new RelayCommand(parameter => OpenFile(parameter as FileEntry));
        ToggleAllFilesCommand = new RelayCommand(_ => ShowAllFiles = !ShowAllFiles);
        CreateBackupCommand = new RelayCommand(async parameter => { await CreateBackupsAsync(parameter is ServerProfile profile ? new[] { profile } : SelectedProfile is { } selected ? new[] { selected } : Array.Empty<ServerProfile>()); });
        CreateAllBackupsCommand = new RelayCommand(async _ => { await CreateBackupsAsync(Profiles.ToArray()); });
        CreateDatabaseBackupCommand = new RelayCommand(async parameter => await CreateDatabaseBackupAsync((parameter as DatabaseEntry)?.Name));
        DeleteBackupCommand = new RelayCommand(parameter => DeleteBackup(parameter as BackupEntry));
        OpenBackupsFolderCommand = new RelayCommand(_ => OpenBackupsFolder());
        SaveSettingsCommand = new RelayCommand(_ => SaveSettings());
        AddPathEntryCommand = new RelayCommand(_ => AddPathEntry());
        RemovePathEntryCommand = new RelayCommand(parameter => RemovePathEntry(parameter as string));
        RemoveTranslationPackCommand = new RelayCommand(parameter => RemoveTranslationPack(parameter as TranslationPack));
        RefreshTranslationPacks();

        _uptimeTimer = dispatcher.CreateTimer();
        _uptimeTimer.Interval = TimeSpan.FromSeconds(1);
        _uptimeTimer.Tick += async (_, _) =>
        {
            RefreshRuntimeState();
            if (DateTimeOffset.UtcNow - _lastLogCleanup >= TimeSpan.FromDays(1)) await CleanOldLogsAsync();
            if (SelectedSection == "Ports" && PortsAutoRefresh && !PortsScanning &&
                DateTime.UtcNow - _lastPortRefresh >= TimeSpan.FromSeconds(PortsRefreshInterval))
                await RefreshPortsAsync();
            if (DateTime.UtcNow - _lastScheduledBackupCheck >= TimeSpan.FromSeconds(30))
            {
                _lastScheduledBackupCheck = DateTime.UtcNow;
                await CheckScheduledBackupsAsync();
            }
        };
        _uptimeTimer.Start();

        var terminal = NewTerminalTab(_settings.DefaultTerminalShell);
        SelectedConsoleTab = terminal;

        RefreshMetrics();
        RefreshFiles();
        RefreshBackups();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<ServerProfile> Profiles { get; } = [];
    public ObservableCollection<MetricItem> Metrics { get; } = [];
    public ObservableCollection<ProfileTemplate> ProfileTemplates { get; } = [];
    public bool TemplatesLoadFailed => _userTemplateStore.LoadFailed;

    public IReadOnlyList<ProfileTemplate> ImportProfileTemplates(string path)
    {
        var imported = _userTemplateStore.Import(path, ProfileTemplates);
        foreach (var template in imported) ProfileTemplates.Add(template);
        return imported;
    }

    public void ExportProfileTemplates(IEnumerable<ProfileTemplate> templates, string path)
        => UserTemplateStore.Export(templates, path);

    public void RemoveUserTemplate(ProfileTemplate template)
    {
        if (!template.IsUserDefined) return;
        _userTemplateStore.Remove(template);
        ProfileTemplates.Remove(template);
        if (SelectedTemplate == template) SelectedTemplate = ProfileTemplates.FirstOrDefault();
    }
    public ObservableCollection<StarterTemplate> StarterTemplates { get; } = [];
    public ObservableCollection<DependencyStatus> Dependencies { get; } = [];
    public bool DependenciesBusy => Dependencies.Any(status => status.Busy || status.Checking);
    public bool CanCheckDependencies => !DependenciesBusy;
    public Visibility DependenciesProgressVisibility => DependenciesBusy ? Visibility.Visible : Visibility.Collapsed;
    public IReadOnlyList<EngineOption> PhpVersionOptions { get; } = Dependency.PhpBranches.Select(branch => new EngineOption { Id = branch, Title = "PHP " + branch, Subtitle = "" }).ToList();
    public IReadOnlyList<ColorOption> ProfileColors { get; } =
    [
        new() { Id = "#3B82F6", Title = "Blue" }, new() { Id = "#22C55E", Title = "Green" },
        new() { Id = "#F59E0B", Title = "Amber" }, new() { Id = "#EF4444", Title = "Red" },
        new() { Id = "#A855F7", Title = "Purple" }, new() { Id = "#14B8A6", Title = "Teal" },
        new() { Id = "#F97316", Title = "Orange" }, new() { Id = "#94A3B8", Title = "Slate" }
    ];
    public ObservableCollection<LogLine> DependencyLogLines { get; } = [];
    public ObservableCollection<EngineOption> EngineOptions { get; } =
    [
        new EngineOption { Id = "pythonHTTP", Title = "Python http.server", Subtitle = "Quick static serving" },
        new EngineOption { Id = "httpServer", Title = "http-server (Node.js)", Subtitle = "Static files with useful flags" },
        new EngineOption { Id = "nodeScript", Title = "Node.js script", Subtitle = "Run server.js or another Node entry" },
        new EngineOption { Id = "phpBuiltIn", Title = "PHP built-in server", Subtitle = "PHP -S for local projects" },
        new EngineOption { Id = "custom", Title = "Custom command", Subtitle = "Run any executable with arguments" }
    ];
    public ObservableCollection<LogLine> EmptyLogLines { get; } = [];
    // The Console shows the log of its own tab's server, independent of the profile selected
    // elsewhere, as on macOS.
    public ObservableCollection<LogLine> ConsoleLines => ConsoleController?.Log.Lines ?? EmptyLogLines;
    private ServerController? ConsoleController =>
        SelectedConsoleTab?.ProfileId is Guid id && _controllers.TryGetValue(id, out var controller) ? controller : null;

    public ICommand ShowConsoleCommand { get; }
    public ICommand ShowProfilesCommand { get; }
    public ICommand ShowControlCommand { get; }
    public ICommand StartStopProfileCommand { get; }
    public ICommand RestartProfileCommand { get; }
    public ICommand OpenProfileCommand { get; }
    public ICommand OpenAllProfilesCommand { get; }
    public ICommand OpenSelectedRootCommand { get; }
    public ICommand CopyAddressesCommand { get; }
    public ICommand HealthCheckCommand { get; }
    public ICommand ClearHealthCheckCommand { get; }
    public ICommand StopAllCommand { get; }
    public ICommand DuplicateProfileCommand { get; }
    public ICommand DeleteProfileCommand { get; }
    public ICommand SaveProfilesCommand { get; }
    public ICommand MakeDefaultProfileCommand { get; }
    public ICommand CreateStarterFileCommand { get; }
    public ICommand CheckDependenciesCommand { get; }
    public ICommand InstallOrRemoveDependencyCommand { get; }
    public ICommand PrepareProfileCommand { get; }
    public ICommand NotifyPlaceholderCommand { get; }
    public ICommand RunDiagnosticsCommand { get; }
    public ICommand CopyDiagnosticsCommand { get; }
    public ICommand ShowDependenciesCommand { get; }
    public ICommand RefreshPortsCommand { get; }
    public ICommand ReservePortCommand { get; }
    public ICommand ReleasePortCommand { get; }
    public ICommand OpenPortCommand { get; }
    public ICommand TerminatePortCommand { get; }
    public ICommand PortDetailsCommand { get; }
    public ICommand InstallDatabaseCommand { get; }
    public ICommand StartDatabaseCommand { get; }
    public ICommand StopDatabaseCommand { get; }
    public ICommand RefreshDatabaseCommand { get; }
    public ICommand CreateDatabaseCommand { get; }
    public ICommand DeleteDatabaseCommand { get; }
    public ICommand CopyDatabaseValueCommand { get; }
    public ICommand ClearDatabaseLogCommand { get; }
    public ICommand ToggleDatabaseLogCommand { get; }
    public ICommand OpenDatabaseAdminCommand { get; }
    public ICommand StopDatabaseAdminCommand { get; }
    public ICommand ShowBackupsCommand { get; }
    public ICommand OpenDatabaseBrowserCommand { get; }
    public ICommand OpenDatabaseStructureCommand { get; }
    public ICommand OpenDatabaseAccountsCommand { get; }
    public ICommand CloseDatabaseBrowserCommand { get; }
    public ICommand RunDatabaseQueryCommand { get; }
    public ICommand RunShellCommand { get; }
    public ICommand StopShellCommand { get; }
    public ICommand ClearShellCommand { get; }
    public ICommand NewTerminalTabCommand { get; }
    public ICommand SelectConsoleTabCommand { get; }
    public ICommand CloseConsoleTabCommand { get; }
    public ICommand OpenUrlCommand { get; }
    public ObservableCollection<ConsoleTab> ConsoleTabs { get; } = [];
    public ConsoleTab? SelectedConsoleTab
    {
        get => _selectedConsoleTab;
        set
        {
            if (!SetProperty(ref _selectedConsoleTab, value)) return;
            foreach (var tab in ConsoleTabs) tab.IsSelected = ReferenceEquals(tab, value);
            if (value is { IsTerminal: true })
            {
                ShellLines = value.Lines;
                ShellKind = value.ShellKind;
            }
            OnPropertyChanged(nameof(ConsoleTabLines));
            OnPropertyChanged(nameof(ConsoleTerminalVisibility));
            OnPropertyChanged(nameof(ConsoleServerVisibility));
            OnPropertyChanged(nameof(ConsoleTabSubtitle));
            OnPropertyChanged(nameof(ConsoleProfile));
            NotifyConsoleLines();
        }
    }
    public ObservableCollection<LogLine> ShellLines { get; private set; } = [];
    public IReadOnlyList<LogLine> ConsoleTabLines => SelectedConsoleTab?.IsTerminal == true ? ShellLines : SelectedController?.Log.Lines ?? EmptyLogLines;
    public Visibility ConsoleTerminalVisibility => SelectedConsoleTab?.IsTerminal == true ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ConsoleServerVisibility => SelectedConsoleTab?.IsTerminal == false ? Visibility.Visible : Visibility.Collapsed;
    public string ConsoleTabSubtitle => SelectedConsoleTab?.IsTerminal == true ? $"{ShellKind} terminal" : ConsoleProfile?.Name ?? "";

    /// <summary>The server of the selected log tab; null for a terminal tab.</summary>
    public ServerProfile? ConsoleProfile => SelectedConsoleTab?.Profile;
    public string ConsoleStatusText => SelectedConsoleTab switch
    {
        { IsTerminal: true, Session: { IsRunning: true } session } => $"{Localization.T("Shell")}: {session.ShellKind} · {session.WorkingDirectory}",
        { IsTerminal: true } => Localization.T("Shell is not running"),
        { Profile: { } profile } => string.Join("   ", new[] { profile.StateText, profile.ProcessId is { } pid ? $"PID {pid}" : "", profile.Address }.Where(part => part.Length > 0)),
        _ => ""
    };
    public Visibility TerminalRunningVisibility => SelectedConsoleTab is { IsTerminal: true, Session.IsRunning: true } ? Visibility.Visible : Visibility.Collapsed;
    public Visibility TerminalStoppedVisibility => SelectedConsoleTab is { IsTerminal: true } tab && tab.Session?.IsRunning != true ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ConsoleServerActiveVisibility => ConsoleProfile?.IsActive == true ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ConsoleServerStartVisibility => ConsoleProfile is { IsActive: false } ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ConsoleServerOpenVisibility => ConsoleProfile?.State == ServerState.Running ? Visibility.Visible : Visibility.Collapsed;
    public string? ConsoleLogFilePath => ConsoleController?.Log.FilePath;
    public string ConsoleLogText => ConsoleController?.Log.TimestampedText ?? "";
    public string ConsolePlainText => ConsoleController?.Log.PlainText ?? "";
    public void ClearConsoleLog() => ConsoleController?.Log.Clear();

    private string _consoleFilter = "";
    private ObservableCollection<LogLine>? _watchedConsoleLines;
    private ObservableCollection<LogLine> _filteredConsoleLines = [];
    public string ConsoleFilter { get => _consoleFilter; set { if (SetProperty(ref _consoleFilter, value ?? "")) NotifyConsoleLines(); } }

    /// <summary>The log as shown: everything, or the lines matching the filter, kept live.</summary>
    public ObservableCollection<LogLine> ConsoleDisplayLines => ConsoleFilter.Length == 0 ? ConsoleLines : _filteredConsoleLines;
    public string ConsoleLineCountText => ConsoleFilter.Length == 0
        ? $"{ConsoleLines.Count} {Localization.T("lines")}"
        : $"{_filteredConsoleLines.Count} / {ConsoleLines.Count} {Localization.T("lines")}";

    private bool MatchesConsoleFilter(LogLine line) => line.Text.Contains(ConsoleFilter, StringComparison.OrdinalIgnoreCase);

    private void NotifyConsoleLines()
    {
        var lines = ConsoleLines;
        if (!ReferenceEquals(lines, _watchedConsoleLines))
        {
            if (_watchedConsoleLines is not null) _watchedConsoleLines.CollectionChanged -= WatchedConsoleLines_CollectionChanged;
            _watchedConsoleLines = lines;
            lines.CollectionChanged += WatchedConsoleLines_CollectionChanged;
        }
        _filteredConsoleLines = ConsoleFilter.Length == 0 ? [] : new(lines.Where(MatchesConsoleFilter));
        OnPropertyChanged(nameof(ConsoleLines));
        OnPropertyChanged(nameof(ConsoleDisplayLines));
        OnPropertyChanged(nameof(ConsoleLineCountText));
        NotifyConsoleStatus();
    }

    private void WatchedConsoleLines_CollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (ConsoleFilter.Length > 0)
        {
            if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Add && e.NewItems is not null)
                foreach (var line in e.NewItems.OfType<LogLine>().Where(MatchesConsoleFilter)) _filteredConsoleLines.Add(line);
            else if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Remove && e.OldItems is not null)
                foreach (var line in e.OldItems.OfType<LogLine>()) _filteredConsoleLines.Remove(line);
            else { NotifyConsoleLines(); return; }
        }
        OnPropertyChanged(nameof(ConsoleLineCountText));
    }

    private void NotifyConsoleStatus()
    {
        OnPropertyChanged(nameof(ConsoleStatusText));
        OnPropertyChanged(nameof(TerminalRunningVisibility));
        OnPropertyChanged(nameof(TerminalStoppedVisibility));
        OnPropertyChanged(nameof(ConsoleServerActiveVisibility));
        OnPropertyChanged(nameof(ConsoleServerStartVisibility));
        OnPropertyChanged(nameof(ConsoleServerOpenVisibility));
        OnPropertyChanged(nameof(ConsoleLogFilePath));
    }
    public string ShellKind
    {
        get => _shellKind;
        set
        {
            if (SetProperty(ref _shellKind, value))
            {
                if (SelectedConsoleTab is { IsTerminal: true } tab) tab.ShellKind = value;
                OnPropertyChanged(nameof(ConsoleTabSubtitle));
            }
        }
    }
    public string ShellCommandText { get => _shellCommandText; set { if (SetProperty(ref _shellCommandText, value)) OnPropertyChanged(nameof(CanRunShell)); } }
    public bool ShellBusy { get => _shellBusy; private set { SetProperty(ref _shellBusy, value); OnPropertyChanged(nameof(CanRunShell)); } }
    public bool CanRunShell => !ShellBusy && !string.IsNullOrWhiteSpace(ShellCommandText);
    public ObservableCollection<PortEntry> PortEntries { get; } = [];
    private string _portSearchText = "";
    public string PortSearchText { get => _portSearchText; set { if (SetProperty(ref _portSearchText, value)) ApplyPortFilters(); } }
    public ObservableCollection<PortReservation> PortReservations { get; } = [];
    private string _reservePortText = "";
    private string _reservePortNote = "";
    public string ReservePortText { get => _reservePortText; set => SetProperty(ref _reservePortText, value); }
    public string ReservePortNote { get => _reservePortNote; set => SetProperty(ref _reservePortNote, value); }
    public Visibility PortReservationsVisibility => _settings.PortReservationsEnabled ? Visibility.Visible : Visibility.Collapsed;
    private bool _portsScanning;
    public bool PortsScanning
    {
        get => _portsScanning;
        private set
        {
            if (!SetProperty(ref _portsScanning, value)) return;
            OnPropertyChanged(nameof(CanRefreshPorts));
            OnPropertyChanged(nameof(PortsProgressVisibility));
            OnPropertyChanged(nameof(PortsEmptyVisibility));
        }
    }
    public bool CanRefreshPorts => !PortsScanning;
    private string _portsSummary = "Not checked yet.";
    public string PortsSummary { get => Localized(_portsSummary); private set => SetProperty(ref _portsSummary, value); }
    public string PortsProblem { get => _portsProblem; private set { if (SetProperty(ref _portsProblem, value)) OnPropertyChanged(nameof(PortsProblemVisibility)); } }
    public Visibility PortsProgressVisibility => PortsScanning ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PortsProblemVisibility => PortsProblem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility PortsEmptyVisibility => !PortsScanning && PortsProblem.Length == 0 && PortEntries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public ObservableCollection<DiagnosticFinding> DiagnosticFindings { get; } = [];
    private bool _diagnosticsRunning;
    public bool DiagnosticsRunning
    {
        get => _diagnosticsRunning;
        private set
        {
            SetProperty(ref _diagnosticsRunning, value);
            OnPropertyChanged(nameof(CanRunDiagnostics));
            OnPropertyChanged(nameof(CanCopyDiagnostics));
            OnPropertyChanged(nameof(DiagnosticsProgressVisibility));
            OnPropertyChanged(nameof(DiagnosticsCheckedAt));
        }
    }
    public bool CanRunDiagnostics => !DiagnosticsRunning;
    public bool CanCopyDiagnostics => !DiagnosticsRunning && DiagnosticFindings.Count > 0;
    private DateTimeOffset? _diagnosticsLastRun;
    private bool _showHealthyDiagnostics;
    public bool ShowHealthyDiagnostics { get => _showHealthyDiagnostics; set => SetProperty(ref _showHealthyDiagnostics, value); }
    public IReadOnlyList<DiagnosticFinding> DiagnosticProblems => DiagnosticFindings.Where(item => item.NeedsAttention).OrderByDescending(item => item.Level).ToArray();
    public IReadOnlyList<DiagnosticFinding> DiagnosticHealthy => DiagnosticFindings.Where(item => !item.NeedsAttention).ToArray();
    public Visibility DiagnosticProblemsVisibility => DiagnosticProblems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DiagnosticsProgressVisibility => DiagnosticsRunning ? Visibility.Visible : Visibility.Collapsed;
    public bool HasHealthyDiagnostics => DiagnosticHealthy.Count > 0;
    public string DiagnosticHealthyHeader => Localized($"Everything that passed ({DiagnosticHealthy.Count})");
    public string DiagnosticsCheckedAt => !DiagnosticsRunning && _diagnosticsLastRun is { } last ? "Checked " + last.LocalDateTime.ToString("g") : "";
    public string DiagnosticsGlyph => DiagnosticFindings.Any(item => item.Level == DiagnosticLevel.Broken) ? "\uEA39"
        : DiagnosticProblems.Count > 0 ? "\uE7BA" : DiagnosticFindings.Count > 0 ? "\uE73E" : "\uE946";
    public string DiagnosticsTint => DiagnosticFindings.Any(item => item.Level == DiagnosticLevel.Broken) ? "#E66A72"
        : DiagnosticProblems.Count > 0 ? "#E7BD57" : DiagnosticFindings.Count > 0 ? "#32B875" : "#A6AAB4";

    private void NotifyDiagnosticResults()
    {
        foreach (var name in new[] { nameof(DiagnosticProblems), nameof(DiagnosticHealthy), nameof(DiagnosticProblemsVisibility),
            nameof(HasHealthyDiagnostics), nameof(DiagnosticHealthyHeader), nameof(DiagnosticsCheckedAt), nameof(DiagnosticsGlyph), nameof(DiagnosticsTint) }) OnPropertyChanged(name);
    }
    public ObservableCollection<SiteHealthResult> HealthResults { get; } = [];
    private bool _healthCheckBusy;
    private DateTimeOffset? _healthLastRun;
    public bool CanHealthCheck => !_healthCheckBusy && Profiles.Any(profile => profile.IsRunning);
    public bool CanClearHealthCheck => !_healthCheckBusy;
    public Visibility HealthPanelVisibility => _healthCheckBusy || HealthResults.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HealthProgressVisibility => _healthCheckBusy ? Visibility.Visible : Visibility.Collapsed;
    public string HealthLastRun => !_healthCheckBusy && _healthLastRun is { } last ? last.LocalDateTime.ToString("T") : "";
    public string HealthSummary => Localized(_healthCheckBusy ? "Checking running sites..." : HealthResults.All(result => result.IsGood)
        ? "Every running site answered." : $"{HealthResults.Count(result => !result.IsGood)} site(s) did not answer properly.");
    private string _diagnosticsSummary = "Not checked yet.";
    public string DiagnosticsSummary { get => Localized(_diagnosticsSummary); private set => SetProperty(ref _diagnosticsSummary, value); }
    public Visibility DiagnosticsVisibility => SelectedSection == "Diagnostics" ? Visibility.Visible : Visibility.Collapsed;

    public ObservableCollection<DiagnosticFinding> TraceSteps { get; } = [];
    private CancellationTokenSource? _traceCancellation;
    private int _traceVersion;
    private bool _traceRunning;
    private string _traceSubject = "";
    public bool TraceRunning { get => _traceRunning; private set { SetProperty(ref _traceRunning, value); OnPropertyChanged(nameof(CanTrace)); OnPropertyChanged(nameof(TraceProgressVisibility)); } }
    public bool CanTrace => !TraceRunning;
    public Visibility TraceProgressVisibility => TraceRunning ? Visibility.Visible : Visibility.Collapsed;
    public Visibility TraceProfilesEmptyVisibility => Profiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public string TraceSubject { get => _traceSubject; private set => SetProperty(ref _traceSubject, value); }

    public async Task TraceProfileAsync(ServerProfile profile)
    {
        if (TraceRunning) return;
        TraceRunning = true;
        TraceSubject = profile.Address;
        TraceSteps.Clear();
        using var cancellation = new CancellationTokenSource();
        _traceCancellation = cancellation;
        var version = ++_traceVersion;
        var target = new SiteHealthTarget(profile.Id, profile.Name, profile.Address, profile.CertificatePath);
        try
        {
            await DomainTrace.RunAsync(target, step => _dispatcher.TryEnqueue(() =>
            {
                if (version == _traceVersion && !cancellation.IsCancellationRequested) TraceSteps.Add(step);
            }), cancellation.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { TraceSteps.Add(new("Trace", "Interrupted", ex.Message, Severity: DiagnosticLevel.Broken)); }
        finally { _traceCancellation = null; TraceRunning = false; }
    }
    public Visibility PortsVisibility => SelectedSection == "Ports" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DatabaseVisibility => SelectedSection == "Database" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility AboutVisibility => SelectedSection == "About" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FilesVisibility => SelectedSection == "Files" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BackupsVisibility => SelectedSection == "Backups" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SettingsVisibility => SelectedSection == "Settings" ? Visibility.Visible : Visibility.Collapsed;
    public bool CanResetSettings => CanCreateBackups && !_databaseBusy && !Dependencies.Any(status => status.Busy);

    public void ResetSettings()
    {
        if (!CanResetSettings) throw new InvalidOperationException("Wait for installation, database or snapshot operations to finish before resetting settings.");
        var defaults = SettingsBehavior.Reset(_settings);
        // Persist first: a failed save must not silently replace the in-memory preferences.
        _store.SaveSettings(defaults);
        _settings = defaults;
        _crashRecovery.CancelAll();
        ExtraPathEntries.Clear();
        ShellEnvironment.Shared.SetExtraEntries(defaults.ExtraPathEntries);
        NewPathEntry = "";
        _portReserver.ReleaseAll();
        PortReservations.Clear();
        AdminerService.SetPort(defaults.DatabaseAdminPort);
        AdminerService.SetTool(defaults.DatabaseAdminTool);
        foreach (var controller in _controllers.Values) controller.Log.Limit = defaults.ConsoleBufferLines;
        ApplyFileLoggingPreference();
        RefreshDefaultMarks();
        ApplyPortFilters();
        RefreshBackups();
        OnPropertyChanged("");
        NotifyControlDetails();
        Notify("Settings reset to defaults. Profiles and project data have not been changed.");
    }
    public string FilesPath { get => _filesPath; private set => SetProperty(ref _filesPath, value); }
    public ServerProfile? FilesProfile
    {
        get => Profiles.FirstOrDefault(profile => profile.Id == _filesProfileId) ?? Profiles.FirstOrDefault();
        set
        {
            if (_filesProfileId == value?.Id) return;
            _filesProfileId = value?.Id;
            FilesPath = "";
            OnPropertyChanged();
            OnPropertyChanged(nameof(FilesProfileName));
            RefreshFiles();
        }
    }
    public string FilesProfileName => FilesProfile?.Name ?? "";
    public string NewPathEntry { get => _newPathEntry; set => SetProperty(ref _newPathEntry, value); }
    public bool OpenBrowserOnStart { get => _settings.OpenBrowserOnStart; set { if (_settings.OpenBrowserOnStart != value) { _settings.OpenBrowserOnStart = value; SaveSettings(); } } }
    public bool StopServerOnQuit { get => _settings.StopServerOnQuit; set { if (_settings.StopServerOnQuit != value) { _settings.StopServerOnQuit = value; SaveSettings(); OnPropertyChanged(nameof(KeepRunningInNotificationArea)); } } }
    // Windows keeps the macOS field: off means closing the window hides ServerMaster in the
    // notification area. Servers stay owned by this process; quitting always stops them.
    public bool KeepRunningInNotificationArea { get => !StopServerOnQuit; set => StopServerOnQuit = !value; }
    public bool ConfirmBeforeStop { get => _settings.ConfirmBeforeStop; set { if (_settings.ConfirmBeforeStop != value) { _settings.ConfirmBeforeStop = value; SaveSettings(); } } }
    public bool RestartOnCrash { get => _settings.RestartOnCrash; set { if (_settings.RestartOnCrash != value) { _settings.RestartOnCrash = value; if (!value) _crashRecovery.CancelAll(); SaveSettings(); } } }
    public bool CheckPortBeforeStart { get => _settings.CheckPortBeforeStart; set { if (_settings.CheckPortBeforeStart != value) { _settings.CheckPortBeforeStart = value; SaveSettings(); } } }
    public bool KillPortOccupantOnStart { get => _settings.KillPortOccupantOnStart; set { _settings.KillPortOccupantOnStart = value; SaveSettings(); OnPropertyChanged(nameof(KillPortWarningVisibility)); } }
    public Visibility KillPortWarningVisibility => _settings.KillPortOccupantOnStart ? Visibility.Visible : Visibility.Collapsed;
    public string DataFolderPath => AppPaths.Support;
    public bool WriteLogsToFile { get => _settings.WriteLogsToFile; set { if (_settings.WriteLogsToFile != value) { _settings.WriteLogsToFile = value; SaveSettings(); } } }
    public int ConsoleBufferLines { get => _settings.ConsoleBufferLines; set { _settings.ConsoleBufferLines = Math.Clamp(value, 100, 50000); SaveSettings(); } }
    public int LogRetentionDays { get => _settings.LogRetentionDays; set { _settings.LogRetentionDays = Math.Clamp(value, 0, 365); _lastLogCleanup = default; SaveSettings(); } }
    public bool AutostartDefaultProfile { get => _settings.AutostartDefaultProfile; set { _settings.AutostartDefaultProfile = value; SaveSettings(); } }
    public bool RestoreLastSection { get => _settings.RestoreLastSection; set { _settings.RestoreLastSection = value; SaveSettings(); } }
    public double ConsoleFontSize { get => _settings.ConsoleFontSize; set { _settings.ConsoleFontSize = Math.Clamp(value, 9, 24); SaveSettings(); } }
    public bool AutoScrollConsole { get => _settings.AutoScrollConsole; set { _settings.AutoScrollConsole = value; SaveSettings(); } }
    public bool PortsAutoRefresh { get => _settings.PortsAutoRefresh; set { _settings.PortsAutoRefresh = value; SaveSettings(); } }
    public bool PortReservationsEnabled
    {
        get => _settings.PortReservationsEnabled;
        set
        {
            if (_settings.PortReservationsEnabled == value) return;
            _settings.PortReservationsEnabled = value;
            if (!value) { _portReserver.ReleaseAll(); PortReservations.Clear(); _ = RefreshPortsAsync(); }
            SaveSettings();
            OnPropertyChanged();
            OnPropertyChanged(nameof(PortReservationsVisibility));
        }
    }
    public double PortsRefreshInterval { get => _settings.PortsRefreshInterval; set { _settings.PortsRefreshInterval = Math.Clamp(value, 1, 60); SaveSettings(); } }
    public bool PortsIncludeUdp { get => _settings.PortsIncludeUdp; set { _settings.PortsIncludeUdp = value; SaveSettings(); if (SelectedSection == "Ports") _ = RefreshPortsAsync(); } }
    public bool PortsShowSystemProcesses { get => _settings.PortsShowSystemProcesses; set { _settings.PortsShowSystemProcesses = value; SaveSettings(); ApplyPortFilters(); } }
    public bool ConfirmBeforeKill { get => _settings.ConfirmBeforeKill; set { _settings.ConfirmBeforeKill = value; SaveSettings(); } }
    public bool CheckDependenciesOnLaunch { get => _settings.CheckDependenciesOnLaunch; set { _settings.CheckDependenciesOnLaunch = value; SaveSettings(); } }
    public bool BackgroundEnabled { get => _settings.BackgroundEnabled; set { _settings.BackgroundEnabled = value; SaveSettings(); OnPropertyChanged(nameof(AppBackgroundBrush)); } }
    public double BackgroundHue { get => _settings.BackgroundHue; set { _settings.BackgroundHue = value; SaveSettings(); OnPropertyChanged(nameof(AppBackgroundBrush)); } }
    public double BackgroundSpeed { get => _settings.BackgroundSpeed; set { _settings.BackgroundSpeed = value; SaveSettings(); OnPropertyChanged(nameof(AppBackgroundBrush)); } }
    public double BackgroundSaturation { get => _settings.BackgroundSaturation; set { _settings.BackgroundSaturation = value; SaveSettings(); OnPropertyChanged(nameof(AppBackgroundBrush)); } }
    public bool BackgroundFollowsServers { get => _settings.BackgroundFollowsServers; set { _settings.BackgroundFollowsServers = value; SaveSettings(); OnPropertyChanged(nameof(AppBackgroundBrush)); } }
    /// <summary>
    /// The ambient palette: shades of one hue (the setting's, or the first running profile's
    /// accent), from a deep base to bright highlights, with small hue shifts between them. Wider
    /// than the Mac steps on purpose: without Display P3 and glass those read as flat slate here,
    /// and the Apple Music look needs visible depth. The first entry is the darkest (the base).
    /// </summary>
    public IReadOnlyList<global::Windows.UI.Color> BackgroundPalette
    {
        get
        {
            var hue = BackgroundHue;
            if (BackgroundFollowsServers && Profiles.FirstOrDefault(profile => profile.IsRunning) is { } active && TryHue(active.ProfileColor, out var profileHue)) hue = profileHue;
            var amount = Math.Clamp(BackgroundSaturation, 0, 1);
            (double Shift, double Saturation, double Brightness)[] steps =
                [(0.00, 0.85, 0.16), (-0.04, 0.80, 0.50), (0.05, 0.70, 0.62), (0.02, 0.90, 0.34), (-0.07, 0.60, 0.70), (0.08, 0.75, 0.44)];
            return steps.Select(step => Hsv(hue + step.Shift, step.Saturation * amount, step.Brightness)).ToArray();
        }
    }

    public Brush AppBackgroundBrush
    {
        get
        {
            if (!BackgroundEnabled) return new SolidColorBrush(ColorHelper.FromArgb(255, 31, 33, 37));
            var hue = BackgroundHue;
            if (BackgroundFollowsServers && Profiles.FirstOrDefault(profile => profile.IsRunning) is { } active && TryHue(active.ProfileColor, out var profileHue)) hue = profileHue;
            var saturation = Math.Clamp(BackgroundSaturation, 0, 1) * .55;
            return new LinearGradientBrush
            {
                StartPoint = new global::Windows.Foundation.Point(0, 0), EndPoint = new global::Windows.Foundation.Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = Hsv(hue - .05, saturation * .65, .30), Offset = 0 },
                    new GradientStop { Color = Hsv(hue, saturation, .52), Offset = .45 },
                    new GradientStop { Color = Hsv(hue + .08, saturation * .9, .32), Offset = 1 }
                }
            };
        }
    }
    public bool BackupsEnabled { get => _settings.BackupsEnabled; set { if (_settings.BackupsEnabled != value) { _settings.BackupsEnabled = value; SaveSettings(); OnPropertyChanged(); OnPropertyChanged(nameof(LastBackupText)); } } }
    public int BackupEvery { get => _settings.BackupEvery; set { _settings.BackupEvery = Math.Clamp(value, 1, 999); SaveSettings(); } }
    public int BackupsToKeep { get => _settings.BackupsToKeep; set { _settings.BackupsToKeep = Math.Clamp(value, 1, 999); SaveSettings(); } }
    public bool BackupIncludesDatabase { get => _settings.BackupIncludesDatabase; set { _settings.BackupIncludesDatabase = value; SaveSettings(); } }
    public bool ScheduledBackupsIncludeAllProfiles => _settings.BackupProfileIds.Count == 0;
    public IReadOnlyList<Guid> ScheduledBackupProfileIds => _settings.BackupProfileIds.ToArray();
    public string ScheduledBackupProfilesSummary => Localized(ScheduledBackupsIncludeAllProfiles ? "All profiles" : $"Selected profiles ({SettingsBehavior.ScheduledProfiles(_settings, Profiles).Count})");

    public void SetScheduledBackupProfiles(bool allProfiles, IEnumerable<Guid> selectedIds)
    {
        if (!CanCreateBackups) throw new InvalidOperationException("Wait for the snapshot operation to finish.");
        var ids = selectedIds.Where(id => Profiles.Any(profile => profile.Id == id)).Distinct().ToList();
        if (!allProfiles && ids.Count == 0) throw new InvalidOperationException("Select at least one profile, or choose All profiles.");
        _settings.BackupProfileIds = allProfiles ? [] : ids;
        SaveSettings();
        OnPropertyChanged(nameof(ScheduledBackupProfilesSummary));
    }
    public bool BackupAllDatabases { get => _settings.BackupAllDatabases; set { _settings.BackupAllDatabases = value; SaveSettings(); } }
    public string BackupDestination => string.IsNullOrWhiteSpace(_settings.BackupDestination) ? Path.Combine(AppPaths.Documents, "ServerMaster Backups") : AppPaths.Expand(_settings.BackupDestination);
    public string LastBackupText => _settings.LastBackup is { } last ? "Last automatic snapshot " + last.LocalDateTime.ToString("g") : "No automatic snapshots yet.";
    public string UpdateRepository
    {
        get => _settings.UpdateRepository;
        set
        {
            if (_settings.UpdateRepository == value) return;
            _settings.UpdateRepository = value;
            SaveSettings();
            NotifyUpdateConfiguration();
        }
    }
    public string UpdateVersionFile
    {
        get => _settings.UpdateVersionFile;
        set
        {
            if (_settings.UpdateVersionFile == value) return;
            _settings.UpdateVersionFile = value;
            SaveSettings();
            NotifyUpdateConfiguration();
        }
    }
    public string UpdateBuildsFolder
    {
        get => _settings.UpdateBuildsFolder;
        set
        {
            if (_settings.UpdateBuildsFolder == value) return;
            _settings.UpdateBuildsFolder = value;
            SaveSettings();
            NotifyUpdateConfiguration();
        }
    }
    public bool CheckUpdatesOnLaunch { get => _settings.CheckUpdatesOnLaunch; set { _settings.CheckUpdatesOnLaunch = value; SaveSettings(); } }
    public string CurrentAppVersion => UpdateChecker.CurrentVersion;
    public string AboutVersionLine => $"{Localization.T("Version")} {CurrentAppVersion} · Windows {Environment.OSVersion.Version.Build}";
    // Matches TargetPlatformMinVersion 10.0.18362 (Windows 10, version 1903).
    public string AboutRequirementsLine => Localization.T("Requires Windows 10 version 1903 or newer · %@").Replace("%@", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(), StringComparison.Ordinal);
    // What the Mac About card copies: name and version, then the system and architecture.
    public string AboutDetails => $"ServerMaster {AboutVersionLine}{Environment.NewLine}{Environment.OSVersion.VersionString} · {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()}";
    public ICommand CopyAboutDetailsCommand => new RelayCommand(_ => CopyText(AboutDetails));
    public string AboutDataFolder => AppPaths.Support;
    public string InstalledAppVersionText => Localization.T("Installed version: %@").Replace("%@", CurrentAppVersion, StringComparison.Ordinal);
    public bool UpdateConfigured => UpdateChecker.NormalizeRepository(UpdateRepository).Length > 0 && UpdateVersionSource.Length > 0;
    public string UpdateVersionSource => _updateChecker.VersionFileUrl(UpdateRepository, UpdateVersionFile);
    public bool UpdateChecking { get => _updateChecking; private set { SetProperty(ref _updateChecking, value); OnPropertyChanged(nameof(CanCheckForUpdates)); OnPropertyChanged(nameof(UpdateCheckingVisibility)); } }
    public bool CanCheckForUpdates => UpdateConfigured && !UpdateChecking;
    public Visibility UpdateCheckingVisibility => UpdateChecking ? Visibility.Visible : Visibility.Collapsed;
    public string UpdateStatus { get => _updateStatus; private set => SetProperty(ref _updateStatus, value); }
    public Visibility UpdateReleaseVisibility => _updateReleaseUrl.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility UpdateBannerVisibility => _availableUpdateVersion.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string UpdateBannerTitle => _availableUpdateVersion.Length == 0 ? "" : Localization.T("Version %@ is available").Replace("%@", _availableUpdateVersion, StringComparison.Ordinal);
    public string UpdateBannerMessage => _availableUpdateVersion.Length == 0 ? "" : Directory.Exists(_availableUpdateBuildPath)
        ? FillInOrder(Localization.T("Installed %@. The build is in %@."), CurrentAppVersion, _availableUpdateBuildPath)
        : Localization.T("Installed %@. The local build folder was not found; the release page will open.").Replace("%@", CurrentAppVersion, StringComparison.Ordinal);
    public string UpdateBannerActionText => Directory.Exists(_availableUpdateBuildPath) ? "Open build" :
        _updateReleaseUrl.Length > 0 ? "Open release" : "Open repository";
    public Visibility UpdateConfigurationVisibility => UpdateConfigured ? Visibility.Visible : Visibility.Collapsed;
    public Visibility UpdateConfigurationProblemVisibility => UpdateConfigured ? Visibility.Collapsed : Visibility.Visible;
    public int CertificateDefaultDays { get => _settings.CertificateDefaultDays; set { _settings.CertificateDefaultDays = Math.Clamp(value, 1, 3650); SaveSettings(); } }
    public string CertificateDefaultDomains { get => _settings.CertificateDefaultDomains; set { _settings.CertificateDefaultDomains = value; SaveSettings(); } }
    public string BackupUnit { get => _settings.BackupUnit; set { _settings.BackupUnit = value; SaveSettings(); } }
    public string SidebarStyle { get => _settings.SidebarStyle; set { _settings.SidebarStyle = value; SaveSettings(); } }
    // A code saved by an older build (or a language whose translation is not bundled) reads as
    // "match the system", which is also what Localization applies for it.
    public string InterfaceLanguage
    {
        get => Localization.IsAvailable(_settings.Language) ? _settings.Language : Localization.SystemCode;
        set
        {
            value ??= Localization.SystemCode;
            if (value == InterfaceLanguage) return;
            _settings.Language = value;
            SaveSettings();
            OnPropertyChanged(nameof(LanguageNotice));
            Notify(Localization.T("The language will apply after the app restarts."));
        }
    }
    public IReadOnlyList<KeyValuePair<string, string>> LanguageOptions =>
        [new(Localization.SystemCode, Localization.T("Match the system")), .. Localization.Available.Select(entry => new KeyValuePair<string, string>(entry.Code, entry.Title))];
    public string LanguageNotice => InterfaceLanguage == Localization.SystemCode
        ? Localization.T("Currently using %@. The app follows the system language.")
            .Replace("%@", Localization.Entry(Localization.Resolve(Localization.SystemCode, System.Globalization.CultureInfo.CurrentUICulture)).NativeName)
        : Localization.T("The language change takes effect after restarting the app.");

    // Translation packs, as on macOS: export today's wording, edit it, import it back.
    public static string TranslationsFolder => Path.Combine(AppPaths.Support, "Translations");
    public ObservableCollection<TranslationPack> TranslationPacksInstalled { get; } = [];
    public ICommand RemoveTranslationPackCommand { get; }
    private TranslationPack? MismatchedTranslationPack => TranslationPacksInstalled.FirstOrDefault(pack => !pack.MatchesApp(CurrentAppVersion));
    public Visibility TranslationMismatchVisibility => MismatchedTranslationPack is null ? Visibility.Collapsed : Visibility.Visible;
    public string TranslationMismatchText => MismatchedTranslationPack is { } pack
        ? FillInOrder(Localization.T("An imported translation was made for ServerMaster %@, and this is %@."), pack.AppVersion, CurrentAppVersion)
        : "";

    private static string FillInOrder(string template, params string[] values)
    {
        foreach (var value in values)
        {
            var at = template.IndexOf("%@", StringComparison.Ordinal);
            if (at < 0) break;
            template = template[..at] + value + template[(at + 2)..];
        }
        return template;
    }

    public void RefreshTranslationPacks()
    {
        TranslationPacksInstalled.Clear();
        foreach (var pack in TranslationPacks.Installed(TranslationsFolder).Values) TranslationPacksInstalled.Add(pack);
        OnPropertyChanged(nameof(TranslationMismatchVisibility));
        OnPropertyChanged(nameof(TranslationMismatchText));
    }

    public bool ExportTranslationPack(string path)
    {
        try
        {
            TranslationPacks.Export(Localization.Effective.Code, CurrentAppVersion, path);
            Notify(Localization.T("Translation exported to %@.").Replace("%@", Path.GetFileName(path), StringComparison.Ordinal));
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            ReportError(Localization.T("The translation could not be written.") + " " + ex.Message);
            return false;
        }
    }

    public void ImportTranslationPack(string path)
    {
        var result = TranslationPacks.Import(path, TranslationsFolder);
        RefreshTranslationPacks();
        switch (result.Kind)
        {
            case TranslationImportKind.Installed when result.Pack!.MatchesApp(CurrentAppVersion):
                Notify(Localization.T("Translation imported. Restart the app to see it."));
                break;
            case TranslationImportKind.Installed:
                ReportError(Localization.T("Imported, but it was made for ServerMaster %@ — some strings will stay in English.").Replace("%@", result.Pack!.AppVersion, StringComparison.Ordinal));
                break;
            case TranslationImportKind.NotAStringsFile:
                ReportError(Localization.T("That file is not a translation the app can read."));
                break;
            default:
                ReportError(result.Message);
                break;
        }
    }

    private void RemoveTranslationPack(TranslationPack? pack)
    {
        if (pack is null) return;
        try { TranslationPacks.Remove(TranslationsFolder, pack.Language); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ReportError(ex.Message); }
        RefreshTranslationPacks();
    }
    public string DefaultTerminalShell { get => _settings.DefaultTerminalShell; set { _settings.DefaultTerminalShell = value is "CMD" ? "CMD" : "PowerShell"; SaveSettings(); } }
    public IReadOnlyList<AdminToolOption> DatabaseAdminTools { get; } =
    [
        new("adminer", "Adminer", "Small and quick; downloaded as one verified PHP file."),
        new("phpmyadmin", "phpMyAdmin", "The familiar MAMP-style interface; downloaded and managed by ServerMaster.")
    ];
    public string DatabaseAdminTool
    {
        get => _settings.DatabaseAdminTool;
        set
        {
            value = value == "phpmyadmin" ? value : "adminer";
            if (_settings.DatabaseAdminTool == value) return;
            _settings.DatabaseAdminTool = value;
            AdminerService.SetTool(value);
            SaveSettings();
            foreach (var name in new[] { nameof(DatabaseAdminTool), nameof(DatabaseAdminToolSubtitle), nameof(AdminPanelTitle),
                nameof(AdminerAddress), nameof(AdminerStatus), nameof(AdminerRunningVisibility) }) OnPropertyChanged(name);
        }
    }
    public string DatabaseAdminToolSubtitle => DatabaseAdminTools.First(item => item.Id == DatabaseAdminTool).Subtitle;
    public int DatabaseAdminPort
    {
        get => _settings.DatabaseAdminPort;
        set { _settings.DatabaseAdminPort = Math.Clamp(value, 1, 65535); AdminerService.SetPort(_settings.DatabaseAdminPort); SaveSettings(); OnPropertyChanged(nameof(AdminerAddress)); }
    }
    public ServerProfile? DefaultProfile
    {
        get => Profiles.FirstOrDefault(profile => profile.Id == _settings.DefaultProfileId);
        set
        {
            _settings.DefaultProfileId = value?.Id;
            SaveSettings();
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectedProfileDefaultVisibility));
            OnPropertyChanged(nameof(SelectedProfileMakeDefaultVisibility));
            RefreshDefaultMarks();
        }
    }
    public DatabaseRuntimeStatus DatabaseStatus => DatabaseService.Detect();
    public bool DatabaseCanStart => !_databaseBusy && DatabaseStatus.Installed && !DatabaseStatus.Running;
    public bool DatabaseCanStop => !_databaseBusy && DatabaseStatus.Running;
    public bool DatabaseCanInstall => !_databaseBusy && !DatabaseStatus.Installed;
    public Visibility DatabaseProgressVisibility => _databaseBusy ? Visibility.Visible : Visibility.Collapsed;
    public ObservableCollection<LogLine> DatabaseLogLines { get; } = [];
    public ObservableCollection<DatabaseEntry> DatabaseEntries { get; } = [];
    public ObservableCollection<string> DatabaseTables { get; } = [];
    public DatabaseEntry? SelectedDatabase
    {
        get => _selectedDatabase;
        private set
        {
            if (!SetProperty(ref _selectedDatabase, value)) return;
            OnPropertyChanged(nameof(DatabaseBrowserVisibility));
            OnPropertyChanged(nameof(SelectedDatabaseTitle));
        }
    }
    public string SelectedDatabaseTitle => SelectedDatabase?.Name ?? "Database";
    public Visibility DatabaseBrowserVisibility => SelectedDatabase is null ? Visibility.Collapsed : Visibility.Visible;
    public string DatabaseSql { get => _databaseSql; set => SetProperty(ref _databaseSql, value); }
    public string DatabaseQueryOutput { get => _databaseQueryOutput; private set => SetProperty(ref _databaseQueryOutput, value); }
    public string AdminerAddress => AdminerService.Address;
    public string AdminPanelTitle => AdminerService.ToolTitle;
    public string AdminerStatus => AdminPanelTitle + " " + Localization.T(AdminerService.IsRunning ? "running" : "stopped");
    public Visibility AdminerRunningVisibility => AdminerService.IsRunning ? Visibility.Visible : Visibility.Collapsed;
    public string NewDatabaseName { get => _newDatabaseName; set => SetProperty(ref _newDatabaseName, value); }
    public string NewDatabaseUser { get => _newDatabaseUser; set => SetProperty(ref _newDatabaseUser, value); }
    public string NewDatabasePassword { get => _newDatabasePassword; set => SetProperty(ref _newDatabasePassword, value); }
    public string DatabaseHost => "127.0.0.1";
    public string DatabasePort => DatabaseService.Port.ToString();
    public string DatabaseConnection => $"{DatabaseHost}:{DatabasePort}";
    public string DatabaseStatusTitle => Localization.T(_databaseBusy ? "Working..." : DatabaseStatus.Running ? "Running" : DatabaseStatus.Installed ? "Stopped" : "Not installed");
    public string DatabaseStatusVersion => DatabaseStatus.Running ? DatabaseStatus.Version : Localization.T("MariaDB is not running");
    public string DatabaseProcessLabel => DatabaseStatus.ProcessId is { } pid ? $"PID {pid}" : "";
    public Brush DatabaseStatusBrush => DatabaseStatus.Running ? _green : DatabaseStatus.Installed ? _orange : _red;
    public string DatabaseLogToggleText => Localization.T(DatabaseLogExpanded ? "Collapse" : "Expand");
    public double DatabaseLogHeight => DatabaseLogExpanded ? 360 : 0;
    public bool DatabaseLogExpanded
    {
        get => _databaseLogExpanded;
        private set
        {
            if (!SetProperty(ref _databaseLogExpanded, value)) return;
            OnPropertyChanged(nameof(DatabaseLogToggleText));
            OnPropertyChanged(nameof(DatabaseLogHeight));
        }
    }
    public Visibility DatabaseRunningVisibility => DatabaseStatus.Running ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DatabaseStoppedVisibility => DatabaseStatus.Running ? Visibility.Collapsed : Visibility.Visible;
    public Visibility DatabaseInstallVisibility => DatabaseStatus.Installed ? Visibility.Collapsed : Visibility.Visible;
    public string DatabaseProblem { get => _databaseProblem; private set { if (SetProperty(ref _databaseProblem, value)) { OnPropertyChanged(nameof(DatabaseProblemVisibility)); OnPropertyChanged(nameof(DatabaseEntriesEmptyVisibility)); } } }
    public Visibility DatabaseProblemVisibility => DatabaseProblem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DatabaseEntriesEmptyVisibility => DatabaseStatus.Running && !_databaseBusy && DatabaseProblem.Length == 0 && DatabaseEntries.Count == 0
        ? Visibility.Visible : Visibility.Collapsed;
    public ObservableCollection<FileEntry> FileEntries { get; } = [];
    public string FilesProblem { get => _filesProblem; private set => SetProperty(ref _filesProblem, value); }
    public Visibility FilesProblemVisibility => FilesProblem.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    public Visibility FilesEmptyVisibility => FilesProfile is not null && FileEntries.Count == 0 && FilesProblem.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HiddenFilesVisibility => HiddenFileEntries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string FilesRoot => _filesRoot;
    public IReadOnlyList<FileEntry> HiddenFileEntries => FileEntries.Where(item => item.IsHiddenOrConfig).ToList();
    public IReadOnlyList<FileEntry> VisibleFileEntries => FileEntries.Where(item => !item.IsHiddenOrConfig).ToList();
    public bool ShowAllFiles
    {
        get => _showAllFiles;
        set { if (SetProperty(ref _showAllFiles, value)) { OnPropertyChanged(nameof(AllFilesToggleText)); OnPropertyChanged(nameof(AllFilesVisibility)); } }
    }
    public string AllFilesToggleText => Localized($"Everything else ({VisibleFileEntries.Count})");
    public Visibility AllFilesVisibility => ShowAllFiles ? Visibility.Visible : Visibility.Collapsed;
    public ObservableCollection<BackupEntry> BackupEntries { get; } = [];
    public IReadOnlyList<BackupTargetRow> BackupProfiles => Profiles.Select(profile => new BackupTargetRow
    {
        Profile = profile,
        History = BackupHistory(BackupEntries.Where(item => item.Kind == "profile" && item.ProfileId == profile.Id))
    }).ToArray();
    public IReadOnlyList<BackupTargetRow> BackupDatabases => DatabaseEntries.Select(database => new BackupTargetRow
    {
        Database = database,
        History = BackupHistory(BackupEntries.Where(item => item.Kind == "database" && item.DatabaseName == database.Name))
    }).ToArray();
    public Visibility BackupProfilesEmptyVisibility => Profiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BackupEntriesEmptyVisibility => BackupEntries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BackupDatabaseMessageVisibility => !DatabaseStatus.Running || DatabaseEntries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public string BackupDatabaseMessage => Localization.T(DatabaseStatus.Running ? "No databases yet." : "The database server is not running - start it to take or restore a snapshot.");
    public Visibility BackupWorkVisibility => _backupsBusy || _scheduledBackupCheckBusy ? Visibility.Visible : Visibility.Collapsed;
    public string BackupProblem { get => _backupProblem; private set { if (SetProperty(ref _backupProblem, value)) OnPropertyChanged(nameof(BackupProblemVisibility)); } }
    public Visibility BackupProblemVisibility => BackupProblem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public ObservableCollection<string> ExtraPathEntries { get; } = [];
    public ICommand QuitCommand { get; }
    public ICommand RefreshFilesCommand { get; }
    public ICommand OpenFilesFolderCommand { get; }
    public ICommand GoUpFilesCommand { get; }
    public ICommand OpenFileCommand { get; }
    public ICommand ToggleAllFilesCommand { get; }
    public ICommand CreateBackupCommand { get; }
    public ICommand CreateAllBackupsCommand { get; }
    public ICommand CreateDatabaseBackupCommand { get; }
    private bool _backupsBusy;
    public bool CanCreateBackups => !_backupsBusy && !_scheduledBackupCheckBusy;
    public bool CanSnapshotProfiles => CanCreateBackups && Profiles.Count > 0;
    public bool CanSnapshotDatabase => CanCreateBackups && DatabaseCanStop;
    public ICommand DeleteBackupCommand { get; }
    public ICommand OpenBackupsFolderCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand AddPathEntryCommand { get; }
    public ICommand RemovePathEntryCommand { get; }

    private ProfileTemplate? _selectedTemplate;
    public ProfileTemplate? SelectedTemplate
    {
        get => _selectedTemplate;
        set
        {
            SetProperty(ref _selectedTemplate, value);
        }
    }

    public string SectionTitle => Localization.T(SelectedSection);
    public string SelectedSection
    {
        get => _selectedSection;
        set
        {
            if (SetProperty(ref _selectedSection, value))
            {
                OnPropertyChanged(nameof(SectionTitle));
                _settings.LastSection = value;
                _store.SaveSettings(_settings);
                OnPropertyChanged(nameof(ControlVisibility));
                OnPropertyChanged(nameof(ProfilesVisibility));
                OnPropertyChanged(nameof(DependenciesVisibility));
                OnPropertyChanged(nameof(ConsoleVisibility));
                OnPropertyChanged(nameof(DiagnosticsVisibility));
                OnPropertyChanged(nameof(PortsVisibility));
                OnPropertyChanged(nameof(DatabaseVisibility));
                OnPropertyChanged(nameof(AboutVisibility));
                OnPropertyChanged(nameof(FilesVisibility));
                OnPropertyChanged(nameof(BackupsVisibility));
                OnPropertyChanged(nameof(SettingsVisibility));
                EnterSection(value);
            }
        }
    }

    /// <summary>
    /// Loads what a screen shows when it is opened. Also run once after loading for the section the
    /// app restored, which is set without the setter, so a restored Diagnostics or Dependencies screen
    /// no longer stays "Not checked yet".
    /// </summary>
    private void EnterSection(string value)
    {
        if (value == "Console") RefreshConsoleTabs();
        if (value == "Files") RefreshFiles();
        if (value == "Backups") RefreshBackups();
        if (value is "Backups" or "Database") _ = RefreshDatabaseAsync();
        // While loading, InitializeAsync owns the first dependency check.
        if (value == "Dependencies" && !_dependenciesLoaded && !IsBootstrapping) { _dependenciesLoaded = true; _ = CheckDependenciesAsync(); }
        if (value == "Diagnostics" && !_diagnosticsLoaded && !IsBootstrapping) { _diagnosticsLoaded = true; _ = RunDiagnosticsAsync(); }
        if (value == "Ports" && !_portsLoaded && !IsBootstrapping) { _portsLoaded = true; _ = RefreshPortsAsync(); }
    }

    public ServerProfile? SelectedProfile
    {
        get => _selectedProfile;
        set
        {
            if (!SetProperty(ref _selectedProfile, value))
            {
                return;
            }

            _settings.LastSelectedProfileId = value?.Id;
            _store.SaveSettings(_settings);

            OnPropertyChanged(nameof(SelectedProfileName));
            OnPropertyChanged(nameof(SelectedProfileEngine));
            OnPropertyChanged(nameof(SelectedProfileAddress));
            OnPropertyChanged(nameof(SelectedProfileRoot));
            OnPropertyChanged(nameof(SelectedProfileCommand));
            OnPropertyChanged(nameof(SelectedProfileIssue));
            OnPropertyChanged(nameof(SelectedProfileIssueVisibility));
            OnPropertyChanged(nameof(SelectedProfileSummary));
            OnPropertyChanged(nameof(SelectedProfileStateBrush));
            RefreshStarterTemplates();
            RefreshProfileConfigFiles();
            OnPropertyChanged(nameof(SelectedProfileSetupMessage));
            OnPropertyChanged(nameof(SelectedProfilePrepareVisibility));
            OnPropertyChanged(nameof(SelectedProfilePhpVisibility));
            OnPropertyChanged(nameof(SelectedProfileNodeVisibility));
            OnPropertyChanged(nameof(SelectedProfileCustomVisibility));
            OnPropertyChanged(nameof(SelectedProfileRootVisibility));
            OnPropertyChanged(nameof(SelectedProfileStaticVisibility));
            OnPropertyChanged(nameof(SelectedProfileHttpsVisibility));
            OnPropertyChanged(nameof(SelectedProfileEngineOption));
            OnPropertyChanged(nameof(SelectedProfileGuideUrl));
            OnPropertyChanged(nameof(SelectedProfilePhpOption));
            OnPropertyChanged(nameof(SelectedProfilePhpStatus));
            OnPropertyChanged(nameof(SelectedProfilePhpInstallVisibility));
            OnPropertyChanged(nameof(SelectedProfileColor));
            OnPropertyChanged(nameof(SelectedProfileDefaultVisibility));
            OnPropertyChanged(nameof(SelectedProfileMakeDefaultVisibility));
            OnPropertyChanged(nameof(ProfilesEmptyVisibility));
            OnPropertyChanged(nameof(ProfilesEditorVisibility));
            NotifyControlDetails();
            var version = ++_profileCheckVersion;
            _ = CheckSelectedProfileAsync(version);
        }
    }

    public string SelectedProfileName => SelectedProfile?.Name ?? "";
    public ObservableCollection<ProfileConfigFile> ProfileConfigFiles { get; } = [];
    public string ProfileConfigFilesProblem
    {
        get => _profileConfigFilesProblem;
        private set
        {
            if (SetProperty(ref _profileConfigFilesProblem, value)) OnPropertyChanged(nameof(ProfileConfigFilesProblemVisibility));
        }
    }
    private string _profileConfigFilesProblem = "";
    public Visibility ProfileConfigFilesProblemVisibility => ProfileConfigFilesProblem.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProfileConfigFilesEmptyVisibility => ProfileConfigFiles.Count == 0 && ProfileConfigFilesProblem.Length == 0
        ? Visibility.Visible : Visibility.Collapsed;

    public void RefreshProfileConfigFiles()
    {
        ProfileConfigFiles.Clear();
        ProfileConfigFilesProblem = "";
        if (SelectedProfile is null) return;
        try
        {
            foreach (var file in ProfileConfigInventory.Collect(SelectedProfile)) ProfileConfigFiles.Add(file);
        }
        catch (Exception ex) { ProfileConfigFilesProblem = "Could not inspect configuration files: " + ex.Message; }
        finally { OnPropertyChanged(nameof(ProfileConfigFilesEmptyVisibility)); }
    }
    public Visibility SelectedProfileDefaultVisibility => SelectedProfile is not null && SelectedProfile.Id == _settings.DefaultProfileId
        ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileMakeDefaultVisibility => SelectedProfile is not null && SelectedProfile.Id != _settings.DefaultProfileId
        ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfilePhpVisibility => SelectedProfile?.Engine == "phpBuiltIn" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileNodeVisibility => SelectedProfile?.Engine == "nodeScript" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileCustomVisibility => SelectedProfile?.Engine == "custom" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileRootVisibility => SelectedProfile?.UsesRootDirectory == true ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileStaticVisibility => SelectedProfile?.Engine == "httpServer" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileHttpsVisibility => SelectedProfile?.SupportsHttps == true ? Visibility.Visible : Visibility.Collapsed;
    public string SelectedProfilePhpStatus
    {
        get
        {
            if (SelectedProfile is not { Engine: "phpBuiltIn" } profile) return "";
            var status = Dependencies.FirstOrDefault(item => item.Dependency.PhpVersion == profile.PhpVersion);
            if (status is null) return $"PHP {profile.PhpVersion} is not available in this version of ServerMaster.";
            if (status.Busy) return $"Preparing PHP {profile.PhpVersion}...";
            if (status.Checking || !status.Checked) return $"Checking PHP {profile.PhpVersion}...";
            if (status.Installed)
            {
                var version = string.IsNullOrWhiteSpace(status.Version) ? $"PHP {profile.PhpVersion}" : status.Version;
                return $"Installed: {version}" + (string.IsNullOrWhiteSpace(status.Path) ? "" : $"\n{status.Path}");
            }
            var detail = !string.IsNullOrWhiteSpace(status.Error) ? status.Error : status.Message;
            return $"PHP {profile.PhpVersion} is not installed." + (string.IsNullOrWhiteSpace(detail) ? "" : $" {detail}");
        }
    }
    public Visibility SelectedProfilePhpInstallVisibility
    {
        get
        {
            if (SelectedProfile is not { Engine: "phpBuiltIn" } profile) return Visibility.Collapsed;
            var status = Dependencies.FirstOrDefault(item => item.Dependency.PhpVersion == profile.PhpVersion);
            return status is null || !status.Checked || status.Installed || status.Checking || status.Busy ? Visibility.Collapsed : Visibility.Visible;
        }
    }
    public string SelectedProfileGuideUrl => "https://adm1nsys.github.io/ServerMaster/wiki.html" +
        (SelectedProfile?.Engine switch
        {
            "pythonHTTP" or "httpServer" or "nodeScript" => "#static",
            "phpBuiltIn" => "#php",
            _ => ""
        });
    public string SelectedProfileSetupMessage => SelectedProfile is not { } profile ? "Select a profile." :
        string.Join(Environment.NewLine, RequirementsFor(profile).Select(status => $"{status.Dependency.Title}: {status.StatusText}. {status.Error switch { { Length: > 0 } error => error, _ => status.Message }}"));
    public Visibility SelectedProfilePrepareVisibility => SelectedProfile is null || RequirementsFor(SelectedProfile).Any(status => !status.Installed || status.Busy || status.Checking)
        ? Visibility.Visible : Visibility.Collapsed;

    private IReadOnlyList<DependencyStatus> RequirementsFor(ServerProfile profile)
    {
        return ProfileRequirements.CommandsFor(profile)
            .Select(command => Dependencies.FirstOrDefault(status => status.Dependency.Command == command)).OfType<DependencyStatus>().ToList();
    }

    public EngineOption? SelectedProfileEngineOption
    {
        get => EngineOptions.FirstOrDefault(item => item.Id == SelectedProfile?.Engine);
        set { if (SelectedProfile is not null && value is not null && SelectedProfile.Engine != value.Id) SelectedProfile.Engine = value.Id; }
    }

    public EngineOption? SelectedProfilePhpOption
    {
        get => PhpVersionOptions.FirstOrDefault(item => item.Id == (SelectedProfile?.PhpVersion ?? "8.3"));
        set { if (SelectedProfile is not null && value is not null && SelectedProfile.PhpVersion != value.Id) SelectedProfile.PhpVersion = value.Id; }
    }

    public ColorOption? SelectedProfileColor
    {
        get => ProfileColors.FirstOrDefault(item => item.Id.Equals(SelectedProfile?.ProfileColor, StringComparison.OrdinalIgnoreCase)) ?? ProfileColors[0];
        set { if (SelectedProfile is not null && value is not null) { SelectedProfile.ProfileColor = value.Id; OnPropertyChanged(nameof(SelectedProfileColor)); } }
    }

    public void OpenUrl(string? url)
    {
        try { OpenUrlCore(url); }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    public void ReportTrayError(string message) => Notify("Notification area: " + message, true);
    public void ReportError(string message) => Notify(message, true);

    private void OpenUrlCore(string? url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
            Process.Start(new ProcessStartInfo(uri.ToString()) { UseShellExecute = true });
    }

    private async Task CheckSelectedProfileAsync(int version)
    {
        try
        {
            await Task.Delay(150);
            if (version != _profileCheckVersion) return;
            if (SelectedProfile is { } profile) await _dependencyManager.CheckAllAsync(RequirementsFor(profile));
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private async Task PrepareSelectedProfileAsync()
    {
        if (SelectedProfile is not { } profile) return;
        try
        {
            foreach (var status in RequirementsFor(profile))
            {
                await _dependencyManager.CheckAsync(status);
                if (!status.Installed) await InstallDependencyAsync(status);
            }
            Notify($"Software for {profile.Name} is ready.");
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private void UpdateDependencyUsage()
    {
        foreach (var status in Dependencies.Where(status => status.Dependency.PhpVersion.Length > 0))
        {
            var names = Profiles.Where(profile => profile.Engine == "phpBuiltIn" && profile.PhpVersion == status.Dependency.PhpVersion).Select(profile => profile.Name).ToList();
            status.RemovalBlockedReason = names.Count > 0 ? "Used by: " + string.Join(", ", names) : "";
        }
    }
    public string SelectedProfileEngine => SelectedProfile?.EngineTitle ?? "";
    public string SelectedProfileAddress => SelectedProfile?.Address ?? "";
    public string SelectedProfileRoot => SelectedProfile?.ExpandedRootPath ?? "";
    public string SelectedProfileCommand => SelectedProfile?.LastCommand ?? "";
    public string SelectedProfileIssue => SelectedProfile?.Failure ?? "";
    public Visibility SelectedProfileFailureVisibility => SelectedProfile?.HasFailure == true ? Visibility.Visible : Visibility.Collapsed;
    public IReadOnlyList<string> SelectedProfilePreflightIssues => SelectedProfile is { } profile
        ? profile.ValidationIssues().Concat(RequirementsFor(profile)
            .Where(status => status.Checked && !status.Checking && !status.Busy && !status.Installed)
            .Select(status => $"{status.Dependency.Title} is not available. {status.Message}")).ToArray() : [];
    public Visibility SelectedProfilePreflightVisibility => SelectedProfilePreflightIssues.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileIssueVisibility => SelectedProfile?.HasFailure == true || SelectedProfilePreflightIssues.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SelectedProfileDetailsVisibility => SelectedProfile is null ? Visibility.Collapsed : Visibility.Visible;
    public string SelectedProfilePid => SelectedProfile?.ProcessId?.ToString() ?? "";
    public Visibility SelectedProfilePidVisibility => SelectedProfile?.ProcessId is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility SelectedProfileCommandVisibility => SelectedProfileCommand.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ControlProfilesEmptyVisibility => Profiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProfilesEmptyVisibility => SelectedProfile is null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProfilesEditorVisibility => SelectedProfile is null ? Visibility.Collapsed : Visibility.Visible;
    public ObservableCollection<string> SelectedProfileUrls { get; } = [];
    public Visibility SelectedProfileUrlsVisibility => SelectedProfileUrls.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    private void RefreshDetectedUrls()
    {
        var urls = SelectedController?.DetectedUrls.ToArray() ?? [];
        if (SelectedProfileUrls.SequenceEqual(urls)) return;
        SelectedProfileUrls.Clear();
        foreach (var url in urls) SelectedProfileUrls.Add(url);
        OnPropertyChanged(nameof(SelectedProfileUrlsVisibility));
    }

    private void NotifyControlDetails()
    {
        RefreshDetectedUrls();
        foreach (var name in new[] { nameof(SelectedProfileIssue), nameof(SelectedProfileFailureVisibility),
            nameof(SelectedProfilePreflightIssues), nameof(SelectedProfilePreflightVisibility), nameof(SelectedProfileIssueVisibility),
            nameof(SelectedProfileDetailsVisibility), nameof(SelectedProfilePid), nameof(SelectedProfilePidVisibility),
            nameof(SelectedProfileCommandVisibility), nameof(SelectedProfileRootVisibility), nameof(SelectedProfileRoot),
            nameof(SelectedProfileName), nameof(SelectedProfileEngine), nameof(SelectedProfileAddress) }) OnPropertyChanged(name);
    }

    private void OpenSelectedRoot()
    {
        try
        {
            if (SelectedProfile is not { UsesRootDirectory: true } profile || !Directory.Exists(profile.ExpandedRootPath))
                throw new DirectoryNotFoundException("The profile's root folder does not exist.");
            Process.Start(new ProcessStartInfo(profile.ExpandedRootPath) { UseShellExecute = true });
        }
        catch (Exception ex) { Notify("Could not open site folder: " + ex.Message, true); }
    }

    private void RefreshDefaultMarks()
    {
        foreach (var profile in Profiles) profile.IsDefault = profile.Id == _settings.DefaultProfileId;
    }
    public string SelectedProfileSummary => SelectedProfile is null
        ? "No profile selected."
        : $"{SelectedProfile.EngineTitle} - {SelectedProfile.Address}";
    public Brush SelectedProfileStateBrush => BrushFor(SelectedProfile?.State ?? ServerState.Stopped);
    public Visibility ControlVisibility => SelectedSection == "Control" ? Visibility.Visible : Visibility.Collapsed;
    public bool CanStopAllServers => _crashRecovery.HasPending || _profileChecks.Count > 0 || Profiles.Any(profile => profile.IsActive) || _controllers.Values.Any(controller => controller.HasOwnedProcess);
    public Visibility StopAllVisibility => CanStopAllServers ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ProfilesVisibility => SelectedSection == "Profiles" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DependenciesVisibility => SelectedSection == "Dependencies" ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ConsoleVisibility => SelectedSection == "Console" ? Visibility.Visible : Visibility.Collapsed;
    public int ActiveCount => Profiles.Count(profile => profile.IsActive);
    public string ControlSubtitle => ActiveCount == 0 ? Localization.T("Nothing running. Pick a profile and press Start.") : RunningCountText;
    private string RunningCountText => ActiveCount == 1 ? "1 " + Localization.T("server running") : $"{ActiveCount} {Localization.T("servers running")}";
    public bool CanOpenAllProfiles => !_openingSites && Profiles.Any(profile => profile.IsRunning);
    public bool CanCopyAddresses => Profiles.Count > 0;
    public string ActiveStatusTitle => Localization.T(ActiveCount == 0 ? "Stopped" : "Running");
    public string ActiveStatusSubtitle => ActiveCount == 0 ? Localization.T("No servers running") : RunningCountText;
    public Brush ActiveStatusBrush => ActiveCount == 0 ? _muted : _green;
    public string LongestUptime
    {
        get
        {
            var running = Profiles.Where(profile => profile.StartedAt is not null && profile.State == ServerState.Running).ToList();
            if (running.Count == 0)
            {
                return "--";
            }

            var earliest = running.Min(profile => profile.StartedAt!.Value);
            var elapsed = DateTimeOffset.Now - earliest;
            return $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}";
        }
    }

    public bool IsBannerOpen
    {
        get => _isBannerOpen;
        set => SetProperty(ref _isBannerOpen, value);
    }

    public string BannerText
    {
        get => _bannerText;
        set => SetProperty(ref _bannerText, value);
    }

    public void SelectSection(string section)
    {
        SelectedSection = section;
    }

    public void SelectProfile(ServerProfile profile)
    {
        SelectedProfile = profile;
    }

    public void ShowProfileLogs(ServerProfile profile)
    {
        if (!Profiles.Contains(profile)) return;
        RefreshConsoleTabs(keep: profile);
        if (ConsoleTabs.FirstOrDefault(tab => tab.ProfileId == profile.Id) is { } tab) SelectConsoleTab(tab);
        SelectSection("Console");
    }

    public void CreateTerminalTab(string shellKind)
    {
        var tab = NewTerminalTab(shellKind);
        SelectConsoleTab(tab);
    }

    private ConsoleTab NewTerminalTab(string? shellKind = null)
    {
        shellKind ??= DefaultTerminalShell;
        var tab = new ConsoleTab { Title = $"Terminal {ConsoleTabs.Count(item => item.IsTerminal) + 1}", IsTerminal = true, ShellKind = shellKind };
        var directory = SelectedProfile?.EffectiveWorkingDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        tab.Session = new TerminalSession(shellKind, directory);
        tab.Session.Output += text => _dispatcher.TryEnqueue(() =>
        {
            tab.TerminalText += text;
            if (tab.TerminalText.Length > 1_000_000) tab.TerminalText = tab.TerminalText[^1_000_000..];
            if (ReferenceEquals(tab, SelectedConsoleTab)) NotifyConsoleStatus(); // the shell may have exited
        });
        ConsoleTabs.Add(tab);
        try { tab.Session.Start(); } catch (Exception ex) { tab.TerminalText = "Could not start terminal: " + ex.Message; }
        return tab;
    }

    public void SelectConsoleTab(ConsoleTab tab)
    {
        if (!ConsoleTabs.Contains(tab)) return;
        SelectedConsoleTab = tab;
        if (tab.IsTerminal) ShellKind = tab.ShellKind;
    }

    public void SendTerminalCommand(string command)
    {
        if (SelectedConsoleTab?.Session is not { } session) return;
        try { session.WriteLine(command); }
        catch (Exception ex) { SelectedConsoleTab.TerminalText += Environment.NewLine + ex.Message + Environment.NewLine; }
    }

    public void RestartTerminal(ConsoleTab? tab = null)
    {
        tab ??= SelectedConsoleTab;
        if (tab?.Session is not { } session) return;
        try { session.Restart(); }
        catch (Exception ex) { tab.TerminalText += Environment.NewLine + ex.Message + Environment.NewLine; }
        NotifyConsoleStatus();
    }

    /// <summary>Ctrl+C for the command running in the selected terminal tab.</summary>
    public async Task InterruptTerminalAsync()
    {
        if (SelectedConsoleTab is not { Session: { } session } tab) return;
        try
        {
            if (!await session.InterruptAsync()) { Notify(Localization.T("Could not interrupt the command."), true); return; }
            // PowerShell drops the rest of the interrupted line, including the prompt marker.
            tab.TerminalText += "^C" + Environment.NewLine + (session.ShellKind == "PowerShell" ? "> " : "");
        }
        catch (Exception ex) { Notify(Localization.T("Could not interrupt the command.") + " " + ex.Message, true); }
    }

    /// <summary>An empty name says nothing, so it falls back to the tab number like macOS.</summary>
    public void RenameConsoleTab(ConsoleTab tab, string name)
    {
        if (!tab.IsTerminal) return;
        var number = ConsoleTabs.Where(item => item.IsTerminal).ToList().IndexOf(tab) + 1;
        tab.Title = string.IsNullOrWhiteSpace(name) ? $"Terminal {number}" : name.Trim();
        OnPropertyChanged(nameof(ConsoleTabSubtitle));
    }

    /// <summary>Changes the selected terminal's directory to the selected profile's working directory.</summary>
    public void GoToProfileRoot()
    {
        if (SelectedConsoleTab is not { IsTerminal: true, Session: { } session } || SelectedProfile?.EffectiveWorkingDirectory is not { Length: > 0 } directory) return;
        SendTerminalCommand(session.ShellKind == "PowerShell"
            ? $"Set-Location -LiteralPath '{directory.Replace("'", "''")}'"
            : $"cd /d \"{directory}\"");
    }

    public string ConsoleExternalDirectory =>
        (ConsoleProfile ?? SelectedProfile)?.EffectiveWorkingDirectory is { Length: > 0 } directory && Directory.Exists(directory)
            ? directory : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Opens Windows Terminal when installed, otherwise the default shell, in the tab's folder.</summary>
    public void OpenExternalTerminal()
    {
        var directory = ConsoleExternalDirectory;
        try
        {
            var terminal = ShellEnvironment.Shared.Which("wt");
            var info = terminal is not null
                ? new ProcessStartInfo(terminal) { ArgumentList = { "-d", directory } }
                : new ProcessStartInfo(DefaultTerminalShell == "CMD" ? "cmd.exe" : "powershell.exe") { WorkingDirectory = directory };
            info.UseShellExecute = terminal is null;
            Process.Start(info);
        }
        catch (Exception ex) { Notify(Localization.T("Could not open the terminal.") + " " + ex.Message, true); }
    }

    private void CloseConsoleTab(ConsoleTab? tab)
    {
        if (tab is null || !tab.IsTerminal || ConsoleTabs.Count(item => item.IsTerminal) <= 1) return;
        tab.Session?.Dispose();
        ConsoleTabs.Remove(tab);
        if (ReferenceEquals(SelectedConsoleTab, tab)) SelectConsoleTab(ConsoleTabs.First(item => item.IsTerminal));
    }

    /// <summary>A server gets a log tab while it is active or has something in its log.</summary>
    private bool HasConsoleLog(ServerProfile profile) =>
        profile.IsActive || (_controllers.TryGetValue(profile.Id, out var controller) && controller.Log.Lines.Count > 0);

    private void RefreshConsoleTabs(ServerProfile? keep = null)
    {
        foreach (var tab in ConsoleTabs.Where(item => !item.IsTerminal && (item.Profile is not { } profile || !Profiles.Contains(profile)
                     || (!HasConsoleLog(profile) && !ReferenceEquals(profile, keep) && !ReferenceEquals(item, SelectedConsoleTab)))).ToList())
        {
            ConsoleTabs.Remove(tab);
            if (ReferenceEquals(tab, SelectedConsoleTab)) SelectedConsoleTab = ConsoleTabs.FirstOrDefault(item => item.IsTerminal);
        }
        foreach (var profile in Profiles.Where(profile => HasConsoleLog(profile) || ReferenceEquals(profile, keep)))
        {
            if (ConsoleTabs.All(item => item.ProfileId != profile.Id))
                ConsoleTabs.Add(new ConsoleTab { Profile = profile });
        }
        OnPropertyChanged(nameof(ConsoleTabLines));
    }

    /// <summary>A server that has just started comes to the front unless a log is already shown.</summary>
    private void OnConsoleProfileStateChanged(ServerProfile profile)
    {
        RefreshConsoleTabs();
        if (profile.State == ServerState.Starting && SelectedConsoleTab?.IsTerminal != false
            && ConsoleTabs.FirstOrDefault(tab => tab.ProfileId == profile.Id) is { } started)
            SelectConsoleTab(started);
        if (SelectedConsoleTab?.ProfileId == profile.Id) NotifyConsoleStatus();
    }

    public void Save()
    {
        _store.SaveProfiles(Profiles);
        _store.SaveSettings(_settings);
    }

    public void RefreshFiles()
    {
        FileEntries.Clear();
        FilesProblem = "";
        try
        {
            var root = FilesProfile?.ExpandedRootPath;
            if (string.IsNullOrWhiteSpace(root)) { FilesPath = ""; _filesRoot = ""; FilesProblem = "Select a profile with a root folder."; return; }
            root = Path.GetFullPath(root);
            if (_filesRoot != root || string.IsNullOrEmpty(FilesPath) || !SiteFiles.IsWithinWithoutLinks(root, FilesPath)) FilesPath = root;
            _filesRoot = root;
            foreach (var entry in SiteFiles.Read(root, FilesPath)) FileEntries.Add(entry);
        }
        catch (Exception ex) { FilesProblem = "Could not read this folder: " + ex.Message; }
        finally
        {
            OnPropertyChanged(nameof(HiddenFileEntries));
            OnPropertyChanged(nameof(VisibleFileEntries));
            OnPropertyChanged(nameof(HiddenFilesVisibility));
            OnPropertyChanged(nameof(FilesProblemVisibility));
            OnPropertyChanged(nameof(FilesEmptyVisibility));
            OnPropertyChanged(nameof(FilesRoot));
            OnPropertyChanged(nameof(FilesPath));
            OnPropertyChanged(nameof(AllFilesToggleText));
        }
    }

    public void NavigateFiles(string path)
    {
        if (_filesRoot.Length == 0 || !SiteFiles.IsWithinWithoutLinks(_filesRoot, path))
        {
            Notify("Linked folders cannot be browsed inside ServerMaster. Open the folder in Explorer instead.", true);
            return;
        }
        FilesPath = path;
        RefreshFiles();
    }

    private void OpenFilesFolder()
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{FilesPath}\"")); }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private void GoUpFiles()
    {
        var parent = Directory.GetParent(FilesPath)?.FullName;
        var root = FilesProfile?.ExpandedRootPath;
        if (parent is not null && !string.IsNullOrWhiteSpace(root) && SiteFiles.IsWithin(root, parent)) NavigateFiles(parent);
    }

    private void OpenFile(FileEntry? entry)
    {
        if (entry is null) return;
        try
        {
            if (entry.IsDirectory) { FilesPath = entry.FullPath; RefreshFiles(); }
            else Process.Start(new ProcessStartInfo(entry.FullPath) { UseShellExecute = true });
        }
        catch (Exception ex) { Notify("Could not open item: " + ex.Message, true); }
    }

    private void RefreshBackups()
    {
        BackupEntries.Clear();
        foreach (var entry in ProfileSnapshots.Load(BackupDestination)) BackupEntries.Add(entry);
        NotifyBackupState();
    }

    private static string BackupHistory(IEnumerable<BackupEntry> entries)
    {
        var ordered = entries.OrderByDescending(item => item.Taken).ToArray();
        return ordered.Length == 0 ? Localization.T("never") : $"{ordered.Length} - {Localization.T("newest")} {ordered[0].Taken.ToLocalTime():g}";
    }

    private void NotifyBackupState()
    {
        var databaseRunning = DatabaseStatus.Running;
        foreach (var entry in BackupEntries)
            entry.CanRestore = entry.Kind == "database" ? databaseRunning : Profiles.Any(profile => profile.Id == entry.ProfileId);
        foreach (var name in new[] { nameof(CanCreateBackups), nameof(CanSnapshotProfiles), nameof(CanSnapshotDatabase),
            nameof(BackupWorkVisibility), nameof(BackupProfiles), nameof(BackupDatabases), nameof(BackupProfilesEmptyVisibility),
            nameof(BackupEntriesEmptyVisibility), nameof(BackupDatabaseMessageVisibility), nameof(BackupDatabaseMessage), nameof(ScheduledBackupProfilesSummary) })
            OnPropertyChanged(name);
        OnPropertyChanged(nameof(CanResetSettings));
    }

    private async Task<List<string>> CreateBackupsAsync(IReadOnlyList<ServerProfile> profiles, string trigger = "manual", bool notify = true)
    {
        if (_backupsBusy || (_scheduledBackupCheckBusy && trigger != "scheduled")) return [];
        if (profiles.Count == 0) { Notify("Select a profile first.", true); return ["No profiles to snapshot."]; }
        BackupProblem = "";
        _backupsBusy = true;
        NotifyBackupState();
        var completed = 0;
        var problems = new List<string>();
        try
        {
            foreach (var profile in profiles)
            {
                try
                {
                    var snapshot = await ProfileSnapshots.CreateProfileAsync(profile, BackupDestination, BackupIncludesDatabase, trigger);
                    completed++;
                    if (!string.IsNullOrWhiteSpace(snapshot.Note)) problems.Add(profile.Name + ": " + snapshot.Note);
                }
                catch (Exception ex) { problems.Add(profile.Name + ": " + ex.Message); }
            }
            RefreshBackups();
            BackupProblem = problems.Count > 0 ? string.Join(Environment.NewLine, problems) : "";
            if (notify) Notify($"Snapshots created: {completed}." + (problems.Count > 0 ? Environment.NewLine + string.Join(Environment.NewLine, problems) : ""), problems.Count > 0);
        }
        catch (Exception ex) { problems.Add(ex.Message); BackupProblem = ex.Message; if (notify) Notify("Could not create backup: " + ex.Message, true); }
        finally { _backupsBusy = false; NotifyBackupState(); }
        return problems;
    }

    private async Task CheckScheduledBackupsAsync()
    {
        if (!BackupsEnabled || _scheduledBackupCheckBusy || _backupsBusy) return;
        var unit = BackupUnit switch
        {
            "minutes" => TimeSpan.FromMinutes(BackupEvery), "hours" => TimeSpan.FromHours(BackupEvery),
            "weeks" => TimeSpan.FromDays(BackupEvery * 7d), "months" => TimeSpan.FromDays(BackupEvery * 30.4368),
            "years" => TimeSpan.FromDays(BackupEvery * 365.2425), _ => TimeSpan.FromDays(BackupEvery)
        };
        if (_settings.LastBackup is { } last && DateTimeOffset.Now - last < unit) return;
        _scheduledBackupCheckBusy = true;
        NotifyBackupState();
        try
        {
            var targets = SettingsBehavior.ScheduledProfiles(_settings, Profiles);
            if (targets.Count == 0 && !BackupAllDatabases) return;
            var problems = targets.Count > 0 ? await CreateBackupsAsync(targets, "scheduled", notify: false) : new List<string>();
            if (BackupAllDatabases)
            {
                if (!DatabaseService.Detect().Running) problems.Add("Database snapshots skipped: MariaDB was stopped.");
                else foreach (var database in await DatabaseService.ListDatabasesAsync())
                {
                    try { await ProfileSnapshots.CreateDatabaseAsync(database.Name, BackupDestination, "scheduled"); }
                    catch (Exception ex) { problems.Add(database.Name + ": " + ex.Message); }
                }
            }
            ProfileSnapshots.PruneScheduled(BackupDestination, BackupsToKeep);
            _settings.LastBackup = DateTimeOffset.Now;
            SaveSettings();
            OnPropertyChanged(nameof(LastBackupText));
            RefreshBackups();
            Notify("Automatic snapshots completed." + (problems.Count > 0 ? Environment.NewLine + string.Join(Environment.NewLine, problems) : ""), problems.Count > 0);
        }
        catch (Exception ex) { Notify("Automatic snapshots failed: " + ex.Message, true); }
        finally { _scheduledBackupCheckBusy = false; NotifyBackupState(); }
    }

    public void SetBackupDestination(string path)
    {
        if (!CanCreateBackups) { Notify("Wait for the snapshot operation to finish before changing its folder.", true); return; }
        Directory.CreateDirectory(AppPaths.Expand(path));
        _settings.BackupDestination = path;
        SaveSettings();
        OnPropertyChanged(nameof(BackupDestination));
        RefreshBackups();
    }

    public bool NeedsFirstSetup { get; private set; }

    public void CompleteFirstSetup()
    {
        NeedsFirstSetup = false;
        _settings.FirstSetupCompleted = true;
        SaveSettings();
    }

    // The loading screen from macOS SplashView: shown until the launch checks finish.
    private bool _isBootstrapping = true;
    private string _bootstrapStage = "";
    private double _bootstrapProgress;
    public bool IsBootstrapping { get => _isBootstrapping; private set { if (SetProperty(ref _isBootstrapping, value)) { OnPropertyChanged(nameof(SplashVisibility)); OnPropertyChanged(nameof(ShellVisibility)); } } }
    public Visibility SplashVisibility => IsBootstrapping ? Visibility.Visible : Visibility.Collapsed;
    /// <summary>The splash shows the moving background through it, so the app stays hidden until it is ready.</summary>
    public Visibility ShellVisibility => IsBootstrapping ? Visibility.Collapsed : Visibility.Visible;
    public string BootstrapStage { get => _bootstrapStage; private set => SetProperty(ref _bootstrapStage, value); }
    public double BootstrapProgress { get => _bootstrapProgress; private set => SetProperty(ref _bootstrapProgress, value); }
    public string SplashVersionLine => $"{Localization.T("Version")} {CurrentAppVersion}";

    private async Task BootstrapStageAsync(string stage, double progress)
    {
        BootstrapStage = Localization.T(stage);
        BootstrapProgress = progress;
        await Task.Delay(120); // let the frame draw, otherwise the steps flash by unnoticed
    }

    public async Task InitializeAsync()
    {
        try
        {
            await BootstrapStageAsync("Reading the environment…", 15);
            if (CheckDependenciesOnLaunch && !_dependenciesLoaded)
            {
                await BootstrapStageAsync("Checking dependencies…", 35);
                _dependenciesLoaded = true;
                // The window is never held behind the loading screen; a slow check finishes in the background.
                var check = CheckDependenciesAsync();
                await Task.WhenAny(check, Task.Delay(TimeSpan.FromSeconds(30)));
            }
            if (CheckUpdatesOnLaunch)
            {
                await BootstrapStageAsync("Checking for updates…", 85);
                await CheckForUpdatesAsync(silent: true).WaitAsync(TimeSpan.FromSeconds(20)).ContinueWith(_ => { });
            }
            await BootstrapStageAsync("Done", 100);
        }
        finally { IsBootstrapping = false; }
        EnterSection(SelectedSection);
        if (!NeedsFirstSetup && AutostartDefaultProfile && DefaultProfile is { IsActive: false } profile) await StartStopProfileAsync(profile);
    }

    public async Task CheckForUpdatesAsync(bool silent = false)
    {
        if (UpdateChecking) return;
        UpdateChecking = true;
        _updateReleaseUrl = "";
        OnPropertyChanged(nameof(UpdateReleaseVisibility));
        UpdateStatus = "Checking for updates...";
        try
        {
            var result = await _updateChecker.CheckAsync(UpdateRepository, UpdateVersionFile, UpdateBuildsFolder, CurrentAppVersion);
            _settings.LastUpdateCheck = DateTimeOffset.UtcNow;
            UpdateStatus = result.Message;
            _updateReleaseUrl = result.ReleaseUrl;
            if (result.Kind == UpdateCheckKind.Available && result.Version != _settings.DismissedUpdateVersion)
            {
                _availableUpdateVersion = result.Version;
                var builds = AppPaths.Expand(UpdateBuildsFolder);
                if (!Path.IsPathRooted(builds)) builds = Path.GetFullPath(builds, Environment.CurrentDirectory);
                _availableUpdateBuildPath = Path.Combine(builds, result.Version);
            }
            else
            {
                _availableUpdateVersion = "";
                _availableUpdateBuildPath = "";
            }
            SaveSettings();
            OnPropertyChanged(nameof(UpdateReleaseVisibility));
            NotifyUpdateBanner();
            if (result.Kind == UpdateCheckKind.Available && result.Version != _settings.DismissedUpdateVersion)
                Notify(result.Message);
            else if (!silent && result.Kind is UpdateCheckKind.Failed or UpdateCheckKind.NotConfigured)
                Notify(result.Message, true);
        }
        catch (Exception ex)
        {
            UpdateStatus = "Could not check for updates: " + ex.Message;
            if (!silent) Notify(UpdateStatus, true);
        }
        finally { UpdateChecking = false; }
    }

    public void OpenUpdateRepository() => OpenUrl("https://github.com/" + UpdateChecker.NormalizeRepository(UpdateRepository));
    public void OpenUpdateRelease() => OpenUrl(_updateReleaseUrl);
    public void OpenAvailableUpdate()
    {
        if (Directory.Exists(_availableUpdateBuildPath))
        {
            try { Process.Start(new ProcessStartInfo(_availableUpdateBuildPath) { UseShellExecute = true }); }
            catch (Exception ex) { Notify("Could not open the build folder: " + ex.Message, true); }
        }
        else if (_updateReleaseUrl.Length > 0) OpenUpdateRelease();
        else OpenUpdateRepository();
    }
    public void DismissAvailableUpdate()
    {
        if (_availableUpdateVersion.Length == 0) return;
        _settings.DismissedUpdateVersion = _availableUpdateVersion;
        _availableUpdateVersion = "";
        _availableUpdateBuildPath = "";
        SaveSettings();
        NotifyUpdateBanner();
    }

    private void NotifyUpdateBanner()
    {
        foreach (var name in new[] { nameof(UpdateBannerVisibility), nameof(UpdateBannerTitle),
            nameof(UpdateBannerMessage), nameof(UpdateBannerActionText) }) OnPropertyChanged(name);
    }

    private void NotifyUpdateConfiguration()
    {
        _updateReleaseUrl = "";
        _availableUpdateVersion = "";
        _availableUpdateBuildPath = "";
        UpdateStatus = "Settings changed. Select Check now to use them.";
        foreach (var name in new[] { nameof(UpdateConfigured), nameof(UpdateVersionSource), nameof(CanCheckForUpdates),
            nameof(UpdateReleaseVisibility), nameof(UpdateConfigurationVisibility), nameof(UpdateConfigurationProblemVisibility) }) OnPropertyChanged(name);
        NotifyUpdateBanner();
    }

    public async Task CleanOldLogsAsync(bool report = false)
    {
        if (_logCleanupBusy || _shuttingDown) return;
        _logCleanupBusy = true;
        _lastLogCleanup = DateTimeOffset.UtcNow;
        try
        {
            if (LogRetentionDays <= 0)
            {
                if (report) Notify("Log cleanup is disabled. Set a retention period above 0 days to remove old logs.");
                return;
            }
            var active = _controllers.Values.Select(controller => controller.Log.FilePath).OfType<string>().ToArray();
            var days = LogRetentionDays;
            var directory = AppPaths.Logs;
            var result = await Task.Run(() => LogRetention.Clean(directory, days, active));
            if (report || result.Problems.Count > 0)
                Notify($"Removed {result.Removed} old log files." + (result.Problems.Count > 0 ? "\n" + string.Join("\n", result.Problems) : ""), result.Problems.Count > 0);
        }
        catch (Exception ex) { Notify("Could not clean old logs: " + ex.Message, true); }
        finally { _logCleanupBusy = false; }
    }

    private async Task CreateDatabaseBackupAsync(string? name)
    {
        if (!CanSnapshotDatabase || string.IsNullOrWhiteSpace(name)) return;
        BackupProblem = "";
        _backupsBusy = true;
        NotifyBackupState();
        try
        {
            await ProfileSnapshots.CreateDatabaseAsync(name, BackupDestination);
            RefreshBackups();
            Notify($"Snapshot of database \"{name}\" created.");
        }
        catch (Exception ex) { BackupProblem = ex.Message; Notify("Could not create database snapshot: " + ex.Message, true); }
        finally { _backupsBusy = false; NotifyBackupState(); }
    }

    private void DeleteBackup(BackupEntry? backup)
    {
        if (backup is null || !CanCreateBackups) return;
        try { BackupProblem = ""; ProfileSnapshots.Delete(BackupDestination, backup); RefreshBackups(); }
        catch (Exception ex) { BackupProblem = ex.Message; Notify("Could not delete backup: " + ex.Message, true); }
    }

    public async Task RestoreBackupAsync(BackupEntry backup, ServerProfile profile, bool settings, bool files, bool database)
    {
        if (!CanCreateBackups) return;
        if (!settings && !files && !database) { Notify("Select at least one part of the snapshot to restore.", true); return; }
        BackupProblem = "";
        _backupsBusy = true;
        NotifyBackupState();
        string? previous = null;
        var siteRestored = false;
        var databaseAttempted = false;
        var databaseRestored = false;
        var settingsApplied = false;
        try
        {
            if (Profiles.Any(item => item.IsActive)) throw new InvalidOperationException("Stop servers before restoring a snapshot.");
            if (backup.Kind == "database")
            {
                if (!database) throw new InvalidOperationException("Select the database to restore.");
                if (!DatabaseService.Detect().Running) throw new InvalidOperationException("Start MariaDB before restoring a database snapshot.");
                databaseAttempted = true;
                await ProfileSnapshots.RestoreDatabaseAsync(backup);
                databaseRestored = true;
                await RefreshDatabaseAsync();
                Notify("Database snapshot restored.");
                return;
            }
            if (database && backup.IncludesDatabase && !DatabaseService.Detect().Running)
                throw new InvalidOperationException("Start MariaDB before restoring the database. No profile files were changed.");
            if (files && backup.IncludesSite && !File.Exists(Path.Combine(backup.FullPath, "site.zip")))
                throw new FileNotFoundException("The site archive is missing. No profile files were changed.");
            if (database && backup.IncludesDatabase && !File.Exists(Path.Combine(backup.FullPath, "database.sql")))
                throw new FileNotFoundException("The database dump is missing. No profile files were changed.");
            if (!Profiles.Contains(profile)) throw new InvalidOperationException("The profile belonging to this snapshot no longer exists.");
            var restored = settings ? ProfileSnapshots.ReadProfile(backup) : profile;
            if (files && backup.IncludesSite)
            {
                previous = await ProfileSnapshots.RestoreSiteAsync(backup, restored.ExpandedRootPath);
                siteRestored = true;
            }
            if (database && backup.IncludesDatabase)
            {
                databaseAttempted = true;
                await ProfileSnapshots.RestoreDatabaseAsync(backup);
                databaseRestored = true;
            }
            if (settings)
            {
                restored.Id = profile.Id;
                var index = Profiles.IndexOf(profile);
                profile.PropertyChanged -= Profile_PropertyChanged;
                restored.PropertyChanged += Profile_PropertyChanged;
                Profiles[index] = restored;
                settingsApplied = true;
                profile = restored;
                SelectedProfile = restored;
                SaveProfiles();
            }
            RefreshFiles();
            if (databaseRestored) await RefreshDatabaseAsync();
            Notify("Snapshot restored." + (previous is null ? "" : " Previous files were preserved at: " + previous));
        }
        catch (Exception ex)
        {
            var changed = siteRestored || databaseRestored || settingsApplied;
            var prefix = databaseAttempted && !databaseRestored
                ? "Database restore did not finish; some SQL statements may have applied: "
                : changed ? "Restore stopped after changing data: " : "Restore failed before changing data: ";
            BackupProblem = prefix + ex.Message;
            Notify(prefix + ex.Message
                + (previous is null ? "" : " Previous site files are at: " + previous), true);
        }
        finally { _backupsBusy = false; NotifyBackupState(); }
    }

    private void OpenBackupsFolder()
    {
        try { Directory.CreateDirectory(BackupDestination); Process.Start(new ProcessStartInfo("explorer.exe", $"\"{BackupDestination}\"")); }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private void AddPathEntry()
    {
        var path = AppPaths.Expand(NewPathEntry).Trim();
        if (path.Length == 0 || ExtraPathEntries.Any(item => item.Equals(path, StringComparison.OrdinalIgnoreCase))) return;
        ExtraPathEntries.Add(path);
        ShellEnvironment.Shared.SetExtraEntries(ExtraPathEntries);
        NewPathEntry = "";
        SaveSettings();
    }

    private void RemovePathEntry(string? path)
    {
        if (path is null) return;
        ExtraPathEntries.Remove(path);
        ShellEnvironment.Shared.SetExtraEntries(ExtraPathEntries);
        SaveSettings();
    }

    private void SaveSettings([CallerMemberName] string propertyName = "")
    {
        _settings.ExtraPathEntries = ExtraPathEntries.ToList();
        _store.SaveSettings(_settings);
        OnPropertyChanged(propertyName);
        if (propertyName == nameof(ConsoleBufferLines))
            foreach (var controller in _controllers.Values) controller.Log.Limit = _settings.ConsoleBufferLines;
        if (propertyName == nameof(WriteLogsToFile)) ApplyFileLoggingPreference();
    }

    private void ApplyFileLoggingPreference()
    {
        foreach (var controller in _controllers.Values)
        {
            if (!WriteLogsToFile) controller.Log.StopFileLogging();
            else if (controller.ActiveProfile is { IsActive: true } profile && !controller.Log.IsFileLogging)
                controller.Log.StartFileLogging(profile.Name);
        }
    }

    private static string SanitizeFileName(string value)
    {
        foreach (var character in Path.GetInvalidFileNameChars()) value = value.Replace(character, '_');
        return string.IsNullOrWhiteSpace(value) ? "profile" : value;
    }

    private async Task RunShellCommandAsync()
    {
        if (!CanRunShell) return;
        _shellCancellation?.Cancel();
        using var cancellation = new CancellationTokenSource();
        _shellCancellation = cancellation;
        var command = ShellCommandText.Trim();
        var executable = ShellKind == "CMD" ? "cmd.exe" : "powershell.exe";
        var arguments = ShellKind == "CMD"
            ? $"/d /s /c \"{command.Replace("\\\"", "\\\\\"")}\""
            : $"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new(); {command.Replace("\\\"", "\\\\\"")}\"";
        var startInfo = new ProcessStartInfo(executable, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            WorkingDirectory = SelectedProfile?.EffectiveWorkingDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        foreach (var pair in ShellEnvironment.Shared.EnvironmentFor()) startInfo.Environment[pair.Key] = pair.Value;
        ShellLines.Add(new LogLine { Stream = LogStream.Command, Text = $"> {ShellKind}: {command}" });
        ShellBusy = true;
        try
        {
            using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.Start();
            OwnedProcesses.Track(process);
            _shellProcess = process;
            var stdout = PumpShellOutputAsync(process.StandardOutput, LogStream.Stdout, cancellation.Token);
            var stderr = PumpShellOutputAsync(process.StandardError, LogStream.Stderr, cancellation.Token);
            await process.WaitForExitAsync(cancellation.Token);
            await Task.WhenAll(stdout, stderr);
            ShellLines.Add(new LogLine { Stream = LogStream.System, Text = $"Exit code: {process.ExitCode}" });
        }
        catch (OperationCanceledException)
        {
            ShellLines.Add(new LogLine { Stream = LogStream.System, Text = "Command stopped." });
        }
        catch (Exception ex)
        {
            ShellLines.Add(new LogLine { Stream = LogStream.Stderr, Text = ex.Message });
        }
        finally
        {
            ShellBusy = false;
            _shellProcess = null;
            if (ReferenceEquals(_shellCancellation, cancellation)) _shellCancellation = null;
        }
    }

    private async Task PumpShellOutputAsync(StreamReader reader, LogStream stream, CancellationToken token)
    {
        while (!reader.EndOfStream)
        {
            var line = await reader.ReadLineAsync(token);
            if (line is not null) ShellLines.Add(new LogLine { Stream = stream, Text = line });
        }
    }

    private async Task RefreshPortsAsync()
    {
        if (PortsScanning) return;
        PortsProblem = "";
        PortsScanning = true;
        _lastPortRefresh = DateTime.UtcNow;
        try
        {
            _allPortEntries = await WindowsPortScanner.ScanAsync(PortsIncludeUdp);
            ApplyPortFilters();
        }
        catch (Exception ex) { PortsSummary = "Could not scan ports."; PortsProblem = ex.Message; Notify(ex.Message, true); }
        finally { PortsScanning = false; }
    }

    private void ApplyPortFilters()
    {
        var query = PortSearchText.Trim();
        var filtered = _allPortEntries.Where(entry =>
            (PortsShowSystemProcesses || !entry.IsSystemProcess) &&
            (query.Length == 0 || entry.Port.ToString().Contains(query, StringComparison.OrdinalIgnoreCase) ||
             entry.ProcessId.ToString().Contains(query, StringComparison.OrdinalIgnoreCase) ||
             entry.ProcessName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             entry.Address.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             entry.Protocol.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        PortEntries.Clear();
        foreach (var entry in filtered) PortEntries.Add(entry);
        PortsSummary = $"{filtered.Length} {Localization.T("of")} {_allPortEntries.Count} {Localization.T("sockets")} - {DateTime.Now:t}";
        OnPropertyChanged(nameof(PortsEmptyVisibility));
    }

    private async Task ReservePortAsync()
    {
        try
        {
            if (!PortReservationsEnabled) throw new InvalidOperationException("Enable port reservations in Settings first.");
            if (!int.TryParse(ReservePortText.Trim(), out var port)) throw new InvalidOperationException("Enter a numeric port from 1 to 65535.");
            var reservation = _portReserver.Reserve(port, ReservePortNote);
            PortReservations.Add(reservation);
            ReservePortText = "";
            ReservePortNote = "";
            await RefreshPortsAsync();
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private async Task ReleasePortAsync(PortReservation? reservation)
    {
        if (reservation is null) return;
        _portReserver.Release(reservation.Port);
        PortReservations.Remove(reservation);
        await RefreshPortsAsync();
    }

    private void OpenPort(PortEntry? entry)
    {
        if (entry is null) return;
        if (!entry.CanOpenInBrowser) { Notify("UDP ports cannot be opened in a browser.", true); return; }
        if (_portReserver.IsReserved(entry.Port)) { Notify("This port is reserved by ServerMaster. Release it before opening a site.", true); return; }
        try { Process.Start(new ProcessStartInfo(entry.LocalUrl) { UseShellExecute = true }); }
        catch (Exception ex) { Notify("Could not open the port: " + ex.Message, true); }
    }

    private async Task ShowPortDetailsAsync(PortEntry? entry)
    {
        if (entry is null || SelectedWindow is not { } window) return;
        try
        {
            var details = await Task.Run(() => WindowsPortScanner.Details(entry));
            var result = await new ContentDialog { XamlRoot = window.Content.XamlRoot, Title = "Process details",
                Content = new TextBox { Text = details, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Width = 540, MinHeight = 150 },
                PrimaryButtonText = "Copy PID",
                CloseButtonText = "Close" }.ShowAsync();
            if (result == ContentDialogResult.Primary) CopyText(entry.ProcessId.ToString());
        }
        catch (Exception ex) { Notify("Could not read process details: " + ex.Message, true); }
    }

    private async Task TerminatePortAsync(PortEntry? entry)
    {
        if (entry is null) return;
        try
        {
            if (!entry.CanTerminate) throw new InvalidOperationException("Windows system processes and ServerMaster cannot be terminated here.");
            if (ConfirmBeforeKill)
            {
                var dialog = new ContentDialog { Title = "Terminate process?", Content = $"{entry.Description} is listening on {entry.Protocol} {entry.DisplayAddress}:{entry.Port}.", PrimaryButtonText = "Terminate", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
                if (SelectedWindow is { } window) { dialog.XamlRoot = window.Content.XamlRoot; if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; }
            }
            if (!(await WindowsPortScanner.ScanAsync(entry.Protocol == "UDP")).Any(current => current.ProcessId == entry.ProcessId &&
                current.Port == entry.Port && current.Protocol == entry.Protocol && current.Address == entry.Address))
                throw new InvalidOperationException("This process no longer owns the selected port. Refresh the list before trying again.");
            try { await Task.Run(() => WindowsPortScanner.Terminate(entry)); }
            catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 5)
            {
                if (SelectedWindow is not { } window) throw;
                var prompt = new ContentDialog { XamlRoot = window.Content.XamlRoot,
                    Title = "Administrator permission required",
                    Content = $"Windows denied access to {entry.Description}. Request administrator permission to force-stop this process?",
                    PrimaryButtonText = "Request permission", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
                if (await prompt.ShowAsync() != ContentDialogResult.Primary) return;
                if (!(await WindowsPortScanner.ScanAsync(entry.Protocol == "UDP")).Any(current => current.ProcessId == entry.ProcessId &&
                    current.Port == entry.Port && current.Protocol == entry.Protocol && current.Address == entry.Address))
                    throw new InvalidOperationException("This process no longer owns the selected port. Refresh the list before trying again.");
                try { await WindowsPortScanner.TerminateAsAdministratorAsync(entry); }
                catch (System.ComponentModel.Win32Exception cancel) when (cancel.NativeErrorCode == 1223)
                {
                    Notify("Administrator request was cancelled.");
                    return;
                }
            }
            Notify($"Terminated {entry.Description}.");
            await RefreshPortsAsync();
        }
        catch (Exception ex) { Notify("Could not terminate the process: " + ex.Message, true); }
    }

    public Window? SelectedWindow { get; set; }

    public IReadOnlyList<StarterTemplate> StarterTemplatesForSelectedProfile()
    {
        return SelectedProfile is null ? [] : StarterTemplate.For(SelectedProfile);
    }

    public int SuggestedPort => NextPort();

    public string SuggestedFolder(ProfileTemplate template)
    {
        var documents = AppPaths.Documents;
        var baseFolder = Path.Combine(documents, "ServerMaster Sites");
        var name = template.Title;
        var candidate = Path.Combine(baseFolder, name);
        var suffix = 2;
        while (Profiles.Any(profile => string.Equals(profile.ExpandedRootPath, candidate, StringComparison.OrdinalIgnoreCase)) ||
               (Directory.Exists(candidate) && Directory.EnumerateFileSystemEntries(candidate).Any()))
        {
            candidate = Path.Combine(baseFolder, $"{name} {suffix++}");
        }

        return string.IsNullOrWhiteSpace(template.RootHint) ? candidate : Path.Combine(candidate, template.RootHint);
    }

    public IReadOnlyList<DependencyStatus> DependenciesFor(ProfileTemplate template, string? phpVersion = null, bool https = false, bool? needsDatabase = null)
    {
        var profile = template.CreateProfile("", 8080);
        profile.PhpVersion = phpVersion ?? DefaultPhp(template);
        profile.HttpsEnabled = https || profile.HttpsEnabled;
        if (needsDatabase is not null) profile.NeedsDatabase = needsDatabase.Value;
        return RequirementsFor(profile);
    }

    public static string DefaultPhp(ProfileTemplate template) => template.PhpVersion.Length > 0 ? template.PhpVersion : "8.3";

    public async Task CheckDependenciesForAsync(ProfileTemplate template, string? phpVersion = null, bool https = false, bool? needsDatabase = null)
    {
        var statuses = DependenciesFor(template, phpVersion, https, needsDatabase).ToList();
        if (statuses.Any(status => status.Dependency.WingetId is not null))
            statuses.Add(Dependencies.First(status => status.Dependency.Command == "winget"));
        await _dependencyManager.CheckAllAsync(statuses);
    }

    public async Task InstallDependencyAsync(DependencyStatus status)
    {
        var log = new ConsoleLog(_dispatcher);
        log.Lines.CollectionChanged += (_, args) =>
        {
            if (args.NewItems is null) return;
            foreach (LogLine line in args.NewItems) DependencyLogLines.Add(line);
        };
        if (status.Dependency.PhpVersion.Length > 0)
        {
            var runtime = Dependencies.First(item => item.Dependency.Command == "vcredist");
            await _dependencyManager.CheckAsync(runtime);
            if (!runtime.Installed) await _dependencyManager.InstallAsync(runtime, log);
        }
        await _dependencyManager.InstallAsync(status, log);
    }

    public async Task<ServerProfile> CreateProfileAsync(ProfileTemplate template, string name, string root, int port,
        bool downloadPackage, bool createStarter, string entryFile, string customCommand, string? phpVersion = null,
        bool https = false, bool trustCertificate = false, StarterTemplate? selectedStarter = null,
        Action<string>? setupProgress = null, bool createDatabase = false, string databaseName = "", string databasePassword = "")
    {
        if (string.IsNullOrWhiteSpace(name)) throw new InvalidOperationException("Enter a profile name.");
        if (template.Id == "joomla6" && phpVersion is not null && Version.TryParse(phpVersion, out var selectedPhp) && selectedPhp < new Version(8, 3))
            throw new InvalidOperationException("Joomla 6 requires PHP 8.3 or newer. Choose another PHP version above.");
        if (port is < 1024 or > 65535) throw new InvalidOperationException("Choose a port between 1024 and 65535.");
        if (Profiles.Any(profile => profile.Port == port)) throw new InvalidOperationException($"Port {port} is already assigned to another profile.");
        if (!IsPortFree(port))
            throw new InvalidOperationException($"Port {port} is already in use. Choose another one.");
        if (string.IsNullOrWhiteSpace(root)) throw new InvalidOperationException("Choose a project folder.");

        var expandedRoot = AppPaths.Expand(root.Trim());
        if (File.Exists(expandedRoot)) throw new InvalidOperationException("The project path points to a file.");
        if (!downloadPackage && !createStarter && !Directory.Exists(expandedRoot))
            throw new InvalidOperationException("The project folder does not exist. Choose an existing folder or download the project.");
        if (downloadPackage && !template.CanDownloadPackage) throw new InvalidOperationException("This template has no project download.");
        if (template.Engine == "custom" && string.IsNullOrWhiteSpace(customCommand))
            throw new InvalidOperationException("Enter the command that starts the server.");

        await CheckDependenciesForAsync(template, phpVersion, https, template.PackageKind == "wordpress-w2p" ? null : createDatabase);
        var missing = DependenciesFor(template, phpVersion, https, template.PackageKind == "wordpress-w2p" ? null : createDatabase)
            .Where(status => !status.Installed || status.Busy).Select(status => status.Dependency.Title).ToList();
        if (missing.Count > 0)
            throw new InvalidOperationException($"Install the required software first: {string.Join(", ", missing)}.");

        var profile = template.CreateProfile(expandedRoot, port);
        if (template.Engine == "phpBuiltIn") profile.PhpVersion = phpVersion ?? DefaultPhp(template);
        profile.Name = name.Trim();
        profile.HttpsEnabled = https;
        if (template.Engine == "nodeScript") profile.NodeEntryFile = entryFile.Trim();
        if (template.Engine == "custom") profile.CustomCommand = customCommand.Trim();

        if (downloadPackage)
        {
            var log = new ConsoleLog(_dispatcher);
            log.Lines.CollectionChanged += (_, args) =>
            {
                if (args.NewItems is null) return;
                foreach (LogLine line in args.NewItems)
                {
                    DependencyLogLines.Add(line);
                    if (!string.IsNullOrWhiteSpace(line.Text)) setupProgress?.Invoke(line.Text);
                }
            };
            await _templateDownloadService.DownloadAndExtractAsync(template, profile, log);
        }
        else if (createStarter)
        {
            var starter = selectedStarter is null ? StarterTemplate.DefaultFor(profile) : StarterTemplate.For(profile).First(item => item.Title == selectedStarter.Title);
            StarterTemplate.Write(profile, starter);
        }

        if (profile.HttpsEnabled) await Task.Run(() => LocalCertificates.Generate(profile, "localhost 127.0.0.1 ::1", trustCertificate));

        if (createDatabase)
        {
            if (template.PackageKind == "wordpress-w2p")
                throw new InvalidOperationException("This template prepares its database separately.");
            if (!DatabaseService.IsValidName(databaseName) || databasePassword.Length < 8)
                throw new InvalidOperationException("Choose a valid database name and a password of at least eight characters.");
            setupProgress?.Invoke("Starting MariaDB...");
            var database = DatabaseService.Detect();
            if (!database.Running) database = await DatabaseService.StartAsync(setupProgress);
            if (!database.Running) throw new InvalidOperationException("MariaDB could not start: " + database.Message);
            if ((await DatabaseService.ListDatabasesAsync()).Any(item => item.Name.Equals(databaseName, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException($"Database {databaseName} already exists. Choose another name; its existing password was not changed.");
            setupProgress?.Invoke("Creating database " + databaseName + "...");
            await DatabaseService.CreateDatabaseAsync(databaseName, databaseName, databasePassword);
            profile.DatabaseName = databaseName;
            try { DatabaseCredentialStore.Save(databaseName, databaseName, databasePassword); }
            catch (Exception ex) { Notify("Database created, but Windows could not save its credentials: " + ex.Message, true); }
            await RefreshDatabaseAsync();
        }
        if (template.PackageKind != "wordpress-w2p") profile.NeedsDatabase = createDatabase;

        profile.PropertyChanged += Profile_PropertyChanged;
        Profiles.Add(profile);
        SelectedProfile = profile;
        SaveProfiles();
        SelectSection("Profiles");
        return profile;
    }

    public bool IsAvailableProfilePort(int port) => port is >= 1024 and <= 65535 &&
        Profiles.All(profile => profile.Port != port) && IsPortFree(port);

    private void DuplicateProfile()
    {
        if (SelectedProfile is null)
        {
            return;
        }

        var source = SelectedProfile;
        var copy = new ServerProfile
        {
            Name = source.Name + " (copy)",
            IconGlyph = source.IconGlyph,
            ProfileColor = source.ProfileColor,
            Notes = source.Notes,
            TemplateId = source.TemplateId,
            NeedsDatabase = source.NeedsDatabase,
            HttpsEnabled = source.HttpsEnabled,
            CertificatePath = source.CertificatePath,
            PrivateKeyPath = source.PrivateKeyPath,
            Engine = source.Engine,
            PhpVersion = source.PhpVersion,
            Host = source.Host,
            Port = NextPort(),
            RootPath = source.RootPath,
            WorkingDirectory = source.WorkingDirectory,
            ConfigPath = source.ConfigPath,
            DatabaseName = source.DatabaseName,
            NodeEntryFile = source.NodeEntryFile,
            CustomCommand = source.CustomCommand,
            CustomArguments = source.CustomArguments,
            ExtraArguments = source.ExtraArguments,
            OpenBrowserOnStart = source.OpenBrowserOnStart,
            EnableCors = source.EnableCors,
            EnableGzip = source.EnableGzip,
            DirectoryListing = source.DirectoryListing,
            SpaFallback = source.SpaFallback,
            ConfigPreset = source.ConfigPreset,
            CacheSeconds = source.CacheSeconds,
            BasicAuthEnabled = source.BasicAuthEnabled,
            BasicAuthUser = source.BasicAuthUser,
            BasicAuthPassword = source.BasicAuthPassword,
            IndexFile = source.IndexFile,
            RunAsAdministrator = source.RunAsAdministrator,
            HideDotfiles = source.HideDotfiles,
            SecurityHeaders = source.SecurityHeaders,
            HstsEnabled = source.HstsEnabled,
            CustomErrorPages = source.CustomErrorPages,
            ErrorPageAccent = source.ErrorPageAccent,
            ErrorPageFooter = source.ErrorPageFooter,
            PhpMemoryLimit = source.PhpMemoryLimit,
            PhpUploadMaxFilesize = source.PhpUploadMaxFilesize,
            PhpMaxExecutionTime = source.PhpMaxExecutionTime,
            PhpDisplayErrors = source.PhpDisplayErrors,
            Environment = source.Environment.Select(item => new EnvVar { Key = item.Key, Value = item.Value }).ToList()
        };
        copy.PropertyChanged += Profile_PropertyChanged;
        Profiles.Add(copy);
        SelectedProfile = copy;
        SelectSection("Profiles");
        SaveProfiles();
    }

    private async Task DeleteProfileAsync()
    {
        if (SelectedProfile is null)
        {
            return;
        }

        var profile = SelectedProfile;
        _crashRecovery.Cancel(profile.Id);
        if (profile.IsActive)
        {
            await ControllerFor(profile).StopAsync(profile);
        }

        profile.PropertyChanged -= Profile_PropertyChanged;
        _controllers.Remove(profile.Id);
        Profiles.Remove(profile);
        if (_settings.DefaultProfileId == profile.Id)
        {
            _settings.DefaultProfileId = Profiles.FirstOrDefault()?.Id;
        }
        RefreshDefaultMarks();

        SelectedProfile = Profiles.FirstOrDefault();
        SaveProfiles();
        RefreshRuntimeState();
    }

    private void SaveProfiles()
    {
        _store.SaveProfiles(Profiles);
        Notify("Profiles saved.");
        RefreshRuntimeState();
    }

    private void MakeDefaultProfile()
    {
        if (SelectedProfile is null)
        {
            return;
        }

        _settings.DefaultProfileId = SelectedProfile.Id;
        _store.SaveSettings(_settings);
        OnPropertyChanged(nameof(DefaultProfile));
        OnPropertyChanged(nameof(SelectedProfileDefaultVisibility));
        OnPropertyChanged(nameof(SelectedProfileMakeDefaultVisibility));
        RefreshDefaultMarks();
        Notify($"\"{SelectedProfile.Name}\" is now the default profile.");
    }

    private void CreateStarterFile(StarterTemplate? starter)
    {
        if (starter is null || SelectedProfile is null)
        {
            return;
        }

        try { StarterTemplate.Write(SelectedProfile, starter); }
        catch (Exception ex) { Notify(ex.Message, true); return; }
        if (SelectedProfile.Engine == "nodeScript")
        {
            SelectedProfile.NodeEntryFile = starter.FileName;
        }

        Notify($"Created {starter.FileName}.");
        RefreshProfileConfigFiles();
    }

    private async Task CheckDependenciesAsync()
    {
        // Only an install/remove blocks a full check. A row that is merely being checked (the
        // selected profile's requirements at launch) used to make this return silently, leaving
        // every other row "Not checked"; concurrent checks of one row are merged by the manager.
        if (Dependencies.Any(status => status.Busy)) return;
        DependencyLog("Checking dependencies...");
        await _dependencyManager.CheckAllAsync(Dependencies);
        DependencyLog("Dependency check finished.");
    }

    private void NotifyDependencyScreenState()
    {
        OnPropertyChanged(nameof(DependenciesBusy));
        OnPropertyChanged(nameof(CanCheckDependencies));
        OnPropertyChanged(nameof(DependenciesProgressVisibility));
    }

    private async Task InstallDatabaseAsync()
    {
        var status = Dependencies.FirstOrDefault(item => item.Dependency.Command == "mariadbd");
        if (status is null) return;
        if (status.Installed)
        {
            await _dependencyManager.CheckAsync(status);
            Notify("MariaDB is already installed. It was not removed.");
        }
        else
        {
            await InstallDependencyAsync(status);
            Notify(status.Installed ? "MariaDB is ready." : status.Error, !status.Installed);
        }
        OnPropertyChanged(nameof(DatabaseStatus));
        OnPropertyChanged(nameof(DatabaseStatusTitle));
        OnPropertyChanged(nameof(DatabaseStatusVersion));
        OnPropertyChanged(nameof(DatabaseProcessLabel));
        OnPropertyChanged(nameof(DatabaseStatusBrush));
        OnPropertyChanged(nameof(DatabaseRunningVisibility));
        OnPropertyChanged(nameof(DatabaseStoppedVisibility));
        OnPropertyChanged(nameof(DatabaseCanStart));
        OnPropertyChanged(nameof(DatabaseCanStop));
        OnPropertyChanged(nameof(DatabaseCanInstall));
    }

    private bool _databaseBusy;
    private bool _lastDatabaseRunning;

    private void NotifyDatabaseState()
    {
        foreach (var name in new[] { nameof(DatabaseStatus), nameof(DatabaseStatusTitle), nameof(DatabaseStatusVersion),
            nameof(DatabaseProcessLabel), nameof(DatabaseStatusBrush), nameof(DatabaseRunningVisibility),
            nameof(DatabaseStoppedVisibility), nameof(DatabaseCanStart), nameof(DatabaseCanStop), nameof(DatabaseCanInstall),
            nameof(DatabaseProgressVisibility), nameof(DatabaseEntriesEmptyVisibility), nameof(CanResetSettings) })
            OnPropertyChanged(name);
        NotifyBackupState();
    }

    private void AppendDatabaseLog(string message) => _dispatcher.TryEnqueue(() =>
    {
        DatabaseLogLines.Add(new LogLine { Stream = LogStream.System, Text = message });
        while (DatabaseLogLines.Count > 5000) DatabaseLogLines.RemoveAt(0);
    });

    private async Task StartDatabaseAsync()
    {
        if (_databaseBusy) return;
        DatabaseProblem = "";
        _databaseBusy = true;
        NotifyDatabaseState();
        try
        {
            await DatabaseService.StartAsync(AppendDatabaseLog);
            await RefreshDatabaseAsync();
        }
        catch (Exception ex) { DatabaseProblem = ex.Message; AppendDatabaseLog(ex.Message); Notify(ex.Message, true); }
        finally { _databaseBusy = false; NotifyDatabaseState(); }
    }

    private async Task StopDatabaseAsync()
    {
        if (_databaseBusy) return;
        _databaseBusy = true;
        NotifyDatabaseState();
        try
        {
            AdminerService.Stop();
            NotifyAdminerState();
            await DatabaseService.StopAsync();
            DatabaseEntries.Clear();
            Notify("MariaDB stopped.");
        }
        catch (Exception ex) { Notify(ex.Message, true); }
        finally { _databaseBusy = false; NotifyDatabaseState(); }
    }

    private int _databaseRefreshVersion;
    private async Task RefreshDatabaseAsync()
    {
        var version = ++_databaseRefreshVersion;
        try
        {
            DatabaseProblem = "";
            IReadOnlyList<DatabaseEntry> databases = DatabaseStatus.Running ? await DatabaseService.ListDatabasesAsync() : [];
            if (version != _databaseRefreshVersion) return;
            DatabaseEntries.Clear();
            if (DatabaseStatus.Running)
                foreach (var item in databases) DatabaseEntries.Add(item);
        }
        catch (Exception ex)
        {
            DatabaseProblem = "Could not refresh databases: " + ex.Message;
            DatabaseLogLines.Add(new LogLine { Stream = LogStream.Stderr, Text = ex.Message });
        }
    }

    private async Task CreateDatabaseAsync()
    {
        if (!DatabaseStatus.Running) { Notify("Start MariaDB first.", true); return; }
        try
        {
            var name = NewDatabaseName.Trim();
            var user = NewDatabaseUser.Trim();
            var password = NewDatabasePassword;
            if ((await DatabaseService.ListDatabasesAsync()).Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException($"Database {name} already exists. Open it or import into it; Create will not change its user password.");
            await DatabaseService.CreateDatabaseAsync(name, user, password);
            try { DatabaseCredentialStore.Save(name, user, password); }
            catch (Exception ex) { Notify("Database created, but Windows could not save its credentials: " + ex.Message, true); }
            await RefreshDatabaseAsync();
            Notify($"Database \"{name}\" created.");
            NewDatabaseName = "";
            NewDatabasePassword = "";
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    public async Task ImportDatabaseAsync(string source)
    {
        if (_databaseBusy || !DatabaseStatus.Running) return;
        var name = NewDatabaseName.Trim();
        if (string.IsNullOrWhiteSpace(name)) { Notify("Enter the target database name before importing.", true); return; }
        if (SelectedWindow?.Content is not FrameworkElement content) return;
        try
        {
            var existing = (await DatabaseService.ListDatabasesAsync()).Any(item => item.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (existing)
            {
                var confirmation = new ContentDialog
                {
                    XamlRoot = content.XamlRoot,
                    Title = "Import into " + name + "?",
                    Content = "The SQL file can replace tables and data already in this database. Take a snapshot first if you need to keep them.",
                    PrimaryButtonText = "Import",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Close
                };
                if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            }
            _databaseBusy = true;
            NotifyDatabaseState();
            AppendDatabaseLog($"Importing {Path.GetFileName(source)} into {name}...");
            await DatabaseService.ImportDatabaseAsync(name, NewDatabaseUser.Trim(), NewDatabasePassword, source);
            if (!existing)
            {
                try { DatabaseCredentialStore.Save(name, NewDatabaseUser.Trim(), NewDatabasePassword); }
                catch (Exception ex) { Notify("Database imported, but Windows could not save its credentials: " + ex.Message, true); }
            }
            await RefreshDatabaseAsync();
            AppendDatabaseLog($"Imported {Path.GetFileName(source)} into {name}.");
            Notify($"Database \"{name}\" imported.");
            NewDatabaseName = "";
            NewDatabasePassword = "";
        }
        catch (Exception ex) { AppendDatabaseLog(ex.Message); Notify("Could not import the database: " + ex.Message + " Some statements may have run before the error; inspect the database or restore a snapshot.", true); }
        finally { _databaseBusy = false; NotifyDatabaseState(); }
    }

    private async Task DeleteDatabaseAsync(DatabaseEntry? database)
    {
        if (database is null) return;
        if (SelectedWindow?.Content is not FrameworkElement content) return;
        var confirmation = new ContentDialog
        {
            XamlRoot = content.XamlRoot, Title = "Delete database " + database.Name + "?",
            Content = "All tables and data in this database will be permanently deleted.",
            PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await DatabaseService.DropDatabaseAsync(database.Name);
            try { DatabaseCredentialStore.Delete(database.Name); }
            catch (Exception ex) { Notify("Database deleted, but its saved password could not be removed: " + ex.Message, true); }
            await RefreshDatabaseAsync();
            Notify($"Database \"{database.Name}\" deleted.");
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private async Task OpenDatabaseAdminAsync()
    {
        try
        {
            if (!DatabaseStatus.Running) { Notify("Start MariaDB before opening its admin panel.", true); return; }
            var panel = Dependencies.First(status => status.Dependency.Command == DatabaseAdminTool);
            await _dependencyManager.CheckAsync(panel);
            if (!panel.Installed)
            {
                if (SelectedWindow?.Content is not FrameworkElement content) return;
                var dialog = new ContentDialog
                {
                    XamlRoot = content.XamlRoot, Title = $"Install {AdminPanelTitle}?",
                    Content = $"The selected database panel is not installed. ServerMaster will download it from its official website and verify it before replacing any existing copy.",
                    PrimaryButtonText = "Install " + AdminPanelTitle, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                await InstallDependencyAsync(panel);
                if (!panel.Installed) return;
            }
            var phpAvailable = DatabaseAdminTool == "phpmyadmin"
                ? PhpRuntime.Find("8.3") is not null || PhpRuntime.Find("8.2") is not null
                : PhpRuntime.Find("") is not null || ShellEnvironment.Shared.Which("php") is not null;
            if (!phpAvailable)
            {
                if (SelectedWindow?.Content is not FrameworkElement phpContent) return;
                var prompt = new ContentDialog { XamlRoot = phpContent.XamlRoot, Title = $"Install PHP for {AdminPanelTitle}?", Content = "The database panel needs PHP. Install compatible PHP 8.3 and its runtime dependencies now?", PrimaryButtonText = "Install PHP", CloseButtonText = "Cancel" };
                if (await prompt.ShowAsync() != ContentDialogResult.Primary) return;
                var php = Dependencies.First(item => item.Dependency.PhpVersion == "8.3");
                await InstallDependencyAsync(php);
                if (!php.Installed) return;
            }
            AdminerService.SetTool(DatabaseAdminTool);
            await AdminerService.StartAsync();
            NotifyAdminerState();
            OpenUrl(AdminerService.LoginAddress);
            Notify(AdminPanelTitle + " opened in the browser.");
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }

    private void StopDatabaseAdmin()
    {
        AdminerService.Stop();
        NotifyAdminerState();
    }

    private void NotifyAdminerState()
    {
        OnPropertyChanged(nameof(AdminerStatus));
        OnPropertyChanged(nameof(AdminerRunningVisibility));
        OnPropertyChanged(nameof(AdminerAddress));
        OnPropertyChanged(nameof(AdminPanelTitle));
    }

    private bool _databaseDialogOpen;
    private async Task OpenDatabaseBrowserAsync(DatabaseEntry? database, bool structure = false)
    {
        if (database is null || _databaseDialogOpen || SelectedWindow?.Content is not FrameworkElement content) return;
        _databaseDialogOpen = true;
        try
        {
            if (structure) await new Views.DatabaseSchemaDialog(database.Name) { XamlRoot = content.XamlRoot }.ShowAsync();
            else await new Views.DatabaseBrowserDialog(database.Name) { XamlRoot = content.XamlRoot }.ShowAsync();
            await RefreshDatabaseAsync();
        }
        catch (Exception ex) { DatabaseQueryOutput = ex.Message; Notify(ex.Message, true); }
        finally { _databaseDialogOpen = false; }
    }

    private async Task OpenDatabaseAccountsAsync(DatabaseEntry? database)
    {
        if (database is null || _databaseDialogOpen || SelectedWindow?.Content is not FrameworkElement content) return;
        _databaseDialogOpen = true;
        try { await new Views.DatabaseAccountsDialog(database.Name) { XamlRoot = content.XamlRoot }.ShowAsync(); }
        catch (Exception ex) { Notify(ex.Message, true); }
        finally { _databaseDialogOpen = false; }
    }

    private async Task RunDatabaseQueryAsync()
    {
        if (SelectedDatabase is null) return;
        try { DatabaseQueryOutput = await DatabaseService.RunQueryAsync(SelectedDatabase.Name, DatabaseSql); }
        catch (Exception ex) { DatabaseQueryOutput = ex.Message; Notify(ex.Message, true); }
    }

    private void CopyText(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var package = new DataPackage(); package.SetText(value); Clipboard.SetContent(package);
        Notify("Copied to clipboard.");
    }

    private async Task InstallOrRemoveDependencyAsync(DependencyStatus? status)
    {
        if (status is null)
        {
            return;
        }

        var log = new ConsoleLog(_dispatcher);
        log.Lines.CollectionChanged += (_, args) =>
        {
            if (args.NewItems is null)
            {
                return;
            }

            foreach (LogLine line in args.NewItems)
            {
                DependencyLogLines.Add(line);
            }
        };

        try
        {
            if (status.Installed && status.Dependency.PhpVersion.Length > 0)
            {
                var users = Profiles.Where(profile => profile.Engine == "phpBuiltIn" &&
                    (profile.PhpVersion == status.Dependency.PhpVersion || profile.PhpVersion.Length == 0)).Select(profile => profile.Name).ToList();
                if (users.Count > 0) throw new InvalidOperationException($"PHP {status.Dependency.PhpVersion} is used by: {string.Join(", ", users)}. Select another PHP version in these profiles before removing it.");
            }
            if (status.Installed && (Profiles.Any(profile => profile.IsActive) || DatabaseStatus.Running || AdminerService.IsRunning))
                throw new InvalidOperationException("Stop servers and the database before removing or repairing dependencies.");
            if (status.Dependency.Command == "vcredist") await _dependencyManager.InstallAsync(status, log, update: true);
            else if (status.Installed) await _dependencyManager.RemoveAsync(status, log);
            else await InstallDependencyAsync(status);
        }
        catch (Exception ex)
        {
            status.Error = ex.Message;
            Notify(ex.Message, true);
        }
        DependencyLog($"{status.Dependency.Title}: {status.StatusText}.");
    }

    public Task CheckRuntimeUpdateAsync(DependencyStatus status) => _dependencyManager.CheckRuntimeUpdateAsync(status);
    public Task<IReadOnlyList<string>> PackageVersionsAsync(DependencyStatus status) => _dependencyManager.PackageVersionsAsync(status);
    public async Task SelectPackageVersionAsync(DependencyStatus status, string version)
    {
        if (Profiles.Any(profile => profile.IsActive) || DatabaseStatus.Running || AdminerService.IsRunning)
            throw new InvalidOperationException("Stop all servers and the database before switching versions.");
        if (status.Dependency.Command == "mariadbd" && status.Installed)
            throw new InvalidOperationException("MariaDB version changes require a database export and a migration plan. Automatic replacement is blocked to protect existing data.");
        await _dependencyManager.InstallVersionAsync(status, version);
    }
    public async Task SelectNodeVersionAsync(string version, Action<string>? progress = null)
    {
        var status = Dependencies.First(item => item.Dependency.Command == "node");
        if (status.Busy) throw new InvalidOperationException("Wait for the current installation.");
        if (Profiles.Any(profile => profile.IsActive) || ShellBusy) throw new InvalidOperationException("Stop servers and terminal commands before switching Node.js.");
        status.Busy = true;
        try
        {
            await NodeRuntime.SelectAsync(version, message => _dispatcher.TryEnqueue(() => { status.Message = message; progress?.Invoke(message); }));
        }
        finally { status.Busy = false; await _dependencyManager.CheckAllAsync(Dependencies); }
    }
    public async Task UpdateDependencyAsync(DependencyStatus status)
    {
        try
        {
            if (Profiles.Any(profile => profile.IsActive) || DatabaseStatus.Running || AdminerService.IsRunning)
                throw new InvalidOperationException("Stop servers and the database before updating dependencies.");
            var log = new ConsoleLog(_dispatcher);
            log.Lines.CollectionChanged += (_, args) =>
            {
                if (args.NewItems is not null) foreach (LogLine line in args.NewItems) DependencyLogLines.Add(line);
            };
            await _dependencyManager.InstallAsync(status, log, update: true);
            await _dependencyManager.CheckAllAsync(Dependencies);
            Notify(status.Dependency.Title + ": " + status.Version);
        }
        catch (Exception ex) { Notify(ex.Message, true); }
    }
    /// <summary>Checks one row; an unchecked row offers this instead of installing what may already be there.</summary>
    public Task CheckDependencyAsync(DependencyStatus status) => _dependencyManager.CheckAsync(status);
    public Task CheckHttpsDependencyAsync() => _dependencyManager.CheckAsync(Dependencies.First(item => item.Dependency.Command == "caddy"));

    public ObservableCollection<ShutdownItem> ShutdownItems { get; } = [];
    private double _shutdownProgress;
    public double ShutdownProgress { get => _shutdownProgress; private set => SetProperty(ref _shutdownProgress, value); }
    private bool _isShutdownVisible;
    public bool IsShutdownVisible { get => _isShutdownVisible; private set { if (SetProperty(ref _isShutdownVisible, value)) OnPropertyChanged(nameof(ShutdownVisibility)); } }
    public Visibility ShutdownVisibility => IsShutdownVisible ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ShutdownItemsVisibility => ShutdownItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Whether quitting must stop something this app started or still manages.</summary>
    public bool HasWorkToStopOnQuit => CanStopAllServers || DatabaseStatus.Running || AdminerService.IsRunning;

    public async Task ShutdownAsync()
    {
        _shuttingDown = true;
        _crashRecovery.CancelAll();
        _traceCancellation?.Cancel();
        ShutdownItems.Clear();
        ShutdownProgress = 0;
        IsShutdownVisible = true;
        var items = new Dictionary<Guid, ShutdownItem>();
        var stopErrors = await StopAllOwnedAsync(targets =>
        {
            foreach (var profile in targets) ShutdownItems.Add(items[profile.Id] = new ShutdownItem(profile.Name));
            if (DatabaseStatus.Running) ShutdownItems.Add(new ShutdownItem("Database"));
            OnPropertyChanged(nameof(ShutdownItemsVisibility));
        }, (profile, problem) =>
        {
            if (!items.TryGetValue(profile.Id, out var item)) return;
            if (problem is null && item.Status == ShutdownItemStatus.Waiting) item.Update(ShutdownItemStatus.Stopping, "stopping...");
            else item.Update(problem is null ? ShutdownItemStatus.Stopped : ShutdownItemStatus.Failed, problem ?? (profile.RunAsAdministrator ? "stopped (administrator)" : "stopped"));
            AdvanceShutdownProgress();
        });
        var databaseItem = ShutdownItems.FirstOrDefault(item => !items.ContainsValue(item));
        databaseItem?.Update(ShutdownItemStatus.Stopping, "stopping...");
        try { await DatabaseService.StopAsync(); databaseItem?.Update(ShutdownItemStatus.Stopped, "stopped"); }
        catch (Exception ex) { stopErrors.Add("MariaDB: " + ex.Message); databaseItem?.Update(ShutdownItemStatus.Failed, ex.Message); }
        AdvanceShutdownProgress();
        if (stopErrors.Count > 0)
        {
            _shuttingDown = false;
            IsShutdownVisible = false;
            throw new AggregateException("Some processes could not be stopped: " + string.Join("; ", stopErrors),
                stopErrors.Select(message => new InvalidOperationException(message)));
        }
        _uptimeTimer.Stop();
        _portReserver.ReleaseAll();
        foreach (var tab in ConsoleTabs.Where(item => item.IsTerminal)) tab.Session?.Dispose();
        _shellCancellation?.Cancel();
        if (_shellProcess is { } shell)
        {
            try
            {
                if (!shell.HasExited) shell.Kill(entireProcessTree: true);
                await shell.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (InvalidOperationException) { }
        }
        AdminerService.Stop();
        Save();
    }

    public async Task StopAllAsync()
    {
        var errors = await StopAllOwnedAsync();
        if (errors.Count > 0) Notify("Could not stop every server: " + string.Join("; ", errors), true);
    }

    private void AdvanceShutdownProgress()
    {
        var total = Math.Max(1, ShutdownItems.Count);
        ShutdownProgress = 100.0 * ShutdownItems.Count(item => item.Status is ShutdownItemStatus.Stopped or ShutdownItemStatus.Failed) / total;
    }

    /// <summary>
    /// The user gave up waiting during quit. Exiting closes every kill-on-close job, and elevated
    /// helpers stop their server tree when the pipe closes, so no owned process outlives the app.
    /// </summary>
    public void ForceQuit()
    {
        _portReserver.ReleaseAll();
        AdminerService.Stop();
        try { Save(); } catch (Exception) { } // Settings are best effort; exiting must not be blocked by disk errors.
        Environment.Exit(0);
    }

    private async Task<List<string>> StopAllOwnedAsync(Action<IReadOnlyList<ServerProfile>>? planned = null,
        Action<ServerProfile, string?>? progress = null)
    {
        _stopRequests++;
        _crashRecovery.CancelAll();
        var targets = Profiles.Where(profile => profile.IsActive ||
                (_controllers.TryGetValue(profile.Id, out var controller) && controller.HasOwnedProcess))
            .Concat(_controllers.Values.Where(controller => controller.HasOwnedProcess)
                .Select(controller => controller.ActiveProfile).OfType<ServerProfile>())
            .DistinctBy(profile => profile.Id).ToList();
        planned?.Invoke(targets);
        var errors = new List<string>();
        foreach (var profile in targets)
        {
            var controller = ControllerFor(profile);
            progress?.Invoke(profile, null);
            try
            {
                await controller.StopAsync(profile);
                if (controller.HasOwnedProcess || profile.State != ServerState.Stopped)
                {
                    var problem = profile.Failure ?? "the owned process or its port did not stop.";
                    errors.Add($"{profile.Name}: {problem}");
                    progress?.Invoke(profile, problem);
                }
                else progress?.Invoke(profile, null);
            }
            catch (Exception ex) { errors.Add($"{profile.Name}: {ex.Message}"); progress?.Invoke(profile, ex.Message); }
        }

        RefreshRuntimeState();
        return errors;
    }

    private readonly HashSet<Guid> _profileChecks = [];
    private int _stopRequests;

    /// <summary>Starts a profile that is not already running (used right after creating one).</summary>
    public Task StartProfileAsync(ServerProfile profile) => profile.IsActive ? Task.CompletedTask : StartStopProfileAsync(profile);

    private async Task StartStopProfileAsync(ServerProfile? profile, bool automaticRecovery = false)
    {
        if (profile is null || _shuttingDown || profile.State == ServerState.Stopping) return;
        if (!automaticRecovery) _crashRecovery.Cancel(profile.Id);
        if (_backupsBusy && !profile.IsActive) { Notify("Wait for the snapshot operation to finish before starting a server.", true); return; }
        try
        {
            if (profile.IsActive)
            {
                await ControllerFor(profile).StopAsync(profile);
                return;
            }
            if (_portReserver.IsReserved(profile.Port))
                throw new InvalidOperationException($"Port {profile.Port} is reserved inside ServerMaster. Release the reservation on Ports before starting this profile.");
            if (!_profileChecks.Add(profile.Id)) return;
            var stopRequest = _stopRequests;
            try
            {
                var required = RequirementsFor(profile);
                await _dependencyManager.CheckAllAsync(required);
                if (stopRequest != _stopRequests || _shuttingDown || !Profiles.Contains(profile) || (automaticRecovery && !RestartOnCrash)) return;
                var unavailable = required.Where(status => !status.Installed || status.Busy).ToList();
                if (unavailable.Count > 0)
                {
                    profile.Failure = string.Join(Environment.NewLine, unavailable.Select(status => $"{status.Dependency.Title}: {status.Message}")) + Environment.NewLine + "Open Profiles and select Install missing software.";
                    profile.State = ServerState.Failed;
                    Notify(profile.Failure, true);
                    return;
                }
                if (profile.NeedsDatabase && !DatabaseStatus.Running)
                {
                    await DatabaseService.StartAsync(AppendDatabaseLog);
                    NotifyDatabaseState();
                    if (stopRequest != _stopRequests || _shuttingDown || !Profiles.Contains(profile) || (automaticRecovery && !RestartOnCrash)) return;
                }
                await ControllerFor(profile).StartAsync(profile, _settings);
                if (profile.State == ServerState.Failed) Notify(profile.Failure ?? "Server startup failed. See Console.", true);
            }
            finally { _profileChecks.Remove(profile.Id); }
        }
        catch (Exception ex)
        {
            if (!profile.IsActive) { profile.Failure = ex.Message; profile.State = ServerState.Failed; }
            Notify("Could not change server state: " + ex.Message, true);
        }
        finally { NotifyConsoleLines(); RefreshRuntimeState(); }
    }


    private async Task RestartProfileAsync(ServerProfile? profile)
    {
        if (profile is null)
        {
            return;
        }

        _crashRecovery.Cancel(profile.Id);

        await ControllerFor(profile).StopAsync(profile);
        await StartStopProfileAsync(profile);
        NotifyConsoleLines();
        RefreshRuntimeState();
    }

    private void OpenProfile(ServerProfile? profile)
    {
        if (profile is null)
        {
            return;
        }

        ControllerFor(profile).OpenInBrowser(profile.Address);
    }

    private bool _openingSites;
    private async Task OpenAllProfilesAsync()
    {
        if (!CanOpenAllProfiles) return;
        _openingSites = true;
        OnPropertyChanged(nameof(CanOpenAllProfiles));
        try
        {
            foreach (var profile in Profiles.Where(profile => profile.IsRunning).ToArray())
            {
                if (profile.IsRunning && Profiles.Contains(profile)) OpenProfile(profile);
                await Task.Delay(150);
            }
        }
        catch (Exception ex) { Notify("Could not open site: " + ex.Message, true); }
        finally { _openingSites = false; OnPropertyChanged(nameof(CanOpenAllProfiles)); }
    }

    private void CopyAddresses()
    {
        var lines = Profiles.Select(profile =>
        {
            var suffix = profile.State == ServerState.Running ? "" : " (stopped)";
            return $"{profile.Name}: {profile.Address}{suffix}";
        });

        var package = new DataPackage();
        package.SetText(string.Join(Environment.NewLine, lines));
        Clipboard.SetContent(package);
        Notify($"{Profiles.Count} address copied.");
    }

    private async Task HealthCheckAsync()
    {
        if (!CanHealthCheck) return;
        var targets = Profiles.Where(profile => profile.IsRunning)
            .Select(profile => new SiteHealthTarget(profile.Id, profile.Name, profile.Address, profile.CertificatePath)).ToArray();
        _healthCheckBusy = true;
        HealthResults.Clear();
        NotifyHealthState();
        try
        {
            foreach (var result in await SiteHealthCheck.RunAsync(targets)) HealthResults.Add(result);
            _healthLastRun = DateTimeOffset.Now;
        }
        catch (Exception ex) { Notify("Health check failed: " + ex.Message, true); }
        finally { _healthCheckBusy = false; NotifyHealthState(); }
    }

    private void ClearHealthCheck()
    {
        if (_healthCheckBusy) return;
        HealthResults.Clear();
        _healthLastRun = null;
        NotifyHealthState();
    }

    private void NotifyHealthState()
    {
        foreach (var name in new[] { nameof(CanHealthCheck), nameof(CanClearHealthCheck), nameof(HealthPanelVisibility),
            nameof(HealthProgressVisibility), nameof(HealthLastRun), nameof(HealthSummary) }) OnPropertyChanged(name);
    }

    private async Task RunDiagnosticsAsync()
    {
        if (DiagnosticsRunning) return;
        DiagnosticsRunning = true;
        DiagnosticFindings.Clear();
        DiagnosticsSummary = "Checking profiles...";
        try
        {
            DiagnosticsSummary = "Checking Windows health...";
            foreach (var finding in await SystemDiagnostics.CheckAsync()) DiagnosticFindings.Add(finding);
            foreach (var finding in await WindowsEnvironmentDiagnostics.CheckAsync()) DiagnosticFindings.Add(finding);
            foreach (var finding in await Task.Run(() => AppDataDiagnostics.CheckAsync(AppPaths.Support))) DiagnosticFindings.Add(finding);
            foreach (var finding in await Task.Run(DatabaseService.Diagnostics)) DiagnosticFindings.Add(finding);
            // Freeze settings so editing a profile during a check cannot mix two configurations.
            var profiles = Profiles.Select(profile =>
            {
                var copy = System.Text.Json.JsonSerializer.Deserialize<ServerProfile>(System.Text.Json.JsonSerializer.Serialize(profile))!;
                copy.State = profile.State;
                return copy;
            }).ToList();
            foreach (var profile in profiles)
            {
                DiagnosticsSummary = "Checking " + profile.Name + "...";
                foreach (var finding in await Task.Run(() => ProfileDiagnostics.CheckAsync(profile))) DiagnosticFindings.Add(finding);
                foreach (var status in RequirementsFor(profile))
                {
                    await _dependencyManager.CheckAsync(status);
                    DiagnosticFindings.Add(new(profile.Name, status.Dependency.Title, status.Message,
                        status.Busy ? "Wait for installation to finish, then check again." : status.Installed ? "" : "Open Dependencies and install or repair this component.",
                        status.Busy || !status.Installed, status.Busy ? DiagnosticLevel.Warning : status.Installed ? DiagnosticLevel.Fine : DiagnosticLevel.Broken));
                }
            }
            var sorted = DiagnosticFindings.OrderByDescending(item => item.Level).ThenBy(item => item.Group).ToList();
            DiagnosticFindings.Clear();
            foreach (var finding in sorted) DiagnosticFindings.Add(finding);
            var broken = sorted.Count(item => item.Level == DiagnosticLevel.Broken);
            var warnings = sorted.Count(item => item.Level == DiagnosticLevel.Warning);
            DiagnosticsSummary = broken > 0 ? $"{broken} {Localization.T("broken")}, {warnings} {Localization.T("worth a look")}" :
                warnings > 0 ? $"{warnings} {Localization.T("worth a look")}" : "Nothing wrong found";
        }
        catch (Exception ex)
        {
            DiagnosticsSummary = "Diagnostics could not finish.";
            DiagnosticFindings.Add(new("System", "Diagnostics interrupted", ex.Message, "Run the checks again.", true));
            Notify(ex.Message, true);
        }
        finally { _diagnosticsLastRun = DateTimeOffset.Now; DiagnosticsRunning = false; NotifyDiagnosticResults(); }
    }

    private void CopyDiagnostics()
    {
        try
        {
            if (!CanCopyDiagnostics) return;
            var package = new DataPackage();
            package.SetText(ProfileDiagnostics.Report(DiagnosticFindings));
            Clipboard.SetContent(package);
            Notify("Diagnostic report copied.");
        }
        catch (Exception ex) { Notify("Could not copy the report: " + ex.Message, true); }
    }

    private ServerController ControllerFor(ServerProfile profile)
    {
        if (_controllers.TryGetValue(profile.Id, out var controller))
        {
            return controller;
        }

        controller = new ServerController(_dispatcher);
        controller.UnexpectedExit += (failed, code) =>
        {
            RefreshRuntimeState();
            Notify($"Server \"{failed.Name}\" exited unexpectedly (code {code}). See Console.", true);
            var stopRequest = _stopRequests;
            _ = _crashRecovery.ScheduleAsync(failed.Id,
                () => RestartOnCrash && !_shuttingDown && stopRequest == _stopRequests && Profiles.Contains(failed)
                    && failed.State == ServerState.Failed && !_backupsBusy,
                () => StartStopProfileAsync(failed, automaticRecovery: true),
                controller.Log.System);
            RefreshRuntimeState();
        };
        _controllers[profile.Id] = controller;
        if (SelectedConsoleTab?.ProfileId == profile.Id) NotifyConsoleLines();
        return controller;
    }

    private ServerController? SelectedController =>
        SelectedProfile is null || !_controllers.TryGetValue(SelectedProfile.Id, out var controller) ? null : controller;

    private void Profile_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is ServerProfile changed && e.PropertyName is nameof(ServerProfile.State)) OnConsoleProfileStateChanged(changed);
        if (sender is ServerProfile shown && SelectedConsoleTab?.ProfileId == shown.Id
            && e.PropertyName is nameof(ServerProfile.ProcessId) or nameof(ServerProfile.Address)) NotifyConsoleStatus();
        if (e.PropertyName is nameof(ServerProfile.Name) or nameof(ServerProfile.RootPath)) NotifyBackupState();
        if (sender == FilesProfile)
        {
            if (e.PropertyName == nameof(ServerProfile.Name)) OnPropertyChanged(nameof(FilesProfileName));
            if (e.PropertyName == nameof(ServerProfile.RootPath) && SelectedSection == "Files") RefreshFiles();
        }
        if (e.PropertyName is nameof(ServerProfile.Name) or nameof(ServerProfile.Engine) or nameof(ServerProfile.PhpVersion)) UpdateDependencyUsage();
        if (sender == SelectedProfile)
        {
            if (e.PropertyName is not (nameof(ServerProfile.Uptime) or nameof(ServerProfile.IsDefault) or nameof(ServerProfile.DefaultGlyph))) NotifyControlDetails();
            OnPropertyChanged(nameof(SelectedProfileCommand));
            OnPropertyChanged(nameof(SelectedProfileIssue));
            OnPropertyChanged(nameof(SelectedProfileIssueVisibility));
            OnPropertyChanged(nameof(SelectedProfileSummary));
            OnPropertyChanged(nameof(SelectedProfileStateBrush));
            if (e.PropertyName is nameof(ServerProfile.Engine) or nameof(ServerProfile.IndexFile) or nameof(ServerProfile.NodeEntryFile))
            {
                RefreshStarterTemplates();
            }
            if (e.PropertyName is nameof(ServerProfile.Engine) or nameof(ServerProfile.RootPath) or nameof(ServerProfile.PhpVersion))
                RefreshProfileConfigFiles();
            if (e.PropertyName is nameof(ServerProfile.Engine) or nameof(ServerProfile.PhpVersion) or nameof(ServerProfile.HttpsEnabled))
            {
                OnPropertyChanged(nameof(SelectedProfilePhpVisibility));
                OnPropertyChanged(nameof(SelectedProfileNodeVisibility));
                OnPropertyChanged(nameof(SelectedProfileCustomVisibility));
                OnPropertyChanged(nameof(SelectedProfileRootVisibility));
                OnPropertyChanged(nameof(SelectedProfileStaticVisibility));
                OnPropertyChanged(nameof(SelectedProfileHttpsVisibility));
                OnPropertyChanged(nameof(SelectedProfileEngineOption));
                OnPropertyChanged(nameof(SelectedProfileGuideUrl));
                OnPropertyChanged(nameof(SelectedProfilePhpOption));
                OnPropertyChanged(nameof(SelectedProfilePhpStatus));
                OnPropertyChanged(nameof(SelectedProfilePhpInstallVisibility));
                OnPropertyChanged(nameof(SelectedProfileSetupMessage));
                var version = ++_profileCheckVersion;
                _ = CheckSelectedProfileAsync(version);
            }
        }

        RefreshMetrics();
    }

    private void RefreshRuntimeState()
    {
        var databaseRunning = DatabaseService.Detect().Running;
        if (databaseRunning != _lastDatabaseRunning)
        {
            _lastDatabaseRunning = databaseRunning;
            NotifyDatabaseState();
        }
        foreach (var profile in Profiles)
        {
            if (_controllers.TryGetValue(profile.Id, out var controller))
            {
                controller.RefreshUptime(profile);
            }
        }

        var backgroundColor = Profiles.FirstOrDefault(profile => profile.IsRunning)?.ProfileColor ?? "";
        if (!backgroundColor.Equals(_backgroundProfileColor, StringComparison.OrdinalIgnoreCase))
        {
            _backgroundProfileColor = backgroundColor;
            if (BackgroundFollowsServers) OnPropertyChanged(nameof(AppBackgroundBrush));
        }

        RefreshMetrics();
    }

    private void RefreshMetrics()
    {
        RefreshDetectedUrls();
        Metrics.Clear();
        Metrics.Add(new MetricItem { Value = ActiveCount.ToString(), Caption = "running", Glyph = "\uE945", Tint = ActiveStatusBrush });
        Metrics.Add(new MetricItem { Value = Profiles.Count.ToString(), Caption = "profiles", Glyph = "\uE8FD", Tint = _muted });
        Metrics.Add(new MetricItem { Value = LongestUptime, Caption = "longest run", Glyph = "\uE916", Tint = _muted });
        OnPropertyChanged(nameof(ActiveCount));
        OnPropertyChanged(nameof(ActiveStatusTitle));
        OnPropertyChanged(nameof(ActiveStatusSubtitle));
        OnPropertyChanged(nameof(ActiveStatusBrush));
        OnPropertyChanged(nameof(StopAllVisibility));
        OnPropertyChanged(nameof(CanStopAllServers));
        OnPropertyChanged(nameof(ControlSubtitle));
        OnPropertyChanged(nameof(CanOpenAllProfiles));
        OnPropertyChanged(nameof(CanCopyAddresses));
        OnPropertyChanged(nameof(CanHealthCheck));
        OnPropertyChanged(nameof(LongestUptime));
    }

    private int NextPort()
    {
        var used = Profiles.Select(profile => profile.Port).ToHashSet();
        var port = 8080;
        while (used.Contains(port) || !IsPortFree(port))
        {
            port++;
        }

        return port;
    }

    private static bool IsPortFree(int port)
    {
        try
        {
            using var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    private static global::Windows.UI.Color Hsv(double hue, double saturation, double value)
    {
        hue = (hue % 1 + 1) % 1;
        var sector = hue * 6;
        var index = (int)Math.Floor(sector);
        var fraction = sector - index;
        var p = value * (1 - saturation);
        var q = value * (1 - fraction * saturation);
        var t = value * (1 - (1 - fraction) * saturation);
        var (r, g, b) = index switch { 0 => (value, t, p), 1 => (q, value, p), 2 => (p, value, t), 3 => (p, q, value), 4 => (t, p, value), _ => (value, p, q) };
        return ColorHelper.FromArgb(255, (byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }

    private static bool TryHue(string hex, out double hue)
    {
        hue = 0;
        if (hex.Length != 7 || hex[0] != '#') return false;
        try
        {
            var r = Convert.ToByte(hex.Substring(1, 2), 16) / 255d;
            var g = Convert.ToByte(hex.Substring(3, 2), 16) / 255d;
            var b = Convert.ToByte(hex.Substring(5, 2), 16) / 255d;
            var max = Math.Max(r, Math.Max(g, b)); var min = Math.Min(r, Math.Min(g, b)); var delta = max - min;
            if (delta == 0) return true;
            hue = max == r ? ((g - b) / delta % 6) / 6 : max == g ? ((b - r) / delta + 2) / 6 : ((r - g) / delta + 4) / 6;
            if (hue < 0) hue += 1;
            return true;
        }
        catch (FormatException) { return false; }
    }

    private void DependencyLog(string text)
    {
        DependencyLogLines.Add(new LogLine { Stream = LogStream.System, Text = text });
    }

    private void RefreshStarterTemplates()
    {
        StarterTemplates.Clear();
        foreach (var starter in StarterTemplatesForSelectedProfile())
        {
            StarterTemplates.Add(starter);
        }
    }

    private Brush BrushFor(ServerState state)
    {
        return state switch
        {
            ServerState.Running => _green,
            ServerState.Starting or ServerState.Stopping => _orange,
            ServerState.Failed => _red,
            _ => _muted
        };
    }

    private static string Localized(string source)
        => Localization.TryTranslateDynamic(source, out var translated) ? translated : Localization.T(source);

    private void Notify(string text, bool error = false)
    {
        BannerSeverity = error ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        BannerText = Localization.TryTranslateDynamic(text, out var translated) ? translated : text;
        IsBannerOpen = true;
    }

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
}
