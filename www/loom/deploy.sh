#!/bin/sh
# Publish loom.luciaos.com.
#
# Builds first — deploying a tree nobody just built is how a
# documentation site starts lying, and the build is what checks the
# links — then hands `www/loom/out` to the shared publisher, which
# mirrors it to the static root Caddy serves.
#
#   ./www/loom/deploy.sh          build, then publish
#   ./www/loom/deploy.sh --fast   publish what is already in www/loom/out
#
# `LOOM_SITE_ROOT` overrides where it lands; the host and the key are
# `www/deploy/publish.sh`'s, and shared with the other sites.
set -e

here=$(cd "$(dirname "$0")" && pwd)

if [ "$1" != "--fast" ]; then
    "$here/build.sh"
fi

if [ ! -f "$here/out/index.html" ]; then
    echo "deploy: $here/out is not a built site — run www/loom/build.sh" >&2
    exit 1
fi

exec "$here/../deploy/publish.sh" \
    "$here/out" \
    "${LOOM_SITE_ROOT:-/opt/apps/loom_docs}" \
    https://loom.luciaos.com/
