//
//  InstallCommands.swift
//  servermaster
//
//  Putting this command on the PATH, and taking it off again.
//
//  The app can do this too, from its settings. This exists for the other half of
//  the story: the tool is meant to work as an alternative to the app, not only
//  alongside it, and someone who has only downloaded the binary has no settings
//  window to click.
//

import Foundation

extension Commands {

    /// Where the links go.
    ///
    /// Two directories, because “on the PATH” means different things on
    /// different Macs. /usr/local/bin is on the default PATH of every shell
    /// macOS ships. A shell set up by Homebrew on Apple Silicon puts
    /// /opt/homebrew/bin *ahead* of it, so a link only in /usr/local/bin loses
    /// to anything older sitting in the Homebrew folder — which is the version
    /// of this problem that is hard to notice. That one is linked too when it
    /// exists, and never created: the folder is Homebrew's to make.
    static var installDirectories: [String] {
        var directories = ["/usr/local/bin"]
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
            directories.append("/opt/homebrew/bin")
        }
        return directories
    }

    static var installPaths: [String] { installDirectories.map { $0 + "/servermaster" } }

    /// What the links should point at.
    ///
    /// The app's copy wins when the app is installed, so updating the app
    /// updates the command and the two can never disagree about what a profile
    /// means. With no app, this binary points at itself — which is the case the
    /// app's own installer cannot cover.
    static func linkSource() -> (path: String, fromApp: Bool)? {
        let bundled = [
            "/Applications/ServerMaster.app",
            NSHomeDirectory() + "/Applications/ServerMaster.app"
        ].map { $0 + "/Contents/Helpers/servermaster" }

        for path in bundled where FileManager.default.isExecutableFile(atPath: path) {
            return (path, true)
        }
        guard let own = Bundle.main.executablePath else { return nil }
        return (URL(fileURLWithPath: own).resolvingSymlinksInPath().path, false)
    }

    func install() async -> ExitCode {
        guard let source = Self.linkSource() else {
            printer.error("Could not work out where this command lives.")
            return .failed
        }

        var linked: [String] = []
        var blocked: [String] = []
        for path in Self.installPaths {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // Replacing an existing link is the normal case, not an error: this
            // is how the command is pointed at a new copy.
            try? FileManager.default.removeItem(atPath: path)
            do {
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: source.path)
                linked.append(path)
            } catch {
                blocked.append(path)
            }
        }

        if options.json {
            printer.json(["linked": linked, "blocked": blocked,
                          "source": source.path, "fromApp": source.fromApp])
            return blocked.isEmpty ? .ok : .failed
        }

        if !linked.isEmpty {
            printer.line("Linked \(linked.joined(separator: " and ")) → \(source.path)")
            printer.line(source.fromApp
                        ? "Pointing at the app's copy, so updating the app updates this command."
                        : "Pointing at this binary. Install the app and run this again to follow it instead.")
        }
        guard blocked.isEmpty else {
            // /usr/local/bin belongs to root on a clean macOS. Rather than
            // asking for a password from a terminal, say exactly what to run:
            // it is one line, and it is honest about what it changes.
            printer.error("Needs permission for \(blocked.joined(separator: " and ")). Run:")
            let commands = blocked.map { path in
                "sudo mkdir -p \((path as NSString).deletingLastPathComponent)"
                    + " && sudo ln -sf \(ProcessRunner.shellQuote(source.path)) \(ProcessRunner.shellQuote(path))"
            }
            for line in commands { print("  " + line) }
            return .failed
        }
        return .ok
    }

    func uninstall() async -> ExitCode {
        var removed: [String] = []
        var blocked: [String] = []
        for path in Self.installPaths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
            } catch {
                blocked.append(path)
            }
        }

        if options.json {
            printer.json(["removed": removed, "blocked": blocked])
            return blocked.isEmpty ? .ok : .failed
        }

        if removed.isEmpty, blocked.isEmpty {
            printer.line("It was not linked anywhere.")
            return .ok
        }
        if !removed.isEmpty { printer.line("Removed \(removed.joined(separator: " and "))") }
        guard blocked.isEmpty else {
            printer.error("Needs permission for \(blocked.joined(separator: " and ")). Run:")
            print("  sudo rm -f " + blocked.map(ProcessRunner.shellQuote).joined(separator: " "))
            return .failed
        }
        return .ok
    }

    /// Where the command is linked from, and whether those links are current.
    func linkStatus() -> [(path: String, destination: String?, current: Bool)] {
        let source = Self.linkSource()?.path
        return Self.installPaths.map { path in
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            return (path, destination, destination != nil && destination == source)
        }
    }
}
