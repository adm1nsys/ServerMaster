namespace ServerMaster.Windows.Models;

public sealed class AppSettings
{
    public bool FirstSetupCompleted { get; set; }
    public Guid? DefaultProfileId { get; set; }
    public Guid? LastSelectedProfileId { get; set; }
    public bool AutostartDefaultProfile { get; set; }
    public bool RestoreLastSection { get; set; } = true;
    public string LastSection { get; set; } = "Control";
    public bool OpenBrowserOnStart { get; set; }
    public bool StopServerOnQuit { get; set; } = true;
    public bool ConfirmBeforeStop { get; set; }
    public bool RestartOnCrash { get; set; }
    public bool CheckPortBeforeStart { get; set; } = true;
    public bool KillPortOccupantOnStart { get; set; }
    public int ConsoleBufferLines { get; set; } = 5000;
    public double ConsoleFontSize { get; set; } = 12;
    public bool AutoScrollConsole { get; set; } = true;
    public bool WriteLogsToFile { get; set; } = true;
    public int LogRetentionDays { get; set; } = 7;
    public bool PortsAutoRefresh { get; set; } = true;
    public bool PortReservationsEnabled { get; set; }
    public double PortsRefreshInterval { get; set; } = 5;
    public bool PortsIncludeUdp { get; set; }
    public bool PortsShowSystemProcesses { get; set; } = true;
    public bool ConfirmBeforeKill { get; set; } = true;
    public bool CheckDependenciesOnLaunch { get; set; } = true;
    public bool BackgroundEnabled { get; set; } = true;
    public double BackgroundHue { get; set; } = .62;
    public double BackgroundSpeed { get; set; } = 1;
    public double BackgroundSaturation { get; set; } = 1;
    public bool BackgroundFollowsServers { get; set; }
    public string SidebarStyle { get; set; } = "standard";
    public bool BackupsEnabled { get; set; }
    public string BackupDestination { get; set; } = "";
    public int BackupEvery { get; set; } = 1;
    public string BackupUnit { get; set; } = "days";
    public int BackupsToKeep { get; set; } = 10;
    public List<Guid> BackupProfileIds { get; set; } = [];
    public bool BackupIncludesDatabase { get; set; } = true;
    public bool BackupAllDatabases { get; set; }
    public DateTimeOffset? LastBackup { get; set; }
    public string Language { get; set; } = "";
    public string DefaultTerminalShell { get; set; } = "PowerShell";
    public string UpdateRepository { get; set; } = "adm1nsys/ServerMaster";
    public string UpdateVersionFile { get; set; } = "updates/windows.txt";
    public string UpdateBuildsFolder { get; set; } = "windows";
    public bool CheckUpdatesOnLaunch { get; set; }
    public DateTimeOffset? LastUpdateCheck { get; set; }
    public string DismissedUpdateVersion { get; set; } = "";
    public string DatabaseAdminTool { get; set; } = "adminer";
    public int DatabaseAdminPort { get; set; } = 8036;
    public int CertificateDefaultDays { get; set; } = 825;
    public string CertificateDefaultDomains { get; set; } = "localhost,127.0.0.1,::1";
    public List<string> ExtraPathEntries { get; set; } = [];
}
