//
//  PortScanner.swift
//  ServerMaster
//
//  Parsing lsof output in machine format (-F), because process names
//  can contain spaces and column parsing breaks on them.
//

import Foundation

nonisolated struct PortEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(String(pid))-\(proto)-\(address)-\(String(port))" }

    var pid: Int32
    var command: String
    var user: String
    var proto: String        // TCP / UDP
    var family: String       // IPv4 / IPv6
    var address: String      // 127.0.0.1, *, ::1
    var port: Int

    var isSystemProcess: Bool {
        user == "root" || user == "_windowserver" || user.hasPrefix("_")
    }

    var displayAddress: String {
        address == "*" ? String(localized: "all interfaces") : address
    }

    var localURL: URL? {
        guard proto == "TCP" else { return nil }
        let host = (address == "*" || address == "::" ) ? "127.0.0.1" : address
        return URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(String(port))")
    }
}

nonisolated enum PortScanner {

    /// Every listening TCP socket (and optionally UDP).
    static func scan(includeUDP: Bool) async -> [PortEntry] {
        async let tcp = runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iTCP", "-sTCP:LISTEN"], proto: "TCP")
        if includeUDP {
            async let udp = runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iUDP"], proto: "UDP")
            let combined = await tcp + udp
            return dedupe(combined)
        }
        return dedupe(await tcp)
    }

    /// Who is listening on a specific port.
    static func processesListening(onPort port: Int) async -> [PortEntry] {
        let entries = await runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iTCP:\(String(port))", "-sTCP:LISTEN"], proto: "TCP")
        return dedupe(entries.filter { $0.port == port })
    }

    /// Whether the port is free (by trying to take it ourselves).
    ///
    /// Both the requested address and the wildcard are checked: with SO_REUSEADDR a
    /// bind to 127.0.0.1 succeeds even when someone is already listening on 0.0.0.0
    /// on the same port, so one check is not enough.
    static func isPortFree(_ port: Int, host: String) -> Bool {
        guard port > 0, port < 65536 else { return false }
        return canBind(port: port, address: resolve(host)) && canBind(port: port, address: INADDR_ANY)
    }

    private static func resolve(_ host: String) -> in_addr_t {
        switch host {
        case "0.0.0.0", "":
            return INADDR_ANY
        case "localhost":
            return inet_addr("127.0.0.1")
        default:
            let resolved = inet_addr(host)
            // Not an IPv4 literal (a host name or IPv6) — a bind check will not work.
            return resolved == INADDR_NONE ? INADDR_ANY : resolved
        }
    }

    private static func canBind(port: Int, address: in_addr_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // SO_REUSEADDR is needed so that recently closed sockets in TIME_WAIT
        // do not look like a taken port.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = address

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Process management

    static func kill(pid: Int32, signal: KillSignal) async -> CommandResult {
        await ProcessRunner.run("/bin/kill", ["-\(signal.rawValue)", String(pid)])
    }

    static func killAsAdmin(pid: Int32, signal: KillSignal) async -> CommandResult {
        await ProcessRunner.runAsAdmin("/bin/kill -\(signal.rawValue) \(String(pid))",
                                       prompt: String(localized: "ServerMaster wants to terminate process \(String(pid))."))
    }

    /// Details about a process — the full command line.
    static func processDetails(pid: Int32) async -> String {
        let result = await ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "pid=,ppid=,user=,%cpu=,%mem=,etime=,command="])
        return result.combined.isEmpty ? String(localized: "Process \(String(pid)) not found.") : result.combined
    }

    // MARK: - Parsing lsof

    private static func runLSOF(arguments: [String], proto: String) async -> [PortEntry] {
        let result = await ProcessRunner.run("/usr/sbin/lsof", arguments, timeout: 20)
        // lsof returns 1 when it simply found nothing — that is not an error.
        return parse(result.stdout, proto: proto)
    }

    static func parse(_ output: String, proto: String) -> [PortEntry] {
        var entries: [PortEntry] = []

        var pid: Int32 = 0
        var command = ""
        var user = ""
        var family = ""

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                command = ""; user = ""; family = ""
            case "c":
                command = value
            case "L":
                user = value
            case "u":
                if user.isEmpty { user = value }
            case "t":
                family = value
            case "n":
                guard let parsed = parseAddress(value) else { continue }
                // For UDP lsof also returns “connected” sockets of the form a->b — those are skipped.
                if value.contains("->") { continue }
                entries.append(PortEntry(pid: pid, command: command, user: user,
                                         proto: proto, family: family,
                                         address: parsed.host, port: parsed.port))
            default:
                break
            }
        }
        return entries
    }

    /// `*:8080`, `127.0.0.1:8080`, `[::1]:8080`, `fe80::1%en0:5353`
    static func parseAddress(_ raw: String) -> (host: String, port: Int)? {
        var value = raw
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let rest = value[value.index(after: closing)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let separator = value.lastIndex(of: ":") else { return nil }
        let host = String(value[value.startIndex..<separator])
        guard let port = Int(value[value.index(after: separator)...]) else { return nil }
        value = host
        return (host.isEmpty ? "*" : host, port)
    }

    private static func dedupe(_ entries: [PortEntry]) -> [PortEntry] {
        var seen = Set<String>()
        return entries
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                lhs.port == rhs.port ? lhs.pid < rhs.pid : lhs.port < rhs.port
            }
    }
}
