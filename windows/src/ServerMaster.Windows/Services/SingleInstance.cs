using System.Runtime.InteropServices;

namespace ServerMaster.Windows.Services;

/// <summary>
/// One ServerMaster per Windows session. A second launch asks the running instance, which may be
/// hidden in the notification area with servers running, to show its window, then exits.
/// </summary>
public static class SingleInstance
{
    private const string DefaultName = @"Local\ServerMaster.Windows";
    private static Mutex? _mutex;
    private static EventWaitHandle? _activate;
    private static RegisteredWaitHandle? _wait;

    /// <summary>Claims the instance, or signals the running one and returns false.</summary>
    public static bool TryClaim(string name = DefaultName)
    {
        try
        {
            // The event exists before the mutex, so a second launch can always signal it.
            _activate = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Activate");
            _mutex = new Mutex(true, name + ".Instance", out var created);
            if (created) return true;
            _mutex.Dispose();
            _mutex = null;
            AllowSetForegroundWindow(-1);
            _activate.Set();
        }
        catch (UnauthorizedAccessException) { } // Owned by an elevated instance; still never start a second one.
        catch (WaitHandleCannotBeOpenedException) { }
        _activate?.Dispose();
        _activate = null;
        return false;
    }

    /// <summary>Runs <paramref name="activated"/> on a pool thread for each later launch.</summary>
    public static void Listen(Action activated)
    {
        if (_activate is null || _wait is not null) return;
        _wait = ThreadPool.RegisterWaitForSingleObject(_activate, (_, _) => activated(), null, Timeout.Infinite, executeOnlyOnce: false);
    }

    public static void Release()
    {
        _wait?.Unregister(null);
        _wait = null;
        if (_mutex is not null)
        {
            try { _mutex.ReleaseMutex(); } catch (ApplicationException) { } // Not owned by this thread.
            _mutex.Dispose();
            _mutex = null;
        }
        _activate?.Dispose();
        _activate = null;
    }

    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int processId);
}
