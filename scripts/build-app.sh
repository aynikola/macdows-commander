#!/bin/bash
# Builds "build/Macdows Commander.app" for both Apple Silicon and Intel Macs.
set -euo pipefail

VERSION="1.2.1"
BUILD="4"

cd "$(dirname "$0")/.."
# Each architecture builds on its own, then lipo joins them into one program.
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx13.0"
done

APP="build/Macdows Commander.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/MacdowsCommander" \
  "$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/MacdowsCommander" \
  "$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/MacdowsCommander"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# The icon is drawn by a script, so it stays reproducible without image files in the repo.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  [ "$size" = 512 ] || sips -z "$((size * 2))" "$((size * 2))" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Macdows Commander</string>
    <key>CFBundleDisplayName</key><string>Macdows Commander</string>
    <key>CFBundleIdentifier</key><string>app.macdows.commander</string>
    <key>CFBundleExecutable</key><string>MacdowsCommander</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Opens the Finder Get Info window for a file.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built: $APP"
