#!/usr/bin/env bash
#
# make_dmg.sh — wrap dist/Goel°.app in a drag-to-Applications .dmg for distribution.
#
# The .app is already self-contained (bundle_dylibs.sh vendored every native lib),
# so the DMG is just presentation: a compressed disk image with the app and an
# /Applications symlink, so the user drags the icon across to install. This is the
# file you upload to a GitHub Release / website.
#
# IMPORTANT for downloaded copies: a .dmg pulled from the internet is quarantined,
# and the app inherits that. For the app to open WITHOUT the Gatekeeper warning,
# the .app inside must be Developer-ID-signed + notarized + stapled BEFORE this
# script runs (build with CODESIGN_IDENTITY + NOTARY_PROFILE — see build_app.sh).
# Set NOTARY_PROFILE here too to also notarize+staple the DMG itself.
#
# Usage: Scripts/make_dmg.sh [path/to/App.app]      (default: dist/Goel°.app)
# Result: dist/Goel-Downloader-<version>-macos-<arch>.dmg

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="${1:-dist/Goel°.app}"
[ -d "$APP" ] || { echo "error: no app at $APP — run Scripts/build_app.sh first" >&2; exit 1; }

INFO_PLIST="$APP/Contents/Info.plist"
VOL_NAME="Goel°"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG="dist/Goel-Downloader-${VERSION}-macos-$(uname -m).dmg"

# Assemble a clean staging folder: the app + a symlink to /Applications so the
# DMG window shows the classic "drag here to install" layout.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Building $DMG"
rm -f "$DMG"
# UDZO = zlib-compressed read-only image (small download, mounts read-only).
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

# Optionally notarize + staple the DMG so even the disk image itself passes
# Gatekeeper cleanly (the app inside must already be notarized). Gated on env var.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing DMG (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "    notarized and stapled."
else
  echo "    (skipping DMG notarization — set NOTARY_PROFILE to enable)"
fi

echo "==> Done: $DMG"
printf '    size: %s\n' "$(du -sh "$DMG" | cut -f1)"
