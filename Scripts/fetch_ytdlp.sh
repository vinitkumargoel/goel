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
# The binary is ~35 MB, so it roughly triples the download. build_app.sh therefore
# does NOT call this by default — the resolve button just hides until the user
# installs yt-dlp themselves. Set BUNDLE_YTDLP=1 for a self-contained build.
#
# Under hardened runtime + notarization this binary needs the entitlements in
# Scripts/Goel.entitlements (PyInstaller dlopen's unsigned .so files at runtime);
# build_app.sh applies them and signs it.
#
# Usage: Scripts/fetch_ytdlp.sh <destination-file>
#   e.g. Scripts/fetch_ytdlp.sh "dist/Goel°.app/Contents/Resources/yt-dlp"
#
# Pin the version for reproducible builds; override with YTDLP_VERSION=YYYY.MM.DD.

set -euo pipefail

DEST="${1:?usage: fetch_ytdlp.sh <destination-file>}"
# Pinned release. Bump this (and rebuild) to ship a newer yt-dlp. "latest" is
# accepted too, but pinning keeps builds reproducible.
YTDLP_VERSION="${YTDLP_VERSION:-2026.06.09}"
ASSET="yt-dlp_macos"

if [ "$YTDLP_VERSION" = "latest" ]; then
  URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/$ASSET"
else
  URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/$ASSET"
fi

mkdir -p "$(dirname "$DEST")"

# Idempotent: skip the download if a working copy is already in place.
if [ -x "$DEST" ] && file "$DEST" | grep -q "Mach-O"; then
  echo "==> yt-dlp already bundled ($DEST) — skipping download"
else
  echo "==> Downloading yt-dlp $YTDLP_VERSION ($ASSET, ~35 MB)"
  echo "    $URL"
  # -L follow redirects, -f fail on HTTP error, --retry for flaky networks.
  curl -fL --retry 3 --retry-delay 2 -o "$DEST" "$URL"
  chmod +x "$DEST"
fi

# Sanity: confirm it's a Mach-O and its arch is compatible with this build.
if ! file "$DEST" | grep -q "Mach-O"; then
  echo "error: downloaded yt-dlp is not a Mach-O binary — download likely failed" >&2
  rm -f "$DEST"
  exit 1
fi

HOST_ARCH="$(uname -m)"
BIN_ARCHS="$(lipo -archs "$DEST" 2>/dev/null || echo "unknown")"
echo "    yt-dlp archs: $BIN_ARCHS   (host: $HOST_ARCH)"
case " $BIN_ARCHS " in
  *" $HOST_ARCH "*) : ;;  # host arch present (arm64, or universal2) — good
  *) echo "warning: bundled yt-dlp ($BIN_ARCHS) does not include host arch $HOST_ARCH;" >&2
     echo "         the resolve-with-yt-dlp button may fail on this build." >&2 ;;
esac

# Quick smoke test — the frozen binary should answer --version offline.
if "$DEST" --version >/dev/null 2>&1; then
  echo "    OK — yt-dlp $("$DEST" --version 2>/dev/null) runs"
else
  echo "warning: bundled yt-dlp did not run cleanly (--version failed)" >&2
fi

echo "==> Bundled yt-dlp -> $DEST"
