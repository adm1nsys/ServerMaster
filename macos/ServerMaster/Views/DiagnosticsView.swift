//
//  DiagnosticsView.swift
//  ServerMaster
//
//  Problems first, everything else underneath.
//
//  The list is deliberately not alphabetical or grouped-by-default: someone
//  opens this screen because something is wrong, and the answer should be the
//  first thing on it. What is healthy is still shown — knowing a check ran and
//  passed is the other half of a diagnosis — but it is out of the way.
//

import SwiftUI
import AppKit

struct DiagnosticsView: View {

    @Environment(AppModel.self) private var model
    @State private var showingHealthy = false
    @State private var tracing: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Diagnostics",
                              subtitle: "What is wrong when everything looks installed") {
                    Button {
                        Task { await model.diagnostics.run(profiles: model.profiles,
                                                           database: model.database) }
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.diagnostics.isRunning)
                }

                if model.diagnostics.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running every check…").foregroundStyle(.secondary)
                    }
                }

                summaryCard
                traceCard

                if !model.diagnostics.problems.isEmpty {
                    card("Needs attention", "exclamationmark.triangle", model.diagnostics.problems)
                }

                DisclosureGroup(isExpanded: $showingHealthy) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(healthy) { finding in
                            row(finding)
                            if finding.id != healthy.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Everything that passed (\(healthy.count))")
                        .font(.headline)
                }
                .disabled(healthy.isEmpty)
            }
            .padding(36)
        }
        .task {
            if model.diagnostics.lastRun == nil {
                await model.diagnostics.run(profiles: model.profiles, database: model.database)
            }
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

    // MARK: - Following one address

    private var traceCard: some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Trace", symbol: "point.topleft.down.to.point.bottomright.curvepath")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Follow an address from the name to the answer. Each profile is traced on its own — two of them on the same host fail in different places.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.profiles.isEmpty {
                        Text("No profiles yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            Text(profile.address)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Trace") {
                                tracing = profile.id
                                Task { await model.trace.run(for: profile) }
                            }
                            .disabled(model.trace.isRunning)
                        }
                        if profile.id != model.profiles.last?.id { Divider() }
                    }

                    if !model.trace.steps.isEmpty || model.trace.isRunning {
                        Divider()
                        HStack(spacing: 8) {
                            if model.trace.isRunning { ProgressView().controlSize(.small) }
                            Text(model.trace.subject)
                                .font(.system(.callout, design: .monospaced))
                        }
                        ForEach(model.trace.steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: symbol(step.outcome))
                                    .foregroundStyle(colour(step.outcome))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(step.title).fontWeight(.medium)
                                        if let elapsed = step.elapsed {
                                            Text("\(Int(elapsed * 1000)) ms")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(step.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(4)
            }
            .padding(15))
    }

    private func symbol(_ outcome: TraceStep.Outcome) -> String {
        switch outcome {
        case .ok:      "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failed:  "xmark.octagon"
        case .skipped: "minus.circle"
        }
    }

    private func colour(_ outcome: TraceStep.Outcome) -> Color {
        switch outcome {
        case .ok:      .green
        case .warning: .orange
        case .failed:  .red
        case .skipped: .secondary
        }
    }

    private var healthy: [Finding] {
        model.diagnostics.findings.filter { $0.level < .warning }
    }

    private var summaryCard: some View {
        glassPanel(
                HStack(spacing: 14) {
                    let broken = model.diagnostics.findings.filter { $0.level == .broken }.count
                    let warnings = model.diagnostics.findings.filter { $0.level == .warning }.count

                    Image(systemName: broken > 0 ? "xmark.octagon.fill"
                          : (warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .font(.title)
                        .foregroundStyle(broken > 0 ? .red : (warnings > 0 ? .orange : .green))

                    VStack(alignment: .leading, spacing: 2) {
                        if broken > 0 {
                            Text("\(broken) broken, \(warnings) worth a look")
                        } else if warnings > 0 {
                            Text("\(warnings) worth a look")
                        } else if model.diagnostics.findings.isEmpty {
                            Text("Nothing checked yet")
                        } else {
                            Text("Nothing wrong found")
                        }
                        if let last = model.diagnostics.lastRun {
                            Text("Checked \(SnapshotStore.readable.string(from: last))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            .padding(15))
    }

    private func card(_ title: LocalizedStringKey, _ symbol: String, _ findings: [Finding]) -> some View {
        glassPanel(
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader(title: title, symbol: symbol)
                ForEach(findings) { finding in
                    row(finding)
                    if finding.id != findings.last?.id { Divider() }
                }
            }
            .padding(15))
    }

    private func row(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.level.symbol)
                .foregroundStyle(colour(finding.level))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title).fontWeight(.medium)
                    Text(finding.group)
                        .font(.caption)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !finding.remedy.isEmpty {
                    Text(finding.remedy)
                        .font(.callout)
                        .foregroundStyle(finding.level >= .warning ? .primary : .secondary)
                }

                if let command = finding.command, finding.level >= .warning {
                    HStack(spacing: 6) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            }
            Spacer()
        }
    }

    private func colour(_ level: Finding.Level) -> Color {
        switch level {
        case .fine:    .green
        case .note:    .secondary
        case .warning: .orange
        case .broken:  .red
        }
    }
}
