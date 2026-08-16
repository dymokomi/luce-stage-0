# stats — stats.luciaos.com

What the three published sites see, counted from the web server's own
access logs and drawn on one public page.

| | |
| --- | --- |
| Site | [stats.luciaos.com](https://stats.luciaos.com) |
| Build | `./www/stats/build.sh` |
| Deploy | `./www/stats/deploy.sh` |
| Static root | `/opt/apps/luciaos_stats` |
| Collector | `/usr/local/bin/luciastats`, every 15 minutes by systemd |
| Database | `/var/lib/luciaos-stats/stats.db` |

This directory is not like the other three under `www/`. Those are
sites; this is a site **and the program that fills it**, because the
numbers on it cannot be computed here — they only exist on the machine
that answers the requests.

## What it measures, and why from logs

Everything is counted from Caddy's access log. No script on any page
of any site reports anything, there is no cookie, and nothing is sent
to a third party. That is partly a privacy position and partly the
only thing that works: the install line is

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

and no browser-side analytics can see a `curl`. **Installs are the
most interesting number these sites produce, and the server log is the
only place they exist.**

Three judgements decide what the numbers mean, and all three are made
in `src/classify.zig` so they can be read rather than trusted:

- **`curl` is not a robot.** Crawlers, scanners and monitors are
  identified and excluded from people; command-line tools are people.
- **An asset is not a visit.** Only pages count as views, so a
  stylesheet does not double its page.
- **Reading the install line and installing are two numbers.**
  `install.sh` is fetched by everyone who runs the command;
  the archive is fetched only when the script decides to proceed.

## What is kept, and what is destroyed

The database holds **per-day counts and nothing else**. No addresses,
no user agents, no path tied to whoever asked for it.

Counting *people* needs to tell one visitor from two, so each request
contributes a hash of address and user agent, salted with a random
value generated for that day alone. When the day closes, its count is
written down and **the hashes and the salt are deleted** — the number
survives and the means of recomputing it does not. Addresses reach a
country lookup and are then dropped; the raw log is the only place one
is ever written, it never leaves the server, and it rolls away within
ninety days.

A person who reads two of the sites is two *site* visitors and one
*person*: the same hash is also filed under the pseudo-site `all`, and
the headline number reads that rather than summing the three, which
would count them twice.

## The pieces

```text
www/stats/
  src/                the collector (Zig, one static binary)
    main.zig          ingest | report | geo
    access.zig        a Caddy JSON log line -> a flat record
    classify.zig      which site, who asked, what they asked for
    ingest.zig        reading the logs once each, across rotation
    store.zig         SQLite: counts, cursors, the day's salted hashes
    report.zig        the JSON the page draws
    geo.zig           address -> country, from a file, offline
    day.zig           what UTC day a timestamp falls on
    sqlite.zig        the fifteen SQLite functions this uses
  site/               the page: hand-written HTML, dashboard CSS, one JS
  server/             what had to be added to the edge server, written
                      down: the log directives, the site block, the
                      systemd unit and timer, and the scripts that
                      install them
  geo/refresh.sh      fetch DB-IP's monthly database and pack it
  vendor-sqlite.sh    fetch the pinned SQLite amalgamation
```

The site build also copies `www/shared/core.css` into `out/assets/core.css`.
The dashboard stylesheet loads after it and deliberately owns the data-view
palette, chart typography, and layout.

The collector is one statically linked binary built against a pinned
SQLite amalgamation, so the server needs no library, no runtime and no
package: `deploy.sh` copies a file. It runs as its own user in
`caddy`'s group — the only reason it belongs to any group is that the
logs are `0640 caddy:caddy` — with no network access at all, which the
unit states rather than assumes.

## Reading the logs once

Caddy writes to `<site>.log` until it reaches 20 MiB, renames it to
`<site>-<timestamp>.log`, gzips it, and starts a new one. Two things
follow, and both are load-bearing:

- The live file is followed by **inode and offset**, not offset alone.
  After a roll the new file starts at zero, and a collector that
  resumed at the old offset would skip everything before it — a bug
  that looks like quiet days rather than like a bug.
- A rolled file is the file the cursor was already reading, under a new
  name. It is ingested from **the offset that cursor reached**, or its
  whole already-counted contents would be counted a second time.

Both are proved by tests in `ingest.zig` that roll a real file.

## Working on it

```sh
./www/stats/build.sh              # tests, both binaries, the site
./www/stats/deploy.sh             # publish, install, collect once
./www/stats/deploy.sh --geo       # ...and send a rebuilt country table
./www/stats/geo/refresh.sh        # rebuild the country table (monthly)
```

To try the collector against real data without touching the server,
copy the logs down and point it at them:

```sh
mkdir -p work/logs
ssh …@edge 'sudo cat /var/log/caddy/luce.log' > work/logs/luce.log
./www/stats/work/luciastats ingest \
    --logs www/stats/work/logs \
    --db www/stats/work/test.db \
    --geo www/stats/work/countries.bin \
    --out www/stats/out/data/stats.json
```

`report` rebuilds the JSON from an existing database without reading a
log, which is what to run after changing the report's shape.

**`data/` is excluded from the deploy mirror.** The collector owns it;
an `rsync --delete` that included it would delete the site's entire
history on every deploy.

The chart colours are not chosen by eye. Three sites need three hues a
reader can tell apart, including one who cannot see colour the usual
way, so each mode's three were checked for lightness, chroma, contrast
against their own background, and separation under protanopia,
deuteranopia and tritanopia. The margins are recorded at the top of
`site/assets/style.css`; re-run the check rather than nudging them.

## What it does not do yet

- **It does not count itself.** `stats.luciaos.com` logs, but the
  collector does not read that log — the page says it counts the three
  sites the project publishes, and counting itself would make that
  untrue. `server/site.caddy` says what changing that would take.
- **There is no backup off the box.** The counts are on one disk. They
  are also, in aggregate, exactly what the public JSON contains, so
  what is at risk is the history behind the current window rather than
  the numbers themselves.
- **It is only these three sites.** The `daily(day, site, kind, key,
  count)` table was shaped so that another producer is a new `site` and
  another measure is a new `kind`, not a migration — which is the road
  to this being the dashboard for more than a documentation site.

IP geolocation by [DB-IP](https://db-ip.com) (CC-BY): the attribution
in the page footer is the whole of that licence's requirement, so it
stays.
