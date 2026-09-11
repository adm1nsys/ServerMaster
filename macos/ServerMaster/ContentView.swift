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
            List(selection: $model.section) {
                Section("Server") {
                    row(.control)
                    row(.console)
                    row(.database)
                    row(.ports)
                }
                Section("Configuration") {
                    row(.profiles)
                    row(.dependencies)
                    row(.settings)
                    row(.about)
                }
            }
            .listStyle(.sidebar)
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

    private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .control:      ControlView()
        case .dependencies: DependenciesView()
        case .console:      ConsoleView()
        case .profiles:     ProfilesView()
        case .database:     DatabaseView()
        case .ports:        PortsView()
        case .settings:     AppSettingsView()
        case .about:        AboutView()
        }
    }

    private var statusSubtitle: String {
        switch model.activeCount {
        case 0:  return "No servers running"
        case 1:  return model.activeProfiles.first?.name ?? ""
        default: return "Servers: \(model.activeCount)"
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
            }
            .padding(.horizontal, 12)
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
