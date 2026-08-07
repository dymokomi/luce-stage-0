#!/bin/sh
# Publish luciaos.com.
#
# The landing page is one self-contained file — no build step, nothing to
# verify beyond its existence — so deploying is mirroring this directory
# to the static root Caddy serves.
#
#   ./www/deploy.sh
set -e

here=$(cd "$(dirname "$0")" && pwd)

host=${LUCIAOS_HOME_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_HOME_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}
target=${LUCIAOS_HOME_ROOT:-/opt/apps/luciaos_home}

if [ ! -f "$here/index.html" ]; then
    echo "deploy: $here/index.html is missing" >&2
    exit 1
fi

echo "==> publishing to $host:$target"
rsync -az --delete -e "ssh -i $key" \
    --exclude deploy.sh --exclude README.md \
    "$here/" "$host:$target/"

echo "==> checking"
curl -fsS -o /dev/null -w 'https://luciaos.com/ %{http_code}\n' https://luciaos.com/
