import Foundation
import Observation

@Observable
final class RecipePreparation {
    enum Phase: Equatable {
        case idle
        case preparing(WebToPrintRecipe.Step)
        case ready
        case failed(String)
    }

    typealias Runner = @MainActor (ProfileTemplate, ServerProfile, DatabaseService, ConsoleLog, WebToPrintRecipe.Runtime) async throws -> WebToPrintRecipe.Outcome

    private(set) var phase: Phase = .idle
    private(set) var template: ProfileTemplate
    let log = ConsoleLog()
    var isWorking: Bool { if case .preparing = phase { return true }; return false }

    init(template: ProfileTemplate) { self.template = template }

    func begin(template: ProfileTemplate) {
        self.template = template
        phase = .preparing(.checking)
        log.system(String(localized: "──────── Project preparation ────────"))
    }

    func advance(_ step: WebToPrintRecipe.Step) {
        guard isWorking else { return }
        phase = .preparing(step)
        log.system(step.title)
    }

    func finish() { phase = .ready }
    func fail(_ message: String) {
        phase = .failed(message)
        log.append(message, stream: .stderr)
    }

    static func supports(_ template: ProfileTemplate) -> Bool {
        ["wordpress-w2p", "printshopcrm"].contains(template.packageKind)
    }
}
