//
//  TerminalView.swift
//  ServerMaster
//
//  Drawing the terminal screen and taking keyboard input, including control
//  combinations. Input is caught through NSView: SwiftUI does not hand over
//  Ctrl combinations and special keys in the form a shell expects.
//

import SwiftUI
import AppKit

struct TerminalView: View {

    let session: PTYSession
    var fontSize: Double = 12

    var body: some View {
        GeometryReader { geometry in
            let metrics = TerminalMetrics(fontSize: fontSize)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

                TerminalScreen(terminal: session.terminal, metrics: metrics)
                    .padding(6)

                TerminalKeyCatcher(session: session)
                    .allowsHitTesting(true)
            }
            .onAppear { applySize(geometry.size, metrics: metrics) }
            .onChange(of: geometry.size) { _, size in applySize(size, metrics: metrics) }
            .onChange(of: fontSize) { _, _ in applySize(geometry.size, metrics: metrics) }
        }
    }

    private func applySize(_ size: CGSize, metrics: TerminalMetrics) {
        let columns = max(20, Int((size.width - 12) / metrics.cellWidth))
        let rows = max(5, Int((size.height - 12) / metrics.lineHeight))
        guard columns != session.terminal.columns || rows != session.terminal.rows else { return }
        session.resize(rows: rows, columns: columns)
    }
}

/// The size of a monospaced cell — the terminal grid is measured from it.
nonisolated struct TerminalMetrics {
    let font: NSFont
    let cellWidth: CGFloat
    let lineHeight: CGFloat

    init(fontSize: Double) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.font = font
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        self.cellWidth = ("W" as NSString).size(withAttributes: attributes).width
        self.lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
    }
}

/// The whole screen is drawn in one Canvas: there are many rows, and a separate
/// Text per cell would stall on fast output.
struct TerminalScreen: View {

    let terminal: TerminalEmulator
    let metrics: TerminalMetrics

    var body: some View {
        Canvas { context, _ in
            let screen = terminal.screen
            for (rowIndex, row) in screen.enumerated() {
                let y = CGFloat(rowIndex) * metrics.lineHeight
                var column = 0
                while column < row.count {
                    let cell = row[column]
                    // Gather runs of adjacent cells that share the same styling.
                    var run = String(cell.character)
                    var next = column + 1
                    while next < row.count, sameStyle(row[next], cell) {
                        run.append(row[next].character)
                        next += 1
                    }
                    draw(run, at: CGPoint(x: CGFloat(column) * metrics.cellWidth, y: y),
                         cell: cell, context: &context, width: CGFloat(next - column) * metrics.cellWidth)
                    column = next
                }
            }

            if terminal.cursorVisible {
                let rect = CGRect(x: CGFloat(terminal.cursorColumn) * metrics.cellWidth,
                                  y: CGFloat(terminal.cursorRow) * metrics.lineHeight,
                                  width: metrics.cellWidth, height: metrics.lineHeight)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.55)))
            }
        }
        // Canvas has no way of knowing on its own that the data changed.
        .id(terminal.revision)
    }

    private func sameStyle(_ a: TerminalCell, _ b: TerminalCell) -> Bool {
        a.foreground == b.foreground && a.background == b.background
            && a.bold == b.bold && a.inverse == b.inverse && a.underline == b.underline
    }

    private func draw(_ text: String, at point: CGPoint, cell: TerminalCell,
                      context: inout GraphicsContext, width: CGFloat) {
        var foreground = color(cell.foreground) ?? .primary
        var background = color(cell.background)
        if cell.inverse {
            let swap = background ?? Color(nsColor: .textBackgroundColor)
            background = foreground
            foreground = swap
        }
        if let background {
            context.fill(Path(CGRect(x: point.x, y: point.y, width: width, height: metrics.lineHeight)),
                         with: .color(background))
        }
        guard text.contains(where: { $0 != " " }) else { return }

        var resolved = context.resolve(
            Text(text)
                .font(.system(size: metrics.font.pointSize, weight: cell.bold ? .bold : .regular,
                              design: .monospaced))
                .foregroundStyle(foreground))
        resolved.shading = .color(foreground)
        context.draw(resolved, at: CGPoint(x: point.x, y: point.y), anchor: .topLeading)
    }

    /// The ANSI palette. 0…7 normal, 8…15 bright, then a 6×6×6 cube and a grey ramp.
    private func color(_ index: Int?) -> Color? {
        guard let index else { return nil }
        let basic: [Color] = [
            .black, .red, .green, .yellow, .blue, .purple, .cyan, Color(white: 0.85),
            Color(white: 0.4), Color(red: 1, green: 0.4, blue: 0.4),
            Color(red: 0.4, green: 1, blue: 0.4), Color(red: 1, green: 1, blue: 0.5),
            Color(red: 0.45, green: 0.65, blue: 1), Color(red: 1, green: 0.5, blue: 1),
            Color(red: 0.5, green: 1, blue: 1), .white
        ]
        if index < basic.count { return basic[index] }
        if index >= 232 {
            let level = Double(index - 232) / 23.0
            return Color(white: level)
        }
        let value = index - 16
        let r = Double((value / 36) % 6) / 5.0
        let g = Double((value / 6) % 6) / 5.0
        let b = Double(value % 6) / 5.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Keyboard input

private struct TerminalKeyCatcher: NSViewRepresentable {
    let session: PTYSession

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.session = session
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.session = session
    }
}

final class KeyCatcherView: NSView {
    var session: PTYSession?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let session, session.isRunning else { return }

        // Leave Command to the system: copy, paste, close window.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.control),
           let letter = event.charactersIgnoringModifiers?.first {
            session.send(control: letter)
            return
        }

        switch event.keyCode {
        case 126: session.send("\u{1B}[A")   // up
        case 125: session.send("\u{1B}[B")   // down
        case 124: session.send("\u{1B}[C")   // right
        case 123: session.send("\u{1B}[D")   // left
        case 115: session.send("\u{1B}[H")   // Home
        case 119: session.send("\u{1B}[F")   // End
        case 116: session.send("\u{1B}[5~")  // PageUp
        case 121: session.send("\u{1B}[6~")  // PageDown
        case 117: session.send("\u{1B}[3~")  // forward Delete
        case 51:  session.send("\u{7F}")     // Backspace
        case 48:  session.send("\t")
        case 53:  session.send("\u{1B}")     // Esc
        case 36, 76: session.send("\r")      // Enter
        default:
            if let characters = event.characters, !characters.isEmpty {
                // Option as Meta: Esc before the character, which is what emacs and shells expect.
                if event.modifierFlags.contains(.option) {
                    session.send("\u{1B}" + characters)
                } else {
                    session.send(characters)
                }
            }
        }
    }

    /// Pasting from the clipboard.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.send(text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
