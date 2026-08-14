#!/bin/sh
# Fetch DB-IP's free country database and pack it for the collector.
#
#   ./www/stats/geo/refresh.sh          this month's, or last month's
#   ./www/stats/geo/refresh.sh 2026-07  a particular month
#
# DB-IP publish a new file at the start of each month under a URL that
# names it, and keep the old ones.  Early in a month the new one may
# not be there yet, so this asks for this month and falls back to last
# month rather than failing.
#
# The result is `work/countries.bin`, which `deploy.sh` sends to the
# server.  It is 17 MB and derived, so it is not in the repository;
# re-running this is how it is rebuilt.
#
# The data is CC-BY: <https://db-ip.com/db/download/ip-to-country-lite>.
# stats.luciaos.com carries the attribution in its footer, which is the
# whole of the licence's requirement — do not remove it.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
work=$root/work

collector=$work/luciastats
if [ ! -x "$collector" ]; then
    echo "geo: $collector is missing — run www/stats/build.sh first" >&2
    exit 1
fi

mkdir -p "$work"

fetch() {
    url="https://download.db-ip.com/free/dbip-country-lite-$1.csv.gz"
    echo "==> $url"
    curl -fsSL --max-time 300 "$url" -o "$work/dbip-$1.csv.gz"
}

if [ "$#" -ge 1 ]; then
    month=$1
    fetch "$month"
else
    month=$(date -u +%Y-%m)
    if ! fetch "$month" 2>/dev/null; then
        # A new month whose file is not published yet.
        month=$(date -u -v-1m +%Y-%m 2>/dev/null || date -u -d "last month" +%Y-%m)
        echo "geo: this month is not published yet, using $month"
        fetch "$month"
    fi
fi

gunzip -cf "$work/dbip-$month.csv.gz" > "$work/dbip.csv"
"$collector" geo --csv "$work/dbip.csv" --out "$work/countries.bin"
rm -f "$work/dbip.csv"

echo "geo: $work/countries.bin is $month"
