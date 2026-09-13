#!/bin/zsh
#
# Rebuilds the ServerMaster CLI from the monorepo and refreshes the local copy
# that the macOS app can embed into its bundle.
#
#   ./macos/Tools/update-cli.sh          rebuild and copy
#   ./macos/Tools/update-cli.sh --check  say whether the copy is stale
#
# The copied binary is intentionally ignored by git. Release binaries belong in
# GitHub Releases and CI artifacts, not in the source tree.

set -e

SCRIPT_DIR=${0:a:h}
REPO_ROOT=${SCRIPT_DIR:h:h}
CLI=${SERVERMASTER_CLI:-$REPO_ROOT/cli}
DEST=$SCRIPT_DIR/servermaster

if [[ ! -f $CLI/Package.swift ]]; then
    print -u2 "The CLI package was not found at: $CLI"
    print -u2 "Point at it with: SERVERMASTER_CLI=/path/to/cli $0"
    exit 1
fi

if [[ -z $DEVELOPER_DIR && ! -d $(xcode-select -p)/Platforms ]]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        [[ -d $candidate ]] && export DEVELOPER_DIR=$candidate/Contents/Developer && break
    done
fi
if [[ ! -d ${DEVELOPER_DIR:-$(xcode-select -p)}/Platforms ]]; then
    print -u2 "Xcode was not found. Set DEVELOPER_DIR to its Contents/Developer."
    exit 1
fi

swift build -c release --package-path $CLI --arch arm64 --arch x86_64 >/dev/null

built=$CLI/.build/out/Products/Release/servermaster
if [[ ! -f $built ]]; then
    built=$(find $CLI/.build -path '*/release/servermaster' -o -path '*/Release/servermaster' | head -n 1)
fi
if [[ -z $built || ! -f $built ]]; then
    print -u2 "Could not find the built servermaster executable in $CLI/.build."
    exit 1
fi

if [[ $1 == "--check" ]]; then
    if [[ ! -f $DEST ]]; then
        print "No bundled CLI copy yet — run $0 to build and copy."
        exit 1
    fi
    if cmp -s $built $DEST; then
        print "The bundled CLI matches the current Release build."
        exit 0
    fi
    print "The bundled CLI is out of date. Run $0."
    exit 1
fi

cp $built $DEST
chmod +x $DEST

print "Copied $($DEST version | head -1) into $DEST"
print "  architectures: $(lipo -archs $DEST)"
