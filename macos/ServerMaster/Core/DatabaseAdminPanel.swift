//
//  DatabaseAdminPanel.swift
//  ServerMaster
//
//  The web admin panel for the managed database — what phpMyAdmin was in MAMP:
//  its own port, a web interface, one button to open it.
//
//  Two panels are offered. Adminer is a single PHP file bundled with the app, so
//  it works instantly and offline. phpMyAdmin is installed through Homebrew when
//  the user prefers the interface they already know.
//
//  Neither will accept the managed database's passwordless root account —
//  verified against Adminer 6, which refuses outright. So the panel gets its own
//  database account with a generated password. Root is left exactly as it is:
//  a CMS already installed with “no password” must keep working.
//

import Foundation

nonisolated enum DatabaseAdminTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case adminer
    case phpMyAdmin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adminer:    return "Adminer"
        case .phpMyAdmin: return "phpMyAdmin"
        }
    }

    var subtitle: String {
        switch self {
        case .adminer:
            return String(localized: "Bundled with the app — nothing to install")
        case .phpMyAdmin:
            return String(localized: "The interface MAMP used — installed through Homebrew")
        }
    }

    /// Homebrew installs phpMyAdmin; Adminer travels inside the app.
    var needsInstallation: Bool { self == .phpMyAdmin }
}

@Observable
final class DatabaseAdminPanel {

    enum State: Equatable {
        case stopped
        case starting
        case running(URL)
        case failed(String)
    }

    private(set) var state: State = .stopped
    let log = ConsoleLog()

    /// The password of the current session's panel account, shown next to the
    /// button so it can be copied. Regenerated on every start.
    private(set) var currentPassword: String = ""
    private(set) var currentTool: DatabaseAdminTool = .adminer

    private var process: Process?
    private var runtimeDirectory: URL?

    /// The database account the panel logs in with. Kept apart from root so that
    /// changing it can never break a site that was installed against root.
    static let accountName = "servermaster_panel"

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var address: URL? {
        if case .running(let url) = state { return url }
        return nil
    }

    // MARK: - Availability

    /// Where phpMyAdmin lives once Homebrew has installed it.
    static func phpMyAdminDirectory() -> String? {
        let candidates = [
            "/opt/homebrew/share/phpmyadmin",
            "/usr/local/share/phpmyadmin"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0 + "/index.php") }
    }

    /// The bundled Adminer file.
    static func adminerFile() -> String? {
        Bundle.main.path(forResource: "adminer", ofType: "php")
    }

    /// Whether the chosen panel can be started at all.
    static func isAvailable(_ tool: DatabaseAdminTool) -> Bool {
        switch tool {
        case .adminer:    return adminerFile() != nil
        case .phpMyAdmin: return phpMyAdminDirectory() != nil
        }
    }

    // MARK: - Lifecycle

    func start(tool: DatabaseAdminTool, database: DatabaseService, port: Int) async {
        guard !isRunning else { return }
        state = .starting
        log.system(String(localized: "Starting \(tool.title)…"))

        guard database.state == .running else {
            fail(String(localized: "The database is not running. Start it first."))
            return
        }
        guard let php = ShellEnvironment.shared.which("php") else {
            fail(String(localized: "PHP was not found. Install it on the Dependencies tab."))
            return
        }
        // A panel from a previous run survives if the app was force-quit rather
        // than closed: terminating the app does not take its child php with it,
        // and the orphan keeps the port. Clear our own leftovers before giving up.
        await reclaimOrphan(port: port)

        guard PortScanner.isPortFree(port, host: "127.0.0.1") else {
            fail(String(localized: "Port \(String(port)) is taken by something else. Choose another one in Settings."))
            return
        }

        // The account is created on every start: the password is regenerated, and
        // a database that was reset in the meantime gets the account back.
        let password = Self.generatedPassword()
        currentPassword = password
        currentTool = tool
        let granted = await database.grantPanelAccount(name: Self.accountName, password: password)
        guard granted.succeeded else {
            fail(String(localized: "Could not prepare the panel account: \(granted.stderr)"))
            return
        }

        let served: (docRoot: URL, router: URL?)
        do {
            served = try prepareDocumentRoot(tool: tool, database: database, password: password)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: php)
        // Bound to the loopback address on purpose: the panel is unrestricted
        // access to every database and must never be reachable from the network.
        var arguments = ["-S", "127.0.0.1:\(String(port))", "-t", served.docRoot.path]
        if let router = served.router { arguments.append(router.path) }
        task.arguments = arguments
        task.currentDirectoryURL = served.docRoot
        task.environment = ShellEnvironment.shared.environment(extra: [:])

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [log] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            log.append(text)
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.state = .stopped
                self.log.system(String(localized: "The admin panel has stopped."))
            }
        }

        do {
            try task.run()
        } catch {
            fail(error.localizedDescription)
            return
        }
        process = task
        writeSentinel(pid: task.processIdentifier, port: port)

        guard let url = URL(string: "http://127.0.0.1:\(String(port))/") else {
            fail(String(localized: "Could not build the panel address."))
            return
        }
        state = .running(url)
        log.system(String(localized: "\(tool.title) is available at \(url.absoluteString)"))
    }

    func stop() {
        // Cleared on every path: a start that failed after generating the
        // password would otherwise leave it in memory and on screen.
        currentPassword = ""
        guard let task = process else {
            state = .stopped
            return
        }
        process = nil
        state = .stopped
        if task.isRunning {
            task.terminate()
            task.waitUntilExit()
        }
        if let directory = runtimeDirectory {
            try? FileManager.default.removeItem(at: directory)
            runtimeDirectory = nil
        }
        try? FileManager.default.removeItem(at: Self.sentinelURL)
        log.system(String(localized: "The admin panel has stopped."))
    }

    /// Called when the application quits; the panel must not outlive it.
    func stopSynchronously() {
        try? FileManager.default.removeItem(at: Self.sentinelURL)
        guard let task = process, task.isRunning else { return }
        process = nil
        task.terminate()
        task.waitUntilExit()
    }

    // MARK: - Leftovers from a previous run

    /// Records which process is serving the panel, so a later run can recognise
    /// its own orphan rather than blaming an unrelated program for the port.
    private static var sentinelURL: URL {
        AppPaths.subdir("Runtime").appendingPathComponent("dbadmin.pid")
    }

    private func writeSentinel(pid: Int32, port: Int) {
        try? "\(String(pid))\n\(String(port))\n".write(to: Self.sentinelURL,
                                                        atomically: true, encoding: .utf8)
    }

    /// Stops a panel left behind by a previous run of the app, if it is ours and
    /// it is on the port we are about to use.
    private func reclaimOrphan(port: Int) async {
        let sentinel = Self.sentinelURL
        guard let text = try? String(contentsOf: sentinel, encoding: .utf8) else { return }
        defer { try? FileManager.default.removeItem(at: sentinel) }

        let parts = text.split(separator: "\n").map(String.init)
        guard parts.count >= 2, let pid = Int32(parts[0]), let recorded = Int(parts[1]),
              recorded == port else { return }

        // kill(pid, 0) does not kill — it only reports whether the process exists.
        guard kill(pid, 0) == 0 else { return }

        // Make sure the pid is still the panel and not a number reused by macOS
        // for something entirely different.
        let check = await ProcessRunner.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 10)
        guard check.stdout.contains("php") && check.stdout.contains("dbadmin") else { return }

        log.system(String(localized: "Stopping an admin panel left over from the previous run."))
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    // MARK: - What gets served

    /// Adminer is served from a folder of our own, because the auto-login page
    /// has to sit next to it. phpMyAdmin is served from where Homebrew put it, so
    /// its stylesheets and scripts resolve, with a router of ours pointing it at
    /// the config we generated — the installed tree is never written to.
    private func prepareDocumentRoot(tool: DatabaseAdminTool,
                                     database: DatabaseService,
                                     password: String) throws -> (docRoot: URL, router: URL?) {
        let directory = AppPaths.subdir("Runtime/dbadmin")
        try? FileManager.default.removeItem(at: directory)
        AppPaths.ensure(directory)
        runtimeDirectory = directory

        switch tool {
        case .adminer:
            guard let source = Self.adminerFile() else {
                throw PanelError.message(String(localized: "The bundled Adminer file is missing."))
            }
            try FileManager.default.copyItem(
                atPath: source,
                toPath: directory.appendingPathComponent("adminer.php").path)
            try adminerAutoLogin(database: database, password: password)
                .write(to: directory.appendingPathComponent("index.php"),
                       atomically: true, encoding: .utf8)
            return (directory, nil)

        case .phpMyAdmin:
            guard let root = Self.phpMyAdminDirectory() else {
                throw PanelError.message(
                    String(localized: "phpMyAdmin was not found. Install it: brew install phpmyadmin"))
            }
            // phpMyAdmin 5.2 reads its config as ROOT_PATH + config.inc.php, and
            // Homebrew symlinks that file to a shared one in etc. Rather than
            // write into the installation, the whole tree is mirrored here with
            // symlinks and only config.inc.php is a real file of ours. ROOT_PATH
            // is then pointed at this folder — index.php guards its own define
            // with `if (! defined(...))`, so ours wins.
            let fm = FileManager.default
            for entry in try fm.contentsOfDirectory(atPath: root) where entry != "config.inc.php" {
                try? fm.createSymbolicLink(atPath: directory.appendingPathComponent(entry).path,
                                           withDestinationPath: (root as NSString).appendingPathComponent(entry))
            }
            try phpMyAdminConfig(database: database, password: password)
                .write(to: directory.appendingPathComponent("config.inc.php"),
                       atomically: true, encoding: .utf8)
            let router = directory.appendingPathComponent("sm-router.php")
            try phpMyAdminRouter(rootPath: directory.path)
                .write(to: router, atomically: true, encoding: .utf8)
            return (directory, router)
        }
    }

    /// Signs in to Adminer without the user typing anything.
    ///
    /// Adminer 6 dropped the `adminer_object()` extension point that older
    /// wrappers used, and its login form carries a CSRF token, so credentials
    /// cannot simply be posted from a static page. This does what a person does:
    /// loads the login page, takes the token out of it, and submits the form.
    /// Same origin, so Adminer sees its own session and accepts it.
    ///
    /// Without this the user has to know that “Server” must be 127.0.0.1 with the
    /// port — leaving it at “localhost” makes Adminer try a socket that is not
    /// there and fail with “No such file or directory”.
    private func adminerAutoLogin(database: DatabaseService, password: String) -> String {
        let server = "127.0.0.1:\(String(database.port))"
        return """
        <?php
        // Generated by ServerMaster — rewritten on every start.
        $server = \(ConfigTemplates.phpQuote(server));
        $user = \(ConfigTemplates.phpQuote(Self.accountName));
        $pass = \(ConfigTemplates.phpQuote(password));
        ?>
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Opening Adminer…</title>
        <style>
          body { background:#111114; color:#e8e8ed; font:15px -apple-system,system-ui,sans-serif;
                 display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
          .box { text-align:center; max-width:30rem; }
          table { margin:1.2rem auto 0; border-collapse:collapse; font-size:13px; }
          th, td { padding:.35rem .8rem; text-align:left; }
          th { color:#8e8e93; font-weight:500; }
          td { font-family:ui-monospace,Menlo,monospace; }
          a { color:#0a84ff; }
        </style></head><body><div class="box">
        <p id="status">Signing in to Adminer…</p>
        <noscript><p>JavaScript is off — sign in with the details below.</p></noscript>
        <table id="details" hidden>
          <tr><th>Server<td><?= htmlspecialchars($server) ?>
          <tr><th>Username<td><?= htmlspecialchars($user) ?>
          <tr><th>Password<td><?= htmlspecialchars($pass) ?>
        </table>
        <p id="manual" hidden><a href="adminer.php">Open the login page</a></p>
        <form id="f" method="post" action="adminer.php" style="display:none">
          <input name="auth[driver]" value="server">
          <input name="auth[server]" value="<?= htmlspecialchars($server) ?>">
          <input name="auth[username]" value="<?= htmlspecialchars($user) ?>">
          <input name="auth[password]" value="<?= htmlspecialchars($pass) ?>">
          <input name="token" value="">
        </form>
        <script>
        (function () {
          var form = document.getElementById('f');
          function manual(message) {
            document.getElementById('status').textContent = message;
            document.getElementById('details').hidden = false;
            document.getElementById('manual').hidden = false;
          }
          fetch('adminer.php', { credentials: 'same-origin' })
            .then(function (r) { return r.text(); })
            .then(function (html) {
              var m = html.match(/name=['"]token['"]\\s+value=['"]([^'"]+)['"]/);
              if (!m) { manual('Could not read the login token — sign in manually.'); return; }
              form.elements.token.value = m[1];
              form.submit();
            })
            .catch(function () { manual('Could not reach Adminer — sign in manually.'); });
        })();
        </script>
        </div></body></html>
        """
    }

    /// phpMyAdmin signs in on its own when the credentials are in the config —
    /// this is the auto-login MAMP had.
    private func phpMyAdminConfig(database: DatabaseService, password: String) -> String {
        """
        <?php
        // Generated by ServerMaster — rewritten on every start.
        $cfg['blowfish_secret'] = '\(Self.generatedPassword(length: 32))';
        $i = 1;
        $cfg['Servers'][$i]['auth_type'] = 'config';
        $cfg['Servers'][$i]['host'] = '127.0.0.1';
        $cfg['Servers'][$i]['port'] = '\(String(database.port))';
        $cfg['Servers'][$i]['user'] = '\(Self.accountName)';
        $cfg['Servers'][$i]['password'] = '\(password)';
        $cfg['Servers'][$i]['AllowNoPassword'] = false;
        $cfg['Servers'][$i]['compress'] = false;
        $cfg['TempDir'] = sys_get_temp_dir();
        """
    }

    /// The router handed to `php -S`. Its only job is to define ROOT_PATH before
    /// phpMyAdmin can, so the config it loads is ours. Returning false lets the
    /// built-in server deliver stylesheets and scripts through the symlinks;
    /// without that the page loads but renders blank.
    private func phpMyAdminRouter(rootPath: String) -> String {
        """
        <?php
        // Generated by ServerMaster — rewritten on every start.
        define('ROOT_PATH', \(ConfigTemplates.phpQuote(rootPath + "/")));

        $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
        if ($path === '/' || $path === '') { $path = '/index.php'; }
        if (strpos($path, '..') !== false) { http_response_code(403); return true; }

        $file = ROOT_PATH . ltrim($path, '/');
        if (is_dir($file)) { $file = rtrim($file, '/') . '/index.php'; }
        if (is_file($file) && substr($file, -4) === '.php') {
            chdir(dirname($file));
            require $file;
            return true;
        }
        return false;
        """
    }

    // MARK: - Helpers

    enum PanelError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        log.append(message, stream: .stderr)
    }

    /// A password for the panel account. It never leaves this machine and is
    /// regenerated on every start, so it is not worth storing anywhere.
    static func generatedPassword(length: Int = 20) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var result = ""
        for _ in 0..<length {
            result.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return result
    }
}
