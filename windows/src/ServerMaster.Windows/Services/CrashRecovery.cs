namespace ServerMaster.Windows.Services;

// Called on the UI dispatcher, alongside profile lifecycle commands.
public sealed class CrashRecovery
{
    private readonly Dictionary<Guid, CancellationTokenSource> _pending = [];
    private readonly Dictionary<Guid, Queue<DateTimeOffset>> _attempts = [];
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly TimeProvider _time;
    public bool HasPending => _pending.Count > 0;

    public CrashRecovery(TimeProvider? time = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _time = time ?? TimeProvider.System;
        _delay = delay ?? ((duration, cancellation) => Task.Delay(duration, cancellation));
    }

    public async Task ScheduleAsync(Guid id, Func<bool> allowed, Func<Task> restart, Action<string> log)
    {
        if (_pending.ContainsKey(id) || !allowed()) return;
        var delay = NextDelay(id);
        if (delay is null) { log("Automatic restart paused after 3 attempts in one minute. Check the console and start the profile manually."); return; }
        using var cancellation = new CancellationTokenSource();
        _pending[id] = cancellation;
        try
        {
            log($"Unexpected exit. Restarting in {delay.Value.TotalSeconds:0} s...");
            await _delay(delay.Value, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!allowed()) return;
            _pending.Remove(id);
            await restart();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception ex) { log("Automatic restart failed: " + ex.Message); }
        finally
        {
            if (_pending.TryGetValue(id, out var current) && ReferenceEquals(current, cancellation)) _pending.Remove(id);
        }
    }

    internal TimeSpan? NextDelay(Guid id)
    {
        if (!_attempts.TryGetValue(id, out var attempts)) _attempts[id] = attempts = new();
        var now = _time.GetUtcNow();
        while (attempts.TryPeek(out var first) && now - first >= TimeSpan.FromMinutes(1)) attempts.Dequeue();
        if (attempts.Count >= 3) return null;
        var delay = TimeSpan.FromSeconds(1 << attempts.Count);
        attempts.Enqueue(now);
        return delay;
    }

    public void Cancel(Guid id)
    {
        if (_pending.Remove(id, out var cancellation)) cancellation.Cancel();
        _attempts.Remove(id);
    }

    public void CancelAll()
    {
        foreach (var id in _pending.Keys.ToArray()) Cancel(id);
        _attempts.Clear();
    }
}
