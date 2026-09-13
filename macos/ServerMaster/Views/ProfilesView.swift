//
//  ProfilesView.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct ProfilesView: View {

    @Environment(AppModel.self) private var model
    @State private var deleteCandidate: ServerProfile?
    @State private var showNewProfile = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScreenTitle(title: "Profiles",
                        subtitle: "^[\(model.profiles.count) profile](inflect: true), and what each one serves") {
                Button {
                    showNewProfile = true
                } label: {
                    Label("New profile", systemImage: "plus")
                }
                .modifier(GlassStyle(prominent: true))
            }
            .padding(.horizontal, 36)
            .padding(.top, 36)
            .padding(.bottom, 14)

            HSplitView {
            glassPanel(list)
                .padding(.trailing, 8)
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
                .frame(maxHeight: .infinity)

            Group {
                if let id = model.selectedProfileID,
                   let profile = model.profile(with: id) {
                    ProfileEditorView(profile: profile)
                        .id(profile.id)
                } else {
                    ContentUnavailableView("No profile selected",
                                           systemImage: "square.stack.3d.up",
                                           description: Text("Pick a profile on the left or create a new one."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(FullHeightGlass())
                }
            }
            // Without filling explicitly on both axes, both columns collapse into
            // a narrow strip in the middle of an empty window when no profile is selected.
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 8)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewProfile) {
            NewProfileSheet()
        }
        .confirmationDialog("Delete the profile “\(deleteCandidate?.name ?? "")”?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete", role: .destructive) {
                if let profile = deleteCandidate { model.deleteProfile(profile) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        }
    }

    private var list: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            List(selection: $model.selectedProfileID) {
                ForEach(model.profiles) { profile in
                    profileRow(profile)
                        .tag(profile.id)
                        .contextMenu {
                            if model.isActive(profile.id) {
                                Button("Restart") { Task { await model.restartServer(profile: profile) } }
                                Button("Stop") { Task { await model.stopServer(profileID: profile.id) } }
                                Button("Open in the browser") {
                                    if let url = URL(string: profile.address) { NSWorkspace.shared.open(url) }
                                }
                            } else {
                                Button("Start") { Task { await model.startServer(profile: profile) } }
                            }
                            Divider()
                            Button("Make the default profile") { model.makeDefault(profile) }
                            Button("Duplicate") { model.duplicateProfile(profile) }
                            Divider()
                            Button("Delete", role: .destructive) { deleteCandidate = profile }
                        }
                }
                .onMove { indices, destination in
                    model.profiles.move(fromOffsets: indices, toOffset: destination)
                    model.saveProfiles()
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)

            // No plus here. Creating a profile is the button beside the screen
            // title; two of them on one screen is two answers to the same
            // question, and the one down here was the less findable of the two.
            HStack(spacing: 6) {
                Button {
                    if let profile = model.selectedProfile { deleteCandidate = profile }
                } label: {
                    // A fixed box, or the glyphs decide the widths and the two
                    // buttons come out different sizes.
                    Image(systemName: "minus").frame(width: 16, height: 14)
                }
                .disabled(model.selectedProfile == nil)
                .help("Delete profile")

                Button {
                    if let profile = model.selectedProfile { model.duplicateProfile(profile) }
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 16, height: 14)
                }
                .disabled(model.selectedProfile == nil)
                .help("Duplicate")

                Spacer()

                Text("\(model.profiles.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .modifier(ChipStyle())
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
        .padding(15)
    }

    /// The list on glass over the moving background.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }

    private struct GlassStyle: ViewModifier {
        var prominent = false
        func body(content: Content) -> some View {
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
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass).controlSize(.small)
            } else {
                content.buttonStyle(.borderless)
            }
        }
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: profile.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(profile.name).lineLimit(1)
                    if model.settings.defaultProfileID == profile.id {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(profile.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isActive(profile.id) {
                Button {
                    Task { await model.restartServer(profile: profile) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .modifier(ChipStyle())
                .help("Restart")

                Button {
                    Task { await model.stopServer(profileID: profile.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .modifier(ChipStyle())
                .help("Stop")

                StatusDot(state: model.state(of: profile.id))
            }
        }
        .padding(.vertical, 2)
    }



    private func suggestPort() -> Int {
        let used = Set(model.profiles.map(\.port))
        var candidate = 8080
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }
}
