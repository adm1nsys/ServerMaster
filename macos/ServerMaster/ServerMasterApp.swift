//
//  ServerMasterApp.swift
//  ServerMaster
//

import SwiftUI

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
                AppDelegate.model = model
                await model.bootstrap()
            }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }

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
