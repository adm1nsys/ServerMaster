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
        let wildcard = address == "*" || address == "::" || address == "0.0.0.0"
        let host = wildcard ? (family == "IPv6" || address == "::" ? "::1" : "127.0.0.1") : address
        return URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(String(port))")
    }
}

nonisolated enum PortScanner {

    /// Every listening TCP socket (and optionally UDP).
    static func scan(includeUDP: Bool) async -> [PortEntry] {
        async let tcp = runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iTCP", "-sTCP:LISTEN"], proto: "TCP")
        async let hiddenTCP = runNetstatListeners()
        let known = await tcp
        let hidden = await hiddenTCP
        if includeUDP {
            async let udp = runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iUDP"], proto: "UDP")
            let udpEntries = await udp
            let combined = known + udpEntries + hiddenEntries(from: hidden, known: known)
            return dedupe(combined)
        }
        return dedupe(known + hiddenEntries(from: hidden, known: known))
    }

    /// Who is listening on a specific port.
    static func processesListening(onPort port: Int) async -> [PortEntry] {
        let entries = await runLSOF(arguments: ["-nP", "-F", "pcuLtn", "-iTCP:\(String(port))", "-sTCP:LISTEN"], proto: "TCP")
        let visible = dedupe(entries.filter { $0.port == port })
        // macOS can withhold root-owned sockets from an ordinary lsof
        // invocation. netstat still exposes their listening endpoints.
        guard visible.isEmpty else { return visible }
        // A root-owned TIME_WAIT socket can prevent a user bind even after
        // the listener has gone. It is not a process that can be terminated.
        let listeners = await runNetstatListeners()
        return listeners.filter { $0.port == port }.map { hiddenEntry(port: port, address: $0.address) }
    }

    /// Check the requested address and its wildcard in the same address family.
    /// Resolving a hostname must not silently replace an IPv6 address with IPv4.
    static func isPortFree(_ port: Int, host: String) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_PASSIVE
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.isEmpty || host == "*" ? nil : host, String(port), &hints, &result) == 0,
              let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var checked = false
        while let item = cursor {
            let info = item.pointee
            if info.ai_family == AF_INET || info.ai_family == AF_INET6 {
                checked = true
                guard canBind(info.ai_addr, length: info.ai_addrlen, family: info.ai_family) else { return false }
                if info.ai_family == AF_INET6 {
                    var wildcard = sockaddr_in6()
                    wildcard.sin6_family = sa_family_t(AF_INET6)
                    wildcard.sin6_port = in_port_t(UInt16(port).bigEndian)
                    let free = withUnsafePointer(to: &wildcard) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            canBind($0, length: socklen_t(MemoryLayout<sockaddr_in6>.size), family: AF_INET6)
                        }
                    }
                    guard free else { return false }
                } else {
                    var wildcard = sockaddr_in()
                    wildcard.sin_family = sa_family_t(AF_INET)
                    wildcard.sin_port = in_port_t(UInt16(port).bigEndian)
                    let free = withUnsafePointer(to: &wildcard) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            canBind($0, length: socklen_t(MemoryLayout<sockaddr_in>.size), family: AF_INET)
                        }
                    }
                    guard free else { return false }
                }
            }
            cursor = info.ai_next
        }
        return checked
    }

    /// Suggestions are unprivileged ports and never return a known occupied
    /// or reserved endpoint. Binding is checked again when a server starts.
    static func availablePort(startingAt preferred: Int = 8080, excluding: Set<Int> = [], host: String = "127.0.0.1") -> Int? {
        let start = (1024...65535).contains(preferred) ? preferred : 8080
        var candidate = start
        repeat {
            if !excluding.contains(candidate), isPortFree(candidate, host: host) { return candidate }
            candidate = candidate == 65535 ? 1024 : candidate + 1
        } while candidate != start
        return nil
    }

    private static func canBind(_ address: UnsafePointer<sockaddr>?, length: socklen_t, family: Int32) -> Bool {
        guard let address else { return false }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        return Darwin.bind(fd, address, length) == 0 && Darwin.listen(fd, 1) == 0
    }

    static func listener(_ entry: PortEntry, matchesHost host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "*" { return true }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return true // An unresolved address cannot prove that the endpoint is free.
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let item = cursor {
            let info = item.pointee
            defer { cursor = info.ai_next }
            let family = info.ai_family == AF_INET6 ? "IPv6" : "IPv4"
            guard entry.family == family else { continue }
            if entry.address == "*" || entry.address == "0.0.0.0" || entry.address == "::" { return true }
            var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.ai_addr, info.ai_addrlen, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                let numeric = String(cString: address)
                if entry.address == numeric || host == "0.0.0.0" || host == "::" { return true }
            }
        }
        return false
    }

    // MARK: - Process management

    /// A saved row is not authority to kill a PID that no longer owns its socket.
    static func stillOwnsEndpoint(_ entry: PortEntry) async -> Bool {
        guard entry.pid > 1, entry.pid != getpid() else { return false }
        let current = await scan(includeUDP: entry.proto == "UDP")
        return current.contains { $0.pid == entry.pid && $0.port == entry.port &&
            $0.proto == entry.proto && $0.address == entry.address && $0.family == entry.family }
    }

    static func terminate(_ entry: PortEntry, signal: KillSignal,
                          asAdministrator: Bool = false) async -> CommandResult {
        guard await stillOwnsEndpoint(entry) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: String(localized:
                "This process no longer owns the selected port. Refresh the list before trying again."))
        }
        if asAdministrator {
            // Check again *after* the authorization prompt, inside the elevated
            // command. Shell-quote the endpoint; only validated numeric PID/port
            // and the closed KillSignal enum are interpolated as command syntax.
            let host = entry.address.contains(":") ? "[\(entry.address)]" : entry.address
            let endpoint = "n\(host):\(entry.port)"
            let quoted = "'" + endpoint.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let proto = entry.proto == "UDP" ? "UDP" : "TCP"
            let listening = proto == "TCP" ? " -sTCP:LISTEN" : ""
            let command = "/usr/sbin/lsof -nP -a -p \(entry.pid) -i\(proto):\(entry.port)\(listening) -Fpn | /usr/bin/grep -Fqx -- \(quoted) && /bin/kill -\(signal.rawValue) \(entry.pid)"
            return await ProcessRunner.runAsAdmin(command,
                prompt: String(localized: "ServerMaster wants to terminate process \(String(entry.pid))."))
        }
        return await kill(pid: entry.pid, signal: signal)
    }

    static func kill(pid: Int32, signal: KillSignal) async -> CommandResult {
        guard pid > 0 else { return CommandResult(exitCode: 1, stdout: "", stderr: "The process owner is hidden by macOS.") }
        return await ProcessRunner.run("/bin/kill", ["-\(signal.rawValue)", String(pid)])
    }

    static func killAsAdmin(pid: Int32, signal: KillSignal) async -> CommandResult {
        guard pid > 0 else { return CommandResult(exitCode: 1, stdout: "", stderr: "Refresh after granting access or stop the server from its profile.") }
        return await ProcessRunner.runAsAdmin("/bin/kill -\(signal.rawValue) \(String(pid))",
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

    /// `netstat` does not reveal PID/owner, but unlike an unprivileged `lsof`
    /// it still reveals that a root-owned listener exists. This closes the
    /// dangerous gap where the Ports screen said “free” while Apache held it.
    private static func runNetstatListeners() async -> [(address: String, port: Int)] {
        let result = await ProcessRunner.run("/usr/sbin/netstat", ["-an", "-p", "tcp"], timeout: 20)
        return parseNetstatListeners(result.stdout)
    }

    static func parseNetstatListeners(_ output: String) -> [(address: String, port: Int)] {
        output.split(separator: "\n").compactMap { raw in
            let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 6, fields[0].hasPrefix("tcp"), fields.last == "LISTEN" else { return nil }
            let endpoint = String(fields[3])
            guard let dot = endpoint.lastIndex(of: "."), let port = Int(endpoint[endpoint.index(after: dot)...]) else { return nil }
            let address = String(endpoint[..<dot])
            return (address.isEmpty || address == "*" ? "*" : address, port)
        }
    }

    private static func hiddenEntries(from listeners: [(address: String, port: Int)], known: [PortEntry]) -> [PortEntry] {
        let visiblePorts = Set(known.map(\.port))
        return listeners.filter { !visiblePorts.contains($0.port) }.map { listener in
            hiddenEntry(port: listener.port, address: listener.address)
        }
    }

    private static func hiddenEntry(port: Int, address: String = "127.0.0.1") -> PortEntry {
        PortEntry(pid: 0, command: String(localized: "Process hidden by macOS"),
                  user: String(localized: "unknown (administrator-owned possible)"),
                  proto: "TCP", family: address.contains(":") ? "IPv6" : "IPv4", address: address, port: port)
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
