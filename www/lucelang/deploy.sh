#!/bin/sh
# Publish lucelang.org through the shared LuciaOS edge publisher.
#
#   ./www/lucelang/deploy.sh          build, check, then publish
#   ./www/lucelang/deploy.sh --fast   publish the existing out/
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--fast" ]; then
    "$here/build.sh"
fi

if [ ! -f "$here/out/index.html" ] || [ ! -f "$here/out/assets/core.css" ]; then
    echo "deploy: $here/out is not a built site — run www/lucelang/build.sh" >&2
    exit 1
fi

exec "$here/../deploy/publish.sh" \
    "$here/out" \
    "${LUCELANG_SITE_ROOT:-/opt/apps/lucelang_org}" \
    https://lucelang.org/

