//
//  ContentView.swift
//  ServerMaster
//

import SwiftUI
import Combine

struct ContentView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Group {
                switch model.settings.sidebarStyle {
                case .standard: standardSidebar
                case .modern:   modernSidebar
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { bannerView }
        }
        .onChange(of: model.section) { _, _ in
            model.flushPendingSaves()
            model.saveSettings()
            if model.section == .ports {
                Task { await model.refreshPorts() }
                model.startPortAutoRefresh()
            } else {
                model.stopPortAutoRefresh()
            }
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            model.saveSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // A safety net: normally the shutdown window from AppDelegate stops everything,
            // we only get here when it has been bypassed.
            if model.settings.stopServerOnQuit {
                model.stopAllImmediately()
            }
            model.reserver.releaseAll()
            model.saveSettings()
        }
    }

    // MARK: - Parts

    // MARK: - The two sidebars

    /// The system sidebar, the way every other Mac app looks. The default,
    /// because familiarity is worth more than novelty in the one control people
    /// use to get anywhere.
    private var standardSidebar: some View {
        @Bindable var model = model

        return List(selection: $model.section) {
            let _ = model.featureRevision
            ForEach(SidebarSection.Group.allCases, id: \.self) { group in
                let sections = SidebarSection.visible(in: group)
                if !sections.isEmpty {
                    Section(LocalizedStringKey(group.rawValue)) {
                        ForEach(sections) { section in
                            row(section)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The other one: taller rows, the icon in its own tinted tile, and Liquid
    /// Glass under whichever is selected.
    ///
    /// Not a List. A List insists on its own selection drawing and its own row
    /// insets, and fighting both to get here produced the flat dark column that
    /// had to be reverted once already. A stack of buttons has none of that.
    private var modernSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let _ = model.featureRevision
                ForEach(SidebarSection.Group.allCases, id: \.self) { group in
                    let sections = SidebarSection.visible(in: group)
                    if !sections.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(group.rawValue))
                                .font(.caption).fontWeight(.medium)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 2)

                            ForEach(sections) { section in
                                modernRow(section)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        }
        .scrollContentBackground(.hidden)
    }

    private func modernRow(_ section: SidebarSection) -> some View {
        let isSelected = model.section == section

        return Button {
            model.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .background(isSelected ? AnyShapeStyle(Color.accentColor)
                                           : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 7))

                Text(section.title)
                    .fontWeight(isSelected ? .medium : .regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .modifier(SidebarRowGlass(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    /// Glass under the selected row only. Every row on glass is a wall of it,
    /// and the material only reads as a material with something plain beside it.
    private struct SidebarRowGlass: ViewModifier {
        let isSelected: Bool

        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(isSelected ? .regular.interactive() : .identity,
                                    in: .rect(cornerRadius: 9))
            } else {
                content.background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                   in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    /// A sidebar row.
    ///
    /// Deliberately plain. Glass was tried here and taken out again: clearing
    /// the row background to make room for it also takes away the vibrancy the
    /// sidebar draws itself with, and the whole column goes flat and dark. The
    /// sidebar already has a material — it is the content beside it that needed
    /// one.
    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section)
    }

    /// One colour per running server, taken from the profile's own accent.
    private var runningColours: [Color] {
        model.profiles
            .filter { model.state(of: $0.id) == .running }
            .compactMap { Color.accent(fromHex: $0.errorPageAccent) }
    }

    /// Every section over the same moving background.
    ///
    /// Put here rather than in each screen: one place decides it, a new section
    /// gets it without being asked, and the colour does not restart when you
    /// move between sections — which it would if each view built its own.
    private var detail: some View {
        ZStack {
            if model.settings.backgroundEnabled {
                AmbientBackground(colours: model.settings.backgroundFollowsServers
                                            ? runningColours : [],
                                  isActive: model.activeCount > 0,
                                  hue: model.settings.backgroundHue,
                                  speed: model.settings.backgroundSpeed,
                                  saturation: model.settings.backgroundSaturation)
            }
            section
        }
        // Scroll views and lists paint an opaque background of their own, which
        // would cover this completely.
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var section: some View {
        switch model.section {
        case .control:      ControlView()
        case .dependencies: DependenciesView()
        case .console:      ConsoleView()
        case .profiles:     ProfilesView()
        case .database:     DatabaseView()
        case .ports:        PortsView()
        case .settings:     AppSettingsView()
        case .backups:      BackupsView()
        case .diagnostics:  DiagnosticsView()
        case .files:        SiteFilesView()
        case .commandLine:  CommandLineView()
        case .about:        AboutView()
        }
    }

    private var statusSubtitle: String {
        switch model.activeCount {
        case 0:  return String(localized: "No servers running")
        case 1:  return model.activeProfiles.first?.name ?? String(localized: "1 server")
        default: return String(localized: "\(String(model.activeCount)) servers running")
        }
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            // Always in view, on every screen: the guides are the answer to most
            // of what stops a newcomer, and burying them in a menu hides them.
            Button {
                AppLinks.open(.index)
            } label: {
                Label("Guides", systemImage: "book")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("How to run Joomla, WordPress and the rest — opens in your browser")
            .padding(.horizontal, 12)
            .padding(.top, 2)

            // A menu rather than a label: with several servers running, the one
            // name that used to be shown told you least about the others.
            Menu {
                if model.activeProfiles.isEmpty {
                    Text("Nothing is running")
                } else {
                    ForEach(model.activeProfiles) { profile in
                        Menu(profile.name) {
                            Button("Open in the browser") {
                                if let url = URL(string: profile.address) { NSWorkspace.shared.open(url) }
                            }
                            Button("Show the log") {
                                model.section = .console
                                model.selectedProfileID = profile.id
                            }
                            Divider()
                            Button("Restart") { Task { await model.restartServer(profile: profile) } }
                            Button("Stop") { Task { await model.stopServer(profileID: profile.id) } }
                        }
                    }
                    Divider()
                    Button("Stop all") { Task { await model.stopAll() } }
                }
            } label: {
                HStack(spacing: 8) {
                    StatusDot(state: model.aggregateState)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.aggregateState.title)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(statusSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.activeCount > 0 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.activeCount == 0)
            .padding(.horizontal, 12)

            // Quitting from here stops every server on the way out, which is not
            // what force-quitting does — hence a button rather than a hint.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.activeCount > 0
                  ? String(localized: "Stops the running servers, then quits")
                  : String(localized: "Quit ServerMaster"))
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = model.banner {
            HStack(spacing: 8) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(banner.text)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(banner.isError ? Color.red.opacity(0.5) : Color.green.opacity(0.5))
            )
            .foregroundStyle(banner.isError ? Color.red : Color.primary)
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Small shared views

struct StatusDot: View {
    let state: ServerState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.15)))
    }

    private var color: Color {
        switch state {
        case .running:  return .green
        case .starting, .stopping: return .orange
        case .failed:   return .red
        case .stopped:  return .secondary
        }
    }
}

/// A section heading with a caption and arbitrary buttons on the right.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2).fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

#Preview {
    ContentView().environment(AppModel())
}
