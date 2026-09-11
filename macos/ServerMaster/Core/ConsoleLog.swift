//
//  ConsoleLog.swift
//  ServerMaster
//

import Foundation
import Observation

nonisolated enum LogStream: String, Codable, Sendable {
    case stdout, stderr, system, command
}

nonisolated struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let stream: LogStream
    let text: String
}

/// A ring buffer of lines for the console.
@Observable
final class ConsoleLog {

    private(set) var lines: [LogLine] = []
    var limit: Int = 5000

    /// Increments on every append — the view uses it for auto-scrolling.
    private(set) var revision: Int = 0

    private var fileHandle: FileHandle?
    private(set) var fileURL: URL?
    /// The cap on a log file. A talkative server can write gigabytes in a day —
    /// past the cap, writing stops.
    var fileSizeLimit: Int = 20 * 1024 * 1024
    private var writtenBytes = 0
    private var fileLimitReached = false

    func append(_ text: String, stream: LogStream = .stdout) {
        let cleaned = text.strippingANSI
        guard !cleaned.isEmpty else { return }

        // In Swift "\r\n" is a single Character, so splitting on "\n" does not cut it
        // and all CRLF output is glued into one line. Line endings are normalised
        // before splitting.
        let normalized = cleaned.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)

        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            // A lone \r means the line is being redrawn (brew and npm progress bars).
            // A terminal would show only the last variant, so we show the same.
            if line.contains("\r") {
                line = line.split(separator: "\r", omittingEmptySubsequences: false)
                    .last.map(String.init) ?? line
            }
            if line.isEmpty && raw.isEmpty && lines.last?.text.isEmpty == true { continue }
            lines.append(LogLine(date: Date(), stream: stream, text: line))
        }
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        revision &+= 1
        writeToFile(cleaned)
    }

    func system(_ text: String) { append(text, stream: .system) }

    func clear() {
        lines.removeAll()
        revision &+= 1
    }

    var plainText: String {
        lines.map { $0.text }.joined(separator: "\n")
    }

    func timestampedText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return lines.map { "[\(formatter.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Log file

    func startFileLogging(name: String) {
        stopFileLogging()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = AppPaths.logs.appendingPathComponent("\(safeName)_\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileURL = fileHandle == nil ? nil : url
        writtenBytes = 0
        fileLimitReached = false
    }

    func stopFileLogging() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func writeToFile(_ text: String) {
        guard let fileHandle, !fileLimitReached else { return }
        var payload = text
        if !payload.hasSuffix("\n") { payload += "\n" }
        let data = Data(payload.utf8)

        if writtenBytes + data.count > fileSizeLimit {
            fileLimitReached = true
            let notice = String(localized: "— the log file reached its limit, writing stopped —\n")
            try? fileHandle.write(contentsOf: Data(notice.utf8))
            try? fileHandle.close()
            self.fileHandle = nil
            return
        }
        try? fileHandle.write(contentsOf: data)
        writtenBytes += data.count
    }
}
