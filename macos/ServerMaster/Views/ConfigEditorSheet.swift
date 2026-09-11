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
                    .disabled(file.isReadOnly)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    .onChange(of: text) { _, _ in validation = nil }
            }

            validationRow
            footer
        }
        .padding(18)
        .frame(width: 860, height: 660)
        .task { load() }
        .confirmationDialog("This file is overwritten on every start",
                            isPresented: $confirmOverwriteGenerated, titleVisibility: .visible) {
            Button("Make it your own config") { adopt() }
            Button("Save here anyway") { save(force: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("So your changes are not lost, save the file as your own — the app will stop overwriting it and will start the engine with it.")
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
                Button("Reload from disk") { load() }
                    .disabled(!isModified)
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
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if isModified {
                Text("unsaved changes")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer()

            if file.validator != .none && !file.isReadOnly {
                Button("Check syntax") { check() }
                    .disabled(isChecking)
            }

            if !file.isReadOnly {
                Button("Save") { save(force: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isModified || isSaving)
            }
        }
    }

    // MARK: - Actions

    private func load() {
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
            let contents = try String(contentsOfFile: file.path, encoding: .utf8)
            text = contents
            original = contents
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func check() {
        isChecking = true
        Task {
            validation = await ConfigInventory.validate(file, contents: text)
            isChecking = false
        }
    }

    private func save(force: Bool) {
        if file.isGenerated && !force {
            confirmOverwriteGenerated = true
            return
        }
        isSaving = true
        Task {
            // Always check before writing — a broken config must not reach the disk.
            let result = await ConfigInventory.validate(file, contents: text)
            validation = result
            if !result.ok && !result.skipped {
                isSaving = false
                return
            }
            do {
                try text.write(toFile: file.path, atomically: true, encoding: .utf8)
                original = text
                model.notify(String(localized: "File saved: \(file.title)"))
            } catch {
                model.notify(error.localizedDescription, isError: true)
            }
            isSaving = false
        }
    }

    /// Copies the generated config into the user's folder and makes it the main one.
    private func adopt() {
        let name = (file.path as NSString).lastPathComponent
        let target = AppPaths.configs
            .appendingPathComponent("\(model.selectedProfile?.name ?? "profile")-\(name)")
            .path
        isSaving = true
        Task {
            let result = await ConfigInventory.validate(file, contents: text)
            validation = result
            if !result.ok && !result.skipped {
                isSaving = false
                return
            }
            do {
                try text.write(toFile: target, atomically: true, encoding: .utf8)
                original = text
                onAdopt?(target)
                model.notify(String(localized: "Saved as your own config — the app will no longer overwrite it."))
                dismiss()
            } catch {
                model.notify(error.localizedDescription, isError: true)
            }
            isSaving = false
        }
    }
}
