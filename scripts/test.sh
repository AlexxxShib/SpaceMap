#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path build/module-cache \
    -target "$(uname -m)-apple-macos14.0" Sources/SpaceMap/{FileTree,DirectoryReader,ScanCache,ChangeJournal,Queue,Volumes,Workspace,Sunburst}.swift \
    Tests/Checks.swift -o build/SpaceMapChecks
build/SpaceMapChecks "$@"
