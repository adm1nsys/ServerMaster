using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Services;

var root = Path.Combine(Path.GetTempPath(), "ServerMaster-log-io-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
AppPaths.DirectoryPath = root;
var log = new ConsoleLog(new DispatcherQueue());
try
{
    log.StartFileLogging("Fixture");
    var first = log.FilePath!;
    log.Append("first output");
    log.StopFileLogging();
    Check(!log.IsFileLogging && File.ReadAllText(first).Contains("first output"), "stop flushes and closes disk logging");
    log.Append("console only");
    Check(log.PlainText.Contains("console only") && !File.ReadAllText(first).Contains("console only"), "disabled disk recording keeps console output working");
    log.StartFileLogging("Fixture");
    var second = log.FilePath!;
    log.Append("recording resumed");
    log.StopFileLogging();
    Check(first != second && File.ReadAllText(first).Contains("first output") && File.ReadAllText(second).Contains("recording resumed"), "rapid re-enable creates a new file without overwriting the old one");
    log.Limit = 2;
    Check(log.Lines.Count <= 2, "changing the buffer limit trims existing lines immediately");
    log.Append("\u001b[31mred text\u001b[0m");
    Check(log.Lines.Last().Text == "red text", "console removes ANSI control sequences");
    log.Limit = 5000;
    await Task.WhenAll(Task.Run(() => { for (var i = 0; i < 500; i++) log.Append("output " + i); }),
        Task.Run(() => { for (var i = 0; i < 30; i++) { log.StartFileLogging("Fixture"); log.StopFileLogging(); } }));
    Check(log.PlainText.Contains("output 499"), "concurrent output and recording toggles finish without disposed-writer errors");
    log.FileSizeLimit = 8;
    log.StartFileLogging("Limited");
    log.Append("this exceeds the file limit");
    Check(!log.IsFileLogging && log.PlainText.Contains("reached its limit"), "disk size limit stops recording with a console explanation");
    log.Append("after limit");
    Check(log.Lines.Last().Text == "after limit", "console continues after disk recording reaches its limit");
    var blocked = Path.Combine(root, "not-a-directory");
    await File.WriteAllTextAsync(blocked, "preserve");
    AppPaths.DirectoryPath = blocked;
    log.StartFileLogging("Blocked");
    Check(!log.IsFileLogging && log.PlainText.Contains("Could not start file logging"), "unwritable log destination does not throw into server startup");
    log.Append("still alive");
    Check(log.Lines.Last().Text == "still alive" && await File.ReadAllTextAsync(blocked) == "preserve", "failed recording leaves existing data and console intact");
    Check(System.Text.RegularExpressions.Regex.IsMatch(log.TimestampedText.Split(Environment.NewLine).Last(), @"^\[\d\d:\d\d:\d\d\] still alive$"), "saved logs carry a time for every line like macOS");
    AppPaths.DirectoryPath = root;
    log.FileSizeLimit = 20 * 1024 * 1024;
    log.StartFileLogging("Cleared");
    log.Append("kept on disk");
    var cleared = log.FilePath!;
    log.Clear();
    log.Append("after clear");
    log.StopFileLogging();
    Check(log.Lines.Count == 1 && File.ReadAllText(cleared).Contains("kept on disk") && File.ReadAllText(cleared).Contains("after clear"), "Clear empties the console but not the log file");
}
finally { log.StopFileLogging(); Directory.Delete(root, true); }

static void Check(bool condition, string description)
{
    if (!condition) throw new Exception(description);
    Console.WriteLine("PASS ConsoleLog: " + description);
}
