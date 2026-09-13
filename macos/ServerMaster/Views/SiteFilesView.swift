//
//  SiteFilesView.swift
//  ServerMaster
//
//  The files a site is configured by, including the ones Finder hides.
//
//  This is not a file manager and is not trying to be one. It answers one
//  question: where are the dotfiles, and let me open one. Joomla, WordPress and
//  every framework since put the thing you need to edit behind a leading dot —
//  .htaccess, .env, .user.ini — and Finder's answer is a keystroke people either
//  know or do not, followed by a folder full of everything else.
//
//  So: hidden files first, config files called out by name, everything else
//  behind a switch.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SiteFilesView: View {

    @Environment(AppModel.self) private var model

    @State private var profileID: UUID?
    @State private var entries: [Entry] = []
    @State private var showingEverything = false
    @State private var editing: URL?
    @State private var renaming: Entry?
    @State private var newName = ""
    @State private var problem: String?
    /// Where we are, relative to the profile's folder. Empty is the root.
    @State private var path: [String] = []

    struct Entry: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var name: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date
        var isHidden: Bool
        /// Files worth pointing at before anything else.
        var isConfig: Bool
    }

    private var profile: ServerProfile? {
        model.profiles.first { $0.id == profileID } ?? model.profiles.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Files",
                            subtitle: "The hidden ones, and the ones worth editing") {
                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .modifier(GlassStyle())
                }

                picker
                breadcrumbs

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }

                if !hidden.isEmpty { card("Hidden and config files", "eye.slash", hidden) }

                glassPanel(
                    DisclosureGroup(isExpanded: $showingEverything) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(visible) { entry in
                                row(entry)
                                if entry.id != visible.last?.id { Divider() }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Everything else (\(visible.count))").fontWeight(.medium)
                    }
                    .padding(15))
                .disabled(visible.isEmpty)
            }
            .padding(36)
        }
        .sheet(item: Binding(get: { editing.map { EditTarget(url: $0) } },
                             set: { editing = $0?.url })) { target in
            FileEditorSheet(url: target.url) { reload() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil },
                                              set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("A file starting with a dot is hidden by Finder. That is the only thing the dot does.")
        }
        .onAppear { if profileID == nil { profileID = model.profiles.first?.id }; reload() }
    }

    private struct EditTarget: Identifiable { var url: URL; var id: String { url.path } }

    // MARK: - Which folder

    private var picker: some View {
        HStack(spacing: 10) {
            // Label-less, with the profile's own icon in the row. A Picker with
            // a title reserves a column for that title on macOS, which is where
            // the empty gap on the left came from.
            Picker("", selection: Binding(get: { profile?.id },
                                          set: { profileID = $0; path = []; reload() })) {
                ForEach(model.profiles) { item in
                    Label(item.name, systemImage: item.symbol).tag(Optional(item.id))
                }
            }
            .labelsHidden()
            .frame(width: 240)

            if profile != nil {
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: currentFolder.path)
                }
                .modifier(ChipStyle())
            }
        }
    }

    /// The folder being shown: the profile's root plus wherever we have walked.
    private var currentFolder: URL {
        var url = URL(fileURLWithPath: AppPaths.expand(profile?.rootPath ?? ""), isDirectory: true)
        for component in path { url.appendPathComponent(component, isDirectory: true) }
        return url
    }

    /// Root, then each folder walked into. Clicking one goes back to it — the
    /// same bargain Finder's path bar makes, and the reason a list you can only
    /// descend into is annoying.
    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button {
                path = []
                reload()
            } label: {
                Label(profile?.name ?? "—", systemImage: "house")
            }
            .modifier(ChipStyle())

            ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button(component) {
                    path = Array(path.prefix(index + 1))
                    reload()
                }
                .modifier(ChipStyle())
                .disabled(index == path.count - 1)
            }
            Spacer()
            // Was .tertiary, which on this background is barely there. The path
            // is the one thing on this bar you might actually need to read.
            Text(AppPaths.abbreviate(currentFolder.path))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.head)
        }
    }

    private var hidden: [Entry] { entries.filter { $0.isHidden || $0.isConfig } }
    private var visible: [Entry] { entries.filter { !$0.isHidden && !$0.isConfig } }

    // MARK: - The list

    private func card(_ title: LocalizedStringKey, _ symbol: String, _ list: [Entry]) -> some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 6) {
                PanelHeader(title: title, symbol: symbol)
                ForEach(list) { entry in
                    row(entry)
                    if entry.id != list.last?.id { Divider() }
                }
            }
            .padding(15))
    }

    /// The panels on this screen, on glass over the moving background.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }

    private struct GlassStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass).controlSize(.small).font(.caption)
            } else {
                content.buttonStyle(.bordered).controlSize(.small).font(.caption)
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : (entry.isHidden ? "eye.slash" : "doc"))
                .foregroundStyle(entry.isHidden ? .orange : .secondary)
                .frame(width: 16)

            if entry.isDirectory {
                Button(entry.name) {
                    path.append(entry.name)
                    reload()
                }
                .modifier(ChipStyle())
                .font(.system(.body, design: entry.isHidden ? .monospaced : .default))
            } else {
                Text(entry.name)
                    .font(.system(.body, design: entry.isHidden ? .monospaced : .default))
            }

            Spacer()

            if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(SnapshotStore.readable.string(from: entry.modified))
                .font(.caption).foregroundStyle(.secondary)

            if !entry.isDirectory {
                Button("Edit") { editing = entry.url }
                    .modifier(ChipStyle())
                    .disabled(entry.size > 4_000_000)
                    .help(entry.size > 4_000_000
                          ? String(localized: "Too large to open here — use another editor.")
                          : String(localized: "Open in ServerMaster's editor"))
            }

            Menu {
                ForEach(openers(for: entry.url), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) {
                        NSWorkspace.shared.open([entry.url], withApplicationAt: app,
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                Button("Rename…") {
                    renaming = entry
                    newName = entry.name
                }
                // Finder refuses to make a name that starts with a dot, so the
                // only way to turn Joomla's shipped “htaccess.txt” into a real
                // “.htaccess” has been the terminal. It is one rename.
                if let suggestion = Self.dottedName(for: entry.name) {
                    Button("Rename to \(suggestion)") { rename(entry, to: suggestion) }
                } else if entry.isHidden, entry.name.count > 1 {
                    Button("Remove the leading dot") {
                        rename(entry, to: String(entry.name.dropFirst()))
                    }
                }
                Button("Get Info") { showInfo(entry) }
                    .keyboardShortcut("i")
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.url.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                path.append(entry.name)
                reload()
            } else if entry.size <= 4_000_000 {
                editing = entry.url
            }
        }
    }

    /// Which apps can open this. Asked of macOS rather than guessed, so whatever
    /// is installed shows up — and a dotfile with no extension still offers the
    /// editors, because it is handed to the system as plain text.
    private func openers(for url: URL) -> [URL] {
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if apps.isEmpty, let text = UTType.plainText.preferredFilenameExtension {
            let stand_in = URL(fileURLWithPath: "/private/tmp/servermaster.\(text)")
            apps = NSWorkspace.shared.urlsForApplications(toOpen: stand_in)
        }
        return Array(apps.prefix(8))
    }

    /// Finder's own info window, asked for by name.
    ///
    /// Reimplementing it would mean reproducing permissions, tags, quarantine,
    /// open-with and preview — all of which Finder already shows, and shows in
    /// the form people recognise. This asks Finder to show its own.
    private func showInfo(_ entry: Entry) {
        let script = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(entry.url.path)" as alias)
        end tell
        """
        guard let apple = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if error != nil {
            // Finder refused or is not scriptable here. Selecting the file is
            // the honest fallback: ⌘I then works, one keystroke away.
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }

    // MARK: - Reading the folder

    private func reload() {
        problem = nil
        entries = []
        guard profile != nil else { return }
        let root = currentFolder

        guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []) else {
            problem = String(localized: "\(AppPaths.abbreviate(root.path)) cannot be read.")
            return
        }

        entries = contents.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                           .contentModificationDateKey])
            let name = url.lastPathComponent
            return Entry(url: url,
                         name: name,
                         isDirectory: values?.isDirectory ?? false,
                         size: Int64(values?.fileSize ?? 0),
                         modified: values?.contentModificationDate ?? .distantPast,
                         isHidden: name.hasPrefix("."),
                         isConfig: Self.configNames.contains(name.lowercased()))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Files that are not hidden but are the ones people came for.
    private static let configNames: Set<String> = [
        "configuration.php", "wp-config.php", "settings.php", "config.php",
        "nginx.conf", "caddyfile", "package.json", "composer.json",
        "docker-compose.yml", "index.php", "web.config"
    ]

    /// The dotted name a file is obviously trying to be.
    ///
    /// Projects ship these with a suffix because a leading dot makes the file
    /// invisible in every archive tool and half the editors: Joomla has
    /// htaccess.txt, others use htaccess.dist or dot.env. Renaming is the
    /// documented step, and the one nobody can do in Finder.
    static func dottedName(for name: String) -> String? {
        let lower = name.lowercased()
        guard !name.hasPrefix(".") else { return nil }

        for base in ["htaccess", "env", "gitignore", "user.ini", "htpasswd", "editorconfig"] {
            for suffix in [".txt", ".dist", ".example", ".sample", ".default", ""] {
                if lower == base + suffix, !(base == "env" && suffix.isEmpty) {
                    return "." + base
                }
            }
        }
        // dot.env, dot-gitignore
        if lower.hasPrefix("dot.") || lower.hasPrefix("dot-") {
            return "." + name.dropFirst(4)
        }
        return nil
    }

    private func rename(_ entry: Entry, to name: String) {
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            problem = String(localized: "“\(name)” already exists in that folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: target)
            reload()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let renaming else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != renaming.name,
              !trimmed.contains("/") else {
            self.renaming = nil
            return
        }
        rename(renaming, to: trimmed)
        self.renaming = nil
    }
}
