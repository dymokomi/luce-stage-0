#!/bin/sh
# Add the checked-in lucelang.org Caddy block to the shared edge host.
# DNS must be in place first so Caddy can obtain the certificate.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
host=${LUCIAOS_EDGE_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_EDGE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}

if [ "${1:-}" = "--check" ]; then
    exec ssh -i "$key" "$host" 'sudo grep -c "^lucelang.org" /etc/caddy/Caddyfile || echo "not present"'
fi

echo "==> checking DNS"
if ! host lucelang.org >/dev/null 2>&1 && ! nslookup lucelang.org >/dev/null 2>&1; then
    echo "enable-site: lucelang.org does not resolve to the edge yet" >&2
    exit 1
fi

scp -q -i "$key" "$here/site.caddy" "$host:/tmp/lucelang-site.caddy"
ssh -i "$key" "$host" 'set -e
    if grep -q "^lucelang.org" /etc/caddy/Caddyfile; then
        echo "caddy: lucelang.org is already configured"
        rm -f /tmp/lucelang-site.caddy
        exit 0
    fi
    backup=/etc/caddy/Caddyfile.before-lucelang-$(date -u +%Y%m%dT%H%M%S)
    sudo cp -p /etc/caddy/Caddyfile "$backup"
    echo "caddy: backed up to $backup"
    { printf "\n"; cat /tmp/lucelang-site.caddy; } | sudo tee -a /etc/caddy/Caddyfile >/dev/null
    rm -f /tmp/lucelang-site.caddy
    sudo mkdir -p /opt/apps/lucelang_org
    sudo chown ubuntu:ubuntu /opt/apps/lucelang_org
    sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
    sudo systemctl reload caddy
    systemctl is-active caddy
'

echo "==> waiting for TLS"
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://lucelang.org/ 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != 000 ]; then
        echo "enable-site: https://lucelang.org/ answers $code"
        exit 0
    fi
    sleep 5
done

echo "enable-site: Caddy is configured but TLS is not answering yet" >&2
exit 1
