# ServerMaster

ServerMaster is a local web server manager for macOS. A cross-platform Swift
command-line interface and native Windows interface are in development.

The repository is being rebuilt from verified release snapshots. Source code,
release history, build instructions, and downloadable applications will be
added in separate, reviewable steps.

## Repository layout

| Path | Purpose |
| --- | --- |
| `macos/` | Native macOS application, extensions, tests, and Xcode project |
| `linux/` | Linux integration files such as service and installation definitions |
| `windows/` | Native Windows interface and Visual Studio solution |
| `cli/` | One cross-platform Swift CLI codebase for macOS and Linux |
| `updates/` | Stable update manifests and legacy compatibility files |
| `web/` | Static project website published with GitHub Pages |
| `docs/` | Architecture, development, and release documentation |
| `scripts/` | Repository maintenance and release scripts |

## Releases

Source snapshots are identified by Git tags. Compiled applications and
checksums are published as assets on the GitHub Releases page; build artifacts
are not stored in the Git history.

## License

Original ServerMaster source code is available under the [MIT License](LICENSE).
Bundled third-party components retain their respective licenses.
