import Foundation
import Darwin
import Testing
@testable import ServerMaster

@MainActor
@Suite("Permissions scan boundaries", .serialized)
struct SitePermissionsTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A normal project is clean only after checking its files")
    func cleanProject() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: cache.appendingPathComponent("data"))
        let report = SitePermissions.check(root: root.path)
        #expect(report.isClean && !report.truncated)
        #expect(report.checkedCount == 3)
        #expect(report.problems.isEmpty)
    }

    @Test("Missing, empty and invalid roots cannot be reported as clean")
    func badRoots() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["", root.appendingPathComponent("absent").path, "bad\0path"] {
            let report = SitePermissions.check(root: path)
            #expect(!report.isClean)
            #expect(report.problems.count == 1 && report.problems.first?.kind == .missing)
            #expect(!report.canFixPermissions)
        }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        let report = SitePermissions.check(root: file.path)
        #expect(!report.isClean && report.problems.first?.kind == .unreadable)
    }

    @Test("Linked CMS folders, files, loops and broken links are skipped")
    func skipLinks() throws {
        let root = try directory()
        let outside = try directory()
        defer {
            chmod(outside.path, 0o700)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("administrator"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cache"), withDestinationURL: root)
        let outsideFile = outside.appendingPathComponent("read-only")
        try Data("private".utf8).write(to: outsideFile)
        #expect(chmod(outsideFile.path, 0o400) == 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-file"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: outside.appendingPathComponent("absent"))
        #expect(chmod(outside.path, 0o000) == 0)
        let report = SitePermissions.check(root: root.path)
        #expect(report.isClean)
        #expect(report.checkedCount == 1 && report.skippedLinks == 4)
        #expect(report.problems.isEmpty)
    }

    @Test("A linked selected root is refused without walking the target")
    func linkedRoot() throws {
        let root = try directory()
        let outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("site")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let report = SitePermissions.check(root: link.path)
        #expect(!report.isClean && report.checkedCount == 0)
        #expect(report.problems.first?.path == link.path)
        #expect(report.problems.first?.kind == .unreadable)
    }

    @Test("Unreadable folders and files are problems rather than silently skipped")
    func unreadablePaths() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("cache")
        let file = root.appendingPathComponent("index.php")
        defer {
            chmod(folder.path, 0o700); chmod(file.path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: file)
        #expect(chmod(folder.path, 0o000) == 0)
        #expect(chmod(file.path, 0o000) == 0)
        let report = SitePermissions.check(root: root.path)
        #expect(!report.isClean && report.checkedCount == 3)
        #expect(report.problems.count == 2)
        #expect(report.problems.allSatisfy { $0.kind == .unreadable })
        #expect(report.canFixPermissions)
        #expect(chmod(root.path, 0o000) == 0)
        let rootReport = SitePermissions.check(root: root.path)
        #expect(!rootReport.isClean && rootReport.problems.first?.kind == .unreadable)
        #expect(chmod(root.path, 0o700) == 0)
    }

    @Test("Read-only files retain their actionable permission problem")
    func readOnlyFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.php")
        try Data().write(to: file)
        #expect(chmod(file.path, 0o400) == 0)
        let report = SitePermissions.check(root: root.path)
        #expect(!report.isClean)
        #expect(report.problems.first?.kind == .notWritable)
        #expect(report.canFixPermissions && !report.needsAdmin)
    }

    @Test("A limited scan is incomplete and prioritizes CMS folders")
    func scanLimit() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<12 { try Data().write(to: root.appendingPathComponent("file-\(number)")) }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { chmod(cache.path, 0o700) }
        #expect(chmod(cache.path, 0o500) == 0)
        let report = SitePermissions.check(root: root.path, limit: 2)
        #expect(!report.isClean && report.truncated && report.checkedCount == 2)
        #expect(report.problems.first?.path == cache.path)
        #expect(report.problems.first?.kind == .notWritable)
        #expect(SitePermissions.check(root: root.path, limit: 0).truncated)
        #expect(!SitePermissions.check(root: root.path, limit: 0).isClean)
        #expect(chmod(cache.path, 0o700) == 0)
        let limitedClean = SitePermissions.check(root: root.path, limit: 2)
        #expect(limitedClean.problems.isEmpty && limitedClean.truncated && !limitedClean.isClean)
    }

    @Test("Git internals and special files do not cause recursion or blocking")
    func specialFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: git.appendingPathComponent("loop"), withDestinationURL: root)
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        let report = SitePermissions.check(root: root.path)
        #expect(report.isClean && report.checkedCount == 1 && report.skippedLinks == 0)
    }
}
