#!/usr/bin/env bash
# Build a snapshot-enabled SQLite for the Linux build of GoelDownloader.
#
# GRDB references `sqlite3_snapshot_*`, which Ubuntu's stock libsqlite3 declares
# in its header but omits from the shared object (it's built without
# SQLITE_ENABLE_SNAPSHOT). This compiles the SQLite amalgamation with that flag
# (plus the features GRDB expects) into Vendor/linux/sqlite/libsqlite3.so, which
# Package.swift links against on Linux (see GOEL_SQLITE_DIR).
#
# The amalgamation is PINNED, not scraped. This .so is linked into the shipped
# Linux daemon, so "whatever sqlite.org's download page links to today" is an
# unverified third party deciding what goes in the release. Bumping SQLite is a
# TWO-LINE edit — the version and its digest belong together:
#
#   curl -fsSL -o /tmp/amalg.zip https://sqlite.org/<year>/sqlite-amalgamation-<n>.zip
#   sha256sum /tmp/amalg.zip
#
# SQLITE_VERSION=latest re-enables the scrape, and still refuses to build
# without a SQLITE_SHA256 to check the result against.
#
# Usage:  Scripts/linux/build-sqlite.sh
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
        # -f so an HTTP error page is a failure rather than something grep reads.
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
