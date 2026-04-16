#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="AI Radio.app"
EXEC="AIRadio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# Build a universal binary (arm64 + x86_64) so Intel Macs also run it.
swiftc -O \
    -target arm64-apple-macos13.0 \
    -framework Cocoa -framework AVFoundation -framework MediaPlayer \
    -o "$APP/Contents/MacOS/${EXEC}-arm64" \
    main.swift

swiftc -O \
    -target x86_64-apple-macos13.0 \
    -framework Cocoa -framework AVFoundation -framework MediaPlayer \
    -o "$APP/Contents/MacOS/${EXEC}-x86_64" \
    main.swift

lipo -create -output "$APP/Contents/MacOS/$EXEC" \
    "$APP/Contents/MacOS/${EXEC}-arm64" \
    "$APP/Contents/MacOS/${EXEC}-x86_64"
rm "$APP/Contents/MacOS/${EXEC}-arm64" "$APP/Contents/MacOS/${EXEC}-x86_64"

# Ad-hoc sign so Gatekeeper lets the local copy run
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built '$APP' (universal binary, arm64 + x86_64)"
