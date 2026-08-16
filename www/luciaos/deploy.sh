#!/bin/sh
# Publish luciaos.com.
#
# The landing page build collects its HTML, site frame, and the shared
# core stylesheet into one tree before handing it to the publisher.
#
#   ./www/luciaos/deploy.sh          build, then publish
#   ./www/luciaos/deploy.sh --fast   publish the existing out/
#
# `LUCIAOS_HOME_ROOT` overrides where it lands; the host and the key
# are `www/deploy/publish.sh`'s, and shared with the other sites.
set -e

here=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--fast" ]; then
    "$here/build.sh"
fi

if [ ! -f "$here/out/index.html" ] || [ ! -f "$here/out/core.css" ] || [ ! -f "$here/out/style.css" ]; then
    echo "deploy: $here/out is not a built site — run www/luciaos/build.sh" >&2
    exit 1
fi

exec "$here/../deploy/publish.sh" \
    "$here/out" \
    "${LUCIAOS_HOME_ROOT:-/opt/apps/luciaos_home}" \
    https://luciaos.com/
