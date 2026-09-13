//
//  Terminal.swift
//  servermaster
//
//  Drawing and keyboard input for the interactive screen, without any
//  dependencies. Everything here is termios and ANSI escapes, which is all a
//  terminal has ever needed and is the same on Linux — the port of this file is
//  no port at all.
//
//  Two rules run through it. The terminal must always be handed back the way it
//  was found: raw mode with the cursor hidden is a wrecked shell if the program
//  exits without restoring it, including when it is killed. And nothing here may
//  assume a terminal exists — the same binary is run by scripts and agents with
//  its output going into a pipe, where every escape sequence would be garbage.
//

import Foundation

enum Key: Equatable {
    case up, down, left, right
    case enter, escape, tab, backspace, delete
    case character(Character)
    case control(Character)      // ctrl-c arrives as .control("c")
    case unknown
}

final class Terminal {

    private var original = termios()
    private var isRaw = false

    /// Whether we are attached to a terminal that can actually draw.
    ///
    /// isatty alone is not enough, and the difference is visible: Xcode's
    /// console can look like a terminal to isatty while showing every escape
    /// sequence as literal text, so the screen arrives as “[90m ──── [0m[K”.
    /// TERM is what says whether escapes mean anything — unset or “dumb” means
    /// they do not, and then this is no more interactive than a pipe.
    static var isInteractive: Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        guard let term = ProcessInfo.processInfo.environment["TERM"],
              !term.isEmpty, term != "dumb" else { return false }
        return true
    }

    // MARK: - Raw mode

    func enterRawMode() {
        guard Terminal.isInteractive, !isRaw else { return }
        tcgetattr(STDIN_FILENO, &original)

        var raw = original
        // No line buffering, no echo: keys arrive as they are pressed rather
        // than a line at a time, which is what makes arrows and single-key
        // commands possible.
        raw.c_lflag &= ~(UInt(ECHO | ICANON | IEXTEN))
        // ISIG stays on deliberately: ctrl-c should still be able to kill this
        // if the drawing loop ever wedges.
        raw.c_iflag &= ~(UInt(IXON | ICRNL))
        raw.c_oflag &= ~(UInt(OPOST))
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true

        write("\u{1B}[?1049h")   // alternate screen, so the shell scrollback survives
        write("\u{1B}[?25l")     // hide the cursor
    }

    /// Asks the terminal emulator to fill the display.
    ///
    /// This is xterm's window-manipulation escape, which macOS Terminal, iTerm2,
    /// Ghostty, Kitty and most others honour. Anything that does not simply
    /// ignores it — there is no error to handle and nothing to detect, which is
    /// why it is safe to send and why it is offered rather than assumed.
    func maximise() {
        guard Terminal.isInteractive else { return }
        write("\u{1B}[9;1t")
    }

    /// Puts the window back to the size it was.
    func unmaximise() {
        guard Terminal.isInteractive else { return }
        write("\u{1B}[9;0t")
    }

    func restore(restoreWindow: Bool = false) {
        guard isRaw else { return }
        if restoreWindow { unmaximise() }
        write("\u{1B}[?25h")
        write("\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        isRaw = false
    }

    deinit { restore() }

    // MARK: - Size

    var size: (rows: Int, columns: Int) {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0, window.ws_col > 0 else {
            return (24, 80)
        }
        return (Int(window.ws_row), Int(window.ws_col))
    }

    // MARK: - Output

    private var buffer = ""

    /// Lines written since `begin()`.
    ///
    /// Counted so a screen can push its footer to the bottom of the window
    /// instead of letting it sit wherever the content happened to end. Without
    /// this the interface hugs the top and leaves a hole underneath, which is
    /// what makes a terminal program look unfinished next to one that fills the
    /// window it was given.
    private(set) var linesWritten = 0

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Everything for one frame is collected and written once. Writing as the
    /// screen is built makes it visibly tear.
    func begin() {
        buffer = Terminal.isInteractive ? "\u{1B}[H" : ""   // home, without clearing: less flicker
        linesWritten = 0
    }

    func put(_ text: String) { buffer += text }

    func putLine(_ text: String = "") {
        linesWritten += 1
        buffer += Terminal.isInteractive
            ? text + "\u{1B}[K\r\n"          // clear to end of line, then wrap
            : text + "\n"
    }

    /// Fills down to `row`, so whatever comes next starts there.
    func padTo(row: Int) {
        while linesWritten < row { putLine() }
    }

    func flush() {
        if Terminal.isInteractive { buffer += "\u{1B}[J" }   // clear what the last frame left
        write(buffer)
        buffer = ""
    }

    // MARK: - Input

    /// Waits up to `timeout` seconds for a key. Returns nil if nothing was
    /// pressed, which is what lets the screen refresh itself: a server that dies
    /// on its own should be seen without anyone touching the keyboard.
    func readKey(timeout: TimeInterval) -> Key? {
        var descriptors = fd_set()
        withUnsafeMutablePointer(to: &descriptors) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                for index in 0..<32 { bits[index] = 0 }
                bits[Int(STDIN_FILENO) / 32] |= Int32(1 << (Int(STDIN_FILENO) % 32))
            }
        }
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let ready = select(STDIN_FILENO + 1, &descriptors, nil, nil, &deadline)
        guard ready > 0 else { return nil }
        return readKey()
    }

    /// Blocks until a key is pressed. Escape sequences for the arrows arrive as
    /// several bytes; anything unrecognised is reported rather than guessed at.
    func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .unknown }

        switch byte {
        case 0x1B:
            // Could be a bare Escape or the start of a sequence. A second byte
            // is only there if it is a sequence, so peek without blocking.
            var next: UInt8 = 0
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }

            guard read(STDIN_FILENO, &next, 1) == 1, next == 0x5B else { return .escape }
            var final: UInt8 = 0
            guard read(STDIN_FILENO, &final, 1) == 1 else { return .escape }
            switch final {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x33:
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)
                return .delete
            default:   return .unknown
            }

        case 0x0D, 0x0A: return .enter
        case 0x09:       return .tab
        case 0x7F, 0x08: return .backspace
        case 0x01...0x1A:
            let letter = Character(UnicodeScalar(byte + 96))
            return .control(letter)
        default:
            // Multi-byte UTF-8: read the continuation bytes so an accented
            // letter is one character rather than three broken ones.
            var bytes = [byte]
            var remaining = 0
            if byte & 0xE0 == 0xC0 { remaining = 1 }
            else if byte & 0xF0 == 0xE0 { remaining = 2 }
            else if byte & 0xF8 == 0xF0 { remaining = 3 }
            for _ in 0..<remaining {
                var extra: UInt8 = 0
                if read(STDIN_FILENO, &extra, 1) == 1 { bytes.append(extra) }
            }
            guard let text = String(bytes: bytes, encoding: .utf8),
                  let character = text.first else { return .unknown }
            return .character(character)
        }
    }
}

// MARK: - Styling

/// ANSI styling, switched off entirely when the output is not a terminal so a
/// redirected run produces clean text.
enum Style {

    static var enabled = Terminal.isInteractive

    private static func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap("1", text) }
    static func dim(_ text: String) -> String { wrap("2", text) }
    static func inverse(_ text: String) -> String { wrap("7", text) }

    static func green(_ text: String) -> String { wrap("32", text) }
    static func yellow(_ text: String) -> String { wrap("33", text) }
    static func red(_ text: String) -> String { wrap("31", text) }
    static func blue(_ text: String) -> String { wrap("34", text) }
    static func grey(_ text: String) -> String { wrap("90", text) }

    /// A table cell: padded like `pad`, but text too long for the column is cut
    /// with an ellipsis and always leaves one space before the next column, so a
    /// narrow window shows “PHP site (Apach… stopped” rather than running the
    /// two words together.
    static func column(_ text: String, _ width: Int) -> String {
        guard text.count > width - 1 else { return pad(text, width) }
        return String(text.prefix(max(0, width - 2))) + "… "
    }

    /// Padding that counts characters rather than bytes, so a name with an
    /// accent in it does not throw the columns out.
    static func pad(_ text: String, _ width: Int) -> String {
        let visible = text.count
        return visible >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - visible)
    }
}
