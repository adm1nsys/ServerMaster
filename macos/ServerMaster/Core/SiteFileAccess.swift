import Foundation
import Darwin

/// The user-selected root is resolved once. Links inside it are listed but never
/// traversed by built-in file operations; they can be opened explicitly in Finder.
nonisolated struct SiteFileAccess: Sendable {
    struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { url.path }
        let url: URL
        let name: String
        let identity: Identity
        let isDirectory: Bool
        let isLink: Bool
        let isRegular: Bool
        let size: Int64
        let modified: Date
        let isHidden: Bool
        let isConfig: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case outside, linked, changed, invalidName, exists
        case rollback(String)
        var errorDescription: String? {
            switch self {
            case .outside: String(localized: "Choose a file or folder inside this project's root.")
            case .linked: String(localized: "This path passes through a symbolic link. Open it in Finder or an external editor.")
            case .changed: String(localized: "The project folder or selected item changed. Refresh the file list before continuing.")
            case .invalidName: String(localized: "Enter one file name, without a slash, a NUL character, or dot-directory names.")
            case .exists: String(localized: "A file or folder with that name already exists. Nothing was replaced.")
            case .rollback(let path): String(localized: "Could not finish renaming. The original item is preserved at \(path).")
            }
        }
    }

    let root: URL
    private let rootIdentity: Identity

    init(root: URL) throws {
        guard root.isFileURL, !root.path.contains("\0") else { throw Failure.outside }
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let metadata = try Self.metadata(resolved)
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw Failure.outside }
        self.root = resolved
        rootIdentity = Self.identity(metadata)
    }

    func checked(_ url: URL, allowLeafLink: Bool = false) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw Failure.outside }
        let candidate = url.standardizedFileURL
        let components = candidate.pathComponents
        let base = root.pathComponents
        guard components.starts(with: base) else { throw Failure.outside }
        let metadata = try Self.metadata(root)
        guard metadata.st_mode & S_IFMT == S_IFDIR, Self.identity(metadata) == rootIdentity else { throw Failure.changed }
        var current = root
        for (index, component) in components.dropFirst(base.count).enumerated() {
            current.appendPathComponent(component)
            let info = try Self.metadata(current)
            if info.st_mode & S_IFMT == S_IFLNK {
                guard allowLeafLink && index == components.count - base.count - 1 else { throw Failure.linked }
            }
        }
        return candidate
    }

    func entries(in folder: URL) throws -> [Entry] {
        let folder = try checked(folder)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let result = try urls.filter { !Self.isEditorTemporary($0.lastPathComponent) }.map { url in
            let info = try Self.metadata(url)
            return Entry(url: url, name: url.lastPathComponent, identity: Self.identity(info),
                         isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                         isLink: info.st_mode & S_IFMT == S_IFLNK,
                         isRegular: info.st_mode & S_IFMT == S_IFREG,
                         size: Int64(info.st_size),
                         modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                         isHidden: url.lastPathComponent.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0,
                         isConfig: Self.configNames.contains(url.lastPathComponent.lowercased()))
        }
        _ = try checked(folder)
        return result.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    func rename(_ entry: Entry, to name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Failure.invalidName }
        let source = try checked(entry.url)
        guard source != root else { throw Failure.outside }
        guard Self.identity(try Self.metadata(source)) == entry.identity else { throw Failure.changed }
        if name == entry.name { return source }
        let parent = try checked(source.deletingLastPathComponent())
        let target = parent.appendingPathComponent(name)
        var targetInfo = stat()
        if lstat(target.path, &targetInfo) == 0 {
            guard name.caseInsensitiveCompare(entry.name) == .orderedSame,
                  Self.identity(targetInfo) == entry.identity else { throw Failure.exists }
            // Case-only changes on a case-insensitive volume need an intermediate name.
            let pending = parent.appendingPathComponent(".servermaster-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: source, to: pending)
            do { try FileManager.default.moveItem(at: pending, to: target) }
            catch {
                do { try FileManager.default.moveItem(at: pending, to: source) }
                catch { throw Failure.rollback(pending.path) }
                throw error
            }
        } else {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try FileManager.default.moveItem(at: source, to: target)
        }
        return target
    }

    static func isEditorTemporary(_ name: String) -> Bool { name.lowercased().hasSuffix(".servermaster-tmp") }

    private static let configNames: Set<String> = [
        "configuration.php", "wp-config.php", "settings.php", "config.php", "nginx.conf", "caddyfile",
        "package.json", "composer.json", "docker-compose.yml", "index.php", "web.config", "php.ini",
        "htaccess.txt", "servermaster-demo.md"
    ]

    private static func identity(_ info: stat) -> Identity { .init(device: info.st_dev, inode: info.st_ino) }
    private static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info
    }
}
