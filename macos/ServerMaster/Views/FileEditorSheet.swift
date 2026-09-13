//
//  FileEditorSheet.swift
//  ServerMaster
//
//  A text editor for the files a site is configured by: .htaccess, .env,
//  configuration.php, an nginx block.
//
//  Built on NSTextView rather than SwiftUI's TextEditor, and not for the look of
//  it. NSTextView already has find and replace, undo, and a ruler — writing any
//  of those again to get a search field would be silly, and the versions people
//  already know the keystrokes for are the ones built into the control.
//
//  Nothing is written until Save. A config file that a server is reading right
//  now is not a document to autosave over.
//

import SwiftUI
import AppKit

struct FileEditorSheet: View {

    let url: URL
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var wrapping = false

    private var changed: Bool { text != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            CodeEditor(text: $text,
                       syntax: Syntax.forFile(url.lastPathComponent),
                       wrapping: wrapping)
                .frame(minWidth: 700, minHeight: 420)

            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .task { load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).fontWeight(.medium)
                Text(AppPaths.abbreviate(url.deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if changed {
                Text("edited").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Wrap", isOn: $wrapping)
                .toggleStyle(.button)
                .controlSize(.small)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("⌘F to search  ·  ⌘Z to undo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { text = original }
                .disabled(!changed)
            Button("Close") { dismiss() }
            Button("Save") { save() }
                .keyboardShortcut("s")
                .disabled(!changed || saving)
        }
        .padding(12)
    }

    private func load() {
        do {
            // Not every config file is UTF-8. A Joomla configuration.php written
            // years ago may not be, and refusing to open it is unhelpful when
            // the alternative is reading it as Latin-1 and saying so.
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else if let latin = String(data: data, encoding: .isoLatin1) {
                text = latin
                problem = String(localized: "This file is not UTF-8. It was read as Latin-1 and will be saved as UTF-8.")
            } else {
                problem = String(localized: "This does not look like a text file.")
            }
            original = text
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        saving = true
        defer { saving = false }
        do {
            // Written through a temporary file in the same folder and swapped in,
            // so a server reading it never sees a half-written config.
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).servermaster-tmp")
            try Data(text.utf8).write(to: temporary, options: .atomic)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            if let permissions = attributes?[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            original = text
            problem = nil
            onSaved?()
        } catch {
            problem = String(localized: "Could not save: \(error.localizedDescription)")
        }
    }
}

// MARK: - What gets coloured

/// Enough of a grammar to read a config file by, and no more. This is not a
/// language server: comments, strings and numbers are what the eye needs to
/// separate a value from the words around it, and everything past that is
/// diminishing returns on a file nobody writes for hours at a time.
nonisolated struct Syntax: Sendable {
    var commentPrefixes: [String]
    var blockComments: [(String, String)] = []
    var keywords: Set<String> = []

    static func forFile(_ name: String) -> Syntax {
        let lower = name.lowercased()
        if lower.hasSuffix(".php") || lower == "configuration.php" {
            return Syntax(commentPrefixes: ["//", "#"],
                          blockComments: [("/*", "*/")],
                          keywords: ["public", "private", "protected", "var", "class", "function",
                                     "return", "null", "true", "false", "const", "define", "new"])
        }
        if lower.hasSuffix(".json") {
            return Syntax(commentPrefixes: [], keywords: ["true", "false", "null"])
        }
        if lower.hasSuffix(".js") || lower.hasSuffix(".ts") {
            return Syntax(commentPrefixes: ["//"],
                          blockComments: [("/*", "*/")],
                          keywords: ["const", "let", "var", "function", "return", "import", "export",
                                     "async", "await", "class", "if", "else", "true", "false", "null"])
        }
        if lower.hasSuffix(".conf") || lower.hasPrefix("nginx") {
            return Syntax(commentPrefixes: ["#"],
                          keywords: ["server", "location", "listen", "root", "index", "proxy_pass",
                                     "server_name", "include", "ssl_certificate", "return", "rewrite"])
        }
        if lower == ".htaccess" || lower.hasSuffix(".htaccess") {
            return Syntax(commentPrefixes: ["#"],
                          keywords: ["RewriteEngine", "RewriteRule", "RewriteCond", "RewriteBase",
                                     "Options", "Require", "Header", "ErrorDocument", "AddType",
                                     "DirectoryIndex", "IfModule"])
        }
        if lower == ".env" || lower.hasPrefix(".env") {
            return Syntax(commentPrefixes: ["#"])
        }
        if lower == "caddyfile" {
            return Syntax(commentPrefixes: ["#"],
                          keywords: ["root", "file_server", "reverse_proxy", "tls", "encode", "php_fastcgi"])
        }
        return Syntax(commentPrefixes: ["#", "//"])
    }
}

// MARK: - The editor itself

private struct CodeEditor: NSViewRepresentable {

    @Binding var text: String
    let syntax: Syntax
    let wrapping: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // Find and replace, for free, with the keystrokes people already know.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wrapping
        scroll.autohidesScrollers = false

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        textView.string = text
        context.coordinator.highlight(textView, syntax: syntax)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.applyWrapping(wrapping, to: textView, in: scroll)

        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            context.coordinator.highlight(textView, syntax: syntax)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: CodeEditor
        /// Highlighting a large file on every keystroke is what makes an editor
        /// feel heavy, so it waits for a pause instead.
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string

            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView, syntax: self.parent.syntax)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func applyWrapping(_ wrapping: Bool, to textView: NSTextView, in scroll: NSScrollView) {
            guard let container = textView.textContainer else { return }
            if wrapping {
                container.widthTracksTextView = true
                container.size = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = false
                scroll.hasHorizontalScroller = false
            } else {
                container.widthTracksTextView = false
                container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                scroll.hasHorizontalScroller = true
            }
        }

        func highlight(_ textView: NSTextView, syntax: Syntax) {
            guard let storage = textView.textStorage else { return }
            let text = storage.string
            let whole = NSRange(location: 0, length: (text as NSString).length)

            storage.beginEditing()
            storage.setAttributes([.font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                   .foregroundColor: NSColor.textColor], range: whole)

            func colour(_ pattern: String, _ value: NSColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                for match in regex.matches(in: text, range: whole) {
                    storage.addAttribute(.foregroundColor, value: value, range: match.range)
                }
            }

            if !syntax.keywords.isEmpty {
                let words = syntax.keywords.map { NSRegularExpression.escapedPattern(for: $0) }
                colour("\\b(" + words.joined(separator: "|") + ")\\b", .systemPurple)
            }
            colour("\\b[0-9]+(\\.[0-9]+)?\\b", .systemBlue)
            colour("\"[^\"\\n]*\"|'[^'\\n]*'", .systemRed)

            // Comments last, so a keyword inside one is not left coloured.
            for (open, close) in syntax.blockComments {
                colour(NSRegularExpression.escapedPattern(for: open) + "[\\s\\S]*?"
                       + NSRegularExpression.escapedPattern(for: close), .systemGreen)
            }
            for prefix in syntax.commentPrefixes {
                colour("^\\s*" + NSRegularExpression.escapedPattern(for: prefix) + ".*$",
                       .systemGreen, options: [.anchorsMatchLines])
            }
            storage.endEditing()
        }
    }
}

// MARK: - Line numbers

/// The ruler down the left. AppKit gives the geometry; the numbers themselves
/// have to be counted and drawn.
private final class LineNumberRuler: NSRulerView {

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                              name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                              name: NSView.boundsDidChangeNotification,
                                              object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSColor.textBackgroundColor.setFill()
        rect.fill()

        let text = textView.string as NSString
        let visible = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        // Counting from the top of the document each time is fine: this runs on
        // what is on screen, and finding the first visible line means counting
        // newlines before it either way.
        var number = 1
        var index = 0
        while index < visible.location {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(line)
            if index <= visible.location { number += 1 }
        }

        var glyph = visible.location
        while glyph < NSMaxRange(visible) {
            let line = text.lineRange(for: NSRange(location: glyph, length: 0))
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + textView.textContainerInset.height
                  - textView.visibleRect.minY + rect.minY

            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attributes)

            glyph = NSMaxRange(line)
            number += 1
            if line.length == 0 { break }
        }
    }
}
