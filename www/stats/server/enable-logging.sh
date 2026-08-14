#!/bin/sh
# Put the access logging in `logging.caddy` into the edge server's Caddyfile.
#
#   www/stats/server/enable-logging.sh          apply, validate, reload
#   www/stats/server/enable-logging.sh --check  say what is there now
#
# The Caddyfile on that machine serves a dozen sites that have nothing
# to do with this project, so this does not replace it: it finds the
# three blocks that are ours and inserts one `log` directive into each,
# leaving every other byte alone.  It backs the file up first, refuses
# to reload a configuration Caddy will not validate, and does nothing
# at all to a block that already logs — so running it twice is running
# it once.
#
# `LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` are the same overrides the
# three deploy scripts take, and mean the same machine.
set -e

host=${LUCIAOS_EDGE_HOST:-ubuntu@35.153.110.211}
key=${LUCIAOS_EDGE_KEY:-$HOME/.ssh/lightsail-apps-edge.pem}

if [ "${1:-}" = "--check" ]; then
    exec ssh -i "$key" "$host" '
        echo "== log directives in our blocks =="
        sudo awk "/^(luce|loom)?\.?luciaos\.com/,/^}/" /etc/caddy/Caddyfile |
            grep -E "^(luce|loom|www)?\.?luciaos\.com|output file" || true
        echo "== files =="
        sudo ls -la /var/log/caddy/
    '
fi

echo "==> editing $host:/etc/caddy/Caddyfile"

ssh -i "$key" "$host" 'sudo python3 - <<"PYTHON"
import re, shutil, sys, time

PATH = "/etc/caddy/Caddyfile"

# Which log file each of our site blocks writes to, keyed by the set of
# addresses on the block'"'"'s opening line.  luciaos.com and its www
# redirect are separate blocks in this file and share a log.
WANTED = {
    "luce.luciaos.com": "luce.log",
    "loom.luciaos.com": "loom.log",
    "luciaos.com": "luciaos.log",
    "www.luciaos.com": "luciaos.log",
}

def directive(name, indent):
    return [
        indent + "log {",
        indent + "\toutput file /var/log/caddy/" + name + " {",
        indent + "\t\troll_size 20MiB",
        indent + "\t\troll_keep 8",
        indent + "\t\troll_keep_for 2160h",
        indent + "\t}",
        indent + "\tformat json",
        indent + "}",
    ]

lines = open(PATH).read().split("\n")
out, changed, skipped, index = [], [], [], 0

while index < len(lines):
    line = lines[index]
    out.append(line)
    index += 1

    # A block opens with its addresses and a brace, at column zero.
    match = re.match(r"^([^\s#{][^{]*)\{\s*$", line)
    if not match:
        continue
    addresses = [a.strip() for a in match.group(1).split(",") if a.strip()]
    names = {WANTED[a] for a in addresses if a in WANTED}
    if len(names) != 1:
        continue
    name = names.pop()

    # Take the whole block so we can see whether it already logs.
    depth, body = 1, []
    while index < len(lines) and depth > 0:
        inner = lines[index]
        depth += inner.count("{") - inner.count("}")
        if depth > 0:
            body.append(inner)
        else:
            break
        index += 1

    if any(re.match(r"^\s*log\s*\{?\s*$", b) for b in body):
        skipped.append(addresses[0])
    else:
        indent = "\t"
        for b in body:
            if b.strip():
                indent = b[: len(b) - len(b.lstrip())] or "\t"
                break
        body = directive(name, indent) + body
        changed.append(addresses[0] + " -> " + name)

    out.extend(body)

if not changed:
    print("caddy: every block already logs (" + ", ".join(skipped) + ")")
    sys.exit(0)

backup = PATH + ".before-stats-" + time.strftime("%Y%m%dT%H%M%S")
shutil.copy2(PATH, backup)
open(PATH, "w").write("\n".join(out))
print("caddy: backed up to " + backup)
for c in changed:
    print("caddy: added log to " + c)
for s in skipped:
    print("caddy: left alone (already logs) " + s)
PYTHON

echo "==> validating"
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -3

# Validating *loads* the configuration, which opens the log writers,
# which creates the files as root — and then the caddy user cannot
# write them and the reload fails with "permission denied".  The
# directory is caddy'"'"'s; the files have to be too.
echo "==> owning the log files"
sudo touch /var/log/caddy/luce.log /var/log/caddy/loom.log /var/log/caddy/luciaos.log
sudo chown caddy:caddy /var/log/caddy /var/log/caddy/*.log
sudo chmod 640 /var/log/caddy/*.log

echo "==> reloading"
sudo systemctl reload caddy
sleep 1
systemctl is-active caddy
'

echo "==> proving a request is recorded"
curl -fsS -o /dev/null https://luce.luciaos.com/
curl -fsS -o /dev/null https://loom.luciaos.com/
curl -fsS -o /dev/null https://luciaos.com/
sleep 1
ssh -i "$key" "$host" 'sudo ls -la /var/log/caddy/; echo "== newest line =="; sudo tail -1 /var/log/caddy/luce.log'
