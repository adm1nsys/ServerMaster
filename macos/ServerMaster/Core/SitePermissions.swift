//
//  SitePermissions.swift
//  ServerMaster
//
//  File permissions on the site are one of the main reasons a CMS fails
//  with no clear explanation. Check and fix them explicitly.
//

import Foundation
import Darwin

nonisolated struct PermissionProblem: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case notWritable        // no write permission
        case foreignOwner       // the owner is not the current user
        case missing
        case unreadable

        var title: String {
            switch self {
            case .notWritable:  return String(localized: "not writable")
            case .foreignOwner: return String(localized: "foreign owner")
            case .missing: return String(localized: "path not found")
            case .unreadable: return String(localized: "could not read this path")
            }
        }
    }

    var id: String { path }
    var path: String
    var kind: Kind
    var isDirectory: Bool
    var owner: String
}

nonisolated struct PermissionReport: Sendable {
    var checkedCount: Int = 0
    var problems: [PermissionProblem] = []
    /// The check stopped before covering everything — the folder is too large.
    var truncated: Bool = false

    var skippedLinks = 0
    var isClean: Bool { checkedCount > 0 && problems.isEmpty && !truncated }
    var canFixPermissions: Bool { problems.contains { $0.kind != .missing } }
    var needsAdmin: Bool { problems.contains { $0.kind == .foreignOwner } }
}

nonisolated enum SitePermissions {

    /// Folders a CMS must be able to write to. These are checked first.
    static let importantDirectories = [
        "administrator/cache", "administrator/logs", "cache", "images",
        "logs", "tmp", "media", "plugins", "templates", "modules",
        "wp-content", "wp-content/uploads", "storage", "bootstrap/cache"
    ]

    /// Walk the tree looking for anything that would stop the site working.
    /// A full walk of a large site is slow, so the number of files is capped.
    static func check(root: String, limit: Int = 4000) -> PermissionReport {
        var report = PermissionReport()
        let expanded = AppPaths.expand(root)
        func problem(_ path: String, _ kind: PermissionProblem.Kind, directory: Bool = false, owner: uid_t = getuid()) {
            // One row per path, including failures discovered during enumeration.
            report.problems.removeAll { $0.path == path }
            report.problems.append(PermissionProblem(path: path, kind: kind, isDirectory: directory,
                                                     owner: owner == getuid() ? NSUserName() : String(owner)))
        }
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !expanded.contains("\0") else {
            problem(expanded, .missing)
            return report
        }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let rootFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            problem(path, errno == ENOENT ? .missing : .unreadable, directory: true)
            return report
        }
        defer { Darwin.close(rootFD) }

        func visit(_ fd: Int32, path: String, relative: String) {
            guard report.checkedCount < max(0, limit) else { report.truncated = true; return }
            report.checkedCount += 1
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { problem(path, .unreadable, directory: true); return }
            if faccessat(fd, ".", R_OK | X_OK, 0) != 0 {
                problem(path, .unreadable, directory: true, owner: metadata.st_uid)
                return
            }
            if metadata.st_uid != getuid() { problem(path, .foreignOwner, directory: true, owner: metadata.st_uid) }
            else if faccessat(fd, ".", W_OK, 0) != 0 { problem(path, .notWritable, directory: true) }

            let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { problem(path, .unreadable, directory: true); return }
            guard let stream = fdopendir(duplicate) else {
                Darwin.close(duplicate)
                problem(path, .unreadable, directory: true)
                return
            }
            defer { closedir(stream) }
            let prefix = relative.isEmpty ? "" : relative + "/"
            let priority = Set(importantDirectories.filter { $0.hasPrefix(prefix) }.map {
                String($0.dropFirst(prefix.count).split(separator: "/").first ?? "")
            })
            // Reserve important paths before bounded enumeration, even if the
            // directory contains more entries than the remaining scan budget.
            var names = priority.filter { name in
                var info = stat()
                return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            }.sorted()
            let reserved = Set(names)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { problem(path, .unreadable, directory: true) }
                    break
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                }
                guard let name, name != ".", name != "..", !name.hasPrefix(".git"),
                      !reserved.contains(name) else { continue }
                names.append(name)
                if names.count > max(0, limit - report.checkedCount) {
                    report.truncated = true
                    break
                }
            }
            names.sort {
                let first = priority.contains($0), second = priority.contains($1)
                return first == second ? $0 < $1 : first
            }
            for name in names {
                guard report.checkedCount < max(0, limit) else { report.truncated = true; break }
                let childPath = (path as NSString).appendingPathComponent(name)
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    report.checkedCount += 1
                    problem(childPath, errno == ENOENT ? .missing : .unreadable)
                    continue
                }
                if info.st_mode & S_IFMT == S_IFLNK { report.skippedLinks += 1; continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else {
                        report.checkedCount += 1
                        problem(childPath, errno == ENOENT ? .missing : .unreadable, directory: true, owner: info.st_uid)
                        continue
                    }
                    defer { Darwin.close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0,
                          opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                        report.checkedCount += 1
                        problem(childPath, .unreadable, directory: true)
                        continue
                    }
                    visit(child, path: childPath, relative: prefix + name)
                } else if info.st_mode & S_IFMT == S_IFREG {
                    report.checkedCount += 1
                    if faccessat(fd, name, R_OK, 0) != 0 { problem(childPath, .unreadable, owner: info.st_uid) }
                    else if info.st_uid != getuid() { problem(childPath, .foreignOwner, owner: info.st_uid) }
                    else if faccessat(fd, name, W_OK, 0) != 0 { problem(childPath, .notWritable) }
                }
            }
        }
        visit(rootFD, path: path, relative: "")
        return report
    }

    /// Fixes permissions on our own files: rwx for directories, rw for files.
    /// The X flag of chmod sets the execute bit on directories only — exactly what is needed.
    static func fix(root: String) async -> CommandResult {
        let expanded = AppPaths.expand(root)
        return await ProcessRunner.run("/bin/chmod",
                                       ["-R", "u+rwX", expanded],
                                       timeout: 300)
    }

    /// Hands ownership back to the current user — needs an administrator password.
    static func takeOwnership(root: String) async -> CommandResult {
        let expanded = AppPaths.expand(root)
        let command = "/usr/sbin/chown -R \(getuid()):\(getgid()) \(ProcessRunner.shellQuote(expanded))"
            + " && /bin/chmod -R u+rwX \(ProcessRunner.shellQuote(expanded))"
        return await ProcessRunner.runAsAdmin(
            command,
            prompt: String(localized: "ServerMaster wants to give the site files back to you."))
    }
}
