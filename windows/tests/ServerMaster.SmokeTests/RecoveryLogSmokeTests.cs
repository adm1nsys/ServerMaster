using ServerMaster.Windows.Services;

internal static class RecoveryLogSmokeTests
{
    public static async Task Run()
    {
        var clock = new Clock();
        var recovery = new CrashRecovery(clock);
        var id = Guid.NewGuid();
        Check(recovery.NextDelay(id) == TimeSpan.FromSeconds(1) && recovery.NextDelay(id) == TimeSpan.FromSeconds(2) && recovery.NextDelay(id) == TimeSpan.FromSeconds(4) && recovery.NextDelay(id) is null,
            "crash recovery backs off and limits repeated attempts");
        Check(recovery.NextDelay(Guid.NewGuid()) == TimeSpan.FromSeconds(1), "restart budget is independent per profile");
        clock.Now += TimeSpan.FromMinutes(2);
        Check(recovery.NextDelay(id) == TimeSpan.FromSeconds(1), "restart budget recovers after a stable interval");

        var runs = 0;
        var messages = new List<string>();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelRecovery = new CrashRecovery(delay: (_, cancellation) => { entered.TrySetResult(); return Task.Delay(Timeout.Infinite, cancellation); });
        var pending = cancelRecovery.ScheduleAsync(id, () => true, () => { runs++; return Task.CompletedTask; }, messages.Add);
        await entered.Task;
        Check(cancelRecovery.HasPending, "pending recovery can keep Stop all available");
        cancelRecovery.Cancel(id);
        await pending.WaitAsync(TimeSpan.FromSeconds(2));
        Check(runs == 0 && !cancelRecovery.HasPending, "manual Stop cancels a delayed restart");
        entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        pending = cancelRecovery.ScheduleAsync(id, () => true, () => { runs++; return Task.CompletedTask; }, messages.Add);
        await entered.Task;
        cancelRecovery.CancelAll();
        await pending.WaitAsync(TimeSpan.FromSeconds(2));
        Check(runs == 0, "Stop all and quit cancel pending restarts");
        var allowed = true;
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var lateRecovery = new CrashRecovery(delay: (_, _) => gate.Task);
        pending = lateRecovery.ScheduleAsync(id, () => allowed, () => { runs++; return Task.CompletedTask; }, messages.Add);
        allowed = false;
        gate.SetResult();
        await pending;
        Check(runs == 0, "a changed preference or deleted profile is checked again before restart");
        var immediate = new CrashRecovery(delay: (_, _) => Task.CompletedTask);
        await immediate.ScheduleAsync(id, () => true, () => { runs++; return Task.CompletedTask; }, messages.Add);
        Check(runs == 1, "eligible unexpected exit invokes restart");
        await immediate.ScheduleAsync(id, () => true, () => throw new IOException("fixture failure"), messages.Add);
        Check(messages.Any(message => message.Contains("fixture failure")), "restart failure is logged instead of escaping a background task");
        await immediate.ScheduleAsync(Guid.NewGuid(), () => false, () => { runs++; return Task.CompletedTask; }, messages.Add);
        Check(runs == 1, "disabled recovery never launches a server");

        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-log-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var now = DateTimeOffset.UtcNow;
            foreach (var name in new[] { "old.log", "active.log", "new.log", "unrelated.txt" })
            {
                var path = Path.Combine(root, name);
                await File.WriteAllTextAsync(path, "keep unless expired log");
                File.SetLastWriteTimeUtc(path, now.AddDays(-30).UtcDateTime);
            }
            File.SetLastWriteTimeUtc(Path.Combine(root, "new.log"), now.UtcDateTime);
            var disabled = LogRetention.Clean(root, 0, [], now);
            Check(disabled.Removed == 0 && File.Exists(Path.Combine(root, "old.log")), "zero retention never removes logs");
            var result = LogRetention.Clean(root, 7, [Path.Combine(root, "active.log")], now);
            Check(result.Removed == 1 && !File.Exists(Path.Combine(root, "old.log")), "only expired log files are removed");
            Check(File.Exists(Path.Combine(root, "active.log")) && File.Exists(Path.Combine(root, "new.log")) && File.Exists(Path.Combine(root, "unrelated.txt")), "active logs, recent logs and unrelated files are preserved");
            Check(LogRetention.Clean(Path.Combine(root, "missing"), 7, [], now).Removed == 0, "cleanup does not create missing folders");
        }
        finally { Directory.Delete(root, true); }
    }

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        Console.WriteLine("PASS Recovery/logs: " + description);
    }
}
