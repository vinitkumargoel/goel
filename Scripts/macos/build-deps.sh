#!/usr/bin/env bash
set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.6.2}"
OPENSSL_SHA256="${OPENSSL_SHA256:-aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f}"

LIBSSH2_VERSION="${LIBSSH2_VERSION:-1.11.1}"
LIBSSH2_SHA256="${LIBSSH2_SHA256:-d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7}"

BOOST_VERSION="${BOOST_VERSION:-1.90.0}"
BOOST_SHA256="${BOOST_SHA256:-9e6bee9ab529fb2b0733049692d57d10a72202af085e553539a05b4204211a6f}"

LIBTORRENT_VERSION="${LIBTORRENT_VERSION:-2.0.13}"
LIBTORRENT_SHA256="${LIBTORRENT_SHA256:-892cb75c06318e2420de0faf9f63a908069d3d237676e2459fd30abe0cb3b1bf}"

# Must agree with LSMinimumSystemVersion in build_app.sh and platforms: in Package.swift.
MIN_MACOS="${GOEL_MIN_MACOS:-14.0}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="${GOEL_ARCH:-$(uname -m)}"
PREFIX="$repo_root/Vendor/macos/$ARCH"
SRC="$PREFIX/src"
STAMPS="$PREFIX/.stamps"
JOBS="$(sysctl -n hw.ncpu)"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

mkdir -p "$PREFIX/lib" "$PREFIX/opt" "$SRC" "$STAMPS"

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

# A checksum mismatch must delete the file, or the poisoned cache is reused next run.
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
    # -mmacosx-version-min is explicit: OpenSSL does not thread MACOSX_DEPLOYMENT_TARGET everywhere.
    ./Configure "$OPENSSL_TARGET" shared no-tests \
      --prefix="$PREFIX/opt/openssl@3" \
      --openssldir="$PREFIX/opt/openssl@3/ssl" \
      "-mmacosx-version-min=$MIN_MACOS"
    make -j"$JOBS"
    make install_sw
  )
  mark_done "openssl-$OPENSSL_VERSION"
fi

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

if done_with "libtorrent-$LIBTORRENT_VERSION"; then
  echo "==> libtorrent-rasterbar $LIBTORRENT_VERSION already built"
else
  echo "==> libtorrent-rasterbar $LIBTORRENT_VERSION (this is the long one)"
  fetch "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" \
        "$LIBTORRENT_SHA256" "libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
  rm -rf "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION"
  tar -xzf "$SRC/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz" -C "$SRC"
  # Must match the defines Package.swift passes for TorrentBridge: an ABI mismatch crashes at run time.
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

# Symlinks, not copies, so install_name_tool sees exactly one file per library.
echo "==> Linking dylibs into $PREFIX/lib"
find "$PREFIX/lib" -maxdepth 1 -type l -delete
# `-type l` too: skipping the SONAME aliases still builds, but loads nothing at run time.
while IFS= read -r dylib; do
  ln -sf "$dylib" "$PREFIX/lib/$(basename "$dylib")"
done < <(find "$PREFIX/opt" \( -type f -o -type l \) -name '*.dylib')

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
