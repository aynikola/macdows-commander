#!/bin/bash
# Builds the app and zips it for sharing: build/Macdows-Commander-<version>.zip
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh
APP="build/Macdows Commander.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/Macdows-Commander-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packed: $ZIP"
