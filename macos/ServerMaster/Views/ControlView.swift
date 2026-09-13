//
//  ControlView.swift
//  ServerMaster
//

import SwiftUI
import Combine

struct ControlView: View {

    @Environment(AppModel.self) private var model
    @State private var stopCandidate: ServerProfile?
    @State private var now = Date()

    /// Ties the header buttons together so Liquid Glass can flow between them
    /// rather than one appearing next to the other.
    @Namespace private var glass

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // The background is drawn once for every section, in ContentView.
        Group {
            ScrollView {
                VStack(alignment: .center, spacing: 22) {
                    title
                    summary
                    quickActions
                    if model.health.hasResults || model.health.isRunning {
                        glassPanel(healthCard)
                    }
                    glassPanel(serverList)
                    if let profile = model.selectedProfile {
                        glassPanel(issuesCard(for: profile))
                        glassPanel(detailsCard(for: profile))
                    }
                }
                .padding(36)
//                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity)
        .onReceive(ticker) { now = $0 }
        .confirmationDialog("Stop “\(stopCandidate?.name ?? "")”?",
                            isPresented: Binding(get: { stopCandidate != nil },
                                                 set: { if !$0 { stopCandidate = nil } })) {
            Button("Stop", role: .destructive) {
                if let profile = stopCandidate {
                    Task { await model.stopServer(profileID: profile.id) }
                }
                stopCandidate = nil
            }
            Button("Cancel", role: .cancel) { stopCandidate = nil }
        }
    }

    // MARK: - Title and the buttons beside it

    private var title: some View {
        ScreenTitle(title: "Control",
                    subtitle: model.activeCount == 0
                        ? "Nothing running. Pick a profile and press Start."
                        : "^[\(model.activeCount) server](inflect: true) running") {
            headerButtons
        }
    }

    /// Console, and Stop all when there is something to stop.
    ///
    /// Both live in one glass container with matched identities, so the second
    /// button grows out of the first instead of appearing beside it — which is
    /// what Liquid Glass is for, and it also answers the question of where a
    /// button that is not always there comes from.
    @ViewBuilder
    private var headerButtons: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    if model.activeCount > 0 {
                        Button(role: .destructive) {
                            Task { await model.stopAll() }
                        } label: {
                            Label("Stop all", systemImage: "stop.fill")
                        }
                        .buttonStyle(.glass)
                        .glassEffectID("stopAll", in: glass)
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button {
                        model.section = .console
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("console", in: glass)
                }
            }
            .animation(.smooth(duration: 0.4), value: model.activeCount > 0)
        } else {
            HStack(spacing: 8) {
                if model.activeCount > 0 {
                    Button { Task { await model.stopAll() } } label: {
                        Label("Stop all", systemImage: "stop.fill")
                    }
                }
                Button { model.section = .console } label: {
                    Label("Console", systemImage: "terminal")
                }
            }
        }
    }

    // MARK: - The strip of numbers

    /// Three figures, monospaced so they do not jitter as they count.
    private var summary: some View {
        HStack(spacing: 12) {
            figure(String(model.activeCount), of: "running",
                   symbol: "bolt.horizontal.circle",
                   tint: model.activeCount > 0 ? .green : .secondary)
            figure(String(model.profiles.count), of: "profiles",
                   symbol: "square.stack.3d.up", tint: .secondary)
            figure(longestUptime, of: "longest run",
                   symbol: "clock", tint: .secondary)
            Spacer()
        }
    }

    private func figure(_ value: String, of caption: LocalizedStringKey,
                        symbol: String, tint: Color) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.medium)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)

        return Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 14))
            } else {
                content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var longestUptime: String {
        let starts = model.profiles.compactMap { profile -> Date? in
            guard model.state(of: profile.id) == .running else { return nil }
            return model.existingController(for: profile.id)?.startedAt
        }
        guard let earliest = starts.min() else { return "—" }
        return uptime(from: earliest)
    }

    // MARK: - Quick actions

    /// Buttons that are drawn but not wired up yet.
    ///
    /// Deliberately visible rather than hidden until they work: the shape of the
    /// screen is being decided here, and a row that appears later changes the
    /// layout everyone has already got used to. Each says so when pressed rather
    /// than doing nothing, which is the difference between unfinished and broken.
    private var quickActions: some View {
        HStack(spacing: 10) {
            action("Open all", "safari") { openAllRunning() }
                .disabled(runningProfiles.isEmpty)

            action("Copy addresses", "doc.on.doc") { copyAddresses() }
                .disabled(model.profiles.isEmpty)

            action("Health check", "waveform.path.ecg") {
                Task { await model.health.run(runningProfiles) }
            }
            .disabled(runningProfiles.isEmpty || model.health.isRunning)

            action("New profile", "plus") { model.section = .profiles }
            Spacer()
        }
    }

    private var runningProfiles: [ServerProfile] {
        model.profiles.filter { model.state(of: $0.id) == .running }
    }

    /// Opens each running site. Staggered by a breath: handing a browser five
    /// URLs in the same instant is how you get four tabs and one dropped.
    private func openAllRunning() {
        let running = runningProfiles
        Task {
            for profile in running {
                model.existingController(for: profile.id)?.openInBrowser()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Every address, one per line, each prefixed with its profile so the
    /// paste is readable in a message rather than being a wall of URLs.
    private func copyAddresses() {
        let lines = model.profiles.map { profile -> String in
            let mark = model.state(of: profile.id) == .running ? "" : "  (stopped)"
            return "\(profile.name): \(profile.address)\(mark)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        model.notify(String(localized: "^[\(lines.count) address](inflect: true) copied."))
    }

    private func action(_ label: LocalizedStringKey, _ symbol: String,
                        _ run: @escaping () -> Void) -> some View {
        let button = Button(action: run) {
            Label(label, systemImage: symbol)
                .font(.callout)
        }
        return Group {
            if #available(macOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    // MARK: - What the health check found

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Health check", systemImage: "waveform.path.ecg")
                    .fontWeight(.medium)
                if model.health.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let last = model.health.lastRun, !model.health.isRunning {
                    Text(last, style: .time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                glassChip("Clear") { model.health.clear() }
            }

            if !model.health.isRunning, model.health.hasResults {
                Text(model.health.failures == 0
                     ? "Every running site answered."
                     : "^[\(model.health.failures) site](inflect: true) did not answer properly.")
                    .font(.callout)
                    .foregroundStyle(model.health.failures == 0 ? Color.secondary : Color.orange)
            }

            ForEach(model.health.results) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.isGood ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.isGood ? .green : .red)
                    Text(result.name)
                    Text(result.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(result.isGood ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(15)
    }

    /// A small glass button for the inline actions — Copy, Open, Configure.
    ///
    /// These were links. A link inside a glass panel is the one control that
    /// still looks like it belongs to a web page, and next to a row of glass
    /// buttons it reads as unfinished rather than as restraint.
    @ViewBuilder
    private func glassChip(_ title: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        let button = Button(title, action: run)
            .font(.caption)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).controlSize(.small)
        } else {
            button.buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// A glass button, or a bordered one on macOS before 26.
    ///
    /// `prominent` is for the one action a row is actually about — Start, or
    /// Stop when it is running. Everything else stays quiet; if every button is
    /// prominent then none of them is.
    @ViewBuilder
    private func glassButton(_ content: some View, prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(.bordered)
        }
    }

    // MARK: - Profile list

    private var serverList: some View {
        // No GroupBox: the glass panel around this is already the container, and
        // a box inside it puts a second surface on top of the first.
        Group {
            VStack(spacing: 0) {
                if model.profiles.isEmpty {
                    HStack {
                        Text("No profiles yet.")
                            .foregroundStyle(.secondary)
                        glassChip("Create") { model.section = .profiles }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider() }
                        row(for: profile)
                    }
                }
            }
            .padding(15)
        }
    }

    private func row(for profile: ServerProfile) -> some View {
        let state = model.state(of: profile.id)
        let controller = model.existingController(for: profile.id)
        let isSelected = model.selectedProfileID == profile.id

        return HStack(spacing: 12) {
            StatusDot(state: state)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    if model.settings.defaultProfileID == profile.id {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if profile.runAsAdministrator {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Starts with administrator rights")
                    }
                }
                HStack(spacing: 6) {
                    Text(profile.engine.title)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(profile.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if state == .running, let started = controller?.startedAt {
                Text(uptime(from: started))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if case .failed = state {
                Text("error")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if state == .running {
                glassButton(Button {
                    controller?.openInBrowser()
                } label: {
                    Image(systemName: "safari")
                })
                .help("Open in browser")
            }

            glassButton(Button {
                model.selectedProfileID = profile.id
                model.section = .console
            } label: {
                Image(systemName: "text.alignleft")
            })
            .help("Show log")
            .disabled(controller == nil)

            if state.isBusy {
                ProgressView().controlSize(.small).frame(width: 74)
            } else if state.isActive {
                // Restart is what you press after every config change, so it
                // belongs next to Stop rather than only in a menu.
                glassButton(Button {
                    Task { await model.restartServer(profile: profile) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                })
                .help("Restart")

                glassButton(Button {
                    if model.settings.confirmBeforeStop {
                        stopCandidate = profile
                    } else {
                        Task { await model.stopServer(profileID: profile.id) }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(width: 56)
                }, prominent: true)
            } else {
                glassButton(Button {
                    Task { await model.startServer(profile: profile) }
                } label: {
                    Label("Start", systemImage: "play.fill").frame(width: 56)
                }, prominent: true)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.primary.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedProfileID = profile.id }
        .contextMenu {
            Button("Configure") {
                model.selectedProfileID = profile.id
                model.section = .profiles
            }
            Button("Make default") { model.makeDefault(profile) }
            if model.isActive(profile.id) {
                Button("Restart") { Task { await model.restartServer(profile: profile) } }
            }
        }
    }

    private func uptime(from date: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    // MARK: - Problems with the selected profile

    /// Liquid Glass behind the panels that carry information.
    ///
    /// These are the ones worth putting on glass: they sit over the moving
    /// background, and a solid card would block it while a transparent one would
    /// leave the text swimming. Glass does both jobs — it stays legible and it
    /// keeps the colour moving underneath visible.
    ///
    /// macOS 26 and later. Below that the panels keep the material they had.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }

    @ViewBuilder
    private func issuesCard(for profile: ServerProfile) -> some View {
        let issues = profile.validationIssues
        let missing = model.dependencies.missingTools(for: profile.engine)
        let state = model.state(of: profile.id)
        let failure: String? = { if case .failed(let m) = state { return m }; return nil }()

        if failure != nil || !issues.isEmpty || !missing.isEmpty {
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        Label("The last start failed", systemImage: "xmark.octagon.fill")
                            .font(.callout).fontWeight(.medium)
                            .foregroundStyle(.red)
                        Text(failure)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        // The moment someone actually needs the guides is the
                        // moment something refused to start, so the link lands
                        // on the page that explains this particular failure.
                        glassChip("What does this mean?") {
                            AppLinks.open(AppLinks.guide(forFailure: failure))
                        }

                        if profile.port < 1024, !profile.runAsAdministrator {
                            HStack(spacing: 12) {
                                if let replacement = PortPresets.localReplacement(for: profile.port) {
                                    Button("Switch the port to \(String(replacement))") {
                                        var updated = profile
                                        updated.port = replacement
                                        model.updateProfile(updated)
                                        model.notify("Port of the “\(profile.name)” profile changed to \(String(replacement)).")
                                    }
                                }
                                glassChip("Start with administrator rights") {
                                    var updated = profile
                                    updated.runAsAdministrator = true
                                    model.updateProfile(updated)
                                    Task { await model.startServer(profile: updated) }
                                }
                            }
                        }
                        if !issues.isEmpty || !missing.isEmpty { Divider() }
                    }

                    if !issues.isEmpty || !missing.isEmpty {
                        Label("Worth checking before start", systemImage: "exclamationmark.triangle")
                            .font(.callout).fontWeight(.medium)
                            .foregroundStyle(.orange)
                    }

                    ForEach(missing, id: \.self) { tool in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text("**\(tool)** is not installed — the \(profile.engine.title) engine will not start.")
                            glassChip("To dependencies") { model.section = .dependencies }
                        }
                        .font(.callout)
                    }

                    ForEach(issues, id: \.self) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(issue).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
            }
        }
    }

    // MARK: - Details of the selected profile

    private func detailsCard(for profile: ServerProfile) -> some View {
        let controller = model.existingController(for: profile.id)

        return Group {
            VStack(alignment: .leading, spacing: 0) {
                // The label GroupBox used to draw, as an ordinary row: the glass
                // panel around this is the container now, and a box inside it
                // would put a second surface on the first.
                PanelHeader(title: LocalizedStringKey(profile.name), symbol: profile.symbol) {
                    glassChip("Configure") { model.section = .profiles }
                }
                .padding(.bottom, 8)

                InfoRow(label: "Engine", value: profile.engine.title)
                Divider()
                InfoRow(label: "Address", value: profile.address)

                if let urls = controller?.detectedURLs, !urls.isEmpty {
                    Divider()
                    HStack(alignment: .top) {
                        Text("Available at")
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(urls, id: \.self) { url in
                                HStack(spacing: 8) {
                                    Text(url)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    glassChip("Open") { controller?.openInBrowser(url) }
                                    glassChip("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                if profile.engine.usesRootDirectory {
                    Divider()
                    InfoRow(label: "Root", value: AppPaths.abbreviate(AppPaths.expand(profile.rootPath)),
                            action: ("Show in Finder", {
                                NSWorkspace.shared.selectFile(nil,
                                    inFileViewerRootedAtPath: AppPaths.expand(profile.rootPath))
                            }))
                }
                if let pid = controller?.processIdentifier {
                    Divider()
                    InfoRow(label: "PID", value: String(pid), monospaced: true)
                }
                if let command = controller?.lastCommand, !command.isEmpty {
                    Divider()
                    InfoRow(label: "Command", value: command, monospaced: true,
                            action: ("Copy", {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }))
                }
            }
            .padding(15)
        }
    }
}

struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced: Bool = false
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                // The same glass chip the rest of the screen uses. InfoRow is a
                // separate type, so it carries its own small copy rather than
                // reaching back into the view above it.
                let button = Button(action.title, action: action.run).font(.caption)
                if #available(macOS 26.0, *) {
                    button.buttonStyle(.glass).controlSize(.small)
                } else {
                    button.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
