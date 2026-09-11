# ServerMaster — TODO

Everything that is planned but not built yet, plus the honest limits of what
ships today. Format: `[ ]` not started, `[~]` partially there, `[x]` completed.

This file describes the imported 1.0 source snapshot. The repository migration
only changes repository paths and build metadata; known application issues are
documented here rather than silently fixed as part of the import.

---

## Repository migration

### [x] Universal macOS build

The Release configuration targets macOS 14 or newer and produces one universal
application containing both `arm64` and `x86_64`. The resulting executable was
verified with `lipo`; the Intel slice has not yet been tested on physical Intel
hardware.

Version 1.0 uses build identifier `arm.27.0.b6.uni`: it was compiled on an Arm
Mac using macOS 27.0 and Xcode beta 6, and the resulting application is
universal.

### [x] Update version-file path

The application reads the latest macOS version from
`updates/maclastversion.txt`. The root `lastversion.txt` remains as a temporary
compatibility path for older compiled builds.

## Features to build

### [ ] Localization — German, French, Danish, Japanese

English is the source language: the strings are written in English directly in
the Swift code, so English needs no `.lproj` of its own. Four languages are
still missing, and no others are planned.

Scope: about 733 keys per language, roughly 2900 translations in total.

How it is wired:

| Piece | Path |
|---|---|
| Language registry | `ServerMaster/Core/AppLanguage.swift` |
| One file per language | `ServerMaster/<code>.lproj/Localizable.strings` |

The translation key is the English text from the code. To add a language:
append an entry to `AppLanguage.supported`, drop the `.strings` file in place,
and add the code to `knownRegions` in `project.pbxproj`.

### [ ] Apache as an engine

Eight engines ship today (http-server, Node.js script, Python http.server, PHP
built-in, Nginx, Nginx + PHP-FPM, Caddy, custom command). Apache is not one of
them. The one thing it adds over Nginx is `.htaccess` support — which matters
for anyone arriving from XAMPP or MAMP with a project that already relies on it.

Work involved: an `ServerEngine.apache` case, a generated `httpd.conf` in
`ConfigTemplates`, `mod_php` or PHP-FPM wiring, and a Homebrew `httpd` check in
`DependencyChecker`.

### [~] Database work without the command line

Already there: browse tables, edit cells in place, add and delete rows, run raw
SQL, copy results as CSV, create and drop databases.

Still missing: schema editing through the UI — create and alter tables, add,
rename and drop columns, indexes and keys, import and export `.sql` dumps, and
manage users and privileges. Right now those still need a terminal.

### [ ] Web database admin panel

Ship a one-click way to open a browser admin panel — Adminer (a single PHP
file, trivial to drop in) or phpMyAdmin — pointed at the profile's MariaDB
instance, without the user installing or configuring anything.

### [ ] Command line tool and its installer

A `servermaster` command for the terminal, so a profile can be started, stopped
and inspected without touching the window — useful in scripts, in a Makefile, or
over SSH.

Sketch of the surface: `servermaster start <profile>`, `stop`, `restart`,
`status`, `list`, `logs <profile>`, `ports`.

It needs an installer too, because a binary inside the `.app` bundle is not on
anyone's `PATH`. A button in Settings that symlinks the tool into
`/usr/local/bin` (with the system password prompt when that directory is not
writable), plus the matching uninstall. The Settings row should show whether the
tool is currently installed and which version it points at.

### [ ] Interface modes — Standard and Advanced

One setting that changes how much the app shows.

*Standard* is for someone who just needs a directory served on a port: pick a
folder, press Start. Ports, engines, config files and certificates stay out of
the way behind sensible defaults.

*Advanced* is what exists today: every engine option, config file editing,
sidecars, privileged ports, database tooling.

---

## Open issues

### [ ] Release builds are not signed for distribution

The downloadable application is currently unsigned because no paid Apple
Developer ID certificate is available. It builds and runs locally, but
Gatekeeper can warn or block it after download. Release notes must state this
clearly and explain how to use **Control-click → Open**. Signing and notarization
remain future distribution work; they are not part of the repository migration.

### [ ] Update notification still uses the legacy build-folder link

The version check already reads `updates/maclastversion.txt`, but after finding
a newer version it still probes `mac/<version>`. Binaries in the new repository
belong in GitHub Releases. Until the link logic is migrated, a missing legacy
folder makes the application open the repository root instead of the exact
release page.

### [~] Feature behaviour was not revalidated during migration

The migration verified the Xcode project, the version comparison tests, and an
unsigned Universal Release build. It did not change or comprehensively retest
the application features. Any existing bugs across profiles, servers, the
terminal, database tooling, ports, dependencies, certificates, settings, and
shutdown flows therefore remain part of the imported 1.0 state.

### [ ] Self-signed certificate is not marked as trusted

A deliberate choice, not a breakage. Checked on the user's machine: the
certificate is issued as `CN=localhost, O=ServerMaster` — so openssl, not
mkcert. HTTPS works and the encryption is real, but `security verify-cert`
returns `CSSMERR_TP_NOT_TRUSTED`, so the browser shows a warning that has to be
clicked through by hand.

Two ways to remove the warning, both requiring a password:

- **Certificates…** → *Trust in the system* for the current certificate, or
- switch to mkcert and install its local CA.

Either is fine, and so is leaving it as is.

### [~] Automated test coverage is minimal

The current unit suite covers parsing and comparison of two- and three-part
update versions. The UI test target still contains only Xcode's template launch
and performance tests. Server engines, privileged launches, database work, and
the rest of the interface require broader automated and manual coverage.

---

## Tool limitations — not app bugs

**http-server does not protect dotfiles.** Its `--no-dotfiles` flag only hides
them from the directory listing; a direct request for `/.env` still returns the
contents. Verified live. Only Nginx and Caddy actually deny access. The UI says
so plainly, so the checkbox does not create false confidence.

**Custom error pages work only on Nginx and Caddy.** http-server, Python and the
PHP built-in server cannot do it at all. The switch is disabled for them, with
the reason shown.

**Ports below 1024 require uid 0.** Being in the `admin` group is not enough —
it has to be root. Handled by launching through the system password prompt (see
*Administrator rights* in the profile). The password is typed into a macOS
window; the app never sees it.
