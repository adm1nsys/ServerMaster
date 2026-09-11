//
//  ShutdownView.swift
//  ServerMaster
//
//  The waiting window shown on quit: the application does not close until
//  every server has been stopped properly.
//

import SwiftUI

struct ShutdownView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            LogoView(size: 84)

            VStack(spacing: 6) {
                Text("Shutting down")
                    .font(.title3).fontWeight(.semibold)
                Text("Stopping the servers so they do not linger in the system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProgressView(value: model.shutdownProgress)
                .progressViewStyle(.linear)
                .frame(width: 280)

            if !model.shutdownItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.shutdownItems) { item in
                        HStack(spacing: 8) {
                            switch item.status {
                            case .waiting:
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                            case .stopping:
                                ProgressView().controlSize(.small)
                            case .stopped:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .forced:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(item.name)
                                .font(.callout)
                            Spacer()
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 320)
                    }
                }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if model.shutdownTookTooLong {
                VStack(spacing: 8) {
                    Text("The server is taking longer than usual to respond.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Force quit") {
                        model.forceQuit()
                    }
                }
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    ShutdownView().environment(AppModel())
        .frame(width: 600, height: 420)
}
