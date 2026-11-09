//
//  ConfigEditorSheet.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct ConfigEditorSheet: View {

    let file: ConfigFile
    /// Called when the user has turned the generated config into their own.
    var onAdopt: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var original = ""
    @State private var loadError: String?
    @State private var validation: ConfigInventory.ValidationResult?
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var confirmOverwriteGenerated = false
    @State private var document: TextFileDocument?
    @State private var saveError: String?
    @State private var confirmDiscard = false
    @State private var reloadAfterDiscard = false

    private var isModified: Bool { text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let loadError {
                ContentUnavailableView("Could not open the file", systemImage: "doc.questionmark",
                                       description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .disabled(file.isReadOnly || isSaving || isChecking)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    .onChange(of: text) { _, _ in validation = nil }
            }

            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            validationRow
            footer
                .confirmationDialog("This file is overwritten on every start",
                                    isPresented: $confirmOverwriteGenerated, titleVisibility: .visible) {
                    Button("Make it your own config") { adopt() }
                    Button("Save here anyway") { save(force: true) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("So your changes are not lost, save the file as your own — the app will stop overwriting it and will start the engine with it.")
                }
        }
        .padding(18)
        .frame(width: 860, height: 660)
        .task { load() }
        .interactiveDismissDisabled(isModified || isSaving || isChecking)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                if reloadAfterDiscard { load() } else { dismiss() }
            }
            Button("Keep editing", role: .cancel) { }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: file.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.title).font(.headline)
                    if file.isGenerated {
                        Text("generated")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if file.isReadOnly {
                        Text("read only")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(AppPaths.abbreviate(file.path))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let document { Text(document.format.label).font(.caption).foregroundStyle(.secondary) }
                if !file.note.isEmpty {
                    Text(file.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Menu {
                Button("Open in external editor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
                Divider()
                Button("Reload from disk") { requestClose(reload: true) }
                    .disabled(isSaving || isChecking)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Check result

    @ViewBuilder
    private var validationRow: some View {
        if isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking syntax…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let validation {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: validation.skipped ? "info.circle"
                                  : (validation.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                    .foregroundStyle(validation.skipped ? Color.secondary
                                     : (validation.ok ? Color.green : Color.red))
                VStack(alignment: .leading, spacing: 2) {
                    Text(validation.skipped ? "No syntax check is available for this file type."
                         : (validation.ok ? "Syntax is fine." : "Syntax error."))
                        .font(.caption)
                        .fontWeight(.medium)
                    if !validation.message.isEmpty {
                        ScrollView {
                            Text(validation.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 70)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Buttons

    private var footer: some View {
        HStack {
            Button("Close") { requestClose() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving || isChecking)

            if isModified {
                Text("unsaved changes")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer()

            if file.validator != .none && !file.isReadOnly {
                Button("Check syntax") { check() }
                    .disabled(isChecking || isSaving || document == nil)
            }

            if !file.isReadOnly {
                Button("Save") { save(force: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isModified || isSaving || isChecking || document == nil)
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard !isSaving, !isChecking else { return }
        document = nil
        validation = nil
        saveError = nil
        if !file.exists {
            // Generated configs only appear after the first launch.
            text = ""
            original = ""
            loadError = file.isGenerated
                ? String(localized: "The file appears after the profile is started once.")
                : String(localized: "File not found: \(file.path)")
            return
        }
        do {
            let loaded = try TextFileDocument.load(URL(fileURLWithPath: file.path))
            document = loaded
            text = loaded.text
            original = loaded.text
            loadError = nil
        } catch {
            text = ""
            original = ""
            loadError = error.localizedDescription
        }
    }

    private func requestClose(reload: Bool = false) {
        guard !isSaving, !isChecking else { return }
        reloadAfterDiscard = reload
        if isModified { confirmDiscard = true }
        else if reload { load() }
        else { dismiss() }
    }

    private func check() {
        guard !isChecking, !isSaving, let loaded = document else { return }
        let draft = text
        guard let bytes = try? loaded.format.encode(draft) else {
            saveError = TextFileDocument.Failure.tooLarge.localizedDescription
            return
        }
        isChecking = true
        Task {
            validation = await ConfigInventory.validate(file, contents: draft, encodedContents: bytes)
            isChecking = false
        }
    }

    private func save(force: Bool) {
        guard !isSaving, !isChecking, !file.isReadOnly, isModified, var loaded = document else { return }
        if file.isGenerated && !force {
            confirmOverwriteGenerated = true
            return
        }
        isSaving = true
        saveError = nil
        let draft = text
        Task {
            defer { isSaving = false }
            let bytes: Data
            do { bytes = try loaded.format.encode(draft) }
            catch { saveError = error.localizedDescription; return }
            // Always check before writing — a broken config must not reach the disk.
            let result = await ConfigInventory.validate(file, contents: draft, encodedContents: bytes)
            validation = result
            if !result.ok && !result.skipped {
                return
            }
            do {
                try loaded.save(draft)
                document = loaded
                original = draft
                model.notify(String(localized: "File saved: \(file.title)"))
            } catch {
                saveError = error.localizedDescription
                model.notify(error.localizedDescription, isError: true)
            }
        }
    }

    /// Copies the generated config into the user's folder and makes it the main one.
    private func adopt() {
        guard !isSaving, !isChecking, !file.isReadOnly, let loaded = document else { return }
        let name = (file.path as NSString).lastPathComponent
        let prefix = String((model.selectedProfile?.name ?? "profile").prefix(40).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let target = AppPaths.configs
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)-\(name)")
        isSaving = true
        saveError = nil
        let draft = text
        Task {
            defer { isSaving = false }
            let bytes: Data
            do { bytes = try loaded.format.encode(draft) }
            catch { saveError = error.localizedDescription; return }
            let result = await ConfigInventory.validate(file, contents: draft, encodedContents: bytes)
            validation = result
            if !result.ok && !result.skipped {
                return
            }
            do {
                try loaded.writeCopy(draft, to: target)
                original = draft
                onAdopt?(target.path)
                model.notify(String(localized: "Saved as your own config — the app will no longer overwrite it."))
                dismiss()
            } catch {
                saveError = error.localizedDescription
                model.notify(error.localizedDescription, isError: true)
            }
        }
    }
}
