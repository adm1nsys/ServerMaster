import Foundation
import CryptoKit
import Darwin

/// Bounded text I/O shared by the site and configuration editors.
/// The original bytes (including BOM) are the conflict baseline, not rendered text.
nonisolated struct TextFileDocument {
    static let maximumBytes = 4_000_000

    enum Format: Equatable, Sendable {
        case utf8(bom: Bool), utf16LE, utf16BE

        var label: String {
            switch self {
            case .utf8(false): "UTF-8"
            case .utf8(true): "UTF-8 BOM"
            case .utf16LE: "UTF-16 LE"
            case .utf16BE: "UTF-16 BE"
            }
        }

        func encode(_ text: String) throws -> Data {
            let encoding: String.Encoding
            let prefix: [UInt8]
            switch self {
            case .utf8(let bom): encoding = .utf8; prefix = bom ? [0xEF, 0xBB, 0xBF] : []
            case .utf16LE: encoding = .utf16LittleEndian; prefix = [0xFF, 0xFE]
            case .utf16BE: encoding = .utf16BigEndian; prefix = [0xFE, 0xFF]
            }
            guard let bytes = text.data(using: encoding, allowLossyConversion: false) else { throw Failure.notText }
            let result = Data(prefix) + bytes
            guard result.count <= maximumBytes else { throw Failure.tooLarge }
            return result
        }
    }

    enum Failure: LocalizedError {
        case tooLarge, notText, unsupportedEncoding, changed, notRegular

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "This file is too large for the built-in editor (4 MB maximum).")
            case .notText: String(localized: "This is not a supported text file. Open it in an external editor.")
            case .unsupportedEncoding: String(localized: "Use UTF-8 or UTF-16 with a BOM. Open other encodings in an external editor; the file has not been converted.")
            case .changed: String(localized: "This file changed outside ServerMaster. Your edits were not saved. Copy them or reload the file before saving.")
            case .notRegular: String(localized: "The built-in editor only opens regular files, not links or special files. Use an external editor.")
            }
        }
    }

    let url: URL
    let format: Format
    private(set) var text: String
    private var digest: SHA256.Digest
    private var identity: Identity
    private let access: SiteFileAccess?

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Bytes {
        let data: Data
        let identity: Identity
        let permissions: mode_t
    }

    static func load(_ url: URL, access: SiteFileAccess? = nil) throws -> TextFileDocument {
        let target = try access?.checked(url) ?? url
        let bytes = try read(target)
        let data = bytes.data
        let format: Format
        let encoding: String.Encoding
        let offset: Int
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format = .utf8(bom: true); encoding = .utf8; offset = 3
        } else if data.starts(with: [0xFF, 0xFE]) {
            format = .utf16LE; encoding = .utf16LittleEndian; offset = 2
        } else if data.starts(with: [0xFE, 0xFF]) {
            format = .utf16BE; encoding = .utf16BigEndian; offset = 2
        } else {
            format = .utf8(bom: false); encoding = .utf8; offset = 0
        }
        guard let text = String(data: data.dropFirst(offset), encoding: encoding) else { throw Failure.unsupportedEncoding }
        try validate(text)
        // Foundation must not repair malformed UTF-16 silently.
        guard try format.encode(text) == data else { throw Failure.unsupportedEncoding }
        if let access { _ = try access.checked(target) }
        return .init(url: target, format: format, text: text, digest: SHA256.hash(data: data), identity: bytes.identity, access: access)
    }

    mutating func save(_ contents: String) throws {
        try Self.validate(contents)
        let encoded = try format.encode(contents)
        var coordinationError: NSError?
        var outcome: Result<Bytes, Error>?
        let expectedDigest = digest
        let expectedIdentity = identity
        let boundary = access
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            outcome = Result {
                if let boundary { _ = try boundary.checked(target) }
                let before = try Self.read(target)
                guard before.identity == expectedIdentity, SHA256.hash(data: before.data) == expectedDigest else { throw Failure.changed }
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).servermaster-tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Self.create(encoded, at: temporary)
                try FileManager.default.setAttributes([.posixPermissions: Int(before.permissions & 0o777)], ofItemAtPath: temporary.path)
                // Check again after preparing the replacement, immediately before swapping.
                let current = try Self.read(target)
                guard current.identity == expectedIdentity, SHA256.hash(data: current.data) == expectedDigest else { throw Failure.changed }
                if let boundary { _ = try boundary.checked(target) }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                let saved = try Self.read(target)
                guard saved.data == encoded else { throw Failure.changed }
                return saved
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        let saved = try outcome.get()
        digest = SHA256.hash(data: saved.data)
        identity = saved.identity
        text = contents
    }

    /// Adoption is save-as: a unique new file, never replacement of another config.
    func writeCopy(_ contents: String, to target: URL) throws {
        try Self.validate(contents)
        try Self.create(format.encode(contents), at: target)
    }

    private static func validate(_ text: String) throws {
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }) else { throw Failure.notText }
    }

    private static func read(_ url: URL) throws -> Bytes {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw Failure.notRegular }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
        guard metadata.st_size <= maximumBytes else { throw Failure.tooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw Failure.tooLarge }
        }
        return .init(data: data, identity: .init(device: metadata.st_dev, inode: metadata.st_ino), permissions: metadata.st_mode)
    }

    private static func create(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
