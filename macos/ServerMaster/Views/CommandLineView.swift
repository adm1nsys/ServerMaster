//
//  CommandLineView.swift
//  ServerMaster
//
//  The command line tool: installing it, and what it can do.
//
//  Written as a reference rather than a second control panel. Anything the tool
//  does can be done in the window with fewer keystrokes; the reason to reach for
//  it is a script, a Makefile, or an agent that has no window at all. So this
//  screen answers “how do I call it” and stays out of the way.
//

import SwiftUI
import AppKit

struct CommandLineView: View {

    @Environment(AppModel.self) private var model

    private struct Example: Identifiable {
        var id: String { command }
        var command: String
        var explanation: String
    }

    private let examples: [Example] = [
        Example(command: "servermaster list",
                explanation: String(localized: "Every profile, with its address and whether it is running")),
        Example(command: "servermaster status --json",
                explanation: String(localized: "What is running right now, for a script to read")),
        Example(command: "servermaster start \"My site\"",
                explanation: String(localized: "Start a profile and stay attached; Ctrl-C stops it")),
        Example(command: "servermaster start \"My site\" --no-wait",
                explanation: String(localized: "Start it and return, leaving it to a supervisor")),
        Example(command: "servermaster doctor",
                explanation: String(localized: "What is installed, what is missing, and how to install it")),
        Example(command: "servermaster ports",
                explanation: String(localized: "Which ports are taken, and by which process")),
        Example(command: "servermaster list --json | jq '.profiles[] | select(.state==\"running\")'",
                explanation: String(localized: "The shape everything is built for: pipe it somewhere"))
    ]

    private let codes: [(String, String)] = [
        ("0",  String(localized: "Fine")),
        ("64", String(localized: "The command line itself was wrong")),
        ("65", String(localized: "No profile by that name")),
        ("69", String(localized: "Something it needs is missing, or the port is taken")),
        ("70", String(localized: "It ran and did not work"))
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                ScreenTitle(title: "Command line",
                              subtitle: "Drive ServerMaster from a script, a Makefile or an agent") {
                    Button {
                        AppLinks.open(.index)
                    } label: {
                        Label("Guide", systemImage: "book")
                    }
                }

                installCard
                examplesCard
                exitCodesCard
                agentCard
            }
            .padding(36)
        }
    }

    /// The panels on this screen, on glass over the moving background.
    @ViewBuilder
    private func glassPanel(_ content: some View) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct GlassStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass).controlSize(.small).font(.caption)
            } else {
                content.buttonStyle(.bordered).controlSize(.small).font(.caption)
            }
        }
    }

    // MARK: - Installing

    private var installCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Installation", symbol: "terminal")
                VStack(alignment: .leading, spacing: 10) {
                    switch model.commandLineTool.state {
                    case .working:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }

                    case .installed(let path):
                        HStack(spacing: 10) {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(path)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Remove") { Task { await model.commandLineTool.uninstall() } }
                                .modifier(ChipStyle())
                        }

                    case .pointsElsewhere(let destination):
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Another servermaster is already installed.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(destination)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("Point it at this copy") { Task { await model.commandLineTool.install() } }
                        }

                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try again") { Task { await model.commandLineTool.install() } }
                        }

                    case .notInstalled:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The tool lives inside the app. Installing it puts a link in /usr/local/bin so a shell can find it — a symlink, so updating the app updates the command too.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button {
                                    Task { await model.commandLineTool.install() }
                                } label: {
                                    Label("Install the command", systemImage: "arrow.down.to.line")
                                }
                                .disabled(!model.commandLineTool.isAvailable)
                                Text("Asks for your password once.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !model.commandLineTool.isAvailable {
                                Text("This build does not carry the tool yet.")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .padding(15))
    }

    // MARK: - What it does

    private var examplesCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Commands", symbol: "chevron.left.forwardslash.chevron.right")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                        if index > 0 { Divider().padding(.vertical, 6) }
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.command)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(example.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(example.command, forType: .string)
                                model.notify(String(localized: "Copied."))
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    }
                }
                .padding(6)
            }
            .padding(15))
    }

    private var exitCodesCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Exit codes", symbol: "number")
                VStack(alignment: .leading, spacing: 6) {
                    Text("A script should branch on the exit code rather than on the text, which may be translated.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(codes, id: \.0) { code, meaning in
                        HStack(spacing: 10) {
                            Text(code)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(code == "0" ? Color.green : Color.secondary)
                            Text(meaning).font(.callout)
                            Spacer()
                        }
                    }
                }
                .padding(6)
            }
            .padding(15))
    }

    private var agentCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Notes for scripts and agents", symbol: "cpu")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every command takes --json, and results go to standard output while errors go to standard error. That is what lets output be piped without the two getting mixed.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("A profile can be named in full, by the start of its name, or by its id. An ambiguous name is refused rather than guessed at — starting the wrong server is worse than being asked again.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Stopping is the one thing the tool leaves alone. A server started by this app belongs to it; ending that process from outside would leave the window showing something that is no longer there.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }
            .padding(15))
    }
}
