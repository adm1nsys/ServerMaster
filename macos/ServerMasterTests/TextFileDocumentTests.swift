import Foundation
import Testing
import Darwin
@testable import ServerMaster

@Suite("R6 bounded text editor documents")
struct TextFileDocumentTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-r6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Repeated saves retain encoding, BOM, newlines and permissions", arguments: [0, 1, 2, 3])
    func encodings(kind: Int) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.txt")
        let encodings: [String.Encoding] = [.utf8, .utf8, .utf16LittleEndian, .utf16BigEndian]
        let prefixes: [[UInt8]] = [[], [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]]
        let original = "Привіт 😺\r\nsecond\nthird\r"
        try (Data(prefixes[kind]) + original.data(using: encodings[kind])!).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        var document = try TextFileDocument.load(file)
        #expect(document.text == original)
        for contents in ["changed\r\nУкраїнська 😺\n", "again\r\n"] {
            try document.save(contents)
            #expect(try Data(contentsOf: file) == Data(prefixes[kind]) + contents.data(using: encodings[kind])!)
            #expect(document.text == contents)
            #expect(try TextFileDocument.load(file).text == contents)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o640)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["config.txt"])
    }

    @Test("An external edit with the same size and timestamp is never silently overwritten")
    func conflict() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        try Data("OLD".utf8).write(to: file)
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        var document = try TextFileDocument.load(file)
        try Data("NEW".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(throws: TextFileDocument.Failure.changed) { try document.save("my unsaved text") }
        #expect(try Data(contentsOf: file) == Data("NEW".utf8))
        #expect(document.text == "OLD")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [".env"])
        document = try TextFileDocument.load(file)
        try document.save("explicitly reloaded")
        #expect(try String(contentsOf: file, encoding: .utf8) == "explicitly reloaded")
    }

    @Test("Missing or replaced files cannot be recreated through an old document")
    func replaced() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config")
        try Data("old".utf8).write(to: file)
        var document = try TextFileDocument.load(file)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original"))
        try Data("old".utf8).write(to: file)
        #expect(throws: TextFileDocument.Failure.changed) { try document.save("new") }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try document.save("new") }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Binary, malformed encodings and oversized files are rejected before editing")
    func rejectedInput() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        for bytes in [Data([0x61, 0x00, 0x62]), Data([0xFF, 0xFE, 0x00]), Data([0xC3, 0x28]), Data([0x1B, 0x61])] {
            try bytes.write(to: file)
            #expect(throws: (any Error).self) { try TextFileDocument.load(file) }
            #expect(try Data(contentsOf: file) == bytes)
        }
        try Data(repeating: 0x61, count: TextFileDocument.maximumBytes + 1).write(to: file)
        #expect(throws: TextFileDocument.Failure.tooLarge) { try TextFileDocument.load(file) }
        try Data("original".utf8).write(to: file)
        var document = try TextFileDocument.load(file)
        #expect(throws: TextFileDocument.Failure.notText) { try document.save("bad\0text") }
        #expect(throws: TextFileDocument.Failure.tooLarge) { try document.save(String(repeating: "x", count: TextFileDocument.maximumBytes + 1)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test("Links and special files are refused, including a link substituted after loading")
    func links() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try Data("edit".utf8).write(to: file)
        var document = try TextFileDocument.load(file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: TextFileDocument.Failure.notRegular) { try TextFileDocument.load(file) }
        #expect(throws: TextFileDocument.Failure.notRegular) { try document.save("overwrite") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        let fifo = root.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: TextFileDocument.Failure.notRegular) { try TextFileDocument.load(fifo) }
    }

    @Test("Write failures leave the original intact; adopting a config never replaces an existing file")
    func failuresAndCopies() throws {
        let root = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("config")
        try Data("keep".utf8).write(to: file)
        var document = try TextFileDocument.load(file)
        #expect(throws: (any Error).self) { try document.writeCopy("other", to: file) }
        let own = root.appendingPathComponent("own.conf")
        try document.writeCopy("own text", to: own)
        #expect(try String(contentsOf: own, encoding: .utf8) == "own text")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try document.save("new") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["config", "own.conf"])
    }
}
