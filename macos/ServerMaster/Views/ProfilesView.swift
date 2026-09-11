//
//  ProfilesView.swift
//  ServerMaster
//

import SwiftUI

struct ProfilesView: View {

    @Environment(AppModel.self) private var model
    @State private var renamingID: UUID?
    @FocusState private var renameFocused: Bool
    @State private var deleteCandidate: ServerProfile?

    var body: some View {
        @Bindable var model = model

        HSplitView {
            list
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
                }
            }
            // Without filling explicitly on both axes, both columns collapse into
            // a narrow strip in the middle of an empty window when no profile is selected.
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .onTapGesture(count: 2) {
                            model.selectedProfileID = profile.id
                            renamingID = profile.id
                            renameFocused = true
                        }
                        .contextMenu {
                            Button("Rename") {
                                model.selectedProfileID = profile.id
                                renamingID = profile.id
                                renameFocused = true
                            }
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

            Divider()

            HStack(spacing: 6) {
                Menu {
                    ForEach(ProfilePreset.all) { preset in
                        Button {
                            create(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.symbol)
                        }
                    }
                    Divider()
                    Button("Empty profile") { create(nil) }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    // A plain click still gives the commonest case rather than a
                    // menu: most people are serving a folder of files.
                    create(ProfilePreset.all.first)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .help("New profile — hold to choose what you are serving")

                Button {
                    if let profile = model.selectedProfile { deleteCandidate = profile }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.selectedProfile == nil)
                .help("Delete profile")

                Button {
                    if let profile = model.selectedProfile { model.duplicateProfile(profile) }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(model.selectedProfile == nil)
                .help("Duplicate")

                Spacer()

                Text("\(model.profiles.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func profileRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: profile.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if renamingID == profile.id {
                        TextField("", text: Binding(
                            get: { model.profile(with: profile.id)?.name ?? "" },
                            set: { newName in
                                guard var updated = model.profile(with: profile.id) else { return }
                                updated.name = newName
                                model.updateProfile(updated)
                            }))
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit { finishRenaming() }
                        .onExitCommand { finishRenaming() }
                    } else {
                        Text(profile.name).lineLimit(1)
                    }
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
                StatusDot(state: model.state(of: profile.id))
            }
        }
        .padding(.vertical, 2)
    }

    private func finishRenaming() {
        // An empty name must not be left — put something meaningful back.
        if let id = renamingID, var profile = model.profile(with: id),
           profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.name = String(localized: "Untitled")
            model.updateProfile(profile)
        }
        renamingID = nil
        renameFocused = false
        model.flushPendingSaves()
    }

    /// Creates a profile from a preset, or an empty one when none is given.
    private func create(_ preset: ProfilePreset?) {
        let number = model.profiles.count + 1
        var profile: ServerProfile
        if let preset {
            profile = preset.makeProfile(name: preset.title, port: suggestPort())
            // Two profiles from the same preset would otherwise share a name.
            if model.profiles.contains(where: { $0.name == profile.name }) {
                profile.name = "\(preset.title) \(String(number))"
            }
        } else {
            profile = ServerProfile()
            profile.name = "Profile \(String(number))"
            profile.port = suggestPort()
        }
        model.addProfile(profile)
        renamingID = profile.id
        renameFocused = true
    }

    private func suggestPort() -> Int {
        let used = Set(model.profiles.map(\.port))
        var candidate = 8080
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }
}
