import SwiftUI

struct ProfileRequirementsView: View {
    let profile: ServerProfile
    var template: ProfileTemplate? = nil
    @Environment(AppModel.self) private var model
    @State private var installing = false
    @State private var problem: String?

    private var missing: [ProfileRequirement] {
        model.dependencies.missingRequirements(for: profile,
            template: template ?? model.templates.all.first { $0.id == profile.templateId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.dependencies.isChecking || installing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(installing ? String(localized: "Installing missing software…") : String(localized: "Checking requirements…"))
                        .font(.caption)
                }
            } else if !missing.isEmpty {
                Label("Not installed: \(missing.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install missing software") {
                        installing = true
                        problem = nil
                        Task {
                            defer { installing = false }
                            do { try await model.installMissingRequirements(for: profile, template: template) }
                            catch { problem = error.localizedDescription }
                        }
                    }
                    .disabled(model.dependencies.isManagingPackages || !model.runtimeChangesAllowed)
                    Button("Open dependencies") { model.section = .dependencies }
                }
                .controlSize(.small)
                if !model.runtimeChangesAllowed {
                    Text("Stop servers and the database before changing packages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("All required software is installed.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if model.dependencies.lastCheck == nil { await model.dependencies.checkAll() } }
    }
}
