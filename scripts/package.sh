#!/bin/bash
# Builds the app and packs it for sharing:
#   build/Macdows-Commander-<version>.dmg  (open it, drag the app onto Applications)
#   build/Macdows-Commander-<version>.zip
# The DMG window layout needs dmgbuild (pip install dmgbuild); without it a plain DMG is made.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh
APP="build/Macdows Commander.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/Macdows-Commander-$VERSION.zip"
DMG="build/Macdows-Commander-$VERSION.dmg"

rm -f "$ZIP" "$DMG"
# No ._ files: extended attributes stay out of the zip.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "Packed: $ZIP"

# Opened, the DMG shows the app with an arrow to Applications. dmgbuild draws that without
# scripting Finder; without it the DMG still has the Applications link, only unarranged.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/Macdows Commander.app"
DMGBUILD=${DMGBUILD:-$(command -v dmgbuild || true)}
if [ -n "$DMGBUILD" ]; then
    "$DMGBUILD" -s scripts/dmg-settings.py -D app="$STAGE/Macdows Commander.app" "Macdows Commander $VERSION" "$DMG" >/dev/null
else
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Macdows Commander $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
fi
echo "Packed: $DMG"
