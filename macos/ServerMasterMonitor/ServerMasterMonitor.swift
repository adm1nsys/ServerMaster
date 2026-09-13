//
//  ServerMasterMonitor.swift
//  ServerMasterMonitor
//
//  What is running, on the desktop. The extension lives in its own process and
//  cannot see the app's memory, so it reads the snapshot the app leaves in
//  Application Support. That works because this extension is not sandboxed —
//  with the sandbox on it would need an App Group instead.
//
//  These types mirror StatusSnapshot in the app. An extension cannot share code
//  with its host without project surgery, so the shape is duplicated here and
//  pinned by a test on the app side.
//

import WidgetKit
import SwiftUI

// MARK: - The snapshot as the widget sees it

struct WidgetStatus: Codable {

    struct Entry: Codable, Identifiable {
        var id: String
        var name: String
        var address: String
        var state: String
        var detail: String?

        var isRunning: Bool { state == "running" }
        var isFailed: Bool { state == "failed" }
        var isBusy: Bool { state == "starting" }

        var colour: Color {
            switch state {
            case "running":  return .green
            case "starting": return .orange
            case "failed":   return .red
            default:         return .secondary
            }
        }
    }

    var updated: Date
    var profiles: [Entry]
    var databaseRunning: Bool
    var adminPanelAddress: String?

    static let placeholder = WidgetStatus(
        updated: Date(),
        profiles: [
            Entry(id: "1", name: "My site", address: "http://127.0.0.1:8080", state: "running", detail: nil),
            Entry(id: "2", name: "Joomla", address: "http://127.0.0.1:8081", state: "stopped", detail: nil),
            Entry(id: "3", name: "API", address: "http://127.0.0.1:3000", state: "failed", detail: "Port taken")
        ],
        databaseRunning: true,
        adminPanelAddress: nil)

    static let empty = WidgetStatus(updated: .distantPast, profiles: [],
                                    databaseRunning: false, adminPanelAddress: nil)

    var runningCount: Int { profiles.filter(\.isRunning).count }
    var failedCount: Int { profiles.filter(\.isFailed).count }

    /// The app has not run yet, or has never written a snapshot.
    var isUnknown: Bool { updated == .distantPast }

    static func read() -> WidgetStatus {
        // The group container, not Application Support: this extension is
        // sandboxed — macOS refuses to register one that is not — so the app's
        // own folder is out of reach.
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "88M5SYPGUR.com.adm1nsys.ServerMaster")
        guard let url = container?.appendingPathComponent("status.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(WidgetStatus.self, from: data)
        else { return .empty }
        return decoded
    }
}

// MARK: - Timeline

struct Provider: TimelineProvider {

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), status: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(),
                               status: context.isPreview ? .placeholder : WidgetStatus.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads the timeline itself whenever anything changes, so this
        // interval is only a safety net for a snapshot written while the widget
        // was asleep.
        let entry = StatusEntry(date: Date(), status: WidgetStatus.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
}

// MARK: - Views

struct ServerMasterMonitorEntryView: View {

    @Environment(\.widgetFamily) private var family
    var entry: StatusEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           list
        }
    }

    // MARK: Small — one number and a colour

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "server.rack")
                Spacer()
                Circle().fill(overallColour).frame(width: 9, height: 9)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if entry.status.isUnknown {
                Text("Not started")
                    .font(.headline)
                Text("Open ServerMaster")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(entry.status.runningCount))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(entry.status.runningCount == 1 ? "server running" : "servers running")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if entry.status.failedCount > 0 {
                Label(String(entry.status.failedCount), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Medium and large — the profiles themselves

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                Text("ServerMaster").fontWeight(.medium)
                Spacer()
                if entry.status.databaseRunning {
                    Image(systemName: "cylinder.split.1x2")
                        .foregroundStyle(.secondary)
                        .help("The database is running")
                }
                Text(entry.status.isUnknown ? "—" : "\(entry.status.runningCount)/\(entry.status.profiles.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Divider()

            if entry.status.isUnknown {
                message("ServerMaster has not run yet.", "Open it once and this fills in.")
            } else if entry.status.profiles.isEmpty {
                message("No profiles yet.", "Create one in ServerMaster.")
            } else {
                ForEach(entry.status.profiles.prefix(rowLimit)) { profile in
                    row(profile)
                }
                if entry.status.profiles.count > rowLimit {
                    Text("and \(entry.status.profiles.count - rowLimit) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func row(_ profile: WidgetStatus.Entry) -> some View {
        HStack(spacing: 7) {
            Circle().fill(profile.colour).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name).font(.caption).lineLimit(1)
                // On the large widget there is room to say why something failed,
                // which is the only thing a glance cannot otherwise tell you.
                if family == .systemLarge, let detail = profile.detail, profile.isFailed {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(profile.address)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if profile.isBusy {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }

    private func message(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).fontWeight(.medium)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var rowLimit: Int { family == .systemLarge ? 10 : 3 }

    private var overallColour: Color {
        if entry.status.failedCount > 0 { return .red }
        if entry.status.runningCount > 0 { return .green }
        return .secondary
    }
}

// MARK: - Widget

struct ServerMasterMonitor: Widget {
    let kind: String = "ServerMasterMonitor"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ServerMasterMonitorEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Servers")
        .description("Which profiles are running, and which one fell over.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    ServerMasterMonitor()
} timeline: {
    StatusEntry(date: Date(), status: .placeholder)
}
