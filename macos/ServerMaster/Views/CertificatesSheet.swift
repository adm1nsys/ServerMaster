//
//  CertificatesSheet.swift
//  ServerMaster
//

import SwiftUI
import AppKit

struct CertificatesSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var onSelect: (CertificatePair) -> Void

    @State private var name = "localhost"
    @State private var domains = "localhost,127.0.0.1,::1"
    @State private var days = 825
    @State private var useMkcert = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Certificates").font(.title2).fontWeight(.semibold)

            GroupBox("Create new") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Name").frame(width: 90, alignment: .leading)
                        TextField("localhost", text: $name)
                    }
                    HStack {
                        Text("Domains and IPs").frame(width: 90, alignment: .leading)
                        TextField("localhost,127.0.0.1", text: $domains)
                            .font(.system(.callout, design: .monospaced))
                    }
                    if !useMkcert {
                        HStack {
                            Text("Validity").frame(width: 90, alignment: .leading)
                            TextField("days", value: $days, format: .number.grouping(.never))
                                .frame(width: 80)
                            Text("days").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    Toggle("Use mkcert instead of openssl", isOn: $useMkcert)
                        .disabled(!model.certificates.mkcert.available)

                    if useMkcert || !model.certificates.mkcert.available {
                        mkcertStatusRow
                    }

                    HStack {
                        Button("Create") { generate() }
                            .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        if busy { ProgressView().controlSize(.small) }
                        Spacer()
                    }

                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
            }

            Text("Existing").font(.callout).fontWeight(.medium)

            List {
                ForEach(model.certificates.certificates) { pair in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: pair.isExpired ? "seal.fill" : "seal")
                            .foregroundStyle(pair.isExpired ? Color.red : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.name).fontWeight(.medium)
                            if !pair.domains.isEmpty {
                                Text(pair.domains.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let notAfter = pair.notAfter {
                                Text(pair.isExpired
                                     ? "Expired \(notAfter.formatted(date: .abbreviated, time: .omitted))"
                                     : "Valid until \(notAfter.formatted(date: .abbreviated, time: .omitted)) (\(pair.daysLeft ?? 0) days)")
                                    .font(.caption2)
                                    .foregroundStyle(pair.isExpired ? .red : .secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("Select") {
                                onSelect(pair)
                                dismiss()
                            }
                            Menu {
                                Button("Trust in system…") {
                                    Task {
                                        let result = await model.certificates.trustInSystemKeychain(pair)
                                        model.notify(result.succeeded
                                                     ? "Certificate added to the system keychain."
                                                     : "Failed: \(result.combined)",
                                                     isError: !result.succeeded)
                                    }
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(pair.certificatePath, inFileViewerRootedAtPath: "")
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task { await model.certificates.delete(pair) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Certificates folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.certificates.path)
                }
                .buttonStyle(.link)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            domains = model.settings.certificateDefaultDomains
            days = model.settings.certificateDefaultDays
            await model.certificates.reload()
            await model.certificates.refreshMkcertStatus()
        }
    }

    @ViewBuilder
    private var mkcertStatusRow: some View {
        let status = model.certificates.mkcert
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.trustedInSystem ? "checkmark.seal.fill"
                              : (status.available ? "exclamationmark.triangle.fill" : "xmark.seal"))
                .foregroundStyle(status.trustedInSystem ? Color.green
                                 : (status.available ? Color.orange : Color.secondary))
            VStack(alignment: .leading, spacing: 3) {
                Text(status.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if status.available && !status.trustedInSystem {
                    Button("Install local CA…") { installCA() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(busy)
                } else if !status.available {
                    Button("Open dependencies") { model.section = .dependencies }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer()
        }
    }

    private func installCA() {
        busy = true
        error = nil
        Task {
            let result = await model.certificates.installMkcertCA()
            busy = false
            if result.succeeded {
                model.notify("The local mkcert CA was added to the system keychain.")
            } else {
                error = result.combined.isEmpty
                    ? "Could not install the CA (code \(String(result.exitCode)))."
                    : result.combined
            }
        }
    }

    private func generate() {
        busy = true
        error = nil
        Task {
            do {
                let pair = useMkcert
                    ? try await model.certificates.generateWithMkcert(name: name, domains: domains)
                    : try await model.certificates.generateSelfSigned(name: name, domains: domains, days: days)
                onSelect(pair)
                busy = false
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
