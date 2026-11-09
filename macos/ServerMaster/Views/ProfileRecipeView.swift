import SwiftUI

struct ProfileRecipeView: View {
    let profile: ServerProfile
    @Environment(AppModel.self) private var model
    @State private var showLog = true

    private var operation: RecipePreparation? { model.recipePreparations[profile.id] }
    private var phase: RecipePreparation.Phase { operation?.phase ?? .idle }
    private var actionTitle: String {
        switch phase {
        case .failed: return String(localized: "Retry preparation")
        case .ready: return String(localized: "Prepare again")
        default: return String(localized: "Prepare project")
        }
    }

    var body: some View {
        if let template = model.recipeTemplate(for: profile) {
            Card("Project setup", systemImage: "wrench.and.screwdriver") {
                switch phase {
                case .idle:
                    Text("Prepare the existing project, or resume an interrupted setup. No second profile or project download is created.")
                        .font(.caption).foregroundStyle(.secondary)
                case .preparing(let step):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(step.title).font(.callout)
                    }
                case .ready:
                    Label("Project is prepared.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label("Project preparation failed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(actionTitle) {
                        Task { await model.prepareProjectRecipe(template, profileID: profile.id) }
                    }
                    .disabled(model.isPreparingProjects || model.isActive(profile.id)
                        || model.existingController(for: profile.id)?.processIdentifier != nil
                        || model.backupOperationInProgress || model.isShuttingDown || model.stoppingAll
                        || model.dependencies.isManagingPackages || model.dependencies.isChecking)
                    if case .failed = phase {
                        Text("Fix the reported problem, then retry this profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let operation {
                    DisclosureGroup("Preparation log", isExpanded: $showLog) {
                        LogOutputView(log: operation.log, fontSize: 11)
                            .frame(height: 180)
                    }
                }
            }
        }
    }
}
