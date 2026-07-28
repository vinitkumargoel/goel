#!/usr/bin/env bash
# build_app.sh — release build + assemble dist/Goel°.app (self-contained: vendored
# dylibs, re-signed). GOEL_RELEASE=1 archives; GOEL_LOCAL_DEV=1 throwaway. See RELEASE.md.

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

# GOEL_LOCAL_DEV=1: deployment-target gates warn and nothing distributable is built.
# GOEL_RELEASE=1: demand Developer ID + updater + clean Gatekeeper, then archive.
LOCAL_DEV="${GOEL_LOCAL_DEV:-0}"
GOEL_RELEASE="${GOEL_RELEASE:-0}"
if [ "$LOCAL_DEV" = "1" ] && [ "$GOEL_RELEASE" = "1" ]; then
  echo "error: GOEL_LOCAL_DEV=1 and GOEL_RELEASE=1 are contradictory." >&2
  echo "       GOEL_LOCAL_DEV waives the gates a release exists to satisfy." >&2
  exit 1
fi

# Size-optimized release: -Osize favors smaller code over speed (irrelevant for
# a UI/IO-bound downloader), -dead_strip drops unreferenced code at link time.
BUILD_FLAGS=(-Xswiftc -Osize -Xlinker -dead_strip)
# `Bundle.module` traps in a shipped .app — SwiftPM's accessor resolves only paths
# that don't exist on a user's Mac. Use GoelCore.ResourceBundles; comments exempted.
BUNDLE_MODULE_USES="$(grep -rn --include='*.swift' 'Bundle\.module' Sources/ \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || true)"
if [ -n "$BUNDLE_MODULE_USES" ]; then
  echo "error: Bundle.module is used in Sources/ — it fatal-errors in a packaged .app:" >&2
  printf '%s\n' "$BUNDLE_MODULE_USES" | sed 's/^/    /' >&2
  echo "       Use GoelCore.ResourceBundles (.core / .app) instead." >&2
  exit 1
fi

echo "==> swift build -c $CONFIG --arch $ARCH_ENV (size-optimized)"
# Working files (build log, notarization payload, Gatekeeper report) all live
# here so none of them can be mistaken for a release artifact in dist/.
SCRATCH="$(mktemp -d -t goel-build)"
trap 'rm -rf "$SCRATCH"' EXIT

# Promote ld's "built for newer version of macOS" warning to an error — earliest
# signal a dylib won't load. Only a hint; check_min_os.sh inspects the real bundle.
BUILD_LOG="$SCRATCH/build.log"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${BUILD_FLAGS[@]}" 2>&1 | tee "$BUILD_LOG"
if grep -q 'which was built for newer version' "$BUILD_LOG"; then
  echo "error: the linker warned that a dependency targets a newer macOS than this app:" >&2
  grep 'which was built for newer version' "$BUILD_LOG" | sed 's/^/    /' >&2
  echo "       dyld will refuse those libraries at launch. See Scripts/check_min_os.sh" >&2
  echo "       for how to produce correctly-targeted dylibs." >&2
  if [ "$LOCAL_DEV" != "1" ]; then
    exit 1
  fi
  echo "warning: GOEL_LOCAL_DEV=1 — continuing. This build is NOT shippable." >&2
fi
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# TCC purpose strings: macOS kills a process that sends an Apple event without
# NSAppleEventsUsageDescription. The ATS dict is required for user-supplied http:// URLs.
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
    <string>1.0.4</string>
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
    <key>NSAppleEventsUsageDescription</key>
    <string>Goel° asks System Events to sleep or shut down your Mac when you have chosen to do that after downloads finish.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Goel° needs your local network to serve the remote-control portal to your other devices and to reach NAS shares and SFTP hosts.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp</string>
    </array>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Goel° needs your Downloads folder so it can save downloads to, and watch for new .torrent files in, the folder you chose.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Goel° needs your Desktop folder so it can save downloads to, and watch for new .torrent files in, the folder you chose.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Goel° needs your Documents folder so it can save downloads to, and watch for new .torrent files in, the folder you chose.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Goel° needs removable disks so it can save downloads to, and watch for new .torrent files in, the folder you chose.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Goel° needs network volumes so it can save downloads to, and watch for new .torrent files in, the folder you chose.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
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

# Version stamping: for a RELEASE the git tag is the source of truth (exact match only).
# CFBundleVersion tracks commit count so Sparkle sees it increase monotonically.
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

PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ -n "${GOEL_BUILD:-}" ]; then
  plist_set CFBundleVersion "$GOEL_BUILD"
else
  BUILD_OVERRIDE="$(git rev-list --count HEAD 2>/dev/null || true)"
  # A shallow clone counts 1 commit and would stamp a CFBundleVersion below the shipped
  # one, so Sparkle would never offer it. Refuse; an explicit GOEL_BUILD is exempt.
  if [ -n "$BUILD_OVERRIDE" ] && [ "$BUILD_OVERRIDE" -lt "$PLIST_BUILD" ] 2>/dev/null; then
    echo "error: git-derived CFBundleVersion ($BUILD_OVERRIDE) is lower than the" >&2
    echo "       Info.plist literal ($PLIST_BUILD), so this build would look OLDER" >&2
    echo "       than the last release to Sparkle." >&2
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)" = "true" ]; then
      echo "       This clone is SHALLOW — fetch the full history (fetch-depth: 0)." >&2
    else
      echo "       Set GOEL_BUILD=<n> explicitly if this number is intentional." >&2
    fi
    exit 1
  fi
  if [ -n "$BUILD_OVERRIDE" ]; then
    plist_set CFBundleVersion "$BUILD_OVERRIDE"
  fi
fi

# Executable + resource bundles go in Contents/MacOS beside the binary: inside the
# signed Contents/ tree, and the first place GoelCore.ResourceBundles looks.
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/MacOS/"; done

# A missing resource bundle degrades silently into untranslated UI and no dock icon,
# so treat its absence as broken packaging rather than an optional feature.
for required in GoelDownloader_GoelCore GoelDownloader_GoelApp; do
  if [ ! -d "$APP/Contents/MacOS/$required.bundle" ]; then
    echo "error: resource bundle $required.bundle is missing from $APP/Contents/MacOS." >&2
    echo "       Expected it in $BIN — check the 'resources:' stanzas in Package.swift." >&2
    exit 1
  fi
done

# Frameworks (Sparkle) live in Contents/Frameworks; the matching rpath makes the binary
# resolve @rpath/Sparkle.framework in-bundle instead of the SwiftPM build dir.
mkdir -p "$APP/Contents/Frameworks"
for f in "$BIN"/*.framework; do [ -e "$f" ] && cp -R "$f" "$APP/Contents/Frameworks/"; done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Sparkle needs SPARKLE_FEED_URL + SPARKLE_ED_KEY together; without both the built-in
# checker is used. Supplying one alone is always a mistake, so fail loudly here.
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
elif [ "$GOEL_RELEASE" = "1" ] && [ "${GOEL_NO_UPDATER:-0}" != "1" ]; then
  # Neither var set. Fine locally, but a RELEASE with no feed can never tell users a
  # later version exists — make that a deliberate decision.
  echo "error: GOEL_RELEASE=1 but neither SPARKLE_FEED_URL nor SPARKLE_ED_KEY is set," >&2
  echo "       so this release would ship with no update path at all." >&2
  echo "       Set both, or set GOEL_NO_UPDATER=1 to acknowledge shipping without one." >&2
  exit 1
fi

# App icon (the dark variant is the shipped icon).
cp Assets/AppIcon-Dark.icns "$APP/Contents/Resources/AppIcon.icns"

# AppleScript dictionary (OSAScriptingDefinition points here).
cp Sources/GoelApp/Resources/GoelDownloader.sdef "$APP/Contents/Resources/GoelDownloader.sdef"

# Licence + third-party notices ride inside the bundle (BSD/Apache require it, and a
# copy should be self-describing). All four are tracked, so a missing one is a defect.
for pair in \
  "LICENSE:LICENSE.txt" \
  "THIRD-PARTY-NOTICES.md:THIRD-PARTY-NOTICES.txt" \
  "LICENSE-COMMERCIAL.md:LICENSE-COMMERCIAL.txt" \
  "TRADEMARK.md:TRADEMARK.txt"
do
  src="${pair%%:*}"
  dst="${pair#*:}"
  if [ ! -f "$src" ]; then
    echo "error: $src is missing — it must ride inside the bundle." >&2
    echo "       Redistributing the native libraries without their notices is a" >&2
    echo "       licence violation, so this is not something to skip." >&2
    exit 1
  fi
  cp "$src" "$APP/Contents/Resources/$dst"
done

# Safari Web Extension (.appex), built by hand: NSExtensionMain executable plus the
# shared WebExtension resources. Signed inside-out before bundle_dylibs.sh seals the app.
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

# Optional bundled yt-dlp (~35 MB, roughly doubles the bundle); BUNDLE_YTDLP=0 to skip.
# Ad-hoc signed now so bundle_dylibs can seal; the Developer ID block re-signs it.
if [ "${BUNDLE_YTDLP:-1}" = "1" ]; then
  YTDLP_ARCH="$ARCH_ENV" Scripts/fetch_ytdlp.sh "$APP/Contents/Resources/yt-dlp"
  codesign --force -s - "$APP/Contents/Resources/yt-dlp"
fi

# Optional static LGPL ffmpeg (~40-80 MB) for Convert / Extract Audio; BUNDLE_FFMPEG=0
# to skip. FFMPEG_OPTIONAL=1 downgrades "no source configured" to a warning.
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

# Vendored dylibs most often out-target the app, so gate before spending time signing.
# MINOS_OK records the honest answer: exit 3 = waived, and a waived bundle ships nothing.
minos_gate() {
  if GOEL_LOCAL_DEV="$LOCAL_DEV" Scripts/check_min_os.sh "$1"; then
    MINOS_OK=1
  else
    status=$?
    [ "$status" = 3 ] || exit "$status"
    MINOS_OK=0
  fi
}
minos_gate "$APP"

# Optional Developer ID distribution, gated on CODESIGN_IDENTITY / NOTARY_PROFILE.
# Sign INSIDE-OUT: every nested Mach-O before its container, or signatures invalidate.
ENTITLEMENTS="Scripts/Goel.entitlements"

# Prefer a stable signing identity even locally: an ad-hoc cdhash changes each rebuild, so
# TCC drops grants (Local Network then fails as EHOSTUNREACH). GOEL_RELEASE=1 demands Developer ID.
DISTRIBUTABLE=0

# All codesigning identities, one per line, as `security` reports them.
codesigning_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[0-9A-F]*[[:space:]]*"\(.*\)"$/\1/p'
}

if [ "$GOEL_RELEASE" = "1" ]; then
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    case "$CODESIGN_IDENTITY" in
      "Developer ID Application: "*) ;;
      *) echo "error: GOEL_RELEASE=1 but CODESIGN_IDENTITY is '$CODESIGN_IDENTITY'." >&2
         echo "       Only a 'Developer ID Application: …' certificate produces a bundle" >&2
         echo "       Gatekeeper will accept on someone else's Mac." >&2
         exit 1 ;;
    esac
  else
    # Never `head -1` the whole list — line 1 is usually an Apple Development cert. Filter
    # first and refuse an ambiguous match rather than guessing which team ships.
    DEV_ID_LIST="$(codesigning_identities | grep '^Developer ID Application:' || true)"
    DEV_ID_COUNT="$(printf '%s' "$DEV_ID_LIST" | grep -c . || true)"
    if [ "$DEV_ID_COUNT" -eq 0 ]; then
      echo "error: GOEL_RELEASE=1 but no 'Developer ID Application' identity is installed." >&2
      echo "       There is no fallback here — an Apple Development signature is not" >&2
      echo "       valid for distribution. Install the certificate, then check with:" >&2
      echo "         security find-identity -v -p codesigning" >&2
      exit 1
    fi
    if [ "$DEV_ID_COUNT" -gt 1 ]; then
      echo "error: more than one 'Developer ID Application' identity is installed:" >&2
      printf '%s\n' "$DEV_ID_LIST" | sed 's/^/    /' >&2
      echo "       Set CODESIGN_IDENTITY explicitly — guessing here is how a release" >&2
      echo "       goes out signed by the wrong team." >&2
      exit 1
    fi
    CODESIGN_IDENTITY="$DEV_ID_LIST"
  fi
  DISTRIBUTABLE=1
elif [ -z "${CODESIGN_IDENTITY:-}" ]; then
  AUTO_IDENTITY="$(codesigning_identities | head -1)"
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
  # A secure timestamp is required for notarized distribution but must reach Apple's
  # server; a local development build neither needs it nor should fail when offline.
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

  # NOT `codesign --verify … && echo ok`: a non-final failing command in an AND list
  # doesn't trip `set -e`, so a broken seal used to pass silently.
  if ! codesign --verify --strict --deep "$APP"; then
    echo "error: code signature verification failed for $APP" >&2
    exit 1
  fi
  echo "    signed & verified."

  # Signing is the last step that can replace a Mach-O in the bundle, so the
  # deployment-target gate runs once more over the finished article.
  minos_gate "$APP"

  # A stapled ticket is a distribution credential and make_dmg.sh trusts it, so a waived
  # (throwaway) build must never be notarized.
  if [ -n "${NOTARY_PROFILE:-}" ] && [ "$MINOS_OK" != 1 ]; then
    echo "error: refusing to notarize $APP — its deployment-target gate was waived" >&2
    echo "       by GOEL_LOCAL_DEV=1. Stapling a ticket to it would let make_dmg.sh" >&2
    echo "       wrap binaries that cannot launch on macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null) into a release .dmg." >&2
    echo "       Build without GOEL_LOCAL_DEV, on a runner whose Homebrew bottles" >&2
    echo "       match the deployment target. See Scripts/check_min_os.sh." >&2
    exit 1
  fi

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    # The submission zip is the PRE-staple copy — worthless afterwards and dangerous beside
    # the real artifacts, so it goes in the scratch dir the trap removes.
    ditto -c -k --keepParent "$APP" "$SCRATCH/$APP_NAME.zip"
    xcrun notarytool submit "$SCRATCH/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "    notarized and stapled."
  fi

  # Gatekeeper is the only authority on whether a download opens elsewhere; `codesign
  # --verify` checks the seal, not policy. Match `source=` — spctl alone accepts locally.
  if [ "$DISTRIBUTABLE" = 1 ]; then
    echo "==> Gatekeeper assessment"
    SPCTL_LOG="$SCRATCH/spctl.log"
    if ! spctl -a -vvv -t exec "$APP" 2>&1 | tee "$SPCTL_LOG"; then
      echo "error: Gatekeeper rejected $APP — it will not open on another Mac." >&2
      exit 1
    fi
    if ! grep -q 'source=Notarized Developer ID' "$SPCTL_LOG"; then
      echo "error: Gatekeeper accepted $APP but not as notarized:" >&2
      grep 'source=' "$SPCTL_LOG" | sed 's/^/    /' >&2
      echo "       Only 'source=Notarized Developer ID' means a downloaded copy opens" >&2
      echo "       cleanly. Set NOTARY_PROFILE and re-run." >&2
      exit 1
    fi
    if ! xcrun stapler validate "$APP"; then
      echo "error: no valid notarization ticket is stapled to $APP." >&2
      echo "       Without the ticket the first launch needs Apple to be reachable." >&2
      exit 1
    fi
    echo "    Gatekeeper: notarized, stapled, accepted."
  fi
fi

# Compressed distributable, produced only by a build that cleared the Developer ID +
# notarization gates — otherwise the file carries a release name it cannot honour.
if [ "$DISTRIBUTABLE" = 1 ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  ZIP="dist/Goel-Downloader-${VERSION}-macos-${ARCH_ENV}.zip"
  echo "==> Packaging $ZIP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Done: $APP"
  printf '    installed: %s   download(zip): %s\n' \
    "$(du -sh "$APP" | cut -f1)" "$(du -sh "$ZIP" | cut -f1)"
else
  echo "==> Done: $APP  (local/dev build — no distributable archive emitted)"
  printf '    installed: %s\n' "$(du -sh "$APP" | cut -f1)"
  echo "    To produce a release archive, set GOEL_RELEASE=1 with a Developer ID"
  echo "    Application certificate and NOTARY_PROFILE. See RELEASE.md."
fi
