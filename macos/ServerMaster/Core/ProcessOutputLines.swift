import Foundation

/// Pipe reads may end in the middle of a UTF-8 scalar or URL. Keep bytes until
/// a line ends; cap unterminated output without splitting a UTF-8 scalar.
nonisolated final class ProcessOutputLines: @unchecked Sendable {
    struct Line: Sendable {
        let text: String
        let complete: Bool
    }

    private let lock = NSLock()
    private var pending = Data()
    private let limit = 64 * 1024

    func consume(_ data: Data, endOfFile: Bool = false) -> [Line] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [Line] = []
        while let newline = pending.firstIndex(of: 10) {
            let end = pending.index(after: newline)
            lines.append(Line(text: String(decoding: pending[..<end], as: UTF8.self), complete: true))
            pending.removeSubrange(..<end)
        }
        while pending.count > limit {
            var end = pending.index(pending.startIndex, offsetBy: limit)
            while end > pending.startIndex, pending[end] & 0xc0 == 0x80 {
                end = pending.index(before: end)
            }
            lines.append(Line(text: String(decoding: pending[..<end], as: UTF8.self), complete: false))
            pending.removeSubrange(..<end)
        }
        if endOfFile, !pending.isEmpty {
            lines.append(Line(text: String(decoding: pending, as: UTF8.self), complete: true))
            pending.removeAll(keepingCapacity: false)
        }
        return lines
    }
}
