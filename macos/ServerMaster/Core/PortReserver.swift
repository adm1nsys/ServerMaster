//
//  PortReserver.swift
//  ServerMaster
//
//  “Reserving” a port = the application opens a listening socket itself,
//  so other processes cannot take it. While a port is reserved,
//  no server can be started on it — the reservation has to be released first.
//

import Foundation
import Observation

nonisolated struct PortReservation: Identifiable, Hashable, Sendable {
    var id: Int { port }
    var port: Int
    var note: String
    var createdAt: Date
}

@Observable
final class PortReserver {

    private(set) var reservations: [PortReservation] = []
    private var sockets: [Int: Int32] = [:]

    enum ReserveError: LocalizedError {
        case alreadyReserved
        case busy(String)

        var errorDescription: String? {
            switch self {
            case .alreadyReserved: return String(localized: "This port is already reserved.")
            case .busy(let reason): return String(localized: "Could not take the port: \(reason)")
            }
        }
    }

    func reserve(port: Int, note: String) throws {
        guard sockets[port] == nil else { throw ReserveError.alreadyReserved }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ReserveError.busy(String(localized: "could not create the socket")) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw ReserveError.busy(String(cString: strerror(errno)))
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw ReserveError.busy(String(cString: strerror(errno)))
        }

        sockets[port] = fd
        reservations.append(PortReservation(port: port, note: note, createdAt: Date()))
        reservations.sort { $0.port < $1.port }
    }

    func release(port: Int) {
        if let fd = sockets.removeValue(forKey: port) { close(fd) }
        reservations.removeAll { $0.port == port }
    }

    func releaseAll() {
        for (_, fd) in sockets { close(fd) }
        sockets.removeAll()
        reservations.removeAll()
    }

    func isReserved(_ port: Int) -> Bool { sockets[port] != nil }
}
