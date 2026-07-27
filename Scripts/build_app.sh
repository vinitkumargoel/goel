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
# Result: dist/Goel°.app
#
# By default this produces a LOCAL build: signed with whatever identity is handy
# so macOS keeps its privacy grants across rebuilds, and deliberately NOT
# packaged into a release archive, because such a build is not one.
#
#   GOEL_RELEASE=1    demand a Developer ID Application certificate, a configured
#                     updater and a clean Gatekeeper assessment; only then emit
#                     dist/Goel-Downloader-<version>-macos-<arch>.zip
#   GOEL_LOCAL_DEV=1  throwaway build: the deployment-target gates warn instead
#                     of failing, and nothing distributable is produced
#
# See RELEASE.md for the full release sequence.

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

# GOEL_LOCAL_DEV=1 marks a throwaway build on the developer's own machine: the
# deployment-target gates degrade to warnings, and in exchange no distributable
# archive is produced (see DISTRIBUTABLE below). It is never set in CI.
#
# GOEL_RELEASE=1 is the opposite end: it demands a Developer ID Application
# certificate, a configured updater, a Gatekeeper-clean result, and only then
# emits an archive. The two are mutually exclusive by construction.
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
# `Bundle.module` is unusable in a shipped .app and must never come back.
#
# SwiftPM's generated accessor resolves a resource bundle from exactly two
# places: `Bundle.main.bundleURL/<name>.bundle` — which for an app is the .app
# root, where codesign forbids anything but Contents/ — and the absolute .build
# path of the machine that compiled the binary. Neither exists on a user's Mac,
# and the accessor calls fatalError rather than returning nil, so the app traps
# on the first localized string. The failure is invisible to whoever built it,
# because on that one machine the hard-coded .build path still resolves.
#
# GoelCore.ResourceBundles is the supported replacement; see
# Sources/GoelCore/ResourceBundle.swift.
# Comment lines are excluded so the explanation above (and the one in
# ResourceBundle.swift) does not trip the check that enforces it.
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

# The build log is kept because ld's "built for newer version of macOS" warning
# is the earliest signal that a linked dylib will not load on the OS this app
# advertises. It scrolls past in a normal build and nothing else looks at it, so
# it is promoted to an error here. `pipefail` is already on, so a failing
# `swift build` still aborts despite the pipe into tee.
#
# This is an EARLY signal, not the authority: an incremental build that relinks
# nothing prints no warning. Scripts/check_min_os.sh inspects the assembled
# bundle itself and is what actually decides.
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

# --- about the TCC purpose strings below ------------------------------------
#
# A missing *UsageDescription is not a cosmetic omission: macOS TERMINATES a
# process that sends an Apple event without NSAppleEventsUsageDescription, so
# the "shut down when downloads finish" drain would kill the app instead of the
# Mac. The rest are the folders and networks this app is actually pointed at:
#
#   NSAppleEvents        LiveSystemActions asks System Events to shut down.
#   NSLocalNetwork       RemoteControlServer binds an NWListener and advertises
#     + NSBonjourServices  _http._tcp; SFTP/NAS transfers reach LAN hosts. The
#                        service type must match RemoteControlServer exactly or
#                        the advertisement is dropped without a word.
#   Downloads/Desktop/   the save directory defaults to ~/Downloads with no open
#     Documents          panel (so there is no implicit grant), and a persisted
#                        watch folder is re-read at launch.
#   Removable/Network    documented targets for finished files (SMB/NFS, disks).
#     Volumes
#
# Nothing else is listed because nothing else is called — no camera, microphone,
# photos or contacts API exists in this codebase, and an unused purpose string is
# a claim the app cannot justify.
#
# NSAppTransportSecurity: a general-purpose download client fetches URLs the
# *user* supplies, and plain http:// is one of them. Without this dict every
# http:// transfer fails with NSURLErrorAppTransportSecurityRequiresSecureConnection
# (-1022) — verified against a packaged build — which surfaces as a generic
# transfer error on a URL that works fine in curl. The scheme allowlist lives in
# NetworkGuard (http/https only) and the redirect chain is sanitised by
# RedirectSanitizer, so relaxing ATS does not widen what the app will fetch; it
# only stops ATS from vetoing a capability the app documents. Sparkle's appcast
# and the release feed independently require https, so the updater path is
# unaffected by this.
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

PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ -n "${GOEL_BUILD:-}" ]; then
  plist_set CFBundleVersion "$GOEL_BUILD"
else
  BUILD_OVERRIDE="$(git rev-list --count HEAD 2>/dev/null || true)"
  # The commit count only increases monotonically over a COMPLETE history. A
  # shallow clone (actions/checkout defaults to fetch-depth: 1) counts 1 commit
  # and would stamp a release with a CFBundleVersion *below* the one already
  # shipped — Sparkle would then read the new release as older and never offer
  # it. Refuse rather than silently regress; an explicit GOEL_BUILD is exempt,
  # because that is a human asserting the number on purpose.
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

# Executable + SwiftPM resource bundles. They live in Contents/MacOS beside the
# binary: that keeps them inside the signed Contents/ tree (codesign rejects an
# app with unsealed contents in the bundle root) and it is the first place
# GoelCore.ResourceBundles looks.
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/MacOS/"; done

# A resource bundle that fails to land does not break the build or the launch —
# it silently degrades into untranslated UI and a missing dock icon, which is
# exactly the kind of defect that reaches users unnoticed. The localization
# tables are declared in Package.swift, so their absence here means packaging
# broke, not that the feature is optional.
for required in GoelDownloader_GoelCore GoelDownloader_GoelApp; do
  if [ ! -d "$APP/Contents/MacOS/$required.bundle" ]; then
    echo "error: resource bundle $required.bundle is missing from $APP/Contents/MacOS." >&2
    echo "       Expected it in $BIN — check the 'resources:' stanzas in Package.swift." >&2
    exit 1
  fi
done

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
elif [ "$GOEL_RELEASE" = "1" ] && [ "${GOEL_NO_UPDATER:-0}" != "1" ]; then
  # Neither var set. For a local build that is fine — the in-app checker tells
  # the user to configure a feed. For a RELEASE it means the copy people
  # download has no way to learn that a later one exists, and nothing anywhere
  # would say so. Make that a decision someone has to take on purpose.
  echo "error: GOEL_RELEASE=1 but neither SPARKLE_FEED_URL nor SPARKLE_ED_KEY is set," >&2
  echo "       so this release would ship with no update path at all." >&2
  echo "       Set both, or set GOEL_NO_UPDATER=1 to acknowledge shipping without one." >&2
  exit 1
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
#
# All four are tracked files, so a missing one is a broken checkout or a bad
# merge, not a condition to route around: copying "if present" turns a licence
# obligation into a coin toss that nothing reports. Fail instead.
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
  YTDLP_ARCH="$ARCH_ENV" Scripts/fetch_ytdlp.sh "$APP/Contents/Resources/yt-dlp"
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

# The vendored dylibs are the ones most likely to out-target the app, so the
# deployment-target gate runs the moment they land — before any time is spent
# signing or notarizing a bundle that cannot launch. It runs again after signing,
# because signing is the last step that can substitute a binary.
#
# MINOS_OK records the *honest* answer. Exit 3 means GOEL_LOCAL_DEV=1 waived a
# real failure, and a waived bundle must not be notarized, stapled or packaged —
# `DISTRIBUTABLE=0` alone was not enough, because it only guards the .zip: the
# stapling block below is gated on CODESIGN_IDENTITY, and make_dmg.sh admits any
# stapled app. That is how a bundle full of unlaunchable dylibs reached a signed,
# notarized .dmg. Run through an `if` so `set -e` doesn't abort before the status
# can be read.
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
#
# GOEL_RELEASE=1 switches this from "any identity keeps TCC happy" to "only a
# Developer ID Application certificate will do". The two are NOT interchangeable:
# an Apple Development certificate signs perfectly and is then rejected by
# Gatekeeper on every machine that is not the one that built it, which is exactly
# how a build can look successful and still be undistributable. DISTRIBUTABLE
# records which of the two happened, and nothing is packaged for release unless
# it is 1.
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
    # Never `head -1` the whole list: the first line is usually an Apple
    # Development certificate, and picking it silently is the defect this gate
    # exists to prevent. Filter first, and refuse an ambiguous match rather than
    # guessing which team ships.
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

  # NOT `codesign --verify … && echo ok`: a failing command that is not the last
  # in an AND list does not trip `set -e`, so the old form printed nothing on
  # failure and carried straight on to package a bundle whose seal was broken.
  if ! codesign --verify --strict --deep "$APP"; then
    echo "error: code signature verification failed for $APP" >&2
    exit 1
  fi
  echo "    signed & verified."

  # Signing is the last step that can replace a Mach-O in the bundle, so the
  # deployment-target gate runs once more over the finished article.
  minos_gate "$APP"

  # Notarizing a waived bundle is what made the escape hatch dangerous: a stapled
  # ticket is a distribution credential, and make_dmg.sh (rightly) trusts it. A
  # throwaway build does not get one, so the hatch stays throwaway.
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
    # The submission zip is the PRE-staple copy. It is worthless once notarytool
    # has answered and actively dangerous sitting in dist/ next to the real
    # artifacts, so it is written to the scratch dir the trap removes.
    ditto -c -k --keepParent "$APP" "$SCRATCH/$APP_NAME.zip"
    xcrun notarytool submit "$SCRATCH/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "    notarized and stapled."
  fi

  # Gatekeeper is the only authority on whether a download will open on someone
  # else's Mac. `codesign --verify` cannot see a rejection — it checks the seal,
  # not the policy — so the real assessment happens here.
  #
  # `spctl` alone is not enough either: on the signing machine a
  # Developer-ID-signed but UNNOTARIZED bundle is still accepted locally, and it
  # says so in the `source=` line. That line is the honest signal, so it is what
  # gets matched. Local/dev builds skip the whole block: they are not claiming to
  # pass, and a CI runner with no certificate has nothing to assess.
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

# Compressed distributable (drag-to-share / drag-to-/Applications). The .app
# installs at ~19 MB but the native dylibs compress well, so the download is
# roughly half that.
#
# Only a build that actually cleared the Developer ID + notarization gates gets
# one. An ad-hoc or Apple-Development bundle used to produce a file with exactly
# the release name, indistinguishable from the real thing until someone
# downloaded it and Gatekeeper refused to open it.
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
