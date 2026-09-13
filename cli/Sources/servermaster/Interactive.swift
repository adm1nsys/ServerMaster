//
//  Interactive.swift
//  servermaster
//
//  The screen you get by running `servermaster` with nothing after it: the same
//  profiles, the same servers, the same settings as the window, in a terminal.
//
//  It exists because the two audiences want opposite things. An agent wants
//  flags and JSON and no surprises; a person sitting at a prompt wants to see
//  what is running and press a key. Serving only the first makes the tool
//  useless to hands; serving only the second makes it useless to scripts. So
//  arguments mean “do this and exit”, and no arguments means “show me”.
//
//  It never starts unless both input and output are a real terminal. Piped into
//  something — which is how an agent runs it — the escape sequences would be
//  garbage in the output, so that case falls through to the help text.
//

import Foundation

@MainActor
final class Interactive {

    private let terminal = Terminal()
    private var profiles: [ServerProfile] = []
    private var running: [RunRecord] = []
    private var selection = 0
    private var message: String?
    private var messageIsError = false
    private var screen: Screen = .menu
    private var quitting = false

    enum Screen {
        /// The screen the tool opens on.
        case menu
        case profiles
        case detail(ServerProfile)
        case services
        case dependencies
        case ports
        case logs(ServerProfile)
        case templates
        case help
        case web
        case settings
        /// A section that exists in the application but is not wired up here yet.
        case comingSoon(MenuItem)
    }

    /// Whether to ask the terminal to fill the display on open.
    ///
    /// Off unless asked for. Resizing somebody's window uninvited is rude — they
    /// arranged it the way they wanted, and a program that rearranges the desk
    /// it was invited to is a program people stop inviting.
    var wantsFullScreen = false

    /// Which menu row is highlighted.
    private var menuSelection = 0

    private var dependencyReport: [(Dependency, DependencyStatus)] = []
    private var portEntries: [PortEntry] = []
    private var logLines: [String] = []
    private var listOffset = 0
    private var busy: String?
    private var screenStack: [Screen] = []
    private var lastSettingsCheck: String?

    // MARK: - Running

    func run() async {
        // Restoring the terminal matters more than anything else here: leaving
        // raw mode on turns the user's shell into something that does not echo
        // what they type, and they will not know why.
        signal(SIGINT) { _ in
            print("\u{1B}[?25h\u{1B}[?1049l")
            exit(0)
        }

        terminal.enterRawMode()
        if wantsFullScreen { terminal.maximise() }
        defer { terminal.restore(restoreWindow: wantsFullScreen) }

        reload()
        if let notice = await CLIUpdateManager.noticeIfDue() {
            say(notice)
        }
        // The panel comes up with the screen. Somebody who never reads the help
        // still finds it, and it costs a socket on the loopback.
        WebInterface.shared.start()

        var lastRefresh = Date()
        while !quitting {
            draw()
            // Waiting with a timeout rather than blocking: a server that stops
            // on its own has to show up without anyone pressing a key.
            if let key = terminal.readKey(timeout: 1.0) {
                await handle(key)
            } else if Date().timeIntervalSince(lastRefresh) > 2 {
                lastRefresh = Date()
                let before = running.map(\.id)
                reload()
                if running.map(\.id) != before { message = nil }
            }
        }
    }

    private func reload() {
        profiles = ProfileStore.load()
        running = RunRegistry.all()
        if selection >= profiles.count { selection = max(0, profiles.count - 1) }
    }

    private func record(for profile: ServerProfile) -> RunRecord? {
        running.first { $0.id == profile.id.uuidString }
    }

    // MARK: - Drawing

    private func draw() {
        terminal.begin()
        // The whole window. There used to be a cap at 110 columns, on the
        // theory that a very long line is hard to read — true for prose, and
        // wrong here: these are tables and rules, and stopping them short leaves
        // a margin that reads as the program failing to fill its window.
        let width = terminal.size.columns

        header(width)
        switch screen {
        case .profiles:            drawProfiles(width)
        case .detail(let profile): drawDetail(profile, width)
        case .services:            drawServices(width)
        case .dependencies:        drawDependencies(width)
        case .ports:               drawPorts(width)
        case .logs(let profile):   drawLogs(profile, width)
        case .templates:           drawTemplates(width)
        case .help:                drawHelp(width)
        case .menu:                drawMenu(width)
        case .web:                 drawWeb(width)
        case .settings:            drawSettings(width)
        case .comingSoon(let item): drawComingSoon(item, width)
        }
        footer(width)
        terminal.flush()
    }

    /// What the header can afford to draw in this window.
    ///
    /// Two separate questions. Which form of the wordmark fits the width — one
    /// line, split in two, or neither. And whether the rows left after that can
    /// still carry the version block without squeezing the profile list down to
    /// nothing, because the list is what the screen is for.
    private var headerLayout: (art: [String], versionMark: [String]) {
        // Only the profile list is the menu. Sub-screens keep the one-line
        // header — the help screen in particular has more to say than fits
        // underneath a banner.
        // The menu and the profile list are the two screens that are the point
        // of the program; the rest are places you go to do one thing, and the
        // banner there is a banner in the way.
        switch screen {
        case .menu, .profiles: break
        default: return ([], [])
        }
        let (rows, columns) = terminal.size

        let art: [String]
        if columns >= Banner.width + 4          { art = Banner.wordmark }
        else if columns >= Banner.stackedWidth + 4 { art = Banner.stacked }
        else { return ([], []) }

        // How much room the content below needs. The profile list can scroll, so
        // a few rows will do; the menu cannot — it is twelve items and a footer,
        // and a banner that leaves no space for them pushes the key hints off
        // the bottom, which is exactly what a menu must never do.
        let needed: Int
        // Plus the blank rows above and below the banner.
        if case .menu = screen { needed = 25 } else { needed = 18 }
        guard rows >= art.count + needed else { return ([], []) }

        guard Banner.versionMarkIsCurrent,
              columns >= Banner.versionMarkWidth + 4,
              rows >= art.count + Banner.versionMark.count + 13 else { return (art, []) }
        return (art, Banner.versionMark)
    }

    /// Rows the header occupies, so the list below sizes itself to what is left
    /// rather than to a constant.
    private var headerHeight: Int {
        let layout = headerLayout
        guard !layout.art.isEmpty else { return 2 }
        let air = terminal.size.rows >= 36 ? 2 : 1
        return layout.art.count + layout.versionMark.count + air * 2 + 2
    }

    private func header(_ width: Int) {
        let count = running.count
        let status = count == 0
            ? Style.grey("nothing running")
            : Style.green("\(count) running")
        let layout = headerLayout

        if layout.art.isEmpty {
            terminal.putLine(Style.bold("  ServerMaster") + Style.grey("  \(CLIVersion.version)") + "   " + status)
        } else {
            // Centred in the window rather than pinned to the left margin. On a
            // wide terminal a logo hugging the edge looks like a mistake.
            let artWidth = layout.art.map(\.count).max() ?? 0
            let margin = String(repeating: " ", count: max(2, (width - artWidth) / 2))

            // Air above and below. The banner used to start on the first row,
            // against the window edge, which reads as the drawing having been
            // cut off rather than placed.
            let air = terminal.size.rows >= 36 ? 2 : 1
            for _ in 0..<air { terminal.putLine() }

            for line in layout.art { terminal.putLine(margin + Theme.paint(line)) }

            if !layout.versionMark.isEmpty {
                let markMargin = String(repeating: " ",
                                        count: max(2, (width - Banner.versionMarkWidth) / 2))
                for line in layout.versionMark { terminal.putLine(markMargin + Style.grey(line)) }
            }
            for _ in 0..<air { terminal.putLine() }
            let line = "Swift \(Banner.swiftVersion), language mode \(Banner.languageMode)"
                + "   ·   \(CLIVersion.version) (\(CLIVersion.build))"
            let statusText = count == 0 ? "nothing running" : "\(count) running"
            let whole = line + "   " + statusText
            let indent = String(repeating: " ", count: max(2, (width - whole.count) / 2))
            terminal.putLine(indent + Style.grey(line) + "   " + status)
            terminal.putLine()
        }
        terminal.putLine(Style.grey("  " + String(repeating: "─", count: max(10, width - 4))))
    }

    private func footer(_ width: Int) {
        // Pushed to the bottom of the window. Three rows are kept for the footer
        // itself: a blank, the message line, the rule, then the keys.
        terminal.padTo(row: max(terminal.linesWritten, terminal.size.rows - 4))
        terminal.putLine()
        if let message {
            terminal.putLine("  " + (messageIsError ? Style.red(message) : Style.green(message)))
        } else {
            terminal.putLine()
        }
        terminal.putLine(Style.grey("  " + String(repeating: "─", count: max(10, width - 4))))

        let keys: String
        switch screen {
        case .menu:
            keys = "↑↓←→ move   ⏎ open   letter jump   F fullscreen   ? help   q quit"
        case .web, .comingSoon:
            keys = "esc back   q quit"
        case .settings:
            keys = "u auto-update on/off   c check updates   w wiki   s site   esc back   q quit"
        case .profiles:
            // The full list is wider than a default 80-column window, and a
            // wrapped hint line pushes the last row of the table off the screen.
            keys = terminal.size.columns >= 122
                ? "↑↓ move  ⏎ open  s start/stop  r restart  l logs  o browser  n new  x delete  d services  e deps  p ports  ? help  q quit"
                : "↑↓ move  ⏎ open  s start/stop  n new  x delete  d services  ? help  q quit"
        case .detail:
            keys = "↑↓ field   ⏎ edit   s start/stop   esc back   q quit"
        case .services:
            keys = "b start/stop database   c create database   a admin panel   esc back"
        case .dependencies:
            keys = "↑↓ move   i install   esc back"
        case .ports:
            keys = "↑↓ move   k end process   R refresh   esc back"
        case .logs:
            keys = "R refresh   esc back   q quit"
        case .templates:
            keys = "↑↓ move   ⏎ create from this   esc back"
        case .help:
            keys = "esc back   q quit"
        }
        terminal.putLine(Style.grey("  " + keys))
    }

    // MARK: - Profiles

    private func drawProfiles(_ width: Int) {
        guard !profiles.isEmpty else {
            terminal.putLine()
            terminal.putLine("  No profiles yet.")
            terminal.putLine(Style.grey("  Create one:  servermaster new static --root ~/Sites/mine"))
            return
        }

        // Columns shrink on a narrow window rather than spilling into each
        // other: “PHP site (Apache + PHP” running into “stopped” is unreadable.
        // The columns grow with the window instead of stopping at a fixed size:
        // a table that ends two thirds of the way across looks like a bug.
        let spare = max(0, width - 96)
        let nameWidth = (width >= 108 ? 24 : 18) + spare / 3
        let addressWidth = (width >= 108 ? 30 : 24) + spare / 3
        let engineWidth = (width >= 108 ? 26 : 16) + spare / 3

        // The four leading spaces line the header up with rows, which start with
        // a state marker and a space.
        terminal.putLine(Style.grey("    " + Style.column("NAME", nameWidth) + Style.column("ADDRESS", addressWidth)
                                    + Style.column("ENGINE", engineWidth) + "STATE"))

        // Only as many rows as fit, scrolled to keep the selection visible —
        // a list longer than the window used to push the key hints off-screen.
        let visible = max(3, terminal.size.rows - 8 - headerHeight)
        if selection < listOffset { listOffset = selection }
        if selection >= listOffset + visible { listOffset = selection - visible + 1 }
        let shown = Array(profiles.enumerated())[listOffset..<min(profiles.count, listOffset + visible)]

        for (index, profile) in shown {
            let entry = record(for: profile)
            let marker = entry == nil ? Style.grey("○") : Style.green("●")
            let state = entry.map { $0.origin == .app ? "running (app)" : "running (terminal)" } ?? "stopped"

            let line = "\(marker) " + Style.column(profile.name, nameWidth)
                + Style.grey(Style.column(profile.address, addressWidth))
                + Style.column(profile.engine.title, engineWidth)
                + (entry == nil ? Style.grey(state) : Style.green(state))

            terminal.putLine(index == selection ? Theme.highlight("  " + line) : "  " + line)
        }
        if profiles.count > visible {
            terminal.putLine(Style.grey("  \(listOffset + shown.count) of \(profiles.count)"))
        }
    }

    // MARK: - One profile

    private static let fields = ["Name", "Port", "Root", "Engine", "PHP", "Index", "HTTPS"]
    private var fieldSelection = 0

    private func drawDetail(_ profile: ServerProfile, _ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold(profile.name))
        terminal.putLine()

        let values = [
            profile.name,
            String(profile.port),
            profile.rootPath,
            profile.engine.title,
            profile.phpVersion.isEmpty ? "whatever is in PATH" : profile.phpVersion,
            profile.indexFile,
            profile.httpsEnabled ? "on" : "off"
        ]

        for (index, name) in Self.fields.enumerated() {
            let row = "  " + Style.pad(name, 10) + values[index]
            terminal.putLine(index == fieldSelection ? Style.inverse(row) : row)
        }

        let problems = profile.validationIssues
        if !problems.isEmpty {
            terminal.putLine()
            terminal.putLine("  " + Style.yellow("Problems"))
            for problem in problems.prefix(4) {
                terminal.putLine(Style.yellow("    · ") + problem)
            }
        }
    }

    // MARK: - Services

    private func drawServices(_ width: Int) {
        let snapshot = StatusSnapshot.read()
        terminal.putLine()
        terminal.putLine("  " + Style.bold("Services"))
        terminal.putLine()
        terminal.putLine("  " + Style.pad("Database", 20)
                         + (snapshot.databaseRunning ? Style.green("running") : Style.grey("stopped")))
        terminal.putLine("  " + Style.pad("Admin panel", 20)
                         + (snapshot.adminPanelAddress.map { Style.green($0) } ?? Style.grey("not started")))
        terminal.putLine()

        let versions = PHPVersions.scan()
        terminal.putLine("  " + Style.pad("PHP", 20)
                         + (versions.isEmpty ? Style.grey("none found")
                            : versions.map(\.version).joined(separator: ", ")))
    }

    // MARK: - The menu

    /// Two columns of sections, the same ones the window has.
    ///
    /// Two columns and not one: a single list of twelve items pushes the key
    /// hints off a short terminal, and the grouping — what a server does, how it
    /// is configured — is the same split the sidebar makes.
    private func drawMenu(_ width: Int) {
        let server = Menu.items(in: .server)
        let configuration = Menu.items(in: .configuration)
        let rows = max(server.count, configuration.count)

        // The menu is centred in what is left between the banner and the footer,
        // rather than sitting right under the logo with a hole beneath it. The
        // block is rows plus its heading, a blank line, and the hint underneath.
        let blockHeight = rows + 4
        let available = terminal.size.rows - 4 - terminal.linesWritten
        let above = max(1, (available - blockHeight) / 2)
        for _ in 0..<above { terminal.putLine() }

        // Split what there is, with a floor so the names never collide and a
        // ceiling so the two halves do not end up at opposite walls of an
        // ultrawide terminal, which is harder to read than a narrow one.
        let column = max(28, min(52, (width - 8) / 2))
        // The pair of columns is centred as one block, so the menu sits under
        // the middle of the logo rather than drifting left of it.
        let margin = String(repeating: " ", count: max(2, (width - column * 2) / 2))

        terminal.putLine(margin + Style.grey(Style.pad("SERVER", column) + "CONFIGURATION"))
        terminal.putLine()

        for row in 0..<rows {
            var line = margin
            line += cell(server.indices.contains(row) ? server[row] : nil,
                         index: row, width: column)
            line += cell(configuration.indices.contains(row) ? configuration[row] : nil,
                         index: server.count + row, width: column)
            terminal.putLine(line)
        }

        terminal.putLine()
        // The subtitle of whatever is highlighted, rather than one under every
        // row: twelve explanations at once is a wall, one is a hint.
        if Menu.items.indices.contains(menuSelection) {
            let item = Menu.items[menuSelection]
            terminal.putLine(margin + Style.grey(item.subtitle))
            if !item.isReady {
                terminal.putLine(margin + Style.yellow("Not on this screen yet — the command line and the web page have it."))
            }
        }
    }

    /// One menu cell: the shortcut letter, then the name.
    private func cell(_ item: MenuItem?, index: Int, width: Int) -> String {
        guard let item else { return String(repeating: " ", count: width) }

        let selected = index == menuSelection
        let key = Style.grey("\(item.key)")
        let name = item.isReady ? item.title : Style.grey(item.title)
        let text = " \(key)  \(name) "

        // Padding is counted on the text without escapes, or the colours make
        // every cell a different width.
        let visible = " \(item.key)  \(item.title) ".count
        let padding = String(repeating: " ", count: max(0, width - visible))
        return (selected ? Theme.highlight(text) : text) + padding
    }

    private func handleMenu(_ key: Key) {
        let count = Menu.items.count
        let leftColumn = Menu.items(in: .server).count

        switch key {
        case .up:    menuSelection = max(0, menuSelection - 1)
        case .down:  menuSelection = min(count - 1, menuSelection + 1)
        // Left and right jump between the columns, which is what the arrangement
        // makes people expect.
        case .left:  if menuSelection >= leftColumn { menuSelection -= leftColumn }
        case .right: if menuSelection < leftColumn { menuSelection = min(count - 1, menuSelection + leftColumn) }
        case .enter:
            guard Menu.items.indices.contains(menuSelection) else { return }
            open(Menu.items[menuSelection])
        case .character("q"): quitting = true
        case .character("?"): navigate(.help)
        case .character(let character):
            guard let item = Menu.item(forKey: character) else { return }
            menuSelection = Menu.items.firstIndex { $0.id == item.id } ?? menuSelection
            open(item)
        default: break
        }
    }

    private func open(_ item: MenuItem) {
        guard case .screen(let name) = item.destination else {
            navigate(.comingSoon(item))
            return
        }
        selection = 0
        listOffset = 0
        switch name {
        case "profiles":     navigate(.profiles)
        case "services":     navigate(.services)
        case "ports":        navigate(.ports); Task { await loadPorts() }
        case "dependencies": navigate(.dependencies); Task { await loadDependencies() }
        case "templates":    navigate(.templates)
        case "help":         navigate(.help)
        case "web":          navigate(.web)
        case "settings":     navigate(.settings)
        case "logs":
            if let profile = current ?? profiles.first {
                navigate(.logs(profile))
                loadLog()
            } else {
                navigate(.profiles)
            }
        default:             navigate(.profiles)
        }
    }

    private func navigate(_ next: Screen) {
        screenStack.append(screen)
        screen = next
    }

    private func back(to fallback: Screen = .menu) {
        if let previous = screenStack.popLast() {
            screen = previous
        } else {
            screen = fallback
        }
        if selection >= profiles.count { selection = max(0, profiles.count - 1) }
        listOffset = 0
    }

    // MARK: - Sections that are not wired up here yet

    private func drawComingSoon(_ item: MenuItem, _ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold(item.title))
        terminal.putLine("  " + Style.grey(item.subtitle))
        terminal.putLine()
        terminal.putLine("  " + Style.yellow("This section is not on the interactive screen yet."))
        terminal.putLine()
        terminal.putLine(Style.grey("  It is not missing from the program — the command line has it,"))
        terminal.putLine(Style.grey("  and so does the web interface. Only this screen is still to come."))
    }

    private func drawWeb(_ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold("Web interface"))
        terminal.putLine()
        if let address = WebInterface.shared.address {
            terminal.putLine("  " + Style.green("Running") + Style.grey("  " + address))
            terminal.putLine()
            terminal.putLine(Style.grey("  Open that address in a browser on this machine."))
            terminal.putLine(Style.grey("  It listens on the loopback only, so nothing on the network reaches it."))
        } else {
            terminal.putLine("  " + Style.grey("Not running."))
            terminal.putLine()
            terminal.putLine(Style.grey("  Start it with:  servermaster web"))
        }
        terminal.putLine()
        terminal.putLine(Style.grey("  To put it on the network, put a real web server in front of it —"))
        terminal.putLine(Style.grey("  nginx or Caddy with a certificate — and proxy to this address."))
    }

    private func drawSettings(_ width: Int) {
        let settings = AppSettings.load()
        let updates = CLIUpdateManager.loadSettings()
        let pathPreview = ShellEnvironment.shared.path
            .split(separator: ":")
            .prefix(width >= 120 ? 6 : 4)
            .joined(separator: ":")

        terminal.putLine()
        terminal.putLine("  " + Style.bold("Settings"))
        terminal.putLine(Style.grey("  Runtime settings, release channel, and paths used by this command."))
        terminal.putLine()

        let labelWidth = width >= 110 ? 22 : 16
        let rows: [(String, String)] = [
            ("CLI version", "\(CLIVersion.version) (\(CLIVersion.build))"),
            ("Target", CLIVersion.platform),
            ("Latest version", CLIUpdateManager.defaultVersionURL),
            ("Auto updates", updates.automaticChecks ? "on — daily check" : "off"),
            ("Last check", updates.lastCheckedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"),
            ("Website", AppLinks.site.absoluteString),
            ("Wiki", AppLinks.Guide.index.url.absoluteString),
            ("Support", AppPaths.abbreviate(AppPaths.support.path)),
            ("Shared", AppPaths.abbreviate(AppPaths.shared.path)),
            ("PATH", pathPreview + "…"),
            ("Accent hue", String(format: "%.2f", settings.backgroundHue))
        ]

        for (label, value) in rows {
            terminal.putLine("  " + Style.pad(label, labelWidth) + Style.grey(value))
        }

        if let lastSettingsCheck {
            terminal.putLine()
            terminal.putLine("  " + Style.green(lastSettingsCheck))
        }
    }

    // MARK: - Templates, dependencies, ports, logs

    private func drawTemplates(_ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold("What are you running?"))
        terminal.putLine(Style.grey("  Everything else is filled in for you."))
        terminal.putLine()

        let all = ProfileTemplate.builtIn
        let visible = max(3, terminal.size.rows - 12)
        if selection < listOffset { listOffset = selection }
        if selection >= listOffset + visible { listOffset = selection - visible + 1 }

        for (index, template) in Array(all.enumerated())[listOffset..<min(all.count, listOffset + visible)] {
            let row = "  " + Style.column(template.title, 26) + Style.grey(template.summary)
            terminal.putLine(index == selection ? Style.inverse(row) : row)
        }
        if all.count > visible {
            terminal.putLine(Style.grey("  \(listOffset + min(visible, all.count - listOffset)) of \(all.count)"))
        }
    }

    private func drawDependencies(_ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold("Dependencies"))
        terminal.putLine()

        guard !dependencyReport.isEmpty else {
            terminal.putLine(Style.grey("  Checking…"))
            return
        }
        for (index, entry) in dependencyReport.enumerated() {
            let (dependency, status) = entry
            let mark = status.installed ? Style.green("✓")
                     : (dependency.required ? Style.red("✗") : Style.grey("·"))
            let version = status.version.map { Style.grey("  " + Self.shortVersion($0)) } ?? ""
            let hint = status.installed ? "" : Style.grey("  → " + dependency.installCommand)
            let row = "\(mark) " + Style.column(dependency.title, 18) + version + hint
            terminal.putLine(index == selection ? Style.inverse("  " + row) : "  " + row)
        }
    }

    /// Tools answer `--version` with anything from “v14.1.1” to a full build
    /// banner. Only the version number is worth a column here.
    private static func shortVersion(_ text: String) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        if let match = first.range(of: "[0-9]+(\\.[0-9]+)+", options: .regularExpression) {
            return String(first[match])
        }
        return String(first.prefix(24))
    }

    private func drawPorts(_ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold("Ports in use"))
        terminal.putLine()

        guard !portEntries.isEmpty else {
            terminal.putLine(Style.grey("  Nothing is listening, or the list has not been read yet — press R."))
            return
        }
        terminal.putLine(Style.grey("  " + Style.pad("PORT", 10) + Style.pad("PROCESS", 26)
                                    + Style.pad("PID", 10) + "ADDRESS"))

        let visible = max(3, terminal.size.rows - 12)
        if selection < listOffset { listOffset = selection }
        if selection >= listOffset + visible { listOffset = selection - visible + 1 }

        for (index, entry) in Array(portEntries.enumerated())[listOffset..<min(portEntries.count, listOffset + visible)] {
            let row = Style.pad(String(entry.port), 10) + Style.column(entry.command, 26)
                + Style.pad(String(entry.pid), 10) + Style.grey(entry.address)
            terminal.putLine(index == selection ? Style.inverse("  " + row) : "  " + row)
        }
    }

    private func drawLogs(_ profile: ServerProfile, _ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold(profile.name) + Style.grey("  log"))
        terminal.putLine()

        guard !logLines.isEmpty else {
            terminal.putLine(Style.grey("  Nothing has been written yet."))
            return
        }
        // The end of a log is the part worth seeing; the beginning almost never is.
        let visible = max(3, terminal.size.rows - 11)
        for line in logLines.suffix(visible) {
            terminal.putLine("  " + Style.grey(String(line.prefix(width - 4))))
        }
    }

    private func drawHelp(_ width: Int) {
        terminal.putLine()
        terminal.putLine("  " + Style.bold("The same tool takes arguments"))
        terminal.putLine()
        for line in [
            "servermaster list                    every profile",
            "servermaster start <name> --no-wait  start it detached",
            "servermaster stop                    stop everything",
            "servermaster new joomla5 --root DIR  create from a template",
            "servermaster status --json           for scripts and agents",
            "servermaster help                    all of it"
        ] {
            terminal.putLine("    " + Style.grey(line))
        }
        terminal.putLine()
        terminal.putLine("  " + Style.bold("Keys on the profile list"))
        terminal.putLine()
        for line in [
            "⏎  open      s  start or stop      r  restart",
            "n  new       x  delete            l  log",
            "d  database  e  dependencies      p  ports",
            "o  open in the browser            q  quit"
        ] {
            terminal.putLine("    " + Style.grey(line))
        }
        terminal.putLine()
        terminal.putLine("  " + Style.grey("Servers started here and in the app are the same servers."))
    }

    // MARK: - Keys

    private func handle(_ key: Key) async {
        message = nil

        if case .control("c") = key { quitting = true; return }
        if case .character("F") = key {
            wantsFullScreen.toggle()
            if wantsFullScreen {
                terminal.maximise()
                say("Fullscreen requested.")
            } else {
                terminal.unmaximise()
                say("Fullscreen released.")
            }
            return
        }

        switch screen {
        case .profiles: await handleProfiles(key)
        case .detail:   await handleDetail(key)
        case .services: await handleServices(key)
        case .dependencies: await handleDependencies(key)
        case .ports: await handlePorts(key)
        case .templates: await handleTemplates(key)
        case .settings: await handleSettings(key)
        case .logs:
            switch key {
            case .escape: back(to: .profiles)
            case .character("q"): quitting = true
            case .character("R"): loadLog()
            default: break
            }
        case .menu: handleMenu(key)
        case .web:
            if key == .escape { back() }
            else if key == .character("q") { quitting = true }
        case .comingSoon:
            if key == .escape { back() }
            else if key == .character("q") { quitting = true }
        case .help:
            if key == .escape { back() }
            else if key == .character("q") { quitting = true }
        }
    }

    private func handleProfiles(_ key: Key) async {
        switch key {
        case .up:    selection = max(0, selection - 1)
        case .down:  selection = min(profiles.count - 1, selection + 1)
        case .escape:
            if screenStack.isEmpty { quitting = true } else { back() }
        case .character("q"): quitting = true
        case .character("?"): navigate(.help)
        case .character("d"): navigate(.services)
        case .character("e"):
            navigate(.dependencies)
            selection = 0
            say("Checking…")
            draw()
            await loadDependencies()
        case .character("p"):
            navigate(.ports)
            selection = 0
            say("Reading…")
            draw()
            await loadPorts()
        case .character("l"):
            guard let profile = current else { return }
            navigate(.logs(profile))
            loadLog()
        case .character("n"):
            navigate(.templates)
            selection = 0
            listOffset = 0
        case .character("x"): await deleteSelected()
        case .enter:
            guard let profile = current else { return }
            fieldSelection = 0
            navigate(.detail(profile))
        case .character("s"): await toggle()
        case .character("r"): await restart()
        case .character("o"):
            guard let profile = current, let url = URL(string: profile.address) else { return }
            NSWorkspaceOpen(url)
            say("Opened \(profile.address)")
        default: break
        }
    }

    private func handleDetail(_ key: Key) async {
        switch key {
        case .up:    fieldSelection = max(0, fieldSelection - 1)
        case .down:  fieldSelection = min(Self.fields.count - 1, fieldSelection + 1)
        case .escape: back(to: .profiles)
        case .character("q"): quitting = true
        case .character("s"): await toggle()
        case .enter: await edit()
        default: break
        }
    }

    private func handleServices(_ key: Key) async {
        switch key {
        case .escape: back(to: .profiles)
        case .character("q"): quitting = true
        case .character("b"):
            say("Starting the database…")
            draw()
            let service = DatabaseService()
            await service.start()
            reload()
            say(service.state == .running ? "Database running." : "The database did not start.",
                error: service.state != .running)
        default: break
        }
    }

    // MARK: - Actions


    // MARK: - The new screens

    private func handleTemplates(_ key: Key) async {
        let all = ProfileTemplate.builtIn
        switch key {
        case .up:   selection = max(0, selection - 1)
        case .down: selection = min(all.count - 1, selection + 1)
        case .escape:
            back(to: .profiles); selection = 0; listOffset = 0
        case .character("q"): quitting = true
        case .enter:
            guard all.indices.contains(selection) else { return }
            await create(from: all[selection])
        default: break
        }
    }

    private func handleSettings(_ key: Key) async {
        switch key {
        case .escape:
            back()
        case .character("q"):
            quitting = true
        case .character("u"):
            var settings = CLIUpdateManager.loadSettings()
            settings.automaticChecks.toggle()
            do {
                try CLIUpdateManager.saveSettings(settings)
                lastSettingsCheck = "Automatic CLI update checks are \(settings.automaticChecks ? "on" : "off")."
            } catch {
                say(error.localizedDescription, error: true)
            }
        case .character("c"):
            lastSettingsCheck = "Checking for updates…"
            draw()
            do {
                let latest = try await CLIUpdateManager.latestVersion()
                lastSettingsCheck = UpdateChecker.isNewer(latest, than: CLIVersion.version)
                    ? "servermaster \(latest) is available."
                    : "servermaster \(CLIVersion.version) is up to date."
            } catch {
                lastSettingsCheck = error.localizedDescription
            }
        case .character("w"):
            NSWorkspaceOpen(AppLinks.Guide.index.url)
            lastSettingsCheck = "Opened the wiki."
        case .character("s"):
            NSWorkspaceOpen(AppLinks.site)
            lastSettingsCheck = "Opened the website."
        default:
            break
        }
    }

    /// Creating a profile: the folder is the only thing that cannot be guessed,
    /// so it is asked for, and everything else comes from the template.
    private func create(from template: ProfileTemplate) async {
        let advice = template.folderAdvice ?? "Which folder should be served?"
        // No "Folder:" label — the field is right there and says what it is.
        guard let typed = prompt(advice), !typed.isEmpty else {
            screen = .profiles
            return
        }
        let root = AppPaths.expand(typed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            screen = .profiles
            say("That folder does not exist: \(root)", error: true)
            return
        }

        var list = ProfileStore.load()
        var name = template.title
        var counter = 2
        while list.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(template.title) \(counter)"
            counter += 1
        }
        let port = ProfileStore.suggestPort(profiles: list)
        let profile = template.makeProfile(name: name, port: port, root: root)
        list.append(profile)

        do {
            try ProfileStore.save(list)
            reload()
            selection = profiles.firstIndex { $0.id == profile.id } ?? 0
            screen = .profiles
            listOffset = 0
            let hint = template.rootHint.map {
                " — this kind of project usually serves its “\($0)” subfolder"
            } ?? ""
            say("Created \(name) on port \(port)" + hint)
        } catch {
            screen = .profiles
            say(error.localizedDescription, error: true)
        }
    }

    /// Deleting asks for the name in full. A list where one keystroke removes
    /// the highlighted row is a list you cannot trust to scroll through.
    private func deleteSelected() async {
        guard let profile = current else { return }
        guard let typed = prompt("Delete “\(profile.name)”? Type the name to confirm: "),
              typed == profile.name else {
            say("Not deleted.")
            return
        }
        if let entry = record(for: profile) { _ = await RunRegistry.stop(entry) }
        var list = ProfileStore.load()
        list.removeAll { $0.id == profile.id }
        do {
            try ProfileStore.save(list)
            reload()
            say("Deleted \(profile.name)")
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func loadDependencies() async {
        let checker = DependencyChecker()
        await checker.checkAll()
        dependencyReport = Dependency.catalog.map { ($0, checker.status(for: $0.command)) }
        message = nil
    }

    private func handleDependencies(_ key: Key) async {
        switch key {
        case .up:   selection = max(0, selection - 1)
        case .down: selection = min(max(0, dependencyReport.count - 1), selection + 1)
        case .escape: back(to: .profiles); selection = 0
        case .character("q"): quitting = true
        case .character("i"):
            guard dependencyReport.indices.contains(selection) else { return }
            let (dependency, status) = dependencyReport[selection]
            guard !status.installed else { say("\(dependency.title) is already installed."); return }
            say("Installing \(dependency.title) — this can take minutes…")
            draw()
            let checker = DependencyChecker()
            await checker.install(dependency, log: ConsoleLog())
            await loadDependencies()
            let now = dependencyReport.first { $0.0.command == dependency.command }?.1
            say(now?.installed == true ? "\(dependency.title) is ready."
                                       : "\(dependency.title) did not install.",
                error: now?.installed != true)
        default: break
        }
    }

    private func loadPorts() async {
        portEntries = await PortScanner.scan(includeUDP: false).sorted { $0.port < $1.port }
        message = nil
    }

    private func handlePorts(_ key: Key) async {
        switch key {
        case .up:   selection = max(0, selection - 1)
        case .down: selection = min(max(0, portEntries.count - 1), selection + 1)
        case .escape: back(to: .profiles); selection = 0; listOffset = 0
        case .character("q"): quitting = true
        case .character("R"):
            say("Reading…"); draw(); await loadPorts()
        case .character("k"):
            guard portEntries.indices.contains(selection) else { return }
            let entry = portEntries[selection]
            guard let typed = prompt("End \(entry.command) (pid \(entry.pid)) on port \(entry.port)? Type yes: "),
                  typed.lowercased() == "yes" else {
                say("Left alone.")
                return
            }
            let result = await PortScanner.kill(pid: entry.pid, signal: .term)
            await loadPorts()
            say(result.succeeded ? "Ended \(entry.command)." : "Could not end it.",
                error: !result.succeeded)
        default: break
        }
    }

    private func loadLog() {
        guard case .logs(let profile) = screen else { return }
        let path = AppPaths.subdir("Logs").appendingPathComponent("\(profile.name)-cli.log").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            logLines = []
            return
        }
        logLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var current: ServerProfile? {
        profiles.indices.contains(selection) ? profiles[selection] : nil
    }

    private func toggle() async {
        guard let profile = current else { return }
        if let entry = record(for: profile) {
            say("Stopping \(profile.name)…")
            draw()
            _ = await RunRegistry.stop(entry)
            reload()
            say("Stopped \(profile.name)")
        } else {
            say("Starting \(profile.name)…")
            draw()
            await startDetached(profile)
        }
    }

    private func restart() async {
        guard let profile = current else { return }
        if let entry = record(for: profile) {
            _ = await RunRegistry.stop(entry)
            try? await Task.sleep(for: .milliseconds(400))
        }
        await startDetached(profile)
    }

    /// Started detached on purpose: closing this screen must not take the
    /// servers with it, exactly as quitting the app does not.
    private func startDetached(_ profile: ServerProfile) async {
        let problems = profile.validationIssues
        guard problems.isEmpty else {
            say(problems[0], error: true)
            return
        }
        guard PortScanner.isPortFree(profile.port, host: profile.host) else {
            say("Port \(profile.port) is already in use.", error: true)
            return
        }
        do {
            let logPath = AppPaths.subdir("Logs").appendingPathComponent("\(profile.name)-cli.log").path
            let plan = try LaunchPlanBuilder.build(for: profile)
            try DetachedLauncher.prepare(plan, profile: profile)
            _ = try DetachedLauncher.launchSidecars(plan, logPath: logPath)
            let pid = try DetachedLauncher.launch(plan, logPath: logPath)

            try await Task.sleep(for: .milliseconds(700))
            guard kill(pid, 0) == 0 || errno == EPERM else {
                say("It started and stopped at once — see \(logPath)", error: true)
                return
            }
            RunRegistry.record(RunRecord(id: profile.id.uuidString, name: profile.name,
                                         address: profile.address, port: profile.port,
                                         pid: pid, origin: .commandLine, startedAt: Date()))
            reload()
            say("Started \(profile.name) on \(profile.address)")
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Editing one field, in place at the bottom of the screen.
    private func edit() async {
        guard case .detail(let profile) = screen,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }

        let name = Self.fields[fieldSelection]
        guard let typed = prompt("\(name): ") else { return }
        var updated = profiles[index]

        switch fieldSelection {
        case 0:
            guard !typed.isEmpty else { say("A name cannot be empty.", error: true); return }
            updated.name = typed
        case 1:
            guard let port = Int(typed), port > 0, port < 65_536 else {
                say("A port has to be between 1 and 65535.", error: true); return
            }
            updated.port = port
        case 2: updated.rootPath = AppPaths.expand(typed)
        case 3:
            guard let engine = ServerEngine(rawValue: typed) else {
                say("Engines: " + ServerEngine.allCases.map(\.rawValue).joined(separator: ", "), error: true)
                return
            }
            updated.engine = engine
        case 4: updated.phpVersion = typed
        case 5: updated.indexFile = typed
        case 6: updated.httpsEnabled = (typed.lowercased() == "on" || typed == "true")
        default: return
        }

        profiles[index] = updated
        do {
            try ProfileStore.save(profiles)
            reload()
            screen = .detail(profiles[index])
            say("Saved.")
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Reads a line with the terminal briefly back in its normal mode, so
    /// deleting and pasting behave the way they do everywhere else.
    /// Asks for a line of text without leaving the screen.
    ///
    /// This used to drop out of the alternate screen, hand the terminal back and
    /// call `readLine()`. That works when it works — and when it does not, the
    /// prompt is printed somewhere the person cannot see it, or Enter never
    /// arrives because the terminal was left in a mode neither side expected.
    /// There is no way to tell which from the outside; the whole manoeuvre was
    /// the fragile part.
    ///
    /// So the field is drawn where everything else is drawn, and keys are read
    /// the same way as everywhere else. Nothing is handed back and forth.
    private func prompt(_ label: String, initial: String = "") -> String? {
        var text = initial

        while true {
            terminal.begin()
            header(terminal.size.columns)

            terminal.putLine()
            for line in label.split(separator: "\n", omittingEmptySubsequences: false) {
                terminal.putLine("  " + Style.grey(String(line)))
            }
            terminal.putLine()

            // A visible caret, because the real one is hidden while drawing.
            terminal.putLine("  " + Style.inverse(" " + text + " "))
            terminal.putLine()
            terminal.putLine(Style.grey("  ⏎ confirm   esc cancel"))
            terminal.flush()

            switch terminal.readKey() {
            case .enter:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            case .escape:
                return nil
            case .backspace, .delete:
                if !text.isEmpty { text.removeLast() }
            case .control("c"):
                return nil
            case .control("u"):
                text = ""
            case .character(let character):
                text.append(character)
            default:
                break
            }
        }
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }
}

/// Opening a URL without dragging AppKit into every file — and the one call that
/// will need replacing on Linux, where `xdg-open` does the same job.
func NSWorkspaceOpen(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
}
