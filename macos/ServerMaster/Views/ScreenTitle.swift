//
//  ScreenTitle.swift
//  ServerMaster
//
//  The heading every section starts with.
//
//  One type rather than each screen writing its own. Two screens that set their
//  own font size drift apart the moment one of them is worked on, which is
//  exactly what happened: Control had a large rounded title and Database still
//  had a small one, and side by side they looked like different applications.
//

import SwiftUI

struct ScreenTitle<Actions: View>: View {

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }
}

extension ScreenTitle where Actions == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The heading inside a glass panel: an icon, a name, and whatever the panel
/// lets you do.
struct PanelHeader<Actions: View>: View {

    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .fontWeight(.medium)
            Spacer()
            actions()
        }
    }
}

extension PanelHeader where Actions == EmptyView {
    init(title: LocalizedStringKey, symbol: String) {
        self.init(title: title, symbol: symbol) { EmptyView() }
    }
}
