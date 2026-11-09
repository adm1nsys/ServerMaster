import Foundation
import Observation

/// The wizard never starts a server as a delayed side effect of preparation.
/// A successful preparation enables a separate, explicit Start action.
@Observable
final class NewProfilePreparation {
    enum Phase: Equatable {
        case idle, preparing, ready, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var profileID: UUID?
    private(set) var isStarting = false
    private(set) var startFailure: String?
    var canStart: Bool { phase == .ready && !isStarting }

    func prepare(profileID: UUID, template: ProfileTemplate, databaseName: String?,
                 password: String?, using model: AppModel) async {
        guard phase != .preparing, !isStarting else { return }
        self.profileID = profileID
        phase = .preparing
        guard let profile = model.profile(with: profileID), !Task.isCancelled, !model.isShuttingDown else {
            phase = .failed(String(localized: "Profile setup was cancelled. No server was started."))
            return
        }
        if password == "" {
            phase = .failed(String(localized: "Enter a database password or generate one."))
            return
        }
        let succeeded: Bool
        if RecipePreparation.supports(template) {
            succeeded = await model.prepareProjectRecipe(template, profileID: profileID, databasePassword: password)
        } else if let databaseName, profile.needsDatabase {
            succeeded = await model.prepareDatabase(named: databaseName, for: profile, password: password)
        } else {
            succeeded = true
        }
        guard !Task.isCancelled, !model.isShuttingDown, model.profile(with: profileID) != nil else {
            phase = .failed(String(localized: "Profile setup was cancelled. No server was started."))
            return
        }
        if succeeded { phase = .ready }
        else if let recipe = model.recipePreparations[profileID], case .failed(let message) = recipe.phase {
            phase = .failed(message)
        } else {
            phase = .failed(model.banner?.text ?? String(localized: "Profile saved, but preparation did not finish. Open its profile to retry."))
        }
    }

    @discardableResult
    func start(using model: AppModel) async -> Bool {
        guard canStart, !Task.isCancelled, let profile = model.profile(with: profileID) else { return false }
        isStarting = true
        startFailure = nil
        defer { isStarting = false }
        // Use the saved profile after the recipe has updated its database name.
        // The normal launch path owns readiness and browser preferences.
        await model.startServer(profile: profile)
        let succeeded = model.state(of: profile.id) == .running
        if !succeeded {
            if case .failed(let message) = model.state(of: profile.id) { startFailure = message }
            else { startFailure = model.banner?.text ?? String(localized: "The server did not start. Check its profile and console, then retry.") }
        }
        return succeeded
    }
}
