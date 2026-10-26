using System.Diagnostics;
using System.Collections.Specialized;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Input;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using ServerMaster.Windows.ViewModels;
using ServerMaster.Windows.Views;
using Windows.Storage.Pickers;
using WinRT.Interop;
using Windows.System;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace ServerMaster.Windows
{
    public sealed partial class MainWindow : Window
    {
        public MainViewModel ViewModel { get; }
        private async void TraceProfile_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ServerProfile profile })
                await ViewModel.TraceProfileAsync(profile);
        }
        private TrayIconService? _tray;
        private bool _closing;
        private bool _closeReady;
        private bool _quitRequested;
        private bool _quitPrompt;
        private bool _initialized;
        private bool _loadingBasicAuthPassword;
        private int _portCheckVersion;
        private int _certificateStatusVersion;
        private INotifyCollectionChanged? _watchedConsoleLines;
        private bool _consoleScrollQueued;

        public MainWindow()
        {
            ViewModel = new MainViewModel(DispatcherQueue);
            // Chosen once per launch, like macOS: changing it in Settings applies after a restart.
            Localization.Initialize(ViewModel.InterfaceLanguage, packFolder: MainViewModel.TranslationsFolder);
            InitializeComponent();
            ViewModel.SelectedWindow = this;
            Root.DataContext = ViewModel;
            Ambient.Apply(ViewModel.BackgroundPalette, ViewModel.BackgroundSpeed, ViewModel.BackgroundEnabled);
            ViewModel.PropertyChanged += (_, args) =>
            {
                // The palette, speed and on/off all announce themselves through AppBackgroundBrush.
                if (args.PropertyName == nameof(MainViewModel.AppBackgroundBrush))
                    Ambient.Apply(ViewModel.BackgroundPalette, ViewModel.BackgroundSpeed, ViewModel.BackgroundEnabled);
            };
            ViewModel.PropertyChanged += (_, args) =>
            {
                if (string.IsNullOrEmpty(args.PropertyName) || args.PropertyName is nameof(MainViewModel.ConsoleLines) or nameof(MainViewModel.ConsoleDisplayLines)
                    or nameof(MainViewModel.SelectedConsoleTab) or nameof(MainViewModel.SelectedSection) or nameof(MainViewModel.AutoScrollConsole))
                    WatchConsoleLines();
                if (string.IsNullOrEmpty(args.PropertyName) || args.PropertyName == nameof(MainViewModel.ConsoleFontSize))
                {
                    if (ServerLogList.ItemsPanelRoot is Panel panel)
                        foreach (var item in panel.Children.OfType<ListViewItem>()) item.FontSize = ViewModel.ConsoleFontSize;
                }
                if (args.PropertyName == nameof(MainViewModel.SelectedSection))
                {
                    var item = Shell.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag as string == ViewModel.SelectedSection);
                    if (item is not null && !ReferenceEquals(item, Shell.SelectedItem)) Shell.SelectedItem = item;
                    QueueTranslation();
                }
            };
            WatchConsoleLines();
            Root.Loaded += async (_, _) =>
            {
                if (_initialized) return;
                _initialized = true;
                XamlTranslator.Apply(Root);
                await ViewModel.InitializeAsync();
                QueueTranslation();
                if (ViewModel.NeedsFirstSetup) await ShowFirstSetupAsync();
            };
            // Ctrl+C with nothing selected interrupts the running command, as in a terminal;
            // with a selection it still copies.
            var interrupt = new KeyboardAccelerator { Key = VirtualKey.C, Modifiers = VirtualKeyModifiers.Control, ScopeOwner = TerminalSurface };
            interrupt.Invoked += (accelerator, args) =>
            {
                if (TerminalSurface.SelectionLength > 0) return;
                args.Handled = true;
                _ = ViewModel.InterruptTerminalAsync();
            };
            TerminalSurface.KeyboardAccelerators.Add(interrupt);
            TerminalSurface.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
            // The macOS window has a 940 x 600 minimum; below it Files and Backups drop controls.
            if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
            {
                var scale = GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;
                presenter.PreferredMinimumWidth = (int)Math.Round(940 * scale);
                presenter.PreferredMinimumHeight = (int)Math.Round(600 * scale);
            }
            // The title bar and taskbar show the ServerMaster logo instead of the generic window icon.
            var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
            if (File.Exists(icon)) AppWindow.SetIcon(icon);
            _tray = new TrayIconService(this, ViewModel);
            SingleInstance.Listen(() => DispatcherQueue.TryEnqueue(() => { if (!_closeReady) BringToFront(); }));
            Shell.SelectedItem = Shell.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag as string == ViewModel.SelectedSection)
                ?? Shell.MenuItems.OfType<NavigationViewItem>().First(item => item.Tag as string == "Control");
            AppWindow.Closing += (closingWindow, args) =>
            {
                if (_closeReady) return;
                args.Cancel = true;
                if (_closing) return;
                if (!_quitRequested && ViewModel.KeepRunningInNotificationArea)
                {
                    // Servers keep running inside this process; the tray and a second launch reopen it.
                    AppWindow.Hide();
                    return;
                }
                _quitRequested = false;
                _ = ShutDownAndCloseAsync();
            };
            Closed += (_, _) =>
            {
                if (_watchedConsoleLines is not null) _watchedConsoleLines.CollectionChanged -= ConsoleLines_CollectionChanged;
                _tray?.Dispose();
            };
        }

        /// <summary>Shows the existing window, including one hidden in the notification area.</summary>
        public void BringToFront()
        {
            AppWindow.Show();
            var hwnd = WindowNative.GetWindowHandle(this);
            if (IsIconic(hwnd)) ShowWindow(hwnd, 9);
            Activate();
            SetForegroundWindow(hwnd);
        }

        /// <summary>
        /// Quit from the sidebar or tray: a real exit, unlike closing the window while the app
        /// keeps running in the notification area. Running servers are always stopped first.
        /// </summary>
        public async void RequestQuit()
        {
            if (_closing || _quitPrompt) return;
            // WinUI shows one ContentDialog at a time. Quitting under an open dialog (database
            // details, an editor with unsaved text) must not discard it or fail with a system error.
            if (Root.XamlRoot is { } root && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root)
                    .Any(popup => popup.Child is ContentDialog))
            {
                BringToFront();
                ViewModel.ReportError(Localization.T("Close the open dialog, then quit ServerMaster again."));
                return;
            }
            if (ViewModel.HasWorkToStopOnQuit)
            {
                BringToFront();
                _quitPrompt = true;
                try
                {
                    var dialog = new ContentDialog
                    {
                        XamlRoot = Root.XamlRoot, Title = "Quit ServerMaster?",
                        Content = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = "To quit safely, ServerMaster stops its running servers, database and admin panel and releases their ports. Nothing keeps running after the app exits." },
                        PrimaryButtonText = "Stop servers and quit", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
                    };
                    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                }
                catch (Exception ex) { ViewModel.ReportError(Localization.T("Could not ask before quitting.") + " " + ex.Message); return; }
                finally { _quitPrompt = false; }
            }
            _quitRequested = true;
            Close();
        }

        private async Task ShutDownAndCloseAsync()
        {
            if (ViewModel.Dependencies.Any(status => status.Busy) || !ViewModel.CanCreateBackups)
            {
                BringToFront();
                ViewModel.ReportTrayError("Wait for the installation or snapshot operation to finish before closing ServerMaster.");
                return;
            }
            _closing = true;
            ForceQuitPanel.Visibility = Visibility.Collapsed;
            var slow = new CancellationTokenSource();
            _ = Task.Delay(TimeSpan.FromSeconds(8), slow.Token).ContinueWith(_ =>
                    DispatcherQueue.TryEnqueue(() => { if (_closing && !_closeReady) ForceQuitPanel.Visibility = Visibility.Visible; }),
                TaskContinuationOptions.OnlyOnRanToCompletion);
            try
            {
                await ViewModel.ShutdownAsync();
                _closeReady = true;
                Close();
            }
            catch (Exception ex)
            {
                _closing = false;
                BringToFront();
                ViewModel.ReportTrayError("Could not finish shutting down: " + ex.Message);
            }
            finally { slow.Cancel(); }
        }

        private void ForceQuit_Click(object sender, RoutedEventArgs e) => ViewModel.ForceQuit();

        private async void CheckUpdates_Click(object sender, RoutedEventArgs e) => await ViewModel.CheckForUpdatesAsync();
        private void OpenUpdateRepository_Click(object sender, RoutedEventArgs e) => ViewModel.OpenUpdateRepository();
        private void OpenUpdateRelease_Click(object sender, RoutedEventArgs e) => ViewModel.OpenUpdateRelease();
        private void OpenAvailableUpdate_Click(object sender, RoutedEventArgs e) => ViewModel.OpenAvailableUpdate();
        private void DismissAvailableUpdate_Click(object sender, RoutedEventArgs e) => ViewModel.DismissAvailableUpdate();

        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);

        // Lists and templates realize after layout, so translate again once it settles.
        private void QueueTranslation() =>
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => XamlTranslator.Apply(Root));

        private void WatchConsoleLines()
        {
            var lines = ViewModel.SelectedConsoleTab?.IsTerminal == false ? ViewModel.ConsoleDisplayLines : null;
            if (!ReferenceEquals(lines, _watchedConsoleLines))
            {
                if (_watchedConsoleLines is not null) _watchedConsoleLines.CollectionChanged -= ConsoleLines_CollectionChanged;
                _watchedConsoleLines = lines;
                if (lines is not null) lines.CollectionChanged += ConsoleLines_CollectionChanged;
            }
            QueueConsoleScroll();
        }

        private void ConsoleLines_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => QueueConsoleScroll();

        private void QueueConsoleScroll()
        {
            if (_closeReady || _consoleScrollQueued || !ViewModel.AutoScrollConsole || ViewModel.SelectedSection != "Console") return;
            _consoleScrollQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                _consoleScrollQueued = false;
                if (_closeReady || !ViewModel.AutoScrollConsole || ViewModel.SelectedSection != "Console") return;
                if (ViewModel.SelectedConsoleTab?.IsTerminal == true) TerminalSurface.SelectionStart = TerminalSurface.Text.Length;
                else if (ServerLogList.Items.Count > 0) ServerLogList.ScrollIntoView(ServerLogList.Items[ServerLogList.Items.Count - 1]);
            });
        }

        private void Shell_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
        {
            if (args.SelectedItem is NavigationViewItem item && item.Tag is string section)
            {
                ViewModel.SelectSection(section);
            }
        }

        private async Task ShowFirstSetupAsync()
        {
            var templates = new ComboBox
            {
                Header = "First site",
                DisplayMemberPath = "ChoiceTitle",
                ItemsSource = ViewModel.ProfileTemplates,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                SelectedItem = ViewModel.ProfileTemplates.FirstOrDefault(item => item.Id == "static") ?? ViewModel.ProfileTemplates.FirstOrDefault()
            };
            var content = new StackPanel { Spacing = 12, Width = 440 };
            content.Children.Add(new TextBlock
            {
                Text = "Choose what you want to run. ServerMaster will check the required software and offer to install anything missing while creating your profile.",
                TextWrapping = TextWrapping.Wrap
            });
            content.Children.Add(templates);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Set up ServerMaster",
                Content = content,
                PrimaryButtonText = "Set up site",
                SecondaryButtonText = "Check software",
                CloseButtonText = "Later",
                DefaultButton = ContentDialogButton.Primary
            };
            var result = await dialog.ShowAsync();
            ViewModel.CompleteFirstSetup();
            if (result == ContentDialogResult.Primary)
            {
                Shell.SelectedItem = Shell.MenuItems.OfType<NavigationViewItem>().First(item => item.Tag as string == "Profiles");
                var creation = new ProfileCreationDialog(this, ViewModel, templates.SelectedItem as ProfileTemplate);
                await creation.ShowAsync();
                await ShowCreatedDatabaseAsync(creation.CreatedDatabase, creation.CreatedDatabaseCredentialsStored);
            }
            else if (result == ContentDialogResult.Secondary)
            {
                Shell.SelectedItem = Shell.MenuItems.OfType<NavigationViewItem>().First(item => item.Tag as string == "Dependencies");
            }
        }

        private void Profiles_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (sender is ListView list && list.SelectedItem is ServerProfile profile)
            {
                ViewModel.SelectProfile(profile);
                PermissionStatus.Text = "Not checked";
                PermissionProblems.Text = "";
                _ = RefreshProfilePortStatusAsync(profile, profile.Port);
                _ = RefreshCertificateStatusAsync(profile);
            }
        }

        private void ProfilePort_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
        {
            if (ViewModel.SelectedProfile is not { } profile || double.IsNaN(args.NewValue)) return;
            _ = RefreshProfilePortStatusAsync(profile, (int)args.NewValue);
        }

        private void ProfileHost_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (sender is TextBox host && ViewModel.SelectedProfile is { } profile)
            {
                var exposed = host.Text.Trim() is "0.0.0.0" or "::" or "[::]";
                NetworkExposureWarning.Visibility = exposed ? Visibility.Visible : Visibility.Collapsed;
                _ = RefreshProfilePortStatusAsync(profile, profile.Port, host.Text);
                _ = RefreshCertificateStatusAsync(profile, hostOverride: host.Text);
            }
        }

        private void ProfileHostPreset_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (sender is not ComboBox picker || picker.SelectedItem is not ComboBoxItem option ||
                option.Tag is not string host || ViewModel.SelectedProfile is not { } profile) return;
            profile.Host = host;
            picker.SelectedIndex = -1;
        }

        private void ProfileHostLocalOnly_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is { } profile) profile.Host = "127.0.0.1";
        }

        private void ProfileHttps_Changed(object sender, RoutedEventArgs e)
        {
            if (sender is CheckBox check && ViewModel.SelectedProfile is { } profile)
                _ = RefreshCertificateStatusAsync(profile, enabledOverride: check.IsChecked == true);
        }

        private void ProfileCertificatePath_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (sender is TextBox path && ViewModel.SelectedProfile is { } profile)
                _ = RefreshCertificateStatusAsync(profile, certificateOverride: path.Text);
        }

        private void ProfilePrivateKeyPath_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (sender is TextBox path && ViewModel.SelectedProfile is { } profile)
                _ = RefreshCertificateStatusAsync(profile, keyOverride: path.Text);
        }

        private async void ChooseProfileCertificateFile_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button { Tag: string kind } || ViewModel.SelectedProfile is not { } profile) return;
            try
            {
                var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
                foreach (var extension in kind == "key"
                    ? new[] { ".pem", ".key" }
                    : new[] { ".pem", ".crt", ".cer" })
                    picker.FileTypeFilter.Add(extension);
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                var file = await picker.PickSingleFileAsync();
                if (file is null || ViewModel.SelectedProfile?.Id != profile.Id) return;
                if (kind == "key") profile.PrivateKeyPath = file.Path;
                else profile.CertificatePath = file.Path;
                await RefreshCertificateStatusAsync(profile);
            }
            catch (Exception ex)
            {
                ProfileCertificateStatus.Text = "Could not choose the certificate file: " + ex.Message;
            }
        }

        private async Task RefreshCertificateStatusAsync(ServerProfile profile, string? hostOverride = null,
            string? certificateOverride = null, string? keyOverride = null, bool? enabledOverride = null)
        {
            if (ProfileCertificateStatus is null || MakeTrustedCertificateButton is null) return;
            var version = ++_certificateStatusVersion;
            if (!(enabledOverride ?? profile.HttpsEnabled))
            {
                ProfileCertificateStatus.Text = "HTTPS is off.";
                MakeTrustedCertificateButton.Visibility = Visibility.Collapsed;
                return;
            }
            ProfileCertificateStatus.Text = "Checking certificate...";
            MakeTrustedCertificateButton.Visibility = Visibility.Collapsed;
            var snapshot = new ServerProfile
            {
                Host = hostOverride ?? profile.Host,
                CertificatePath = certificateOverride ?? profile.CertificatePath,
                PrivateKeyPath = keyOverride ?? profile.PrivateKeyPath
            };
            try
            {
                var status = await Task.Run(() => LocalCertificates.Status(snapshot));
                if (version != _certificateStatusVersion || ViewModel.SelectedProfile?.Id != profile.Id) return;
                ProfileCertificateStatus.Text = status.Message;
                MakeTrustedCertificateButton.Visibility = status.State == CertificateTrustState.Trusted
                    ? Visibility.Collapsed : Visibility.Visible;
            }
            catch (Exception ex)
            {
                if (version != _certificateStatusVersion || ViewModel.SelectedProfile?.Id != profile.Id) return;
                ProfileCertificateStatus.Text = "Could not check certificate: " + ex.Message;
                MakeTrustedCertificateButton.Visibility = Visibility.Visible;
            }
        }

        private async Task RefreshProfilePortStatusAsync(ServerProfile profile, int port, string? hostOverride = null)
        {
            if (ProfilePortStatus is null || ProfilePortNote is null) return;
            var version = ++_portCheckVersion;
            var host = hostOverride ?? profile.Host;
            ProfilePortNote.Text = Localization.T(ProfilePortSuggestions.Find(port)?.Note ?? "Custom port");
            ProfilePortStatus.Text = Localization.T(port is < 1 or > 65535 ? "Invalid port" : "Checking...");
            if (port is < 1 or > 65535) return;
            await Task.Delay(200);
            try
            {
                var available = await ProfilePortSuggestions.IsAvailableAsync(host, port);
                if (version == _portCheckVersion && ViewModel.SelectedProfile?.Id == profile.Id)
                    ProfilePortStatus.Text = Localization.T(available ? "Free" : profile.IsActive ? "In use (profile running)" : "Busy");
            }
            catch (Exception ex)
            {
                if (version == _portCheckVersion && ViewModel.SelectedProfile?.Id == profile.Id)
                    ProfilePortStatus.Text = Localization.T("Cannot check:") + " " + ex.Message;
            }
        }

        private async void ChooseProfilePort_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || ViewModel.SelectedProfile is not { } profile) return;
            var preferred = profile.HttpsEnabled ? ProfilePortSuggestions.Https : ProfilePortSuggestions.Http;
            var alternate = profile.HttpsEnabled ? ProfilePortSuggestions.Http : ProfilePortSuggestions.Https;
            var presets = preferred.Concat(alternate).ToArray();
            var host = profile.Host;
            try
            {
                var available = await Task.WhenAll(presets.Select(item => ProfilePortSuggestions.IsAvailableAsync(host, item.Port)));
                if (ViewModel.SelectedProfile?.Id != profile.Id || profile.Host != host) return;
                var menu = new MenuFlyout();
                for (var index = 0; index < presets.Length; index++)
                {
                    if (index == preferred.Count) menu.Items.Add(new MenuFlyoutSeparator());
                    var preset = presets[index];
                    var choice = new MenuFlyoutItem { Text = $"{preset.Port} - {preset.Title}" + (available[index] ? "" : " (busy)") };
                    choice.Click += (_, _) => profile.Port = preset.Port;
                    menu.Items.Add(choice);
                }
                menu.Items.Add(new MenuFlyoutSeparator());
                var nearest = new MenuFlyoutItem { Text = "Nearest free" };
                nearest.Click += async (_, _) =>
                {
                    try
                    {
                        ProfilePortStatus.Text = Localization.T("Searching...");
                        var free = await Task.Run(() => ProfilePortSuggestions.NearestFreeAsync(host, profile.Port));
                        if (ViewModel.SelectedProfile?.Id != profile.Id || profile.Host != host) return;
                        if (free is { } value) profile.Port = value;
                        else ProfilePortStatus.Text = Localization.T("No free port found");
                    }
                    catch (Exception ex) { ProfilePortStatus.Text = Localization.T("Cannot find a port:") + " " + ex.Message; }
                };
                menu.Items.Add(nearest);
                menu.ShowAt(button);
            }
            catch (Exception ex) { ProfilePortStatus.Text = Localization.T("Cannot check ports:") + " " + ex.Message; }
        }

        private void BasicAuthPassword_DataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
        {
            if (sender is not PasswordBox passwordBox) return;
            _loadingBasicAuthPassword = true;
            passwordBox.Password = (sender.DataContext as ServerProfile)?.BasicAuthPassword ?? "";
            _loadingBasicAuthPassword = false;
        }

        private void BasicAuthPassword_Changed(object sender, RoutedEventArgs e)
        {
            if (_loadingBasicAuthPassword || sender is not PasswordBox { DataContext: ServerProfile profile } passwordBox) return;
            profile.BasicAuthPassword = passwordBox.Password;
        }

        private async void CheckProfilePermissions_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile || sender is not Button button) return;
            var root = profile.ExpandedRootPath;
            button.IsEnabled = false;
            PermissionStatus.Text = "Checking...";
            PermissionProblems.Text = "";
            try
            {
                var report = await Task.Run(() => SitePermissions.Check(root));
                if (ViewModel.SelectedProfile?.Id != profile.Id || ViewModel.SelectedProfile.ExpandedRootPath != root) return;
                PermissionStatus.Text = report.Problems.Count == 0
                    ? $"No problems found in {report.CheckedCount} checked items" + (report.Truncated ? " (scan limit reached)." : ".")
                    : $"{report.Problems.Count} problem(s) in {report.CheckedCount} checked items" + (report.Truncated ? " (scan limit reached)." : ".");
                PermissionProblems.Text = string.Join(Environment.NewLine,
                    report.Problems.Take(6).Select(item =>
                        (string.IsNullOrWhiteSpace(root) ? item.Path : Path.GetRelativePath(root, item.Path)) + ": " + item.Reason));
                if (report.Problems.Count > 6) PermissionProblems.Text += $"{Environment.NewLine}...and {report.Problems.Count - 6} more.";
            }
            catch (Exception ex) { PermissionStatus.Text = "Could not check permissions: " + ex.Message; }
            finally { button.IsEnabled = true; }
        }

        private void OpenProfilePermissionsFolder_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile) return;
            try { Process.Start(new ProcessStartInfo(profile.ExpandedRootPath) { UseShellExecute = true }); }
            catch (Exception ex) { PermissionStatus.Text = "Could not open site folder: " + ex.Message; }
        }

        private async void RenameProfile_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile) return;
            var name = new TextBox { Header = "Name", Text = profile.Name, MaxLength = 100 };
            var icon = new IconPicker(ServerProfile.EngineSymbol(profile.Engine), profile.IconGlyph);
            var error = new TextBlock { Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
            var fields = new StackPanel { Spacing = 12, Width = 420 };
            fields.Children.Add(name);
            fields.Children.Add(new TextBlock { Text = Localization.T("Profile icon"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            fields.Children.Add(icon);
            fields.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Rename profile",
                Content = fields, PrimaryButtonText = "Rename", CloseButtonText = "Cancel" };
            dialog.PrimaryButtonClick += (_, args) =>
            {
                if (string.IsNullOrWhiteSpace(name.Text))
                {
                    error.Text = "Enter a profile name.";
                    error.Visibility = Visibility.Visible;
                    args.Cancel = true;
                }
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            profile.Name = name.Text.Trim();
            profile.IconGlyph = icon.SelectedGlyph;
            ViewModel.SaveProfilesCommand.Execute(null);
        }

        private void Snapshot_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement element || !ViewModel.CanCreateBackups) return;
            var profile = element.DataContext is BackupTargetRow row ? row.Profile : element.DataContext as ServerProfile;
            if (profile is not null) ViewModel.CreateBackupCommand.Execute(profile);
        }

        private void DatabaseSnapshot_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: BackupTargetRow { Database: { } database } } && ViewModel.CanSnapshotDatabase)
                ViewModel.CreateDatabaseBackupCommand.Execute(database);
        }

        private async void ImportDatabase_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
                foreach (var extension in new[] { ".sql", ".gz", ".zip", ".tar", ".tgz" }) picker.FileTypeFilter.Add(extension);
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                var file = await picker.PickSingleFileAsync();
                if (file is not null) await ViewModel.ImportDatabaseAsync(file.Path);
            }
            catch (Exception ex) { ViewModel.ReportTrayError("Could not choose a database dump: " + ex.Message); }
        }

        private async void RestoreSnapshot_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: BackupEntry backup } || !ViewModel.CanCreateBackups) return;
            var profile = backup.ProfileId is { } id ? ViewModel.Profiles.FirstOrDefault(item => item.Id == id) : null;
            if (backup.Kind == "profile" && profile is null)
            {
                ViewModel.ReportTrayError("The profile belonging to this snapshot no longer exists.");
                return;
            }
            if (backup.Kind == "database")
            {
                if (!ViewModel.DatabaseStatus.Running)
                {
                    ViewModel.ReportTrayError("Start MariaDB before restoring a database snapshot.");
                    return;
                }
                var databaseDialog = new ContentDialog
                {
                    XamlRoot = Root.XamlRoot, Title = "Restore database snapshot?",
                    Content = new TextBlock { Text = $"Current data in \"{backup.DatabaseName}\" will be replaced by the snapshot from {backup.Taken.ToLocalTime():g}.", TextWrapping = TextWrapping.Wrap },
                    PrimaryButtonText = "Restore", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
                };
                if (await databaseDialog.ShowAsync() == ContentDialogResult.Primary)
                    await ViewModel.RestoreBackupAsync(backup, profile ?? new ServerProfile(), false, false, true);
                return;
            }
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(new TextBlock { Text = backup.Name + "\nTaken " + backup.Taken.ToLocalTime().ToString("g"), TextWrapping = TextWrapping.Wrap });
            var restoreSettings = new CheckBox { Content = "Settings", IsChecked = backup.Kind == "profile", IsEnabled = backup.Kind == "profile" };
            var restoreFiles = new CheckBox { Content = "Files in the site folder", IsChecked = backup.IncludesSite, IsEnabled = backup.IncludesSite };
            var restoreDatabase = new CheckBox { Content = backup.DatabaseName is { Length: > 0 } name ? $"Database \"{name}\"" : "Database", IsChecked = backup.IncludesDatabase, IsEnabled = backup.IncludesDatabase };
            content.Children.Add(restoreSettings); content.Children.Add(restoreFiles); content.Children.Add(restoreDatabase);
            if (backup.IncludesSite) content.Children.Add(new TextBlock { Text = "Current files are replaced. A copy is preserved beside the site folder.", TextWrapping = TextWrapping.Wrap });
            if (backup.IncludesDatabase) content.Children.Add(new TextBlock { Text = "Restoring the database replaces its current data and requires MariaDB to be running.", TextWrapping = TextWrapping.Wrap });
            var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Restore snapshot", Content = content, PrimaryButtonText = "Restore", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            void UpdateRestoreButton(object? _, RoutedEventArgs __) => dialog.IsPrimaryButtonEnabled =
                restoreSettings.IsChecked == true || restoreFiles.IsChecked == true || restoreDatabase.IsChecked == true;
            foreach (var choice in new[] { restoreSettings, restoreFiles, restoreDatabase })
            {
                choice.Checked += UpdateRestoreButton;
                choice.Unchecked += UpdateRestoreButton;
            }
            UpdateRestoreButton(null, new RoutedEventArgs());
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            await ViewModel.RestoreBackupAsync(backup, profile!, restoreSettings.IsChecked == true, restoreFiles.IsChecked == true, restoreDatabase.IsChecked == true);
        }

        private async void DeleteSnapshot_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: BackupEntry backup } || !ViewModel.CanCreateBackups) return;
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Delete snapshot?",
                Content = new TextBlock { Text = $"\"{backup.Name}\" and its saved files will be removed. This cannot be undone.", TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "Delete", CloseButtonText = "Keep", DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && ViewModel.CanCreateBackups)
                ViewModel.DeleteBackupCommand.Execute(backup);
        }

        private void ShowSnapshotFolder_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: BackupEntry backup }) return;
            try
            {
                if (!Directory.Exists(backup.FullPath)) throw new DirectoryNotFoundException("The snapshot folder is missing. Refresh Backups to update the list.");
                Process.Start(new ProcessStartInfo(backup.FullPath) { UseShellExecute = true });
            }
            catch (Exception ex) { ViewModel.ReportTrayError("Could not open snapshot folder: " + ex.Message); }
        }

        private void ProfilePrimary_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ServerProfile profile })
            {
                ViewModel.SelectProfile(profile);
                ViewModel.StartStopProfileCommand.Execute(profile);
            }
        }

        private void ProfileOpen_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ServerProfile profile })
            {
                ViewModel.OpenProfileCommand.Execute(profile);
            }
        }

        private void ProfileRestart_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ServerProfile profile })
            {
                ViewModel.RestartProfileCommand.Execute(profile);
            }
        }

        private void ProfileLogs_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ServerProfile profile }) ViewModel.ShowProfileLogs(profile);
        }

        private void ControlProfile_RightTapped(object sender, RightTappedRoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: ServerProfile profile } anchor) return;
            var menu = new MenuFlyout();
            void Add(string title, Action action, bool enabled = true)
            {
                var item = new MenuFlyoutItem { Text = title, IsEnabled = enabled };
                item.Click += (_, _) => { if (ViewModel.Profiles.Contains(profile)) action(); };
                menu.Items.Add(item);
            }
            Add("Configure", () => { ViewModel.SelectProfile(profile); ViewModel.SelectSection("Profiles"); });
            Add("Make default", () => { ViewModel.SelectProfile(profile); ViewModel.MakeDefaultProfileCommand.Execute(null); }, !profile.IsDefault);
            if (profile.IsRunning) Add("Restart", () => ViewModel.RestartProfileCommand.Execute(profile));
            menu.ShowAt(anchor);
            e.Handled = true;
        }

        private void DetectedUrlOpen_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: string url }) ViewModel.OpenUrl(url);
        }

        private void DetectedUrlCopy_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: string url }) ViewModel.CopyDatabaseValueCommand.Execute(url);
        }

        private async void PickRoot_Click(object sender, RoutedEventArgs e)
        {
            var folder = await PickFolderAsync();
            if (folder is not null && ViewModel.SelectedProfile is not null)
            {
                ViewModel.SelectedProfile.RootPath = folder.Path;
            }
        }

        private async void NewProfile_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new ProfileCreationDialog(this, ViewModel, null);
            await dialog.ShowAsync();
            await ShowCreatedDatabaseAsync(dialog.CreatedDatabase, dialog.CreatedDatabaseCredentialsStored);
            // Straight from "Create profile" to the running site: Control shows it starting and the
            // browser opens once it answers (templates open the browser on start).
            if (dialog.CreatedProfile is { } created && dialog.StartWhenReady)
            {
                ViewModel.SelectedSection = "Control";
                ViewModel.SelectedProfile = created;
                ControlProfileList.ScrollIntoView(created);
                await ViewModel.StartProfileAsync(created);
            }
        }

        private async Task ShowCreatedDatabaseAsync((string Name, string User, string Password)? credentials, bool stored)
        {
            if (credentials is not { } database) return;
            var details = new StackPanel { Spacing = 8, Width = 420 };
            details.Children.Add(new TextBlock { Text = stored
                ? "Enter these details in the CMS installer. The password is saved in Windows Credential Manager, not in the profile."
                : "Enter these details in the CMS installer and keep the password. Windows could not save it for later.", TextWrapping = TextWrapping.Wrap });
            details.Children.Add(new TextBlock { Text = "Host: 127.0.0.1    Port: 3307" });
            details.Children.Add(new TextBlock { Text = "Database: " + database.Name });
            details.Children.Add(new TextBlock { Text = "User: " + database.User });
            details.Children.Add(new TextBox { Header = "Password", Text = database.Password, IsReadOnly = true });
            var copy = new Button { Content = "Copy password" };
            copy.Click += (_, _) =>
            {
                var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
                data.SetText(database.Password);
                global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
            };
            details.Children.Add(copy);
            await new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Database ready",
                Content = details,
                CloseButtonText = "Done"
            }.ShowAsync();
        }

        private async void DatabaseCredentials_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: DatabaseEntry database }) return;
            try
            {
                var saved = DatabaseCredentialStore.Read(database.Name);
                if (saved is { } credentials)
                    await ShowCreatedDatabaseAsync((database.Name, credentials.User, credentials.Password), true);
                else
                    await new ContentDialog { XamlRoot = Root.XamlRoot, Title = "No saved credentials",
                        Content = "This database was not created by the profile wizard, or its password was not saved. Use the account details from your site configuration.",
                        CloseButtonText = "Done" }.ShowAsync();
            }
            catch (Exception ex)
            {
                await new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Could not read database credentials",
                    Content = ex.Message, CloseButtonText = "Done" }.ShowAsync();
            }
        }

        private async void EditEnvironment_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile) return;
            var rows = new List<(Grid Row, TextBox Key, TextBox Value)>();
            var fields = new StackPanel { Spacing = 8 };
            var error = new TextBlock { Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.IndianRed),
                TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };

            void AddRow(string key = "", string value = "")
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var keyBox = new TextBox { PlaceholderText = "KEY", Text = key };
                var valueBox = new TextBox { PlaceholderText = "value", Text = value };
                Grid.SetColumn(valueBox, 1);
                var remove = new Button { Content = "Remove" };
                Grid.SetColumn(remove, 2);
                remove.Click += (_, _) => { fields.Children.Remove(row); rows.RemoveAll(item => item.Row == row); };
                row.Children.Add(keyBox);
                row.Children.Add(valueBox);
                row.Children.Add(remove);
                rows.Add((row, keyBox, valueBox));
                fields.Children.Add(row);
            }

            foreach (var variable in profile.Environment) AddRow(variable.Key, variable.Value);
            var add = new Button { Content = "Add variable", HorizontalAlignment = HorizontalAlignment.Left };
            add.Click += (_, _) => AddRow();
            var content = new StackPanel { Spacing = 10, Width = 570 };
            content.Children.Add(new TextBlock { Text = "Variables are passed only to this profile's server process.",
                TextWrapping = TextWrapping.Wrap });
            content.Children.Add(new ScrollViewer { Content = fields, MaxHeight = 380,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
            content.Children.Add(add);
            content.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Environment variables",
                Content = content, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
            List<EnvVar>? result = null;
            dialog.PrimaryButtonClick += (_, args) =>
            {
                var variables = new List<EnvVar>();
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var (_, keyBox, valueBox) in rows)
                {
                    var key = keyBox.Text.Trim();
                    if (key.Length == 0 && valueBox.Text.Length == 0) continue;
                    if (!ServerProfile.IsValidEnvironmentKey(key))
                    {
                        error.Text = "Names must begin with a letter or underscore and contain only letters, digits or underscores.";
                        error.Visibility = Visibility.Visible;
                        args.Cancel = true;
                        return;
                    }
                    if (!seen.Add(key))
                    {
                        error.Text = $"{key} is listed more than once.";
                        error.Visibility = Visibility.Visible;
                        args.Cancel = true;
                        return;
                    }
                    variables.Add(new EnvVar { Key = key, Value = valueBox.Text });
                }
                result = variables;
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && result is not null)
            {
                profile.Environment = result;
                ViewModel.SaveProfilesCommand.Execute(null);
            }
        }

        private async void Certificates_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile) return;
            await new CertificateDialog(this, ViewModel, profile).ShowAsync();
            await RefreshCertificateStatusAsync(profile);
        }

        private async void MakeTrustedCertificate_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedProfile is not { } profile) return;
            await new CertificateDialog(this, ViewModel, profile, preferTrust: true).ShowAsync();
            await RefreshCertificateStatusAsync(profile);
        }

        private void CreateStarter_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: StarterTemplate starter }) ViewModel.CreateStarterFileCommand.Execute(starter);
        }

        private void DependencyAction_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: DependencyStatus status }) return;
            if (!status.Checked && !status.Busy && status.Error.Length == 0) _ = ViewModel.CheckDependencyAsync(status);
            else ViewModel.InstallOrRemoveDependencyCommand.Execute(status);
        }

        private void ShellCommand_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            if (e.Key == VirtualKey.Enter && ViewModel.CanRunShell)
            {
                ViewModel.RunShellCommand.Execute(null);
                e.Handled = true;
            }
        }

        private void TerminalSurface_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            // PreviewKeyDown: a multi-line TextBox consumes Enter before KeyDown is raised.
            if (sender is not TextBox box) return;
            var text = box.Text;
            var lineStart = Math.Max(text.LastIndexOf('\n'), text.LastIndexOf('\r')) + 1;
            if (ViewModel.SelectedConsoleTab?.Session is { } session && box.SelectionLength == 0 &&
                e.Key is VirtualKey.Up or VirtualKey.Down && box.SelectionStart >= lineStart)
            {
                var current = text[lineStart..].TrimStart('>', ' ');
                var recalled = e.Key == VirtualKey.Up ? session.PreviousCommand(current) : session.NextCommand();
                if (recalled is not null)
                {
                    box.Text = text[..lineStart] + "> " + recalled;
                    box.SelectionStart = box.Text.Length;
                    e.Handled = true;
                }
                return;
            }
            if (e.Key != VirtualKey.Enter)
            {
                // Typing goes to the command line, as in a terminal: a caret left inside earlier
                // output moves to the end first. Navigation keys and selections are left alone.
                if (box.SelectionLength == 0 && box.SelectionStart < Math.Max(text.LastIndexOf('\n'), text.LastIndexOf('\r')) + 1
                    && e.Key is not (VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End
                        or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Shift or VirtualKey.Control or VirtualKey.Menu
                        or VirtualKey.LeftShift or VirtualKey.RightShift or VirtualKey.LeftControl or VirtualKey.RightControl
                        or VirtualKey.LeftMenu or VirtualKey.RightMenu or VirtualKey.Tab or VirtualKey.Escape or VirtualKey.LeftWindows or VirtualKey.RightWindows))
                    box.SelectionStart = text.Length;
                return;
            }
            var line = text[lineStart..].TrimStart('>', ' ');
            // Write through the tab, not the box: output can arrive before the binding pushes the
            // box text back, which used to drop this line break.
            if (ViewModel.SelectedConsoleTab is { } tab) tab.TerminalText = text + Environment.NewLine;
            else box.Text += Environment.NewLine;
            // Replacing Text moves the caret to the start; the next command is typed at the end.
            box.SelectionStart = box.Text.Length;
            ViewModel.SendTerminalCommand(line);
            e.Handled = true;
        }

        private void TerminalSurface_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (ViewModel.AutoScrollConsole && sender is TextBox box) box.SelectionStart = box.Text.Length;
        }

        private void RestartTerminal_Click(object sender, RoutedEventArgs e) => ViewModel.RestartTerminal();

        private void ServerLogList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args) =>
            args.ItemContainer.FontSize = ViewModel.ConsoleFontSize;

        private void OpenCertificateFolder_Click(object sender, RoutedEventArgs e) => OpenFolder(AppPaths.Subdir("Certificates"));

        private void OpenDataFolder_Click(object sender, RoutedEventArgs e) => OpenFolder(AppPaths.Support);

        private async void ResetSettings_Click(object sender, RoutedEventArgs e)
        {
            if (!ViewModel.CanResetSettings) return;
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Reset all app settings?",
                Content = "Restore default preferences while keeping the default profile. Profiles, sites, databases and certificates will not be deleted. Existing snapshots stay in their original folder. Port reservations will be released; the web admin panel may need to be reopened.",
                PrimaryButtonText = "Reset", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try { ViewModel.ResetSettings(); }
            catch (Exception ex) { ViewModel.ReportTrayError("Could not reset settings: " + ex.Message); }
        }

        private async void ChooseScheduledProfiles_Click(object sender, RoutedEventArgs e)
        {
            var all = new CheckBox { Content = "All profiles", IsChecked = ViewModel.ScheduledBackupsIncludeAllProfiles };
            var profiles = new ListView
            {
                ItemsSource = ViewModel.Profiles.ToArray(), DisplayMemberPath = "Name", SelectionMode = ListViewSelectionMode.Multiple,
                MaxHeight = 320, IsEnabled = all.IsChecked != true
            };
            foreach (var profile in ViewModel.Profiles.Where(profile => ViewModel.ScheduledBackupProfileIds.Contains(profile.Id))) profiles.SelectedItems.Add(profile);
            var content = new StackPanel { Spacing = 12, MinWidth = 300 };
            content.Children.Add(all);
            content.Children.Add(profiles);
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "Automatic snapshots", Content = content,
                PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary
            };
            void Refresh()
            {
                profiles.IsEnabled = all.IsChecked != true;
                dialog.IsPrimaryButtonEnabled = all.IsChecked == true || profiles.SelectedItems.Count > 0;
            }
            all.Checked += (_, _) => Refresh();
            all.Unchecked += (_, _) => Refresh();
            profiles.SelectionChanged += (_, _) => Refresh();
            Refresh();
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            try { ViewModel.SetScheduledBackupProfiles(all.IsChecked == true, profiles.SelectedItems.OfType<ServerProfile>().Select(profile => profile.Id)); }
            catch (Exception ex) { ViewModel.ReportTrayError(ex.Message); }
        }

        private void OpenLogsFolder_Click(object sender, RoutedEventArgs e) => OpenFolder(AppPaths.Logs);

        private async void ClearOldLogs_Click(object sender, RoutedEventArgs e) => await ViewModel.CleanOldLogsAsync(report: true);

        private async void ChooseBackupDestination_Click(object sender, RoutedEventArgs e)
        {
            if (!ViewModel.CanCreateBackups) return;
            try
            {
                var folder = await PickFolderAsync();
                if (folder is not null) ViewModel.SetBackupDestination(folder.Path);
            }
            catch (Exception ex) { ViewModel.ReportTrayError("Could not choose snapshot folder: " + ex.Message); }
        }

        private static void OpenFolder(string path)
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }

        private ConsoleTab? _consoleMenuTab;

        private void ConsoleTab_DoubleTapped(object sender, Microsoft.UI.Xaml.Input.DoubleTappedRoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ConsoleTab { IsTerminal: true } tab }) _ = RenameConsoleTabAsync(tab);
        }

        // Rename, Restart shell and Close belong to terminal tabs, as in the macOS context menu.
        private void ConsoleTabMenu_Opening(object? sender, object e)
        {
            if (sender is not MenuFlyout menu) return;
            XamlTranslator.ApplyMenu(menu);
            _consoleMenuTab = (menu.Target as FrameworkElement)?.DataContext as ConsoleTab;
            if (_consoleMenuTab is not { IsTerminal: true }) { DispatcherQueue.TryEnqueue(menu.Hide); return; }
            if (menu.Items.OfType<MenuFlyoutItem>().LastOrDefault() is { } close)
                close.IsEnabled = ViewModel.ConsoleTabs.Count(tab => tab.IsTerminal) > 1;
        }

        private void RenameConsoleTab_Click(object sender, RoutedEventArgs e)
        {
            if (_consoleMenuTab is { } tab) _ = RenameConsoleTabAsync(tab);
        }

        private void RenameSelectedConsoleTab_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedConsoleTab is { IsTerminal: true } tab) _ = RenameConsoleTabAsync(tab);
        }

        private async Task RenameConsoleTabAsync(ConsoleTab tab)
        {
            var name = new TextBox { Text = tab.Title, SelectionStart = 0, SelectionLength = tab.Title.Length };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = Localization.T("Rename tab"), Content = name,
                PrimaryButtonText = Localization.T("Rename"), CloseButtonText = Localization.T("Cancel"), DefaultButton = ContentDialogButton.Primary
            };
            name.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { args.Handled = true; dialog.Hide(); ViewModel.RenameConsoleTab(tab, name.Text); } };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) ViewModel.RenameConsoleTab(tab, name.Text);
        }

        private void RestartConsoleTab_Click(object sender, RoutedEventArgs e) => ViewModel.RestartTerminal(_consoleMenuTab);

        private void CloseConsoleTab_Click(object sender, RoutedEventArgs e) => ViewModel.CloseConsoleTabCommand.Execute(_consoleMenuTab);

        private async void InterruptTerminal_Click(object sender, RoutedEventArgs e) => await ViewModel.InterruptTerminalAsync();

        private void ConsoleActionsMenu_Opening(object? sender, object e)
        {
            XamlTranslator.ApplyMenu(ConsoleActionsMenu);
            var terminal = ViewModel.SelectedConsoleTab?.IsTerminal == true;
            var terminalItems = terminal ? Visibility.Visible : Visibility.Collapsed;
            ConsoleTerminalSeparator.Visibility = ConsoleProfileRootItem.Visibility = ConsoleRestartShellItem.Visibility =
                ConsoleRenameTabItem.Visibility = ConsoleNewTabItem.Visibility = terminalItems;
            ConsoleProfileRootItem.IsEnabled = ViewModel.SelectedProfile is not null;
            var logFile = ViewModel.ConsoleLogFilePath;
            ConsoleRevealLogItem.Visibility = !terminal && File.Exists(logFile) ? Visibility.Visible : Visibility.Collapsed;
            if (logFile is not null) ConsoleRevealLogItem.Text = Localization.T("Show") + " " + Path.GetFileName(logFile);
        }

        private void ConsoleClear_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.SelectedConsoleTab?.IsTerminal == true) ViewModel.ClearShellCommand.Execute(null);
            else ViewModel.ClearConsoleLog();
        }

        private void ConsoleCopyAll_Click(object sender, RoutedEventArgs e)
        {
            var text = ViewModel.SelectedConsoleTab?.IsTerminal == true ? ViewModel.SelectedConsoleTab.TerminalText : ViewModel.ConsolePlainText;
            var package = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        }

        private async void ConsoleSave_Click(object sender, RoutedEventArgs e)
        {
            var tab = ViewModel.SelectedConsoleTab;
            if (tab is null) return;
            try
            {
                // Narrator and Voice Access press buttons through a synchronous UI Automation call;
                // the save dialog cannot open inside it, so let that call return first.
                await Task.Yield();
                var name = tab.IsTerminal ? "terminal" : string.Join("-", tab.Title.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
                var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = name.Length > 0 ? name : "server" };
                if (tab.IsTerminal) picker.FileTypeChoices.Add(Localization.T("Text"), [".txt"]);
                else picker.FileTypeChoices.Add(Localization.T("Log"), [".log", ".txt"]);
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                if (await picker.PickSaveFileAsync() is not { } file) return;
                await File.WriteAllTextAsync(file.Path, tab.IsTerminal ? tab.TerminalText : ViewModel.ConsoleLogText, new System.Text.UTF8Encoding(false));
            }
            catch (Exception ex) { ViewModel.ReportError(Localization.T("Could not save the log.") + " " + ex.Message); }
        }

        private async void ExportTranslation_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                await Task.Yield();
                var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = Localization.Effective.Code };
                picker.FileTypeChoices.Add(Localization.T("Translation"), [TranslationPacks.Extension]);
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                if (await picker.PickSaveFileAsync() is not { } file) return;
                if (ViewModel.ExportTranslationPack(file.Path))
                    Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file.Path}\"") { UseShellExecute = true });
            }
            catch (Exception ex) { ViewModel.ReportError(Localization.T("The translation could not be written.") + " " + ex.Message); }
        }

        private async void ImportTranslation_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                await Task.Yield();
                var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
                picker.FileTypeFilter.Add(TranslationPacks.Extension);
                picker.FileTypeFilter.Add("*");
                InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
                if (await picker.PickSingleFileAsync() is not { } file) return;
                ViewModel.ImportTranslationPack(file.Path);
            }
            catch (Exception ex) { ViewModel.ReportError(ex.Message); }
        }

        private void ConsoleExternalTerminal_Click(object sender, RoutedEventArgs e) => ViewModel.OpenExternalTerminal();

        private void ConsoleLogsFolder_Click(object sender, RoutedEventArgs e) => OpenFolder(AppPaths.Logs);

        private void ConsoleRevealLog_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel.ConsoleLogFilePath is { } path && File.Exists(path))
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }

        private void ConsoleProfileRoot_Click(object sender, RoutedEventArgs e) => ViewModel.GoToProfileRoot();

        private void ConsoleTab_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: ConsoleTab tab })
                ViewModel.SelectConsoleTab(tab);
        }

        private sealed record ShellChoice(string Kind, string Title) { public override string ToString() => Title; }

        private async void NewTerminalTab_Click(object sender, RoutedEventArgs e)
        {
            // Same names as the Default terminal setting, which also picks the preselected shell.
            var shell = new ComboBox
            {
                Header = "Shell",
                ItemsSource = new[] { new ShellChoice("PowerShell", "PowerShell"), new ShellChoice("CMD", Localization.T("Command Prompt")) },
                SelectedIndex = ViewModel.DefaultTerminalShell == "CMD" ? 1 : 0,
                HorizontalAlignment = HorizontalAlignment.Stretch
            };
            var dialog = new ContentDialog
            {
                Title = "New terminal tab",
                Content = shell,
                PrimaryButtonText = "Create",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = Root.XamlRoot
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                ViewModel.CreateTerminalTab((shell.SelectedItem as ShellChoice)?.Kind ?? "PowerShell");
        }

        private async void DependencyUpdateCheck_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: DependencyStatus status })
                await ViewModel.CheckRuntimeUpdateAsync(status);
        }

        private async void DependencyVersions_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button { DataContext: DependencyStatus status } button) return;
            button.IsEnabled = false;
            try
            {
                var node = status.Dependency.Command == "node";
                var versions = node ? new[] { "System" }.Concat(await NodeRuntime.VersionsAsync()).ToArray() : (await ViewModel.PackageVersionsAsync(status)).ToArray();
                var picker = new ComboBox { Header = "Release", ItemsSource = versions, SelectedItem = node ? NodeRuntime.ActiveDirectory is { } directory ? Path.GetFileName(directory) : "System" : versions.FirstOrDefault(), HorizontalAlignment = HorizontalAlignment.Stretch };
                var content = new StackPanel { Spacing = 12 };
                content.Children.Add(picker);
                content.Children.Add(new TextBlock { Text = node ? "Installs alongside system Node.js. The selected version and its npm are used by ServerMaster. Older releases may lack security fixes. System returns to your system installation." : status.Dependency.Command == "http-server" ? "Installs the selected http-server release globally with npm. Older releases may lack security fixes." : "Installs the selected release from Windows Package Manager. This changes the system package. Some installers require removing a newer version first. Older releases may lack security fixes. Existing MariaDB installations cannot be replaced here because their data needs migration.", TextWrapping = TextWrapping.Wrap, MaxWidth = 440 });
                var progress = new TextBlock { TextWrapping = TextWrapping.Wrap };
                content.Children.Add(progress);
                var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = status.Dependency.Title + " versions", Content = content, PrimaryButtonText = "Install / use", CloseButtonText = "Cancel" };
                dialog.PrimaryButtonClick += async (_, args) =>
                {
                    var deferral = args.GetDeferral();
                    dialog.IsPrimaryButtonEnabled = false; dialog.IsSecondaryButtonEnabled = false;
                    try
                    {
                        if (picker.SelectedItem is not string version) throw new InvalidOperationException("Select a version.");
                        progress.Text = "Installing and checking the selected release. Download progress is shown in Dependencies.";
                        if (node) await ViewModel.SelectNodeVersionAsync(version, message => progress.Text = message);
                        else await ViewModel.SelectPackageVersionAsync(status, version);
                    }
                    catch (Exception ex) { progress.Text = ex.Message; args.Cancel = true; }
                    finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
                };
                await dialog.ShowAsync();
            }
            catch (Exception ex) { ViewModel.ReportTrayError("Could not load dependency versions: " + ex.Message); }
            finally { button.IsEnabled = true; }
        }

        private async void DependencyUpdate_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: DependencyStatus status })
                await ViewModel.UpdateDependencyAsync(status);
        }

        private void OpenPort_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: PortEntry entry }) ViewModel.OpenPortCommand.Execute(entry);
        }

        private void PortDetails_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: PortEntry entry }) ViewModel.PortDetailsCommand.Execute(entry);
        }

        private void TerminatePort_Click(object sender, RoutedEventArgs e)
        {
            if (sender is FrameworkElement { DataContext: PortEntry entry }) ViewModel.TerminatePortCommand.Execute(entry);
        }

        private void FileEntry_Click(object sender, ItemClickEventArgs e)
        {
            if (e.ClickedItem is FileEntry entry) ViewModel.OpenFileCommand.Execute(entry);
        }

        private void RefreshProfileConfigFiles_Click(object sender, RoutedEventArgs e) => ViewModel.RefreshProfileConfigFiles();

        private async void OpenProfileConfigFile_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: ProfileConfigFile file }) return;
            try { Process.Start(new ProcessStartInfo(file.Path) { UseShellExecute = true }); }
            catch (Exception ex) { await ShowProfileConfigErrorAsync(ex.Message); }
        }

        private async void EditProfileConfigFile_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement { DataContext: ProfileConfigFile file } || !file.CanEdit) return;
            try
            {
                var document = await SiteFiles.LoadTextAsync(file.Path);
                var entry = new FileEntry { Name = file.Title, FullPath = file.Path, IsConfig = true };
                await new Views.SiteFileEditorDialog(entry, document) { XamlRoot = Root.XamlRoot }.ShowAsync();
                ViewModel.RefreshProfileConfigFiles();
            }
            catch (Exception ex) { await ShowProfileConfigErrorAsync(ex.Message); }
        }

        private async Task ShowProfileConfigErrorAsync(string message) =>
            await new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Configuration file",
                Content = message, CloseButtonText = "Done" }.ShowAsync();

        private async void PickWorkingDirectory_Click(object sender, RoutedEventArgs e)
        {
            var folder = await PickFolderAsync();
            if (folder is not null && ViewModel.SelectedProfile is not null)
            {
                ViewModel.SelectedProfile.WorkingDirectory = folder.Path;
            }
        }

        internal async Task<global::Windows.Storage.StorageFolder?> PickFolderAsync()
        {
            var picker = new FolderPicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary
            };
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            return await picker.PickSingleFolderAsync();
        }
    }
}
