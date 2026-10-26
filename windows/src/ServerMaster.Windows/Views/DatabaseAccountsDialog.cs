using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Views;

public sealed class DatabaseAccountsDialog : ContentDialog
{
    private readonly string _database;
    private readonly ListView _accounts = new() { DisplayMemberPath = "Display", SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _grants = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _name = new() { PlaceholderText = "User name" };
    private readonly TextBox _host = new() { Text = "localhost", PlaceholderText = "Host" };
    private readonly PasswordBox _password = new() { PlaceholderText = "Password" };
    private readonly Button _create = new() { Content = "Create user" };
    private readonly Button _changePassword = new() { Content = "Change password" };
    private readonly Button _grantAll = new() { Content = "Grant full access" };
    private readonly Button _grantRead = new() { Content = "Grant read only" };
    private readonly Button _revoke = new() { Content = "Revoke access" };
    private readonly Button _drop = new() { Content = "Delete user" };
    private readonly Button _confirm = new() { Content = "Confirm" };
    private readonly StackPanel _confirmation = new() { Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly TextBlock _confirmationText = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _problem = new() { Severity = InfoBarSeverity.Error, IsOpen = false };
    private DatabaseAccount? _pendingAccount;
    private string? _pendingAction;
    private bool _busy;

    public DatabaseAccountsDialog(string database)
    {
        _database = database;
        Title = "Accounts - " + database;
        CloseButtonText = "Close";
        Resources["ContentDialogMaxWidth"] = 1050d;

        var body = new Grid { Width = 870, Height = 510, ColumnSpacing = 18, RowSpacing = 10 };
        body.ColumnDefinitions.Add(new() { Width = new GridLength(245) });
        body.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var left = new StackPanel { Spacing = 8 };
        left.Children.Add(new TextBlock { Text = "Users", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        left.Children.Add(_accounts);
        body.Children.Add(left);

        var right = new StackPanel { Spacing = 10 };
        right.Children.Add(new TextBlock { Text = $"Privileges on {_database}", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        right.Children.Add(new ScrollViewer { Content = _grants, MaxHeight = 125 });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        actions.Children.Add(_grantAll); actions.Children.Add(_grantRead); actions.Children.Add(_revoke);
        right.Children.Add(actions);
        right.Children.Add(new TextBlock { Text = "User account", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var identity = new Grid { ColumnSpacing = 8 };
        identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        identity.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        identity.Children.Add(_name);
        Grid.SetColumn(_host, 1); identity.Children.Add(_host);
        right.Children.Add(identity);
        right.Children.Add(_password);
        var accountActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        accountActions.Children.Add(_create); accountActions.Children.Add(_changePassword); accountActions.Children.Add(_drop);
        right.Children.Add(accountActions);
        right.Children.Add(new TextBlock { Text = "Changing a site's account or password may require updating its CMS configuration.", TextWrapping = TextWrapping.Wrap, Opacity = .7 });
        _confirmation.Children.Add(_confirmationText);
        var confirmActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        confirmActions.Children.Add(_confirm);
        var cancel = new Button { Content = "Cancel" };
        confirmActions.Children.Add(cancel);
        _confirmation.Children.Add(confirmActions);
        right.Children.Add(_confirmation);
        var scroll = new ScrollViewer { Content = right, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetColumn(scroll, 1); body.Children.Add(scroll);
        Grid.SetRow(_problem, 1); Grid.SetColumnSpan(_problem, 2); body.Children.Add(_problem);
        Content = body;

        _accounts.SelectionChanged += async (_, _) => { CancelConfirmation(); await LoadGrantsAsync(); };
        _create.Click += async (_, _) => await RunAsync(() => DatabaseAccountService.CreateAsync(_database, _name.Text, _host.Text, _password.Password),
            new DatabaseAccount(_name.Text.Trim(), string.IsNullOrWhiteSpace(_host.Text) ? "localhost" : _host.Text.Trim()));
        _changePassword.Click += (_, _) => Prepare("password");
        _grantAll.Click += (_, _) => Prepare("all");
        _grantRead.Click += (_, _) => Prepare("read");
        _revoke.Click += (_, _) => Prepare("revoke");
        _drop.Click += (_, _) => Prepare("drop");
        _confirm.Click += async (_, _) => await ConfirmAsync();
        cancel.Click += (_, _) => CancelConfirmation();
        Loaded += async (_, _) =>
        {
            body.Width = Math.Max(500, Math.Min(870, XamlRoot.Size.Width - 110));
            body.Height = Math.Max(320, Math.Min(510, XamlRoot.Size.Height - 210));
            await RefreshAsync();
        };
        SetBusy(false);
    }

    private async Task RefreshAsync(DatabaseAccount? preferred = null)
    {
        if (_busy) return;
        preferred ??= _accounts.SelectedItem as DatabaseAccount;
        SetBusy(true);
        try
        {
            var accounts = await DatabaseAccountService.ListAsync(_database);
            _accounts.ItemsSource = accounts;
            _accounts.SelectedItem = accounts.FirstOrDefault(account => account == preferred) ?? accounts.FirstOrDefault();
        }
        catch (Exception ex) { ShowError(ex); }
        finally { SetBusy(false); }
        await LoadGrantsAsync();
    }

    private async Task LoadGrantsAsync()
    {
        if (_busy || _accounts.SelectedItem is not DatabaseAccount account) { _grants.Text = "Select a user."; SetBusy(false); return; }
        SetBusy(true);
        try { _grants.Text = string.Join(Environment.NewLine, await DatabaseAccountService.GrantsAsync(_database, account)); }
        catch (Exception ex) { ShowError(ex); }
        finally { SetBusy(false); }
    }

    private void Prepare(string action)
    {
        if (_busy || _accounts.SelectedItem is not DatabaseAccount account || account.IsManaged) return;
        _pendingAccount = account;
        _pendingAction = action;
        _confirmationText.Text = action switch
        {
            "password" => $"Change the password for {account.Display}? Its CMS configuration may need updating.",
            "all" => $"Grant {account.Display} full access to {_database}?",
            "read" => $"Grant {account.Display} read-only access to {_database}?",
            "revoke" => $"Revoke all access to {_database} from {account.Display}?",
            _ => $"Permanently delete {account.Display}? Sites using this account will lose database access."
        };
        _confirmation.Visibility = Visibility.Visible;
    }

    private async Task ConfirmAsync()
    {
        if (_pendingAccount is not { } account || _accounts.SelectedItem is not DatabaseAccount selected || selected != account) return;
        var action = _pendingAction;
        if (action == "password" && string.IsNullOrEmpty(_password.Password)) { ShowError(new InvalidOperationException("Enter a new password first.")); return; }
        await RunAsync(() => action switch
        {
            "password" => DatabaseAccountService.ChangePasswordAsync(_database, account, _password.Password),
            "all" => DatabaseAccountService.GrantAsync(_database, account, false),
            "read" => DatabaseAccountService.GrantAsync(_database, account, true),
            "revoke" => DatabaseAccountService.RevokeAsync(_database, account),
            "drop" => DatabaseAccountService.DropAsync(_database, account),
            _ => Task.CompletedTask
        }, action == "drop" ? null : account);
    }

    private async Task RunAsync(Func<Task> action, DatabaseAccount? selection)
    {
        if (_busy) return;
        SetBusy(true);
        try { await action(); _password.Password = ""; CancelConfirmation(); }
        catch (Exception ex) { ShowError(ex); return; }
        finally { SetBusy(false); }
        await RefreshAsync(selection);
    }

    private void CancelConfirmation() { _pendingAccount = null; _pendingAction = null; _confirmation.Visibility = Visibility.Collapsed; }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        var editable = !busy && _accounts.SelectedItem is DatabaseAccount { IsManaged: false };
        _accounts.IsEnabled = _create.IsEnabled = !busy;
        _changePassword.IsEnabled = _grantAll.IsEnabled = _grantRead.IsEnabled = _revoke.IsEnabled = _drop.IsEnabled = editable;
        _confirm.IsEnabled = editable;
        if (busy) _problem.IsOpen = false;
    }

    private void ShowError(Exception ex) { _problem.Message = ex.Message; _problem.IsOpen = true; }
}
