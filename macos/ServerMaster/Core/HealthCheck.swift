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

    private static func check(_ profile: ServerProfile) async -> HealthResult {
        guard let url = URL(string: profile.address) else {
            return HealthResult(id: profile.id, name: profile.name, address: profile.address,
                                status: nil, elapsed: 0, server: nil,
                                problem: String(localized: "the address cannot be read"))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // HEAD would be lighter, and plenty of PHP sites answer it with a 501.
        request.httpMethod = "GET"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        // A self-signed certificate is the normal case for a local site, and
        // refusing to look at it would make this check useless exactly where it
        // is needed. Only ever aimed at an address the person configured.
        let session = URLSession(configuration: configuration,
                                 delegate: LocallyTrusting(), delegateQueue: nil)

        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            guard let http = response as? HTTPURLResponse else {
                return HealthResult(id: profile.id, name: profile.name, address: profile.address,
                                    status: nil, elapsed: elapsed, server: nil,
                                    problem: String(localized: "answered, but not with HTTP"))
            }
            return HealthResult(id: profile.id, name: profile.name, address: profile.address,
                                status: http.statusCode, elapsed: elapsed,
                                server: http.value(forHTTPHeaderField: "Server"), problem: nil)
        } catch {
            return HealthResult(id: profile.id, name: profile.name, address: profile.address,
                                status: nil, elapsed: Date().timeIntervalSince(started),
                                server: nil,
                                problem: (error as NSError).localizedDescription)
        }
    }
}

/// Accepts the certificate a local server presents, self-signed included.
private final class LocallyTrusting: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
