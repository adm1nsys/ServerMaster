import Foundation

nonisolated struct StartupBudget {
    private let deadline: ContinuousClock.Instant
    init(seconds: TimeInterval = 8) {
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
    }
    func remaining(upTo maximum: TimeInterval) -> TimeInterval {
        let parts = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(0, min(maximum, seconds))
    }
}

/// One background operation, bounded foreground waiting. A timed-out check is
/// still owned here, so later callers join it rather than launch a duplicate.
@MainActor
final class StartupWork {
    enum WaitResult: Equatable { case finished, timedOut, cancelled }
    private var task: Task<Void, Never>?
    private(set) var finished = false

    func run(wait seconds: TimeInterval, operation: @escaping @MainActor () async -> Void) async -> WaitResult {
        if task == nil {
            task = Task { @MainActor in
                await operation()
                self.finished = true
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
        while !finished && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if finished { return .finished }
        return Task.isCancelled ? .cancelled : .timedOut
    }
}
