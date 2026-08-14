#!/bin/sh
# Fetch the SQLite amalgamation the collector is built against.
#
#   ./www/stats/vendor-sqlite.sh      # fetch, check, unpack
#
# The collector keeps its history in SQLite, and it runs on a server
# that has libsqlite3 but no headers, no CLI and no compiler.  Rather
# than depend on what that machine happens to ship — the same drift
# `vendor-llvm.sh` exists to remove — the amalgamation is fetched from
# one pinned URL with one pinned hash and compiled into the binary, so
# what runs on the edge server is exactly what was tested here.
#
# Everything lands in www/stats/work/sqlite (gitignored): ~3 MB
# fetched, one .c and one .h unpacked.  `build.sh` calls this when the
# source is missing and never otherwise.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)

version=3530400
sha256=1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d
url="https://sqlite.org/2026/sqlite-amalgamation-$version.zip"

work="$here/work/sqlite"
archive="$work/sqlite-amalgamation-$version.zip"

if [ -f "$work/sqlite3.c" ] && [ -f "$work/sqlite3.h" ]; then
    echo "vendor-sqlite: already unpacked in $work"
    exit 0
fi

mkdir -p "$work"

if [ ! -f "$archive" ]; then
    echo "==> fetching sqlite $version"
    curl -fsSL "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
fi

echo "==> checking"
got=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$got" != "$sha256" ]; then
    echo "vendor-sqlite: hash mismatch for $archive" >&2
    echo "vendor-sqlite:   expected $sha256" >&2
    echo "vendor-sqlite:   got      $got" >&2
    echo "vendor-sqlite: refusing to unpack" >&2
    exit 1
fi

echo "==> unpacking"
rm -rf "$work/unpacked"
mkdir -p "$work/unpacked"
unzip -q "$archive" -d "$work/unpacked"
cp "$work/unpacked/sqlite-amalgamation-$version/sqlite3.c" "$work/sqlite3.c"
cp "$work/unpacked/sqlite-amalgamation-$version/sqlite3.h" "$work/sqlite3.h"
rm -rf "$work/unpacked"

echo "vendor-sqlite: $work/sqlite3.c ready"
