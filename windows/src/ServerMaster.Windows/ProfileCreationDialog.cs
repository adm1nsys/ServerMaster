using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using ServerMaster.Windows.ViewModels;
using System.Diagnostics;
using System.Security.Cryptography;
using Microsoft.UI.Xaml.Data;
using WinRT.Interop;

namespace ServerMaster.Windows;

public sealed class ProfileCreationDialog : ContentDialog
{
    private readonly MainWindow _owner;
    private readonly MainViewModel _model;
    private readonly ComboBox _templates = new() { HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "LocalizedTitle" };
    private readonly TextBox _templateSearch = new() { PlaceholderText = "Search templates" };
    private readonly StackPanel _galleryItems = new() { Spacing = 14 };
    private readonly StackPanel _gallery = new() { Spacing = 10 };
    private readonly Button _importTemplates = new() { Content = "Import..." };
    private readonly Button _exportUserTemplates = new() { Content = "Export my templates..." };
    private readonly TextBlock _selectedTemplateTitle = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly Button _backToGallery = new() { Content = "Back to templates" };
    private readonly ScrollViewer _fieldsScroll = new() { MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock _stepTitle = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly ProgressBar _stepProgress = new() { Minimum = 0, Maximum = 1 };
    private readonly Button _previousStep = new() { Content = "Back" };
    private readonly Button _nextStep = new() { Content = "Next" };
    private readonly Dictionary<WizardStep, StackPanel> _pages = [];
    private readonly List<WizardStep> _steps = [];
    private readonly TextBox _name = new();
    private readonly TextBox _folder = new();
    private readonly NumberBox _port = new() { Minimum = 1024, Maximum = 65535, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
    private readonly TextBox _entryFile = new() { Text = "server.js" };
    private readonly TextBox _command = new() { PlaceholderText = "npm run dev" };
    private readonly CheckBox _download = new() { Content = "Download project files", IsChecked = true };
    private readonly CheckBox _starter = new() { Content = "Create a starting file", IsChecked = true };
    private readonly ComboBox _starterKind = new() { Header = "Starting configuration", DisplayMemberPath = "LocalizedTitle", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly CheckBox _https = new() { Content = "HTTPS", IsChecked = false };
    private readonly CheckBox _createDatabase = new() { Content = "Create a database for this project", IsChecked = true };
    private readonly TextBox _databaseName = new() { PlaceholderText = "Database name" };
    private readonly PasswordBox _databasePassword = new() { PlaceholderText = "Database password" };
    private readonly StackPanel _databaseFields = new() { Spacing = 8 };
    private readonly CheckBox _trust = new() { Content = "Trust the generated certificate for my Windows account", IsChecked = false, Visibility = Visibility.Collapsed };
    private readonly StackPanel _requirements = new() { Spacing = 8 };
    private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _advice = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _problem = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
    private readonly ProgressBar _activity = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    private readonly ComboBox _php = new() { ItemsSource = Dependency.PhpBranches, HorizontalAlignment = HorizontalAlignment.Stretch, Header = "PHP version" };
    private readonly List<FrameworkElement> _inputs = [];
    private readonly Button _installAll = new() { Content = "Install missing software" };
    private readonly CheckBox _startWhenReady = new() { Content = "Start it and open it in the browser when ready", IsChecked = true };
    private readonly TextBlock _progress = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly StackPanel _entrySection = new() { Spacing = 5 };
    private readonly StackPanel _commandSection = new() { Spacing = 5 };
    private bool _busy;
    private bool _showingGallery;
    private int _stepIndex;

    private enum WizardStep { Folder, Name, Port, Database, Php, Https, EntryFile, Command, Software }

    public (string Name, string User, string Password)? CreatedDatabase { get; private set; }
    public bool CreatedDatabaseCredentialsStored { get; private set; }
    /// <summary>The profile this dialog created, or null when it was cancelled.</summary>
    public ServerProfile? CreatedProfile { get; private set; }
    public bool StartWhenReady => _startWhenReady.IsChecked == true;

    public ProfileCreationDialog(MainWindow owner, MainViewModel model, ProfileTemplate? initial)
    {
        _owner = owner;
        _model = model;
        Title = "New profile";
        PrimaryButtonText = "Create profile";
        CloseButtonText = "Cancel";
        DefaultButton = ContentDialogButton.Primary;
        XamlRoot = owner.Content.XamlRoot;
        PrimaryButtonClick += Create_Click;
        Closing += (_, args) => { if (_busy) args.Cancel = true; };
        _php.SelectionChanged += async (_, _) =>
        {
            if (ChosenTemplate is not { } template || template.Engine != "phpBuiltIn") return;
            try { await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase); }
            catch (Exception ex) { ShowProblem(ex.Message); }
            if (ChosenTemplate == template) RenderRequirements(template);
        };

        _templates.ItemsSource = model.ProfileTemplates;
        _templates.SelectionChanged += (_, _) => TemplateChanged();
        _templateSearch.TextChanged += (_, _) => RenderGallery();
        _importTemplates.Click += async (_, _) => await ImportTemplatesAsync();
        _exportUserTemplates.Click += async (_, _) =>
            await ExportTemplatesAsync(_model.ProfileTemplates.Where(template => template.IsUserDefined).ToArray(), "templates");
        _backToGallery.Click += (_, _) => ShowGallery();
        _folder.TextChanged += (_, _) => RefreshStarterChoice();
        _entryFile.TextChanged += (_, _) => RefreshStarterChoice();
        _https.Checked += HttpsChanged;
        _https.Unchecked += HttpsChanged;
        _createDatabase.Checked += DatabaseChoiceChanged;
        _createDatabase.Unchecked += DatabaseChoiceChanged;
        _entrySection.Children.Add(Label("Node entry file"));
        _entrySection.Children.Add(_entryFile);
        _commandSection.Children.Add(Label("Start command"));
        _commandSection.Children.Add(_command);

        var choose = new Button { Content = "Choose..." };
        choose.Click += async (_, _) =>
        {
            var selected = await _owner.PickFolderAsync();
            if (selected is not null) _folder.Text = selected.Path;
        };
        var folderRow = new Grid { ColumnSpacing = 8 };
        folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        folderRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(choose, 1);
        folderRow.Children.Add(_folder);
        folderRow.Children.Add(choose);

        var fields = new StackPanel { Spacing = 12, Width = 500 };
        var chosenTemplate = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        chosenTemplate.Children.Add(_backToGallery);
        chosenTemplate.Children.Add(_selectedTemplateTitle);
        fields.Children.Add(chosenTemplate);
        _templates.Visibility = Visibility.Collapsed;
        fields.Children.Add(_templates);
        fields.Children.Add(_summary);
        fields.Children.Add(_stepTitle);
        fields.Children.Add(_stepProgress);
        StackPanel Page(WizardStep step)
        {
            var page = new StackPanel { Spacing = 10, Visibility = Visibility.Collapsed };
            _pages[step] = page;
            fields.Children.Add(page);
            return page;
        }
        var folderPage = Page(WizardStep.Folder);
        folderPage.Children.Add(_advice);
        folderPage.Children.Add(folderRow);
        folderPage.Children.Add(_download);
        folderPage.Children.Add(_starter);
        folderPage.Children.Add(_starterKind);
        Page(WizardStep.Name).Children.Add(_name);
        Page(WizardStep.Port).Children.Add(_port);
        var databasePage = Page(WizardStep.Database);
        databasePage.Children.Add(new TextBlock { Text = "This project can use a separate MariaDB database. Other databases are untouched.", TextWrapping = TextWrapping.Wrap });
        databasePage.Children.Add(_createDatabase);
        _databaseFields.Children.Add(_databaseName);
        _databaseFields.Children.Add(_databasePassword);
        _databaseFields.Children.Add(new TextBlock { Text = "Use this name, user and password in the CMS installer. They will be shown again after creation.", TextWrapping = TextWrapping.Wrap, Opacity = .7 });
        databasePage.Children.Add(_databaseFields);
        Page(WizardStep.Php).Children.Add(_php);
        var httpsPage = Page(WizardStep.Https);
        httpsPage.Children.Add(_https);
        httpsPage.Children.Add(_trust);
        Page(WizardStep.EntryFile).Children.Add(_entrySection);
        Page(WizardStep.Command).Children.Add(_commandSection);
        var softwarePage = Page(WizardStep.Software);
        softwarePage.Children.Add(_requirements);
        softwarePage.Children.Add(_installAll);
        softwarePage.Children.Add(_startWhenReady);
        var stepActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        stepActions.Children.Add(_previousStep);
        stepActions.Children.Add(_nextStep);
        fields.Children.Add(stepActions);
        _previousStep.Click += (_, _) => { if (_stepIndex > 0) { _stepIndex--; ShowStep(); } else ShowGallery(); };
        _nextStep.Click += (_, _) => { if (ValidateStep()) { _stepIndex++; ShowStep(); } };
        _installAll.Click += InstallAll_Click;
        _inputs.AddRange(new FrameworkElement[] { _templates, _backToGallery, _name, _folder, choose, _port, _createDatabase, _databaseName, _databasePassword, _entryFile, _command, _download, _starter, _starterKind, _php, _https, _trust, _startWhenReady });
        // The step question is the visual label; screen readers need the field's own name.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_name, Localization.T("Name"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_folder, Localization.T("Folder"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_port, Localization.T("Port"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_entryFile, Localization.T("Entry file"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_command, Localization.T("Command"));
        _gallery.Children.Add(Label("What are you running?"));
        _gallery.Children.Add(_templateSearch);
        var shareActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        shareActions.Children.Add(_importTemplates);
        shareActions.Children.Add(_exportUserTemplates);
        _gallery.Children.Add(shareActions);
        _gallery.Children.Add(new ScrollViewer
        {
            Content = _galleryItems,
            MaxHeight = 360,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        });
        _fieldsScroll.Content = fields;
        var layout = new StackPanel { Spacing = 10, MaxWidth = 500 };
        layout.Children.Add(_activity);
        layout.Children.Add(_progress);
        layout.Children.Add(_problem);
        layout.Children.Add(_gallery);
        layout.Children.Add(_fieldsScroll);
        Content = layout;
        RenderGallery();
        if (initial is null) ShowGallery();
        else { _templates.SelectedItem = initial; ShowQuestions(); }
    }

    private static TextBlock Label(string text) => new() { Text = text, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };

    private ProfileTemplate? ChosenTemplate => _templates.SelectedItem as ProfileTemplate;
    private bool UseHttps => _https.IsChecked == true && ChosenTemplate?.Engine != "custom";
    private bool NeedDatabase => _steps.Contains(WizardStep.Database)
        ? _createDatabase.IsChecked == true : ChosenTemplate?.NeedsDatabase == true;

    private async void DatabaseChoiceChanged(object sender, RoutedEventArgs e)
    {
        _databaseFields.Visibility = _createDatabase.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        if (ChosenTemplate is not { } template) return;
        try { await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase); }
        catch (Exception ex) { ShowProblem(ex.Message); }
        if (ChosenTemplate == template) RenderRequirements(template);
    }

    private void ShowGallery()
    {
        _showingGallery = true;
        _templates.SelectedItem = null;
        _gallery.Visibility = Visibility.Visible;
        _fieldsScroll.Visibility = Visibility.Collapsed;
        PrimaryButtonText = "";
        DefaultButton = ContentDialogButton.None;
        IsPrimaryButtonEnabled = false;
    }

    private void ShowQuestions()
    {
        _showingGallery = false;
        _gallery.Visibility = Visibility.Collapsed;
        _fieldsScroll.Visibility = Visibility.Visible;
        _selectedTemplateTitle.Text = ChosenTemplate?.Title ?? "";
        _stepIndex = 0;
        ShowStep();
    }

    private void ConfigureSteps(ProfileTemplate template)
    {
        _steps.Clear();
        // One-click templates: the name and a free port are already filled in.
        if (template.QuickSetup)
        {
            _steps.AddRange([WizardStep.Folder, WizardStep.Software]);
            return;
        }
        if (template.Questions.Length > 0)
        {
            foreach (var question in template.Questions)
            {
                var step = question switch
                {
                    "folder" => WizardStep.Folder, "name" => WizardStep.Name,
                    "port" => WizardStep.Port, "database" => WizardStep.Database,
                    "phpVersion" => WizardStep.Php, "https" => WizardStep.Https,
                    "entryFile" => WizardStep.EntryFile, "command" => WizardStep.Command,
                    _ => (WizardStep?)null
                };
                if (step is { } value && !_steps.Contains(value) &&
                    (value != WizardStep.Php || template.Engine == "phpBuiltIn") &&
                    (value != WizardStep.Https || template.Engine != "custom") &&
                    (value != WizardStep.Database || template.PackageKind != "wordpress-w2p"))
                    _steps.Add(value);
            }
            foreach (var required in new[] { WizardStep.Folder, WizardStep.Name, WizardStep.Port })
                if (!_steps.Contains(required)) _steps.Insert(0, required);
            _steps.Add(WizardStep.Software);
            return;
        }
        _steps.AddRange([WizardStep.Folder, WizardStep.Name, WizardStep.Port]);
        if (template.NeedsDatabase && template.PackageKind != "wordpress-w2p") _steps.Add(WizardStep.Database);
        if (template.Engine == "phpBuiltIn") _steps.Add(WizardStep.Php);
        if (template.Id == "static-https") _steps.Add(WizardStep.Https);
        if (template.Engine == "nodeScript") _steps.Add(WizardStep.EntryFile);
        if (template.Engine == "custom") _steps.Add(WizardStep.Command);
        _steps.Add(WizardStep.Software);
    }

    private void ShowStep()
    {
        if (_showingGallery || _steps.Count == 0) return;
        var step = _steps[_stepIndex];
        foreach (var page in _pages) page.Value.Visibility = page.Key == step ? Visibility.Visible : Visibility.Collapsed;
        _stepTitle.Text = step switch
        {
            WizardStep.Folder => "Which folder?",
            WizardStep.Name => "What should it be called?",
            WizardStep.Port => "Which port?",
            WizardStep.Database => "Does it need a database?",
            WizardStep.Php => "Which PHP version?",
            WizardStep.Https => "Serve over HTTPS?",
            WizardStep.EntryFile => "Which file starts it?",
            WizardStep.Command => "Which command?",
            _ => "Required software"
        };
        _stepProgress.Maximum = _steps.Count;
        _stepProgress.Value = _stepIndex + 1;
        _previousStep.IsEnabled = !_busy;
        _nextStep.Visibility = _stepIndex == _steps.Count - 1 ? Visibility.Collapsed : Visibility.Visible;
        _nextStep.IsEnabled = !_busy;
        PrimaryButtonText = _stepIndex == _steps.Count - 1 ? "Create profile" : "";
        DefaultButton = _stepIndex == _steps.Count - 1 ? ContentDialogButton.Primary : ContentDialogButton.None;
        IsPrimaryButtonEnabled = !_busy && _stepIndex == _steps.Count - 1;
        _fieldsScroll.ChangeView(null, 0, null);
    }

    private bool ValidateStep()
    {
        _problem.IsOpen = false;
        switch (_steps[_stepIndex])
        {
            case WizardStep.Folder when string.IsNullOrWhiteSpace(_folder.Text):
                ShowProblem("Choose a project folder."); return false;
            case WizardStep.Folder when !Directory.Exists(AppPaths.Expand(_folder.Text.Trim())) &&
                                        _download.IsChecked != true && _starter.IsChecked != true:
                ShowProblem("This folder does not exist. Choose another folder or create a starting project."); return false;
            case WizardStep.Name when string.IsNullOrWhiteSpace(_name.Text):
                ShowProblem("Enter a profile name."); return false;
            case WizardStep.Port when double.IsNaN(_port.Value) || _port.Value is < 1024 or > 65535:
                ShowProblem("Choose a port between 1024 and 65535."); return false;
            case WizardStep.Port when !_model.IsAvailableProfilePort((int)_port.Value):
                ShowProblem($"Port {(int)_port.Value} is already in use. Choose another one."); return false;
            case WizardStep.Database when _createDatabase.IsChecked == true && !DatabaseService.IsValidName(_databaseName.Text.Trim()):
                ShowProblem("Use 1-64 letters, digits or underscores for the database name."); return false;
            case WizardStep.Database when _createDatabase.IsChecked == true && _databasePassword.Password.Length < 8:
                ShowProblem("Use at least eight characters for the database password."); return false;
            case WizardStep.EntryFile when string.IsNullOrWhiteSpace(_entryFile.Text):
                ShowProblem("Enter the file that starts this project."); return false;
            case WizardStep.Command when string.IsNullOrWhiteSpace(_command.Text):
                ShowProblem("Enter the command that starts this project."); return false;
        }
        return true;
    }

    private void RenderGallery()
    {
        _galleryItems.Children.Clear();
        _exportUserTemplates.IsEnabled = _model.ProfileTemplates.Any(template => template.IsUserDefined);
        if (_model.TemplatesLoadFailed)
            _galleryItems.Children.Add(new TextBlock { Text = "Saved templates could not be read. Built-in templates still work.", TextWrapping = TextWrapping.Wrap });
        var search = _templateSearch.Text.Trim();
        var matches = _model.ProfileTemplates.Where(template =>
            search.Length == 0 || template.Title.Contains(search, StringComparison.OrdinalIgnoreCase) ||
            template.Summary.Contains(search, StringComparison.OrdinalIgnoreCase) ||
            template.LocalizedTitle.Contains(search, StringComparison.OrdinalIgnoreCase) ||
            template.LocalizedSummary.Contains(search, StringComparison.OrdinalIgnoreCase));
        foreach (var category in matches.GroupBy(template => template.Category))
        {
            var group = new StackPanel { Spacing = 6 };
            group.Children.Add(new TextBlock { Text = Localization.T(category.Key), Opacity = .7, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            foreach (var template in category)
            {
                var content = new StackPanel { Spacing = 2 };
                content.Children.Add(new TextBlock { Text = template.LocalizedTitle, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                content.Children.Add(new TextBlock { Text = template.LocalizedSummary, TextWrapping = TextWrapping.Wrap, Opacity = .7 });
                var choose = new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(choose, template.ChoiceTitle);
                choose.Click += (_, _) => { _templates.SelectedItem = template; ShowQuestions(); };
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                row.Children.Add(choose);
                var export = new Button { Content = "Export", VerticalAlignment = VerticalAlignment.Center };
                export.Click += async (_, _) => await ExportTemplatesAsync([template], template.Id);
                Grid.SetColumn(export, 1);
                row.Children.Add(export);
                group.Children.Add(row);
                if (template.IsUserDefined)
                {
                    var remove = new Button { Content = "Delete template" };
                    remove.Click += (_, _) => { _model.RemoveUserTemplate(template); RenderGallery(); };
                    group.Children.Add(remove);
                }
            }
            _galleryItems.Children.Add(group);
        }
        if (_galleryItems.Children.Count == 0)
            _galleryItems.Children.Add(new TextBlock { Text = "No matching templates.", Opacity = .7 });
    }

    private async Task ImportTemplatesAsync()
    {
        try
        {
            var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
            picker.FileTypeFilter.Add(".smtemplate");
            picker.FileTypeFilter.Add(".json");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(_owner));
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            var imported = _model.ImportProfileTemplates(file.Path);
            RenderGallery();
            ShowMessage($"Imported {imported.Count} template(s).");
        }
        catch (Exception ex) { ShowProblem(ex.Message); }
    }

    private async Task ExportTemplatesAsync(IReadOnlyList<ProfileTemplate> templates, string name)
    {
        if (templates.Count == 0) return;
        try
        {
            // Narrator and Voice Access press buttons through a synchronous UI Automation call;
            // the save dialog cannot open inside it, so let that call return first.
            await Task.Yield();
            var picker = new global::Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = name };
            picker.FileTypeChoices.Add("ServerMaster template", [".smtemplate"]);
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(_owner));
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            _model.ExportProfileTemplates(templates, file.Path);
            ShowMessage("Template exported.");
        }
        catch (Exception ex) { ShowProblem(ex.Message); }
    }

    private void ShowMessage(string message)
    {
        _problem.Severity = InfoBarSeverity.Informational;
        _problem.Message = message;
        _problem.IsOpen = true;
    }

    private async void HttpsChanged(object sender, RoutedEventArgs e)
    {
        _trust.Visibility = UseHttps ? Visibility.Visible : Visibility.Collapsed;
        if (ChosenTemplate is not { } template) return;
        try { await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase); }
        catch (Exception ex) { ShowProblem(ex.Message); }
        if (ChosenTemplate == template) RenderRequirements(template);
    }
    private string SelectedPhp => _php.SelectedItem as string ?? (ChosenTemplate is { } template ? MainViewModel.DefaultPhp(template) : "8.3");

    private async void TemplateChanged()
    {
        var template = ChosenTemplate;
        if (template is null) return;
        _selectedTemplateTitle.Text = template.LocalizedTitle;
        _name.Text = template.LocalizedTitle;
        _folder.Text = _model.SuggestedFolder(template);
        _port.Value = _model.SuggestedPort;
        _summary.Text = template.LocalizedSummary;
        _advice.Text = template.LocalizedFolderAdvice;
        _entryFile.Text = template.NodeEntryFile;
        ConfigureSteps(template);
        _createDatabase.IsChecked = template.NeedsDatabase;
        _databaseName.Text = new string(template.Id.Take(48)
            .Select(character => char.IsAsciiLetterOrDigit(character) || character == '_' ? character : '_').ToArray())
            + "_" + (int)_port.Value;
        _databasePassword.Password = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant();
        _entrySection.Visibility = template.Engine == "nodeScript" ? Visibility.Visible : Visibility.Collapsed;
        _commandSection.Visibility = template.Engine == "custom" ? Visibility.Visible : Visibility.Collapsed;
        _download.Visibility = template.CanDownloadPackage ? Visibility.Visible : Visibility.Collapsed;
        _download.IsChecked = template.CanDownloadPackage;
        _starter.Visibility = template.Id is "static" or "spa" or "node-script" or "node-api" or "php" or "python" ? Visibility.Visible : Visibility.Collapsed;
        _starterKind.Visibility = _starter.Visibility;
        var preview = template.CreateProfile(_folder.Text, 8080);
        var starters = StarterTemplate.For(preview);
        _starterKind.ItemsSource = starters;
        _starterKind.SelectedItem = starters.First(item => item.Title == StarterTemplate.DefaultFor(preview).Title);
        _https.IsEnabled = template.Engine != "custom";
        _https.IsChecked = template.Id == "static-https" || template.Questions.Contains("https");
        RefreshStarterChoice();
        _php.Visibility = template.Engine == "phpBuiltIn" ? Visibility.Visible : Visibility.Collapsed;
        _php.SelectedItem = MainViewModel.DefaultPhp(template);
        _problem.IsOpen = false;
        var check = _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase);
        RenderRequirements(template);
        try
        {
            await check;
            if (ChosenTemplate == template) RenderRequirements(template);
        }
        catch (Exception ex) { ShowProblem(ex.Message); }
    }

    private void RefreshStarterChoice()
    {
        if (ChosenTemplate is not { } template || _starter.Visibility != Visibility.Visible) return;
        var file = template.Engine == "nodeScript" ? _entryFile.Text : template.IndexFile;
        _starter.IsChecked = !File.Exists(Path.Combine(_folder.Text, file));
    }

    private void RenderRequirements(ProfileTemplate template)
    {
        _requirements.Children.Clear();
        var statuses = _model.DependenciesFor(template, SelectedPhp, UseHttps, NeedDatabase);
        if (statuses.Count == 0)
        {
            _requirements.Children.Add(new TextBlock { Text = "Uses your own command." });
            return;
        }

        foreach (var status in statuses)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var description = new StackPanel { Spacing = 2 };
            description.Children.Add(Label(status.Dependency.Title));
            var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
            message.SetBinding(TextBlock.TextProperty, new Binding { Source = status, Path = new PropertyPath(nameof(status.Message)) });
            description.Children.Add(message);
            var activity = new ProgressBar { IsIndeterminate = status.Dependency.PhpVersion.Length == 0, Maximum = 100 };
            activity.SetBinding(ProgressBar.IsIndeterminateProperty, new Binding { Source = status, Path = new PropertyPath(nameof(status.IsIndeterminate)) });
            activity.SetBinding(VisibilityProperty, new Binding { Source = status, Path = new PropertyPath(nameof(status.ActivityVisibility)) });
            activity.SetBinding(ProgressBar.ValueProperty, new Binding { Source = status, Path = new PropertyPath(nameof(status.Progress)) });
            description.Children.Add(activity);
            row.Children.Add(description);
            if (!status.Installed && !status.Checking)
            {
                var install = new Button { Content = "Install", VerticalAlignment = VerticalAlignment.Center };
                var npmReady = status.Dependency.Command != "http-server" ||
                    _model.Dependencies.First(item => item.Dependency.Command == "npm").Installed;
                var wingetReady = status.Dependency.WingetId is null ||
                    _model.Dependencies.First(item => item.Dependency.Command == "winget").Installed;
                install.IsEnabled = npmReady && wingetReady;
                install.Click += async (_, _) =>
                {
                    if (_busy) return;
                    _busy = true;
                    SetBusy(true);
                    IsPrimaryButtonEnabled = false;
                    install.IsEnabled = false;
                    _progress.Text = $"Installing {status.Dependency.Title}...";
                    _progress.Visibility = Visibility.Visible;
                    try
                    {
                        await _model.InstallDependencyAsync(status);
                        await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase);
                        if (!status.Installed) ShowProblem($"Could not install {status.Dependency.Title}. {status.Message}");
                    }
                    catch (Exception ex) { ShowProblem(ex.Message); }
                    finally
                    {
                        _progress.Visibility = Visibility.Collapsed;
                        _busy = false;
                        SetBusy(false);
                        IsPrimaryButtonEnabled = true;
                        if (ChosenTemplate == template) RenderRequirements(template);
                    }
                };
                Grid.SetColumn(install, 1);
                row.Children.Add(install);
            }
            _requirements.Children.Add(row);
        }

        if (statuses.Any(status => !status.Installed && status.Dependency.WingetId is not null) &&
            !_model.Dependencies.First(status => status.Dependency.Command == "winget").Installed)
        {
            var setup = new StackPanel { Spacing = 5 };
            setup.Children.Add(new TextBlock { Text = "Windows Package Manager is needed to install the missing software.", TextWrapping = TextWrapping.Wrap });
            var guide = new Button { Content = "Get App Installer" };
            guide.Click += (_, _) => Process.Start(new ProcessStartInfo
            {
                FileName = "https://learn.microsoft.com/windows/package-manager/winget/",
                UseShellExecute = true
            });
            setup.Children.Add(guide);
            _requirements.Children.Add(setup);
        }
    }

    private async void Create_Click(Microsoft.UI.Xaml.Controls.ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (_busy || _showingGallery || _steps.Count == 0 || _stepIndex != _steps.Count - 1 || ChosenTemplate is null)
        {
            args.Cancel = true;
            return;
        }
        var deferral = args.GetDeferral();
        try
        {
            _busy = true;
            SetBusy(true);
            IsPrimaryButtonEnabled = false;
            CloseButtonText = "";
            _problem.IsOpen = false;
            _progress.Text = _download.IsChecked == true && ChosenTemplate.CanDownloadPackage
                ? $"Downloading {ChosenTemplate.Title}... This can take a few minutes."
                : "Creating profile...";
            _progress.Visibility = Visibility.Visible;
            CreatedProfile = await _model.CreateProfileAsync(ChosenTemplate, _name.Text, _folder.Text, (int)_port.Value,
                _download.IsChecked == true && ChosenTemplate.CanDownloadPackage,
                _starter.IsChecked == true && _starter.Visibility == Visibility.Visible,
                _entryFile.Text, _command.Text, SelectedPhp, UseHttps, _trust.IsChecked == true,
                _starterKind.SelectedItem as StarterTemplate, message => _progress.Text = message,
                _steps.Contains(WizardStep.Database) && _createDatabase.IsChecked == true,
                _databaseName.Text.Trim(), _databasePassword.Password);
            if (_steps.Contains(WizardStep.Database) && _createDatabase.IsChecked == true)
            {
                CreatedDatabase = (_databaseName.Text.Trim(), _databaseName.Text.Trim(), _databasePassword.Password);
                try { CreatedDatabaseCredentialsStored = DatabaseCredentialStore.Read(_databaseName.Text.Trim()) is not null; }
                catch { CreatedDatabaseCredentialsStored = false; }
            }
        }
        catch (Exception ex)
        {
            args.Cancel = true;
            ShowProblem(ex.Message);
        }
        finally
        {
            _busy = false;
            SetBusy(false);
            IsPrimaryButtonEnabled = true;
            CloseButtonText = "Cancel";
            _progress.Visibility = Visibility.Collapsed;
            deferral.Complete();
        }
    }

    private void ShowProblem(string message)
    {
        _problem.Severity = InfoBarSeverity.Error;
        _problem.Message = message;
        _problem.IsOpen = true;
    }

    private void SetBusy(bool busy)
    {
        foreach (var input in _inputs) if (input is Control control) control.IsEnabled = !busy;
        _activity.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _installAll.IsEnabled = !busy;
        _previousStep.IsEnabled = _nextStep.IsEnabled = !busy;
        IsPrimaryButtonEnabled = !busy && !_showingGallery && _steps.Count > 0 && _stepIndex == _steps.Count - 1;
    }

    private async void InstallAll_Click(object sender, RoutedEventArgs args)
    {
        if (_busy || ChosenTemplate is not { } template) return;
        _busy = true;
        SetBusy(true);
        _problem.IsOpen = false;
        _progress.Visibility = Visibility.Visible;
        try
        {
            await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase);
            RenderRequirements(template);
            foreach (var status in _model.DependenciesFor(template, SelectedPhp, UseHttps, NeedDatabase))
            {
                await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase);
                if (status.Installed) continue;
                _progress.Text = "Installing " + status.Dependency.Title + "...";
                await _model.InstallDependencyAsync(status);
            }
            await _model.CheckDependenciesForAsync(template, SelectedPhp, UseHttps, NeedDatabase);
            var missing = _model.DependenciesFor(template, SelectedPhp, UseHttps, NeedDatabase)
                .Where(status => !status.Installed)
                .Select(status => status.Dependency.Title + ": " + status.Message).ToList();
            if (missing.Count > 0) throw new InvalidOperationException(string.Join(Environment.NewLine, missing));
            _progress.Text = "All required software is ready.";
        }
        catch (Exception ex) { ShowProblem(ex.Message); }
        finally
        {
            _busy = false;
            SetBusy(false);
            RenderRequirements(template);
        }
    }
}
