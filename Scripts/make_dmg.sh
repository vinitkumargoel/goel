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
# script runs (build with GOEL_RELEASE=1 + NOTARY_PROFILE — see build_app.sh),
# and the disk image itself must be signed and notarized too. That used to be
# advice in this comment and nothing more: the script would happily wrap an
# ad-hoc app, leave the image unsigned, and report success. All three are now
# enforced below.
#
# THIS SCRIPT IS A RELEASE PATH IN ITS OWN RIGHT, and twice it forgot that:
#
#   * It ran none of build_app.sh's gates over the payload. It is invoked
#     separately (RELEASE.md's own two-step sequence does exactly that), so
#     "build_app.sh already checked" was never true of the app it was handed —
#     which could be any stapled bundle, including one built before a gate
#     existed. It now re-runs the deployment-target gate and the Gatekeeper
#     assessment itself, on the bundle in front of it.
#   * It wrote the image straight to dist/ under the release filename and only
#     then signed, notarized and assessed it. Every failure after `hdiutil
#     create` — a rejected notarization, a stapler or spctl refusal — exited 1
#     and left that file behind, and RELEASE.md publishes with `dist/*.dmg`.
#     The image is now built in a scratch directory and moved into dist/ as the
#     last action, after everything has passed.
#
# Env:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" — signs the DMG
#   NOTARY_PROFILE="<notarytool keychain profile>"              — notarize+staple
#   GOEL_LOCAL_DEV=1  build an unsigned image for internal testing; it is written
#                     to a scratch path, never to dist/
#
# Usage: Scripts/make_dmg.sh [path/to/App.app]      (default: dist/Goel°.app)
# Result: dist/Goel-Downloader-<version>-macos-<arch>.dmg

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="${1:-dist/Goel°.app}"
[ -d "$APP" ] || { echo "error: no app at $APP — run Scripts/build_app.sh first" >&2; exit 1; }

LOCAL_DEV="${GOEL_LOCAL_DEV:-0}"

# The deployment-target gate, on the bundle actually being wrapped. dyld refuses
# an over-targeted Mach-O before main(), so this is the difference between a
# release that launches and one that dies on a dialog — and it is checked here
# because this script is reachable without build_app.sh having run in the same
# invocation. A local/dev image may proceed on a waiver (exit 3); a dist/ image
# may not.
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

# A DMG is a distribution container. Building one around an app that has not
# been notarized produces a file that looks exactly like a release and refuses
# to open on the first machine that downloads it — so the app's ticket is
# checked before anything is staged, not after the image exists.
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
  # `stapler validate` proves a ticket is attached; it says nothing about whether
  # the certificate that ticket was issued against is still good. Gatekeeper is
  # the authority on that, and only its `source=` line separates "notarized" from
  # "signed with a Developer ID and accepted locally" — the same assessment
  # build_app.sh performs, applied to whatever bundle this script was handed.
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
# Derive the arch label from the actual app binary (so a cross-built Intel app
# on an Apple Silicon host is labelled x86_64, not the host's arm64).
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
ARCHES="$(lipo -archs "$EXE" 2>/dev/null || true)"
case "$ARCHES" in
  *" "*) ARCH="universal" ;;
  "")    ARCH="$(uname -m)" ;;
  *)     ARCH="$ARCHES" ;;
esac
NAME="Goel-Downloader-${VERSION}-macos-${ARCH}.dmg"

# EVERY image is built in a scratch directory, and dist/ is written exactly once,
# by the `mv` at the very bottom — after signing, notarization, stapling and the
# Gatekeeper assessment have all passed. dist/ is where release artifacts are
# picked up from (RELEASE.md publishes with `dist/*.dmg`), and a file called
# Goel-Downloader-1.0.2-macos-arm64.dmg sitting there is indistinguishable from
# one that passed the gates until somebody tries to open it. Building in place and
# checking afterwards meant every failure path — a rejected notarization, a
# stapler or spctl refusal — exited 1 and left exactly that file behind.
WORK="$(mktemp -d -t goel-dmg)"
trap 'rm -rf "$WORK"' EXIT
DMG="$WORK/$NAME"

# Assemble a clean staging folder: the app + a symlink to /Applications so the
# DMG window shows the classic "drag here to install" layout.
STAGE="$WORK/stage"
mkdir "$STAGE"
echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Building $NAME"
# UDZO = zlib-compressed read-only image (small download, mounts read-only).
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

if [ "$LOCAL_DEV" = "1" ]; then
  # Kept out of dist/ deliberately — moved somewhere that survives the trap so it
  # can still be mounted and tested, but under no circumstances into the directory
  # the release upload globs.
  KEEP="$(mktemp -d -t goel-dmg-local)"
  mv "$DMG" "$KEEP/$NAME"
  echo "==> Done: $KEEP/$NAME  (unsigned local image — NOT for distribution)"
  printf '    size: %s\n' "$(du -sh "$KEEP/$NAME" | cut -f1)"
  exit 0
fi

# The notarized app inside does not sign the container around it. An unsigned
# image is quarantined on download and Gatekeeper has nothing to assess.
echo "==> Signing $NAME"
codesign --force --timestamp -s "$CODESIGN_IDENTITY" "$DMG"

# The DMG is notarized in its own right — the ticket stapled to the app inside
# does not travel with the image.
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

# The gates this script was missing. `stapler validate` proves the ticket is
# attached to the image (not just to the app inside), and `spctl -t open` is the
# assessment the user's Mac actually performs when they double-click the
# download — --context primary-signature is what tells it to judge the disk
# image rather than its payload.
if ! xcrun stapler validate "$DMG"; then
  echo "error: no valid notarization ticket is stapled to $DMG." >&2
  exit 1
fi
if ! spctl -a -t open --context context:primary-signature -vvv "$DMG"; then
  echo "error: Gatekeeper rejected $DMG — it will not open on another Mac." >&2
  exit 1
fi
echo "    notarized, stapled and accepted by Gatekeeper."

# Everything has passed, so — and only now — the image becomes a release artifact.
# This `mv` is the single place dist/ is written; anything that went wrong above
# exited with the image still in $WORK, which the trap removes.
mkdir -p dist
FINAL="dist/$NAME"
rm -f "$FINAL"
mv "$DMG" "$FINAL"

echo "==> Done: $FINAL"
printf '    size: %s\n' "$(du -sh "$FINAL" | cut -f1)"
