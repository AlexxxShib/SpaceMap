#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

signer=${SPACEMAP_SIGN_IDENTITY:-Space Map Local Development}
if [[ "$signer" == "-" ]]; then
    echo "Для сохранения разрешений укажите постоянный сертификат подписи." >&2
    exit 1
fi
mkdir -p build/module-cache
stage=$(mktemp -d build/.spacemap.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Space Map.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path build/module-cache \
    -target "$(uname -m)-apple-macos14.0" Sources/SpaceMap/*.swift -o "$bundle/Contents/MacOS/SpaceMap"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/SpaceMap.icns "$bundle/Contents/Resources/"

if ! /usr/bin/codesign --force --sign "$signer" "$bundle"; then
    echo "Проверьте доступ к сертификату. Для первой локальной сборки выполните ./scripts/setup-signing.sh." >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$bundle"

# Publish only a verified bundle. macOS swaps existing directories atomically.
xcrun swift -module-cache-path build/module-cache - "$bundle" "build/Space Map.app" <<'SWIFT'
import Darwin
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Space Map")
        exit(1)
    }
}
SWIFT
