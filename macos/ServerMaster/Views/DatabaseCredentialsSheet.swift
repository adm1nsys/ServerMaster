import SwiftUI
import AppKit

/// A short-lived snapshot, owned only by the presented sheet. It is never
/// persisted in settings, logs or profiles.
struct DatabaseCredentialDetails: Identifiable {
    let id = UUID()
    let database: String
    let host: String
    let port: Int
    let credential: DatabaseCredentialStore.Credential?
    var error: String? = nil
    var sessionOnly = false
}

struct DatabaseCredentialsSheet: View {
    let details: DatabaseCredentialDetails
    @Environment(\.dismiss) private var dismiss
    @State private var showingPassword = false
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Database credentials")
                .font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                field("Host", value: details.host)
                field("Port", value: String(details.port))
                field("Database", value: details.database)
                if let credential = details.credential {
                    Divider()
                    field("User", value: credential.user)
                    HStack(alignment: .top) {
                        Text("Password").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        if showingPassword {
                            Text(verbatim: credential.password)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text("••••••••").accessibilityLabel(Text("Password hidden"))
                        }
                        Spacer()
                    }
                    Toggle("Show password", isOn: $showingPassword)
                        .toggleStyle(.checkbox)
                    if details.sessionOnly {
                        Text("Keychain could not save this password. Copy it now: it is available only until ServerMaster quits.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("The password is saved in Keychain, not in the profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Divider()
                    Text(details.error ?? String(localized: "No saved credentials. Use the account details from your site configuration."))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack {
                if let credential = details.credential {
                    Button(copiedField == "user" ? "Copied" : "Copy user") {
                        copy(credential.user, field: "user")
                    }
                    Button(copiedField == "password" ? "Copied" : "Copy password") {
                        copy(credential.password, field: "password")
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func copy(_ value: String, field: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value, forType: .string) {
            copiedField = field
        }
    }
}
