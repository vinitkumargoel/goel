#!/usr/bin/env bash
#
# bundle_dylibs.sh — make a release .app self-contained (distributable).
#
# A SwiftPM release build links libtorrent / openssl at absolute Homebrew paths
# (/opt/homebrew/...), so the assembled .app only runs on a machine that has
# those exact formulae installed. This script vendors the *full* dylib closure
# into Contents/Frameworks, rewrites every install name to @rpath, adds an
# rpath to the executable, and re-signs (ad-hoc). After it runs, the .app loads
# all of its native dependencies from inside the bundle and runs on any
# same-architecture Mac (macOS 14+) with no Homebrew required.
#
# Notes
#   * boost is statically linked into libtorrent, so it is not a dylib dep.
#   * The Swift runtime is resolved from the OS (/usr/lib/swift, present on
#     macOS 12.3+), so it is intentionally NOT vendored.
#   * Dedup is keyed on the filesystem (a dep is "done" once its file exists in
#     Frameworks), so the script is idempotent — re-running just re-signs.
#   * Written for stock macOS /bin/bash 3.2 (no associative arrays).
#
# Usage: Scripts/bundle_dylibs.sh [path/to/App.app]   (default: dist/GoelDownloader.app)

set -euo pipefail

APP="${1:-dist/GoelDownloader.app}"
INFO_PLIST="$APP/Contents/Info.plist"
EXE_DIR="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"

[ -f "$INFO_PLIST" ] || { echo "error: no Info.plist at $INFO_PLIST" >&2; exit 1; }
EXE="$EXE_DIR/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
[ -f "$EXE" ] || { echo "error: executable not found at $EXE" >&2; exit 1; }

mkdir -p "$FRAMEWORKS"

# True if a dependency lives under a Homebrew prefix and must be vendored.
is_vendorable() {
  case "$1" in
    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit the Homebrew install-name dependencies of a Mach-O file, one per line.
# (Line 1 of `otool -L` is the file's own path; skip it. @rpath/system deps are
# filtered out by is_vendorable.)
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
[ -e "$FRAMEWORKS"/*.dylib ] 2>/dev/null || echo "    (nothing to vendor — already self-contained)"

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

# Remove build-machine rpaths that leaked into the binaries. They point at
# Homebrew / the Xcode toolchain and are searched BEFORE the bundled Frameworks,
# so on a machine that HAS Homebrew's libtorrent installed dyld would load that
# copy instead of the vendored one (silently defeating the vendoring, and
# possibly loading an incompatible version). Harmless on a clean machine (path
# absent) but wrong everywhere else — strip them so the bundle is the only source.
echo "==> Removing stale build-machine rpaths (Homebrew, Xcode toolchain)"
delete_stale_rpaths() {
  local file="$1" rp
  otool -l "$file" | awk '/LC_RPATH/{f=1;next} f&&/ path /{print $2;f=0}' | while read -r rp; do
    case "$rp" in
      /opt/homebrew/*|/usr/local/*|*/Xcode.app/*)
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null \
          && echo "    - $rp ($(basename "$file"))" || true ;;
    esac
  done
}
delete_stale_rpaths "$EXE"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && delete_stale_rpaths "$f"; done

# Thin fat binaries to the one arch this .app actually ships. Sparkle is
# distributed universal (x86_64 + arm64), but the app itself is single-arch, so
# the other slice is dead weight the user downloads and never executes.
APP_ARCH="$(lipo -archs "$EXE" 2>/dev/null | awk '{print $1}')"
echo "==> Thinning fat binaries to $APP_ARCH"
find "$FRAMEWORKS" -type f | while read -r m; do
  file "$m" | grep -q "Mach-O universal" || continue
  lipo -archs "$m" 2>/dev/null | grep -qw "$APP_ARCH" || continue
  before=$(stat -f%z "$m")
  lipo -thin "$APP_ARCH" "$m" -output "$m.thin" 2>/dev/null || continue
  mv "$m.thin" "$m"
  echo "    $(basename "$m"): $((before/1024))KB -> $(( $(stat -f%z "$m") / 1024 ))KB"
done

# Strip symbols. The executable is fully stripped — nothing links against it,
# and Swift runtime reflection lives in __swift5_* sections (not the symbol
# table), so this is safe. Dylibs keep their exported (global) symbols and drop
# only locals. Homebrew ships libtorrent UNstripped, so this alone reclaims ~4 MB.
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

# A SwiftPM resource bundle (Bundle.module) is a shallow bundle that sits next
# to the executable. Some are generated without an Info.plist, which makes
# codesign reject them ("bundle format unrecognized") and, in turn, blocks the
# app wrapper from sealing. Give any such bundle a minimal Info.plist so it
# becomes a signable bundle. Harmless to resource lookup (done by name).
ensure_bundle_plist() {
  local b="$1" name
  [ -f "$b/Info.plist" ] && return 0
  name="$(basename "$b" .bundle)"
  cat > "$b/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.goel.downloader.$name</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>2</string>
</dict>
</plist>
EOF
  echo "    + synthesized Info.plist for $(basename "$b")"
}

# Re-sign inside-out (editing load commands invalidates signatures): leaf
# dylibs, then nested resource bundles, then the executable, then the wrapper.
echo "==> Re-signing (ad-hoc)"
for f in "$FRAMEWORKS"/*.dylib; do [ -e "$f" ] && codesign --force -s - "$f"; done
# Sparkle was mutated above (stripped Mach-Os + removed headers), so its sealed
# signature is now stale. Re-sign inside-out: xpc services, Updater.app, the
# Autoupdate helper, then the framework wrapper.
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
if echo "$leftover" | grep -qE '/opt/homebrew|/usr/local/(Cellar|opt)'; then
  echo "error: Homebrew paths still present after bundling:" >&2
  echo "$leftover" | grep -E '/opt/homebrew|/usr/local/(Cellar|opt)' >&2
  exit 1
fi
echo "    OK — no Homebrew paths remain. Frameworks:"
ls -1 "$FRAMEWORKS" | sed 's/^/      /'

# Confirm the whole bundle (exe + nested dylibs + bundles) is validly signed.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "    OK — code signature valid (ad-hoc, --deep --strict)"
else
  echo "warning: codesign --verify --deep --strict reported issues" >&2
fi
