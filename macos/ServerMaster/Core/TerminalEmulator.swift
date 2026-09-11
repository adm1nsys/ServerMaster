//
//  TerminalEmulator.swift
//  ServerMaster
//
//  The terminal screen: character buffer, cursor and parsing of control
//  sequences. Needed so that vim, top and everything else that draws
//  pseudographics works, rather than just printing lines.
//

import Foundation
import Observation

nonisolated struct TerminalCell: Sendable, Equatable {
    var character: Character = " "
    /// An ANSI colour index (0…255), or nil for the default colour.
    var foreground: Int?
    var background: Int?
    var bold = false
    var inverse = false
    var underline = false

    static let blank = TerminalCell()
}

@Observable
final class TerminalEmulator {

    private(set) var rows: Int
    private(set) var columns: Int
    private(set) var screen: [[TerminalCell]]
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var cursorVisible = true
    /// Increments on every change — the view redraws from it.
    private(set) var revision = 0

    /// Lines that scrolled off the top. Capped so they do not grow without limit.
    private(set) var scrollback: [[TerminalCell]] = []
    var scrollbackLimit = 2000

    // Current styling
    private var pen = TerminalCell()

    // Scroll region
    private var scrollTop = 0
    private var scrollBottom: Int

    // The alternate screen — vim, top and less switch to it
    private var alternateScreen: [[TerminalCell]]?
    private var savedCursor: (row: Int, column: Int)?

    // Parsing
    private enum State { case ground, escape, csi, osc, charset }
    private var state: State = .ground
    private var parameters = ""
    private var intermediate = ""
    private var pendingBytes: [UInt8] = []

    init(rows: Int = 24, columns: Int = 80) {
        let r = max(1, rows)
        let c = max(1, columns)
        self.rows = r
        self.columns = c
        self.scrollBottom = r - 1
        self.screen = Array(repeating: Array(repeating: TerminalCell.blank, count: c), count: r)
    }

    // MARK: - Input

    func feed(_ data: Data) {
        pendingBytes.append(contentsOf: data)
        // UTF-8 can arrive split between reads — keep the tail for later.
        let (text, leftover) = Self.decode(pendingBytes)
        pendingBytes = leftover
        guard !text.isEmpty else { return }
        // By scalars, not by Character: in Swift "\r\n" is a single Character,
        // and parsing by characters would see neither the carriage return nor the line feed.
        for scalar in text.unicodeScalars { process(Character(scalar)) }
        revision &+= 1
    }

    func reset() {
        screen = Array(repeating: Array(repeating: TerminalCell.blank, count: columns), count: rows)
        scrollback.removeAll()
        cursorRow = 0
        cursorColumn = 0
        pen = TerminalCell()
        alternateScreen = nil
        scrollTop = 0
        scrollBottom = rows - 1
        state = .ground
        revision &+= 1
    }

    func resize(rows newRows: Int, columns newColumns: Int) {
        let r = max(1, newRows), c = max(1, newColumns)
        guard r != rows || c != columns else { return }

        var resized = Array(repeating: Array(repeating: TerminalCell.blank, count: c), count: r)
        for row in 0..<min(r, rows) {
            for column in 0..<min(c, columns) {
                resized[row][column] = screen[row][column]
            }
        }
        screen = resized
        rows = r
        columns = c
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = min(cursorRow, r - 1)
        cursorColumn = min(cursorColumn, c - 1)
        revision &+= 1
    }

    /// The screen as text — for copying and for tests.
    var plainText: String {
        screen.map { row in
            String(row.map(\.character)).replacingOccurrences(of: "\u{0}", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        }.joined(separator: "\n")
    }

    // MARK: - Parsing

    private func process(_ character: Character) {
        switch state {
        case .ground:
            ground(character)
        case .escape:
            escape(character)
        case .csi:
            if character.isNumber || character == ";" || character == "?" || character == ">" {
                parameters.append(character)
            } else if character.asciiValue.map({ $0 >= 0x20 && $0 <= 0x2F }) == true {
                intermediate.append(character)
            } else {
                executeCSI(character)
                state = .ground
            }
        case .osc:
            // Window title and the like — we do not need it, wait for the end.
            if character == "\u{07}" { state = .ground }
            else if character == "\\" && parameters.hasSuffix("\u{1B}") { state = .ground }
            else { parameters.append(character) }
        case .charset:
            state = .ground
        }
    }

    private func ground(_ character: Character) {
        switch character {
        case "\u{1B}":
            state = .escape
            parameters = ""
            intermediate = ""
        case "\n", "\u{0B}", "\u{0C}":
            lineFeed()
        case "\r":
            cursorColumn = 0
        case "\u{08}":
            cursorColumn = max(0, cursorColumn - 1)
        case "\t":
            cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
        case "\u{07}":
            break // bell
        default:
            guard !character.isASCII || character.asciiValue.map({ $0 >= 0x20 }) == true else { return }
            put(character)
        }
    }

    private func escape(_ character: Character) {
        switch character {
        case "[":
            state = .csi
        case "]":
            state = .osc
            parameters = ""
        case "(", ")", "*", "+":
            state = .charset
        case "M":
            reverseLineFeed()
            state = .ground
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            state = .ground
        case "8":
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
            }
            state = .ground
        case "c":
            reset()
            state = .ground
        default:
            state = .ground
        }
    }

    private func executeCSI(_ command: Character) {
        let isPrivate = parameters.hasPrefix("?")
        let raw = isPrivate ? String(parameters.dropFirst()) : parameters
        let values = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < values.count else { return fallback }
            return values[index] == 0 ? fallback : values[index]
        }

        switch command {
        case "A": cursorRow = max(scrollTop, cursorRow - value(0))
        case "B": cursorRow = min(scrollBottom, cursorRow + value(0))
        case "C": cursorColumn = min(columns - 1, cursorColumn + value(0))
        case "D": cursorColumn = max(0, cursorColumn - value(0))
        case "E": cursorRow = min(rows - 1, cursorRow + value(0)); cursorColumn = 0
        case "F": cursorRow = max(0, cursorRow - value(0)); cursorColumn = 0
        case "G", "`": cursorColumn = min(columns - 1, value(0) - 1)
        case "d": cursorRow = min(rows - 1, value(0) - 1)
        case "H", "f":
            cursorRow = min(rows - 1, value(0) - 1)
            cursorColumn = min(columns - 1, value(1) - 1)
        case "J": eraseDisplay(values.first ?? 0)
        case "K": eraseLine(values.first ?? 0)
        case "L": insertLines(value(0))
        case "M": deleteLines(value(0))
        case "P": deleteCharacters(value(0))
        case "@": insertCharacters(value(0))
        case "X": eraseCharacters(value(0))
        case "S": scrollUp(value(0))
        case "T": scrollDown(value(0))
        case "m": applySGR(values.isEmpty ? [0] : values)
        case "r":
            scrollTop = max(0, value(0) - 1)
            scrollBottom = min(rows - 1, value(1, rows) - 1)
            if scrollTop >= scrollBottom { scrollTop = 0; scrollBottom = rows - 1 }
            cursorRow = scrollTop
            cursorColumn = 0
        case "s": savedCursor = (cursorRow, cursorColumn)
        case "u":
            if let saved = savedCursor {
                cursorRow = min(saved.row, rows - 1)
                cursorColumn = min(saved.column, columns - 1)
            }
        case "h" where isPrivate: setMode(values, enabled: true)
        case "l" where isPrivate: setMode(values, enabled: false)
        default: break
        }
    }

    private func setMode(_ values: [Int], enabled: Bool) {
        for mode in values {
            switch mode {
            case 25:
                cursorVisible = enabled
            case 1049, 47, 1047:
                // The alternate screen: vim and top draw on it
                // and restore the original one on exit.
                if enabled {
                    if alternateScreen == nil {
                        alternateScreen = screen
                        savedCursor = (cursorRow, cursorColumn)
                        screen = Array(repeating: Array(repeating: TerminalCell.blank, count: columns),
                                       count: rows)
                        cursorRow = 0
                        cursorColumn = 0
                    }
                } else if let saved = alternateScreen {
                    screen = saved
                    alternateScreen = nil
                    if let cursor = savedCursor {
                        cursorRow = min(cursor.row, rows - 1)
                        cursorColumn = min(cursor.column, columns - 1)
                    }
                }
            default:
                break
            }
        }
    }

    private func applySGR(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: pen = TerminalCell()
            case 1: pen.bold = true
            case 4: pen.underline = true
            case 7: pen.inverse = true
            case 22: pen.bold = false
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 30...37: pen.foreground = code - 30
            case 39: pen.foreground = nil
            case 40...47: pen.background = code - 40
            case 49: pen.background = nil
            case 90...97: pen.foreground = code - 90 + 8
            case 100...107: pen.background = code - 100 + 8
            case 38, 48:
                // 38;5;n — a colour from the 256 palette. 38;2;r;g;b is skipped.
                if index + 2 < values.count && values[index + 1] == 5 {
                    if code == 38 { pen.foreground = values[index + 2] }
                    else { pen.background = values[index + 2] }
                    index += 2
                } else if index + 4 < values.count && values[index + 1] == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    // MARK: - Screen operations

    private func put(_ character: Character) {
        if cursorColumn >= columns {
            cursorColumn = 0
            lineFeed()
        }
        var cell = pen
        cell.character = character
        screen[cursorRow][cursorColumn] = cell
        cursorColumn += 1
    }

    private func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseLineFeed() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<count {
            let leaving = screen[scrollTop]
            // Only lines from the main screen go into the scrollback.
            if alternateScreen == nil && scrollTop == 0 {
                scrollback.append(leaving)
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            screen.remove(at: scrollTop)
            screen.insert(Array(repeating: TerminalCell.blank, count: columns), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: TerminalCell.blank, count: columns), at: scrollTop)
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for row in (cursorRow + 1)..<rows {
                screen[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        case 1:
            eraseLine(1)
            for row in 0..<cursorRow {
                screen[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        default:
            for row in 0..<rows {
                screen[row] = Array(repeating: TerminalCell.blank, count: columns)
            }
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns { screen[cursorRow][column] = .blank }
        case 1:
            for column in 0...min(cursorColumn, columns - 1) { screen[cursorRow][column] = .blank }
        default:
            screen[cursorRow] = Array(repeating: TerminalCell.blank, count: columns)
        }
    }

    private func eraseCharacters(_ count: Int) {
        for column in cursorColumn..<min(columns, cursorColumn + count) {
            screen[cursorRow][column] = .blank
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Array(repeating: TerminalCell.blank, count: columns), at: cursorRow)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            screen.remove(at: cursorRow)
            screen.insert(Array(repeating: TerminalCell.blank, count: columns), at: scrollBottom)
        }
    }

    private func insertCharacters(_ count: Int) {
        for _ in 0..<count {
            screen[cursorRow].insert(.blank, at: cursorColumn)
            screen[cursorRow].removeLast()
        }
    }

    private func deleteCharacters(_ count: Int) {
        for _ in 0..<count {
            guard cursorColumn < screen[cursorRow].count else { break }
            screen[cursorRow].remove(at: cursorColumn)
            screen[cursorRow].append(.blank)
        }
    }

    // MARK: - UTF-8 decoding with a tail

    nonisolated static func decode(_ bytes: [UInt8]) -> (String, [UInt8]) {
        var end = bytes.count
        // Cut off an unfinished sequence at the end.
        var index = bytes.count - 1
        var trailing = 0
        while index >= 0 && trailing < 4 {
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                trailing += 1
                index -= 1
                continue
            }
            let expected: Int
            if byte & 0b1000_0000 == 0 { expected = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { expected = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { expected = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { expected = 4 }
            else { expected = 1 }
            if trailing + 1 < expected { end = index }
            break
        }
        let head = Array(bytes[0..<end])
        let tail = Array(bytes[end...])
        return (String(decoding: head, as: UTF8.self), tail)
    }
}
