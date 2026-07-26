#!/usr/bin/env bash
#
# fetch_ytdlp.sh — download the self-contained yt-dlp macOS binary into the app.
#
# yt-dlp powers the optional "Resolve Media with yt-dlp" button (video-site pages
# → a direct downloadable stream). We bundle the official `yt-dlp_macos` standalone
# build, which is PyInstaller-frozen: it carries its OWN Python, so it needs no
# system Python (macOS ships none since 12.3) and works on a machine with nothing
# installed. The app's YtDlpResolver looks for this copy in Contents/Resources
# first, then falls back to a user-installed yt-dlp.
#
# The binary is ~35 MB, so it roughly doubles the bundle. Set BUNDLE_YTDLP=0 in
# build_app.sh (or don't call this) to ship without it — the button just hides
# until the user installs yt-dlp themselves.
#
# Under hardened runtime + notarization this binary needs the entitlements in
# Scripts/Goel.entitlements (PyInstaller dlopen's unsigned .so files at runtime);
# build_app.sh applies them and signs it.
#
# Usage: Scripts/fetch_ytdlp.sh <destination-file>
#   e.g. Scripts/fetch_ytdlp.sh "dist/Goel°.app/Contents/Resources/yt-dlp"
#
# Env:
#   YTDLP_VERSION=YYYY.MM.DD  release to fetch (pinned below)
#   YTDLP_SHA256=<hex>        expected SHA-256 of the published asset
#   YTDLP_ARCH=<arch>         target arch (defaults to the host's)
#
# BUMPING THE VERSION IS A TWO-LINE EDIT. The digest belongs to the release, so
# YTDLP_VERSION and YTDLP_SHA256 must change together. Record the new one with:
#
#   curl -fL -o /tmp/yt-dlp_macos \
#     https://github.com/yt-dlp/yt-dlp/releases/download/<version>/yt-dlp_macos
#   shasum -a 256 /tmp/yt-dlp_macos

set -euo pipefail

DEST="${1:?usage: fetch_ytdlp.sh <destination-file>}"
# Pinned release + the digest of its published asset. This binary is copied into
# a bundle that is then Developer-ID signed and notarized — our signature vouches
# for whatever bytes arrived — so it is verified before it is ever made
# executable. It is also the one bundled binary carrying the
# disable-library-validation / allow-jit entitlements, which is precisely the
# thing you would not want an unverified download to hold.
YTDLP_VERSION="${YTDLP_VERSION:-2026.06.09}"
YTDLP_SHA256="${YTDLP_SHA256:-b82c3626952e6c14eaf654cc565866775ffd0b9ffb7021628ac59b42c2f4f244}"
ASSET="yt-dlp_macos"
ARCH="${YTDLP_ARCH:-$(uname -m)}"
HOST_ARCH="$(uname -m)"

# "latest" is a moving target and therefore cannot have a digest — there is no
# way to state in advance what it should hash to. Accepting it would mean
# signing bytes nobody vetted, so it is refused rather than silently skipping
# verification.
if [ "$YTDLP_VERSION" = "latest" ]; then
  echo "error: YTDLP_VERSION=latest cannot be verified — a moving tag has no digest." >&2
  echo "       Pick the release you want and pin both values:" >&2
  echo "         curl -fL -o /tmp/$ASSET \\" >&2
  echo "           https://github.com/yt-dlp/yt-dlp/releases/download/<version>/$ASSET" >&2
  echo "         shasum -a 256 /tmp/$ASSET" >&2
  echo "       then set YTDLP_VERSION and YTDLP_SHA256 (or edit the pins in this script)." >&2
  exit 1
fi
URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/$ASSET"

mkdir -p "$(dirname "$DEST")"

# The version the binary at $DEST reports, or empty when it cannot be asked.
# build_app.sh ad-hoc signs the staged copy, which changes its bytes, so the
# digest cannot be used to recognise a copy that is already in place — the
# version it prints can.
staged_version() {
  [ -x "$DEST" ] || return 0
  file "$DEST" | grep -q "Mach-O" || return 0
  "$DEST" --version 2>/dev/null | head -1 || true
}

# Idempotent, but only for a copy that is demonstrably the pinned release. The
# old check accepted any Mach-O sitting at the path, so a leftover from a
# different version — or the other architecture — shipped unnoticed.
STAGED="$(staged_version)"
if [ "$STAGED" = "$YTDLP_VERSION" ]; then
  echo "==> yt-dlp $YTDLP_VERSION already bundled ($DEST) — skipping download"
else
  if [ -e "$DEST" ]; then
    echo "==> Replacing staged yt-dlp (${STAGED:-unidentifiable}) with $YTDLP_VERSION"
    rm -f "$DEST"
  fi
  echo "==> Downloading yt-dlp $YTDLP_VERSION ($ASSET, ~35 MB)"
  echo "    $URL"
  # -L follow redirects, -f fail on HTTP error, --retry for flaky networks.
  curl -fL --retry 3 --retry-delay 2 -o "$DEST" "$URL"
  # Verified BEFORE chmod +x: nothing that failed this check should ever be
  # executable, let alone reachable by the signing step.
  ACTUAL="$(shasum -a 256 "$DEST" | awk '{print $1}')"
  if [ "$ACTUAL" != "$YTDLP_SHA256" ]; then
    rm -f "$DEST"
    echo "error: yt-dlp checksum mismatch — refusing to bundle it." >&2
    echo "       expected $YTDLP_SHA256" >&2
    echo "       actual   $ACTUAL" >&2
    echo "       If you bumped YTDLP_VERSION, record the matching digest too (see" >&2
    echo "       the header of this script)." >&2
    exit 1
  fi
  echo "    checksum OK ($YTDLP_SHA256)"
  chmod +x "$DEST"
fi

# Sanity: confirm it's a Mach-O and its arch matches what is being BUILT — not
# the host's, or a cross-built Intel app on Apple Silicon would check the wrong
# thing and pass. Every failure below removes $DEST first, so a bad copy can
# never be picked up by the idempotent path on the next run.
if ! file "$DEST" | grep -q "Mach-O"; then
  echo "error: downloaded yt-dlp is not a Mach-O binary — download likely failed" >&2
  rm -f "$DEST"
  exit 1
fi

BIN_ARCHS="$(lipo -archs "$DEST" 2>/dev/null || echo "unknown")"
echo "    yt-dlp archs: $BIN_ARCHS   (target: $ARCH)"
case " $BIN_ARCHS " in
  *" $ARCH "*) : ;;  # target arch present (or universal2) — good
  *) rm -f "$DEST"
     echo "error: yt-dlp ($BIN_ARCHS) does not include the target arch $ARCH." >&2
     echo "       Shipping it would give the user a 'Resolve with yt-dlp' button that" >&2
     echo "       is present and broken. Set BUNDLE_YTDLP=0 to ship without it." >&2
     exit 1 ;;
esac

# Smoke test — the frozen binary should answer --version offline. Skipped, out
# loud, for a cross-build: an x86_64 slice cannot run on an arm64 host without
# Rosetta, so a failure there would say nothing about the binary.
if [ "$ARCH" = "$HOST_ARCH" ]; then
  if ! "$DEST" --version >/dev/null 2>&1; then
    rm -f "$DEST"
    echo "error: bundled yt-dlp did not run (--version failed) — it is not usable." >&2
    echo "       Set BUNDLE_YTDLP=0 to ship without it." >&2
    exit 1
  fi
  echo "    OK — yt-dlp $("$DEST" --version 2>/dev/null) runs"
else
  echo "    (cross-build for $ARCH on $HOST_ARCH — skipping the --version smoke test)"
fi

echo "==> Bundled yt-dlp -> $DEST"
