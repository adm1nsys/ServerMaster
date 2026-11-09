# Changelog

Changes are listed separately for the macOS application, Windows application
and shared CLI. Published source snapshots are identified by platform-specific
Git tags. Dates follow the website release catalog.

| Version | Platform | Date | GitHub Release |
| --- | --- | --- | --- |
| [2.1.0](#macos-210) | macOS | 2026-11-09 | — |
| [1.0.0](#windows-100) | Windows | 2026-10-25 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/windows-v1.0.0) |
| [2.0.0](#macos-200) | macOS | 2026-09-12 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/macos-v2.0.0) |
| [1.0.0](#cli-100) | CLI | 2026-09-13 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/cli-v1.0.0) |
| [1.2.0](#macos-120) | macOS | 2026-09-10 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/macos-v1.2.0) |
| [1.1.0](#macos-110) | macOS | 2026-09-03 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/macos-v1.1.0) |
| [1.0.0](#macos-100) | macOS | 2026-08-29 | [Release](https://github.com/adm1nsys/ServerMaster/releases/tag/macos-v1.0.0) |

<a id="macos-210"></a>

## macOS 2.1.0 — 2026-11-09

### Profiles and setup

- Add profile colours and a background that follows running profiles.
- Open the new-profile wizard directly from Control.
- Keep duplicated profile settings and assign a free port outside saved profiles
  and current reservations.
- Show preparation progress and an explicit Start action when setup finishes;
  cancelled or failed setup does not start a server later.
- Support entered or generated database passwords in the setup wizard without
  exporting passwords or replacing an existing account's credentials.
- Align shared template defaults, package metadata and quick-setup settings.
- Prepare or retry Print Shop CRM, Web-to-Print Store and Showcase from saved
  profiles, with progress, a separate setup log and preserved project data.
- Include Ukrainian Showcase content and additional Ukrainian interface labels.
- Improve cross-platform profile, template and language-pack import/export,
  including shared fields, validation and duplicate-ID handling.

### Runtimes and server control

- Add management of verified official Node releases and their bundled npm,
  installed-version selection and a System option.
- Protect active runtimes and PHP versions used by saved profiles from removal.
- Check profile requirements and install missing dependencies from the profile
  editor and setup wizard.
- Add managed HTTPS for Node, Python and PHP built-in servers.
- Apply each profile's PHP memory, upload, timeout and error settings to the
  PHP built-in server; pass HOST and PORT defaults to custom commands.
- Improve Node starter files for selected entry paths and module formats.
- Improve parallel Joomla 5/6 launches, separate PHP-FPM ports, administrator
  sessions and recovery of managed server processes.
- Serialize start/stop actions, check HTTP readiness and report failed stops
  with a retry action instead of showing an unconfirmed shutdown as successful.
- Improve occupied-port checks, IPv6 handling and process-ownership checks.

### Database, files and backups

- Store database credentials in Keychain with hidden passwords, Show/Copy
  controls and a clear session-only fallback.
- Improve account validation, password changes, custom hosts, protected-account
  handling and stale-credential cleanup.
- Distinguish SQL NULL, empty strings and the text `null`; improve table paging
  and prevent old results or confirmations from changing a newly selected table.
- Preserve text encoding and detect external changes before saving file and
  configuration edits.
- Keep built-in file operations inside the project and handle linked paths.
- Validate backup archives and restore paths, preserve the previous project
  folder and block conflicting restore/start operations.
- Improve backup retention and reporting of save, restore and deletion errors.

### Startup, diagnostics and build information

- Improve first-run setup, slow or offline startup and handling of legacy,
  damaged or unwritable settings.
- Add profile and recipe diagnostics with actionable results.
- Preserve UTF-8 output and complete URLs, separate log sessions and report
  file-write failures while keeping console output available.
- Apply log-retention settings without deleting active log files.
- Hide Basic Auth passwords in displayed commands and command logs.
- Improve TLS validation and permission-scan results.
- Set the application and matching extensions to version 2.1.0.
- Use the build-label format `arm.m27.3b.x27.3b1.uni`; keep older labels readable
  and document their format as Legacy.
- Document the build environment in GitHub Release notes.

<a id="windows-100"></a>

## Windows 1.0.0 — 2026-10-25

- Implement and release the native Windows application using C# and WinUI,
  with a portable x64 download for Windows 10 1903 or later.
- Add saved profiles, individual server controls, profile colours and
  running-profile backgrounds.
- Add dependency management, verified PHP downloads, per-profile PHP versions
  and Visual C++ Runtime installation checks.
- Add managed MariaDB, database tools and an Adminer web panel.
- Add Joomla and other project templates, including Print Shop CRM,
  Web-to-Print Store and the Ukrainian Web-to-Print Showcase.
- Add live logs, profile diagnostics, address tracing, TCP/UDP port inspection
  and confirmed process termination.
- Add project file browsing and editing, backups and restore tools.
- Provide native CMD and PowerShell terminals and request UAC for operations
  that require administrator access.
- Add Windows build checks and the Windows download entry on the project site.

<a id="macos-200"></a>

## macOS 2.0.0 — 2026-09-12

- Redesign the SwiftUI interface with an updated sidebar, ambient background,
  glass-style panels and richer status cards.
- Add the Control dashboard for running profiles, quick actions, health state,
  copied addresses and profile details.
- Expand the database workspace with table browsing and editing, SQL execution,
  imports and a bundled admin web panel.
- Add project/template helpers for PHP and CMS workflows and starter files.
- Expand diagnostics, domain tracing, health checks, progress messages and logs.
- Add project and database backups, snapshots and scheduling controls.
- Add Safari extension and desktop monitor/widget targets.
- Bundle the ServerMaster CLI helper from the shared `cli/` package.
- Use `updates/maclastversion.txt` and GitHub Releases for macOS update checks;
  remove the obsolete repository-root update file.
- Update website and wiki links for the GitHub Pages root structure.
- Keep macOS 14 as the minimum OS and package the app and embedded CLI helper
  as Universal binaries for Apple Silicon and Intel.
- Add a dedicated macOS release workflow with application, source and checksum
  assets stored in GitHub Releases.

<a id="cli-100"></a>

## CLI 1.0.0 — 2026-09-13

- Add the ServerMaster command-line interface as a shared Swift Package.
- Add `updates/clilastversion.txt` as the CLI update-version manifest.
- Add `update check`, `update install --yes` and `update auto on|off|status`.
- Add the interactive Settings screen with version, update channel, website,
  wiki, local paths and automatic-update state.
- Fix navigation so leaving Controls or pressing Esc returns to the previous
  screen instead of exiting the entire CLI.
- Provide a Universal macOS CLI archive and separate build/release workflows.
- Prepare the release catalog for separate Linux glibc and musl builds.

<a id="macos-120"></a>

## macOS 1.2.0 — 2026-09-10

- Add presets for common server profiles while retaining empty-profile creation.
- Add in-app guide links and update website/wiki destinations.
- Recover the app's own database admin-panel processes left by an earlier run
  so they do not keep its port occupied.
- Improve update handling and expand profile and configuration regression checks.
- Adapt the source snapshot and download/update links to the new repository.

<a id="macos-110"></a>

## macOS 1.1.0 — 2026-09-03

- Add Apache and Apache + PHP-FPM engines with generated per-profile configs
  and support for projects using `.htaccess`.
- Add the bundled Adminer database web panel and its settings and launch controls.
- Expand dependency checks and PHP-FPM launch support for Apache profiles.
- Adapt the source snapshot and update links to the new repository.
- Preserve compiled application archives, project sources and checksums in
  GitHub Releases.

<a id="macos-100"></a>

## macOS 1.0.0 — 2026-08-29

- Introduce the macOS application with saved server profiles, engine selection,
  local process controls, dependency checks and logs.
- Import the original project into the new monorepository and prepare folders
  for platform sources, CLI, updates, documentation and the website.
- Prepare a Universal application for Apple Silicon and Intel with macOS 14
  as the deployment target.
- Move macOS update checks to `updates/maclastversion.txt`, initially retaining
  the old root path for compatibility with earlier compiled builds.
- Add version-comparison checks and separate macOS build and website workflows.
