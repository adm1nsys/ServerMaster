# Linux integration

The ServerMaster CLI source lives in `cli/` and is shared by macOS and Linux.
This directory is reserved for Linux-specific integration such as service
definitions, installation metadata, and distribution support files.

glibc and musl are build variants of the same CLI source version. Their build
rules will live in GitHub Actions and reusable scripts rather than duplicated
source directories.
