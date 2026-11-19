#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
app="build/Space Map.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources" build/module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache \
    -target "$(uname -m)-apple-macos14.0" Sources/SpaceMap/*.swift -o "$app/MacOS/SpaceMap"
cp Resources/Info.plist "$app/Info.plist"
cp Resources/SpaceMap.icns "$app/Resources/"
codesign --force --sign - "build/Space Map.app"
