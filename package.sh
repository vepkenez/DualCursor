#!/bin/bash
# Builds a universal (Apple Silicon + Intel) DualCursor.app and wraps it in a DMG to share.
# Output: dist/DualCursor-<version>.dmg
#
# The app is ad-hoc signed (no Apple Developer ID), so it is not notarized: recipients have to
# allow it once in System Settings → Privacy & Security ("Open Anyway"). See "How to install.txt".
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
STAGE=build/dmg
APP="$STAGE/DualCursor.app"
DMG="dist/DualCursor-$VERSION.dmg"

rm -rf "$STAGE" && mkdir -p "$APP/Contents/MacOS" dist

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" -o "build/DualCursor-$arch" Sources/main.swift \
        -framework Cocoa -framework IOKit -framework ServiceManagement
done
lipo -create build/DualCursor-arm64 build/DualCursor-x86_64 -output "$APP/Contents/MacOS/DualCursor"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.dualcursor "$APP"

cp "How to install.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "DualCursor $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG"
