//
//  AboutView.swift
//  ServerMaster
//
//  An overview of what the app can do. Written for someone who has opened it
//  for the first time and wants to understand it within a minute.
//

import SwiftUI
import AppKit

struct AboutView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                quickStart
                scenarios
                features
                comparison
                whereThingsLive
                footer
            }
            .padding(36)
//.frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Introduction

    private var intro: some View {
        HStack(alignment: .top, spacing: 16) {
            LogoView(size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("ServerMaster").font(.title).fontWeight(.semibold)
                Text("A local web server on your Mac: static files, PHP sites and a database in one window.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppInfo.versionLine)
                    .font(.caption).foregroundStyle(.tertiary)
                if let minimum = AppInfo.minimumSystemVersion {
                    Text("Requires macOS \(minimum) or newer · \(AppInfo.architecture)")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                HStack(spacing: 14) {
                    Button {
                        AppLinks.open(.index)
                    } label: {
                        Label("Guides", systemImage: "book")
                    }
                    Button("Website") { NSWorkspace.shared.open(AppLinks.site) }
                        .modifier(ChipStyle())
                    Button("Report a problem") { NSWorkspace.shared.open(AppLinks.issues) }
                        .modifier(ChipStyle())
                }
                .font(.callout)
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    // MARK: - Getting started

    private var quickStart: some View {
        Card("Getting started", systemImage: "play.circle") {
            step(1, "Create a profile",
                 "The Profiles tab, the “+” button. A profile is one site: a folder, a port and an engine.")
            step(2, "Point it at your site folder",
                 "“Site root” is the folder with your files. If it contains index.php, pick the “PHP site” engine.")
            step(3, "Press Start",
                 "On the Control tab. The address appears next to it — open it to see your site.")

            Divider()
            HStack {
                Button {
                    model.section = .profiles
                } label: {
                    Label("Open profiles", systemImage: "square.stack.3d.up")
                }
                Button {
                    model.section = .dependencies
                } label: {
                    Label("Check dependencies", systemImage: "checklist")
                }
                Spacer()
            }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number))
                .font(.callout).fontWeight(.semibold)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Scenarios

    private var scenarios: some View {
        Card("What you can run", systemImage: "square.grid.2x2") {
            scenario("chevron.left.forwardslash.chevron.right",
                     "A static site",
                     "A folder with HTML, CSS and JavaScript. The http-server, Python or Nginx engines all work — the choice hardly matters.")
            Divider()
            scenario("cylinder.split.1x2",
                     "A PHP site with a database",
                     "A PHP engine plus the built-in MariaDB. That runs WordPress, Joomla, Drupal, Laravel and any other PHP CMS or framework.")
            Divider()
            scenario("building.columns",
                     "A project that ships its own .htaccess",
                     "The “PHP site (Apache + PHP-FPM)” engine reads .htaccess the way the hosting will. Joomla, WordPress and Drupal all ship one, and their pretty URLs depend on it.")
            Divider()
            scenario("shippingbox",
                     "Your own Node.js server",
                     "The profile runs your server.js and passes the port and host through environment variables.")
            Divider()
            scenario("terminal",
                     "Any command of your own",
                     "The “Custom command” engine runs anything with your own arguments and environment — from bun to your own binary.")
        }
    }

    private var features: some View {
        Card("What is included", systemImage: "checklist") {
            feature("play.circle", "Several servers at once",
                    "Profiles run in parallel, each with its own port, log and settings. Stop or restart them one at a time.")
            Divider()
            feature("cylinder.split.1x2", "Database",
                    "MariaDB runs in its own folder on its own port. Create a database in one click, then browse and edit its contents as a table or with SQL.")
            Divider()
            feature("lock", "HTTPS",
                    "Certificates are issued inside the app, with openssl or mkcert. Ports below 1024 are available through the system password prompt.")
            Divider()
            feature("point.3.connected.trianglepath.dotted", "Ports",
                    "See every busy port and the process holding it. Free a port without leaving the app.")
            Divider()
            feature("terminal", "Terminal",
                    "A real terminal in the profile folder, with tabs. vim, top, ssh, composer and npm all work — anything that needs a proper terminal.")
            Divider()
            feature("doc.on.doc", "Configuration files",
                    "Every file of a profile in one list: the engine config, PHP settings, site files and logs. Syntax is checked before saving, so a broken config never reaches the disk.")
            Divider()
            feature("exclamationmark.bubble", "Error pages and protection",
                    "Custom pages for 404, 403, 500 and the rest. Dotfiles such as .env are blocked and security headers are set — the way a real server does it.")
            Divider()
            feature("curlybraces", "Several PHP versions",
                    "The version is set per profile, and a version that is missing can be installed from the app. Sites on different PHP versions run at the same time.")
            Divider()
            feature("building.columns", "Apache as well as Nginx",
                    "Apache reads .htaccess, which is what a CMS expects and what the hosting will do. Nothing to install: the copy macOS ships is used, or Homebrew's where privacy rules get in the way.")
            Divider()
            feature("tablecells.badge.ellipsis", "Database without the terminal",
                    "Browse and edit rows like a spreadsheet, run SQL, and change the shape of a database — tables, columns, indexes, accounts and privileges. A dump can be imported from a .sql file or straight out of a backup archive.")
            Divider()
            feature("clock.arrow.circlepath", "Snapshots and backups",
                    "Take a snapshot of a profile — its settings, its files and its database — by hand or on a schedule, and roll back to it. Databases can be snapshotted on their own.")
            Divider()
            feature("stethoscope", "Diagnostics",
                    "What is wrong when everything looks installed: disk space and health, a binary built for the wrong architecture, a half-written database directory, a folder macOS will not let Apache read. Each address can be traced from the name to the answer.")
            Divider()
            feature("doc.text.magnifyingglass", "Hidden files",
                    "The dotfiles a project hides — .htaccess, .env, .user.ini — in one list, with an editor that has search, line numbers and syntax colouring. Renaming htaccess.txt to .htaccess is one click instead of a terminal.")
            Divider()
            feature("apple.terminal", "A command line tool",
                    "`servermaster` does everything the window does, for a script, a Makefile or an agent — with an interactive screen of its own when it is run with no arguments.")
            Divider()
            feature("safari", "Safari extension and a widget",
                    "See what is running and start or stop it without leaving the browser, or from the desktop.")
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).font(.callout)
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func scenario(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - What is different

    private var comparison: some View {
        Card("If you used XAMPP or MAMP before", systemImage: "arrow.triangle.2.circlepath") {
            difference("You can see why it failed",
                       "Each server has its own log, PHP errors are never lost, and a crash is explained in words instead of an exit code.")
            difference("Several PHP versions at once",
                       "The version belongs to the profile, not to the whole app. An old and a new project run side by side.")
            difference("Several servers at once",
                       "Every profile gets its own tab, port and engine, started and stopped on its own — instead of one Apache for everything.")
            difference("Apache with .htaccess, nothing to install",
                       "A project that ships its own .htaccess works as it did under XAMPP — macOS already carries Apache, so there is no download and no setup.")
            difference("Leaves your system alone",
                       "The database runs in its own folder on its own port. Any MySQL, Apache or system services you already have are left untouched.")
        }
    }

    private func difference(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).font(.callout)
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: - Where things live

    private var whereThingsLive: some View {
        Card("Where things live", systemImage: "folder") {
            Text("Profiles, certificates, configs, logs and database data live in the app folder. Removing the app leaves nothing behind — just delete that folder.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(AppPaths.abbreviate(AppPaths.support.path))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { model.revealSupportFolder() }
                    .modifier(ChipStyle())
            }

            Divider()

            Text("Servers, PHP and the database are installed through Homebrew. The Dependencies tab shows what you have, what is missing, and installs the rest in one click.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("The app sends nothing anywhere. The only network request is the update check, and you can turn it off.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
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

}
