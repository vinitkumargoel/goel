#!/usr/bin/env bash
# Build a snapshot-enabled SQLite for the Linux build of GoelDownloader.
#
# GRDB references `sqlite3_snapshot_*`, which Ubuntu's stock libsqlite3 declares
# in its header but omits from the shared object (it's built without
# SQLITE_ENABLE_SNAPSHOT). This compiles the SQLite amalgamation with that flag
# (plus the features GRDB expects) into Vendor/linux/sqlite/libsqlite3.so, which
# Package.swift links against on Linux (see GOEL_SQLITE_DIR).
#
# Usage:  Scripts/linux/build-sqlite.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
out_dir="$repo_root/Vendor/linux/sqlite"
mkdir -p "$out_dir"
cd "$out_dir"

if [ ! -f sqlite3.c ]; then
    url_path="$(curl -s https://sqlite.org/download.html | grep -oE '20[0-9][0-9]/sqlite-amalgamation-[0-9]+\.zip' | head -1)"
    [ -n "$url_path" ] || { echo "could not locate the SQLite amalgamation URL"; exit 1; }
    echo "downloading https://sqlite.org/$url_path"
    curl -sSL "https://sqlite.org/$url_path" -o amalg.zip
    unzip -o -j amalg.zip '*sqlite3.c' '*sqlite3.h' >/dev/null
    rm -f amalg.zip
fi

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
