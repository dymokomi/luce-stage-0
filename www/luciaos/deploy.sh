#!/bin/sh
# Publish luciaos.com.
#
# The landing page is one self-contained file — no build step, nothing
# to verify beyond its existence — so deploying is handing this
# directory to the shared publisher, minus the two files that are
# about the page rather than part of it.
#
#   ./www/luciaos/deploy.sh
#
# `LUCIAOS_HOME_ROOT` overrides where it lands; the host and the key
# are `www/deploy/publish.sh`'s, and shared with the other two sites.
set -e

here=$(cd "$(dirname "$0")" && pwd)

if [ ! -f "$here/index.html" ]; then
    echo "deploy: $here/index.html is missing" >&2
    exit 1
fi

exec "$here/../deploy/publish.sh" \
    "$here" \
    "${LUCIAOS_HOME_ROOT:-/opt/apps/luciaos_home}" \
    https://luciaos.com/ \
    --exclude deploy.sh --exclude README.md
