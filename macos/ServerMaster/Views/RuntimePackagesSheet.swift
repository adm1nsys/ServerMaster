import SwiftUI
import AppKit

struct RuntimePackagesSheet: View {
    let dependency: Dependency
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var package: RuntimePackages.Package?
    @State private var versions: [String] = []
    @State private var selected = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var resultMessage: String?
    @State private var confirmingRemoval = false

    private var manager: RuntimePackages { model.dependencies.runtimePackages }
    private var running: Bool {
        !model.runtimeChangesAllowed
    }
    private var blocked: Bool { busy || model.dependencies.isManagingPackages || model.dependencies.isChecking || running }

    var body: some View {
        if ["node", "npm"].contains(dependency.command) {
            NodeReleasesSheet()
        } else {
            packageBody
        }
    }

    private var packageBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(dependency.title).font(.title2).fontWeight(.semibold)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.disabled(busy)
            }
            if let package {
                Text(package.formula).font(.system(.body, design: .monospaced))
                LabeledContent("Installed", value: package.installed.isEmpty ? String(localized: "Not installed") : package.installed.joined(separator: ", "))
                LabeledContent("Available", value: package.latest)
                if let path = package.activePath {
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if package.activePath != nil && !package.isManaged {
                    Text("The active executable is outside this package manager. It has not been changed.")
                        .font(.caption).foregroundStyle(.orange)
                } else if !package.installed.isEmpty {
                    Label(package.outdated ? "Update available" : "Up to date", systemImage: package.outdated ? "arrow.down.circle" : "checkmark.circle")
                }
                let phpUsers = model.dependencies.profilesUsingPHP(formula: package.formula, profiles: model.profiles)
                if !phpUsers.isEmpty {
                    Text("Used by: \(phpUsers.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for updates") { Task { await refresh() } }.disabled(busy || model.dependencies.isManagingPackages)
                    if package.installed.isEmpty {
                        Button("Install") { perform(.install) }.disabled(blocked || package.activePath != nil && !package.isManaged)
                    } else {
                        Button("Update") { perform(.update) }.disabled(blocked || !package.isManaged || !package.outdated)
                        Button("Remove", role: .destructive) { confirmingRemoval = true }.disabled(blocked || !package.isManaged || !phpUsers.isEmpty)
                    }
                }
                if !versions.isEmpty {
                    Divider()
                    Picker("Version", selection: $selected) {
                        ForEach(versions, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(blocked)
                    Button(dependency.command == "http-server" ? "Install selected version" : "Install and use selected Node") {
                        perform(.install, version: selected)
                    }
                    .disabled(blocked || selected.isEmpty)
                    Text(dependency.command == "http-server"
                         ? "The selected http-server version replaces the global npm package."
                         : "Node versions offered by Homebrew can coexist. The selected version is used by ServerMaster through PATH; other applications keep their own settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !busy {
                Button("Retry") { Task { await refresh() } }.disabled(blocked)
            }
            if running {
                Text("Stop servers and the database before changing packages.").foregroundStyle(.orange)
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if let resultMessage { Text(resultMessage).foregroundStyle(.secondary).textSelection(.enabled) }
            if busy { Text("Package operations can take several minutes.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24)
        .frame(width: 590)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(busy)
        .task { await refresh() }
        .confirmationDialog("Remove this package?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { perform(.remove) }
        } message: {
            Text("Other projects may use this package. Homebrew dependency checks remain enabled.")
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        problem = nil
        do {
            package = try await manager.inspect(command: dependency.command)
            if ["node", "npm", "http-server"].contains(dependency.command) {
                do {
                    versions = try await manager.versions(command: dependency.command)
                    if !versions.contains(selected) { selected = versions.first ?? "" }
                } catch {
                    versions = []
                    problem = error.localizedDescription
                }
            }
        } catch { problem = error.localizedDescription }
    }

    private func perform(_ action: RuntimePackages.Action, version: String? = nil) {
        guard !blocked else { return }
        busy = true
        problem = nil
        resultMessage = nil
        Task {
            defer { busy = false }
            let oldPaths = model.settings.extraPATHEntries
            do {
                try await model.dependencies.managePackages {
                    guard !running else {
                        throw RuntimePackages.Failure(message: String(localized: "Stop servers and the database before changing packages."))
                    }
                    let selectedBin = try await manager.perform(command: dependency.command, action: action,
                                                                selectedVersion: version, log: model.installLog, beforeRemoval: { package in
                        try model.dependencies.checkPHPRemoval(formula: package.formula, profiles: model.profiles)
                    })
                    if let selectedBin {
                        model.settings.extraPATHEntries.removeAll { $0.range(of: #"/opt/node(?:@[0-9]+)?/bin$"#, options: .regularExpression) != nil || $0 == selectedBin }
                        model.settings.extraPATHEntries.insert(selectedBin, at: 0)
                        model.saveSettings()
                        let active = ShellEnvironment.shared.which("node")
                        guard active.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == URL(fileURLWithPath: selectedBin + "/node").resolvingSymlinksInPath().path else {
                            model.settings.extraPATHEntries = oldPaths
                            model.saveSettings()
                            throw RuntimePackages.Failure(message: String(localized: "The requested Node version was not activated."))
                        }
                    } else if action == .remove, let package {
                        model.settings.extraPATHEntries.removeAll { $0 == package.prefix + "/bin" }
                        model.saveSettings()
                    }
                }
                await model.dependencies.checkAll()
                package = try await manager.inspect(command: dependency.command)
                resultMessage = String(localized: "Package operation completed. The detected version and path have been refreshed.")
            } catch {
                problem = error.localizedDescription
                await model.dependencies.checkAll()
            }
        }
    }
}
