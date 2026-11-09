//
//  ConsoleLog.swift
//  ServerMaster
//

import Foundation
import Darwin
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

    enum FileLoggingState: Equatable {
        case idle, writing, stopped, limitReached, failed(String)
    }

    /// Kept separate from the memory buffer so disk errors cannot lose console output.
    struct FileIO {
        var open: (URL) throws -> FileHandle = { url in
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                Darwin.close(fd)
                throw failure
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
        var close: (FileHandle) throws -> Void = { try $0.close() }
    }

    @ObservationIgnored private let fileIO: FileIO
    private var fileHandle: FileHandle?
    private(set) var fileLoggingState: FileLoggingState = .idle
    var isFileLogging: Bool { fileHandle != nil }

    var fileLoggingStatus: String {
        switch fileLoggingState {
        case .idle: String(localized: "File logging is off")
        case .writing: String(localized: "Writing log to file")
        case .stopped: String(localized: "Log file closed")
        case .limitReached: String(localized: "Log file size limit reached")
        case .failed(let message): message
        }
    }

    init(fileIO: FileIO = FileIO()) { self.fileIO = fileIO }
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

    /// The last lines as plain text. Used where a log has to be reported rather
    /// than displayed — a command line message, or an error the UI shows once.
    func tail(_ count: Int) -> String {
        lines.suffix(count).map(\.text).joined(separator: "\n")
    }

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

    func startFileLogging(name: String, directory: URL = AppPaths.logs) {
        stopFileLogging()
        fileURL = nil
        writtenBytes = 0
        fileLimitReached = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("\(Self.safeFilename(name))_\(formatter.string(from: Date()))_\(UUID().uuidString).log")
        do {
            fileHandle = try fileIO.open(url)
            fileURL = url
            fileLoggingState = .writing
        } catch {
            reportFileError(String(localized: "Could not open log file: \(error.localizedDescription)"))
        }
    }

    func stopFileLogging() {
        guard let handle = fileHandle else { return }
        // Clear the writer before reporting errors: reporting must never write
        // back into a broken handle or recursively report the same failure.
        fileHandle = nil
        do {
            try fileIO.close(handle)
            fileLoggingState = fileLimitReached ? .limitReached : .stopped
        } catch {
            reportFileError(String(localized: "Could not close log file: \(error.localizedDescription)"))
        }
    }

    private func writeToFile(_ text: String) {
        guard let handle = fileHandle, !fileLimitReached else { return }
        var payload = text
        if !payload.hasSuffix("\n") { payload += "\n" }
        let data = Data(payload.utf8)
        do {
            if data.count > max(0, fileSizeLimit - writtenBytes) {
                fileLimitReached = true
                let notice = String(localized: "— the log file reached its limit, writing stopped —\n")
                try fileIO.write(handle, Data(notice.utf8))
                stopFileLogging()
                return
            }
            try fileIO.write(handle, data)
            writtenBytes += data.count
        } catch {
            fileHandle = nil
            var message = String(localized: "Could not write log file: \(error.localizedDescription)")
            do { try fileIO.close(handle) }
            catch { message += "\n" + String(localized: "Could not close log file: \(error.localizedDescription)") }
            reportFileError(message)
        }
    }

    private func reportFileError(_ message: String) {
        fileLoggingState = .failed(message)
        system(message)
    }

    private static func safeFilename(_ name: String) -> String {
        let cleaned = String(name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "-" : String($0)
        }.joined()).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Leave room for the timestamp, UUID and extension within NAME_MAX.
        var result = ""
        for character in cleaned {
            guard result.utf8.count + character.utf8.count <= 120 else { break }
            result.append(character)
        }
        return result.isEmpty ? "server" : result
    }
}
