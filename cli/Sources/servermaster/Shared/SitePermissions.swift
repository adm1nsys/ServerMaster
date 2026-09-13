//
//  SitePermissions.swift
//  ServerMaster
//
//  File permissions on the site are one of the main reasons a CMS fails
//  with no clear explanation. Check and fix them explicitly.
//

import Foundation

nonisolated struct PermissionProblem: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case notWritable        // no write permission
        case foreignOwner       // the owner is not the current user

        var title: String {
            switch self {
            case .notWritable:  return String(localized: "not writable")
            case .foreignOwner: return String(localized: "foreign owner")
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

    var isClean: Bool { problems.isEmpty }
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
        let fm = FileManager.default
        let expanded = AppPaths.expand(root)

        guard fm.fileExists(atPath: expanded) else { return report }

        let uid = getuid()
        var queue = [expanded]

        // Important subfolders go to the front of the queue — those will definitely be checked.
        for name in importantDirectories {
            let path = (expanded as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) { queue.append(path) }
        }

        var visited = Set<String>()

        while let path = queue.popLast() {
            guard visited.insert(path).inserted else { continue }
            if report.checkedCount >= limit {
                report.truncated = true
                break
            }
            report.checkedCount += 1

            guard let attributes = try? fm.attributesOfItem(atPath: path) else { continue }
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? uid
            let ownerName = (attributes[.ownerAccountName] as? String) ?? String(ownerID)
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: path, isDirectory: &isDirectory)

            if ownerID != uid {
                report.problems.append(PermissionProblem(path: path, kind: .foreignOwner,
                                                         isDirectory: isDirectory.boolValue,
                                                         owner: ownerName))
            } else if !fm.isWritableFile(atPath: path) {
                report.problems.append(PermissionProblem(path: path, kind: .notWritable,
                                                         isDirectory: isDirectory.boolValue,
                                                         owner: ownerName))
            }

            // Descend only into directories, and no further than the important places.
            if isDirectory.boolValue,
               let children = try? fm.contentsOfDirectory(atPath: path) {
                for child in children where !child.hasPrefix(".git") {
                    queue.append((path as NSString).appendingPathComponent(child))
                }
            }
        }

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
