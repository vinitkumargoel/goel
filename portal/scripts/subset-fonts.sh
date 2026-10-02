#!/bin/sh
# Rebuilds portal/src/fonts/*.woff2 from the variable TTFs the macOS app ships.
#
# The portal is served offline by the app and the Linux daemon, so the Studio faces travel in the
# bundle instead of coming from a font CDN. To keep that bundle small each face is:
#   - instanced: Bricolage pinned to wdth 100 / opsz 28 (a display cut), every face trimmed to the
#     weights the CSS uses;
#   - subset to Latin plus the arrows, ≈, ≤ and the typographic punctuation the UI prints;
#   - written as WOFF2, unhinted.
#
# Needs fonttools with brotli:  python3 -m pip install fonttools brotli
# Run from anywhere:            sh portal/scripts/subset-fonts.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../Sources/GoelApp/Resources/Fonts"
out="$here/../src/fonts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

latin='U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+2000-206F,U+2074,U+20AC,U+2122,U+2190-2199,U+2212,U+2215,U+2248,U+2264-2265,U+2318,U+FEFF,U+FFFD'
features='kern,liga,calt,tnum,lnum,case,ss01'

fonttools varLib.instancer "$src/BricolageGrotesque-Variable.ttf" wdth=100 opsz=28 wght=500:800 -q -o "$tmp/display.ttf"
fonttools varLib.instancer "$src/Figtree-Variable.ttf" wght=400:800 -q -o "$tmp/ui.ttf"
fonttools varLib.instancer "$src/SplineSansMono-Variable.ttf" wght=400:700 -q -o "$tmp/mono.ttf"

subset() {
  pyftsubset "$tmp/$1.ttf" --unicodes="$latin" --layout-features="$features" \
    --flavor=woff2 --no-hinting --desubroutinize --output-file="$out/$2.woff2"
}
subset display bricolage-grotesque
subset ui figtree
subset mono spline-sans-mono

cp "$src"/OFL-*.txt "$out/"
ls -l "$out"/*.woff2
