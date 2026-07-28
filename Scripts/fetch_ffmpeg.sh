#!/usr/bin/env bash
# fetch_ffmpeg.sh — stage a static ffmpeg into the bundle. MUST be LGPL: Goel°'s
# PolyForm licence is GPL-incompatible, so the banner is checked and --enable-gpl refused.

set -euo pipefail

DEST="${1:?usage: fetch_ffmpeg.sh <destination-file>}"
ARCH="${FFMPEG_ARCH:-$(uname -m)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Pinned remote assets, filled in when a checksummed LGPL build is chosen. `unpinned`
# means no vetted asset yet — never a URL without its digest.
case "$ARCH" in
  arm64)
    PINNED_URL="unpinned"
    PINNED_SHA256="unpinned"
    ;;
  x86_64)
    PINNED_URL="unpinned"
    PINNED_SHA256="unpinned"
    ;;
  *)
    echo "error: unsupported architecture '$ARCH' (expected arm64 or x86_64)" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$DEST")"

# --- helpers -----------------------------------------------------------------

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Fail the build, unless the caller opted into a converter-less .app.
give_up() {
  if [ "${FFMPEG_OPTIONAL:-0}" = "1" ]; then
    echo "warning: $1" >&2
    echo "         Building WITHOUT a bundled ffmpeg. Convert / Extract Audio will" >&2
    echo "         tell the user it is missing instead of working." >&2
    exit 0
  fi
  echo "error: $1" >&2
  echo "       Set FFMPEG_LOCAL=<path>, or FFMPEG_URL=<url> with FFMPEG_SHA256=<hex>," >&2
  echo "       or FFMPEG_OPTIONAL=1 to ship without the built-in converter." >&2
  echo "       See the header of Scripts/fetch_ffmpeg.sh for a from-source recipe." >&2
  exit 1
}

# Everything a candidate binary must satisfy before entering the .app. Runs against the
# staged $DEST and removes it on any failure, so a bad copy can't be reused later.
verify() {
  local expected_sha="${1:-}"

  if ! file "$DEST" | grep -q "Mach-O"; then
    rm -f "$DEST"
    give_up "the ffmpeg for $ARCH is not a Mach-O binary — the source is wrong or the download failed"
  fi

  if [ -n "$expected_sha" ] && [ "$expected_sha" != "unpinned" ]; then
    local actual; actual="$(sha256_of "$DEST")"
    if [ "$actual" != "$expected_sha" ]; then
      rm -f "$DEST"
      echo "error: ffmpeg checksum mismatch" >&2
      echo "       expected $expected_sha" >&2
      echo "       actual   $actual" >&2
      exit 1
    fi
    echo "    checksum OK ($expected_sha)"
  fi

  # Arch: a bundle built for arm64 must not carry an x86_64-only ffmpeg. Universal
  # binaries list both and pass either way.
  local archs; archs="$(lipo -archs "$DEST" 2>/dev/null || echo unknown)"
  echo "    ffmpeg archs: $archs   (target: $ARCH)"
  case " $archs " in
    *" $ARCH "*) : ;;
    *) rm -f "$DEST"
       give_up "the ffmpeg binary ($archs) does not include the target arch $ARCH" ;;
  esac

  # Licence gate. `ffmpeg -version` prints the exact configure line it was built
  # with, so this is a fact about the binary rather than a promise about the URL.
  local banner licence="LGPL"
  if ! banner="$("$DEST" -hide_banner -version 2>/dev/null)"; then
    rm -f "$DEST"
    give_up "the ffmpeg binary did not run (-version failed) — it is not usable in the bundle"
  fi
  if printf '%s' "$banner" | grep -qE -- '--enable-(gpl|nonfree)'; then
    licence="GPL/nonfree"
    if [ "${FFMPEG_ALLOW_GPL:-0}" = "1" ]; then
      echo "warning: this ffmpeg is a GPL/nonfree build and FFMPEG_ALLOW_GPL=1 was set." >&2
      echo "         Redistributing it inside a PolyForm Noncommercial app is a licence" >&2
      echo "         violation. THIRD-PARTY-NOTICES.md must be corrected before shipping." >&2
    else
      rm -f "$DEST"
      echo "error: refusing to bundle a GPL/nonfree ffmpeg build." >&2
      echo "       Goel° ships under PolyForm Noncommercial 1.0.0, which is not" >&2
      echo "       GPL-compatible, so only an LGPL configuration may be redistributed." >&2
      echo "       Rebuild ffmpeg with --disable-gpl --disable-nonfree (recipe in this" >&2
      echo "       script's header), or set FFMPEG_ALLOW_GPL=1 if you have taken legal" >&2
      echo "       advice saying otherwise." >&2
      exit 1
    fi
  fi

  local version; version="$(printf '%s' "$banner" | head -1 | awk '{print $3}')"
  echo "    OK — ffmpeg ${version:-?} runs, $licence-configured"
}

# A rebuild should not re-download 70 MB. An existing copy is re-verified rather than
# trusted — it may be left over from a run with different settings or another arch.
if [ -x "$DEST" ] && file "$DEST" | grep -q "Mach-O"; then
  echo "==> ffmpeg already bundled ($DEST) — verifying in place"
  verify ""
  echo "==> Bundled ffmpeg -> $DEST"
  exit 0
fi

# --- source selection --------------------------------------------------------

VENDORED="$REPO_ROOT/Vendor/ffmpeg/$ARCH/ffmpeg"

if [ -n "${FFMPEG_LOCAL:-}" ]; then
  [ -f "$FFMPEG_LOCAL" ] || { echo "error: FFMPEG_LOCAL='$FFMPEG_LOCAL' is not a file" >&2; exit 1; }
  echo "==> Staging ffmpeg from FFMPEG_LOCAL ($FFMPEG_LOCAL)"
  cp "$FFMPEG_LOCAL" "$DEST"
  chmod +x "$DEST"
  verify "${FFMPEG_SHA256:-}"

elif [ -f "$VENDORED" ]; then
  echo "==> Staging vendored ffmpeg ($VENDORED)"
  cp "$VENDORED" "$DEST"
  chmod +x "$DEST"
  verify "${FFMPEG_SHA256:-}"

else
  URL="${FFMPEG_URL:-$PINNED_URL}"
  SHA="${FFMPEG_SHA256:-$PINNED_SHA256}"
  if [ -z "$URL" ] || [ "$URL" = "unpinned" ]; then
    give_up "no ffmpeg source is configured for $ARCH"
  fi
  if [ -z "$SHA" ] || [ "$SHA" = "unpinned" ]; then
    echo "error: FFMPEG_URL is set but FFMPEG_SHA256 is not." >&2
    echo "       Record the digest once and pin it — an unverified binary must never" >&2
    echo "       be copied into a bundle that then gets code-signed:" >&2
    echo "         curl -fL -o /tmp/ffmpeg '$URL' && shasum -a 256 /tmp/ffmpeg" >&2
    exit 1
  fi
  echo "==> Downloading ffmpeg for $ARCH (~40-80 MB)"
  echo "    $URL"
  TMP="$(mktemp -t goel-ffmpeg)"
  # -L follow redirects, -f fail on HTTP error, --retry for flaky networks.
  # Mirrors fetch_ytdlp.sh so both vendoring steps behave identically.
  curl -fL --retry 3 --retry-delay 2 -o "$TMP" "$URL"
  # The digest is checked against the asset as published, and checked HERE — before
  # the branches below hand unverified bytes to unzip/tar.
  ACTUAL="$(sha256_of "$TMP")"
  if [ "$ACTUAL" != "$SHA" ]; then
    rm -f "$TMP"
    echo "error: ffmpeg download checksum mismatch" >&2
    echo "       expected $SHA" >&2
    echo "       actual   $ACTUAL" >&2
    exit 1
  fi
  echo "    checksum OK ($SHA)"
  # Some publishers ship the binary inside a .zip/.tar.xz; unwrap those so the
  # caller never has to care which layout an asset happens to use.
  case "$URL" in
    *.zip)
      WORK="$(mktemp -d -t goel-ffmpeg-unpack)"
      unzip -q -o "$TMP" -d "$WORK"
      FOUND="$(find "$WORK" -type f -name ffmpeg -perm -u+x -print -quit 2>/dev/null || true)"
      [ -n "$FOUND" ] || FOUND="$(find "$WORK" -type f -name ffmpeg -print -quit 2>/dev/null || true)"
      [ -n "$FOUND" ] || { echo "error: no 'ffmpeg' file inside $URL" >&2; exit 1; }
      cp "$FOUND" "$DEST"
      rm -rf "$WORK"
      ;;
    *.tar.xz|*.tar.gz|*.tgz)
      WORK="$(mktemp -d -t goel-ffmpeg-unpack)"
      tar -xf "$TMP" -C "$WORK"
      FOUND="$(find "$WORK" -type f -name ffmpeg -print -quit 2>/dev/null || true)"
      [ -n "$FOUND" ] || { echo "error: no 'ffmpeg' file inside $URL" >&2; exit 1; }
      cp "$FOUND" "$DEST"
      rm -rf "$WORK"
      ;;
    *)
      cp "$TMP" "$DEST"
      ;;
  esac
  # The digest belonged to the archive, which has already been verified above, so
  # verify() is handed only the non-checksum checks.
  rm -f "$TMP"
  chmod +x "$DEST"
  verify ""
fi

echo "==> Bundled ffmpeg -> $DEST"
