//
//  MenuBarView.swift
//  ServerMaster
//
//  The status item next to Control Center. The point is not to be a second copy
//  of the app: it answers “is it running?” at a glance and lets a profile be
//  started, stopped or restarted without switching windows at all.
//
//  Anything that needs reading — logs, configuration, the database — opens the
//  real window instead of being crammed in here.
//

import SwiftUI
import AppKit

/// What the icon in the menu bar shows, before anything is clicked.
struct MenuBarLabel: View {

    let model: AppModel

    var body: some View {
        // A filled icon reads as “something is running” even in a crowded menu
        // bar; the count only appears when it is worth knowing.
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if model.activeCount > 1 {
                Text(String(model.activeCount))
            }
        }
    }

    private var symbol: String {
        switch model.aggregateState {
        case .running:  return "server.rack"
        case .starting: return "arrow.triangle.2.circlepath"
        case .failed:   return "exclamationmark.triangle.fill"
        default:        return "server.rack"
        }
    }
}

struct MenuBarView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider().padding(.vertical, 6)
            profiles
            Divider().padding(.vertical, 6)
            services
            Divider().padding(.vertical, 6)
            actions
        }
        .padding(10)
        .frame(width: 320)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 8) {
            StatusDot(state: model.aggregateState)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.aggregateState.title).fontWeight(.medium)
                Text(model.activeCount == 0
                     ? String(localized: "Nothing is running")
                     : String(localized: "Running: \(String(model.activeCount))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeCount > 0 {
                Button("Stop all") { Task { await model.stopAll() } }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - Profiles

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.profiles.isEmpty {
                Text("No profiles yet")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(model.profiles) { profile in
                row(profile)
            }
        }
    }

    private func row(_ profile: ServerProfile) -> some View {
        let state = model.state(of: profile.id)
        let active = model.isActive(profile.id)

        return HStack(spacing: 8) {
            StatusDot(state: state)

            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name).lineLimit(1)
                Text(profile.address)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if case .failed = state {
                // A failure is the one thing worth explaining here, because the
                // reason is otherwise only visible in the window.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(failureText(for: profile.id) ?? String(localized: "The last start failed"))
            }

            if active {
                Button {
                    Task { await model.restartServer(profile: profile) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart")

                Button {
                    Task { await model.stopServer(profileID: profile.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button {
                    Task { await model.startServer(profile: profile) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start")
            }

            if active, let url = URL(string: profile.address) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open in the browser")
            }
        }
        .padding(.vertical, 3)
    }

    private func failureText(for id: UUID) -> String? {
        if case .failed(let message) = model.state(of: id) { return message }
        return nil
    }

    // MARK: - Services

    private var services: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(.secondary).frame(width: 14)
                Text("Database")
                Spacer()
                if model.database.state == .running {
                    Button("Stop") { Task { await model.stopDatabase() } }
                        .buttonStyle(.link)
                } else {
                    Button("Start") { Task { await model.startDatabase() } }
                        .buttonStyle(.link)
                }
            }

            if model.database.state == .running {
                HStack(spacing: 8) {
                    Image(systemName: "tablecells.badge.ellipsis")
                        .foregroundStyle(.secondary).frame(width: 14)
                    Text("Admin panel")
                    Spacer()
                    Button(model.adminPanel.isRunning ? "Open" : "Start and open") {
                        Task { await model.openAdminPanel() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                show(.control)
            } label: {
                Label("Open ServerMaster", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            Button {
                show(.console)
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
            .buttonStyle(.plain)

            Button {
                AppLinks.open(.index)
            } label: {
                Label("Guides", systemImage: "book")
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit ServerMaster", systemImage: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    /// Brings the window forward on the section that answers the question that
    /// was just asked from the menu.
    private func show(_ section: SidebarSection) {
        model.section = section
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
