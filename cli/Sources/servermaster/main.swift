//
//  main.swift
//  servermaster
//
//  Routing and the help text.
//

import Foundation

let raw = Array(ProcessInfo.processInfo.arguments.dropFirst())
let (command, options) = CommandLine2.parse(raw)
let printer = Printer(options: options)
let commands = Commands(printer: printer, options: options)

func usage() {
    print("""
    servermaster \(CLIVersion.version) — ServerMaster from the terminal

    Everything the app does, without the window. Servers started here and there
    are the same servers: start one in the app, stop it here, and back again.

    USAGE
      servermaster                   The interactive screen
      servermaster <command> [...]   Do one thing and exit  [--json] [--quiet]

    SERVERS
      list                          Every profile, with its address and state
      status                        What is running right now, and who started it
      start <profile>               Start it and stay attached; Ctrl-C stops it
      start <profile> --no-wait     Start it detached, surviving this terminal
      stop [profile]                Stop one, or everything when no name is given
      restart <profile>             Stop it and start it again
      logs <profile> [--lines n]    The last lines it wrote
      open <profile>                Open its address in the browser

    PROFILES
      show <profile>                Everything about one, including what is wrong
      templates                     What can be created, by id
      new <template> --root <dir>   Create a profile  [--name --port --php --https]
      set <profile> --port 9000     Change one  [--name --root --php --engine --host --index --https]
      duplicate <profile>           Copy it onto a free port
      delete <profile> --yes        Remove it for good

    SERVICES
      db start|stop|status|list
      db create <name>              With a user and a generated password
      db drop <name> --yes
      php list|install <version>
      cert list|trust <name>
      doctor                        What is installed and what is missing
      web [start|stop|status]       The control panel in a browser  [--port --host]
      update check                  Check whether a newer CLI is published
      update install --yes          Download and replace this CLI
      update auto on|off|status     Toggle daily automatic update checks
      install                       Put this command on the PATH
      uninstall                     Take it off again
      ports                         Which ports are taken, and by what
      kill <port> --yes             End whatever holds a port

    OPTIONS
      --json      Machine-readable output on stdout
      --quiet     Only errors and the answer
      --no-wait   Start detached instead of staying attached
      --yes       Confirm something that cannot be undone

    THE INTERACTIVE SCREEN
      --fullscreen        Ask the terminal to fill the display
      --colour 0.0…1.0    The accent hue. Without it, the colour chosen in the
                          Mac application is used, so both look the same.


    A profile can be given by name, by the start of its name, or by id. An
    ambiguous name is refused rather than guessed at.

    EXIT CODES
      0  fine                    64  wrong usage           65  no such profile
      69 something is missing    70  it ran and failed

    EXAMPLES
      servermaster new joomla5 --root ~/Sites/diploma --php 8.2
      servermaster start diploma --no-wait
      servermaster status --json | jq '.servers[] | .name'
      servermaster db create diploma
      servermaster stop
    """)
}

let code: ExitCode

switch command {
// Servers
case "list", "ls":            code = await commands.list()
case "status", "st":          code = await commands.status()
case "start", "run":          code = await commands.start()
case "stop":                  code = await commands.stop()
case "restart":               code = await commands.restart()
case "logs", "log":           code = await commands.logs()
case "open":                  code = await commands.open()

// Profiles
case "show", "info":          code = await commands.show()
case "templates", "tpl":      code = await commands.templates()
case "new", "create":         code = await commands.new()
case "set", "edit":           code = await commands.set()
case "duplicate", "copy":     code = await commands.duplicate()
case "delete", "rm":          code = await commands.delete()

// Services
case "db", "database":        code = await commands.database()
case "php":                   code = await commands.php()
case "cert", "certificates":  code = await commands.certificates()
case "doctor", "deps":        code = await commands.doctor()
case "web":                   code = await commands.web()
case "update", "upgrade":     code = await commands.update()
case "install":               code = await commands.install()
case "uninstall":             code = await commands.uninstall()
case "ports":                 code = await commands.ports()
case "kill":                  code = await commands.killPort()

case "version", "--version", "-v":
    let app = ProfileStore.installedAppVersion()
    if options.json {
        var payload = CLIVersion.payload
        payload["app"] = app as Any
        printer.json(payload.compactMapValues { $0 })
    } else {
        print(CLIVersion.full)
        print(app.map { "ServerMaster \($0)" } ?? "ServerMaster is not installed in Applications")
    }
    code = .ok

case "":
    // Nothing after the command name. A person gets the screen; a script or an
    // agent, whose output is a pipe rather than a terminal, gets the help text
    // — escape sequences in a pipe are just noise.
    if Terminal.isInteractive {
        let screen = Interactive()
        screen.wantsFullScreen = options.flags["fullscreen"] != nil
        if let colour = options.flag("colour") ?? options.flag("color"),
           let hue = Double(colour), (0...1).contains(hue) {
            Theme.hue = hue
        }
        await screen.run()
        code = .ok
    } else {
        usage()
        code = .usage
    }

case "help", "--help", "-h":
    usage()
    code = .ok

default:
    printer.error("Unknown command “\(command)”. Try: servermaster help")
    code = .usage
}

exit(code.rawValue)
