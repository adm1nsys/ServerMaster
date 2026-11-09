import Foundation
import Darwin
import Testing
@testable import ServerMaster

@MainActor
@Suite("Log retention and file logging", .serialized)
struct LogRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func file(_ root: URL, _ name: String, age: Double) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("preserve me\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: url.path)
        return url
    }

    @Test("Configured retention and exact cutoff apply only to regular top-level logs")
    func retentionAndTypes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try file(root, "expired.log", age: 4)
        let uppercase = try file(root, "older.LOG", age: 4)
        let cutoff = try file(root, "cutoff.log", age: 3)
        let recent = try file(root, "recent.log", age: 2)
        let unrelated = try file(root, "keep.txt", age: 40)
        let folder = root.appendingPathComponent("folder.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = try file(folder, "nested.log", age: 40)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: folder.path)
        let fifo = root.appendingPathComponent("pipe.log")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let result = LogRetention.clean(directory: root, days: 3, now: now)
        #expect(result.removed == 2)
        #expect(result.failureCount == 0)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(!FileManager.default.fileExists(atPath: uppercase.path))
        for url in [cutoff, recent, unrelated, nested, fifo] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Zero and negative retention do not enumerate or remove files")
    func disabledRetention() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try file(root, "old.log", age: 100)
        for days in [0, -2] {
            let result = LogRetention.clean(directory: root, days: days, now: now)
            #expect(result.disabled && result.removed == 0 && result.failureCount == 0)
        }
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test("Linked files and linked log roots never delete the target")
    func linkedPaths() throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let target = try file(outside, "outside.log", age: 100)
        let link = root.appendingPathComponent("linked.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(LogRetention.clean(directory: root, days: 1, now: now).removed == 0)
        let linkedRoot = root.appendingPathComponent("Logs")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        let result = LogRetention.clean(directory: linkedRoot, days: 1, now: now)
        #expect(result.removed == 0 && result.failureCount == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve me\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test("Active writers remain protected without an active-path snapshot")
    func activeWriter() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ConsoleLog()
        log.startFileLogging(name: "session", directory: root)
        defer { log.stopFileLogging() }
        log.append("Привіт 🌻")
        let url = try #require(log.fileURL)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: url.path)
        let active = LogRetention.clean(directory: root, days: 1, now: now)
        #expect(active.removed == 0 && active.skippedActive == 1 && active.failureCount == 0)
        log.stopFileLogging()
        #expect(!log.isFileLogging)
        #expect(log.fileURL == url) // Reveal remains available after closing.
        let closed = LogRetention.clean(directory: root, days: 1, now: now)
        #expect(closed.removed == 1 && closed.failureCount == 0)
    }

    @Test("Explicit active paths remain protected even without a cooperating writer")
    func activeSnapshot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try file(root, "external.log", age: 100)
        let result = LogRetention.clean(directory: root, days: 1, activeFiles: [active], now: now)
        #expect(result.removed == 0 && result.skippedActive == 1)
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("Failed deletions report errors and do not count as removed")
    func removalFailure() throws {
        let root = try directory()
        defer {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let old = try file(root, "old.log", age: 100)
        #expect(chmod(root.path, 0o500) == 0)
        let result = LogRetention.clean(directory: root, days: 1, now: now)
        #expect(result.removed == 0)
        #expect(result.failureCount == 1)
        #expect(result.problems.first?.contains("old.log") == true)
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test("Missing log folder is harmless; invalid and unreadable roots report errors")
    func rootFailures() throws {
        let root = try directory()
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        #expect(LogRetention.clean(directory: root.appendingPathComponent("absent"), days: 1).failureCount == 0)
        let regular = try file(root, "not-a-folder", age: 10)
        #expect(LogRetention.clean(directory: regular, days: 1).failureCount == 1)
        #expect(chmod(root.path, 0o000) == 0)
        #expect(LogRetention.clean(directory: root, days: 1).failureCount == 1)
    }

    @Test("The model cleanup uses saved retention and reports actual success or failure")
    func modelCleanup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationDirectory: root)
        try FileManager.default.createDirectory(at: model.logsDirectory, withIntermediateDirectories: true)
        let clock = Date()
        let old = try file(model.logsDirectory, "old.log", age: 5)
        let recent = try file(model.logsDirectory, "recent.log", age: 1)
        for (url, days) in [(old, 5), (recent, 1)] {
            try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-Double(days) * 86_400)], ofItemAtPath: url.path)
        }
        model.settings.logRetentionDays = 3
        let first = await model.cleanOldLogs(showNotification: true)
        #expect(first.removed == 1 && first.failureCount == 0)
        #expect(!model.isCleaningLogs)
        #expect(model.banner?.isError == false)
        #expect(FileManager.default.fileExists(atPath: recent.path))
        model.settings.logRetentionDays = 0
        #expect(await model.cleanOldLogs(showNotification: true).disabled)
        #expect(model.banner?.text == String(localized: "Log cleanup is disabled. Set a retention period above zero."))
        model.settings.logRetentionDays = 1
        #expect(chmod(model.logsDirectory.path, 0o500) == 0)
        defer { chmod(model.logsDirectory.path, 0o700) }
        let failure = await model.cleanOldLogs(showNotification: true)
        #expect(failure.removed == 0 && failure.failureCount == 1)
        #expect(model.banner?.isError == true)
        #expect(model.shell.log.plainText.contains("recent.log"))
    }

    @Test("Long unsafe names stay private, bounded, unique and inside the log folder")
    func filenames() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".. /../bad\n:name\\", String(repeating: "🌻", count: 1_000), "..."] {
            let log = ConsoleLog()
            log.startFileLogging(name: name, directory: root)
            defer { log.stopFileLogging() }
            let url = try #require(log.fileURL)
            #expect(url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
            #expect(url.lastPathComponent.utf8.count <= 255)
            #expect(!url.lastPathComponent.hasPrefix("."))
            #expect(!url.lastPathComponent.contains("\n"))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(log.isFileLogging && log.fileLoggingState == .writing)
            log.append("Unicode Україна 🌻")
            log.stopFileLogging()
            #expect(log.fileLoggingState == .stopped)
            #expect(try String(contentsOf: url, encoding: .utf8) == "Unicode Україна 🌻\n")
        }
    }

    @Test("Open failure keeps memory output and reports the real status")
    func openFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ConsoleLog()
        log.startFileLogging(name: "server", directory: root.appendingPathComponent("missing"))
        #expect(!log.isFileLogging && log.fileURL == nil)
        guard case .failed = log.fileLoggingState else { Issue.record("Open failure was hidden"); return }
        log.append("Still visible")
        #expect(log.plainText.contains("Could not open log file"))
        #expect(log.plainText.contains("Still visible"))
        log.startFileLogging(name: "retry", directory: root)
        #expect(log.isFileLogging && log.fileLoggingState == .writing)
        log.stopFileLogging()
    }

    @Test("Exclusive creation refuses existing files and links without changing them")
    func exclusiveCreation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try file(root, "existing.log", age: 1)
        let link = root.appendingPathComponent("linked.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let io = ConsoleLog.FileIO()
        for url in [target, link] { #expect(throws: (any Error).self) { try io.open(url) } }
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve me\n")
        let handle = try io.open(root.appendingPathComponent("new.log"))
        #expect(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        try io.close(handle)
    }

    @Test("Write failures stop disk output without recursive error logging")
    func writeFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var writes = 0
        var closes = 0
        var io = ConsoleLog.FileIO()
        io.write = { _, _ in writes += 1; throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        io.close = { handle in closes += 1; try handle.close() }
        let log = ConsoleLog(fileIO: io)
        log.startFileLogging(name: "disk-full", directory: root)
        log.append("Original line")
        log.append("Memory keeps working")
        log.stopFileLogging()
        #expect(writes == 1 && closes == 1)
        #expect(!log.isFileLogging)
        guard case .failed = log.fileLoggingState else { Issue.record("Write failure was hidden"); return }
        #expect(log.plainText.contains("Original line"))
        #expect(log.plainText.contains("Could not write log file"))
        #expect(log.plainText.contains("Memory keeps working"))
    }

    @Test("Close failures remain visible and repeated stops do not repeat them")
    func closeFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var closes = 0
        var io = ConsoleLog.FileIO()
        io.close = { handle in
            closes += 1
            try handle.close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        let log = ConsoleLog(fileIO: io)
        log.startFileLogging(name: "close-error", directory: root)
        log.append("Saved before close")
        log.stopFileLogging()
        log.stopFileLogging()
        log.append("After close")
        #expect(closes == 1 && !log.isFileLogging)
        guard case .failed = log.fileLoggingState else { Issue.record("Close failure was hidden"); return }
        #expect(log.lines.filter { $0.text.contains("Could not close log file") }.count == 1)
        #expect(log.plainText.contains("After close"))
        let url = try #require(log.fileURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Saved before close\n")
    }

    @Test("The size cap closes the writer honestly and memory output continues")
    func sizeCap() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ConsoleLog()
        log.fileSizeLimit = 4
        log.startFileLogging(name: "cap", directory: root)
        log.append("ok")
        log.append("larger than limit")
        log.append("Memory still works")
        #expect(!log.isFileLogging && log.fileLoggingState == .limitReached)
        let url = try #require(log.fileURL)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.hasPrefix("ok\n"))
        #expect(content.contains("writing stopped"))
        #expect(!content.contains("larger than limit"))
        #expect(log.plainText.contains("larger than limit") && log.plainText.contains("Memory still works"))
    }
}
