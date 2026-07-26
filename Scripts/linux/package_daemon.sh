#!/usr/bin/env bash
#
# package_daemon.sh — build and package the Linux GoelDaemon tarball.
#
# WHY THIS EXISTS
#
# The tarball that shipped before this script was assembled by hand, and it
# showed: it carried libXCTest.so and libTesting.so (test-only libraries with no
# business in a production artifact), it copied the Swift runtime wholesale
# rather than the daemon's actual dependency closure, and it contained no
# licence files at all — not the project's own, and not the Apache-2.0 notice
# that MUST travel with the redistributed Swift runtime .so files. None of that
# is something a human assembling a directory can be relied upon to get right
# twice, so it is a script.
#
# NOT YET VERIFIED ON LINUX. This script was written and reviewed on macOS,
# where `ldd`, `swift build -c release` for GoelDaemon and the .so closure it
# resolves cannot be exercised. Run it once under Ubuntu before treating its
# output as a release artifact, and delete this paragraph when you have.
#
# Prerequisites (Ubuntu):
#   apt install libtorrent-rasterbar-dev libssh2-1-dev libcurl4-openssl-dev \
#               libssl-dev libboost-system-dev
#   Scripts/linux/build-sqlite.sh     # snapshot-enabled libsqlite3.so for GRDB
#
# Usage:  Scripts/linux/package_daemon.sh
# Result: dist/goel-daemon-<version>-linux-<arch>.tar.gz

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ARCH="$(uname -m)"
BIN_NAME="GoelDaemon"

# Version, derived exactly as Scripts/build_app.sh derives it, so a daemon
# tarball and a macOS bundle cut from the same commit cannot disagree about what
# release they are. Only an EXACT tag counts.
VERSION="${GOEL_VERSION:-}"
if [ -z "$VERSION" ]; then
  GIT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  case "$GIT_TAG" in
    v[0-9]*) VERSION="${GIT_TAG#v}" ;;
    [0-9]*)  VERSION="$GIT_TAG" ;;
  esac
fi
if [ -z "$VERSION" ]; then
  echo "error: no exact git tag and no GOEL_VERSION — refusing to name a tarball" >&2
  echo "       after a version it cannot establish. Tag the commit, or set" >&2
  echo "       GOEL_VERSION=<x.y.z> for a deliberate off-tag build." >&2
  exit 1
fi

STAGE_NAME="goel-daemon-${VERSION}-linux-${ARCH}"
STAGE="$(mktemp -d -t goel-daemon-pkg)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$STAGE_NAME"
mkdir -p "$ROOT/bin" "$ROOT/lib"

echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "error: no $BIN_NAME at $BIN" >&2; exit 1; }
cp "$BIN" "$ROOT/bin/$BIN_NAME"

# The Swift runtime .so closure, resolved from the binary rather than copied
# wholesale from the toolchain's lib directory. Only the distro's own packages
# are left out — those are the documented apt prerequisites, and vendoring
# someone's libssl would be both larger and less secure than using theirs.
#
# The three exclusions are the ones a wholesale copy drags in: XCTest and
# swift-testing exist only to run tests, and _InternalSwiftStaticMirror is a
# compiler-internal library nothing at runtime loads.
echo "==> Resolving the .so closure"
EXCLUDE='libXCTest\.so|libTesting\.so|lib_InternalSwiftStaticMirror\.so'
ldd "$ROOT/bin/$BIN_NAME" \
  | awk '/=>/ && $3 ~ /^\// { print $3 }' \
  | grep -E '/swift|/usr/lib/swift' \
  | grep -vE "$EXCLUDE" \
  | while read -r so; do
      cp -L "$so" "$ROOT/lib/$(basename "$so")"
      echo "    + $(basename "$so")"
    done

# GRDB needs the snapshot-enabled SQLite that build-sqlite.sh produces; Ubuntu's
# stock libsqlite3 declares sqlite3_snapshot_* and does not define it.
SQLITE="$REPO_ROOT/Vendor/linux/sqlite/libsqlite3.so"
if [ ! -f "$SQLITE" ]; then
  echo "error: $SQLITE is missing — run Scripts/linux/build-sqlite.sh first." >&2
  exit 1
fi
cp -L "$SQLITE" "$ROOT/lib/libsqlite3.so"
echo "    + libsqlite3.so (snapshot-enabled)"

# Licences. The project's own terms plus the third-party notices, and separately
# the Swift runtime's own LICENSE/NOTICE: those .so files are redistributed
# under Apache-2.0 with the Runtime Library Exception, which requires the notice
# to accompany them. A missing file is a hard stop, not a warning — a tarball
# that ships the libraries without their notices is a licence violation, and the
# previous hand-assembled one had none of these at all.
echo "==> Copying licences"
for f in LICENSE LICENSE-COMMERCIAL.md TRADEMARK.md THIRD-PARTY-NOTICES.md; do
  if [ ! -f "$REPO_ROOT/$f" ]; then
    echo "error: $f is missing from the repository — refusing to package without it." >&2
    exit 1
  fi
  cp "$REPO_ROOT/$f" "$ROOT/$f"
done

SWIFT_LIB_ROOT="$(dirname "$(dirname "$(command -v swift)")")"
SWIFT_NOTICE_FOUND=0
for f in LICENSE.txt NOTICE.txt; do
  found="$(find "$SWIFT_LIB_ROOT" -maxdepth 3 -name "$f" -print -quit 2>/dev/null || true)"
  if [ -n "$found" ]; then
    cp "$found" "$ROOT/SWIFT-RUNTIME-$f"
    SWIFT_NOTICE_FOUND=1
  fi
done
if [ "$SWIFT_NOTICE_FOUND" -eq 0 ]; then
  echo "error: could not find the Swift toolchain's LICENSE.txt/NOTICE.txt under" >&2
  echo "       $SWIFT_LIB_ROOT. The runtime .so files in lib/ are redistributed" >&2
  echo "       under Apache-2.0 with the Runtime Library Exception and cannot ship" >&2
  echo "       without it." >&2
  exit 1
fi

# run.sh and README.txt are GENERATED. The hand-written pair that shipped before
# could drift from the runtime deps the build actually links against, and did.
cat > "$ROOT/run.sh" <<'RUNSH'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$here/lib:${LD_LIBRARY_PATH:-}"
exec "$here/bin/GoelDaemon" "$@"
RUNSH
chmod +x "$ROOT/run.sh"

cat > "$ROOT/README.txt" <<README
Goel daemon $VERSION — Linux $ARCH

The web portal is the UI: start the daemon, then open http://<host>:<port>/.

Runtime packages this build expects from your distribution (the Swift runtime
itself is bundled in lib/):

  apt install libtorrent-rasterbar2.0 libssh2-1 libcurl4 libssl3 \\
              libboost-system1.83.0 ffmpeg

Run:

  GOEL_PORT=8080 GOEL_USERNAME=admin GOEL_PASSWORD=<password> ./run.sh

Licensing: see LICENSE (PolyForm Noncommercial 1.0.0), LICENSE-COMMERCIAL.md,
TRADEMARK.md and THIRD-PARTY-NOTICES.md in this directory. The Swift runtime
libraries in lib/ are redistributed under the Apache License 2.0 with the
Runtime Library Exception — see SWIFT-RUNTIME-LICENSE.txt.
README

echo "==> Packaging"
mkdir -p "$REPO_ROOT/dist"
TARBALL="$REPO_ROOT/dist/$STAGE_NAME.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$STAGE" "$STAGE_NAME"

echo "==> Done: $TARBALL"
printf '    size: %s\n' "$(du -sh "$TARBALL" | cut -f1)"
