#!/usr/bin/env bash
# bundle_dylibs.sh — vendor the full libtorrent/openssl dylib closure into
# Contents/Frameworks, rewrite install names to @rpath, re-sign. Makes the .app portable.

set -euo pipefail

APP="${1:-dist/GoelDownloader.app}"
INFO_PLIST="$APP/Contents/Info.plist"
EXE_DIR="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"

[ -f "$INFO_PLIST" ] || { echo "error: no Info.plist at $INFO_PLIST" >&2; exit 1; }
EXE="$EXE_DIR/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
[ -f "$EXE" ] || { echo "error: executable not found at $EXE" >&2; exit 1; }

mkdir -p "$FRAMEWORKS"

# The prefix Scripts/macos/build-deps.sh installs into. Same variable Package.swift
# reads, so the linker and this script cannot disagree about where the libs came from.
VENDOR_PREFIX="${GOEL_BREW_PREFIX:-}"
case "$VENDOR_PREFIX" in
  /opt/homebrew|/usr/local) VENDOR_PREFIX="" ;;  # already covered below
esac

# True if a dependency lives on this build machine rather than in the OS, and so
# must be copied into the bundle.
is_vendorable() {
  case "$1" in
    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) return 0 ;;
  esac
  # A vendored prefix is as build-machine-local as a Homebrew one. Guarded on non-empty:
  # an unset prefix leaves the pattern `/*`, which would match /usr/lib too.
  if [ -n "$VENDOR_PREFIX" ]; then
    case "$1" in
      "$VENDOR_PREFIX"/*) return 0 ;;
    esac
  fi
  return 1
}

# Emit the Homebrew install-name dependencies of a Mach-O, one per line. (Line 1 of
# `otool -L` is the file itself; @rpath/system deps are filtered by is_vendorable.)
deps_of() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    is_vendorable "$dep" && echo "$dep"
  done
}

# Copy one dependency into Frameworks under the basename used to reference it
# (so @rpath/<basename> resolves). Returns 0 only if it was newly copied.
vendor_one() {
  local dep="$1" base
  base="$(basename "$dep")"
  [ -f "$FRAMEWORKS/$base" ] && return 1   # already vendored
  cp -L "$dep" "$FRAMEWORKS/$base"         # -L: deref the Homebrew symlink
  chmod u+w "$FRAMEWORKS/$base"
  install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base"
  echo "    + $base"
  return 0
}

echo "==> Vendoring dylib closure into $FRAMEWORKS"
# Seed from the executable, then walk to a fixed point over Frameworks so
# transitive deps (e.g. libtorrent -> libssl -> libcrypto) are pulled in too.
for dep in $(deps_of "$EXE"); do vendor_one "$dep" || true; done
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for f in "$FRAMEWORKS"/*.dylib; do
    [ -e "$f" ] || continue
    for dep in $(deps_of "$f"); do
      if vendor_one "$dep"; then changed=1; fi
    done
  done
done
# `[ -e "$FRAMEWORKS"/*.dylib ]` is a syntax error once the glob matches more than
# one file, so this message printed after successfully vendoring. Test the first match.
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

# The executable needs an rpath pointing at Contents/Frameworks.
if otool -l "$EXE" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  :
else
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
  echo "    + added rpath @executable_path/../Frameworks"
fi

# Strip build-machine rpaths: they point at Homebrew/Xcode and are searched BEFORE
# the bundled Frameworks, so dyld would silently load the system copy instead.
echo "==> Removing stale build-machine rpaths (Homebrew, Xcode toolchain)"
delete_stale_rpaths() {
  local file="$1" rp
  otool -l "$file" | awk '/LC_RPATH/{f=1;next} f&&/ path /{print $2;f=0}' | while read -r rp; do
    local stale=1
    case "$rp" in
      /opt/homebrew/*|/usr/local/*|*/Xcode.app/*) stale=0 ;;
    esac
        # Package.swift adds -rpath $GOEL_BREW_PREFIX/lib, so a vendored build leaves one
        # of these too — and it out-ranks the bundled Frameworks just like a Homebrew rpath.
    if [ -n "$VENDOR_PREFIX" ]; then
      case "$rp" in
        "$VENDOR_PREFIX"/*) stale=0 ;;
      esac
    fi
    [ "$stale" = 0 ] || continue
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null \
      && echo "    - $rp ($(basename "$file"))" || true
  done
}
delete_stale_rpaths "$EXE"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && delete_stale_rpaths "$f"; done

# Strip symbols: the executable fully (Swift reflection lives in __swift5_* sections),
# dylibs keep exports and drop locals. Homebrew ships libtorrent unstripped — saves ~4 MB.
echo "==> Stripping symbols"
before_exe=$(stat -f%z "$EXE")
strip -rSTx "$EXE"
echo "    $(basename "$EXE"): $((before_exe/1024/1024))MB -> $(( $(stat -f%z "$EXE") / 1024/1024 ))MB"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && strip -x "$f"; done
# Sparkle: strip its Mach-Os (keep exports) and drop ship-time-useless headers.
SPK="$FRAMEWORKS/Sparkle.framework"
if [ -d "$SPK" ]; then
  find "$SPK" -type f | while read -r m; do
    if file "$m" | grep -q "Mach-O"; then strip -x "$m" 2>/dev/null || true; fi
  done
  rm -rf "$SPK/Versions/B/Headers" "$SPK/Versions/B/PrivateHeaders" \
         "$SPK/Versions/B/Modules" "$SPK/Headers" "$SPK/PrivateHeaders" "$SPK/Modules"
fi

# Some SwiftPM resource bundles ship without an Info.plist, which codesign rejects and
# that blocks sealing. Synthesize a minimal one, taking the version pair from the app's.
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

# Re-sign inside-out (editing load commands invalidates signatures): leaf
# dylibs, then nested resource bundles, then the executable, then the wrapper.
echo "==> Re-signing (ad-hoc)"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && codesign --force -s - "$f"; done
# Sparkle was mutated above (stripped Mach-Os, removed headers) so its seal is stale.
# Re-sign inside-out: xpc services, Updater.app, the Autoupdate helper, then the wrapper.
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
# -F, not -E: the vendored prefix is a filesystem path and would otherwise be read as
# a regex by anyone whose checkout sits somewhere with a `+` or `.` in the name.
if [ -n "$VENDOR_PREFIX" ]; then
  remaining="$remaining$(echo "$leftover" | grep -F "$VENDOR_PREFIX" || true)"
fi
if [ -n "$remaining" ]; then
  echo "error: build-machine paths still present after bundling:" >&2
  echo "$remaining" >&2
  exit 1
fi
echo "    OK — no build-machine paths remain. Frameworks:"
ls -1 "$FRAMEWORKS" | sed 's/^/      /'

# Confirm the whole bundle is validly signed. Terminal, not advisory: build_app.sh
# re-signs and packages next, so "reported issues" meant shipping a broken seal.
if ! codesign --verify --deep --strict "$APP"; then
  echo "error: bundle is not validly signed after vendoring" >&2
  exit 1
fi
echo "    OK — code signature valid (ad-hoc, --deep --strict)"
