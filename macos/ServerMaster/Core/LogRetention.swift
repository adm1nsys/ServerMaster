import Foundation
import Darwin

/// Only closed, regular log files in this directory are eligible. Directory
/// descriptors keep cleanup anchored even if a path is renamed during a scan.
nonisolated enum LogRetention {
    struct Result: Sendable {
        var removed = 0
        var skippedActive = 0
        var failureCount = 0
        var problems: [String] = []
        var disabled = false

        fileprivate mutating func failed(_ path: String, code: Int32) {
            failureCount += 1
            if problems.count < 5 {
                problems.append("\(path): \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)")
            }
        }
    }

    static func clean(directory: URL, days: Int, activeFiles: Set<URL> = [], now: Date = Date()) -> Result {
        var result = Result()
        guard days > 0 else { result.disabled = true; return result }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno != ENOENT { result.failed(directory.path, code: errno) }
            return result
        }
        defer { Darwin.close(fd) }
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { result.failed(directory.path, code: errno); return result }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            result.failed(directory.path, code: code)
            return result
        }
        defer { closedir(stream) }
        let active = Set(activeFiles.map { $0.standardizedFileURL.path })
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { result.failed(directory.path, code: errno) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard (name as NSString).pathExtension.lowercased() == "log" else { continue }
            let url = directory.appendingPathComponent(name)
            if active.contains(url.standardizedFileURL.path) { result.skippedActive += 1; continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { result.failed(name, code: errno) }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG, modified(info) < cutoff else { continue }
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else {
                if errno != ENOENT { result.failed(name, code: errno) }
                continue
            }
            defer { Darwin.close(file) }
            // Every app writer holds an exclusive lock for its whole session.
            // This also protects other windows/processes after the snapshot.
            guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { result.skippedActive += 1 }
                else { result.failed(name, code: errno) }
                continue
            }
            var opened = stat()
            guard fstat(file, &opened) == 0 else { result.failed(name, code: errno); continue }
            guard sameFile(opened, info), opened.st_mode & S_IFMT == S_IFREG,
                  modified(opened) < cutoff else { continue }
            var current = stat()
            guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { result.failed(name, code: errno) }
                continue
            }
            guard sameFile(current, opened), current.st_mode & S_IFMT == S_IFREG,
                  modified(current) < cutoff else { continue }
            // unlinkat never traverses/removes a substituted directory.
            if unlinkat(fd, name, 0) == 0 { result.removed += 1 }
            else if errno != ENOENT { result.failed(name, code: errno) }
        }
        return result
    }

    private static func modified(_ value: stat) -> Double {
        Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
