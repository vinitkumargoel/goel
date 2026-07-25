#!/usr/bin/env bash
# Render each device frame of visual.html to its own PNG, so simulator screenshots can be
# compared against the design spec image-to-image rather than from memory.
#
#   ./Scripts/ios/mockup-frames.sh   ->  tasks/ios-app/shots/mockup/frame0.png … frame8.png
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="tasks/ios-app/shots/mockup"
TMP="/tmp/goel-visual-shot.html"

[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 1; }
mkdir -p "$OUT"

# Inject a hash-driven isolator: file://…/goel-visual-shot.html#f3 renders only frame 3.
python3 - "$TMP" <<'PY'
import pathlib, sys
src = pathlib.Path('visual.html').read_text()
inject = """
<script>
(function(){
  var m = location.hash.match(/^#f(\\d+)$/);
  if(!m) return;
  var figs = Array.prototype.slice.call(document.querySelectorAll('figure.device'));
  var pick = figs[parseInt(m[1],10)];
  if(!pick) return;
  document.body.innerHTML = '';
  document.body.style.cssText = 'margin:0;padding:24px;background:#0b0b0c;display:flex;align-items:flex-start;justify-content:center;';
  document.body.appendChild(pick);
})();
</script>
"""
out = src.replace('</body>', inject + '</body>') if '</body>' in src else src + inject
pathlib.Path(sys.argv[1]).write_text(out)
PY

for i in 0 1 2 3 4 5 6 7 8; do
  "$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=470,1000 \
    --screenshot="$REPO_ROOT/$OUT/frame$i.png" \
    "file://$TMP#f$i" >/dev/null 2>&1
  echo "$OUT/frame$i.png"
done
