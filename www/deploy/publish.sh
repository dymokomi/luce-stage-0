#!/bin/sh
# Mirror a built directory to the edge server, then check the live URL.
#
#   www/deploy/publish.sh DIRECTORY REMOTE-PATH URL [rsync-option...]
#
# All three sites in this tree — luce.luciaos.com, loom.luciaos.com and
# luciaos.com — are one host, one key and one rsync away from being
# published.  That was written out three times; it is written here
# once, so moving the server is one edit rather than three, and the
# address of the machine appears in exactly one file.
#
# What each site keeps for itself is what it cannot share: how it is
# built, what counts as built, where it lands and what URL proves it.
# This script only knows how to send a directory that already exists.
#
# `LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` override the server and
# the key it is reached with.  The remote path is an argument rather
# than an environment variable, because it is the caller's business:
# each site's deploy.sh names its own root and its own override.
#
# **The default target is a single host** — a Lightsail instance
# serving each static root with Caddy, which takes the certificates
# itself.  There is no infrastructure-as-code for it, no second host
# and no record of the Caddy configuration in this repository; moving
# a site means editing the line below and knowing where the
# certificate comes from.  Written down because it is the one thing
# about these sites that is not reproducible from the tree.
set -e

if [ "$#" -lt 3 ]; then
    echo "publish: usage: publish.sh DIRECTORY REMOTE-PATH URL [rsync-option...]" >&2
    exit 2
fi

directory=$1
target=$2
url=$3
shift 3

host=${LUCIAOS_EDGE_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_EDGE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}

if [ ! -d "$directory" ]; then
    echo "publish: $directory is not a directory" >&2
    exit 1
fi

echo "==> publishing to $host:$target"
rsync -az --delete -e "ssh -i $key" "$@" "$directory/" "$host:$target/"

echo "==> checking"
curl -fsS -o /dev/null -w "$url %{http_code}\n" "$url"
