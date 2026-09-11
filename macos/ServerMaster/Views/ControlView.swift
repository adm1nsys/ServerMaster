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

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                SectionHeader(title: "Control",
                              subtitle: model.activeCount == 0
                                        ? "Start profiles — several at once if you like"
                                        : "Servers running: \(model.activeCount)") {
                    HStack(spacing: 8) {
                        if model.activeCount > 0 {
                            Button {
                                Task { await model.stopAll() }
                            } label: {
                                Label("Stop all", systemImage: "stop.circle")
                            }
                        }
                        Button {
                            model.section = .console
                        } label: {
                            Label("Console", systemImage: "terminal")
                        }
                    }
                }

                serverList

                if let profile = model.selectedProfile {
                    issuesCard(for: profile)
                    detailsCard(for: profile)
                }
            }
            .padding(20)
            .frame(maxWidth: 940, alignment: .leading)
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

    // MARK: - Profile list

    private var serverList: some View {
        GroupBox {
            VStack(spacing: 0) {
                if model.profiles.isEmpty {
                    HStack {
                        Text("No profiles yet.")
                            .foregroundStyle(.secondary)
                        Button("Create") { model.section = .profiles }
                            .buttonStyle(.link)
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
            .padding(4)
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
                Button {
                    controller?.openInBrowser()
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open in browser")
            }

            Button {
                model.selectedProfileID = profile.id
                model.section = .console
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Show log")
            .disabled(controller == nil)

            if state.isBusy {
                ProgressView().controlSize(.small).frame(width: 74)
            } else if state.isActive {
                Button {
                    if model.settings.confirmBeforeStop {
                        stopCandidate = profile
                    } else {
                        Task { await model.stopServer(profileID: profile.id) }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(width: 56)
                }
            } else {
                Button {
                    Task { await model.startServer(profile: profile) }
                } label: {
                    Label("Start", systemImage: "play.fill").frame(width: 56)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
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

    @ViewBuilder
    private func issuesCard(for profile: ServerProfile) -> some View {
        let issues = profile.validationIssues
        let missing = model.dependencies.missingTools(for: profile.engine)
        let state = model.state(of: profile.id)
        let failure: String? = { if case .failed(let m) = state { return m }; return nil }()

        if failure != nil || !issues.isEmpty || !missing.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        Label("The last start failed", systemImage: "xmark.octagon.fill")
                            .font(.callout).fontWeight(.medium)
                            .foregroundStyle(.red)
                        Text(failure)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if profile.port < 1024, !profile.runAsAdministrator {
                            HStack(spacing: 12) {
                                if let replacement = PortPresets.localReplacement(for: profile.port) {
                                    Button("Switch the port to \(String(replacement))") {
                                        var updated = profile
                                        updated.port = replacement
                                        model.updateProfile(updated)
                                        model.notify("Port of the “\(profile.name)” profile changed to \(String(replacement)).")
                                    }
                                    .buttonStyle(.link)
                                }
                                Button("Start with administrator rights") {
                                    var updated = profile
                                    updated.runAsAdministrator = true
                                    model.updateProfile(updated)
                                    Task { await model.startServer(profile: updated) }
                                }
                                .buttonStyle(.link)
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
                            Button("To dependencies") { model.section = .dependencies }
                                .buttonStyle(.link)
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
                .padding(6)
            }
        }
    }

    // MARK: - Details of the selected profile

    private func detailsCard(for profile: ServerProfile) -> some View {
        let controller = model.existingController(for: profile.id)

        return GroupBox {
            VStack(alignment: .leading, spacing: 0) {
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
                                    Button("Open") { controller?.openInBrowser(url) }
                                        .buttonStyle(.link)
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                    }
                                    .buttonStyle(.link)
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
            .padding(6)
        } label: {
            HStack {
                Label(profile.name, systemImage: profile.symbol)
                Spacer()
                Button("Configure") { model.section = .profiles }
                    .buttonStyle(.link)
            }
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
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 6)
    }
}
