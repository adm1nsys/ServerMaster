# ServerMaster for macOS

The native SwiftUI application, companion targets, tests, and the Xcode project
live here.

Open `ServerMaster.xcodeproj` in Xcode. Release binaries are published through
GitHub Releases rather than committed to the repository.

The current source snapshot is the macOS 2.0 line. It keeps update checks on the
public macOS channel at `updates/maclastversion.txt` and links users to GitHub
Releases for downloadable builds.

GitHub Actions artifacts are temporary. Permanent downloadable builds should be
attached to GitHub Releases. If a specific temporary artifact is no longer
available, fork the repository and run the macOS build workflow on the desired
tag or commit to reproduce the binary.
