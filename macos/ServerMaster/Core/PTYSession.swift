//
//  PTYSession.swift
//  ServerMaster
//
//  A real pseudo-terminal. Unlike running commands through pipes,
//  everything that needs a terminal works here: vim, top, ssh, interactive
//  prompts, Ctrl-C and syntax colouring.
//

import Foundation
import Darwin
import Observation

@Observable
final class PTYSession {

    let terminal: TerminalEmulator

    private(set) var isRunning = false
    private(set) var processIdentifier: pid_t = 0
    private(set) var lastExitCode: Int32?

    /// Called when the shell has exited.
    var onExit: ((Int32) -> Void)?

    private var masterDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?

    init(rows: Int = 24, columns: Int = 80) {
        terminal = TerminalEmulator(rows: rows, columns: columns)
    }

    deinit {
        // deinit is not isolated — close the descriptor directly.
        if masterDescriptor >= 0 { close(masterDescriptor) }
    }

    // MARK: - Startup

    @discardableResult
    func start(shell: String? = nil,
               arguments: [String] = ["-i", "-l"],
               directory: String,
               environment: [String: String] = [:]) -> Bool {
        guard !isRunning else { return true }

        let executable = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }

        var childEnvironment = ShellEnvironment.shared.environment(extra: environment)
        childEnvironment["TERM"] = "xterm-256color"
        childEnvironment["COLUMNS"] = String(terminal.columns)
        childEnvironment["LINES"] = String(terminal.rows)
        childEnvironment.removeValue(forKey: "PAGER")

        // Everything the child needs is prepared in advance: between fork and exec
        // nothing may allocate memory or call anything more complex than execve.
        let argv = [executable] + arguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvironment: [UnsafeMutablePointer<CChar>?] =
            childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cExecutable = strdup(executable)
        let cDirectory = strdup(directory)
        defer {
            for pointer in cArguments where pointer != nil { free(pointer) }
            for pointer in cEnvironment where pointer != nil { free(pointer) }
            free(cExecutable)
            free(cDirectory)
        }

        var master: Int32 = 0
        var size = winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.columns),
                           ws_xpixel: 0, ws_ypixel: 0)

        // forkpty, not posix_spawn: it calls login_tty, which does setsid and
        // TIOCSCTTY. Without a controlling terminal, job control does not work —
        // Ctrl-C never becomes SIGINT.
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return false }

        if pid == 0 {
            // The child. Only async-signal-safe calls.
            if let cDirectory { _ = chdir(cDirectory) }
            execve(cExecutable, &cArguments, &cEnvironment)
            _exit(127)
        }

        masterDescriptor = master
        processIdentifier = pid
        isRunning = true
        lastExitCode = nil

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master,
                                                   queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            Task { @MainActor in self?.terminal.feed(data) }
        }
        source.resume()
        readSource = source

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                          queue: .global())
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
            Task { @MainActor in self?.handleExit(Int32(code)) }
        }
        exitSource.resume()
        waitSource = exitSource

        return true
    }

    // MARK: - Input

    func send(_ text: String) {
        write(Data(text.utf8))
    }

    /// A control character: send(control: "c") gives Ctrl-C.
    func send(control letter: Character) {
        guard let ascii = letter.uppercased().first?.asciiValue,
              ascii >= 0x40, ascii <= 0x5F else { return }
        write(Data([ascii - 0x40]))
    }

    func write(_ data: Data) {
        guard isRunning, masterDescriptor >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(masterDescriptor, base + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    // MARK: - Size and termination

    func resize(rows: Int, columns: Int) {
        terminal.resize(rows: rows, columns: columns)
        guard masterDescriptor >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterDescriptor, TIOCSWINSZ, &size)
        // Tell the process that the window changed.
        if processIdentifier > 0 { kill(-processIdentifier, SIGWINCH) }
    }

    func interrupt() { send(control: "c") }

    func terminate() {
        guard isRunning, processIdentifier > 0 else { return }
        // Signal the whole group: the shell and its children.
        kill(-processIdentifier, SIGHUP)
        let deadline = Date().addingTimeInterval(2)
        while kill(processIdentifier, 0) == 0 && Date() < deadline { usleep(50_000) }
        if kill(processIdentifier, 0) == 0 { kill(-processIdentifier, SIGKILL) }
        handleExit(-1)
    }

    private func handleExit(_ code: Int32) {
        guard isRunning else { return }
        isRunning = false
        lastExitCode = code
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil
        if masterDescriptor >= 0 {
            close(masterDescriptor)
            masterDescriptor = -1
        }
        processIdentifier = 0
        onExit?(code)
    }
}
