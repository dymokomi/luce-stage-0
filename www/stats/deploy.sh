#!/bin/sh
# Publish stats.luciaos.com, and the collector that fills it.
#
#   ./www/stats/deploy.sh          build, publish, install, collect
#   ./www/stats/deploy.sh --fast   publish what is already in out/
#   ./www/stats/deploy.sh --geo    also send a rebuilt country table
#
# This deploy has a second half the other three do not: the site is
# only the front of a pair, and the collector that writes its data
# lives on the server.  So it publishes the page, installs the binary
# and its timer, and then runs one collection — so a fresh deploy is
# never a page waiting fifteen minutes for its first numbers.
#
# **`data/` is excluded from the mirror.** It is the one directory the
# server owns rather than this tree: the collector writes `stats.json`
# into it every quarter hour, and an `rsync --delete` that did not
# exclude it would delete the site's entire reason for existing on
# every deploy, hourly numbers and all.
#
# `LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` are the same overrides the
# other three deploys take; `LUCIAOS_STATS_ROOT` moves the static root.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
work=$here/work
host=${LUCIAOS_EDGE_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_EDGE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}
root=${LUCIAOS_STATS_ROOT:-/opt/apps/luciaos_stats}

fast=0
geo=0
for argument in "$@"; do
    case "$argument" in
        --fast) fast=1 ;;
        --geo) geo=1 ;;
        *) echo "deploy: unknown option $argument" >&2; exit 2 ;;
    esac
done

if [ "$fast" -eq 0 ]; then
    "$here/build.sh"
fi

if [ ! -f "$here/out/index.html" ]; then
    echo "deploy: $here/out is not a built site — run www/stats/build.sh" >&2
    exit 1
fi
if [ ! -x "$work/luciastats-linux" ]; then
    echo "deploy: $work/luciastats-linux is missing — run www/stats/build.sh" >&2
    exit 1
fi

# ------------------------------------------------------------- the page

"$here/../deploy/publish.sh" \
    "$here/out" \
    "$root" \
    https://stats.luciaos.com/ \
    --exclude /data/

# --------------------------------------------------------- the machinery

echo "==> installing the collector on $host"

remote() {
    ssh -i "$key" "$host" "$@"
}

# The collector's own user, in caddy's group so it can read the logs.
remote 'set -e
    if ! id luciastats >/dev/null 2>&1; then
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin luciastats
        echo "created user luciastats"
    fi
    sudo usermod -a -G caddy luciastats
    sudo mkdir -p /var/lib/luciaos-stats
    sudo chown luciastats:luciastats /var/lib/luciaos-stats
    sudo chmod 750 /var/lib/luciaos-stats
'

scp -q -i "$key" "$work/luciastats-linux" "$host:/tmp/luciastats"
remote 'sudo install -m 755 -o root -g root /tmp/luciastats /usr/local/bin/luciastats && rm -f /tmp/luciastats'

# The country table is 17 MB and changes monthly, so it is sent when it
# is missing or when it is asked for, never on every deploy.
needs_geo=$geo
if [ "$needs_geo" -eq 0 ]; then
    if ! remote 'test -s /var/lib/luciaos-stats/countries.bin'; then
        needs_geo=1
    fi
fi

if [ "$needs_geo" -eq 1 ]; then
    if [ ! -s "$work/countries.bin" ]; then
        "$here/geo/refresh.sh"
    fi
    echo "==> sending the country table"
    scp -q -i "$key" "$work/countries.bin" "$host:/tmp/countries.bin"
    remote 'sudo install -m 644 -o luciastats -g luciastats /tmp/countries.bin \
        /var/lib/luciaos-stats/countries.bin && rm -f /tmp/countries.bin'
fi

scp -q -i "$key" "$here/server/luciaos-stats.service" "$here/server/luciaos-stats.timer" "$host:/tmp/"
remote 'set -e
    sudo install -m 644 /tmp/luciaos-stats.service /etc/systemd/system/
    sudo install -m 644 /tmp/luciaos-stats.timer /etc/systemd/system/
    rm -f /tmp/luciaos-stats.service /tmp/luciaos-stats.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now luciaos-stats.timer
'

# The collector writes into the site, so the directory has to be its
# own — everything else under the root belongs to the mirror above.
remote "set -e
    sudo mkdir -p $root/data
    sudo chown luciastats:luciastats $root/data
    sudo chmod 755 $root/data
"

echo "==> collecting once"
remote 'sudo systemctl start luciaos-stats.service && sudo systemctl status luciaos-stats.service --no-pager | tail -4'

echo "==> checking"
curl -fsS -o /dev/null -w "https://stats.luciaos.com/ %{http_code}\n" https://stats.luciaos.com/
curl -fsS -o /dev/null -w "https://stats.luciaos.com/data/stats.json %{http_code}\n" https://stats.luciaos.com/data/stats.json
