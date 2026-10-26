using ServerMaster.Windows.Services;

namespace ServerMaster.Windows.Models;

public sealed class StarterTemplate
{
    // List rows and combo items are announced by this text (otherwise the type name).
    public override string ToString() => LocalizedTitle;

    public required string Title { get; init; }
    public required string FileName { get; init; }
    public required string Content { get; init; }
    public string Symbol { get; init; } = "\uE7C3";
    public string LocalizedTitle => Localization.T(Title);
    public string Summary => FileName;

    public static IReadOnlyList<StarterTemplate> For(ServerProfile profile)
    {
        return profile.Engine switch
        {
            "nodeScript" =>
            [
                new StarterTemplate
                {
                    Title = "JSON API", FileName = profile.NodeEntryFile, Symbol = "\uE7B8",
                    Content = """
                    const http = require('node:http');
                    const host = process.env.HOST || '127.0.0.1';
                    const port = Number(process.env.PORT || 8080);
                    http.createServer((req, res) => {
                      const path = new URL(req.url, 'http://localhost').pathname;
                      const found = req.method === 'GET' && ['/', '/health'].includes(path);
                      res.writeHead(found ? 200 : 404, { 'Content-Type': 'application/json; charset=utf-8' });
                      res.end(JSON.stringify(found ? { ok: true, path } : { error: 'Not found' }));
                    }).listen(port, host, () => console.log(`Listening at http://${host}:${port}`));
                    """
                },
                new StarterTemplate
                {
                    Title = "Minimal Node server",
                    FileName = string.IsNullOrWhiteSpace(profile.NodeEntryFile) ? "server.js" : profile.NodeEntryFile,
                    Symbol = "\uE7B8",
                    Content = """
                    const http = require("http");

                    const host = process.env.HOST || "127.0.0.1";
                    const port = Number(process.env.PORT || 8080);

                    http.createServer((req, res) => {
                      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
                      res.end("Hello from ServerMaster on Windows\n");
                    }).listen(port, host, () => {
                      console.log(`Listening at http://${host}:${port}`);
                    });
                    """
                }
            ],
            "phpBuiltIn" =>
            [
                new StarterTemplate
                {
                    Title = "PHP starter page",
                    FileName = "index.php",
                    Symbol = "\uE943",
                    Content = """
                    <?php
                    echo "<h1>Hello from ServerMaster</h1>";
                    echo "<p>PHP is working on Windows.</p>";
                    echo "<p>PHP " . htmlspecialchars(PHP_VERSION) . "</p>";
                    """
                }
            ],
            _ =>
            [
                new StarterTemplate
                {
                    Title = "Simple HTML page",
                    FileName = string.IsNullOrWhiteSpace(profile.IndexFile) ? "index.html" : profile.IndexFile,
                    Content = """
                    <!doctype html>
                    <html lang="en">
                    <head>
                      <meta charset="utf-8">
                      <meta name="viewport" content="width=device-width, initial-scale=1">
                      <title>ServerMaster</title>
                      <style>
                        body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 16px/1.5 system-ui; background: #10131a; color: #f5f7fb; }
                        main { max-width: 620px; padding: 40px; }
                        h1 { font-size: 40px; margin: 0 0 8px; }
                        p { color: #aab2c0; }
                      </style>
                    </head>
                    <body>
                      <main>
                        <h1>Hello from ServerMaster</h1>
                        <p>Your local Windows server is running.</p>
                      </main>
                    </body>
                    </html>
                    """
                }
            ]
        };
    }

    public static StarterTemplate DefaultFor(ServerProfile profile) => profile.Engine == "nodeScript" && profile.TemplateId != "node-api"
        ? For(profile).Last() : For(profile).First();

    public static void Write(ServerProfile profile, StarterTemplate starter)
    {
        var root = Path.GetFullPath(profile.ExpandedRootPath);
        var path = Path.GetFullPath(Path.Combine(root, starter.FileName));
        if (!path.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The starting file must stay inside the project folder.");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        using var writer = new StreamWriter(file);
        writer.Write(starter.Content);
    }
}
