#!/bin/sh
# Publish luce.luciaos.com.
#
# Builds from clean first — deploying a tree nobody just verified is
# how a documentation site starts lying — then hands `www/luce/out` to
# the shared publisher, which mirrors it to the static root Caddy
# serves.
#
#   ./www/luce/deploy.sh          build, then publish
#   ./www/luce/deploy.sh --fast   publish what is already in www/luce/out
#
# `LUCE_SITE_ROOT` overrides where it lands; the host and the key are
# `www/deploy/publish.sh`'s, and shared with the other sites.
set -e

here=$(cd "$(dirname "$0")" && pwd)

if [ "$1" != "--fast" ]; then
    "$here/build.sh" "$@"
fi

if [ ! -f "$here/out/index.html" ]; then
    echo "deploy: $here/out is not a built site — run www/luce/build.sh" >&2
    exit 1
fi

exec "$here/../deploy/publish.sh" \
    "$here/out" \
    "${LUCE_SITE_ROOT:-/opt/apps/luce_docs}" \
    https://luce.luciaos.com/
