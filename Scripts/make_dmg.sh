#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Goel°.app}"
[ -d "$APP" ] || { echo "error: no app at $APP — run Scripts/build_app.sh first" >&2; exit 1; }

LOCAL_DEV="${GOEL_LOCAL_DEV:-0}"

# check_min_os.sh exit 3 is a waiver: a local image may proceed on it, dist/ may not.
MINOS_STATUS=0
Scripts/check_min_os.sh "$APP" || MINOS_STATUS=$?
if [ "$MINOS_STATUS" != 0 ]; then
  if [ "$LOCAL_DEV" = "1" ] && [ "$MINOS_STATUS" = 3 ]; then
    echo "warning: GOEL_LOCAL_DEV=1 — wrapping a bundle that failed the gate above." >&2
  else
    echo "error: $APP did not pass Scripts/check_min_os.sh (status $MINOS_STATUS)." >&2
    echo "       Wrapping it would ship a .dmg whose app cannot start on the macOS" >&2
    echo "       its own Info.plist advertises. See that script's header for how to" >&2
    echo "       produce correctly-targeted dylibs." >&2
    exit 1
  fi
fi

if [ "$LOCAL_DEV" != "1" ]; then
  if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "error: $APP has no stapled notarization ticket." >&2
    echo "       A DMG built around it would fail Gatekeeper for everyone who" >&2
    echo "       downloads it. Rebuild with:" >&2
    echo "         GOEL_RELEASE=1 NOTARY_PROFILE=<profile> Scripts/build_app.sh" >&2
    echo "       or set GOEL_LOCAL_DEV=1 for an unsigned internal-testing image." >&2
    exit 1
  fi
  if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "error: CODESIGN_IDENTITY is not set, so the disk image itself would be" >&2
    echo "       unsigned — the app inside being notarized does not cover it." >&2
    echo "       Set CODESIGN_IDENTITY='Developer ID Application: …'." >&2
    exit 1
  fi
  case "$CODESIGN_IDENTITY" in
    "Developer ID Application: "*) ;;
    *) echo "error: CODESIGN_IDENTITY is '$CODESIGN_IDENTITY'." >&2
       echo "       Only a 'Developer ID Application: …' certificate is valid for" >&2
       echo "       distribution; anything else signs and is then rejected." >&2
       exit 1 ;;
  esac
  # `stapler validate` only proves a ticket is attached; only spctl's `source=` line proves notarized.
  echo "==> Gatekeeper assessment of $APP"
  APP_SPCTL="$(mktemp -t goel-dmg-spctl)"
  if ! spctl -a -vvv -t exec "$APP" 2>&1 | tee "$APP_SPCTL"; then
    echo "error: Gatekeeper rejected $APP — a DMG around it will not open." >&2
    rm -f "$APP_SPCTL"; exit 1
  fi
  if ! grep -q 'source=Notarized Developer ID' "$APP_SPCTL"; then
    echo "error: Gatekeeper accepted $APP but not as notarized:" >&2
    grep 'source=' "$APP_SPCTL" | sed 's/^/    /' >&2
    rm -f "$APP_SPCTL"; exit 1
  fi
  rm -f "$APP_SPCTL"
fi

INFO_PLIST="$APP/Contents/Info.plist"
VOL_NAME="Goel°"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
# Arch label comes from the app binary, not the host: a cross-built Intel app is x86_64, not arm64.
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
ARCHES="$(lipo -archs "$EXE" 2>/dev/null || true)"
case "$ARCHES" in
  *" "*) ARCH="universal" ;;
  "")    ARCH="$(uname -m)" ;;
  *)     ARCH="$ARCHES" ;;
esac
NAME="Goel-Downloader-${VERSION}-macos-${ARCH}.dmg"

WORK="$(mktemp -d -t goel-dmg)"
trap 'rm -rf "$WORK"' EXIT
DMG="$WORK/$NAME"

STAGE="$WORK/stage"
mkdir "$STAGE"
echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Building $NAME"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

if [ "$LOCAL_DEV" = "1" ]; then
  # Deliberately outside dist/: survives the trap for testing, but the release upload glob must never see it.
  KEEP="$(mktemp -d -t goel-dmg-local)"
  mv "$DMG" "$KEEP/$NAME"
  echo "==> Done: $KEEP/$NAME  (unsigned local image — NOT for distribution)"
  printf '    size: %s\n' "$(du -sh "$KEEP/$NAME" | cut -f1)"
  exit 0
fi

# The DMG must be signed in its own right; the notarized app inside does not cover the container.
echo "==> Signing $NAME"
codesign --force --timestamp -s "$CODESIGN_IDENTITY" "$DMG"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "error: NOTARY_PROFILE is not set, so this DMG cannot be notarized." >&2
  echo "       An un-notarized image shows the 'cannot be opened' dialog on every" >&2
  echo "       Mac that downloads it. Set NOTARY_PROFILE, or GOEL_LOCAL_DEV=1 for" >&2
  echo "       an internal-testing image that is not written to dist/." >&2
  exit 1
fi
echo "==> Notarizing DMG (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# spctl needs `--context primary-signature` to judge the image itself rather than its payload.
if ! xcrun stapler validate "$DMG"; then
  echo "error: no valid notarization ticket is stapled to $DMG." >&2
  exit 1
fi
if ! spctl -a -t open --context context:primary-signature -vvv "$DMG"; then
  echo "error: Gatekeeper rejected $DMG — it will not open on another Mac." >&2
  exit 1
fi
echo "    notarized, stapled and accepted by Gatekeeper."

mkdir -p dist
FINAL="dist/$NAME"
rm -f "$FINAL"
mv "$DMG" "$FINAL"

echo "==> Done: $FINAL"
printf '    size: %s\n' "$(du -sh "$FINAL" | cut -f1)"
