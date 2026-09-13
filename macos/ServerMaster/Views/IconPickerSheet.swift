//
//  IconPickerSheet.swift
//  ServerMaster
//
//  Choosing a profile icon by looking at it.
//
//  It used to be a menu, where each row was the symbol's system name next to a
//  small glyph — “externaldrive.connected.to.line.below” tells you nothing, and
//  the glyph was too small to tell them apart. A grid shows the icons at a size
//  where the choice is obvious, which is the whole point of having icons.
//

import SwiftUI

struct IconPickerSheet: View {

    /// The engine's own icon, offered as the default.
    let engineSymbol: String
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    private var groups: [ProfileIcons.Group] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return ProfileIcons.groups }
        return ProfileIcons.groups.compactMap { group in
            let matches = group.symbols.filter { $0.contains(needle) }
            return matches.isEmpty ? nil : ProfileIcons.Group(title: group.title, symbols: matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile icon").font(.headline)
                    Text("Shown in the lists and in the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The engine's icon first, because “whatever this engine
                    // uses” is the right answer for most profiles.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default").font(.caption).foregroundStyle(.secondary)
                        cell(engineSymbol, isSelected: selection.isEmpty, label: "Same as the engine") {
                            selection = ""
                        }
                    }

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 8)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(group.symbols, id: \.self) { symbol in
                                    cell(symbol, isSelected: selection == symbol) {
                                        selection = symbol
                                    }
                                }
                            }
                        }
                    }

                    if groups.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(height: 160)
                    }
                }
                .padding(14)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search icons")
        .frame(width: 460, height: 480)
    }

    @ViewBuilder
    private func cell(_ symbol: String, isSelected: Bool, label: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 34)
                if let label {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: label == nil ? nil : .infinity, alignment: .center)
            .padding(.vertical, 4)
            .padding(.horizontal, label == nil ? 0 : 8)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}
