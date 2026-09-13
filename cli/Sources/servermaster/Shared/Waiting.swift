//
//  Waiting.swift
//  ServerMaster
//
//  What to say while something slow is happening.
//
//  The line changes with how long it has been running, which makes it useful as
//  well as friendly: a glance tells you whether this is a two-second job or one
//  that has been going for a minute. A spinner alone cannot say that.
//
//  The tone is deliberate. This app exists so nobody has to unpack an archive by
//  hand, write a vhost, create a user and grant it rights, one command at a
//  time — and having got all of that out of the way, suggesting a coffee is a
//  fair thing to do with the time it gave back. It is also faintly ridiculous,
//  which is the point.
//

import Foundation

nonisolated enum Waiting {

    /// What is being waited on, because the joke lands differently depending on
    /// whether files are being copied or a site is being put back.
    enum Job: Sendable {
        case snapshot
        case restore
        case download
        case database
    }

    /// The line for a job that has been running this long.
    ///
    /// Four bands. Under five seconds it just says what is happening — a quip
    /// that appears and vanishes before it is read is only noise. After that the
    /// suggestions get progressively less reasonable.
    static func line(for job: Job, elapsed: TimeInterval) -> String {
        let band = min(3, Int(elapsed) / 15)
        switch job {
        case .snapshot:  return snapshot[band]
        case .restore:   return restore[band]
        case .download:  return download[band]
        case .database:  return database[band]
        }
    }

    private static let snapshot = [
        String(localized: "Copying. This is the part you would otherwise be doing by hand."),
        String(localized: "Still copying. Now would be a reasonable time to put the kettle on."),
        String(localized: "A large site, then. The coffee suggestion stands, and is upgraded to a proper one."),
        String(localized: "This is going to be a while. Go outside. The files will still be here.")
    ]

    private static let restore = [
        String(localized: "Putting it back. Nothing is overwritten until the whole copy is in place."),
        String(localized: "Still going. Undoing an afternoon takes a moment; it used to take the evening."),
        String(localized: "Unpacking properly. Coffee, if you have not already."),
        String(localized: "Long one. Whatever you broke, you broke it thoroughly. Admirable.")
    ]

    private static let download = [
        String(localized: "Fetching from the official release."),
        String(localized: "Downloading. Somebody once did this with a browser and a zip on the desktop."),
        String(localized: "Still coming down. Kettle."),
        String(localized: "Slow connection, big project. This is the moment the coffee pays for itself.")
    ]

    private static let database = [
        String(localized: "Working on the database."),
        String(localized: "Still working. Dumps take as long as the data is big."),
        String(localized: "A real database, then. Tea is also acceptable."),
        String(localized: "Nothing has gone wrong — a big dump is just a big dump. Take the break.")
    ]
}

/// Ticks once a second so a view can ask `Waiting.line(for:elapsed:)` and have
/// it change on its own.
///
/// One timer per waiting view rather than a global one: two things can be slow
/// at the same time, and they did not start together.
@Observable
final class WaitingClock {

    private(set) var elapsed: TimeInterval = 0
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        elapsed = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run { self.elapsed += 1 }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        elapsed = 0
    }

    deinit { task?.cancel() }
}
