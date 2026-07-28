#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=public/audio
mkdir -p "$DEST"

fetch() {
  [ -f "$DEST/$1" ] && { echo "have  $1"; return; }
  echo "fetch $1"
  curl -fsSL "$2" -o "$DEST/$1"
}
fetch bgm-house-vibez.mp3      https://assets.mixkit.co/music/745/745.mp3
fetch air-zoom-vacuum.mp3      https://assets.mixkit.co/active_storage/sfx/2608/2608-preview.mp3
fetch bass-transition-pulse.mp3 https://assets.mixkit.co/active_storage/sfx/2295/2295-preview.mp3
fetch drum-impact-subtle.mp3   https://assets.mixkit.co/active_storage/sfx/549/549-preview.mp3
fetch shimmer-sparkle-sweep.mp3 https://assets.mixkit.co/active_storage/sfx/2633/2633-preview.mp3
fetch sub-bass-knock.mp3       https://assets.mixkit.co/active_storage/sfx/2300/2300-preview.mp3
fetch sweep-fast-small.mp3     https://assets.mixkit.co/active_storage/sfx/166/166-preview.mp3
fetch sweep-scifi-fast.mp3     https://assets.mixkit.co/active_storage/sfx/3114/3114-preview.mp3
fetch impact-zoom-quick.mp3    https://assets.mixkit.co/active_storage/sfx/772/772-preview.mp3
fetch riser-trailer.mp3        https://assets.mixkit.co/active_storage/sfx/790/790-preview.mp3

LIB="${VIDEO_SHOTCRAFT:-$HOME/.claude/skills/video-shotcraft}/assets/audio"
for f in click-camera impact-cine pop riser-cine sparkle swoosh-quick \
         transition-snap transition-soft whoosh-big whoosh-fast; do
  if [ -f "$DEST/$f.mp3" ]; then echo "have  $f.mp3"; continue; fi
  if [ -f "$LIB/$f.mp3" ]; then cp "$LIB/$f.mp3" "$DEST/"; echo "copy  $f.mp3"
  else echo "MISSING $f.mp3 — not in $LIB; set VIDEO_SHOTCRAFT to the skill dir" >&2; exit 1; fi
done
echo "audio ready in $DEST"
