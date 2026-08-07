#!/bin/sh
# Publish luce.luciaos.com.
#
# Builds from clean first — deploying a tree nobody just verified is
# how a documentation site starts lying — then mirrors site/out to the
# static root Caddy serves.
#
#   ./site/deploy.sh          build, then publish
#   ./site/deploy.sh --fast   publish what is already in site/out
set -e

here=$(cd "$(dirname "$0")" && pwd)

host=${LUCE_SITE_HOST:-ubuntu@35.153.110.211}
key=${LUCE_SITE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}
target=${LUCE_SITE_ROOT:-/opt/apps/luce_docs}

if [ "$1" != "--fast" ]; then
    "$here/build.sh" "$@"
fi

if [ ! -f "$here/out/index.html" ]; then
    echo "deploy: $here/out is not a built site — run site/build.sh" >&2
    exit 1
fi

echo "==> publishing to $host:$target"
rsync -az --delete -e "ssh -i $key" "$here/out/" "$host:$target/"

echo "==> checking"
curl -fsS -o /dev/null -w 'https://luce.luciaos.com/ %{http_code}\n' https://luce.luciaos.com/
