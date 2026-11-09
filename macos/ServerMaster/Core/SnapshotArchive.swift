import Foundation
import Darwin
import zlib

/// Validates the ZIP container and streams every payload before handing it to
/// ditto. Names from both headers agree; unlisted local records are not accepted.
nonisolated enum SnapshotArchive {
    static let maximumBytes: UInt64 = 10 * 1024 * 1024 * 1024
    static let maximumEntries = 200_000

    struct Contents: Sendable { let rootName: String }
    enum Failure: LocalizedError {
        case invalid, unsafe, limit
        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "The backup ZIP is damaged or uses an unsupported format.")
            case .unsafe: String(localized: "The backup ZIP contains unsafe paths, links or conflicting names.")
            case .limit: String(localized: "The backup exceeds the restore limit (10 GB / 200,000 entries).")
            }
        }
    }

    static func inspect(_ url: URL) throws -> Contents {
        let reader = try Reader(url)
        let tailSize = Int(min(reader.length, 65_557))
        guard tailSize >= 22 else { throw Failure.invalid }
        let tailOffset = reader.length - UInt64(tailSize)
        let tail = try reader.read(tailOffset, tailSize)
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.number($0, 4) == 0x06054b50 && $0 + 22 + Int(tail.number($0 + 20, 2)) == tail.count
        }) else { throw Failure.invalid }
        guard tail.number(end + 4, 2) == 0, tail.number(end + 6, 2) == 0 else { throw Failure.invalid }
        var count = tail.number(end + 10, 2)
        var size = tail.number(end + 12, 4)
        var offset = tail.number(end + 16, 4)
        var boundary = tailOffset + UInt64(end)
        if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
            guard boundary >= 20 else { throw Failure.invalid }
            let locator = try reader.read(boundary - 20, 20)
            guard locator.number(0, 4) == 0x07064b50, locator.number(4, 4) == 0, locator.number(16, 4) == 1 else { throw Failure.invalid }
            let position = locator.number(8, 8)
            let record = try reader.read(position, 56)
            guard record.number(0, 4) == 0x06064b50, record.number(4, 8) >= 44,
                  position <= boundary - 20, boundary - 20 - position >= 56,
                  record.number(4, 8) <= boundary - 20 - position - 12,
                  record.number(16, 4) == 0, record.number(20, 4) == 0,
                  record.number(24, 8) == record.number(32, 8) else { throw Failure.invalid }
            count = record.number(32, 8); size = record.number(40, 8); offset = record.number(48, 8)
            boundary = position
        } else if tail.number(end + 8, 2) != count { throw Failure.invalid }
        guard count > 0 else { throw Failure.invalid }
        guard count <= maximumEntries, size <= 64 * 1024 * 1024 else { throw Failure.limit }
        guard offset <= boundary, size == boundary - offset else { throw Failure.invalid }
        let directory = try reader.read(offset, Int(size))
        var cursor = 0
        var total: UInt64 = 0
        var roots = Set<String>()
        var paths: [String: Bool] = [:]
        var parents = Set<String>()
        var ranges: [(UInt64, UInt64)] = []
        var metadataPaths: [[String]] = []
        for _ in 0..<Int(count) {
            guard cursor <= directory.count - 46, directory.number(cursor, 4) == 0x02014b50 else { throw Failure.invalid }
            let flags = directory.number(cursor + 8, 2), method = directory.number(cursor + 10, 2)
            guard flags & ~UInt64(0x080e) == 0, method == 0 || method == 8 else { throw Failure.invalid }
            let nameSize = Int(directory.number(cursor + 28, 2)), extraSize = Int(directory.number(cursor + 30, 2)), commentSize = Int(directory.number(cursor + 32, 2))
            let end = cursor + 46 + nameSize + extraSize + commentSize
            guard end <= directory.count else { throw Failure.invalid }
            let rawName = directory.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: rawName, encoding: .utf8) else { throw Failure.invalid }
            let parts = try components(name)
            let extras = try extraFields(directory.subdata(in: cursor + 46 + nameSize..<cursor + 46 + nameSize + extraSize), name: rawName)
            var unpacked = directory.number(cursor + 24, 4), packed = directory.number(cursor + 20, 4), localOffset = directory.number(cursor + 42, 4)
            var disk = directory.number(cursor + 34, 2)
            if unpacked == 0xffffffff || packed == 0xffffffff || localOffset == 0xffffffff || disk == 0xffff {
                guard let zip64 = extras[1] else { throw Failure.invalid }
                var index = 0
                func next(_ bytes: Int) throws -> UInt64 {
                    guard index + bytes <= zip64.count else { throw Failure.invalid }
                    defer { index += bytes }
                    return zip64.number(index, bytes)
                }
                if unpacked == 0xffffffff { unpacked = try next(8) }
                if packed == 0xffffffff { packed = try next(8) }
                if localOffset == 0xffffffff { localOffset = try next(8) }
                if disk == 0xffff { disk = try next(4) }
            }
            guard disk == 0, unpacked <= maximumBytes, total <= maximumBytes - unpacked else { throw Failure.limit }
            total += unpacked
            let mode = (directory.number(cursor + 38, 4) >> 16) & 0xf000
            guard mode == 0 || mode == 0x4000 || mode == 0x8000 else { throw Failure.unsafe }
            let isDirectory = mode == 0x4000 || name.hasSuffix("/")
            guard !isDirectory || unpacked == 0 else { throw Failure.invalid }
            let keyParts = parts.map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
            let key = keyParts.joined(separator: "/")
            guard paths[key] == nil, isDirectory || !parents.contains(key) else { throw Failure.unsafe }
            for depth in 1..<keyParts.count {
                let parent = keyParts.prefix(depth).joined(separator: "/")
                guard paths[parent] != false else { throw Failure.unsafe }
                parents.insert(parent)
            }
            paths[key] = isDirectory
            if parts[0] == "__MACOSX" { metadataPaths.append(parts) }
            else {
                guard parts.count > 1 || isDirectory else { throw Failure.unsafe }
                roots.insert(parts[0])
            }
            let local = try reader.read(localOffset, 30)
            guard local.number(0, 4) == 0x04034b50, local.number(6, 2) == flags, local.number(8, 2) == method else { throw Failure.invalid }
            let localNameSize = Int(local.number(26, 2)), localExtraSize = Int(local.number(28, 2))
            guard try reader.read(localOffset + 30, localNameSize) == rawName else { throw Failure.unsafe }
            let localExtra = try extraFields(reader.read(localOffset + 30 + UInt64(localNameSize), localExtraSize), name: rawName)
            let payload = localOffset + 30 + UInt64(localNameSize + localExtraSize)
            guard payload <= offset, packed <= offset - payload else { throw Failure.invalid }
            let checksum = directory.number(cursor + 16, 4)
            try reader.verify(payload, compressed: packed, uncompressed: unpacked, method: method, crc: checksum)
            var localEnd = payload + packed
            if flags & 8 != 0 {
                let signature = try reader.read(localEnd, 4)
                if signature.number(0, 4) == 0x08074b50 { localEnd += 4 }
                let wide = localExtra[1] != nil
                let descriptor = try reader.read(localEnd, wide ? 20 : 12)
                guard descriptor.number(0, 4) == checksum,
                      descriptor.number(4, wide ? 8 : 4) == packed,
                      descriptor.number(wide ? 12 : 8, wide ? 8 : 4) == unpacked else { throw Failure.invalid }
                localEnd += wide ? 20 : 12
            } else {
                guard local.number(14, 4) == checksum else { throw Failure.invalid }
                if local.number(18, 4) != 0xffffffff { guard local.number(18, 4) == packed else { throw Failure.invalid } }
                if local.number(22, 4) != 0xffffffff { guard local.number(22, 4) == unpacked else { throw Failure.invalid } }
            }
            ranges.append((localOffset, localEnd))
            cursor = end
        }
        guard cursor == directory.count, roots.count == 1, let root = roots.first, root.lowercased() != "__macosx" else { throw Failure.unsafe }
        for parts in metadataPaths where parts.count > 1 {
            guard parts[1] == root || parts.count == 2 && parts[1] == "._" + root else { throw Failure.unsafe }
        }
        var previousEnd: UInt64 = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 == previousEnd, range.1 <= offset else { throw Failure.invalid }
            previousEnd = range.1
        }
        guard previousEnd == offset else { throw Failure.invalid }
        return Contents(rootName: root)
    }

    static func components(_ name: String) throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { throw Failure.unsafe }
        let value = name.hasSuffix("/") ? String(name.dropLast()) : name
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw Failure.unsafe }
        return parts
    }

    private static func extraFields(_ data: Data, name: Data) throws -> [UInt64: Data] {
        var result: [UInt64: Data] = [:]
        var offset = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { throw Failure.invalid }
            let tag = data.number(offset, 2), size = Int(data.number(offset + 2, 2))
            guard offset + 4 + size <= data.count, result[tag] == nil else { throw Failure.invalid }
            // Other extensions can encode alternate names, links, or file types.
            guard [1, 0x000a, 0x5455, 0x5855, 0x7875, 0x7075, 0x6375].contains(tag) else { throw Failure.invalid }
            let value = data.subdata(in: offset + 4..<offset + 4 + size)
            if tag == 0x7075 {
                guard value.count >= 5, value[0] == 1, value.dropFirst(5) == name else { throw Failure.unsafe }
            }
            result[tag] = value
            offset += 4 + size
        }
        return result
    }

    private final class Reader {
        let handle: FileHandle
        let length: UInt64
        init(_ url: URL) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.unsafe }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw Failure.unsafe }
            length = UInt64(info.st_size)
            guard length <= 12 * 1024 * 1024 * 1024 else { throw Failure.limit }
        }
        deinit { try? handle.close() }
        func read(_ offset: UInt64, _ size: Int) throws -> Data {
            guard size >= 0, offset <= length, UInt64(size) <= length - offset else { throw Failure.invalid }
            try handle.seek(toOffset: offset)
            var data = Data()
            while data.count < size {
                guard let chunk = try handle.read(upToCount: size - data.count), !chunk.isEmpty else { throw Failure.invalid }
                data.append(chunk)
            }
            return data
        }
        func verify(_ offset: UInt64, compressed: UInt64, uncompressed: UInt64, method: UInt64, crc: UInt64) throws {
            var position: UInt64 = 0, produced: UInt64 = 0
            var checksum = crc32(0, nil, 0)
            var stream = z_stream()
            var ended = false
            if method == 8 {
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
            }
            defer { if method == 8 { inflateEnd(&stream) } }
            var output = [UInt8](repeating: 0, count: 65_536)
            while position < compressed {
                let chunk = try read(offset + position, Int(min(65_536, compressed - position)))
                position += UInt64(chunk.count)
                try chunk.withUnsafeBytes { raw in
                    let input = raw.bindMemory(to: Bytef.self).baseAddress!
                    if method == 0 {
                        produced += UInt64(chunk.count)
                        checksum = crc32(checksum, input, uInt(chunk.count))
                    } else {
                        stream.next_in = UnsafeMutablePointer(mutating: input); stream.avail_in = uInt(chunk.count)
                        repeat {
                            let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                                stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                                let result = inflate(&stream, Z_NO_FLUSH)
                                let count = buffer.count - Int(stream.avail_out)
                                produced += UInt64(count)
                                checksum = crc32(checksum, buffer.baseAddress, uInt(count))
                                return result
                            }
                            guard produced <= uncompressed else { throw Failure.limit }
                            if status == Z_STREAM_END {
                                guard stream.avail_in == 0, position == compressed else { throw Failure.invalid }
                                ended = true
                                break
                            }
                            guard status == Z_OK else { throw Failure.invalid }
                        } while stream.avail_in > 0 || stream.avail_out == 0
                    }
                }
                guard produced <= uncompressed else { throw Failure.limit }
            }
            guard (method == 0 || ended), produced == uncompressed, UInt64(checksum) == crc else { throw Failure.invalid }
        }
    }
}

private extension Data {
    nonisolated func number(_ offset: Int, _ bytes: Int) -> UInt64 {
        (0..<bytes).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
}
