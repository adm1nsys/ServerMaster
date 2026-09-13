//
//  CommandLineTool.swift
//  ServerMaster
//
//  Putting `servermaster` on the PATH, and taking it off again.
//
//  A binary inside the app bundle is on nobody's PATH, so the tool needs a link
//  somewhere a shell looks. /usr/local/bin is the conventional place and needs a
//  password the first time, because on a clean macOS it does not exist yet.
//
//  A symlink rather than a copy, deliberately: updating the app then updates the
//  tool, and the two can never disagree about what a profile means.
//

import Foundation

@Observable
final class CommandLineTool {

    enum State: Equatable {
        case notInstalled
        case installed(String)      // where the link points from
        /// A link exists but points at a different copy of the app.
        case pointsElsewhere(String)
        case working
        case failed(String)
    }

    private(set) var state: State = .notInstalled

    /// Where the links go.
    ///
    /// Two directories, because “on the PATH” means different things on
    /// different Macs. /usr/local/bin is on the default PATH of every shell
    /// macOS ships, so it is always used. A shell set up by Homebrew on Apple
    /// Silicon puts /opt/homebrew/bin *ahead* of it — link only into
    /// /usr/local/bin there and an older copy in the Homebrew folder wins
    /// silently, which is the confusing half of this problem rather than the
    /// obvious half. So that one is linked too, when it exists; it is never
    /// created, since that is Homebrew's to make.
    static let primaryDirectory = "/usr/local/bin"
    static let homebrewDirectory = "/opt/homebrew/bin"

    static var installDirectories: [String] {
        var directories = [primaryDirectory]
        if FileManager.default.fileExists(atPath: homebrewDirectory) {
            directories.append(homebrewDirectory)
        }
        return directories
    }

    static var installPaths: [String] { installDirectories.map { $0 + "/servermaster" } }

    /// The one to name when only one can be shown.
    static let installPath = primaryDirectory + "/servermaster"

    /// The binary inside the app bundle.
    ///
    /// Contents/Helpers, not Contents/MacOS, and not by chance: the volume is
    /// case-insensitive, so a file called `servermaster` next to the app's own
    /// `ServerMaster` executable is the same file. Copying the tool there
    /// silently replaces the app with it, and the build still succeeds.
    static var bundledTool: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/servermaster")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    var isAvailable: Bool { Self.bundledTool != nil }

    // MARK: - Looking

    func refresh() {
        let fm = FileManager.default
        let present = Self.installPaths.filter { fm.fileExists(atPath: $0) }
        guard !present.isEmpty else {
            state = .notInstalled
            return
        }

        // A link that points at another copy of the app is the case worth
        // reporting: the command works, it just does not mean this app.
        let stray = present.filter { path in
            (try? fm.destinationOfSymbolicLink(atPath: path)) != Self.bundledTool
        }
        if stray.isEmpty {
            state = .installed(present.joined(separator: ", "))
        } else {
            let destinations = stray.map { path in
                (try? fm.destinationOfSymbolicLink(atPath: path)) ?? path
            }
            state = .pointsElsewhere(destinations.joined(separator: ", "))
        }
    }

    // MARK: - Changing

    func install() async {
        guard let tool = Self.bundledTool else {
            state = .failed(String(localized: "This build does not carry the command line tool."))
            return
        }
        state = .working

        // mkdir -p first: on a clean macOS /usr/local/bin does not exist, and a
        // symlink into a missing folder fails with a message about the link
        // rather than about the folder, which sends people the wrong way.
        let command = (["/bin/mkdir -p \(ProcessRunner.shellQuote(Self.primaryDirectory))"]
            + Self.installPaths.map { path in
                "/bin/ln -sf \(ProcessRunner.shellQuote(tool)) \(ProcessRunner.shellQuote(path))"
            }).joined(separator: " && ")

        let places = Self.installDirectories.joined(separator: " and ")
        let result = await ProcessRunner.runAsAdmin(
            command,
            prompt: String(localized: "ServerMaster wants to put the servermaster command in \(places)."))

        refresh()
        if case .installed = state { return }
        state = .failed(result.stderr.isEmpty
                        ? String(localized: "The command could not be installed.")
                        : result.stderr)
    }

    func uninstall() async {
        state = .working
        let result = await ProcessRunner.runAsAdmin(
            Self.installPaths.map { "/bin/rm -f \(ProcessRunner.shellQuote($0))" }.joined(separator: "; "),
            prompt: String(localized: "ServerMaster wants to remove the servermaster command."))

        refresh()
        if case .notInstalled = state { return }
        state = .failed(result.stderr.isEmpty
                        ? String(localized: "The command could not be removed.")
                        : result.stderr)
    }

    /// What to show when the tool is not installed and cannot be, so the person
    /// can still use it from where it lives.
    var manualHint: String {
        guard let tool = Self.bundledTool else { return "" }
        return String(localized: "You can also run it directly: \(tool)")
    }
}
