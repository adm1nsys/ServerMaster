using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Microsoft.UI.Dispatching;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;

internal static class ServerLifecycleSmokeTests
{
    public static async Task Run()
    {
        var parsed = LaunchPlanBuilder.SplitArguments("--file \"C:\\My Sites\\server.js\" --root C:\\Sites --empty \"\"");
        Check(parsed.SequenceEqual(new[] { "--file", @"C:\My Sites\server.js", "--root", @"C:\Sites", "--empty", "" }), "Windows arguments preserve backslashes, spaces and empty values");
        if (ShellEnvironment.Shared.Which("node") is null) { Console.WriteLine("SKIP Lifecycle: Node.js is not installed"); return; }
        var hostExe = Path.GetFullPath("windows/src/ServerMaster.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ServerMaster.exe");
        if (File.Exists(hostExe))
        {
            var port = FreePort();
            var output = new System.Collections.Concurrent.ConcurrentQueue<string>();
            var client = new ElevatedServerClient { HostPath = hostExe };
            client.Output += (line, _) => output.Enqueue(line);
            var plan = new LaunchPlan
            {
                Executable = ShellEnvironment.Shared.Which("node")!,
                WorkingDirectory = Environment.CurrentDirectory,
                Arguments = ["-e", $"require('net').createServer(s=>s.end('ok')).listen({port},'127.0.0.1',()=>console.log('ready'))"]
            };
            try
            {
                await client.StartAsync(plan, CancellationToken.None, testMode: true);
                var ready = false;
                for (var attempt = 0; attempt < 30 && !ready; attempt++)
                {
                    ready = output.Contains("ready");
                    if (!ready) await Task.Delay(100);
                }
                Check(ready && client.IsAlive && client.ServerProcessId > 0, "separate server host forwards output and reports the child PID");
            }
            finally { await client.StopAsync(); }
            Check(await ServerReadiness.WaitPortReleasedAsync(new ServerProfile { Host = "127.0.0.1", Port = port }, TimeSpan.FromSeconds(5)),
                "separate server host releases the child-owned port on Stop");

            var crashPort = FreePort();
            var ownerInfo = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
            ownerInfo.ArgumentList.Add("--host-owner-child");
            ownerInfo.ArgumentList.Add(crashPort.ToString());
            using var owner = Process.Start(ownerInfo) ?? throw new Exception("Could not start helper owner test.");
            try
            {
                var line = await owner.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15));
                var fields = (line ?? "").Split(' ');
                Check(fields.Length == 3 && fields[0] == "READY", "separate helper owner starts a listening server");
                var helperPid = int.Parse(fields[1]);
                owner.Kill();
                await owner.WaitForExitAsync();
                Check(await ServerReadiness.WaitPortReleasedAsync(new ServerProfile { Host = "127.0.0.1", Port = crashPort }, TimeSpan.FromSeconds(5)),
                    "forced UI exit releases the elevated helper's child-owned port");
                var helperExited = false;
                try { using var helper = Process.GetProcessById(helperPid); helperExited = helper.HasExited; }
                catch (ArgumentException) { helperExited = true; }
                Check(helperExited, "forced UI exit closes the separate helper");
            }
            finally { if (!owner.HasExited) { owner.Kill(true); await owner.WaitForExitAsync(); } }
        }
        using (var forcedExit = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--job-port-only")
               { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true })!)
        {
            var output = await forcedExit.StandardOutput.ReadToEndAsync();
            var error = await forcedExit.StandardError.ReadToEndAsync();
            await forcedExit.WaitForExitAsync();
            Check(forcedExit.ExitCode == 0, "forced parent exit test: " + output + error);
        }
        var root = Path.Combine(Path.GetTempPath(), "ServerMaster-lifecycle-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var first = new ServerController(new DispatcherQueue());
        var second = new ServerController(new DispatcherQueue());
        var settings = new AppSettings { WriteLogsToFile = false };
        var a = new ServerProfile { Engine = "nodeScript", RootPath = root, Port = FreePort() };
        var b = new ServerProfile { Engine = "nodeScript", RootPath = root, Port = FreePort() };
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"), "setTimeout(()=>require('http').createServer((q,s)=>s.end('ready')).listen(Number(process.env.PORT),process.env.HOST),1500);");
            var start = first.StartAsync(a, settings);
            await Task.Delay(200);
            Check(a.State == ServerState.Starting, "slow startup remains Starting until HTTP answers");
            await Task.WhenAll(start, first.StartAsync(a, settings));
            Check(a.State == ServerState.Running && a.ProcessId.HasValue, "duplicate Start creates one running instance");
            using var http = new HttpClient(new HttpClientHandler { UseProxy = false });
            Check(await http.GetStringAsync(a.Address) == "ready", "reported Running serves real HTTP");
            var previousPid = a.ProcessId;
            await second.StartAsync(b, settings);
            await first.RestartAsync(a, settings);
            Check(a.State == ServerState.Running && a.ProcessId != previousPid && b.State == ServerState.Running, "restart replaces only the selected profile process");
            await first.StopAsync(a);
            Check(a.State == ServerState.Stopped && a.ProcessId is null && await http.GetStringAsync(b.Address) == "ready", "stop clears PID without stopping another profile");
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"),
                "const cp=require('child_process'); cp.spawn(process.execPath,['child.js'],{stdio:'ignore'}); setInterval(()=>{},1000);");
            await File.WriteAllTextAsync(Path.Combine(root, "child.js"),
                "require('http').createServer((q,s)=>s.end('child')).listen(Number(process.env.PORT),process.env.HOST);");
            await first.StartAsync(a, settings);
            Check(a.State == ServerState.Running && first.HasOwnedProcess && await http.GetStringAsync(a.Address) == "child", "child server answers HTTP while owned by the profile");
            await first.StopAsync(a);
            Check(a.State == ServerState.Stopped && !first.HasOwnedProcess, "stop terminates the whole owned process group");
            await ServerReadiness.CheckPortAsync(a, CancellationToken.None);
            Check(true, "stop releases a port held by a child process");
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"),
                "const cp=require('child_process'); cp.spawn(process.execPath,['child.js'],{stdio:'ignore'}); setTimeout(()=>process.exit(9),1800);");
            await first.StartAsync(a, settings);
            Check(a.State == ServerState.Running && await http.GetStringAsync(a.Address) == "child", "child server starts before its parent exits");
            await Task.Delay(2500);
            Check(a.State == ServerState.Failed && !first.HasOwnedProcess && a.ProcessId is null,
                "unexpected parent exit releases the owned child process group");
            await ServerReadiness.CheckPortAsync(a, CancellationToken.None);
            Check(true, "unexpected parent exit releases the child-owned port");
            using (var occupied = new TcpListener(IPAddress.Loopback, a.Port))
            {
                occupied.Start();
                await first.StartAsync(a, settings);
                Check(a.State == ServerState.Failed && a.Failure!.Contains("occupied"), "occupied port fails before launch with an actionable error");
                Check(occupied.Server.IsBound, "occupied port owner is left untouched");
            }
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"), "setTimeout(()=>require('http').createServer((q,s)=>s.end('late')).listen(Number(process.env.PORT),process.env.HOST),10000);");
            var pending = first.StartAsync(a, settings);
            await Task.Delay(200);
            var clock = Stopwatch.StartNew();
            await first.StopAsync(a);
            await pending;
            Check(clock.Elapsed < TimeSpan.FromSeconds(4) && a.State == ServerState.Stopped && a.ProcessId is null, "Stop cancels startup promptly without a late Running state");
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"), "console.error('fixture startup failure'); process.exit(7);");
            await first.StartAsync(a, settings);
            Check(a.State == ServerState.Failed && a.ProcessId is null, "early exit never becomes Running and releases PID");
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"), "require('http').createServer((q,s)=>s.end('ok')).listen(Number(process.env.PORT),process.env.HOST); setTimeout(()=>process.exit(9),1800);");
            await first.StartAsync(a, settings);
            await Task.Delay(2200);
            Check(a.State == ServerState.Failed && a.ProcessId is null, "unexpected exit updates the running profile");
            await first.StopAsync(a);
            await File.WriteAllTextAsync(Path.Combine(root, "server.js"),
                "const fs=require('fs'); require('http').createServer((q,s)=>s.end('recovered')).listen(Number(process.env.PORT),process.env.HOST); if(!fs.existsSync('recovery.flag')){fs.writeFileSync('recovery.flag','once');setTimeout(()=>process.exit(9),1800);}");
            var recovery = new CrashRecovery();
            var recovered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var unexpected = 0;
            void Recover(ServerProfile profile, int code)
            {
                unexpected++;
                _ = recovery.ScheduleAsync(profile.Id, () => profile.State == ServerState.Failed,
                    async () => { await first.StartAsync(profile, settings); recovered.TrySetResult(); }, first.Log.System);
            }
            first.UnexpectedExit += Recover;
            try
            {
                await first.StartAsync(a, settings);
                await recovered.Task.WaitAsync(TimeSpan.FromSeconds(20));
                Check(a.State == ServerState.Running && await http.GetStringAsync(a.Address) == "recovered", "crashed server is restarted and serves HTTP on the same port");
                recovery.CancelAll();
                await first.StopAsync(a);
                await Task.Delay(200);
                Check(unexpected == 1 && a.State == ServerState.Stopped && !first.HasOwnedProcess, "intentional Stop does not emit another crash or restart the server");
                await ServerReadiness.CheckPortAsync(a, CancellationToken.None);
                Check(true, "recovered server releases its port after Stop");
            }
            finally { first.UnexpectedExit -= Recover; recovery.CancelAll(); }
        }
        finally { await first.StopAsync(a); await second.StopAsync(b); Directory.Delete(root, true); }
    }
    private static int FreePort() { using var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start(); return ((IPEndPoint)probe.LocalEndpoint).Port; }
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); Console.WriteLine("PASS Lifecycle: " + message); }
}
