//
//  UpdateBanner.swift
//  ServerMaster
//
//  The banner about an available update. Unlike ordinary notifications
//  it does not disappear on its own: it stays until the user opens the build
//  or dismisses it for this version.
//

import SwiftUI

struct UpdateBanner: View {

    @Environment(AppModel.self) private var model
    let release: ReleaseInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(release.version) is available")
                    .font(.callout).fontWeight(.medium)
                Text("Installed \(AppInfo.version). The download is available from the GitHub release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                model.updates.openReleasePage()
            } label: {
                Text("Open release")
            }
            .buttonStyle(.borderedProminent)

            Button("Later") {
                model.dismissUpdate(release.version)
            }

            Button {
                model.dismissUpdate(release.version)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide until the next version")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
