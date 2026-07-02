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

APP_NAME="GoelDownloader"          # executable / SwiftPM product name (internal, unchanged)
APP_BUNDLE="Goel°"                  # user-facing app name → dist/Goel°.app
CONFIG="release"
APP="dist/$APP_BUNDLE.app"

# Size-optimized release: -Osize favors smaller code over speed (irrelevant for
# a UI/IO-bound downloader), -dead_strip drops unreferenced code at link time.
BUILD_FLAGS=(-Xswiftc -Osize -Xlinker -dead_strip)
echo "==> swift build -c $CONFIG (size-optimized)"
swift build -c "$CONFIG" "${BUILD_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Goel°</string>
    <key>CFBundleDisplayName</key>
    <string>Goel°</string>
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
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>GoelDownloader.sdef</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>GoelDownloader add-download</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>goeldownloader</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleURLName</key>
            <string>Magnet link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>magnet</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>BitTorrent document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.bittorrent.torrent</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>torrent</string>
            </array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Download with Goel°</string>
            </dict>
            <key>NSMessage</key>
            <string>downloadWithGoel</string>
            <key>NSPortName</key>
            <string>GoelDownloader</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Executable + SwiftPM resource bundles (Bundle.module resolves these next to
# the executable, so they live in Contents/MacOS alongside the binary).
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/MacOS/"; done

# Frameworks (Sparkle) live in Contents/Frameworks; add the matching rpath so
# the binary resolves @rpath/Sparkle.framework inside the bundle instead of
# the absolute SwiftPM build directory.
mkdir -p "$APP/Contents/Frameworks"
for f in "$BIN"/*.framework; do [ -e "$f" ] && cp -R "$f" "$APP/Contents/Frameworks/"; done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Sparkle activates only when a build provides its appcast + EdDSA public key:
#   SPARKLE_FEED_URL="https://example.com/appcast.xml"
#   SPARKLE_ED_KEY="<base64 public key from Sparkle's generate_keys>"
# Without them the app uses the built-in release-feed checker instead.
if [ -n "${SPARKLE_FEED_URL:-}" ] && [ -n "${SPARKLE_ED_KEY:-}" ]; then
  echo "==> Enabling Sparkle updates ($SPARKLE_FEED_URL)"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED_KEY" "$APP/Contents/Info.plist"
fi

# App icon (the dark variant is the shipped icon).
cp Assets/AppIcon-Dark.icns "$APP/Contents/Resources/AppIcon.icns"

# AppleScript dictionary (OSAScriptingDefinition points here).
cp Sources/GoelApp/Resources/GoelDownloader.sdef "$APP/Contents/Resources/GoelDownloader.sdef"

# Safari Web Extension (.appex). Built by hand (no Xcode): the handler is a
# minimal NSExtensionMain executable, and the SAME WebExtension resources the
# Chrome/Firefox build ships are dropped into the appex's Resources so Safari
# discovers manifest.json. Signed here (inside-out) before the app wrapper is
# sealed by bundle_dylibs.sh.
APPEX="$APP/Contents/PlugIns/GoelSafariExtension.appex"
echo "==> Assembling Safari extension $APPEX"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp SafariExtension/Info.plist "$APPEX/Contents/Info.plist"
cp -R Sources/GoelApp/BrowserExtension/. "$APPEX/Contents/Resources/"
ARCH="$(uname -m)"
swiftc -parse-as-library \
  SafariExtension/SafariWebExtensionHandler.swift \
  -o "$APPEX/Contents/MacOS/GoelSafariExtension" \
  -target "${ARCH}-apple-macosx14.0" \
  -framework Foundation -framework AppKit -framework SafariServices \
  -Xlinker -e -Xlinker _NSExtensionMain
codesign --force -s - "$APPEX"

# Vendor native dylibs, rewrite install names, and sign.
Scripts/bundle_dylibs.sh "$APP"

# Optional Developer ID distribution, gated on env vars so the default build
# stays untouched:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" — sign with
#     hardened runtime (innermost first: frameworks/dylibs/bundles, then app)
#   NOTARY_PROFILE="<notarytool keychain profile>" — submit + staple
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Codesigning with '$CODESIGN_IDENTITY' (hardened runtime)"
  find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" -o -name "*.appex" \) -prune | while read -r item; do
    codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY" "$item"
  done
  codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"
  echo "    signed."
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    ditto -c -k --keepParent "$APP" "dist/$APP_NAME.zip"
    xcrun notarytool submit "dist/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "    notarized and stapled."
  fi
fi

# Compressed distributable (drag-to-share / drag-to-/Applications). The .app
# installs at ~19 MB but the native dylibs compress well, so the download is
# roughly half that.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="dist/Goel-Downloader-${VERSION}-macos-$(uname -m).zip"
echo "==> Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done: $APP"
printf '    installed: %s   download(zip): %s\n' \
  "$(du -sh "$APP" | cut -f1)" "$(du -sh "$ZIP" | cut -f1)"
