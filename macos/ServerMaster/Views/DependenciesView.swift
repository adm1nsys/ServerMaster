//
//  DependenciesView.swift
//  ServerMaster
//

import SwiftUI

struct DependenciesView: View {

    @Environment(AppModel.self) private var model
    @State private var installing: String?
    @State private var installLog = ConsoleLog()
    @State private var showInstallLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                SectionHeader(title: "Dependencies",
                              subtitle: "What each configuration needs in order to start") {
                    HStack {
                        if model.dependencies.isChecking { ProgressView().controlSize(.small) }
                        Button {
                            Task { await model.dependencies.checkAll() }
                        } label: {
                            Label("Check all", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.dependencies.isChecking)

                        Button {
                            AppLinks.open(.install)
                        } label: {
                            Label("Guide", systemImage: "book")
                        }
                        .help("What each engine needs, and how to install it")
                    }
                }

                engineMatrix

                ForEach(DependencyKind.allCases, id: \.self) { kind in
                    let items = Dependency.catalog.filter { $0.kind == kind }
                    if !items.isEmpty {
                        GroupBox {
                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, dependency in
                                    if index > 0 { Divider() }
                                    dependencyRow(dependency)
                                }
                            }
                            .padding(4)
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                }

                if showInstallLog {
                    GroupBox {
                        LogOutputView(log: installLog, fontSize: 11)
                            .frame(height: 220)
                    } label: {
                        HStack {
                            Text("Install log")
                            Spacer()
                            Button("Hide") { showInstallLog = false }.buttonStyle(.link)
                        }
                    }
                }

                pathCard

                if let last = model.dependencies.lastCheck {
                    Text("Last check: \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            if model.dependencies.lastCheck == nil {
                await model.dependencies.checkAll()
            }
        }
    }

    // MARK: - Engine readiness

    private var engineMatrix: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(ServerEngine.allCases.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { Divider() }
                    let missing = model.dependencies.missingTools(for: engine)
                    HStack(spacing: 10) {
                        Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(missing.isEmpty ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(engine.title).fontWeight(.medium)
                            Text(missing.isEmpty
                                 ? (engine.requiredTools.isEmpty ? "No external dependencies" : "All present: " + engine.requiredTools.joined(separator: ", "))
                                 : "Missing: " + missing.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let count = model.profiles.filter { $0.engine == engine }.count
                        if count > 0 {
                            Text("\(count) prof.")
                                .font(.caption)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(4)
        } label: {
            Label("Configuration readiness", systemImage: "square.grid.2x2")
        }
    }

    // MARK: - Dependency row

    private func dependencyRow(_ dependency: Dependency) -> some View {
        let status = model.dependencies.status(for: dependency.command)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.installed ? "checkmark.circle.fill" : (dependency.required ? "exclamationmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(status.installed ? Color.green : (dependency.required ? Color.red : Color.secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.title).fontWeight(.medium)
                    Text(dependency.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if dependency.required {
                        Text("required")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(dependency.summary).font(.caption).foregroundStyle(.secondary)
                if status.installed {
                    if let version = status.version {
                        Text(version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let path = status.path {
                        Text(AppPaths.abbreviate(path))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(dependency.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if status.checking || installing == dependency.command {
                    ProgressView().controlSize(.small)
                } else if !status.installed && dependency.command != "lsof" {
                    Button("Install") {
                        install(dependency)
                    }
                    .disabled(installing != nil)
                }
                Button {
                    Task { await model.dependencies.check(command: dependency.command) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again")
            }
        }
        .padding(.vertical, 7)
    }

    private func install(_ dependency: Dependency) {
        installing = dependency.command
        showInstallLog = true
        Task {
            await model.dependencies.install(dependency, log: installLog)
            installing = nil
        }
    }

    // MARK: - PATH

    private var pathCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("The app looks for executables in these directories. Extra paths are configured in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(ShellEnvironment.shared.path.replacingOccurrences(of: ":", with: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("PATH", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
    }
}
