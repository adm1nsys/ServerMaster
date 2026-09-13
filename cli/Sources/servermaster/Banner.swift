//
//  Banner.swift
//  servermaster
//
//  The wordmark at the top of the interactive screen.
//
//  It is drawn only when it fits. A logo that wraps is worse than no logo, and
//  on a short window every row it takes is a row of the profile list that is not
//  shown — so the header degrades to a single line rather than pushing the
//  content off the screen.
//

import Foundation

nonisolated enum Banner {

    /// The widest line of the art. Everything here is one block of fixed-width
    /// lines, so one number describes all of it.
    static let width = 99

    static let wordmark: [String] = String(#"""
 ____                                                                         __
/\  _`\                                             /'\_/`\                  /\ \__
\ \,\L\_\     __   _ __   __  __     __   _ __     /\      \     __      ____\ \ ,_\    __   _ __
 \/_\__ \   /'__`\/\`'__\/\ \/\ \  /'__`\/\`'__\   \ \ \__\ \  /'__`\   /',__\\ \ \/  /'__`\/\`'__\
   /\ \L\ \/\  __/\ \ \/ \ \ \_/ |/\  __/\ \ \/     \ \ \_/\ \/\ \L\.\_/\__, `\\ \ \_/\  __/\ \ \/
   \ `\____\ \____\\ \_\  \ \___/ \ \____\\ \_\      \ \_\\ \_\ \__/.\_\/\____/ \ \__\ \____\\ \_\
    \/_____/\/____/ \/_/   \/__/   \/____/ \/_/       \/_/ \/_/\/__/\/_/\/___/   \/__/\/____/ \/_/
"""#).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    /// “CLI V1.0”, drawn rather than written.
    ///
    /// The version is spelled out in the art, so it can only be shown while the
    /// art is still telling the truth — the check below is what stops a 1.1
    /// build from announcing itself as 1.0 in letters six rows high.
    static let versionMark: [String] = String(#"""
 ____     __     ______      __  __     _          __
/\  _`\  /\ \   /\__  _\    /\ \/\ \  /' \       /'__`\
\ \ \/\_\\ \ \  \/_/\ \/    \ \ \ \ \/\_, \     /\ \/\ \
 \ \ \/_/_\ \ \  __\ \ \     \ \ \ \ \/_/\ \    \ \ \ \ \
  \ \ \L\ \\ \ \L\ \\_\ \__   \ \ \_/ \ \ \ \  __\ \ \_\ \
   \ \____/ \ \____//\_____\   \ `\___/  \ \_\/\_\\ \____/
    \/___/   \/___/ \/_____/    `\/__/    \/_/\/_/ \/___/
"""#).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    static let versionMarkWidth = 58

    /// The same wordmark broken in two, for a window too narrow for one line.
    ///
    /// Columns 48 to 50 are the only ones blank in all seven rows — the gap
    /// between “Server” and “Master” — so that is the one place the art can be
    /// cut without slicing a glyph. Both halves come out 48 wide, which is what
    /// makes it fit an ordinary 80-column window.
    static let stackedWidth = 48

    static let stacked: [String] = {
        func slice(_ range: Range<Int>) -> [String] {
            wordmark.map { line in
                let padded = Array(line.padding(toLength: width, withPad: " ", startingAt: 0))
                var text = String(padded[range])
                while text.hasSuffix(" ") { text.removeLast() }
                return text
            }
        }
        return slice(0..<48) + slice(51..<width)
    }()

    static var versionMarkIsCurrent: Bool { CLIVersion.version.hasPrefix("1.0") }

    /// The language mode the sources are compiled in, which is not the same
    /// number as the compiler and is worth saying out loud.
    static let languageMode: String = {
        #if swift(>=6.0)
        return "6"
        #else
        return "5"
        #endif
    }()

    /// The Swift the binary was built with, decided by the compiler rather than
    /// written down: there is no way to ask for this at runtime, and a hard-coded
    /// number would quietly go stale on the next toolchain.
    ///
    /// `compiler(>=)` and not `swift(>=)`: the second one reports the *language
    /// mode*, which is 5 here, so asking it which Swift this is gives the answer
    /// “5.10” from a 6.4 toolchain.
    static let swiftVersion: String = {
        #if compiler(>=6.5)
        return "6.5 or newer"
        #elseif compiler(>=6.4)
        return "6.4"
        #elseif compiler(>=6.3)
        return "6.3"
        #elseif compiler(>=6.2)
        return "6.2"
        #elseif compiler(>=6.1)
        return "6.1"
        #elseif compiler(>=6.0)
        return "6.0"
        #elseif compiler(>=5.10)
        return "5.10"
        #else
        return "5.9 or older"
        #endif
    }()
}
