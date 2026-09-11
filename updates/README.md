# Update metadata

This directory is reserved for small, stable update manifests for independently
released ServerMaster components. The expected initial layout is:

```text
maclastversion.txt
cli.txt
windows.txt
```

The CLI has one version across macOS, Linux glibc, and Linux musl. Those builds
therefore share `cli.txt` instead of maintaining three version files.

Legacy paths used by existing macOS releases will remain available until those
clients are no longer supported. Release manifests will point to immutable
assets on GitHub Releases rather than binaries committed to the repository.

The macOS application reads `updates/maclastversion.txt`. The root-level
`lastversion.txt` is retained only for compatibility with older compiled builds.

Plain text version files are intentional here: old clients can read them
without an API dependency or JSON migration. A structured manifest will only be
introduced when additional metadata such as checksums or release channels is
actually needed.
