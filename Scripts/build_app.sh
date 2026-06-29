#!/usr/bin/env bash
#
# build_app.sh — build GoelDownloader (release) and assemble a distributable .app.
#
# Steps:
#   1. swift build -c release
#   2. assemble dist/GoelDownloader.app (Info.plist, icon, executable, and the
#      SwiftPM resource bundles, which must sit next to the executable)
#   3. vendor the libtorrent/openssl dylib closure + re-sign (bundle_dylibs.sh),
#      making the .app self-contained so it runs on any same-arch Mac (macOS 14+)
#      without Homebrew.
#
# Usage: Scripts/build_app.sh
# Result: dist/GoelDownloader.app  (ready to zip / drag to /Applications / ship)

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP_NAME="GoelDownloader"
CONFIG="release"
APP="dist/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>GoelDownloader</string>
    <key>CFBundleDisplayName</key>
    <string>GoelDownloader</string>
    <key>CFBundleExecutable</key>
    <string>GoelDownloader</string>
    <key>CFBundleIdentifier</key>
    <string>com.goel.downloader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Executable + SwiftPM resource bundles (Bundle.module resolves these next to
# the executable, so they live in Contents/MacOS alongside the binary).
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/MacOS/"; done

# App icon (the dark variant is the shipped icon).
cp Assets/AppIcon-Dark.icns "$APP/Contents/Resources/AppIcon.icns"

# Vendor native dylibs, rewrite install names, and sign.
Scripts/bundle_dylibs.sh "$APP"

echo "==> Done: $APP"
du -sh "$APP" | sed 's/^/    /'
