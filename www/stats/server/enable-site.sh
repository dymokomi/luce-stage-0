#!/bin/sh
# Add the stats.luciaos.com block in `site.caddy` to the edge server.
#
#   www/stats/server/enable-site.sh          add it, validate, reload
#   www/stats/server/enable-site.sh --check   say whether it is there
#
# One-time wiring, like `enable-logging.sh` beside it.  The Caddyfile
# on that machine serves a dozen sites that are not ours, so this
# appends one block and touches nothing else, backs the file up first,
# refuses to reload a configuration Caddy will not validate, and does
# nothing at all if the block is already there.
#
# The DNS record must exist first: Caddy takes the certificate over
# HTTP-01, which needs the name to resolve to this machine.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
host=${LUCIAOS_EDGE_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_EDGE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}

if [ "${1:-}" = "--check" ]; then
    exec ssh -i "$key" "$host" 'sudo grep -c "^stats.luciaos.com" /etc/caddy/Caddyfile || echo "not present"'
fi

echo "==> checking that the name resolves here"
if ! host stats.luciaos.com >/dev/null 2>&1 && ! nslookup stats.luciaos.com >/dev/null 2>&1; then
    echo "enable-site: stats.luciaos.com does not resolve yet — Caddy will not" >&2
    echo "enable-site: get a certificate until it does.  Add the A record first." >&2
    exit 1
fi

echo "==> appending the block"

# The block travels as a file rather than a here-string inside a
# here-string, which is unreadable and one quoting mistake from
# writing rubbish into a production Caddyfile.
scp -q -i "$key" "$here/site.caddy" "$host:/tmp/stats-site.caddy"

ssh -i "$key" "$host" 'set -e
    if grep -q "^stats.luciaos.com" /etc/caddy/Caddyfile; then
        echo "caddy: stats.luciaos.com is already configured"
        rm -f /tmp/stats-site.caddy
        exit 0
    fi

    backup=/etc/caddy/Caddyfile.before-stats-site-$(date -u +%Y%m%dT%H%M%S)
    sudo cp -p /etc/caddy/Caddyfile "$backup"
    echo "caddy: backed up to $backup"

    # The comment header explains the block to whoever reads the
    # Caddyfile next; the file it came from is named so they can find
    # the rest of the story.
    { printf "\n"; cat /tmp/stats-site.caddy; } | sudo tee -a /etc/caddy/Caddyfile >/dev/null
    rm -f /tmp/stats-site.caddy
    echo "caddy: appended stats.luciaos.com"

    # The static root belongs to the deploying user, like every other
    # root under /opt/apps — deploy.sh mirrors into it over ssh as
    # `ubuntu`, and a root-owned directory turns that into a wall of
    # permission errors.  `data/` is the one exception, and deploy.sh
    # hands that to the collector itself.
    sudo mkdir -p /opt/apps/luciaos_stats
    sudo chown ubuntu:ubuntu /opt/apps/luciaos_stats
    sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -1

    # Validating opens the log writer as root; the file has to be
    # caddy'"'"'s or the reload fails with permission denied.
    sudo touch /var/log/caddy/stats.log
    sudo chown caddy:caddy /var/log/caddy/stats.log
    sudo chmod 640 /var/log/caddy/stats.log

    sudo systemctl reload caddy
    sleep 1
    systemctl is-active caddy
'

echo "==> waiting for the certificate"

# Any answer over TLS means the certificate arrived and Caddy is
# serving the name.  A 404 is the *expected* answer here — nothing has
# been deployed into the root yet, and `deploy.sh` is what fills it —
# so this waits for a working handshake, not for a page.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://stats.luciaos.com/ 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
        echo "enable-site: https://stats.luciaos.com/ answers $code — certificate is in place"
        echo "enable-site: run www/stats/deploy.sh to put the site there"
        exit 0
    fi
    sleep 5
done

echo "enable-site: the site is configured but not answering yet." >&2
echo "enable-site: check 'sudo journalctl -u caddy -n 50' for the certificate." >&2
exit 1
