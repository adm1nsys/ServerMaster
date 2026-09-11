//
//  PortsView.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct PortsView: View {

    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var killCandidate: PortEntry?
    @State private var details: String?
    @State private var reservePort = ""
    @State private var reserveNote = ""
    @State private var reserveError: String?
    @State private var sortOrder = [KeyPathComparator(\PortEntry.port)]
    @State private var selection: PortEntry.ID?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Divider()

            if model.settings.portReservationsEnabled {
                reservationsBar
                Divider()
            }

            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Port", value: \.port) { entry in
                    HStack(spacing: 5) {
                        Text(String(entry.port))
                            .font(.system(.body, design: .monospaced))
                        if model.reserver.isReserved(entry.port) {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Process", value: \.command) { entry in
                    HStack(spacing: 5) {
                        Text(entry.command).lineLimit(1)
                        if let owner = model.ownedProfile(forPID: entry.pid) {
                            Text(owner.name)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                }
                .width(min: 120, ideal: 180)

                TableColumn("PID", value: \.pid) { entry in
                    Text(String(entry.pid)).font(.system(.body, design: .monospaced))
                }
                .width(min: 55, ideal: 65, max: 80)

                TableColumn("User", value: \.user) { entry in
                    Text(entry.user).foregroundStyle(entry.isSystemProcess ? .secondary : .primary)
                }
                .width(min: 80, ideal: 110)

                TableColumn("Protocol", value: \.proto) { entry in
                    Text("\(entry.proto) · \(entry.family)").font(.caption)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Address", value: \.address) { entry in
                    Text(entry.displayAddress).font(.system(.caption, design: .monospaced))
                }
                .width(min: 90, ideal: 130)

                TableColumn("") { entry in
                    HStack(spacing: 6) {
                        if entry.proto == "TCP", let url = entry.localURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .help("Open in browser")
                        }
                        Button {
                            Task { details = await PortScanner.processDetails(pid: entry.pid) }
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Process details")

                        Button {
                            requestKill(entry)
                        } label: {
                            Image(systemName: "xmark.octagon")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Terminate process")
                    }
                }
                .width(min: 90, ideal: 96, max: 110)
            }
            .onChange(of: sortOrder) { _, order in
                model.portEntries.sort(using: order)
            }
            .contextMenu(forSelectionType: PortEntry.ID.self) { ids in
                if let id = ids.first, let entry = model.portEntries.first(where: { $0.id == id }) {
                    Button("Terminate process") { requestKill(entry) }
                    Button("Terminate as administrator") {
                        Task { await model.killPortAsAdmin(entry, signal: model.settings.defaultKillSignal) }
                    }
                    Divider()
                    Button("Copy PID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(entry.pid), forType: .string)
                    }
                    Button("Details") {
                        Task { details = await PortScanner.processDetails(pid: entry.pid) }
                    }
                }
            }

            Divider()
            footer
        }
        .task {
            await model.refreshPorts()
            model.startPortAutoRefresh()
        }
        .onDisappear { model.stopPortAutoRefresh() }
        .confirmationDialog(killPrompt,
                            isPresented: Binding(get: { killCandidate != nil },
                                                 set: { if !$0 { killCandidate = nil } })) {
            if let entry = killCandidate {
                Button("Terminate (\(model.settings.defaultKillSignal.rawValue))", role: .destructive) {
                    Task { await model.killPort(entry, signal: model.settings.defaultKillSignal) }
                    killCandidate = nil
                }
                Button("Force (SIGKILL)", role: .destructive) {
                    Task { await model.killPort(entry, signal: .kill) }
                    killCandidate = nil
                }
                Button("As administrator…") {
                    Task { await model.killPortAsAdmin(entry, signal: .term) }
                    killCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { killCandidate = nil }
        }
        .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Process").font(.headline)
                ScrollView {
                    Text(details ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Close") { details = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 640, height: 300)
        }
    }

    private var killPrompt: String {
        guard let entry = killCandidate else { return "Terminate the process?" }
        return "Terminate \(entry.command) (PID \(String(entry.pid))) holding port \(entry.port)?"
    }

    private func requestKill(_ entry: PortEntry) {
        if model.settings.confirmBeforeKill {
            killCandidate = entry
        } else {
            Task { await model.killPort(entry, signal: model.settings.defaultKillSignal) }
        }
    }

    private func isOurServer(_ entry: PortEntry) -> Bool {
        model.ownedProfile(forPID: entry.pid) != nil
    }

    private var filtered: [PortEntry] {
        var entries = model.portEntries
        if !model.settings.portsShowSystemProcesses {
            entries = entries.filter { !$0.isSystemProcess }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.command.localizedCaseInsensitiveContains(query)
            || String($0.port).contains(query)
            || String($0.pid).contains(query)
            || $0.user.localizedCaseInsensitiveContains(query)
            || $0.address.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        @Bindable var model = model

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ports").font(.title3).fontWeight(.semibold)
                Text("Who is listening and how to free it")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search: port, process, PID", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)

            Toggle("UDP", isOn: $model.settings.portsIncludeUDP)
                .toggleStyle(.checkbox)
                .onChange(of: model.settings.portsIncludeUDP) { _, _ in
                    model.saveSettings()
                    Task { await model.refreshPorts() }
                }

            Toggle("System", isOn: $model.settings.portsShowSystemProcesses)
                .toggleStyle(.checkbox)
                .onChange(of: model.settings.portsShowSystemProcesses) { _, _ in model.saveSettings() }

            if model.isScanningPorts { ProgressView().controlSize(.small) }

            Button {
                Task { await model.refreshPorts() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("\(filtered.count) of \(model.portEntries.count) sockets")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.settings.portsAutoRefresh {
                Text("Auto refresh every \(Int(model.settings.portsRefreshInterval)) s")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Reservation

    private var reservationsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Reservation").font(.callout).fontWeight(.medium)
                TextField("port", text: $reservePort)
                    .frame(width: 80)
                TextField("why", text: $reserveNote)
                    .frame(width: 180)
                Button("Reserve") { reserve() }
                    .disabled(Int(reservePort) == nil)
                if let reserveError {
                    Text(reserveError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }

            if !model.reserver.reservations.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.reserver.reservations) { reservation in
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill").font(.caption2)
                            Text(String(reservation.port)).font(.system(.caption, design: .monospaced))
                            if !reservation.note.isEmpty {
                                Text(reservation.note).font(.caption2).foregroundStyle(.secondary)
                            }
                            Button {
                                model.reserver.release(port: reservation.port)
                                Task { await model.refreshPorts() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                }
            }

            Text("A reservation holds the port with a socket inside the app — you cannot start a server on it until the reservation is released. It is released on quit.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func reserve() {
        guard let port = Int(reservePort) else { return }
        reserveError = nil
        do {
            try model.reserver.reserve(port: port, note: reserveNote)
            reservePort = ""
            reserveNote = ""
            Task { await model.refreshPorts() }
        } catch {
            reserveError = error.localizedDescription
        }
    }
}
