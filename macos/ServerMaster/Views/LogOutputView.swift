//
//  LogOutputView.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct LogOutputView: View {

    let log: ConsoleLog
    var fontSize: Double = 12
    var autoScroll: Bool = true
    var filter: String = ""

    private var visibleLines: [LogLine] {
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return log.lines }
        return log.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    /// How wide the widest line is, in points.
    private var contentWidth: CGFloat {
        // Measured rather than guessed: every character in a monospaced font is
        // this wide, so one measurement answers for all of them.
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let character = ("0" as NSString)
            .size(withAttributes: [.font: font]).width
        let longest = visibleLines.reduce(0) { max($0, $1.text.count) }
        return CGFloat(longest) * character + 16
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleLines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(color(for: line.stream))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(8)
                // The width is given, not inferred.
                //
                // A LazyVStack inside a horizontally scrolling ScrollView takes
                // the width it is offered rather than the width of its content —
                // it has not laid the far rows out yet and cannot know. So long
                // lines were clipped at the edge with nothing to scroll to.
                //
                // A monospaced font makes the answer arithmetic: the longest
                // line, times the width of one character.
                .frame(width: contentWidth, alignment: .leading)
            }
            // No background. The log sits over the window's own colour now, the
            // same as the terminal beside it — an opaque panel here made the two
            // console tabs look like two different applications.
            .scrollContentBackground(.hidden)
            .onChange(of: log.revision) { _, _ in
                guard autoScroll else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }

    private let bottomID = "log-bottom"

    private func color(for stream: LogStream) -> Color {
        switch stream {
        case .stdout:  return .primary
        case .stderr:  return .red
        case .system:  return .accentColor
        case .command: return .green
        }
    }
}
