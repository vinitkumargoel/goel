#!/usr/bin/env bash
# fetch_ytdlp.sh — download the PyInstaller-frozen `yt-dlp_macos` (carries its own
# Python) into Contents/Resources. ~35 MB; BUNDLE_YTDLP=0 to skip. Needs the entitlements.

set -euo pipefail

DEST="${1:?usage: fetch_ytdlp.sh <destination-file>}"
# Pinned release + digest of its published asset. These bytes get Developer-ID signed
# and notarized under our name, and carry disable-library-validation — so verify first.
YTDLP_VERSION="${YTDLP_VERSION:-2026.06.09}"
YTDLP_SHA256="${YTDLP_SHA256:-b82c3626952e6c14eaf654cc565866775ffd0b9ffb7021628ac59b42c2f4f244}"
ASSET="yt-dlp_macos"
ARCH="${YTDLP_ARCH:-$(uname -m)}"
HOST_ARCH="$(uname -m)"

# "latest" is a moving target and cannot have a digest, so accepting it would mean
# signing bytes nobody vetted. Refused rather than silently skipping verification.
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

# The version the binary at $DEST reports, or empty. build_app.sh ad-hoc signs the
# staged copy, changing its bytes, so the digest can't recognise an in-place copy.
staged_version() {
  [ -x "$DEST" ] || return 0
  file "$DEST" | grep -q "Mach-O" || return 0
  "$DEST" --version 2>/dev/null | head -1 || true
}

# Idempotent only for a copy that is demonstrably the pinned release — the old check
# accepted any Mach-O at the path, so leftovers from another version shipped unnoticed.
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

# Confirm it's a Mach-O whose arch matches what is being BUILT, not the host's. Every
# failure below removes $DEST so a bad copy can't be picked up by the idempotent path.
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

# Smoke test: the frozen binary should answer --version offline. Skipped out loud for
# a cross-build, where an x86_64 slice can't run on an arm64 host without Rosetta.
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
