# Changelog

All notable changes to ServerMaster will be documented in this file.

The project uses semantic version numbers and immutable Git tags for published
versions. Historical entries will be reconstructed from the archived release
snapshots before the first public push.

## Unreleased

- Continue reconstructing the historical macOS releases.
- Prepare the cross-platform CLI import.

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
