//
//  WebCommands.swift
//  servermaster
//
//  Turning the web interface on, and pointing it somewhere else.
//
//  It runs by default when the interactive screen is opened, because a control
//  panel nobody knows about is a control panel nobody uses. It binds to the
//  loopback and speaks plain HTTP — see WebInterface for why both of those are
//  deliberate, and why putting it on the network is a job for a real web server
//  in front rather than a flag here.
//
//  --host is offered anyway, because refusing to let someone bind elsewhere on
//  their own machine is paternalism, not safety. It says plainly what it does.
//

import Foundation

extension Commands {

    func web() async -> ExitCode {
        let action = options.first ?? "start"

        switch action {
        case "start", "on":
            let port = options.integer("port") ?? WebInterface.defaultPort
            let host = options.flag("host") ?? "127.0.0.1"

            guard let address = WebInterface.shared.start(port: port, host: host) else {
                printer.error("Could not listen on \(host):\(String(port)). Something else may hold that port.")
                return .failed
            }
            if options.json {
                printer.json(["address": address, "host": host, "port": port])
            } else {
                printer.line("The web interface is at \(address)")
                if host != "127.0.0.1" && host != "localhost" {
                    printer.line("")
                    printer.line("It is bound to \(host), which means other machines can reach it —")
                    printer.line("and anyone who can reach it can start and stop your servers.")
                    printer.line("There is no password here. Put a web server in front of it.")
                }
            }
            // No --no-wait here, on purpose. This process *is* the server: the
            // listening socket belongs to it, so returning immediately would
            // print an address and then close it. To run it in the background,
            // background the command — or hand it to launchd or systemd, which
            // is what a machine that should always have it wants anyway.
            printer.line("")
            printer.line("Ctrl-C to stop.")
            while WebInterface.shared.address != nil {
                try? await Task.sleep(for: .seconds(1))
            }
            return .ok

        case "stop", "off":
            WebInterface.shared.stop()
            printer.result(true, String(localized: "The web interface is off."))
            return .ok

        case "status":
            let address = WebInterface.shared.address
            if options.json {
                printer.json(["running": address != nil, "address": address as Any]
                    .compactMapValues { $0 })
            } else {
                printer.line(address.map { "Running at \($0)" } ?? "Not running.")
            }
            return .ok

        default:
            printer.error("Unknown action “\(action)”. Try: web start | stop | status")
            return .usage
        }
    }
}
