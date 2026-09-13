//
//  SplashView.swift
//  ServerMaster
//
//  The loading screen: shown while dependencies are checked and profiles are read.
//

import SwiftUI

struct SplashView: View {

    let stage: String
    let progress: Double
    /// Read straight from disk rather than from the model: this is shown while
    /// the model is still being built, so there is nothing to ask yet.
    var settings: AppSettings = AppSettings.load()

    var body: some View {
        ZStack {
            if settings.backgroundEnabled {
                AmbientBackground(colours: [],
                                  isActive: false,
                                  hue: settings.backgroundHue,
                                  speed: settings.backgroundSpeed,
                                  saturation: settings.backgroundSaturation)
            }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.backgroundEnabled ? AnyShapeStyle(.clear) : AnyShapeStyle(.background))
    }

    private var card: some View {
        let content = VStack(spacing: 20) {
            LogoView(size: 104)

            VStack(spacing: 5) {
                Text(AppInfo.name)
                    .font(.title2).fontWeight(.semibold)
                Text(AppInfo.versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 16)
                    .animation(.default, value: stage)
            }
        }
        .padding(36)

        return Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 18))
            } else {
                content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}

#Preview {
    SplashView(stage: "Checking dependencies…", progress: 0.4)
        .frame(width: 600, height: 400)
}
