//
//  FirstSetupSheet.swift
//  ServerMaster
//
//  The Windows edition asks one useful question on a genuinely fresh install:
//  what should the first local site be?  Keep the same short, dismissible
//  entry point on macOS and hand the actual work to the regular profile wizard.
//

import SwiftUI

struct FirstSetupSheet: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var templateID = "static"
    @State private var showingProfileWizard = false

    private var templates: [ProfileTemplate] { model.templates.all }

    var body: some View {
        Group {
            if showingProfileWizard {
                NewProfileSheet(initialTemplateID: templateID, onCancel: { showingProfileWizard = false })
            } else {
                welcome
            }
        }
        .frame(width: showingProfileWizard ? 640 : 500,
               height: showingProfileWizard ? 560 : 330)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                LogoView(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up ServerMaster")
                        .font(.title2).fontWeight(.semibold)
                    Text("Choose what you want to run first. Missing software is checked while the profile is created.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("First site", selection: $templateID) {
                ForEach(templates) { template in
                    Text(template.title).tag(template.id)
                }
            }

            Spacer()

            HStack {
                Button("Later") { complete() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check software") {
                    model.section = .dependencies
                    complete()
                }
                Button("Set up site") {
                    showingProfileWizard = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }

    private func complete() {
        model.completeFirstSetup()
        dismiss()
    }
}
