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

    var body: some View {
        VStack(spacing: 20) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    SplashView(stage: "Checking dependencies…", progress: 0.4)
        .frame(width: 600, height: 400)
}
