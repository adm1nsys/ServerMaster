using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Input;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using ServerMaster.Windows.ViewModels;
using Windows.ApplicationModel.DataTransfer;

namespace ServerMaster.Windows.Views;

public sealed partial class SiteFilesView : UserControl
{
    private MainViewModel? _model;
    private readonly List<string> _crumbPaths = [];
    private bool _dialogOpen;

    public SiteFilesView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) => Connect();
        Loaded += (_, _) => Connect();
        Unloaded += (_, _) => { if (_model is not null) _model.PropertyChanged -= ModelChanged; _model = null; };
    }

    private void Connect()
    {
        if (_model is not null) _model.PropertyChanged -= ModelChanged;
        _model = DataContext as MainViewModel;
        if (_model is not null) _model.PropertyChanged += ModelChanged;
        RefreshBreadcrumbs();
    }

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.FilesPath) or nameof(MainViewModel.FilesRoot) or nameof(MainViewModel.FilesProfileName)) RefreshBreadcrumbs();
    }

    private void RefreshBreadcrumbs()
    {
        _crumbPaths.Clear();
        var labels = new List<string>();
        if (_model is { FilesRoot.Length: > 0, FilesPath.Length: > 0 } && SiteFiles.IsWithin(_model.FilesRoot, _model.FilesPath))
        {
            var path = _model.FilesRoot;
            labels.Add(_model.FilesProfileName);
            _crumbPaths.Add(path);
            var relative = Path.GetRelativePath(path, _model.FilesPath);
            if (relative != ".") foreach (var part in relative.Split(Path.DirectorySeparatorChar))
            {
                path = Path.Combine(path, part);
                labels.Add(part);
                _crumbPaths.Add(path);
            }
        }
        Breadcrumbs.ItemsSource = labels;
    }

    private void Breadcrumb_Click(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Index >= 0 && args.Index < _crumbPaths.Count) _model?.NavigateFiles(_crumbPaths[args.Index]);
    }

    private async void Entry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: FileEntry entry }) await OpenEntry(entry);
    }

    private async void Entry_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: FileEntry entry }) { e.Handled = true; await OpenEntry(entry); }
    }

    private async Task OpenEntry(FileEntry entry)
    {
        if (entry.IsLink) { await ShowError("Windows links cannot be browsed or edited here. Open the item in Explorer instead."); return; }
        if (entry.IsDirectory) _model?.NavigateFiles(entry.FullPath);
        else if (entry.CanEdit) await Edit(entry);
    }

    private async void Edit_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: FileEntry entry }) await Edit(entry);
    }

    private async Task Edit(FileEntry entry)
    {
        if (_dialogOpen) return;
        _dialogOpen = true;
        try
        {
            if (_model is null || !SiteFiles.IsWithinWithoutLinks(_model.FilesRoot, entry.FullPath))
                throw new IOException("This file is outside the profile or passes through a Windows link.");
            var document = await SiteFiles.LoadTextAsync(entry.FullPath);
            await new SiteFileEditorDialog(entry, document) { XamlRoot = XamlRoot }.ShowAsync();
            _model?.RefreshFiles();
        }
        catch (Exception ex) { await ShowError(ex.Message); }
        finally { _dialogOpen = false; }
    }

    private void Menu_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: FileEntry entry } anchor) return;
        var menu = new MenuFlyout();
        Add("Open with default app", () => Run(() => Process.Start(new ProcessStartInfo(entry.FullPath) { UseShellExecute = true })));
        if (!entry.IsDirectory) Add("Open with...", async () =>
        {
            try
            {
                var file = await global::Windows.Storage.StorageFile.GetFileFromPathAsync(entry.FullPath);
                await global::Windows.System.Launcher.LaunchFileAsync(file,
                    new global::Windows.System.LauncherOptions { DisplayApplicationPicker = true });
            }
            catch (Exception ex) { await ShowError(ex.Message); }
        });
        Add("Show in Explorer", () => Run(() => Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + entry.FullPath + "\"") { UseShellExecute = true })));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Rename...", async () => await Rename(entry));
        var suggestion = SiteFiles.DottedName(entry.Name);
        if (suggestion is not null) Add("Rename to " + suggestion, () => RenameTo(entry, suggestion));
        else if (entry.Name.StartsWith('.') && entry.Name.Length > 1) Add("Remove the leading dot", () => RenameTo(entry, entry.Name[1..]));
        Add("Get Info", async () => await new ContentDialog
        {
            XamlRoot = XamlRoot, Title = entry.Name, CloseButtonText = "Close",
            Content = new TextBlock { Text = $"{entry.FullPath}\n\n{entry.TypeLabel}\n{entry.SizeLabel}\nModified: {entry.ModifiedLabel}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
        }.ShowAsync());
        Add("Copy path", () => { var data = new DataPackage(); data.SetText(entry.FullPath); Clipboard.SetContent(data); });
        menu.ShowAt(anchor);

        void Add(string label, Action action) { var item = new MenuFlyoutItem { Text = label }; item.Click += (_, _) => action(); menu.Items.Add(item); }
    }

    private async Task Rename(FileEntry entry)
    {
        var name = new TextBox { Text = entry.Name, Header = "Name" };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var content = new StackPanel { Spacing = 10 };
        content.Children.Add(name); content.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Rename", Content = content, PrimaryButtonText = "Rename", CloseButtonText = "Cancel" };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try { SiteFiles.Rename(_model!.FilesRoot, entry, name.Text); _model.RefreshFiles(); }
            catch (Exception ex) { error.Text = ex.Message; args.Cancel = true; }
        };
        await dialog.ShowAsync();
    }

    private void RenameTo(FileEntry entry, string name) => Run(() => { SiteFiles.Rename(_model!.FilesRoot, entry, name); _model.RefreshFiles(); });
    private async void Run(Action action) { try { action(); } catch (Exception ex) { await ShowError(ex.Message); } }
    private async Task ShowError(string message) => await new ContentDialog { XamlRoot = XamlRoot, Title = "Files", Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, CloseButtonText = "Close" }.ShowAsync();
}
