#!/usr/bin/env bash
#
# check_min_os.sh — refuse a bundle that cannot start on the macOS it advertises.
#
# WHY THIS EXISTS
#
# dyld will not load a Mach-O whose LC_BUILD_VERSION `minos` is newer than the
# running system, and it makes that decision *before* main() — so the failure is
# not a degraded feature, it is a bundle that dies on launch with a dialog the
# user cannot act on. Nothing else in the build notices: `swift build` prints a
# link-time warning that scrolls past, `codesign --verify` is happy, the app runs
# perfectly on the machine that built it, and the first person to find out is
# somebody on an older Mac who downloaded it.
#
# The concrete way this happens here: bundle_dylibs.sh vendors libtorrent /
# openssl / libssh2 straight out of Homebrew, and a Homebrew bottle is built for
# the OS of the machine that poured it. Building on macOS 26 therefore produces a
# bundle whose Info.plist says macOS 14 and whose libcrypto says macOS 26.
#
# HOW TO PRODUCE CORRECTLY-TARGETED DYLIBS
#
# This script only reports the mismatch; fixing it is a build-environment change:
#
#   * Build on a machine (or CI runner) whose Homebrew bottles match the
#     deployment target — macos-14 runners pour sonoma bottles, which are
#     minos 14.0. This is what .github/workflows/ci.yml does, and it is the
#     cheapest correct answer.
#   * Or build the native dependencies from source with the target pinned:
#       MACOSX_DEPLOYMENT_TARGET=14.0 brew install --build-from-source \
#           openssl@3 libssh2 libtorrent-rasterbar
#     (boost is statically linked into libtorrent, so it follows automatically.)
#
# GOEL_LOCAL_DEV=1 downgrades the failure to a warning for a throwaway build on
# the developer's own machine. It is NOT silent about it: the script then exits 3
# rather than 0, so every caller can tell "passed" from "waived" and refuse to do
# anything distribution-shaped with the bundle. That distinction was missing, and
# the hole it left was real: a waived build was still notarized and stapled, and
# make_dmg.sh accepted any stapled app, so the escape hatch reached a signed,
# notarized, Gatekeeper-clean .dmg full of dylibs that cannot launch on the macOS
# the bundle advertises.
#
# Exit status:
#   0  every Mach-O runs on the advertised LSMinimumSystemVersion
#   3  it does not, but GOEL_LOCAL_DEV=1 waived the failure — throwaway only
#   1  a real failure (bad bundle, missing purpose strings, unreadable version)
#
# Usage:
#   Scripts/check_min_os.sh <path/to/App.app>
#   Scripts/check_min_os.sh --self-test     # exercise the comparator, no bundle needed

set -euo pipefail

# --- version comparison ------------------------------------------------------
#
# Compared numerically, never lexically: "9.0" sorts after "10.0" as a string,
# and "14.10" sorts before "14.2". Both mistakes silently pass a bundle that
# cannot launch, which is the exact class of bug this script exists to catch.

# version_key <dotted-version> — print a comparable integer, or fail (status 1)
# when the input is not a version this script is willing to reason about.
version_key() {
  local v="${1:-}"
  case "$v" in
    ''|*[!0-9.]*|*.) return 1 ;;
  esac
  local major minor patch
  local IFS=.
  set -- $v
  [ "$#" -ge 1 ] && [ "$#" -le 3 ] || return 1
  major="${1:-}"; minor="${2:-0}"; patch="${3:-0}"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
  printf '%d\n' "$(( 10#$major * 10000 + 10#$minor * 100 + 10#$patch ))"
}

# exceeds <limit> <found> — true when <found> needs a newer macOS than <limit>.
# An unparseable version on either side counts as exceeding: a version this
# script cannot read is a version it cannot vouch for.
exceeds() {
  local limit_key found_key
  limit_key="$(version_key "${1:-}")" || return 0
  found_key="$(version_key "${2:-}")" || return 0
  [ "$found_key" -gt "$limit_key" ]
}

# --- self-test ---------------------------------------------------------------
#
# The comparator is the whole gate, and it runs on machines that have no bundle
# and no signing identity (CI's pull-request job), so it carries its own
# regression test rather than relying on a build to exercise it.
self_test() {
  local failures=0 c limit found expected got
  # limit|found|expected
  local -a cases=(
    '14.0|26.0|fail'    # the live defect: Homebrew bottle from a newer OS
    '14.0|14.0|pass'    # equal is fine — minos == LSMinimumSystemVersion
    '14.0|10.13|pass'   # older is fine
    '9.0|10.0|fail'     # lexical compare would call 10.0 older than 9.0
    '14.2|14.10|fail'   # lexical compare would call 14.10 older than 14.2
    '14.0||fail'        # unreadable version → fail closed
    '14.0|banana|fail'  # ditto
    '|14.0|fail'        # unreadable limit → fail closed
  )
  for c in "${cases[@]}"; do
    limit="${c%%|*}"; c="${c#*|}"
    found="${c%%|*}"; expected="${c#*|}"
    if exceeds "$limit" "$found"; then got="fail"; else got="pass"; fi
    if [ "$got" = "$expected" ]; then
      echo "    ok   limit=${limit:-<empty>} found=${found:-<empty>} -> $got"
    else
      echo "    FAIL limit=${limit:-<empty>} found=${found:-<empty>} -> $got (expected $expected)" >&2
      failures=$((failures + 1))
    fi
  done
  if [ "$failures" -ne 0 ]; then
    echo "error: check_min_os.sh self-test failed ($failures case(s))" >&2
    exit 1
  fi
  echo "==> check_min_os.sh self-test passed (${#cases[@]} cases)"
  exit 0
}

[ "${1:-}" = "--self-test" ] && self_test

# --- bundle gate -------------------------------------------------------------

APP="${1:?usage: check_min_os.sh <path/to/App.app> | --self-test}"
INFO_PLIST="$APP/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || { echo "error: no Info.plist at $INFO_PLIST" >&2; exit 1; }

command -v vtool >/dev/null 2>&1 \
  || { echo "error: vtool not found — install the Xcode command line tools" >&2; exit 1; }

LIMIT="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || true)"
if ! version_key "$LIMIT" >/dev/null; then
  echo "error: $INFO_PLIST has no readable LSMinimumSystemVersion (got '${LIMIT:-<missing>}')" >&2
  echo "       Without it there is nothing to check the Mach-Os against." >&2
  exit 1
fi

# Every macOS deployment target recorded in a file, one per line. Universal
# binaries carry one load command per slice, and the two spellings coexist:
# LC_BUILD_VERSION reports `minos`, the older LC_VERSION_MIN_MACOSX reports
# `version` (the bundled yt-dlp has one of each). The tool-version line that
# follows `ntools` inside LC_BUILD_VERSION is deliberately not matched.
build_versions_of() {
  vtool -show-build-version "$1" 2>/dev/null | awk '
    /^ *cmd LC_BUILD_VERSION/      { mode = "build"; next }
    /^ *cmd LC_VERSION_MIN_MACOSX/ { mode = "min";   next }
    /^Load command/                { mode = "";      next }
    mode == "build" && $1 == "minos"   { print $2; mode = ""; next }
    mode == "min"   && $1 == "version" { print $2; mode = ""; next }
  '
}

# Everything inside the bundle that dyld may be asked to map — the whole of
# Contents, recursively, rather than an allow-list of directories.
#
# The allow-list was MacOS / Frameworks / PlugIns / Resources, which covers where
# things live today (Sparkle's nested XPC services, Updater.app and the Autoupdate
# helper; the bundled yt-dlp and ffmpeg in Resources) and silently excused
# anything added tomorrow: a `Contents/Library`, `Contents/XPCServices` or
# `Contents/Helpers` would have gone unexamined, which is the same failure mode
# with a different directory name. Walking everything cannot miss, and the cost is
# nil — Resources was always the bulk of the file count anyway. `-type f` skips
# the symlink farm inside a versioned framework.
echo "==> Checking Mach-O deployment targets against LSMinimumSystemVersion $LIMIT"
OFFENDERS=""
CHECKED=0
WAIVED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  file "$f" | grep -q "Mach-O" || continue
  CHECKED=$((CHECKED + 1))
  worst=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ -z "$worst" ] || exceeds "$worst" "$v"; then worst="$v"; fi
  done <<EOF
$(build_versions_of "$f")
EOF
  if [ -z "$worst" ]; then
    OFFENDERS="$OFFENDERS
    ${f#$APP/}  (no readable deployment target)"
  elif exceeds "$LIMIT" "$worst"; then
    OFFENDERS="$OFFENDERS
    ${f#$APP/}  requires macOS $worst"
  fi
done <<EOF
$(find "$APP/Contents" -type f)
EOF

if [ "$CHECKED" -eq 0 ]; then
  echo "error: found no Mach-O files in $APP — the bundle is not assembled" >&2
  exit 1
fi

if [ -n "$OFFENDERS" ]; then
  echo "error: $APP advertises macOS $LIMIT but contains binaries that need newer:" >&2
  printf '%s\n' "$OFFENDERS" >&2
  echo "" >&2
  echo "       dyld refuses these before main(), so the app dies on launch on every" >&2
  echo "       Mac between macOS $LIMIT and the highest version listed above." >&2
  echo "       See the header of this script for how to produce correctly-targeted" >&2
  echo "       dylibs, or set GOEL_LOCAL_DEV=1 for a throwaway local build (which" >&2
  echo "       then refuses to emit a distributable archive)." >&2
  # The escape hatch only relaxes THIS gate, and only for a build the caller has
  # already marked as throwaway. The purpose-string gate below still runs: a
  # missing Info.plist key is a repository defect, not a build-machine one.
  if [ "${GOEL_LOCAL_DEV:-0}" != "1" ]; then
    exit 1
  fi
  echo "" >&2
  echo "warning: GOEL_LOCAL_DEV=1 — continuing anyway. This bundle is NOT shippable." >&2
  # Recorded, not forgotten: the exit status below tells the caller the gate was
  # waived, so it can refuse to notarize, staple or package the result.
  WAIVED=1
else
  echo "    OK — all $CHECKED Mach-O files run on macOS $LIMIT"
fi

# --- TCC purpose strings -----------------------------------------------------
#
# Second gate over the same assembled bundle, here because it is the same kind
# of defect: a key that is missing from Info.plist produces a failure the build
# cannot see and the user cannot diagnose. macOS *terminates* a process that
# sends an Apple event without NSAppleEventsUsageDescription, and silently drops
# local-network traffic without NSLocalNetworkUsageDescription — so both are
# launch/runtime correctness, not paperwork.
echo "==> Checking TCC purpose strings"
for key in NSAppleEventsUsageDescription NSLocalNetworkUsageDescription; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    echo "error: $INFO_PLIST is missing $key (or it is empty)." >&2
    echo "       macOS shows this string in the permission prompt; without it the" >&2
    echo "       request is refused — for Apple events, by killing the process." >&2
    exit 1
  fi
done
echo "    OK — purpose strings present"

# 3, not 0: the purpose strings are fine but the deployment targets were waived,
# and a caller that treats that as a pass is the bug this status exists to stop.
if [ "$WAIVED" = "1" ]; then
  exit 3
fi
