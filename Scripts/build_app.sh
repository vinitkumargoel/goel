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

# Target arch: native by default. Set GOEL_ARCH=x86_64 (with an x86_64 Homebrew
# via GOEL_BREW_PREFIX=/usr/local) to cross-build an Intel app from Apple Silicon.
ARCH_ENV="${GOEL_ARCH:-$(uname -m)}"
ARCH_FLAGS=(--arch "$ARCH_ENV")

# Size-optimized release: -Osize favors smaller code over speed (irrelevant for
# a UI/IO-bound downloader), -dead_strip drops unreferenced code at link time.
BUILD_FLAGS=(-Xswiftc -Osize -Xlinker -dead_strip)
echo "==> swift build -c $CONFIG --arch $ARCH_ENV (size-optimized)"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${BUILD_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${BUILD_FLAGS[@]}" --show-bin-path)"

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
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Vinit Kumar Goel. Licensed under PolyForm Noncommercial 1.0.0. Commercial use requires a paid licence.</string>
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

# --- version stamping -------------------------------------------------------
#
# The literals above are the fallback for a plain working-copy build. For a
# RELEASE build the git tag is the source of truth: tagging is the one step of
# the release checklist that cannot be forgotten (it is what the appcast and the
# GitHub release are named after), so deriving the version from it removes the
# classic failure where the tag says v1.1.0 and the shipped Info.plist still
# says 1.0.1. Only an EXACT tag match counts — being 13 commits past v1.0.1 does
# not make you v1.0.1, and silently mislabelling a dev build as a release is
# worse than leaving the literal alone.
#
#   GOEL_VERSION=1.2.0  — override CFBundleShortVersionString explicitly
#   GOEL_BUILD=57       — override CFBundleVersion explicitly
#
# CFBundleVersion tracks the commit count: Sparkle compares this to decide
# whether an appcast item is newer, so it must increase monotonically across
# releases, which a commit count does and a hand-edited literal does not.
plist_set() {  # plist_set <key> <value> — set, or add when the key is absent
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$APP/Contents/Info.plist"
}

VERSION_SOURCE="GOEL_VERSION"
VERSION_OVERRIDE="${GOEL_VERSION:-}"
if [ -z "$VERSION_OVERRIDE" ]; then
  VERSION_SOURCE="git tag"
  GIT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  case "$GIT_TAG" in
    v[0-9]*) VERSION_OVERRIDE="${GIT_TAG#v}" ;;
    [0-9]*)  VERSION_OVERRIDE="$GIT_TAG" ;;
  esac
fi
if [ -n "$VERSION_OVERRIDE" ]; then
  echo "==> Version $VERSION_OVERRIDE (from $VERSION_SOURCE)"
  plist_set CFBundleShortVersionString "$VERSION_OVERRIDE"
else
  echo "==> Version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") (untagged build — Info.plist literal)"
fi

BUILD_OVERRIDE="${GOEL_BUILD:-$(git rev-list --count HEAD 2>/dev/null || true)}"
[ -n "$BUILD_OVERRIDE" ] && plist_set CFBundleVersion "$BUILD_OVERRIDE"

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
# Without them the app uses the built-in release-feed checker instead
# (SparkleUpdaterService refuses to start on a half-configured bundle).
#
# Supplying only ONE of the pair is always a mistake — a feed without a key
# means unverified downloads, a key without a feed means nothing happens — so
# fail loudly here rather than shipping a build whose updater silently does the
# wrong thing. HTTPS is likewise enforced at package time, not just at runtime.
if [ -n "${SPARKLE_FEED_URL:-}" ] || [ -n "${SPARKLE_ED_KEY:-}" ]; then
  if [ -z "${SPARKLE_FEED_URL:-}" ] || [ -z "${SPARKLE_ED_KEY:-}" ]; then
    echo "error: set BOTH SPARKLE_FEED_URL and SPARKLE_ED_KEY, or neither." >&2
    exit 1
  fi
  case "$SPARKLE_FEED_URL" in
    https://*) ;;
    *) echo "error: SPARKLE_FEED_URL must be https:// (got $SPARKLE_FEED_URL)" >&2; exit 1 ;;
  esac
  echo "==> Enabling Sparkle updates ($SPARKLE_FEED_URL)"
  plist_set SUFeedURL "$SPARKLE_FEED_URL"
  plist_set SUPublicEDKey "$SPARKLE_ED_KEY"
fi

# App icon (the dark variant is the shipped icon).
cp Assets/AppIcon-Dark.icns "$APP/Contents/Resources/AppIcon.icns"

# AppleScript dictionary (OSAScriptingDefinition points here).
cp Sources/GoelApp/Resources/GoelDownloader.sdef "$APP/Contents/Resources/GoelDownloader.sdef"

# License + third-party notices ride inside the bundle — BSD/Apache require the
# notices to accompany the redistributed native libraries. The commercial-licence
# and trademark notes ride along too so a copy of the .app is self-describing:
# someone who receives the bundle without the repository can still read what the
# terms are and who to contact, which is the whole point of an honour-based
# licence (there is no key check to tell them).
[ -f LICENSE ] && cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
[ -f THIRD-PARTY-NOTICES.md ] && cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
[ -f LICENSE-COMMERCIAL.md ] && cp LICENSE-COMMERCIAL.md "$APP/Contents/Resources/LICENSE-COMMERCIAL.txt"
[ -f TRADEMARK.md ] && cp TRADEMARK.md "$APP/Contents/Resources/TRADEMARK.txt"

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
ARCH="$ARCH_ENV"
swiftc -parse-as-library \
  SafariExtension/SafariWebExtensionHandler.swift \
  -o "$APPEX/Contents/MacOS/GoelSafariExtension" \
  -target "${ARCH}-apple-macosx14.0" \
  -framework Foundation -framework AppKit -framework SafariServices \
  -Xlinker -e -Xlinker _NSExtensionMain
codesign --force -s - "$APPEX"

# Optional: bundle a self-contained yt-dlp (video-site → direct-stream resolver).
# ~35 MB, so it roughly doubles the bundle; set BUNDLE_YTDLP=0 to ship without it
# (the "Resolve with yt-dlp" button then stays hidden until the user installs one).
# Signed ad-hoc now so bundle_dylibs can seal the app wrapper; the Developer ID
# block below re-signs it with hardened runtime + entitlements.
if [ "${BUNDLE_YTDLP:-1}" = "1" ]; then
  Scripts/fetch_ytdlp.sh "$APP/Contents/Resources/yt-dlp"
  codesign --force -s - "$APP/Contents/Resources/yt-dlp"
fi

# Optional: bundle a static LGPL ffmpeg (Convert / Extract Audio on finished
# media). Adds ~40-80 MB. Set BUNDLE_FFMPEG=0 to ship without it — the actions
# then TELL the user it is missing rather than silently disappearing.
# FFMPEG_OPTIONAL=1 (the default here) downgrades "no source configured" from a
# build failure to a warning; flip it to 0 once a checksummed LGPL asset is
# pinned in Scripts/fetch_ffmpeg.sh. Signed ad-hoc now so bundle_dylibs.sh can
# seal the app wrapper; the Developer ID block below re-signs it.
if [ "${BUNDLE_FFMPEG:-1}" = "1" ]; then
  FFMPEG_ARCH="$ARCH_ENV" FFMPEG_OPTIONAL="${FFMPEG_OPTIONAL:-1}" \
    Scripts/fetch_ffmpeg.sh "$APP/Contents/Resources/ffmpeg"
  # NOT collapsed into `[ -e ... ] && codesign ...`: under `set -e` a false test
  # as the last statement of the outer if-body aborts the build.
  if [ -e "$APP/Contents/Resources/ffmpeg" ]; then
    codesign --force -s - "$APP/Contents/Resources/ffmpeg"
  fi
fi

# Vendor native dylibs, rewrite install names, and sign.
Scripts/bundle_dylibs.sh "$APP"

# Optional Developer ID distribution, gated on env vars so the default build
# stays untouched:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" — sign with
#     hardened runtime, INSIDE-OUT (leaves first, app wrapper last)
#   NOTARY_PROFILE="<notarytool keychain profile>" — submit + staple
# The entitlements (disable-library-validation, allow-jit, …) let the hardened
# app load its vendored dylibs and run the PyInstaller-based yt-dlp. See
# Scripts/Goel.entitlements. Editing load commands invalidates signatures, so the
# ORDER matters: every nested Mach-O must be signed before the thing that contains it.
ENTITLEMENTS="Scripts/Goel.entitlements"

# Prefer a *stable* signing identity even for local builds.
#
# Ad-hoc signing (`codesign -s -`) yields a designated requirement made of
# nothing but the code hash:
#
#     designated => cdhash H"9c4e1e6f…"
#
# That hash changes on every rebuild, and macOS keys its privacy grants to the
# designated requirement — so each rebuild is a brand-new app to TCC and
# silently loses whatever the user already approved. The one that bites here is
# Local Network: without it, connecting to a LAN server fails at the socket with
# EHOSTUNREACH, which surfaces as a connection error against a server that is
# switched on and perfectly reachable. Re-approving after every build is not a
# thing anyone should have to know to do.
#
# Signing with a real certificate anchors the requirement to that certificate
# instead, so approvals persist across rebuilds. Any identity works for local
# use; an "Apple Development" one is what most Macs with Xcode already have.
# Set CODESIGN_IDENTITY=- to force the old ad-hoc behaviour.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  AUTO_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
                  | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[0-9A-F]*[[:space:]]*"\(.*\)"$/\1/p' \
                  | head -1)
  if [ -n "$AUTO_IDENTITY" ]; then
    CODESIGN_IDENTITY="$AUTO_IDENTITY"
    echo "==> Auto-selected signing identity (keeps macOS privacy approvals across rebuilds):"
    echo "    $CODESIGN_IDENTITY"
    echo "    Override with CODESIGN_IDENTITY=…, or CODESIGN_IDENTITY=- for ad-hoc."
  else
    echo "==> No code-signing identity found — falling back to ad-hoc."
    echo "    macOS will treat each rebuild as a new app and drop its Local"
    echo "    Network / privacy approvals. Create a signing certificate to fix."
  fi
fi
[ "${CODESIGN_IDENTITY:-}" = "-" ] && CODESIGN_IDENTITY=""

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Codesigning with '$CODESIGN_IDENTITY' (hardened runtime, inside-out)"
  # A secure timestamp is required for notarized distribution but needs to reach
  # Apple's timestamp server; a local development build neither needs it nor
  # should fail when offline.
  case "$CODESIGN_IDENTITY" in
    "Developer ID"*) TIMESTAMP_FLAG="--timestamp" ;;
    *)               TIMESTAMP_FLAG="--timestamp=none" ;;
  esac
  sign() { codesign --force --options runtime "$TIMESTAMP_FLAG" -s "$CODESIGN_IDENTITY" "$@"; }

  # 1. Vendored native dylibs (leaves — no entitlements needed).
  for f in "$APP/Contents/Frameworks/"*.dylib; do [ -e "$f" ] && sign "$f"; done

  # 2. Sparkle's nested helpers, inside-out, preserving their own entitlements.
  SPK="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPK" ]; then
    for x in "$SPK/Versions/B/XPCServices/"*.xpc; do [ -e "$x" ] && sign --preserve-metadata=entitlements "$x"; done
    [ -e "$SPK/Versions/B/Updater.app" ] && sign "$SPK/Versions/B/Updater.app"
    [ -e "$SPK/Versions/B/Autoupdate" ] && sign "$SPK/Versions/B/Autoupdate"
    sign "$SPK"
  fi

  # 3. Bundled yt-dlp — needs the hardened-runtime entitlements to run its Python.
  [ -e "$APP/Contents/Resources/yt-dlp" ] && sign --entitlements "$ENTITLEMENTS" "$APP/Contents/Resources/yt-dlp"

  # 3b. Bundled ffmpeg — a plain static Mach-O; no entitlements needed.
  [ -e "$APP/Contents/Resources/ffmpeg" ] && sign "$APP/Contents/Resources/ffmpeg"

  # 4. SwiftPM resource bundles, 5. Safari extension.
  for b in "$APP/Contents/MacOS/"*.bundle; do [ -e "$b" ] && sign "$b"; done
  for x in "$APP/Contents/PlugIns/"*.appex; do [ -e "$x" ] && sign "$x"; done

  # 6. Main executable, then 7. the app wrapper — both carry the app entitlements.
  sign --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/$APP_NAME"
  sign --entitlements "$ENTITLEMENTS" "$APP"

  codesign --verify --strict --deep "$APP" && echo "    signed & verified."
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
ZIP="dist/Goel-Downloader-${VERSION}-macos-${ARCH_ENV}.zip"
echo "==> Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done: $APP"
printf '    installed: %s   download(zip): %s\n' \
  "$(du -sh "$APP" | cut -f1)" "$(du -sh "$ZIP" | cut -f1)"
