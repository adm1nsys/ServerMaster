# ServerMaster CLI

ServerMaster CLI is the terminal companion for ServerMaster. It can list,
start, stop, inspect, and create local server profiles without opening the
macOS application.

The CLI release line is designed for three binary targets:

- macOS universal
- Linux glibc
- Linux musl

The first binary prepared from this repo is the macOS universal build. Linux
glibc and musl builds should come from the same CLI source tree after the
remaining macOS-specific shared components are isolated behind platform checks.

## Build

```bash
swift build -c release --package-path cli
```

The binary is produced as:

```text
cli/.build/release/servermaster
```

## Update metadata

The latest CLI version is published in:

```text
updates/clilastversion.txt
```

Release assets should use tags like `cli-v1.0.0`, so scripts and the updater can
resolve a version without guessing. The expected asset names are:

```text
servermaster-macos-universal.zip
servermaster-linux-glibc.tar.gz
servermaster-linux-musl.tar.gz
SHA256SUMS.txt
```
