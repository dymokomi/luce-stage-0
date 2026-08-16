#!/bin/sh
# Build stats.luciaos.com into www/stats/out, and the collector with it.
#
#   ./www/stats/build.sh          tests, both binaries, the site
#   ./www/stats/build.sh --fast   skip the tests
#
# Two things come out of here, because the site is half of a pair:
#
#   work/luciastats         the collector for this machine, so it can
#                           be run against a copy of the logs
#   work/luciastats-linux   the collector for the edge server, static
#                           against musl so the box needs nothing —
#                           no libsqlite3, no glibc version to match,
#                           no runtime at all
#   out/                    the site, ready for deploy.sh
#
# The page is hand-written rather than generated: there is no content
# to template, and the numbers arrive at runtime from `data/stats.json`,
# which the collector writes on the server.  So "building the site" is
# copying it — but an empty, valid report is written into it, so a
# freshly deployed site draws zeroes rather than an error while it
# waits for the first collection.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
out=$here/out
work=$here/work
fast=0
[ "${1:-}" = "--fast" ] && fast=1

sqlite_flags="-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0"

if [ ! -f "$work/sqlite/sqlite3.c" ]; then
    "$here/vendor-sqlite.sh"
fi

mkdir -p "$work"

if [ "$fast" -eq 0 ]; then
    echo "==> tests"
    zig fmt --check "$here/src"
    # shellcheck disable=SC2086
    zig test "$here/src/main.zig" "$work/sqlite/sqlite3.c" \
        -lc -I "$work/sqlite" \
        --global-cache-dir "$work/zig-cache" \
        -cflags $sqlite_flags --
fi

build() {
    echo "==> collector ($1)"
    # shellcheck disable=SC2086
    zig build-exe "$here/src/main.zig" "$work/sqlite/sqlite3.c" \
        -lc -I "$work/sqlite" \
        -O ReleaseSafe \
        --name luciastats \
        -femit-bin="$2" \
        --global-cache-dir "$work/zig-cache" \
        ${3:+-target $3} \
        -cflags $sqlite_flags --
}

build "this machine" "$work/luciastats"
build "edge server" "$work/luciastats-linux" x86_64-linux-musl

echo "==> site"
rm -rf "$out"
mkdir -p "$out"
cp -R "$here/site/." "$out/"
cp "$here/../shared/core.css" "$out/assets/core.css"
cmp "$here/../shared/core.css" "$out/assets/core.css"

# A valid report with nothing in it, so the page is never broken —
# the server's own collection replaces it within the hour.
"$work/luciastats" report --db "$work/empty.db" --out "$out/data/stats.json" --quiet
rm -f "$work/empty.db" "$work/empty.db-wal" "$work/empty.db-shm"

echo "==> built $out"
