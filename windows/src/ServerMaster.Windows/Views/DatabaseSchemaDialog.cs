using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Media;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Views;

public sealed class DatabaseSchemaDialog : ContentDialog
{
    private readonly string _database;
    private readonly ListView _tables = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly ListView _columns = new() { DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single };
    private readonly Button _dropColumn = new() { Content = "Drop column" };
    private readonly Button _editColumn = new() { Content = "Edit column" };
    private readonly Button _saveColumn = new() { Content = "Save changes", Visibility = Visibility.Collapsed };
    private readonly Button _cancelColumnEdit = new() { Content = "Cancel", Visibility = Visibility.Collapsed };
    private readonly ListView _indexes = new() { DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single, Height = 115 };
    private readonly ListView _indexColumns = new() { DisplayMemberPath = "Name", SelectionMode = ListViewSelectionMode.Multiple, Height = 110 };
    private readonly TextBox _indexName = new() { PlaceholderText = "Index name", Width = 200 };
    private readonly CheckBox _indexUnique = new() { Content = "Unique: refuse duplicate values" };
    private readonly Button _showIndexForm = new() { Content = "Add index" };
    private readonly Button _createIndex = new() { Content = "Create index" };
    private readonly Button _dropIndex = new() { Content = "Drop index" };
    private readonly StackPanel _indexForm = new() { Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly TextBox _statement = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 115, FontFamily = new FontFamily("Consolas") };
    private readonly TextBox _tableName = new() { PlaceholderText = "table name", Width = 180 };
    private readonly TextBox _columnName = new() { PlaceholderText = "column name", Width = 150 };
    private readonly ComboBox _columnType = new() { Width = 165, ItemsSource = DatabaseSchemaService.CommonTypes };
    private readonly CheckBox _nullable = new() { Content = "May be NULL", IsChecked = true, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _create = new() { Content = "Create table" };
    private readonly Button _add = new() { Content = "Add column" };
    private readonly Button _refresh = new() { Content = new SymbolIcon(Symbol.Refresh) };
    private readonly Button _rename = new() { Content = "Rename" };
    private readonly Button _empty = new() { Content = "Empty" };
    private readonly Button _drop = new() { Content = "Drop" };
    private readonly StackPanel _confirmation = new() { Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly TextBlock _confirmationText = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _newName = new() { PlaceholderText = "New table name", Width = 180 };
    private readonly InfoBar _problem = new() { Severity = InfoBarSeverity.Error, IsOpen = false };
    private bool _busy;
    private string? _pendingAction;
    private string? _pendingTable;
    private string? _pendingIndex;
    private string? _pendingColumn;
    private string? _editingColumn;

    public DatabaseSchemaDialog(string database)
    {
        _database = database;
        Title = "Structure - " + database;
        CloseButtonText = "Close";
        Resources["ContentDialogMaxWidth"] = 1100d;
        _columnType.SelectedIndex = 4;
        ToolTipService.SetToolTip(_refresh, "Refresh structure");

        var body = new Grid { Width = 920, Height = 540, RowSpacing = 12 };
        body.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var split = new Grid { ColumnSpacing = 16 };
        split.ColumnDefinitions.Add(new() { Width = new GridLength(190) });
        split.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var left = new Grid { RowSpacing = 8 };
        left.RowDefinitions.Add(new() { Height = GridLength.Auto });
        left.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(new TextBlock { Text = "Tables", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Grid.SetRow(_tables, 1); left.Children.Add(_tables);
        split.Children.Add(left);

        var rightContent = new StackPanel { Spacing = 10 };
        var right = new ScrollViewer { Content = rightContent, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        heading.Children.Add(new TextBlock { Text = "Columns", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        heading.Children.Add(_refresh);
        heading.Children.Add(_editColumn);
        heading.Children.Add(_dropColumn);
        rightContent.Children.Add(heading);
        var tableActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        tableActions.Children.Add(_rename); tableActions.Children.Add(_empty); tableActions.Children.Add(_drop);
        rightContent.Children.Add(tableActions);
        var confirmActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var confirm = new Button { Content = "Confirm" };
        var cancel = new Button { Content = "Cancel" };
        confirmActions.Children.Add(confirm); confirmActions.Children.Add(cancel);
        _confirmation.Children.Add(_confirmationText);
        _confirmation.Children.Add(_newName);
        _confirmation.Children.Add(confirmActions);
        rightContent.Children.Add(_confirmation);
        _columns.Height = 165;
        rightContent.Children.Add(_columns);
        var addRow = new StackPanel { Spacing = 6 };
        var addFields = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        addFields.Children.Add(_columnName); addFields.Children.Add(_columnType);
        var addActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        addActions.Children.Add(_nullable); addActions.Children.Add(_add);
        addActions.Children.Add(_saveColumn); addActions.Children.Add(_cancelColumnEdit);
        addRow.Children.Add(addFields); addRow.Children.Add(addActions);
        rightContent.Children.Add(addRow);
        var indexHeading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        indexHeading.Children.Add(new TextBlock { Text = "Indexes", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        indexHeading.Children.Add(_showIndexForm);
        indexHeading.Children.Add(_dropIndex);
        rightContent.Children.Add(indexHeading);
        rightContent.Children.Add(_indexes);
        _indexForm.Children.Add(_indexName);
        _indexForm.Children.Add(_indexUnique);
        _indexForm.Children.Add(new TextBlock { Text = "Columns, in order", Opacity = .7 });
        _indexForm.Children.Add(_indexColumns);
        var indexCommands = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        indexCommands.Children.Add(_createIndex);
        var cancelIndex = new Button { Content = "Cancel" };
        indexCommands.Children.Add(cancelIndex);
        _indexForm.Children.Add(indexCommands);
        rightContent.Children.Add(_indexForm);
        var sql = new StackPanel { Spacing = 5 };
        sql.Children.Add(new TextBlock { Text = "Create statement", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        sql.Children.Add(_statement);
        rightContent.Children.Add(sql);
        Grid.SetColumn(right, 1); split.Children.Add(right);
        body.Children.Add(split);
        var newTable = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        newTable.Children.Add(new TextBlock { Text = "New table", VerticalAlignment = VerticalAlignment.Center });
        newTable.Children.Add(_tableName); newTable.Children.Add(_create);
        Grid.SetRow(newTable, 1); body.Children.Add(newTable);
        Grid.SetRow(_problem, 2); body.Children.Add(_problem);
        Content = body;

        _tables.SelectionChanged += async (_, _) => { ClearConfirmation(); CancelColumnEdit(); _indexForm.Visibility = Visibility.Collapsed; if (!_busy) await LoadSelectedAsync(); };
        _refresh.Click += async (_, _) => await RefreshAsync();
        _rename.Click += (_, _) => PrepareConfirmation("rename");
        _empty.Click += (_, _) => PrepareConfirmation("empty");
        _drop.Click += (_, _) => PrepareConfirmation("drop");
        _dropColumn.Click += (_, _) => PrepareConfirmation("dropColumn");
        _editColumn.Click += (_, _) =>
        {
            if (_busy || _columns.SelectedItem is not DatabaseColumnInfo column) return;
            _editingColumn = column.Name;
            _columnName.Text = column.Name;
            _columnType.SelectedItem = DatabaseSchemaService.CommonTypes.FirstOrDefault(type => type.Equals(column.Type, StringComparison.OrdinalIgnoreCase));
            _nullable.IsChecked = column.Nullable;
            _add.Visibility = Visibility.Collapsed;
            _saveColumn.Visibility = _cancelColumnEdit.Visibility = Visibility.Visible;
        };
        _cancelColumnEdit.Click += (_, _) => CancelColumnEdit();
        _saveColumn.Click += async (_, _) =>
        {
            if (_tables.SelectedItem is not string table || _editingColumn is not string existing) return;
            await RunAsync(() => DatabaseSchemaService.ChangeColumnAsync(_database, table, existing, _columnName.Text.Trim(),
                _columnType.SelectedItem as string ?? "", _nullable.IsChecked == true), table);
            if (!_problem.IsOpen) CancelColumnEdit();
        };
        _columns.SelectionChanged += (_, _) =>
        {
            if (_editingColumn is not null && (_columns.SelectedItem as DatabaseColumnInfo)?.Name != _editingColumn)
                CancelColumnEdit();
            if (_pendingAction == "dropColumn") ClearConfirmation();
            _dropColumn.IsEnabled = !_busy && _tables.SelectedItem is string && _columns.SelectedItem is DatabaseColumnInfo;
            _editColumn.IsEnabled = !_busy && _tables.SelectedItem is string && _columns.SelectedItem is DatabaseColumnInfo;
        };
        _dropIndex.Click += (_, _) => PrepareConfirmation("dropIndex");
        _indexes.SelectionChanged += (_, _) =>
        {
            if (_pendingAction == "dropIndex") ClearConfirmation();
            _dropIndex.IsEnabled = !_busy && _tables.SelectedItem is string && _indexes.SelectedItem is DatabaseIndexInfo;
        };
        _indexColumns.SelectionChanged += (_, _) =>
            _createIndex.IsEnabled = !_busy && _tables.SelectedItem is string && _indexColumns.SelectedItems.Count > 0;
        _showIndexForm.Click += (_, _) => { _indexName.Text = ""; _indexUnique.IsChecked = false; _indexColumns.SelectedItems.Clear(); _indexForm.Visibility = Visibility.Visible; };
        cancelIndex.Click += (_, _) => _indexForm.Visibility = Visibility.Collapsed;
        _createIndex.Click += async (_, _) =>
        {
            if (_tables.SelectedItem is not string table) return;
            var chosen = _indexColumns.SelectedItems.OfType<DatabaseColumnInfo>().Select(column => column.Name).ToArray();
            var name = string.IsNullOrWhiteSpace(_indexName.Text) ? "idx_" + string.Join("_", chosen) : _indexName.Text.Trim();
            await RunAsync(() => DatabaseSchemaService.AddIndexAsync(_database, table, name, chosen, _indexUnique.IsChecked == true), table);
            if (!_problem.IsOpen) _indexForm.Visibility = Visibility.Collapsed;
        };
        cancel.Click += (_, _) => ClearConfirmation();
        confirm.Click += async (_, _) => await ConfirmTableActionAsync();
        _create.Click += async (_, _) => await RunAsync(
            () => DatabaseSchemaService.CreateTableAsync(_database, _tableName.Text.Trim()), _tableName.Text.Trim());
        _add.Click += async (_, _) =>
        {
            if (_tables.SelectedItem is not string table) return;
            await RunAsync(() => DatabaseSchemaService.AddColumnAsync(_database, table, _columnName.Text.Trim(),
                _columnType.SelectedItem as string ?? "", _nullable.IsChecked == true), table);
        };
        Loaded += async (_, _) =>
        {
            body.Width = Math.Max(500, Math.Min(920, XamlRoot.Size.Width - 110));
            body.Height = Math.Max(300, Math.Min(540, XamlRoot.Size.Height - 210));
            await RefreshAsync();
        };
    }

    private void PrepareConfirmation(string action)
    {
        if (_busy || _tables.SelectedItem is not string table) return;
        if (action == "dropIndex" && _indexes.SelectedItem is not DatabaseIndexInfo) return;
        if (action == "dropColumn" && _columns.SelectedItem is not DatabaseColumnInfo) return;
        _pendingAction = action;
        _pendingTable = table;
        _pendingIndex = action == "dropIndex" ? (_indexes.SelectedItem as DatabaseIndexInfo)?.Name : null;
        _pendingColumn = action == "dropColumn" ? (_columns.SelectedItem as DatabaseColumnInfo)?.Name : null;
        _newName.Visibility = action == "rename" ? Visibility.Visible : Visibility.Collapsed;
        _newName.Text = action == "rename" ? table : "";
        _confirmationText.Text = action switch
        {
            "rename" => $"Rename {table} to:",
            "empty" => $"Remove every row from {table}? The table remains, but the data cannot be recovered without a snapshot.",
            "dropIndex" => _pendingIndex == "PRIMARY"
                ? $"Remove the primary key from {table}? Row editing will be unavailable until a primary key is restored."
                : $"Drop index {_pendingIndex} from {table}? No row data is lost, but queries may become slower.",
            "dropColumn" => $"Drop column {_pendingColumn} from {table} and permanently delete its data? This cannot be undone without a snapshot.",
            _ => $"Drop {table} and all its data? This cannot be undone without a snapshot."
        };
        _confirmation.Visibility = Visibility.Visible;
    }

    private void ClearConfirmation()
    {
        _pendingAction = _pendingTable = _pendingIndex = _pendingColumn = null;
        _confirmation.Visibility = Visibility.Collapsed;
    }

    private void CancelColumnEdit()
    {
        _editingColumn = null;
        _columnName.Text = "";
        _columnType.SelectedIndex = 4;
        _nullable.IsChecked = true;
        _add.Visibility = Visibility.Visible;
        _saveColumn.Visibility = _cancelColumnEdit.Visibility = Visibility.Collapsed;
    }

    private async Task ConfirmTableActionAsync()
    {
        if (_busy || _pendingTable is not string table || _tables.SelectedItem is not string selected || selected != table) return;
        var action = _pendingAction;
        var index = _pendingIndex;
        var column = _pendingColumn;
        if (action == "dropIndex" && (_indexes.SelectedItem is not DatabaseIndexInfo chosen || chosen.Name != index)) return;
        if (action == "dropColumn" && (_columns.SelectedItem is not DatabaseColumnInfo chosenColumn || chosenColumn.Name != column)) return;
        var newName = _newName.Text.Trim();
        SetBusy(true);
        try
        {
            switch (action)
            {
                case "rename": await DatabaseSchemaService.RenameTableAsync(_database, table, newName); break;
                case "empty": await DatabaseSchemaService.EmptyTableAsync(_database, table); break;
                case "drop": await DatabaseSchemaService.DropTableAsync(_database, table); break;
                case "dropIndex" when index is not null: await DatabaseSchemaService.DropIndexAsync(_database, table, index); break;
                case "dropColumn" when column is not null: await DatabaseSchemaService.DropColumnAsync(_database, table, column); break;
                default: return;
            }
            ClearConfirmation();
        }
        catch (Exception ex) { ShowError(ex); return; }
        finally { SetBusy(false); }
        await RefreshAsync(action == "rename" ? newName : action is "empty" or "dropIndex" or "dropColumn" ? table : null);
    }

    private async Task RunAsync(Func<Task> action, string? selection)
    {
        if (_busy) return;
        SetBusy(true);
        try { await action(); _columnName.Text = ""; _tableName.Text = ""; }
        catch (Exception ex) { ShowError(ex); return; }
        finally { SetBusy(false); }
        await RefreshAsync(selection);
    }

    private async Task RefreshAsync(string? selection = null)
    {
        if (_busy) return;
        selection ??= _tables.SelectedItem as string;
        SetBusy(true);
        try
        {
            var tables = await DatabaseService.ListTablesAsync(_database);
            _tables.ItemsSource = tables;
            _tables.SelectedItem = tables.Contains(selection ?? "") ? selection : tables.FirstOrDefault();
        }
        catch (Exception ex) { ShowError(ex); return; }
        finally { SetBusy(false); }
        await LoadSelectedAsync();
    }

    private async Task LoadSelectedAsync()
    {
        if (_busy) return;
        if (_tables.SelectedItem is not string table)
        {
            _columns.ItemsSource = null;
            _indexes.ItemsSource = null;
            _indexColumns.ItemsSource = null;
            _statement.Text = "";
            SetBusy(false);
            return;
        }
        SetBusy(true);
        try
        {
            var columns = await DatabaseSchemaService.ColumnsAsync(_database, table);
            _columns.ItemsSource = columns;
            _indexColumns.ItemsSource = columns;
            _indexes.ItemsSource = await DatabaseSchemaService.IndexesAsync(_database, table);
            _statement.Text = await DatabaseSchemaService.CreateStatementAsync(_database, table);
        }
        catch (Exception ex) { ShowError(ex); }
        finally { SetBusy(false); }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _tables.IsEnabled = _refresh.IsEnabled = _create.IsEnabled = !busy;
        _add.IsEnabled = !busy && _tables.SelectedItem is string;
        _editColumn.IsEnabled = !busy && _tables.SelectedItem is string && _columns.SelectedItem is DatabaseColumnInfo;
        _saveColumn.IsEnabled = !busy && _editingColumn is not null;
        _cancelColumnEdit.IsEnabled = !busy;
        _rename.IsEnabled = _empty.IsEnabled = _drop.IsEnabled = !busy && _tables.SelectedItem is string;
        _showIndexForm.IsEnabled = !busy && _tables.SelectedItem is string;
        _dropColumn.IsEnabled = !busy && _tables.SelectedItem is string && _columns.SelectedItem is DatabaseColumnInfo;
        _dropIndex.IsEnabled = !busy && _tables.SelectedItem is string && _indexes.SelectedItem is DatabaseIndexInfo;
        _createIndex.IsEnabled = !busy && _tables.SelectedItem is string && _indexColumns.SelectedItems.Count > 0;
        if (busy) _problem.IsOpen = false;
    }

    private void ShowError(Exception ex) { _problem.Message = ex.Message; _problem.IsOpen = true; }
}
