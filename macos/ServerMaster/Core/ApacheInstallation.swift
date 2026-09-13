//
//  ApacheInstallation.swift
//  ServerMaster
//
//  Which Apache to run, decided once so the binary, its modules, its ServerRoot
//  and its mime.types can never come from different installations.
//
//  Homebrew's copy is preferred over the one macOS ships, and the reason is not
//  taste. A site kept in Documents, Desktop or Downloads is behind macOS privacy
//  protection. A binary we launch ourselves inherits this app's permission, but
//  /usr/sbin/httpd is a platform binary that macOS judges on its own — and it is
//  refused. The visible result is a page that renders while every stylesheet and
//  script comes back 403, which reads like a broken config and is not one.
//
//  Verified both ways on the same folder: Homebrew's httpd answered 200, the
//  system one logged “AH00132: file permissions deny server access”.
//

import Foundation

nonisolated struct ApacheInstallation: Sendable, Equatable {

    var binary: String
    var serverRoot: String
    var modulesDirectory: String
    var mimeTypesPath: String
    /// The copy macOS ships, which cannot read privacy-protected folders.
    var isSystemCopy: Bool

    // MARK: - Finding one

    private static let candidates: [(binary: String, root: String, modules: String, mime: String, system: Bool)] = [
        ("/opt/homebrew/opt/httpd/bin/httpd", "/opt/homebrew/opt/httpd",
         "/opt/homebrew/opt/httpd/lib/httpd/modules", "/opt/homebrew/etc/httpd/mime.types", false),
        ("/usr/local/opt/httpd/bin/httpd", "/usr/local/opt/httpd",
         "/usr/local/opt/httpd/lib/httpd/modules", "/usr/local/etc/httpd/mime.types", false),
        ("/usr/sbin/httpd", "/usr", "/usr/libexec/apache2", "/etc/apache2/mime.types", true)
    ]

    /// The installation to use, Homebrew first.
    static func resolve() -> ApacheInstallation? {
        let fm = FileManager.default
        for candidate in candidates
        where fm.isExecutableFile(atPath: candidate.binary)
            && fm.fileExists(atPath: candidate.modules) {
            return ApacheInstallation(binary: candidate.binary,
                                      serverRoot: candidate.root,
                                      modulesDirectory: candidate.modules,
                                      mimeTypesPath: candidate.mime,
                                      isSystemCopy: candidate.system)
        }
        return nil
    }

    /// Whether a Homebrew copy is installed at all.
    static var homebrewAvailable: Bool {
        resolve()?.isSystemCopy == false
    }

    // MARK: - Privacy-protected folders

    /// Folders macOS keeps behind a privacy prompt. A site kept in one of these
    /// cannot be served by the system Apache, whatever the file permissions say.
    static func isProtected(_ path: String) -> Bool {
        let expanded = AppPaths.expand(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guarded = ["Documents", "Desktop", "Downloads",
                       "Library/Mobile Documents", "Library/CloudStorage"]
        return guarded.contains { folder in
            let root = (home as NSString).appendingPathComponent(folder)
            return expanded == root || expanded.hasPrefix(root + "/")
        }
    }

    /// The warning to show before a start that is going to fail this way, or nil
    /// when the combination is fine.
    static func privacyWarning(forRoot path: String) -> String? {
        guard isProtected(path) else { return nil }
        guard let installation = resolve(), installation.isSystemCopy else { return nil }
        return String(localized: """
            This folder is in a privacy-protected location, and the Apache that comes with \
            macOS is not allowed to read it — pages will load while every stylesheet and \
            script returns 403. Install Apache through Homebrew (brew install httpd) or move \
            the project somewhere outside Documents, Desktop and Downloads.
            """)
    }
}
