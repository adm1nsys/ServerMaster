import Foundation
import Darwin

/// Keeps a kernel reservation while planning and a logical reservation while
/// the child is binding. Concurrent profiles cannot choose the same FPM port
/// in the gap between closing the reservation socket and starting php-fpm.
nonisolated final class RuntimePortLease: @unchecked Sendable {
    private static let lock = NSLock()
    private static var planned: Set<Int> = []
    let port: Int
    private var descriptor: Int32

    private init(port: Int, descriptor: Int32) { self.port = port; self.descriptor = descriptor }

    static func acquire(excluding: Int) throws -> RuntimePortLease {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            let port = Int(UInt16(bigEndian: address.sin_port))
            if bound == 0 && found == 0 && port >= 1024 && port != excluding && !planned.contains(port) {
                planned.insert(port)
                return RuntimePortLease(port: port, descriptor: fd)
            }
            close(fd)
        }
        throw LaunchPlanBuilder.BuildError.invalid(String(localized: "Could not reserve a private runtime port."))
    }

    func allowChildBind() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    deinit {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if descriptor >= 0 { close(descriptor) }
        Self.planned.remove(port)
    }
}
