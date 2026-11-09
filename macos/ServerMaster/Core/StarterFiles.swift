//
//  StarterFiles.swift
//  ServerMaster
//
//  Nginx, Apache and Caddy get their config written for them. Everything else
//  was left with nothing: a Node.js profile refuses to start until an entry file
//  exists, and a fresh folder has no index.html to serve — both perfectly
//  reasonable failures that a person new to this cannot act on.
//
//  So every engine now offers a starting point, usually more than one, and the
//  file is written into the site folder rather than hidden in the app's
//  Application Support: it belongs to the project.
//
//  Nothing here ever overwrites silently — the caller is told when a file is
//  already there and asks first.
//

import Foundation
import Darwin

nonisolated struct StarterFile: Identifiable, Sendable {

    var id: String
    var title: String
    var summary: String
    /// Where it goes, relative to the site folder.
    var fileName: String
    var symbol: String
    /// Written when the person picks this one.
    var contents: @Sendable (ServerProfile) -> String
    /// Shown after writing, when there is something the person must still do.
    var afterNote: String?

    func write(into root: String, profile: ServerProfile, overwrite: Bool) throws -> URL {
        guard !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StarterError.noRoot }
        let directory = URL(fileURLWithPath: AppPaths.expand(root))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let access = try SiteFileAccess(root: directory)
        var relativeName = fileName
        if profile.engine == .nodeScript, !profile.workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            let working = URL(fileURLWithPath: profile.effectiveWorkingDirectory).standardizedFileURL
            let base = directory.standardizedFileURL.pathComponents
            guard working.pathComponents.starts(with: base) else { throw SiteFileAccess.Failure.outside }
            let prefix = working.pathComponents.dropFirst(base.count).joined(separator: "/")
            if !prefix.isEmpty { relativeName = prefix + "/" + fileName }
        }
        let components = relativeName.split(separator: "/", omittingEmptySubsequences: false)
        guard !fileName.contains("\0"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SiteFileAccess.Failure.outside
        }
        var parent = access.root
        for component in components.dropLast() {
            let next = parent.appendingPathComponent(String(component))
            var info = stat()
            if lstat(next.path, &info) != 0 {
                guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                _ = try access.checked(parent)
                try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
            }
            parent = try access.checked(next)
        }
        let target = parent.appendingPathComponent(String(components.last!))
        var info = stat()
        if lstat(target.path, &info) == 0 {
            _ = try access.checked(target)
            guard overwrite else { throw StarterError.exists(fileName) }
            var document = try TextFileDocument.load(target, access: access)
            try document.save(contents(profile))
        } else {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            _ = try access.checked(parent)
            try Data(contents(profile).utf8).write(to: target, options: .withoutOverwriting)
        }
        return target
    }
}

nonisolated enum StarterError: LocalizedError {
    case exists(String)
    case noRoot

    var errorDescription: String? {
        switch self {
        case .exists(let name): return String(localized: "“\(name)” already exists in the site folder.")
        case .noRoot:           return String(localized: "Choose the site folder first.")
        }
    }
}

nonisolated enum StarterFiles {

    /// What can be generated for a profile, in the order worth offering it.
    static func available(for profile: ServerProfile) -> [StarterFile] {
        var files: [StarterFile] = []

        switch profile.engine {
        case .nodeScript:
            let entry = nodeEntry(for: profile)
            files = [nodeJSONAPI, nodeMinimal, nodeStatic, nodeExpress].map { starter in
                var result = starter
                result.fileName = entry
                return result
            }
            files.append(packageJSON)

        case .httpServer, .pythonHTTP:
            files += [indexHTML, spaIndexHTML]

        case .phpBuiltIn, .phpFpm:
            files += [indexPHP, phpInfo, indexHTML]

        case .apache, .apachePHP:
            files += [htaccessBasic, htaccessSPA]
            if profile.engine == .apachePHP { files += [indexPHP, phpInfo] }
            files += [indexHTML]

        case .nginx, .caddy:
            files += [indexHTML, spaIndexHTML]

        case .custom:
            files += [indexHTML, packageJSON]
        }

        return files
    }

    // MARK: - Web pages

    static let indexHTML = StarterFile(
        id: "index.html",
        title: String(localized: "Starter page"),
        summary: String(localized: "A plain index.html so the folder serves something"),
        fileName: "index.html",
        symbol: "doc.richtext",
        contents: { profile in
            page(title: profile.name,
                 heading: profile.name,
                 body: """
                 <p>This page is being served by ServerMaster.</p>
                 <p class="muted">Replace <code>index.html</code> with your own site.</p>
                 """)
        },
        afterNote: nil)

    static let spaIndexHTML = StarterFile(
        id: "index.html.spa",
        title: String(localized: "Single-page app shell"),
        summary: String(localized: "index.html with a mount point and a router-friendly base"),
        fileName: "index.html",
        symbol: "square.stack.3d.up",
        contents: { profile in
            page(title: profile.name,
                 heading: profile.name,
                 body: """
                 <div id="root"></div>
                 <p class="muted">Mount your app on <code>#root</code>. Deep links are
                 sent here as long as “SPA fallback” stays switched on.</p>
                 <script type="module">
                   document.getElementById('root').textContent = 'Your app goes here.';
                 </script>
                 """)
        },
        afterNote: String(localized: "Switch on “SPA fallback” in the profile so deep links reach this page."))

    static let indexPHP = StarterFile(
        id: "index.php",
        title: String(localized: "Starter PHP page"),
        summary: String(localized: "Proves PHP is being executed, not shown as source"),
        fileName: "index.php",
        symbol: "curlybraces",
        contents: { profile in
            """
            <?php
            // Generated by ServerMaster as a starting point — replace it with your own.
            $version = PHP_VERSION;
            $served = $_SERVER['SERVER_SOFTWARE'] ?? 'unknown';
            ?>
            \(page(title: profile.name,
                   heading: profile.name,
                   body: """
                   <p>PHP <?= htmlspecialchars($version) ?> is running.</p>
                   <p class="muted">Served by <?= htmlspecialchars($served) ?>.</p>
                   <p class="muted">If you see this file's source instead of this text,
                   the profile is using an engine that does not execute PHP.</p>
                   """))
            """
        },
        afterNote: nil)

    static let phpInfo = StarterFile(
        id: "phpinfo.php",
        title: String(localized: "PHP information page"),
        summary: String(localized: "Every setting and extension — useful when a CMS complains"),
        fileName: "phpinfo.php",
        symbol: "list.bullet.rectangle",
        contents: { _ in
            """
            <?php
            // Generated by ServerMaster. Delete this file when you are done with it:
            // it lists your entire PHP configuration and is not meant to be public.
            phpinfo();
            """
        },
        afterNote: String(localized: "Delete phpinfo.php when you are finished — it exposes your whole PHP configuration."))

    // MARK: - Node.js

    static func nodeEntry(for profile: ServerProfile) -> String {
        let value = profile.nodeEntryFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "server.js" : value
    }

    /// JSON string encoding also protects quotes, backticks, ${...} and newlines.
    private static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    private static func nodeImport(_ binding: String, from module: String, profile: ServerProfile) -> String {
        if nodeEntry(for: profile).lowercased().hasSuffix(".cjs") {
            return "const \(binding) = require(\(jsString(module)));"
        }
        // Dynamic import works in both CommonJS and ESM .js packages, and .mjs.
        return "const \(binding) = await import(\(jsString(module)));"
    }

    private static func nodeSource(_ profile: ServerProfile, body: String) -> String {
        """
        // Generated by ServerMaster. PORT and HOST override the profile defaults.
        (async () => {
        \(body)
        })().catch(error => { console.error(error); process.exitCode = 1; });
        """
    }

    private static func nodeAddress(_ profile: ServerProfile) -> String {
        """
        const port = Number(process.env.PORT ?? \(profile.port));
        const host = process.env.HOST ?? \(jsString(profile.host));
        """
    }

    static let nodeJSONAPI = StarterFile(
        id: "server.cjs.api",
        title: String(localized: "JSON API"),
        summary: String(localized: "A small API with no npm dependencies"),
        fileName: "server.cjs", symbol: "arrow.left.arrow.right.circle",
        contents: { profile in nodeSource(profile, body: """
            \(nodeImport("{ createServer }", from: "node:http", profile: profile))
            \(nodeAddress(profile))
            createServer((request, response) => {
              response.setHeader('Content-Type', 'application/json; charset=utf-8');
              response.end(JSON.stringify({ ok: true, path: request.url }));
            }).listen(port, host, () => console.log(`Listening on http://${host}:${port}`));
            """) }, afterNote: nil)

    static let nodeMinimal = StarterFile(
        id: "server.js.minimal",
        title: String(localized: "Minimal HTTP server"),
        summary: String(localized: "No dependencies — answers on the profile's port"),
        fileName: "server.js", symbol: "shippingbox",
        contents: { profile in nodeSource(profile, body: """
            \(nodeImport("{ createServer }", from: "node:http", profile: profile))
            \(nodeAddress(profile))
            const name = \(jsString(profile.name));
            createServer((request, response) => {
              response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
              response.end('Hello from ' + name + '\\nYou asked for ' + request.url + '\\n');
            }).listen(port, host, () => console.log(`Listening on http://${host}:${port}`));
            """) }, afterNote: nil)

    static let nodeStatic = StarterFile(
        id: "server.js.static",
        title: String(localized: "Static file server"),
        summary: String(localized: "Serves the folder next to it, still without dependencies"),
        fileName: "server.js", symbol: "folder",
        contents: { profile in nodeSource(profile, body: """
            \(nodeImport("{ createServer }", from: "node:http", profile: profile))
            \(nodeImport("{ readFile, realpath }", from: "node:fs/promises", profile: profile))
            \(nodeImport("{ extname, dirname, resolve, relative, isAbsolute }", from: "node:path", profile: profile))
            \(nodeAddress(profile))
            const root = resolve(dirname(await realpath(process.argv[1])), 'public');
            const types = {
              '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
              '.js': 'text/javascript; charset=utf-8', '.json': 'application/json',
              '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg'
            };
            const inside = file => {
              const path = relative(root, file);
              return path !== '..' && !path.startsWith('../') && !isAbsolute(path);
            };
            createServer(async (request, response) => {
              let path;
              try { path = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
              catch { response.writeHead(400).end('Bad request'); return; }
              const file = resolve(root, '.' + path + (path.endsWith('/') ? 'index.html' : ''));
              if (!inside(file)) { response.writeHead(403).end('Forbidden'); return; }
              try {
                const actual = await realpath(file);
                if (!inside(actual)) { response.writeHead(403).end('Forbidden'); return; }
                const body = await readFile(actual);
                response.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream' });
                response.end(body);
              } catch {
                response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found');
              }
            }).listen(port, host, () => console.log(`Listening on http://${host}:${port}`));
            """) },
        afterNote: String(localized: "Put your files in a “public” subfolder next to the generated entry file."))

    static let nodeExpress = StarterFile(
        id: "server.js.express",
        title: String(localized: "Express server"),
        summary: String(localized: "Routing and middleware — needs npm install express"),
        fileName: "server.js", symbol: "arrow.triangle.branch",
        contents: { profile in nodeSource(profile, body: """
            \(nodeEntry(for: profile).lowercased().hasSuffix(".cjs")
              ? "const express = require('express');" : "const { default: express } = await import('express');")
            const app = express();
            \(nodeAddress(profile))
            app.use(express.static('public'));
            app.get('/api/hello', (request, response) => {
              response.json({ from: \(jsString(profile.name)) });
            });
            app.listen(port, host, () => console.log(`Listening on http://${host}:${port}`));
            """) },
        afterNote: String(localized: "Run “npm install express” in the site folder, or the server will not start."))

    static let packageJSON = StarterFile(
        id: "package.json", title: "package.json",
        summary: String(localized: "Package settings and a start command for the selected entry"),
        fileName: "package.json", symbol: "shippingbox",
        contents: { profile in
            let name = profile.name.lowercased().replacingOccurrences(of: " ", with: "-")
                .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            let entry = nodeEntry(for: profile)
            // npm runs scripts in a shell; use literal POSIX quoting before JSON encoding.
            let command = "node './" + entry.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let object: [String: Any] = ["name": name.isEmpty ? "site" : name, "private": true,
                "type": entry.lowercased().hasSuffix(".cjs") ? "commonjs" : "module",
                "scripts": ["start": command]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }, afterNote: nil)

    // MARK: - Apache

    static let htaccessBasic = StarterFile(
        id: ".htaccess.basic",
        title: String(localized: "Basic .htaccess"),
        summary: String(localized: "Pretty URLs and a couple of safe defaults"),
        fileName: ".htaccess",
        symbol: "feather",
        contents: { _ in
            """
            # Generated by ServerMaster as a starting point.
            # Apache reads this file; Nginx and Caddy do not.

            <IfModule mod_rewrite.c>
                RewriteEngine On

                # A request that matches no file or folder goes to index.php.
                RewriteCond %{REQUEST_FILENAME} !-f
                RewriteCond %{REQUEST_FILENAME} !-d
                RewriteRule ^ index.php [L]
            </IfModule>

            <IfModule mod_headers.c>
                Header always set X-Content-Type-Options "nosniff"
            </IfModule>

            # Never serve dotfiles, whatever the profile settings say.
            <FilesMatch "^\\.">
                Require all denied
            </FilesMatch>
            """
        },
        afterNote: nil)

    static let htaccessSPA = StarterFile(
        id: ".htaccess.spa",
        title: String(localized: ".htaccess for a single-page app"),
        summary: String(localized: "Deep links go to index.html instead of 404"),
        fileName: ".htaccess",
        symbol: "square.stack.3d.up",
        contents: { _ in
            """
            # Generated by ServerMaster as a starting point.

            <IfModule mod_rewrite.c>
                RewriteEngine On

                RewriteCond %{REQUEST_FILENAME} !-f
                RewriteCond %{REQUEST_FILENAME} !-d
                RewriteRule ^ index.html [L]
            </IfModule>
            """
        },
        afterNote: nil)

    // MARK: - Shared page shell

    /// One look for every generated page, so a starter page is recognisable as
    /// one rather than being mistaken for the project's own.
    private static func page(title: String, heading: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 16px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            margin: 0; min-height: 100vh; display: flex; align-items: center;
            justify-content: center; text-align: center; padding: 2rem;
          }
          main { max-width: 32rem; }
          h1 { font-size: 1.6rem; margin: 0 0 .6rem; }
          .muted { opacity: .65; font-size: .95rem; }
          code { font-family: ui-monospace, Menlo, monospace; font-size: .9em; }
        </style>
        </head>
        <body>
        <main>
        <h1>\(escape(heading))</h1>
        \(body)
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
