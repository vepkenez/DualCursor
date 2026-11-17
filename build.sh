#!/bin/bash
# Builds DualCursor.app and installs it to ~/Applications.
# Signing is ad-hoc, so macOS treats each rebuild as a new app: after rebuilding, remove and
# re-add DualCursor under Privacy & Security → Input Monitoring and → Accessibility.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/DualCursor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/DualCursor" Sources/main.swift \
    -framework Cocoa -framework IOKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.dualcursor "$APP"

pkill -x DualCursor 2>/dev/null || true
rm -rf ~/Applications/DualCursor.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/DualCursor.app"
