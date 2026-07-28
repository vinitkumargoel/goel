#!/usr/bin/env bash
# Ubuntu's stock libsqlite3 omits the `sqlite3_snapshot_*` symbols GRDB needs, hence this build.
set -euo pipefail

SQLITE_YEAR="${SQLITE_YEAR:-2026}"
SQLITE_VERSION="${SQLITE_VERSION:-3530400}"
SQLITE_SHA256="${SQLITE_SHA256:-1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
out_dir="$repo_root/Vendor/linux/sqlite"
mkdir -p "$out_dir"
cd "$out_dir"

if [ ! -f sqlite3.c ]; then
    if [ "$SQLITE_VERSION" = "latest" ]; then
        # Keep curl -f: without it grep parses an HTTP error page instead of failing.
        url_path="$(curl -fsSL https://sqlite.org/download.html | grep -oE '20[0-9][0-9]/sqlite-amalgamation-[0-9]+\.zip' | head -1)"
        [ -n "$url_path" ] || { echo "could not locate the SQLite amalgamation URL"; exit 1; }
        if [ -z "${SQLITE_SHA256:-}" ]; then
            echo "SQLITE_VERSION=latest needs an explicit SQLITE_SHA256 — an unverified"
            echo "amalgamation must not be compiled into a shipped .so."
            exit 1
        fi
    else
        url_path="$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_VERSION.zip"
    fi
    echo "downloading https://sqlite.org/$url_path"
    curl -fsSL "https://sqlite.org/$url_path" -o amalg.zip
    echo "$SQLITE_SHA256  amalg.zip" | sha256sum -c - || {
        rm -f amalg.zip
        echo "SQLite amalgamation checksum mismatch — refusing to build it."
        exit 1
    }
    unzip -o -j amalg.zip '*sqlite3.c' '*sqlite3.h' >/dev/null
    rm -f amalg.zip
fi

command -v cc >/dev/null 2>&1 \
    || { echo "error: no C compiler on PATH. Fix: sudo apt install gcc" >&2; exit 1; }

echo "compiling snapshot-enabled libsqlite3.so"
cc -O2 -fPIC -shared \
    -DSQLITE_ENABLE_SNAPSHOT \
    -DSQLITE_ENABLE_FTS5 \
    -DSQLITE_ENABLE_JSON1 \
    -DSQLITE_ENABLE_RTREE \
    -DSQLITE_THREADSAFE=1 \
    sqlite3.c -o libsqlite3.so -lpthread -ldl -lm

echo "built $out_dir/libsqlite3.so"
nm -D libsqlite3.so | grep -q sqlite3_snapshot_get && echo "snapshot symbols present ✓"
