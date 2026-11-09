import Foundation
import Security
import Network

/// Startup reads HTTP headers directly: no redirect, proxy, body download or
/// content sniffing that could hold a streaming response open indefinitely.
nonisolated enum HTTPStartup {
    enum Result: Sendable { case response, failed, timedOut }

    static func address(for profile: ServerProfile) -> URL? {
        var host = profile.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "0.0.0.0" { host = "127.0.0.1" }
        if host == "::" { host = "::1" }
        var parts = URLComponents()
        parts.scheme = profile.scheme
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = profile.port
        parts.path = "/"
        return parts.url
    }

    struct Response: Sendable {
        var result: Result
        var status: Int?
        var server: String?
        var problem: String?
    }

    static func inspect(url: URL, certificatePath: String?, timeout: TimeInterval) async -> Response {
        let request = HeaderRequest(certificatePath: certificatePath)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { request.start(url: url, timeout: timeout, continuation: $0) }
        } onCancel: { request.cancel() }
    }

    static func headers(url: URL, certificatePath: String?, timeout: TimeInterval) async -> Result {
        await inspect(url: url, certificatePath: certificatePath, timeout: timeout).result
    }
}

/// All mutable state is confined to queue, including cancellation and timeout.
nonisolated private final class HeaderRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ServerMaster.HTTPStartup")
    private var result: HTTPStartup.Response?
    private var continuation: CheckedContinuation<HTTPStartup.Response, Never>?
    private var connection: NWConnection?
    private var timer: DispatchWorkItem?
    private var received = Data()
    private let expected: SecCertificate?
    private let invalidCertificate: Bool

    init(certificatePath: String?) {
        let certificate = certificatePath.flatMap { $0.isEmpty ? nil : try? TLSValidation.certificate($0) }
        expected = certificate
        invalidCertificate = certificatePath.map { !$0.isEmpty && certificate == nil } ?? false
    }

    func start(url: URL, timeout: TimeInterval, continuation: CheckedContinuation<HTTPStartup.Response, Never>) {
        queue.async { self.begin(url: url, timeout: timeout, continuation: continuation) }
    }

    func cancel() { queue.async { self.finish(.failed) } }

    private func begin(url: URL, timeout: TimeInterval, continuation: CheckedContinuation<HTTPStartup.Response, Never>) {
        if let result { continuation.resume(returning: result); return }
        self.continuation = continuation
        if invalidCertificate { finish(.failed); return }
        guard let rawHost = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue != 0, !rawHost.contains(where: { $0.isNewline }) else { finish(.failed); return }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let tls: NWProtocolTLS.Options?
        if url.scheme == "https" {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
            let expected = expected
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                complete(TLSValidation.accepts(trust, host: host, expected: expected))
            }, queue)
            tls = options
        } else { tls = nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        let timer = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.result == nil else { return }
            switch state {
            case .ready:
                let request = "GET / HTTP/1.1\r\nHost: \(rawHost):\(port.rawValue)\r\nConnection: close\r\nCache-Control: no-cache, no-store\r\nPragma: no-cache\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.finish(.failed) } else { self.readHeaders() }
                })
            case .failed: self.finish(.failed)
            case .waiting: self.finish(.failed)
            case .cancelled: self.finish(.failed)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func readHeaders() {
        guard result == nil, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, ended, error in
            guard let self, self.result == nil else { return }
            if let data { self.received.append(data) }
            while let boundary = self.received.range(of: Data([13,10,13,10])) {
                guard self.received.distance(from: self.received.startIndex, to: boundary.upperBound) <= 64 * 1024 else { self.finish(.failed); return }
                let header = String(decoding: self.received[..<boundary.lowerBound], as: UTF8.self)
                let status = header.components(separatedBy: "\r\n").first ?? ""
                guard status.range(of: #"^HTTP/1\.[01] [1-5][0-9]{2}( |$)"#, options: .regularExpression) != nil else {
                    self.finish(.failed); return
                }
                let code = Int(status.dropFirst(9).prefix(3)) ?? 0
                if code >= 200 || code == 101 {
                    let server = header.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("server:") }
                        .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    self.finish(.response, status: code, server: server)
                    return
                }
                self.received.removeSubrange(..<boundary.upperBound)
            }
            guard self.received.count <= 64 * 1024, !ended, error == nil else { self.finish(.failed); return }
            self.readHeaders()
        }
    }

    private func finish(_ value: HTTPStartup.Result, status: Int? = nil, server: String? = nil) {
        guard result == nil else { return }
        let response = HTTPStartup.Response(result: value, status: status, server: server,
            problem: value == .response ? nil : value == .timedOut
                ? String(localized: "No HTTP response within the time limit.")
                : String(localized: "The connection failed or the HTTPS certificate could not be verified."))
        result = response
        timer?.cancel()
        timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: response)
    }
}
