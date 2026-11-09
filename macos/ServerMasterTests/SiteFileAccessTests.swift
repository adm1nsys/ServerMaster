import Foundation
import Testing
@testable import ServerMaster

@Suite("R7 project file boundaries")
struct SiteFileAccessTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-r7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Navigation stays inside the selected root; links are listed without traversal")
    func boundaries() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("project-other")
        for folder in [root, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("private.env"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let access = try SiteFileAccess(root: root)
        #expect(try access.checked(access.root) == access.root)
        #expect(throws: SiteFileAccess.Failure.outside) { try access.checked(outside) }
        var remote = URLComponents()
        remote.scheme = "https"; remote.host = "example.invalid"; remote.path = access.root.path
        #expect(throws: SiteFileAccess.Failure.outside) { try access.checked(remote.url!) }
        #expect(throws: SiteFileAccess.Failure.outside) { try access.checked(access.root.appendingPathComponent("../project-other")) }
        let link = try #require(access.entries(in: access.root).first)
        #expect(link.isLink && !link.isDirectory && !link.isRegular)
        #expect(throws: SiteFileAccess.Failure.linked) { try access.entries(in: link.url) }
        #expect(throws: SiteFileAccess.Failure.linked) { try access.checked(link.url.appendingPathComponent("private.env")) }
        #expect(throws: SiteFileAccess.Failure.linked) { try access.rename(link, to: "renamed") }
        #expect(try String(contentsOf: outside.appendingPathComponent("private.env"), encoding: .utf8) == "keep")
    }

    @Test("Replacing an ancestor with a link cannot redirect an already open editor")
    func changedAncestor() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        let folder = root.appendingPathComponent("sub")
        let outside = base.appendingPathComponent("outside")
        for path in [folder, outside] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("original".utf8).write(to: folder.appendingPathComponent("config"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("config"))
        let access = try SiteFileAccess(root: root)
        var document = try TextFileDocument.load(access.root.appendingPathComponent("sub/config"), access: access)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("old-sub"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(throws: SiteFileAccess.Failure.linked) { try document.save("must not write") }
        #expect(try String(contentsOf: outside.appendingPathComponent("config"), encoding: .utf8) == "outside")
        #expect(try String(contentsOf: root.appendingPathComponent("old-sub/config"), encoding: .utf8) == "original")
    }

    @Test("The root and selected entry cannot be silently replaced")
    func changedIdentity() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("file"))
        let access = try SiteFileAccess(root: root)
        let entry = try #require(access.entries(in: access.root).first)
        try FileManager.default.moveItem(at: entry.url, to: root.appendingPathComponent("held-original"))
        try Data("new".utf8).write(to: entry.url)
        #expect(throws: SiteFileAccess.Failure.changed) { try access.rename(entry, to: "other") }
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("old-root"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: SiteFileAccess.Failure.changed) { try access.entries(in: access.root) }
    }

    @Test("Mac file names are preserved, including dotfiles, spaces and Windows reserved words", arguments: [".htaccess", "CON", "config\\name", "quoted \" name", " trailing space ", "file%2Fname"])
    func nativeNames(name: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: root.appendingPathComponent("source"))
        let access = try SiteFileAccess(root: root)
        let entry = try #require(access.entries(in: access.root).first)
        let target = try access.rename(entry, to: name)
        #expect(target.lastPathComponent == name)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try access.entries(in: access.root).map(\.name) == [name])
    }

    @Test("Unsafe names and occupied destinations never replace other items")
    func refusedRename() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source".utf8).write(to: root.appendingPathComponent("source"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("occupied"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "/does-not-exist/r7")
        let access = try SiteFileAccess(root: root)
        let entry = try #require(access.entries(in: access.root).first { $0.name == "source" })
        for name in ["", ".", "..", "../outside", "folder/file", "bad\0name"] {
            #expect(throws: SiteFileAccess.Failure.invalidName) { try access.rename(entry, to: name) }
        }
        for name in ["occupied", "dangling"] {
            #expect(throws: SiteFileAccess.Failure.exists) { try access.rename(entry, to: name) }
        }
        #expect(try String(contentsOf: root.appendingPathComponent("occupied"), encoding: .utf8) == "keep")
        #expect(try String(contentsOf: entry.url, encoding: .utf8) == "source")
        let renamed = try access.rename(entry, to: "SOURCE")
        #expect(try access.entries(in: access.root).contains { $0.name == "SOURCE" })
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "source")
    }

    @Test("Editor leftovers are hidden, recipe notes are configuration, and a chosen root alias is stable")
    func listings() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("physical")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [".private.servermaster-tmp", "config.UUID.SERVERMASTER-TMP", "notes.servermaster-tmp.txt", "servermaster-demo.md", "php.ini", "htaccess.txt"] {
            try Data("text".utf8).write(to: root.appendingPathComponent(name))
        }
        let alias = base.appendingPathComponent("chosen-root")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let access = try SiteFileAccess(root: alias)
        let items = try access.entries(in: access.root)
        #expect(items.count == 4)
        #expect(items.filter(\.isConfig).map(\.name).sorted() == ["htaccess.txt", "php.ini", "servermaster-demo.md"])
        var profile = ServerProfile()
        profile.engine = .nodeScript
        profile.rootPath = access.root.path
        #expect(ConfigInventory.files(for: profile).contains { $0.title == "servermaster-demo.md" && $0.kind == .site })
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        #expect(try access.entries(in: access.root) == items)
    }
}
