import SwiftUI

struct NodeReleasesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var catalogue: [NodeReleases.Release] = []
    @State private var copies: [NodeReleases.Release] = []
    @State private var selected = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var message: String?
    @State private var confirmingRemoval = false

    private var manager: NodeReleases { model.dependencies.nodeReleases }
    private var blocked: Bool {
        busy || model.dependencies.isManagingPackages || model.dependencies.isChecking || !model.runtimeChangesAllowed
    }
    private var versions: [String] {
        Set(catalogue.map(\.version) + copies.map(\.version)).sorted {
            $0.compare($1, options: .numeric) == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Node.js & npm").font(.title2).fontWeight(.semibold)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.disabled(busy)
            }
            LabeledContent("Active", value: model.settings.managedNodeVersion.isEmpty ? "System" : model.settings.managedNodeVersion)
            if let path = ShellEnvironment.shared.which("node") {
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else {
                Text("The selected Node executable is unavailable.").foregroundStyle(.orange)
            }
            Text("Official Node releases are stored separately inside ServerMaster. Each release includes its own npm. System restores your existing PATH without deleting installed versions.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Use System") { use("System") }
                .disabled(blocked || model.settings.managedNodeVersion.isEmpty)
            Divider()
            if !versions.isEmpty {
                Picker("Version", selection: $selected) {
                    ForEach(versions, id: \.self) { version in
                        Text(copies.contains { $0.version == version } ? "\(version) · \(String(localized: "Installed"))" : version).tag(version)
                    }
                }
                .disabled(blocked)
                HStack {
                    Button(copies.contains { $0.version == selected } ? "Use selected Node" : "Install and use selected Node") { use(selected) }
                        .disabled(blocked || selected.isEmpty || selected == model.settings.managedNodeVersion)
                    Button("Remove selected copy", role: .destructive) { confirmingRemoval = true }
                        .disabled(blocked || selected == model.settings.managedNodeVersion || !copies.contains { $0.version == selected })
                }
            }
            Button("Refresh version list") { Task { await refresh() } }.disabled(busy || model.dependencies.isManagingPackages)
            if !model.runtimeChangesAllowed {
                Text("Stop servers and the database before changing packages.").foregroundStyle(.orange)
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).foregroundStyle(.secondary) }
            if busy { Text("Package operations can take several minutes.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(busy)
        .task { await refresh() }
        .confirmationDialog("Remove selected Node copy?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Only this inactive ServerMaster copy will be removed. Homebrew and System Node are not changed.")
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        problem = nil
        copies = manager.installed()
        do { catalogue = try await manager.versions() }
        catch { problem = error.localizedDescription }
        if !versions.contains(selected) {
            selected = versions.contains(model.settings.managedNodeVersion) ? model.settings.managedNodeVersion : versions.first ?? ""
        }
    }

    private func use(_ version: String) {
        guard !blocked else { return }
        busy = true
        problem = nil
        message = nil
        Task {
            defer { busy = false }
            do {
                try await model.selectNodeRelease(version)
                copies = manager.installed()
                message = String(localized: "Node selection saved. Future server starts use the selected runtime.")
            } catch { problem = error.localizedDescription }
            await model.dependencies.checkAll()
        }
    }

    private func remove() {
        guard !blocked else { return }
        busy = true
        problem = nil
        message = nil
        let version = selected
        Task {
            defer { busy = false }
            do {
                try await model.removeNodeRelease(version)
                copies = manager.installed()
                message = String(localized: "The unused Node copy was removed.")
            } catch { problem = error.localizedDescription }
            await model.dependencies.checkAll()
        }
    }
}
