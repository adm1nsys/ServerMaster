//
//  ConsoleView.swift
//  ServerMaster
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConsoleView: View {

    @Environment(AppModel.self) private var model

    /// A console tab: a terminal, or the log of a specific server.
    enum Tab: Hashable {
        case terminal(UUID)
        case server(UUID)
    }

    @State private var tab: Tab = .terminal(UUID())
    @State private var filter = ""
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @State private var renamingTerminal: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // No dividers between these. The two bars are glass panels floating
            // over the background, and a hairline across the window is the thing
            // that made this screen look like a form.
            VStack(spacing: 8) {
                tabBar
                toolbar
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            switch tab {
            case .terminal(let id):
                if let item = model.terminal(id) {
                    terminalConsole(item)
                } else {
                    ContentUnavailableView("Tab closed", systemImage: "terminal")
                }
            case .server(let id):
                if let controller = model.existingController(for: id) {
                    serverConsole(id: id, controller: controller)
                } else {
                    ContentUnavailableView("Log unavailable", systemImage: "text.alignleft")
                }
            }
        }
        .onAppear { selectSensibleTab() }
        .onChange(of: model.runningOrder) { _, order in
            // A freshly started server is brought to the front.
            if case .terminal = tab, let last = order.last {
                tab = .server(last)
            }
            if case .server(let id) = tab, model.existingController(for: id) == nil {
                tab = .terminal(model.ensureTerminal().id)
            }
        }
    }

    // MARK: - Tabs

    @Namespace private var glass

    @ViewBuilder
    private var tabBar: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { tabRow }
        } else {
            tabRow
        }
    }

    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.terminals) { item in
                    if renamingTerminal == item.id {
                        TextField("", text: Binding(
                            get: { model.terminal(item.id)?.title ?? "" },
                            set: { model.terminal(item.id)?.title = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .frame(width: 140)
                        .focused($renameFocused)
                        .onSubmit { finishRenamingTerminal() }
                        .onExitCommand { finishRenamingTerminal() }
                    } else {
                        chip(title: item.title, symbol: "terminal", state: nil,
                             tab: .terminal(item.id), closable: model.terminals.count > 1) {
                            closeTerminal(item.id)
                        }
                        .onTapGesture(count: 2) { startRenaming(item.id) }
                        .contextMenu {
                            Button("Rename") { startRenaming(item.id) }
                            Button("Restart shell") { model.restartTerminal(item.id) }
                            Divider()
                            Button("Close", role: .destructive) { closeTerminal(item.id) }
                                .disabled(model.terminals.count <= 1)
                        }
                    }
                }

                Button {
                    let created = model.newTerminal()
                    tab = .terminal(created.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .modifier(TabGlass(isSelected: false))
                }
                .buttonStyle(.plain)
                .help("New terminal tab")

                Divider().frame(height: 16)

                ForEach(loggedProfiles, id: \.id) { profile in
                    chip(title: profile.name,
                         symbol: profile.symbol,
                         state: model.state(of: profile.id),
                         tab: .server(profile.id))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    /// Profiles with something to show: running, or with a launch history.
    private var loggedProfiles: [ServerProfile] {
        let running = model.runningOrder
        let withLogs = model.servers
            .filter { !$0.value.log.lines.isEmpty }
            .map(\.key)
        var ordered = running
        for id in withLogs where !ordered.contains(id) { ordered.append(id) }
        return ordered.compactMap { id in model.profiles.first { $0.id == id } }
    }

    private func chip(title: String, symbol: String, state: ServerState?, tab target: Tab,
                      closable: Bool = false, onClose: (() -> Void)? = nil) -> some View {
        let isSelected = tab == target
        return Button {
            tab = target
            filter = ""
        } label: {
            HStack(spacing: 6) {
                if let state {
                    StatusDot(state: state)
                } else {
                    Image(systemName: symbol).font(.caption)
                }
                Text(title).lineLimit(1)
                if case .server(let id) = target, model.isActive(id) {
                    Button {
                        Task { await model.stopServer(profileID: id) }
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
                if closable, let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
            .font(.callout)
            .fontWeight(isSelected ? .medium : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(TabGlass(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    /// Glass on a tab, and the selected one carries more of it.
    ///
    /// Both states get glass rather than only the selected one: a row of tabs is
    /// a row of the same thing, and giving half of them a different material
    /// makes the unselected ones read as disabled.
    private struct TabGlass: ViewModifier {
        let isSelected: Bool

        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.35)).interactive()
                                            : .regular.interactive(),
                                 in: .capsule)
            } else {
                content
                    .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                           : AnyShapeStyle(.quaternary),
                                in: Capsule())
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            if case .terminal(let id) = tab, let item = model.terminal(id) {
                Text(item.session.isRunning
                     ? String(localized: "Shell: \(model.settings.shellPath)")
                     : String(localized: "Shell is not running"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if case .server(let id) = tab,
                      let profile = model.profiles.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                    Text(model.state(of: id).title)
                        .font(.caption).foregroundStyle(.secondary)
                    if let pid = model.existingController(for: id)?.processIdentifier {
                        Text("PID \(String(pid))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(profile.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Everything that used to sit in a strip along the bottom. It was
            // the only part of the window that was neither content nor chrome,
            // and it separated the log from the edge for no reason — the actions
            // belong with the other controls.
            tabActions

            filterField

            if let currentLog {
                Text("\(currentLog.lines.count) lines")
                    .font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Menu {
                Button("Clear") {
                    if case .terminal(let id) = tab {
                        model.terminal(id)?.session.terminal.reset()
                    } else { currentLog?.clear() }
                }
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    let text: String
                    if case .terminal(let id) = tab {
                        text = model.terminal(id)?.session.terminal.plainText ?? ""
                    }
                    else { text = currentLog?.plainText ?? "" }
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save to file…") { saveLog() }
                Divider()
                Button("Open external terminal") { openExternalTerminal() }
                Button("Logs folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.logs.path)
                }
                // The file this tab is writing to. It used to be a caption in
                // the strip along the bottom; here it is something you can act
                // on rather than only read.
                if let url = currentLog?.fileURL {
                    Button("Reveal \(url.lastPathComponent)") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if case .terminal(let id) = tab {
                    Divider()
                    Button("Go to the profile root") {
                        if let directory = model.selectedProfile?.effectiveWorkingDirectory {
                            model.terminal(id)?.session.send("cd \(ProcessRunner.shellQuote(directory))\n")
                        }
                    }
                    Button("Restart shell") { model.restartTerminal(id) }
                    Button("Rename tab") { startRenaming(id) }
                    Button("New tab") {
                        let created = model.newTerminal()
                        tab = .terminal(created.id)
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(BarGlass())
    }

    /// The toolbar itself on glass, so it reads as a panel over the log rather
    /// than as another band of window.
    private struct BarGlass: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 12))
            } else {
                content.background(.bar, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// A search field that looks like the rest of the screen. A rounded-border
    /// text field next to a row of glass is the one control that still looks
    /// like a settings dialog.
    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 130)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(TabGlass(isSelected: false))
    }

    /// Start, stop, restart, open — whichever of them applies to the tab in
    /// front of you.
    @ViewBuilder
    private var tabActions: some View {
        switch tab {
        case .server(let id):
            if let profile = model.profiles.first(where: { $0.id == id }),
               let controller = model.existingController(for: id) {
                if controller.state.isActive {
                    consoleButton("Stop", "stop.fill") {
                        Task { await model.stopServer(profileID: id) }
                    }
                    consoleButton("Restart", "arrow.clockwise") {
                        Task { await model.restartServer(profile: profile) }
                    }
                } else {
                    consoleButton("Start", "play.fill", prominent: true) {
                        Task { await model.startServer(profile: profile) }
                    }
                }
                if controller.state == .running {
                    consoleButton("Open", "safari") { controller.openInBrowser() }
                }
            }

        case .terminal(let id):
            if let item = model.terminal(id) {
                if item.session.isRunning {
                    Text("\(String(item.session.terminal.columns))×\(String(item.session.terminal.rows))")
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    consoleButton("Interrupt", "hand.raised") { item.session.interrupt() }
                } else {
                    Label("Shell stopped", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                consoleButton("Restart", "arrow.clockwise") { model.restartTerminal(id) }
            }
        }
    }

    @ViewBuilder
    private func consoleButton(_ title: LocalizedStringKey, _ symbol: String,
                               prominent: Bool = false,
                               _ run: @escaping () -> Void) -> some View {
        let button = Button(action: run) {
            Label(title, systemImage: symbol).font(.callout)
        }
        if #available(macOS 26.0, *) {
            if prominent {
                button.buttonStyle(.glassProminent).controlSize(.small)
            } else {
                button.buttonStyle(.glass).controlSize(.small)
            }
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var currentLog: ConsoleLog? {
        switch tab {
        case .terminal: return nil   // a real terminal has its own screen buffer
        case .server(let id): return model.existingController(for: id)?.log
        }
    }

    // MARK: - Server log

    private func serverConsole(id: UUID, controller: ServerController) -> some View {
        // Just the log. Everything that used to be in a strip underneath is in
        // the toolbar above, where the rest of the controls are.
        LogOutputView(log: controller.log,
                      fontSize: model.settings.consoleFontSize,
                      autoScroll: model.settings.autoScrollConsole,
                      filter: filter)
    }

    // MARK: - Terminal

    private func terminalConsole(_ item: AppModel.TerminalTab) -> some View {
        TerminalView(session: item.session, fontSize: model.settings.consoleFontSize)
    }

    private func startRenaming(_ id: UUID) {
        tab = .terminal(id)
        renamingTerminal = id
        renameFocused = true
    }

    private func finishRenamingTerminal() {
        // An empty name says nothing — fall back to the tab number.
        if let id = renamingTerminal, let item = model.terminal(id),
           item.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let number = (model.terminals.firstIndex { $0.id == id } ?? 0) + 1
            item.title = String(localized: "Terminal \(String(number))")
        }
        renamingTerminal = nil
        renameFocused = false
    }

    private func closeTerminal(_ id: UUID) {
        let wasSelected = tab == .terminal(id)
        model.closeTerminal(id)
        if wasSelected, let first = model.terminals.first {
            tab = .terminal(first.id)
        }
    }

    // MARK: - Line-by-line shell (fallback)

    private var shellConsole: some View {
        VStack(spacing: 0) {
            if model.shell.log.lines.isEmpty {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: {
                    Text("A plain console in the profile working directory. Browse command history with the up and down arrows.")
                } actions: {
                    Button("Open external terminal") { openExternalTerminal() }
                }
                .frame(maxHeight: .infinity)
            } else {
                LogOutputView(log: model.shell.log,
                              fontSize: model.settings.consoleFontSize,
                              autoScroll: model.settings.autoScrollConsole,
                              filter: filter)
            }

            Divider()

            HStack(spacing: 8) {
                Text(model.shell.prompt)
                    .font(.system(size: model.settings.consoleFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .trailing)

                TextField("command", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: model.settings.consoleFontSize, design: .monospaced))
                    .focused($commandFocused)
                    .onSubmit(runCommand)
                    .onKeyPress(.upArrow) {
                        if let previous = model.shell.previousCommand(current: command) {
                            command = previous
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        if let next = model.shell.nextCommand() {
                            command = next
                            return .handled
                        }
                        return .ignored
                    }

                if model.shell.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run", action: runCommand)
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear { commandFocused = true }
    }

    // MARK: - Actions

    private func selectSensibleTab() {
        let first = model.ensureTerminal()
        if let last = model.runningOrder.last {
            tab = .server(last)
        } else if let selected = model.selectedProfileID,
                  model.existingController(for: selected)?.log.lines.isEmpty == false {
            tab = .server(selected)
        } else {
            tab = .terminal(first.id)
        }
    }

    private func runCommand() {
        let text = command
        command = ""
        Task { await model.shell.run(text) }
    }

    private func openExternalTerminal() {
        let directory: String
        switch tab {
        case .terminal:
            directory = model.selectedProfile?.effectiveWorkingDirectory ?? NSHomeDirectory()
        case .server(let id):
            directory = model.profiles.first { $0.id == id }?.effectiveWorkingDirectory
                ?? model.shell.currentDirectory
        }
        ShellSession.openExternalTerminal(app: model.settings.terminalApp, directory: directory)
    }

    private func saveLog() {
        if case .terminal(let id) = tab, let item = model.terminal(id) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "terminal.txt"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? item.session.terminal.plainText.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let log = currentLog else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = {
            if case .server(let id) = tab, let profile = model.profiles.first(where: { $0.id == id }) {
                return profile.name.replacingOccurrences(of: "/", with: "-") + ".log"
            }
            return "shell.log"
        }()
        panel.allowedContentTypes = [.plainText, .log]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.timestampedText().write(to: url, atomically: true, encoding: .utf8)
    }
}
