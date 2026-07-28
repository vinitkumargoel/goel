#!/usr/bin/env bash
# Build the app's native deps from source with MACOSX_DEPLOYMENT_TARGET pinned, so the
# advertised floor is a decision, not whichever Homebrew bottles the build Mac had.
set -euo pipefail

# ---- pins ------------------------------------------------------------------
OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.2}"
OPENSSL_SHA256="${OPENSSL_SHA256:-aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f}"

LIBSSH2_VERSION="${LIBSSH2_VERSION:-1.11.1}"
LIBSSH2_SHA256="${LIBSSH2_SHA256:-d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7}"

BOOST_VERSION="${BOOST_VERSION:-1.90.0}"
BOOST_SHA256="${BOOST_SHA256:-9e6bee9ab529fb2b0733049692d57d10a72202af085e553539a05b4204211a6f}"

LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-2.0.13}"
LIBTORRENT_SHA256="${LIBTORRENT_SHA256:-892cb75c06318e2420de0faf9f63a908069d3d237676e2459fd30abe0cb3b1bf}"

# The floor the app advertises. Must agree with LSMinimumSystemVersion in build_app.sh
# and platforms: [.macOS(...)] in Package.swift — all three state the same promise.
MIN_MACOS="${GOEL_MIN_MACOS:-14.0}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="${GOEL_ARCH:-$(uname -m)}"
PREFIX="$repo_root/Vendor/macos/$ARCH"
SRC="$PREFIX/src"
STAMPS="$PREFIX/.stamps"
JOBS="$(sysctl -n hw.ncpu)"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

mkdir -p "$PREFIX/lib" "$PREFIX/opt" "$SRC" "$STAMPS"

# Prerequisites checked by name up front: otherwise the first failure is a bare
# "command not found" tens of lines into an unrelated build.
for tool in curl shasum tar cmake clang vtool install_name_tool; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: '$tool' is not on PATH." >&2
    case "$tool" in
      cmake) echo "       Fix: brew install cmake" >&2 ;;
      clang|vtool|install_name_tool)
        echo "       Fix: xcode-select --install" >&2 ;;
      *) echo "       It ships with macOS; check your PATH." >&2 ;;
    esac
    exit 1
  }
done

case "$ARCH" in
  arm64)  OPENSSL_TARGET="darwin64-arm64-cc" ;;
  x86_64) OPENSSL_TARGET="darwin64-x86_64-cc" ;;
  *) echo "error: unsupported architecture '$ARCH'" >&2; exit 1 ;;
esac

# ---- helpers ---------------------------------------------------------------

# fetch <url> <sha256> <filename> — download once and verify. A mismatch deletes the
# file rather than leaving a poisoned cache for the next run to "resume" from.
fetch() {
  local url="$1" want="$2" file="$SRC/$3"
  if [ -f "$file" ]; then
    if echo "$want  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
      return 0
    fi
    echo "    cached $3 failed its checksum; re-downloading"
    rm -f "$file"
  fi
  echo "    downloading $url"
  curl -fsSL "$url" -o "$file"
  echo "$want  $file" | shasum -a 256 -c - >/dev/null || {
    rm -f "$file"
    echo "error: checksum mismatch for $3 — refusing to build it." >&2
    exit 1
  }
}

done_with() { [ -f "$STAMPS/$1" ]; }
mark_done() { touch "$STAMPS/$1"; }

# ---- OpenSSL ---------------------------------------------------------------
if done_with "openssl-$OPENSSL_VERSION"; then
  echo "==> OpenSSL $OPENSSL_VERSION already built"
else
  echo "==> OpenSSL $OPENSSL_VERSION"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz"
  rm -rf "$SRC/openssl-$OPENSSL_VERSION"
  tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$SRC"
  (
    cd "$SRC/openssl-$OPENSSL_VERSION"
    # no-tests skips a suite we don't run; -mmacosx-version-min is explicit because OpenSSL
    # doesn't always thread MACOSX_DEPLOYMENT_TARGET through to every compiler invocation.
    ./Configure "$OPENSSL_TARGET" shared no-tests \
      --prefix="$PREFIX/opt/openssl@3" \
      --openssldir="$PREFIX/opt/openssl@3/ssl" \
      "-mmacosx-version-min=$MIN_MACOS"
    make -j"$JOBS"
    # install_sw: libraries, headers and nothing else. `install` additionally
    # writes a man page tree we would only delete.
    make install_sw
  )
  mark_done "openssl-$OPENSSL_VERSION"
fi

# ---- libssh2 ---------------------------------------------------------------
if done_with "libssh2-$LIBSSH2_VERSION"; then
  echo "==> libssh2 $LIBSSH2_VERSION already built"
else
  echo "==> libssh2 $LIBSSH2_VERSION"
  fetch "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz" \
        "$LIBSSH2_SHA256" "libssh2-$LIBSSH2_VERSION.tar.gz"
  rm -rf "$SRC/libssh2-$LIBSSH2_VERSION"
  tar -xzf "$SRC/libssh2-$LIBSSH2_VERSION.tar.gz" -C "$SRC"
  cmake -S "$SRC/libssh2-$LIBSSH2_VERSION" -B "$SRC/libssh2-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/opt/libssh2" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$PREFIX/opt/openssl@3" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF
  cmake --build "$SRC/libssh2-build" -j"$JOBS"
  cmake --install "$SRC/libssh2-build"
  mark_done "libssh2-$LIBSSH2_VERSION"
fi

# Boost: libtorrent's CMake asks find_package for the `system` component even though it
# has been header-only since 1.69. Building the stub is quicker than fighting the module.
if done_with "boost-$BOOST_VERSION"; then
  echo "==> Boost $BOOST_VERSION already built"
else
  echo "==> Boost $BOOST_VERSION (headers + system)"
  boost_dir="boost-$BOOST_VERSION"
  fetch "https://github.com/boostorg/boost/releases/download/boost-$BOOST_VERSION/boost-$BOOST_VERSION-b2-nodocs.tar.xz" \
        "$BOOST_SHA256" "boost-$BOOST_VERSION.tar.xz"
  rm -rf "${SRC:?}/$boost_dir"
  tar -xJf "$SRC/boost-$BOOST_VERSION.tar.xz" -C "$SRC"
  (
    cd "$SRC/$boost_dir"
    ./bootstrap.sh --prefix="$PREFIX/opt/boost" --with-libraries=system
    ./b2 -j"$JOBS" install \
      --prefix="$PREFIX/opt/boost" \
      link=shared runtime-link=shared variant=release \
      cxxflags="-mmacosx-version-min=$MIN_MACOS" \
      linkflags="-mmacosx-version-min=$MIN_MACOS"
  )
  mark_done "boost-$BOOST_VERSION"
fi

# ---- libtorrent-rasterbar --------------------------------------------------
if done_with "libtorrent-$LIBTORRENT_VERSION"; then
  echo "==> libtorrent-rasterbar $LIBTORRENT_VERSION already built"
else
  echo "==> libtorrent-rasterbar $LIBTORRENT_VERSION (this is the long one)"
  fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" \
        "$LIBTORRENT_SHA256" "libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
  rm -rf "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION"
  tar -xzf "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" -C "$SRC"
  # The defines mirror what Package.swift passes when compiling TorrentBridge; a libtorrent
  # built with a different ABI switch than its caller is a run-time crash, not a link error.
  cmake -S "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION" -B "$SRC/libtorrent-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/opt/libtorrent-rasterbar" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_CXX_STANDARD=17 \
    -DBUILD_SHARED_LIBS=ON \
    -DBOOST_ROOT="$PREFIX/opt/boost" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DOPENSSL_ROOT_DIR="$PREFIX/opt/openssl@3" \
    -Dencryption=ON \
    -Dbuild_tests=OFF \
    -Dbuild_examples=OFF \
    -Dbuild_tools=OFF
  cmake --build "$SRC/libtorrent-build" -j"$JOBS"
  cmake --install "$SRC/libtorrent-build"
  mark_done "libtorrent-$LIBTORRENT_VERSION"
fi

# Package.swift links -L$PREFIX/lib and adds it as an rpath, mirroring Homebrew's layout.
# Symlinks, not copies, so install_name_tool sees exactly one file per library.
echo "==> Linking dylibs into $PREFIX/lib"
find "$PREFIX/lib" -maxdepth 1 -type l -delete
# `-type l` as well as `-type f`: a library installs both the real file and the versioned
# alias its SONAME names. Linking only real files builds fine but loads nothing.
while IFS= read -r dylib; do
  ln -sf "$dylib" "$PREFIX/lib/$(basename "$dylib")"
done < <(find "$PREFIX/opt" \( -type f -o -type l \) -name '*.dylib')

# The point of this script: a library whose minos exceeds the floor is the defect it
# exists to prevent, so check here rather than after a full app build.
echo "==> Verifying every dylib targets macOS $MIN_MACOS or older"
fail=0
count=0
while IFS= read -r dylib; do
  count=$((count + 1))
  minos="$(vtool -show-build "$dylib" 2>/dev/null | awk '/minos/ {print $2; exit}')"
  if [ -z "$minos" ]; then
    echo "    ?  $(basename "$dylib") — no LC_BUILD_VERSION could be read"
    fail=1
    continue
  fi
  # Sorts as versions: the lower of (minos, floor) must be minos itself.
  if [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | head -1)" != "$minos" ]; then
    echo "    ✗  $(basename "$dylib") — minos $minos exceeds $MIN_MACOS"
    fail=1
  else
    echo "    ✓  $(basename "$dylib") — minos $minos"
  fi
done < <(find "$PREFIX/opt" -type f -name '*.dylib')

[ "$count" -gt 0 ] || { echo "error: no dylibs were produced." >&2; exit 1; }
[ "$fail" = 0 ] || {
  echo "error: at least one vendored library targets a newer macOS than $MIN_MACOS." >&2
  exit 1
}

cat <<EOF

==> Done: $PREFIX  ($count dylibs, all at macOS $MIN_MACOS or older)

Build against it with:

    export GOEL_BREW_PREFIX="$PREFIX"
    swift build
    Scripts/build_app.sh

The sources under $SRC are kept so a re-run resumes; delete
Vendor/macos/$ARCH to start clean.
EOF
