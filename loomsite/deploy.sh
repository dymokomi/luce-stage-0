#!/bin/sh
# Publish loom.luciaos.com.
#
# Builds first — deploying a tree nobody just built is how a
# documentation site starts lying, and the build is what checks the
# links — then mirrors loomsite/out to the static root Caddy serves.
#
#   ./loomsite/deploy.sh          build, then publish
#   ./loomsite/deploy.sh --fast   publish what is already in loomsite/out
set -e

here=$(cd "$(dirname "$0")" && pwd)

host=${LOOM_SITE_HOST:-ubuntu@35.153.110.211}
key=${LOOM_SITE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}
target=${LOOM_SITE_ROOT:-/opt/apps/loom_docs}

if [ "$1" != "--fast" ]; then
    "$here/build.sh"
fi

if [ ! -f "$here/out/index.html" ]; then
    echo "deploy: $here/out is not a built site — run loomsite/build.sh" >&2
    exit 1
fi

echo "==> publishing to $host:$target"
rsync -az --delete -e "ssh -i $key" "$here/out/" "$host:$target/"

echo "==> checking"
curl -fsS -o /dev/null -w 'https://loom.luciaos.com/ %{http_code}\n' https://loom.luciaos.com/
