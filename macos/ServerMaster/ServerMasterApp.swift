//
//  ServerMasterApp.swift
//  ServerMaster
//

import SwiftUI
import AppKit

/// Quitting is intercepted so the servers can be shut down properly in time.
final class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.model, model.needsGracefulShutdown else { return .terminateNow }
        model.beginShutdown {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ServerMasterApp: App {

    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The language override must reach UserDefaults before the system
        // assembles the list of localizations.
        AppLanguage.apply(AppModel.storedLanguage())
    }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isShuttingDown {
                    ShutdownView()
                        .transition(.opacity)
                } else if model.isBootstrapping {
                    SplashView(stage: model.bootstrapStage,
                               progress: model.bootstrapProgress)
                        .transition(.opacity)
                } else {
                    ContentView()
                        .transition(.opacity)
                }
            }
            .environment(model)
            .frame(minWidth: 940, minHeight: 600)
            .animation(.easeInOut(duration: 0.25), value: model.isBootstrapping)
            .animation(.easeInOut(duration: 0.2), value: model.isShuttingDown)
            .task {
                // Before anything is drawn: an imported translation has to be
                // in place before the first string is looked up.
                TranslationOverride.install()
                AppDelegate.model = model
                await model.bootstrap()
            }
        }
        // The title bar stays. Hiding it was tried and reverted: without it the
        // window keeps the same strip at the top, only now it is empty and dark
        // on every screen instead of carrying the title.
        .defaultSize(width: 1120, height: 720)

        // Next to Control Center: the state of every profile without switching
        // windows, and start/stop/restart without opening the app at all.
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // macOS puts documentation under Help, so that is where the guides go.
            CommandGroup(replacing: .help) {
                Button("ServerMaster Guides") { AppLinks.open(.index) }
                    .keyboardShortcut("?", modifiers: [.command])

                Divider()

                Button("Getting started") { AppLinks.open(.install) }
                Button("Running a CMS") { AppLinks.open(.joomla) }
                Button("Errors and what they mean") { AppLinks.open(.errors) }

                Divider()

                Button("Website") { NSWorkspace.shared.open(AppLinks.site) }
                Button("Report a problem") { NSWorkspace.shared.open(AppLinks.issues) }
            }

            CommandMenu("Server") {
                Button("Start profile") {
                    if let profile = model.selectedProfile {
                        Task { await model.startServer(profile: profile) }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.selectedProfile.map { model.isActive($0.id) } ?? true)

                Button("Stop") {
                    if let id = model.selectedProfileID {
                        Task { await model.stopServer(profileID: id) }
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(model.selectedProfileID.map { !model.isActive($0) } ?? true)

                Button("Restart") {
                    if let profile = model.selectedProfile {
                        Task { await model.restartServer(profile: profile) }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedProfile == nil)

                Divider()

                Button("Start all profiles") {
                    Task {
                        for profile in model.profiles where !model.isActive(profile.id) {
                            await model.startServer(profile: profile)
                        }
                    }
                }
                Button("Stop all") {
                    Task { await model.stopAll() }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(model.activeCount == 0)

                Divider()

                Button("Open in browser") {
                    model.existingController(for: model.selectedProfileID)?.openInBrowser()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selectedProfileID.map { model.state(of: $0) != .running } ?? true)

                Button("Refresh port list") {
                    Task { await model.refreshPorts() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            AppSettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
        }
    }
}
