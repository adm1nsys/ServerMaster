//
//  CommandLineInterface.swift
//  servermaster
//
//  Parsing, and the shape of everything the tool prints.
//
//  Two audiences, one tool. A person wants short readable lines; an agent wants
//  something it can parse without guessing. So every command can print JSON with
//  --json, exit codes mean something specific, and errors go to stderr while
//  results go to stdout — which is what lets `servermaster status --json | jq`
//  work at all.
//

import Foundation

/// What the process returns. An agent branches on these, so they are part of the
/// contract and must not be reshuffled.
enum ExitCode: Int32 {
    case ok = 0
    case usage = 64            // the command line itself was wrong
    case notFound = 65         // no such profile
    case failed = 70           // the operation ran and did not work
    case unavailable = 69      // something the operation needs is missing
}

struct Options {
    var json = false
    var quiet = false
    var wait = true
    /// Positional words after the command name.
    var arguments: [String] = []
    var flags: [String: String] = [:]

    func flag(_ name: String) -> String? { flags[name] }

    func integer(_ name: String) -> Int? {
        flags[name].flatMap(Int.init)
    }

    var first: String? { arguments.first }
}

enum CommandLine2 {

    /// Commands that look like flags because that is how people write them.
    static let flagCommands: Set<String> = [
        "--version", "-v", "--help", "-h", "--complete", "--completion"
    ]

    /// Splits `servermaster start "My site" --json --port 8080` into its parts.
    /// Unknown flags are kept rather than rejected: a future version of the app
    /// may understand a flag this build does not, and failing on it would break
    /// scripts written against the newer one.
    static func parse(_ raw: [String]) -> (command: String, options: Options) {
        var options = Options()
        var command = ""
        var index = 0

        while index < raw.count {
            let token = raw[index]
            index += 1

            // A few commands are conventionally written as flags. Without this
            // they were parsed as options, the command stayed empty, and
            // `servermaster --version` printed the help text instead.
            if command.isEmpty, flagCommands.contains(token) {
                command = token
                continue
            }

            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                switch name {
                case "json":     options.json = true
                case "quiet":    options.quiet = true
                case "no-wait":  options.wait = false
                default:
                    // --name value, or --name=value
                    if let equals = name.firstIndex(of: "=") {
                        options.flags[String(name[name.startIndex..<equals])] =
                            String(name[name.index(after: equals)...])
                    } else if index < raw.count, !raw[index].hasPrefix("--") {
                        options.flags[name] = raw[index]
                        index += 1
                    } else {
                        options.flags[name] = "true"
                    }
                }
            } else if command.isEmpty {
                command = token
            } else {
                options.arguments.append(token)
            }
        }
        return (command, options)
    }
}

// MARK: - Output

/// Everything printed goes through here, so a command never has to decide how to
/// format itself twice.
struct Printer {

    let options: Options

    func line(_ text: String) {
        guard !options.quiet, !options.json else { return }
        print(text)
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// The machine-readable half. Written even when --quiet: quiet suppresses
    /// chatter, not the answer that was asked for.
    func json(_ value: [String: Any]) {
        guard options.json else { return }
        let encoded = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.prettyPrinted, .sortedKeys])
        if let encoded, let text = String(data: encoded, encoding: .utf8) {
            print(text)
        }
    }

    func result(_ ok: Bool, _ message: String, extra: [String: Any] = [:]) {
        if options.json {
            var payload: [String: Any] = ["ok": ok, "message": message]
            payload.merge(extra) { _, new in new }
            json(payload)
        } else if ok {
            line(message)
        } else {
            error(message)
        }
    }
}
