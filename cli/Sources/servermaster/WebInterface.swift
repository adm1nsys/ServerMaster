//
//  WebInterface.swift
//  servermaster
//
//  The same control panel, in a browser.
//
//  A terminal is not always the right shape. Somebody wants to glance at what is
//  running from a laptop, or hand a colleague a link instead of a lesson in a
//  TUI. So the tool serves a small page of its own.
//
//  Two decisions worth stating, because they are about safety rather than taste.
//
//  It listens on the loopback address only. This page can start and stop
//  processes; on 0.0.0.0 it would be a remote shell for anyone on the same
//  network, and no amount of "it is only a dev machine" makes that acceptable as
//  a default. Putting it on the network is deliberately somebody else's job:
//  point nginx or Caddy at it, with a certificate and whatever authentication
//  the situation deserves.
//
//  And it speaks plain HTTP. Not because encryption does not matter, but because
//  a self-signed certificate on localhost buys a browser warning and no safety —
//  the traffic never leaves the machine. HTTPS belongs on the proxy in front,
//  where it is real.
//
//  The server itself is POSIX sockets and nothing else: no framework, no
//  dependency, and the same code compiles on Linux.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class WebInterface: @unchecked Sendable {

    static let shared = WebInterface()

    private(set) var address: String?
    private var listener: Int32 = -1
    private var thread: Thread?

    /// The default port. High enough to need no privileges, and fixed so the
    /// address can be written down.
    static let defaultPort = 7654

    // MARK: - Running

    @discardableResult
    func start(port: Int = WebInterface.defaultPort, host: String = "127.0.0.1") -> String? {
        guard listener < 0 else { return address }

        let socketHandle = socket(AF_INET, SOCK_STREAM, 0)
        guard socketHandle >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(socketHandle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketHandle, 16) == 0 else {
            close(socketHandle)
            return nil
        }

        listener = socketHandle
        address = "http://\(host):\(port)"

        let thread = Thread { [weak self] in self?.accept() }
        thread.name = "servermaster.web"
        thread.start()
        self.thread = thread
        return address
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        address = nil
    }

    private func accept() {
        while listener >= 0 {
            let client = Foundation.accept(listener, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            close(client)
        }
    }

    // MARK: - One request

    private func handle(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0,
              let request = String(bytes: buffer[0..<count], encoding: .utf8),
              let line = request.split(separator: "\r\n").first
        else { return }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])

        let response: (status: String, type: String, body: Data)
        switch (method, target) {
        case ("GET", "/"):
            response = ("200 OK", "text/html; charset=utf-8", Data(WebPage.html.utf8))
        case ("GET", "/api/status"):
            response = ("200 OK", "application/json", json(status()))
        case ("POST", let path) where path.hasPrefix("/api/start/"),
             ("POST", let path) where path.hasPrefix("/api/stop/"):
            response = act(target)
        default:
            response = ("404 Not Found", "text/plain", Data("Not found".utf8))
        }

        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: \(response.type)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // The page is served to one machine and never embedded anywhere.
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { _ = send(client, $0.baseAddress, out.count, 0) }
    }

    // MARK: - What the page asks for

    private func status() -> [String: Any] {
        let profiles = ProfileStore.load()
        let running = RunRegistry.all()

        return [
            "version": CLIVersion.version,
            "profiles": profiles.map { profile -> [String: Any] in
                let record = running.first { $0.id == profile.id.uuidString }
                // Built up rather than filtered: an Optional wrapped in Any is
                // not nil to compactMapValues, so "pid": null leaked into the
                // JSON for every stopped profile.
                var entry: [String: Any] = [
                    "id": profile.id.uuidString,
                    "name": profile.name,
                    "address": profile.address,
                    "engine": profile.engine.title,
                    "running": record != nil
                ]
                if let pid = record?.pid { entry["pid"] = pid }
                return entry
            }
        ]
    }

    /// Start and stop, addressed by profile id.
    private func act(_ target: String) -> (String, String, Data) {
        let pieces = target.split(separator: "/")
        guard pieces.count == 3, let id = UUID(uuidString: String(pieces[2])) else {
            return ("400 Bad Request", "application/json", json(["error": "no such profile"]))
        }
        let profiles = ProfileStore.load()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            return ("404 Not Found", "application/json", json(["error": "no such profile"]))
        }

        if pieces[1] == "stop" {
            guard let record = RunRegistry.find(profileID: id) else {
                return ("200 OK", "application/json", json(["ok": true, "note": "was not running"]))
            }
            // The registry's stop is async; this runs on a socket thread, so it
            // is waited on rather than left to finish after the reply is sent —
            // a page that says "stopped" while the process is still up is worse
            // than one that takes a moment.
            let done = DispatchSemaphore(value: 0)
            var result: RunRegistry.StopResult?
            Task {
                result = await RunRegistry.stop(record)
                done.signal()
            }
            done.wait()
            switch result {
            case .stopped, .notRunning:
                return ("200 OK", "application/json", json(["ok": true]))
            case .refused(let why):
                return ("403 Forbidden", "application/json", json(["error": why]))
            case nil:
                return ("500 Internal Server Error", "application/json",
                        json(["error": "the stop did not finish"]))
            }
        }

        do {
            let plan = try LaunchPlanBuilder.build(for: profile)
            try DetachedLauncher.prepare(plan, profile: profile)
            let logPath = AppPaths.logs.appendingPathComponent("\(profile.name)-web.log").path
            let pid = try DetachedLauncher.launch(plan, logPath: logPath)
            RunRegistry.record(RunRecord(id: profile.id.uuidString,
                                         name: profile.name,
                                         address: profile.address,
                                         port: profile.port,
                                         pid: pid,
                                         origin: .commandLine,
                                         startedAt: Date()))
            return ("200 OK", "application/json", json(["ok": true, "pid": pid]))
        } catch {
            return ("500 Internal Server Error", "application/json",
                    json(["error": error.localizedDescription]))
        }
    }

    private func json(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
