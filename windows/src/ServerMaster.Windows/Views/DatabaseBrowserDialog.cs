using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using Windows.ApplicationModel.DataTransfer;

namespace ServerMaster.Windows.Views;

public sealed class DatabaseBrowserDialog : ContentDialog
{
    private readonly string _database;
    private readonly ListView _tables = new();
    private readonly ListView _rows = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0) };
    private readonly Grid _results = new();
    private readonly InfoBar _error = new() { IsOpen = false, Severity = InfoBarSeverity.Error };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ToggleButton _structure = new() { Content = "Structure" };
    private readonly Button _previous = new() { Content = new SymbolIcon(Symbol.Back) };
    private readonly Button _next = new() { Content = new SymbolIcon(Symbol.Forward) };
    private readonly Button _refresh = new() { Content = new SymbolIcon(Symbol.Refresh) };
    private readonly Button _run = new() { Content = "Run query" };
    private readonly Button _add = new() { Content = "Add row" };
    private readonly Button _edit = new() { Content = "Edit cell" };
    private readonly Button _delete = new() { Content = "Delete row" };
    private readonly ComboBox _editColumn = new() { Width = 170, DisplayMemberPath = "Name" };
    private readonly TextBox _editValue = new() { MinWidth = 220, PlaceholderText = "Value" };
    private readonly CheckBox _editNull = new() { Content = "NULL" };
    private readonly StackPanel _rowEditor = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly StackPanel _deletePrompt = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly TextBox _sql = new() { AcceptsReturn = true, MinHeight = 80, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _queryOutput = new() { IsReadOnly = true, AcceptsReturn = true, MaxHeight = 140, FontFamily = new FontFamily("Consolas"), Visibility = Visibility.Collapsed };
    private bool _busy;
    private bool _hasNext;
    private int _offset;
    private DatabaseResult? _currentResult;
    private IReadOnlyList<DatabaseColumnInfo> _columns = [];

    public DatabaseBrowserDialog(string database, bool structure = false)
    {
        _database = database;
        Title = database;
        CloseButtonText = "Close";
        Resources["ContentDialogMaxWidth"] = 1100d;
        _structure.IsChecked = structure;
        var body = new Grid { Width = 940, Height = 530, RowSpacing = 10 };
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var sqlToggle = new ToggleButton { Content = "SQL query" };
        toolbar.Children.Add(new TextBlock { Text = "127.0.0.1:3307", VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas") });
        toolbar.Children.Add(_structure); toolbar.Children.Add(sqlToggle); toolbar.Children.Add(_refresh);
        body.Children.Add(toolbar);
        ToolTipService.SetToolTip(_refresh, "Refresh tables");
        ToolTipService.SetToolTip(_previous, "Previous 100 rows");
        ToolTipService.SetToolTip(_next, "Next 100 rows");
        var split = new Grid { ColumnSpacing = 12 };
        split.ColumnDefinitions.Add(new() { Width = new GridLength(170) });
        split.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        _tables.SelectionMode = ListViewSelectionMode.Single;
        split.Children.Add(_tables);
        var right = new Grid { RowSpacing = 8 };
        right.RowDefinitions.Add(new() { Height = GridLength.Auto });
        right.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        right.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var editor = new StackPanel { Spacing = 6, Visibility = Visibility.Collapsed };
        editor.Children.Add(_sql); editor.Children.Add(_run); right.Children.Add(editor);
        sqlToggle.Checked += (_, _) => editor.Visibility = Visibility.Visible;
        sqlToggle.Unchecked += (_, _) => editor.Visibility = Visibility.Collapsed;
        var scroller = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = _results };
        Grid.SetRow(scroller, 1); right.Children.Add(scroller);
        Grid.SetRow(_queryOutput, 2); right.Children.Add(_queryOutput);
        Grid.SetColumn(right, 1); split.Children.Add(right);
        Grid.SetRow(split, 1); body.Children.Add(split);
        var footer = new StackPanel { Spacing = 8 };
        var paging = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        paging.Children.Add(_previous); paging.Children.Add(_next); paging.Children.Add(_status);
        var commands = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        commands.Children.Add(_add); commands.Children.Add(_edit); commands.Children.Add(_delete);
        footer.Children.Add(paging); footer.Children.Add(commands);
        Grid.SetRow(footer, 2); body.Children.Add(footer);
        var rowActions = new StackPanel { Spacing = 5 };
        var editInput = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        editInput.Children.Add(_editColumn);
        editInput.Children.Add(_editValue);
        editInput.Children.Add(_editNull);
        var saveEdit = new Button { Content = "Save cell" };
        var cancelEdit = new Button { Content = "Cancel" };
        var editCommands = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        editCommands.Children.Add(saveEdit);
        editCommands.Children.Add(cancelEdit);
        _rowEditor.Orientation = Orientation.Vertical;
        _rowEditor.Children.Add(editInput);
        _rowEditor.Children.Add(editCommands);
        rowActions.Children.Add(_rowEditor);
        _deletePrompt.Children.Add(new TextBlock { Text = "Delete the selected row?", VerticalAlignment = VerticalAlignment.Center });
        var confirmDelete = new Button { Content = "Delete" };
        var cancelDelete = new Button { Content = "Cancel" };
        _deletePrompt.Children.Add(confirmDelete);
        _deletePrompt.Children.Add(cancelDelete);
        rowActions.Children.Add(_deletePrompt);
        Grid.SetRow(rowActions, 3); body.Children.Add(rowActions);
        Grid.SetRow(_error, 4); body.Children.Add(_error);
        Content = body;
        _rows.SelectionChanged += (_, _) => UpdateRowActions();
        _editColumn.SelectionChanged += (_, _) => PopulateEditValue();
        _editNull.Checked += (_, _) => _editValue.IsEnabled = false;
        _editNull.Unchecked += (_, _) => _editValue.IsEnabled = true;
        _add.Click += async (_, _) => await ChangeRow(async () =>
            await DatabaseRowService.InsertEmptyRowAsync(_database, (string)_tables.SelectedItem, _columns));
        _edit.Click += (_, _) => { _deletePrompt.Visibility = Visibility.Collapsed; _rowEditor.Visibility = Visibility.Visible; _editColumn.ItemsSource = _columns; _editColumn.SelectedItem = _columns.FirstOrDefault(); };
        _delete.Click += (_, _) => { _rowEditor.Visibility = Visibility.Collapsed; _deletePrompt.Visibility = Visibility.Visible; };
        saveEdit.Click += async (_, _) => await ChangeRow(async () =>
            await DatabaseRowService.UpdateCellAsync(_database, (string)_tables.SelectedItem, _currentResult!,
                (DatabaseRow)_rows.SelectedItem, _columns, ((DatabaseColumnInfo)_editColumn.SelectedItem).Name,
                _editNull.IsChecked == true ? null : _editValue.Text));
        confirmDelete.Click += async (_, _) => await ChangeRow(async () =>
            await DatabaseRowService.DeleteRowAsync(_database, (string)_tables.SelectedItem, _currentResult!,
                (DatabaseRow)_rows.SelectedItem, _columns));
        cancelEdit.Click += (_, _) => _rowEditor.Visibility = Visibility.Collapsed;
        cancelDelete.Click += (_, _) => _deletePrompt.Visibility = Visibility.Collapsed;
        _tables.SelectionChanged += async (_, _) => { if (!_busy) { _offset = 0; await LoadTable(); } };
        _structure.Click += async (_, _) => { _offset = 0; await LoadTable(); };
        _refresh.Click += async (_, _) => await LoadTables();
        _previous.Click += async (_, _) => { _offset = Math.Max(0, _offset - 100); await LoadTable(); };
        _next.Click += async (_, _) => { _offset += 100; await LoadTable(); };
        _run.Click += async (_, _) =>
        {
            if (_busy) return;
            SetBusy(true);
            try { _queryOutput.Text = await DatabaseService.RunQueryAsync(_database, _sql.Text); _queryOutput.Visibility = Visibility.Visible; }
            catch (Exception ex) { ShowError(ex); }
            finally { SetBusy(false); }
            await LoadTables();
        };
        Loaded += async (_, _) =>
        {
            body.Width = Math.Max(500, Math.Min(940, XamlRoot.Size.Width - 110));
            body.Height = Math.Max(270, Math.Min(530, XamlRoot.Size.Height - 210));
            await LoadTables();
        };
    }

    private async Task LoadTables()
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            var selected = _tables.SelectedItem as string;
            var tables = await DatabaseService.ListTablesAsync(_database);
            _tables.ItemsSource = tables;
            _tables.SelectedItem = tables.Contains(selected ?? "") ? selected : tables.FirstOrDefault();
            _offset = 0;
        }
        catch (Exception ex) { ShowError(ex); }
        finally { SetBusy(false); }
        await LoadTable();
    }

    private async Task LoadTable()
    {
        if (_busy) return;
        _results.Children.Clear(); _results.RowDefinitions.Clear();
        _rowEditor.Visibility = _deletePrompt.Visibility = Visibility.Collapsed;
        _currentResult = null;
        _columns = [];
        _hasNext = false;
        if (_tables.SelectedItem is not string table) { _status.Text = "No tables"; SetBusy(false); return; }
        SetBusy(true);
        try
        {
            var structure = _structure.IsChecked == true;
            var result = await DatabaseService.BrowseTableAsync(_database, table, _offset, structure);
            _currentResult = result;
            if (!structure) _columns = await DatabaseSchemaService.ColumnsAsync(_database, table);
            _hasNext = !structure && result.Rows.Count > 100;
            var rows = result.Rows.Take(structure ? int.MaxValue : 100).ToArray();
            _results.Width = Math.Max(180, result.Columns.Count * 180);
            _results.RowDefinitions.Add(new() { Height = GridLength.Auto });
            _results.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
            var header = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var column in result.Columns) header.Children.Add(new TextBlock { Text = column, Width = 180, Padding = new Thickness(8), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            _results.Children.Add(header);
            var cells = string.Concat(Enumerable.Range(0, result.Columns.Count).Select(index => $"<TextBlock Width='180' Padding='8' Text='{{Binding Cells[{index}]}}' TextTrimming='CharacterEllipsis' ToolTipService.ToolTip='{{Binding Cells[{index}]}}'/>"));
            var template = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><StackPanel Orientation='Horizontal'>" + cells + "</StackPanel></DataTemplate>");
            _rows.ItemsSource = rows;
            _rows.ItemTemplate = template;
            var menu = new MenuFlyout();
            var copy = new MenuFlyoutItem { Text = "Copy selected row" };
            copy.Click += (_, _) => { if (_rows.SelectedItem is DatabaseRow row) { var data = new DataPackage(); data.SetText(string.Join("\t", row.Cells)); Clipboard.SetContent(data); } };
            menu.Items.Add(copy); _rows.ContextFlyout = menu;
            Grid.SetRow(_rows, 1); _results.Children.Add(_rows);
            _status.Text = structure ? $"{rows.Length} columns" : rows.Length == 0 ? "No rows" :
                $"Rows {_offset + 1}-{_offset + rows.Length}" + (_columns.Any(column => column.Key == "PRI") ? "" : " (read-only: no primary key)");
        }
        catch (Exception ex) { ShowError(ex); }
        finally { SetBusy(false); }
    }

    private void PopulateEditValue()
    {
        if (_editColumn.SelectedItem is not DatabaseColumnInfo column || _rows.SelectedItem is not DatabaseRow row || _currentResult is null) return;
        var index = _currentResult.Columns.ToList().FindIndex(name => name.Equals(column.Name, StringComparison.OrdinalIgnoreCase));
        if (index < 0 || index >= row.Values.Count) return;
        _editNull.IsChecked = row.Values[index] is null;
        _editValue.Text = row.Values[index] ?? "";
        _editNull.IsEnabled = column.Nullable;
    }

    private async Task ChangeRow(Func<Task> change)
    {
        if (_busy) return;
        SetBusy(true);
        try { await change(); _rowEditor.Visibility = _deletePrompt.Visibility = Visibility.Collapsed; }
        catch (Exception ex) { ShowError(ex); SetBusy(false); return; }
        SetBusy(false);
        await LoadTable();
    }

    private void UpdateRowActions()
    {
        var editable = !_busy && _structure.IsChecked != true && _columns.Any(column => column.Key == "PRI") && _rows.SelectedItem is DatabaseRow;
        _add.IsEnabled = !_busy && _structure.IsChecked != true && _tables.SelectedItem is string;
        _edit.IsEnabled = editable;
        _delete.IsEnabled = editable;
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _tables.IsEnabled = _structure.IsEnabled = _refresh.IsEnabled = _run.IsEnabled = !busy;
        _previous.IsEnabled = !busy && _structure.IsChecked != true && _offset > 0;
        _next.IsEnabled = !busy && _hasNext;
        UpdateRowActions();
        if (busy) { _status.Text = "Loading..."; _error.IsOpen = false; }
    }
    private void ShowError(Exception ex) { _error.Message = ex.Message; _error.IsOpen = true; _status.Text = "Could not load data"; }
}
