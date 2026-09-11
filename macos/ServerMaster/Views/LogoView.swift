//
//  LogoView.swift
//  ServerMaster
//
//  The application's own icon, shown inside the app — on the splash screen,
//  in About, in Settings and in the shutdown window.
//
//  It is deliberately not a separate drawing: the icon is read from the bundle,
//  so replacing AppIcon.icon changes every one of those places at once and the
//  logo can never drift from what the Dock shows.
//

import SwiftUI
import AppKit

struct LogoView: View {

    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// AppKit caches the named image, so looking it up on each redraw is cheap.
    private var icon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSApplication.shared.applicationIconImage
    }
}

#Preview {
    HStack(spacing: 20) {
        LogoView(size: 128)
        LogoView(size: 64)
    }
    .padding(40)
}
