//
//  DomainTrace.swift
//  ServerMaster
//
//  Following a profile's address from the name to the socket.
//
//  “It works in one browser and not another”, “it used to open and now it does
//  not”, “my colleague sees the old site” — all of these are one question with
//  several places to lose it: the hosts file, the resolver, the route, whether
//  anything is listening, and what answers when you ask.
//
//  Each step is run separately and reported separately, because the useful
//  answer is which step is the one that changed.
//

import Foundation

nonisolated struct TraceStep: Identifiable, Sendable {
    enum Outcome: Sendable { case ok, warning, failed, skipped }

    var id: String
    var title: String
    var detail: String
    var outcome: Outcome
    var elapsed: TimeInterval?
}

@Observable
final class DomainTrace {

    private(set) var steps: [TraceStep] = []
    private(set) var isRunning = false
    private(set) var subject: String = ""

    /// Traces one profile's own address. Each profile is traced on its own — two
    /// profiles on the same host and different ports fail in different places,
    /// and a single result for “the machine” would hide that.
    func run(for profile: ServerProfile) async {
        guard !isRunning else { return }
        isRunning = true
        subject = profile.address
        steps = []
        defer { isRunning = false }

        let host = profile.host.isEmpty ? "127.0.0.1" : profile.host
        let port = profile.port

        add(await hostsFile(host))
        add(await resolve(host))
        add(await ping(host))
        add(await listening(port: port, host: host))
        add(await request(profile))
        add(await certificate(profile))
    }

    private func add(_ step: TraceStep?) {
        guard let step else { return }
        steps.append(step)
    }

    // MARK: - The steps

    /// A stale line in /etc/hosts outlives every other kind of fix, and nothing
    /// in a browser will ever mention it.
    private func hostsFile(_ host: String) async -> TraceStep? {
        guard !isNumeric(host) else { return nil }
        guard let text = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            return TraceStep(id: "hosts", title: String(localized: "Hosts file"),
                             detail: String(localized: "/etc/hosts could not be read."),
                             outcome: .warning)
        }
        let matches = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && $0.split(whereSeparator: \.isWhitespace).dropFirst().contains(Substring(host)) }

        if matches.isEmpty {
            return TraceStep(id: "hosts", title: String(localized: "Hosts file"),
                             detail: String(localized: "No entry for \(host) — the name is resolved normally."),
                             outcome: .ok)
        }
        return TraceStep(id: "hosts", title: String(localized: "Hosts file"),
                         detail: matches.joined(separator: "\n"),
                         outcome: matches.count > 1 ? .warning : .ok)
    }

    private func resolve(_ host: String) async -> TraceStep {
        if isNumeric(host) {
            return TraceStep(id: "dns", title: String(localized: "Name"),
                             detail: String(localized: "\(host) is an address already — nothing to resolve."),
                             outcome: .ok)
        }
        let started = Date()
        let result = await ProcessRunner.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 10)
        let addresses = result.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("ip_address:") || $0.hasPrefix("ipv6_address:") }
            .map { $0.replacingOccurrences(of: "ip_address: ", with: "")
                     .replacingOccurrences(of: "ipv6_address: ", with: "") }

        guard !addresses.isEmpty else {
            return TraceStep(id: "dns", title: String(localized: "Name"),
                             detail: String(localized: "\(host) does not resolve to anything."),
                             outcome: .failed, elapsed: Date().timeIntervalSince(started))
        }
        return TraceStep(id: "dns", title: String(localized: "Name"),
                         detail: addresses.joined(separator: ", "),
                         outcome: .ok, elapsed: Date().timeIntervalSince(started))
    }

    private func ping(_ host: String) async -> TraceStep {
        let started = Date()
        let result = await ProcessRunner.run("/sbin/ping", ["-c", "1", "-t", "2", host], timeout: 8)
        let reachable = result.stdout.contains("bytes from")
        return TraceStep(id: "ping", title: String(localized: "Reachable"),
                         detail: reachable
                            ? String(localized: "\(host) answers.")
                            : String(localized: "No answer from \(host). On a local address this is usually a firewall."),
                         outcome: reachable ? .ok : .warning,
                         elapsed: Date().timeIntervalSince(started))
    }

    /// Whether anything holds the port, and whether it is ours. A port held by
    /// something else is the difference between “not started” and “started, and
    /// you are looking at another program's answer”.
    private func listening(port: Int, host: String) async -> TraceStep {
        let result = await ProcessRunner.run("/usr/sbin/lsof",
                                             ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"], timeout: 10)
        let lines = result.stdout.split(separator: "\n").dropFirst()
        guard let first = lines.first else {
            return TraceStep(id: "port", title: String(localized: "Port \(String(port))"),
                             detail: String(localized: "Nothing is listening."),
                             outcome: .failed)
        }
        let fields = first.split(whereSeparator: \.isWhitespace)
        let command = fields.first.map(String.init) ?? "?"
        let pid = fields.count > 1 ? String(fields[1]) : "?"
        return TraceStep(id: "port", title: String(localized: "Port \(String(port))"),
                         detail: String(localized: "\(command) (pid \(pid)) is listening."),
                         outcome: .ok)
    }

    /// What actually comes back. A 200 from the wrong server is still a 200, so
    /// the Server header is reported alongside it.
    func request(_ profile: ServerProfile) async -> TraceStep {
        let response = await HealthCheck.check(profile)
        return TraceStep(id: "http", title: String(localized: "Request"), detail: response.summary,
            outcome: response.status == nil ? .failed : response.isGood ? .ok : .warning, elapsed: response.elapsed)
    }

    func certificate(_ profile: ServerProfile) async -> TraceStep? {
        guard profile.httpsEnabled, profile.engine.supportsHTTPS else { return nil }
        let result = TLSValidation.check(profile)
        return TraceStep(id: "tls", title: String(localized: "Certificate"),
            detail: result.issues.isEmpty ? String(localized: "Certificate and key match; validity dates and host SAN are valid.") : result.issues.joined(separator: "\n"),
            outcome: result.issues.isEmpty ? .ok : .failed)
    }

    private func isNumeric(_ host: String) -> Bool {
        host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }
}
