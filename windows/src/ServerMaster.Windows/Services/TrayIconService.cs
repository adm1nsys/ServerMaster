using System.ComponentModel;
using System.Runtime.InteropServices;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.ViewModels;
using WinRT.Interop;

namespace ServerMaster.Windows.Services;

public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly MainWindow _window;
    private readonly MainViewModel _model;
    private readonly IntPtr _hwnd;
    private readonly SubclassProc _callback;
    private readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private readonly IntPtr _ownedIcon;
    private NOTIFYICONDATA _data;
    private bool _disposed;

    public TrayIconService(MainWindow window, MainViewModel model)
    {
        _window = window;
        _model = model;
        _hwnd = WindowNative.GetWindowHandle(window);
        _callback = WindowProc;
        using (var resource = typeof(TrayIconService).Assembly.GetManifestResourceStream("ServerMaster.TrayIcon.png"))
        {
            if (resource is not null)
            {
                using var buffer = new MemoryStream();
                resource.CopyTo(buffer);
                var bytes = buffer.ToArray();
                _ownedIcon = CreateIconFromResourceEx(bytes, (uint)bytes.Length, true, 0x00030000, 32, 32, 0);
            }
        }
        _data = new NOTIFYICONDATA
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = _hwnd, uID = 1,
            uFlags = 1 | 2 | 4 | 128, uCallbackMessage = CallbackMessage,
            hIcon = _ownedIcon != IntPtr.Zero ? _ownedIcon : LoadIcon(IntPtr.Zero, 32512),
            szTip = "ServerMaster", szInfo = "", szInfoTitle = "", uVersion = 4
        };
        if (!SetWindowSubclass(_hwnd, _callback, 1, UIntPtr.Zero))
            throw new InvalidOperationException("Could not register the notification icon window.");
        AddIcon();
        _model.PropertyChanged += ModelChanged;
        UpdateTip();
    }

    private void AddIcon()
    {
        Shell_NotifyIcon(0, ref _data);
        _data.uVersion = 4;
        Shell_NotifyIcon(4, ref _data);
    }

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.ActiveCount)) UpdateTip();
    }

    private void UpdateTip()
    {
        if (_disposed) return;
        var running = _model.Profiles.Count(p => p.State == ServerState.Running);
        var failed = _model.Profiles.Count(p => p.State == ServerState.Failed);
        var starting = _model.Profiles.Count(p => p.State == ServerState.Starting);
        var tip = $"ServerMaster: {running} running, {starting} starting, {failed} failed";
        if (_data.szTip == tip) return;
        _data.szTip = tip;
        Shell_NotifyIcon(1, ref _data);
    }

    private IntPtr WindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr reference)
    {
        try
        {
            if (message == _taskbarCreated) AddIcon();
            if (message == CallbackMessage)
            {
                var notification = unchecked((uint)lParam.ToInt64()) & 0xffff;
                if (notification is 0x007B or 0x0205) ShowMenu();
                else if (notification is 0x0400 or 0x0401 or 0x0203) Activate();
                return IntPtr.Zero;
            }
        }
        catch (Exception ex) { _model.ReportTrayError(ex.Message); }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = CreatePopupMenu();
        var actions = new Dictionary<uint, Action>();
        uint next = 100;
        void Item(IntPtr parent, string text, Action action, bool enabled = true)
        {
            var id = next++;
            AppendMenu(parent, enabled ? 0u : 1u, (UIntPtr)id, Localization.T(text).Replace("&", "&&"));
            if (enabled) actions[id] = action;
        }
        void Separator() => AppendMenu(menu, 0x800, UIntPtr.Zero, "");
        try
        {
            Item(menu, "Show ServerMaster", Activate);
            Item(menu, _data.szTip, () => { }, false);
            Separator();
            foreach (var profile in _model.Profiles.ToArray())
            {
                var submenu = CreatePopupMenu();
                AppendMenu(menu, 0x10, (UIntPtr)(nuint)submenu, (profile.Name + " - " + profile.StateText).Replace("&", "&&"));
                Item(submenu, profile.IsActive ? "Stop" : "Start", () =>
                {
                    if (_model.Profiles.Contains(profile)) _model.StartStopProfileCommand.Execute(profile);
                }, profile.State != ServerState.Stopping);
                Item(submenu, "Restart", () => _model.RestartProfileCommand.Execute(profile), profile.State == ServerState.Running);
                Item(submenu, "Open site", () => _model.OpenProfileCommand.Execute(profile), profile.State == ServerState.Running);
                Item(submenu, "Logs", () => { _model.ShowProfileLogs(profile); Activate(); });
                Item(submenu, "Files", () => { _model.FilesProfile = profile; Navigate("Files"); }, profile.UsesRootDirectory);
                Item(submenu, "Configure", () => { _model.SelectProfile(profile); Navigate("Profiles"); });
            }
            if (_model.Profiles.Count == 0) Item(menu, "No profiles - open Profiles", () => Navigate("Profiles"));
            Separator();
            var databaseMenu = CreatePopupMenu();
            AppendMenu(menu, 0x10, (UIntPtr)(nuint)databaseMenu, "Database - " + _model.DatabaseStatusTitle);
            var databaseRunning = _model.DatabaseStatus.Running;
            Item(databaseMenu, databaseRunning ? "Stop MariaDB" : "Start MariaDB",
                () => (databaseRunning ? _model.StopDatabaseCommand : _model.StartDatabaseCommand).Execute(null),
                databaseRunning ? _model.DatabaseCanStop : _model.DatabaseCanStart);
            Item(databaseMenu, AdminerService.IsRunning ? "Open admin panel" : "Start and open admin panel",
                () => { Activate(); _model.OpenDatabaseAdminCommand.Execute(null); }, databaseRunning);
            if (AdminerService.IsRunning) Item(databaseMenu, "Stop admin panel", () => _model.StopDatabaseAdminCommand.Execute(null));
            Item(databaseMenu, "Manage databases", () => Navigate("Database"));
            if (!_model.DatabaseStatus.Installed) Item(databaseMenu, "Install MariaDB...", () => Navigate("Dependencies"));
            Item(menu, "Files", () => Navigate("Files"));
            Item(menu, "Stop all servers", () => _model.StopAllCommand.Execute(null), _model.CanStopAllServers);
            Item(menu, "Guides", () => _model.OpenUrlCommand.Execute("https://adm1nsys.github.io/ServerMaster/wiki.html"));
            Separator();
            Item(menu, "Quit", _window.RequestQuit);
            GetCursorPos(out var point);
            SetForegroundWindow(_hwnd);
            var chosen = TrackPopupMenu(menu, 0x0100 | 0x0080 | 0x0002, point.X, point.Y, 0, _hwnd, IntPtr.Zero);
            PostMessage(_hwnd, 0, IntPtr.Zero, IntPtr.Zero);
            // Run commands after leaving the native menu callback so WinUI dialogs can open.
            if (actions.TryGetValue(chosen, out var action)) _window.DispatcherQueue.TryEnqueue(() =>
            {
                try { action(); } catch (Exception ex) { _model.ReportTrayError(ex.Message); }
            });
        }
        finally { DestroyMenu(menu); }
    }

    private void Navigate(string section) { Activate(); _model.SelectSection(section); }
    private void Activate() => _window.BringToFront();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _model.PropertyChanged -= ModelChanged;
        Shell_NotifyIcon(2, ref _data);
        RemoveWindowSubclass(_hwnd, _callback, 1);
        if (_ownedIcon != IntPtr.Zero) DestroyIcon(_ownedIcon);
        GC.KeepAlive(_callback);
    }

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr reference);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public uint cbSize; public IntPtr hWnd; public uint uID; public uint uFlags; public uint uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState; public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATA data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, UIntPtr reference);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern IntPtr LoadIcon(IntPtr instance, int id);
    [DllImport("user32.dll")] private static extern IntPtr CreateIconFromResourceEx(byte[] bytes, uint size, bool icon, uint version, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr hwnd, IntPtr rect);
}
