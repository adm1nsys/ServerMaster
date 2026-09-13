# Changelog

All notable changes to ServerMaster will be documented in this file.

The project uses semantic version numbers and immutable Git tags for published
versions. Historical entries will be reconstructed from the archived release
snapshots before the first public push.

## Unreleased

- Keep the root `lastversion.txt` compatibility file for older macOS builds.

## CLI 1.0.0 — 2026-09-13

- Add the ServerMaster command-line interface as a Swift Package under `cli/`.
- Add `updates/clilastversion.txt` as the CLI update-version manifest.
- Add CLI update commands: `update check`, `update install --yes`, and
  `update auto on|off|status`.
- Add the interactive Settings screen with version, update channel, website,
  wiki, local paths, and automatic update state.
- Fix interactive navigation so `Esc` returns to the previous screen instead of
  leaving the CLI from nested screens such as Control.
- Build the macOS CLI as a universal binary for Apple Silicon and Intel.
- Add GitHub Actions workflows for CLI build checks and release packaging.
- Prepare the release catalog for future Linux glibc and Linux musl CLI assets.

## 1.2 — 2026-09-10

- Import the ServerMaster 1.2 macOS source snapshot.
- Update documentation links to the new GitHub Pages structure.
- Keep the macOS update checker pointed at `updates/maclastversion.txt`.

## 1.1 — 2026-09-03

- Import the ServerMaster 1.1 macOS source snapshot.
- Preserve release assets and checksums through GitHub Releases.

## 1.0 — 2026-09-11

- Import the verified ServerMaster 1.0 macOS source snapshot.
- Prepare the monorepository layout for macOS, Linux, Windows, CLI, updates,
  documentation, scripts, and the project website.
- Build the macOS application as a Universal binary for Apple Silicon and Intel
  with macOS 14 as the deployment target.
- Move the macOS update-version path to `updates/maclastversion.txt`, retaining
  the old root path for compatibility with earlier compiled builds.
- Add local version-comparison tests and manually triggered GitHub Actions
  workflows for the macOS build and website deployment.
