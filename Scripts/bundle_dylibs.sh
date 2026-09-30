#!/usr/bin/env bash

set -euo pipefail

APP="${1:-dist/GoelDownloader.app}"
INFO_PLIST="$APP/Contents/Info.plist"
EXE_DIR="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"

[ -f "$INFO_PLIST" ] || { echo "error: no Info.plist at $INFO_PLIST" >&2; exit 1; }
EXE="$EXE_DIR/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
[ -f "$EXE" ] || { echo "error: executable not found at $EXE" >&2; exit 1; }

mkdir -p "$FRAMEWORKS"

VENDOR_PREFIX="${GOEL_BREW_PREFIX:-}"
case "$VENDOR_PREFIX" in
  /opt/homebrew|/usr/local) VENDOR_PREFIX="" ;;
esac
# A worktree's Vendor/ is often a symlink to the main checkout's. Libraries built there carry
# install names under the PHYSICAL path, so matching only the logical prefix misses them and they
# ship as absolute build-machine paths that crash at launch. Match both spellings.
VENDOR_PREFIX_REAL=""
if [ -n "$VENDOR_PREFIX" ] && [ -d "$VENDOR_PREFIX" ]; then
  VENDOR_PREFIX_REAL="$(cd "$VENDOR_PREFIX" && pwd -P)"
  [ "$VENDOR_PREFIX_REAL" = "$VENDOR_PREFIX" ] && VENDOR_PREFIX_REAL=""
fi

# Guarded on non-empty: an unset prefix leaves the pattern `/*`, matching /usr/lib too.
under_vendor_prefix() {
  if [ -n "$VENDOR_PREFIX" ]; then
    case "$1" in "$VENDOR_PREFIX"/*) return 0 ;; esac
  fi
  if [ -n "$VENDOR_PREFIX_REAL" ]; then
    case "$1" in "$VENDOR_PREFIX_REAL"/*) return 0 ;; esac
  fi
  return 1
}

is_vendorable() {
  case "$1" in
    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) return 0 ;;
  esac
  under_vendor_prefix "$1"
}

deps_of() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    is_vendorable "$dep" && echo "$dep"
  done
}

# Floor-targeted libs built by Scripts/macos/build-deps.sh already carry `@rpath/…` install names, so
# deps_of never sees them: resolve those against the prefix's lib/ and copy them too.
rpath_deps_of() {
  [ -n "$VENDOR_PREFIX" ] || return 0
  otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      @rpath/*.dylib)
        local candidate="$VENDOR_PREFIX/lib/${dep#@rpath/}"
        [ -f "$candidate" ] && echo "$candidate"
        ;;
    esac
  done
}

# Returns 0 only if newly copied — the fixed-point loop below depends on that.
vendor_one() {
  local dep="$1" base
  base="$(basename "$dep")"
  [ -f "$FRAMEWORKS/$base" ] && return 1
  cp -L "$dep" "$FRAMEWORKS/$base"         # -L: deref the Homebrew symlink
  chmod u+w "$FRAMEWORKS/$base"
  install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base"
  echo "    + $base"
  return 0
}

echo "==> Vendoring dylib closure into $FRAMEWORKS"
for dep in $(deps_of "$EXE") $(rpath_deps_of "$EXE"); do vendor_one "$dep" || true; done
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for f in "$FRAMEWORKS"/*.dylib; do
    [ -e "$f" ] || continue
    for dep in $(deps_of "$f") $(rpath_deps_of "$f"); do
      if vendor_one "$dep"; then changed=1; fi
    done
  done
done
# `[ -e "$FRAMEWORKS"/*.dylib ]` breaks once the glob matches >1 file; test the first match.
set -- "$FRAMEWORKS"/*.dylib
[ -e "$1" ] || echo "    (nothing to vendor — already self-contained)"

echo "==> Rewriting install names to @rpath"
rewrite_refs() {
  local file="$1" dep
  for dep in $(deps_of "$file"); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file"
  done
}
rewrite_refs "$EXE"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && rewrite_refs "$f"; done

# Captured first: under pipefail, `grep -q` exiting early SIGPIPEs otool and a present rpath
# reads as missing — then -add_rpath fails on the duplicate.
rpath_commands=$(otool -l "$EXE" | grep -A2 LC_RPATH || true)
if grep -q "@executable_path/../Frameworks" <<<"$rpath_commands"; then
  :
else
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
  echo "    + added rpath @executable_path/../Frameworks"
fi

# Build-machine rpaths are searched BEFORE bundled Frameworks: dyld silently loads the system copy.
echo "==> Removing stale build-machine rpaths (Homebrew, Xcode toolchain)"
delete_stale_rpaths() {
  local file="$1" rp
  otool -l "$file" | awk '/LC_RPATH/{f=1;next} f&&/ path /{print $2;f=0}' | while read -r rp; do
    local stale=1
    case "$rp" in
      /opt/homebrew/*|/usr/local/*|*/Xcode.app/*) stale=0 ;;
    esac
    under_vendor_prefix "$rp" && stale=0
    [ "$stale" = 0 ] || continue
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null \
      && echo "    - $rp ($(basename "$file"))" || true
  done
}
delete_stale_rpaths "$EXE"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && delete_stale_rpaths "$f"; done

echo "==> Stripping symbols"
before_exe=$(stat -f%z "$EXE")
strip -rSTx "$EXE"
echo "    $(basename "$EXE"): $((before_exe/1024/1024))MB -> $(( $(stat -f%z "$EXE") / 1024/1024 ))MB"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && strip -x "$f"; done
SPK="$FRAMEWORKS/Sparkle.framework"
if [ -d "$SPK" ]; then
  find "$SPK" -type f | while read -r m; do
    if file "$m" | grep -q "Mach-O"; then strip -x "$m" 2>/dev/null || true; fi
  done
  rm -rf "$SPK/Versions/B/Headers" "$SPK/Versions/B/PrivateHeaders" \
         "$SPK/Versions/B/Modules" "$SPK/Headers" "$SPK/PrivateHeaders" "$SPK/Modules"
fi

# codesign rejects a resource bundle with no Info.plist, which blocks sealing.
ensure_bundle_plist() {
  local b="$1" name short build
  [ -f "$b/Info.plist" ] && return 0
  name="$(basename "$b" .bundle)"
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
  cat > "$b/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.goel.downloader.$name</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$short</string>
    <key>CFBundleVersion</key><string>$build</string>
</dict>
</plist>
EOF
  echo "    + synthesized Info.plist for $(basename "$b")"
}

# Sign inside-out: editing load commands invalidates every enclosing signature.
echo "==> Re-signing (ad-hoc)"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && codesign --force -s - "$f"; done
if [ -d "$SPK" ]; then
  for x in "$SPK/Versions/B/XPCServices/"*.xpc; do [ -e "$x" ] && codesign --force -s - "$x"; done
  [ -e "$SPK/Versions/B/Updater.app" ] && codesign --force -s - "$SPK/Versions/B/Updater.app"
  [ -e "$SPK/Versions/B/Autoupdate" ] && codesign --force -s - "$SPK/Versions/B/Autoupdate"
  codesign --force -s - "$SPK"
fi
for b in "$EXE_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  ensure_bundle_plist "$b"
  codesign --force -s - "$b"
done
codesign --force -s - "$EXE"
codesign --force -s - "$APP"

echo "==> Verifying"
leftover="$(
  otool -L "$EXE"
  for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && otool -L "$f"; done
)"
remaining="$(echo "$leftover" | grep -E '/opt/homebrew|/usr/local/(Cellar|opt)' || true)"
# -F, not -E: the prefix is a filesystem path and a `+` or `.` in it would be read as regex.
# Name-based checks only catch prefixes we know about. The real invariant is simpler: a shipped
# Mach-O may load only system libraries or paths relative to the bundle. Anything else absolute is a
# build-machine path, whatever directory it came from.
remaining="$remaining$(echo "$leftover" | awk '/^[[:space:]]/{print $1}' \
  | grep -E '^/' | grep -vE '^/(System/Library|usr/lib)/' || true)"
if [ -n "$remaining" ]; then
  echo "error: build-machine paths still present after bundling:" >&2
  echo "$remaining" >&2
  exit 1
fi
# A clean path list says nothing about presence: an `@rpath` dylib that was never copied only fails at
# launch, in dyld, with "Library not loaded". Every one must be in Frameworks/.
missing=""
for dep in $(echo "$leftover" | awk '$1 ~ /^@rpath\/.*\.dylib$/ {print $1}' | sort -u); do
  [ -f "$FRAMEWORKS/${dep#@rpath/}" ] || missing="$missing $dep"
done
if [ -n "$missing" ]; then
  echo "error: linked but not bundled in $FRAMEWORKS:$missing" >&2
  exit 1
fi
echo "    OK — no build-machine paths remain, every @rpath dylib is bundled. Frameworks:"
# shellcheck disable=SC2012  # display only; names are our own dylibs
ls -1 "$FRAMEWORKS" | sed 's/^/      /'

# Terminal, not advisory: build_app.sh packages next, so a broken seal would ship.
if ! codesign --verify --deep --strict "$APP"; then
  echo "error: bundle is not validly signed after vendoring" >&2
  exit 1
fi
echo "    OK — code signature valid (ad-hoc, --deep --strict)"
