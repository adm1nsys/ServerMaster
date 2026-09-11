# ServerMaster CLI

This directory will contain one cross-platform Swift package with the command-
line interface, shared source code, and tests. Conditional compilation and
platform implementations will adapt the same codebase to macOS and Linux.

The same tagged source version will produce the macOS, Linux glibc, and Linux
musl release artifacts. Those are build variants, not separate source trees.
