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
# Verified end to end: built in a swift:6.1-noble container (Ubuntu 24.04) and the
# resulting tarball installed, started, downloaded and uninstalled on an Ubuntu
# 26.04 host — the cross-release case this script's vendoring exists for.
#
# Prerequisites (Ubuntu):
#   apt install libtorrent-rasterbar-dev libssh2-1-dev libcurl4-openssl-dev \
#               libssl-dev libboost-system-dev binutils gcc
#   Scripts/linux/build-sqlite.sh     # snapshot-enabled libsqlite3.so for GRDB
#
# Do NOT `apt install clang`: the Swift toolchain ships its own, and apt's replaces
# /usr/bin/clang with one that rejects -index-store-path, breaking every C target.
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
# The template must end in X's and be a full path: GNU coreutils rejects `-t NAME`
# with "too few X's", while BSD/macOS mktemp accepts it. This form works on both.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/goel-daemon-pkg.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$STAGE_NAME"
mkdir -p "$ROOT/bin" "$ROOT/lib"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$BIN_NAME"
[ -x "$BIN" ] || { echo "error: no $BIN_NAME at $BIN" >&2; exit 1; }
cp "$BIN" "$ROOT/bin/$BIN_NAME"

# The `goel` admin CLI ships in the same tarball; install.sh wraps it as
# /usr/local/bin/goel. Without it an installed daemon has no interface beyond
# hand-editing the unit, so a tarball missing it is not shippable.
CLI="$BIN_DIR/goel"
[ -x "$CLI" ] || { echo "error: no goel CLI at $CLI" >&2; exit 1; }
cp "$CLI" "$ROOT/bin/goel"

# The localization tables. SwiftPM names this bundle `.resources` on Linux (it is
# `.bundle` on Darwin), and it must sit beside the executable — that is the first
# place ResourceBundles looks. Omitting it left the daemon silently English-only.
RESOURCES="$BIN_DIR/GoelDownloader_GoelCore.resources"
[ -d "$RESOURCES" ] || { echo "error: no resource bundle at $RESOURCES" >&2; exit 1; }
cp -R "$RESOURCES" "$ROOT/bin/"
for code in en de; do
  [ -d "$ROOT/bin/GoelDownloader_GoelCore.resources/$code.lproj" ] \
    || { echo "error: resource bundle has no $code.lproj" >&2; exit 1; }
done

# The unit file the installer installs. Shipping it inside the tarball (rather
# than embedding its text in install.sh) keeps one copy under review in the repo.
mkdir -p "$ROOT/systemd"
cp "$REPO_ROOT/Scripts/linux/goel.service" "$ROOT/systemd/goel.service"

# `goel version` reads this.
printf '%s\n' "$VERSION" > "$ROOT/VERSION"

# The runtime .so closure, resolved from the binaries rather than copied
# wholesale from the toolchain's lib directory.
#
# WHAT IS VENDORED, AND WHY EXACTLY THESE
#
# Two rules decide it: a library is bundled if its SONAME is not stable across
# distributions, and left to the distro if it is — because a distro-supplied
# library keeps getting security updates and a vendored one only updates when we
# cut a release.
#
#   Bundled: the Swift runtime (no distro ships it at all), and
#            libtorrent-rasterbar + Boost. Those two are bundled because their
#            SONAME encodes an upstream version that CHANGES BETWEEN RELEASES:
#            Ubuntu 24.04 has libtorrent-rasterbar.so.2.0, 26.04 has .so.2.1, and
#            Boost goes 1.83 → 1.88. A tarball built on one therefore cannot even
#            start on the other. Verified on Ubuntu 26.04, where
#            `libtorrent-rasterbar2.0` does not exist as a package at all.
#
#   Not bundled: OpenSSL, libcurl, libssh2, and glibc. Their SONAMEs are stable
#            (libssl.so.3, libcurl.so.4, libssh2.so.1) — Debian's `t64` renames
#            changed the *package* name, not the SONAME — and these are precisely
#            the libraries where shipping a frozen copy of someone else's TLS
#            stack would be actively worse than using the one the operator's
#            distribution is patching.
#
# Both libtorrent and Boost are permissively licensed (BSD-3-Clause and BSL-1.0)
# and already recorded in THIRD-PARTY-NOTICES.md, which travels in this tarball —
# see the licence block below.
#
# The three exclusions are the ones a wholesale copy drags in: XCTest and
# swift-testing exist only to run tests, and _InternalSwiftStaticMirror is a
# compiler-internal library nothing at runtime loads.
#
# The closure is resolved from BOTH shipped binaries and unioned: the CLI is a
# separate executable with its own (smaller) set of runtime dependencies, and a
# closure taken from the daemon alone is not guaranteed to cover it.
#
# WHY THIS WALKS TRANSITIVELY RATHER THAN MATCHING A LIST
#
# An allowlist of names to bundle only ever sees the FIRST hop. The vendored
# libFoundationXML.so needs libxml2.so.2, which is not in any such list — so a
# tarball built on 24.04 vendored FoundationXML, left libxml2 to the distro, and
# could not start on 26.04, where libxml2 is .so.16 and the `libxml2` package has
# no candidate at all. Vendoring libxml2 by name would then have failed one hop
# further along, on the libicuuc.so.74 that noble's libxml2 pulls in against
# 26.04's ICU 78.
#
# So the rule is inverted and fails closed: walk the dependencies of everything
# bundled, and bundle each one too UNLESS its SONAME is known stable. A new
# unstable dependency is then carried automatically instead of being discovered
# by a user whose daemon will not start.
#
# The walk follows DIRECT DT_NEEDED edges (objdump -p), not `ldd` output. `ldd`
# prints the whole transitive closure, so walking it treats libcurl's dependencies
# as if the Swift runtime needed them directly — and bundles a frozen GnuTLS,
# Kerberos and OpenLDAP, which is precisely the "someone else's TLS stack, never
# updated" outcome the rules above exist to avoid. Skipping libcurl has to skip
# everything reachable only through it, and only direct edges do that.
echo "==> Resolving the .so closure"
EXCLUDE='libXCTest\.so|libTesting\.so|lib_InternalSwiftStaticMirror\.so'
VENDOR='/usr/lib/swift|libtorrent-rasterbar\.so|libboost_'
# Provided by the target. Base system (glibc and friends), plus the TLS/HTTP stack
# we deliberately leave to the distro's security updates. Anything NOT here that a
# bundled library needs gets bundled.
# ld-linux carries an arch infix (ld-linux-x86-64.so.2, ld-linux-aarch64.so.1), and
# the loader is never something to bundle.
STABLE='^(ld-linux[-a-z0-9]*|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl'
STABLE="$STABLE"'|libstdc\+\+|libgcc_s|libz|liblzma|libzstd|libbz2|libffi'
STABLE="$STABLE"'|libssl|libcrypto|libcurl|libssh2)\.so'

command -v objdump >/dev/null 2>&1 \
  || { echo "error: objdump is required (apt install binutils)." >&2; exit 1; }

# Shared state in files, not variables: the walk recurses through pipelines, and a
# subshell's variable assignments would be lost.
VENDORED="$STAGE/vendored.txt"
SONAME_MAP="$STAGE/sonames.txt"
: > "$VENDORED"

# SONAME -> absolute path, from the binaries' full closure. `ldd`'s transitivity is
# what makes it the right tool HERE (it sees everything reachable) and the wrong
# one for deciding what to bundle.
for binary in "$ROOT/bin/$BIN_NAME" "$ROOT/bin/goel"; do
  ldd "$binary" | awk '/=>/ && $3 ~ /^\// { print $1, $3 }'
done | sort -u > "$SONAME_MAP"

# True when the target distribution is expected to provide this SONAME.
is_stable() {
  printf '%s' "$1" | grep -qE "$STABLE"
}

# Direct DT_NEEDED entries only — see the note above on why not `ldd`.
needed_sonames() {
  objdump -p "$1" 2>/dev/null | awk '/NEEDED/ { print $2 }'
}

resolve_soname() {
  awk -v want="$1" '$1 == want { print $2; exit }' "$SONAME_MAP"
}

vendor_so() {
  _path=$1
  _base=$(basename "$_path")
  if grep -qxF "$_base" "$VENDORED"; then return 0; fi
  printf '%s\n' "$_base" >> "$VENDORED"
  # cp -L follows the symlink, and basename keeps the SONAME as the filename,
  # which is what the dynamic linker looks for at load time.
  cp -L "$_path" "$ROOT/lib/$_base"
  echo "    + $_base"
  needed_sonames "$_path" | sort -u | while read -r _soname; do
    if printf '%s' "$_soname" | grep -qE "$EXCLUDE"; then continue; fi
    if is_stable "$_soname"; then continue; fi
    _dep=$(resolve_soname "$_soname")
    if [ -z "$_dep" ]; then
      echo "error: $_base needs $_soname, which the linker did not resolve on this" >&2
      echo "       build host. The tarball would not start." >&2
      exit 1
    fi
    vendor_so "$_dep"
  done
}

for binary in "$ROOT/bin/$BIN_NAME" "$ROOT/bin/goel"; do
  needed_sonames "$binary" | while read -r soname; do
    path=$(resolve_soname "$soname")
    [ -n "$path" ] || continue
    if printf '%s' "$path" | grep -qE "$EXCLUDE"; then continue; fi
    if printf '%s' "$path" | grep -qE "$VENDOR"; then vendor_so "$path"; fi
  done
done

# Everything a bundled library needs must now be either bundled or known stable.
# The walk guarantees that by construction, so this only catches a typo in the
# patterns above — but it catches it here rather than on a user's machine.
echo "==> Verifying the closure is self-contained"
UNSATISFIED="$STAGE/unsatisfied.txt"
: > "$UNSATISFIED"
for so in "$ROOT"/lib/*.so*; do
  needed_sonames "$so" | while read -r dep; do
    if is_stable "$dep"; then continue; fi
    if [ -e "$ROOT/lib/$dep" ]; then continue; fi
    printf '%s needs %s\n' "$(basename "$so")" "$dep" >> "$UNSATISFIED"
  done
done
if [ -s "$UNSATISFIED" ]; then
  echo "error: bundled libraries depend on SONAMEs that are neither bundled nor" >&2
  echo "       listed as stable, so this tarball would fail to start:" >&2
  sed 's/^/       /' "$UNSATISFIED" >&2
  exit 1
fi
echo "    all $(wc -l < "$VENDORED" | tr -d ' ') bundled libraries resolve"

# libtorrent is the reason this tarball is portable at all, so its absence is a
# hard stop rather than something to discover on the target machine. (Boost is
# not checked: libtorrent may be built with Boost linked statically, in which
# case there is legitimately nothing to copy.)
if ! ls "$ROOT"/lib/libtorrent-rasterbar.so.* >/dev/null 2>&1; then
  echo "error: libtorrent-rasterbar was not vendored into lib/." >&2
  echo "       Without it this tarball only runs on the exact distro release it" >&2
  echo "       was built on. Check that ldd resolves it for $BIN_NAME." >&2
  exit 1
fi

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

You probably do not need this tarball directly. The supported install is:

  curl -fsSL https://goel.vinitk.dev/install.sh | sudo sh

which unpacks this same archive to /opt/goel, installs the systemd service from
systemd/goel.service, writes /etc/goel/config, and puts the \`goel\` command on
your PATH. To install THIS file rather than a downloaded release:

  curl -fsSL https://goel.vinitk.dev/install.sh | sudo GOEL_TARBALL=\$PWD/<tarball> sh

Runtime libraries this build expects from your distribution. The Swift runtime,
libtorrent and Boost are bundled in lib/ and are NOT in this list — their SONAMEs
change between distribution releases, so shipping them is what makes one tarball
work on more than one Ubuntu. These four are left to your distribution so that it
keeps patching them:

  libssh2.so.1   libcurl.so.4   libssl.so.3 / libcrypto.so.3   plus ffmpeg

Package names for those move between releases (Debian's 64-bit time_t transition
renamed several), so let the installer resolve them; by hand on 24.04 it is:

  apt install libssh2-1 libcurl4 libssl3 ffmpeg

and on 26.04 the same packages are named libssh2-1t64, libcurl4t64, libssl3t64.

Contents:

  bin/GoelDaemon      the daemon; the web portal is its only UI
  bin/goel            admin CLI (service, config, queue) — see \`goel help\`
  systemd/goel.service the unit the installer installs
  lib/                the Swift runtime closure, plus snapshot-enabled SQLite
  run.sh              sets LD_LIBRARY_PATH for lib/, then execs the daemon

To run it by hand with no systemd and no installer:

  GOEL_PORT=8080 GOEL_USERNAME=admin GOEL_PASSWORD=<password> ./run.sh

Licensing: see LICENSE (PolyForm Noncommercial 1.0.0), LICENSE-COMMERCIAL.md,
TRADEMARK.md and THIRD-PARTY-NOTICES.md in this directory. The Swift runtime
libraries in lib/ are redistributed under the Apache License 2.0 with the
Runtime Library Exception — see SWIFT-RUNTIME-LICENSE.txt.
README

echo "==> Packaging"
mkdir -p "$REPO_ROOT/dist"
TARBALL="$REPO_ROOT/dist/$STAGE_NAME.tar.gz"
rm -f "$TARBALL" "$TARBALL.sha256"
tar -czf "$TARBALL" -C "$STAGE" "$STAGE_NAME"

# NOT optional: install.sh refuses a release whose .sha256 it cannot fetch, so this
# must ship as a release asset too. The name inside is the basename, so
# `sha256sum -c` works wherever the pair was downloaded.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$REPO_ROOT/dist" && sha256sum "$STAGE_NAME.tar.gz" > "$STAGE_NAME.tar.gz.sha256" )
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$REPO_ROOT/dist" && shasum -a 256 "$STAGE_NAME.tar.gz" > "$STAGE_NAME.tar.gz.sha256" )
else
  echo "error: neither sha256sum nor shasum is available, so the release checksum" >&2
  echo "       cannot be generated — and install.sh refuses releases without one." >&2
  exit 1
fi

echo "==> Done: $TARBALL"
printf '    size:   %s\n' "$(du -sh "$TARBALL" | cut -f1)"
printf '    sha256: %s\n' "$(cut -d' ' -f1 < "$TARBALL.sha256")"
echo "    Publish BOTH files as release assets — install.sh requires the .sha256."
