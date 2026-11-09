import Foundation
import Darwin

nonisolated enum SnapshotFileSafety {
    enum Failure: LocalizedError {
        case path, overlap, links, changed, extraction, rollback(String)
        var errorDescription: String? {
            switch self {
            case .path: String(localized: "Choose an ordinary project folder, not your home, a system root or a linked path.")
            case .overlap: String(localized: "The backup folder and project folder must be separate; neither can contain the other.")
            case .links: String(localized: "This backup contains links or special files. They cannot be copied or restored by the built-in backup tool.")
            case .changed: String(localized: "The backup or project path changed. Refresh before trying again.")
            case .extraction: String(localized: "The backup could not be unpacked safely. The project was not replaced.")
            case .rollback(let path): String(localized: "Restore failed. The original project is preserved at \(path).")
            }
        }
    }

    static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    static func directory(_ url: URL, allowMissing: Bool = false) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw Failure.path }
        let value = normalized(url)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in value.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if allowMissing && errno == ENOENT { return value }
                throw Failure.path
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                // Foundation canonicalizes /private/var back to /var. Permit
                // only these OS aliases with their exact system destinations.
                let name = current.lastPathComponent
                guard ["var", "tmp", "etc"].contains(name), current.path == "/" + name,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path),
                      target == "private/" + name || target == "/private/" + name else { throw Failure.path }
            } else if info.st_mode & S_IFMT != S_IFDIR { throw Failure.path }
        }
        return value
    }

    static func project(_ url: URL, storage: URL, allowMissing: Bool = false) throws -> URL {
        let value = try directory(url, allowMissing: allowMissing)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
        guard value.pathComponents.count > 2, !contains(value, home) else { throw Failure.path }
        let storage = normalized(storage)
        guard !contains(value, storage), !contains(storage, value) else { throw Failure.overlap }
        return value
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool { child.standardizedFileURL.pathComponents.starts(with: parent.standardizedFileURL.pathComponents) }

    static func regularFile(_ url: URL, scope: SiteFileAccess) throws -> URL {
        let value = try scope.checked(url)
        var info = stat()
        guard lstat(value.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.links }
        return value
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.path }
        return false
    }

    static func readFile(_ url: URL, scope: SiteFileAccess, maximum: Int) throws -> Data {
        let url = try regularFile(url, scope: scope)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.path }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.links }
        guard info.st_size <= maximum else { throw SnapshotArchive.Failure.limit }
        var data = Data()
        while let part = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= maximum else { throw SnapshotArchive.Failure.limit }
        }
        return data
    }

    private static func freezeArchive(_ source: URL, to target: URL) throws {
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw Failure.path }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(inputFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.links }
        let limit: UInt64 = 12 * 1024 * 1024 * 1024
        guard info.st_size >= 0, UInt64(info.st_size) <= limit else { throw SnapshotArchive.Failure.limit }
        let outputFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw Failure.path }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            guard UInt64(chunk.count) <= limit - copied else { throw SnapshotArchive.Failure.limit }
            copied += UInt64(chunk.count)
            try output.write(contentsOf: chunk)
        }
    }

    /// Copy a frozen, link-free tree for archive creation, excluding only the
    /// editor's reserved temporary suffix. Directories are not recursively copied.
    static func copyProject(_ source: URL, to destination: URL) throws {
        let scope = try SiteFileAccess(root: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var stack = [(scope.root, destination)]
        var directories = [(scope.root, destination)]
        var count = 1
        var bytes: UInt64 = 0
        while let (folder, target) = stack.popLast() {
            for entry in try scope.entries(in: folder) {
                count += 1
                guard count <= SnapshotArchive.maximumEntries else { throw SnapshotArchive.Failure.limit }
                _ = try scope.checked(entry.url)
                let copied = target.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: false)
                    stack.append((entry.url, copied))
                    directories.append((entry.url, copied))
                } else if entry.isRegular {
                    let size = UInt64(max(0, entry.size))
                    guard size <= SnapshotArchive.maximumBytes, bytes <= SnapshotArchive.maximumBytes - size else { throw SnapshotArchive.Failure.limit }
                    bytes += size
                    try FileManager.default.copyItem(at: entry.url, to: copied)
                } else { throw Failure.links }
            }
        }
        _ = try scope.checked(source)
        try validateTree(destination)
        for (original, copied) in directories.reversed() {
            _ = try scope.checked(original)
            guard copyfile(original.path, copied.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else { throw Failure.path }
        }
    }

    static func validateTree(_ root: URL) throws {
        _ = try directory(root)
        var traversalError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in traversalError = error; return false }) else { throw Failure.path }
        var bytes: UInt64 = 0, count = 0
        for case let url as URL in iterator {
            count += 1
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Failure.path }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { throw Failure.links }
            let size = type == S_IFREG ? UInt64(max(0, info.st_size)) : 0
            guard count <= SnapshotArchive.maximumEntries, size <= SnapshotArchive.maximumBytes,
                  bytes <= SnapshotArchive.maximumBytes - size else { throw SnapshotArchive.Failure.limit }
            bytes += size
        }
        if let traversalError { throw traversalError }
    }

    static func restoreSite(archive: URL, into target: URL, storage: URL,
                            move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) async throws -> URL? {
        let target = try project(target, storage: storage, allowMissing: true)
        let parent = target.deletingLastPathComponent()
        _ = try directory(parent, allowMissing: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentScope = try SiteFileAccess(root: parent)
        let work = parent.appendingPathComponent(".servermaster-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let workScope = try SiteFileAccess(root: work)
        defer {
            if let checked = try? workScope.checked(work) { try? FileManager.default.removeItem(at: checked) }
        }
        let frozen = work.appendingPathComponent("archive.zip")
        try await Task.detached { try freezeArchive(archive, to: frozen) }.value
        let contents = try await Task.detached { try SnapshotArchive.inspect(frozen) }.value
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
        let result = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", frozen.path, unpacked.path], timeout: 600)
        guard result.succeeded else { throw Failure.extraction }
        _ = try workScope.checked(unpacked)
        try await Task.detached { try validateTree(unpacked) }.value
        let roots = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        guard roots.allSatisfy({ $0.lastPathComponent == contents.rootName || $0.lastPathComponent == "__MACOSX" }) else { throw Failure.extraction }
        let incoming = unpacked.appendingPathComponent(contents.rootName, isDirectory: true)
        _ = try directory(incoming)
        _ = try parentScope.checked(parent)
        _ = try project(target, storage: storage, allowMissing: true)
        let existed = FileManager.default.fileExists(atPath: target.path)
        let previous = parent.appendingPathComponent(target.lastPathComponent + ".before-restore-" + UUID().uuidString, isDirectory: true)
        if existed { try move(target, previous) }
        do { try move(incoming, target) }
        catch {
            if existed {
                do { try move(previous, target) }
                catch { throw Failure.rollback(previous.path) }
            }
            throw error
        }
        return existed ? previous : nil
    }
}
