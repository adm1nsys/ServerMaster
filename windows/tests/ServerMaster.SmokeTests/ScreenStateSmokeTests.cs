internal static class ScreenStateSmokeTests
{
    public static void Run()
    {
        var root = FindRepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows", "src", "ServerMaster.Windows", "MainWindow.xaml"));
        var files = File.ReadAllText(Path.Combine(root, "windows", "src", "ServerMaster.Windows", "Views", "SiteFilesView.xaml"));
        var viewModel = File.ReadAllText(Path.Combine(root, "windows", "src", "ServerMaster.Windows", "ViewModels", "MainViewModel.cs"));

        CheckAll(xaml, "Control", "ControlProfilesEmptyVisibility", "HealthProgressVisibility", "SelectedProfileIssueVisibility");
        CheckAll(xaml, "Profiles", "ProfilesEmptyVisibility", "ProfilesEditorVisibility", "SelectedProfilePrepareVisibility");
        CheckAll(xaml, "Database", "DatabaseProgressVisibility", "DatabaseProblemVisibility", "DatabaseEntriesEmptyVisibility", "DatabaseInstallVisibility");
        CheckAll(xaml, "Dependencies", "DependenciesProgressVisibility", "ErrorVisibility", "CanCheckDependencies");
        CheckAll(xaml, "Ports", "PortsProgressVisibility", "PortsProblemVisibility", "PortsEmptyVisibility");
        CheckAll(xaml, "Diagnostics", "DiagnosticsProgressVisibility", "DiagnosticProblemsVisibility", "TraceProfilesEmptyVisibility");
        CheckAll(files, "Files", "FilesProblemVisibility", "FilesEmptyVisibility");
        CheckAll(xaml, "Backups", "BackupWorkVisibility", "BackupProblemVisibility", "BackupEntriesEmptyVisibility");
        CheckAll(xaml, "Settings", "UpdateCheckingVisibility", "UpdateConfigurationProblemVisibility", "UpdateStatus");

        CheckAll(viewModel, "ViewModel state contract", "PortsProblemVisibility", "DatabaseProblemVisibility", "FilesEmptyVisibility",
            "BackupProblemVisibility", "DependenciesProgressVisibility", "TraceProfilesEmptyVisibility");
    }

    private static void CheckAll(string text, string screen, params string[] tokens)
    {
        var missing = tokens.Where(token => !text.Contains(token, StringComparison.Ordinal)).ToArray();
        if (missing.Length > 0) throw new Exception($"{screen} is missing state bindings: {string.Join(", ", missing)}");
        Console.WriteLine($"PASS Screen states: {screen} exposes empty, busy and error feedback where applicable");
    }

    private static string FindRepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            if (File.Exists(Path.Combine(directory.FullName, "windows", "PORT_PARITY.md"))) return directory.FullName;
        }
        throw new DirectoryNotFoundException("Could not locate the ServerMaster repository root.");
    }
}
