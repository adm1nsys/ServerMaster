//
//  HealthCheck.swift
//  ServerMaster
//
//  Asking every running server whether it is actually answering.
//
//  “Running” in this app means the process is alive and the port is held. That
//  is not the same as the site working: a PHP fatal error, a missing document
//  root, a config that loads but serves nothing — all of those leave a perfectly
//  healthy process behind a broken site. This is the difference between the two.
//
//  One request each, in parallel, with a short deadline. It is a check, not a
//  crawl: the first response tells you what you need, and waiting thirty seconds
//  for a server that is clearly not answering helps nobody.
//

import Foundation

nonisolated struct HealthResult: Identifiable, Sendable {
    var id: UUID                 // the profile's
    var name: String
    var address: String
    var status: Int?             // nil when nothing answered
    var elapsed: TimeInterval
    var server: String?
    var problem: String?

    var isGood: Bool {
        guard let status else { return false }
        return (200..<400).contains(status)
    }

    var summary: String {
        if let problem { return problem }
        guard let status else { return String(localized: "no answer") }
        let time = "\(Int(elapsed * 1000)) ms"
        guard let server, !server.isEmpty else { return "\(status) · \(time)" }
        return "\(status) · \(server) · \(time)"
    }
}

@Observable
final class HealthCheck {

    private(set) var results: [HealthResult] = []
    private(set) var isRunning = false
    private(set) var lastRun: Date?

    var hasResults: Bool { !results.isEmpty }
    var failures: Int { results.filter { !$0.isGood }.count }

    func clear() {
        results = []
        lastRun = nil
    }

    /// Checks the given profiles at once rather than one after another. Five
    /// sites checked in sequence is five timeouts long in the bad case.
    func run(_ profiles: [ServerProfile]) async {
        guard !isRunning else { return }
        guard !profiles.isEmpty else {
            results = []
            return
        }
        isRunning = true
        defer { isRunning = false; lastRun = Date() }

        let collected = await withTaskGroup(of: HealthResult.self) { group in
            for profile in profiles {
                group.addTask { await Self.check(profile) }
            }
            var out: [HealthResult] = []
            for await result in group { out.append(result) }
            return out
        }
        // Back into the order the profiles are shown in, so the list does not
        // reshuffle itself according to which server answered first.
        let order = Dictionary(uniqueKeysWithValues: profiles.enumerated().map { ($1.id, $0) })
        results = collected.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }
    }

    static func check(_ profile: ServerProfile) async -> HealthResult {
        guard let url = HTTPStartup.address(for: profile) else {
            return HealthResult(id: profile.id, name: profile.name, address: profile.address,
                status: nil, elapsed: 0, server: nil, problem: String(localized: "the address cannot be read"))
        }
        let started = Date()
        let response = await HTTPStartup.inspect(url: url,
            certificatePath: profile.scheme == "https" ? profile.certificatePath : nil, timeout: 6)
        return HealthResult(id: profile.id, name: profile.name, address: profile.address,
            status: response.status, elapsed: Date().timeIntervalSince(started),
            server: response.server, problem: response.problem)
    }
}
