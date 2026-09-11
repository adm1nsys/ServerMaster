//
//  LogOutputView.swift
//  ServerMaster
//

import SwiftUI

struct LogOutputView: View {

    let log: ConsoleLog
    var fontSize: Double = 12
    var autoScroll: Bool = true
    var filter: String = ""

    private var visibleLines: [LogLine] {
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return log.lines }
        return log.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
