//
//  Version.swift
//  servermaster
//
//  The tool has its own version, separate from the app's.
//
//  They are separate because they can be separately wrong. The tool is a symlink
//  into whichever copy of the app installed it, and that copy can be replaced,
//  moved, or be one of two. When something behaves oddly the first question is
//  “which one am I actually running”, and a single shared version number cannot
//  answer it.
//
//  The build string follows the same scheme the app uses — host, the macOS it
//  was built against, its developer beta, and the target — with `cli` as the
//  target so a build string can never be mistaken for the app's.
//
//      arm . 27.0 . b6 . cli
//
//  Both are printed by `servermaster version`, and the app compares the two so
//  it can offer to relink when they drift apart.
//

import Foundation

enum CLIVersion {

    static let version = "1.0.0"
    static let build = "arm.27.0.b6.cli"

    /// The whole identity in one line, for logs and bug reports.
    static var full: String { "servermaster \(version) (\(build))" }

    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        #if canImport(Glibc)
        return "Linux glibc"
        #else
        return "Linux musl"
        #endif
        #else
        return "Unknown"
        #endif
    }

    static var payload: [String: Any] {
        ["tool": version, "build": build]
    }
}
