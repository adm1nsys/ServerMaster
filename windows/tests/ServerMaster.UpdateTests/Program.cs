using System.Net;
using ServerMaster.Windows.Services;

var passed = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException("FAIL: " + name);
    passed++;
    Console.WriteLine("PASS: " + name);
}

Check(UpdateChecker.NormalizeRepository("https://github.com/adm1nsys/ServerMaster.git") == "adm1nsys/ServerMaster", "repository normalization");
Check(UpdateChecker.NormalizeRepository("https://example.com/not-github") == "", "invalid repository rejected");
Check(UpdateChecker.ParseVersion("\uFEFF# comment\nv2.10.3 beta\n") == "2.10.3", "version parsing");
Check(UpdateChecker.IsNewer("1.10.0", "1.9.9"), "numeric version comparison");
Check(!UpdateChecker.IsNewer("1.0", "1.0.0"), "equal padded versions");

var handler = new FakeHandler(request => request.RequestUri!.AbsolutePath.Contains("/main/")
    ? new HttpResponseMessage(HttpStatusCode.NotFound)
    : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("v1.2.0\n") });
var checker = new UpdateChecker(new HttpClient(handler)) { RawBaseUrl = "https://raw.test", SiteBaseUrl = "https://site.test" };
var available = await checker.CheckAsync("owner/repo", "updates/windows.txt", "windows", "1.1.0");
Check(available.Kind == UpdateCheckKind.Available && available.Version == "1.2.0", "branch fallback finds update");
Check(available.ReleaseUrl == "https://site.test/owner/repo/releases/tag/windows-v1.2.0", "Windows release URL");
var current = await checker.CheckAsync("owner/repo", "updates/windows.txt", "windows", "1.2.0");
Check(current.Kind == UpdateCheckKind.UpToDate, "up-to-date result");
var invalid = await checker.CheckAsync("bad", "../secret", "windows", "1.0.0");
Check(invalid.Kind == UpdateCheckKind.NotConfigured, "unsafe configuration rejected");
Check(handler.Requests == 4, "only expected branches requested");

Console.WriteLine($"{passed} update checks passed.");

sealed class FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
{
    public int Requests { get; private set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests++;
        return Task.FromResult(response(request));
    }
}
