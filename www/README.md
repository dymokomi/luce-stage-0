# www — the sites

Everything this project publishes to the web, one directory per site,
plus the one script that sends any of them.

| Directory | Site | Build | Deploy | Static root |
| --- | --- | --- | --- | --- |
| `luce/` | [luce.luciaos.com](https://luce.luciaos.com) — the language's documentation | `./www/luce/build.sh` | `./www/luce/deploy.sh` | `/opt/apps/luce_docs` |
| `lucelang/` | [lucelang.org](https://lucelang.org) — the language's engineering atlas | `./www/lucelang/build.sh` | `./www/lucelang/deploy.sh` | `/opt/apps/lucelang_org` |
| `loom/` | [loom.luciaos.com](https://loom.luciaos.com) — the tool's documentation | `./www/loom/build.sh` | `./www/loom/deploy.sh` | `/opt/apps/loom_docs` |
| `luciaos/` | [luciaos.com](https://luciaos.com) — the landing page | `./www/luciaos/build.sh` | `./www/luciaos/deploy.sh` | `/opt/apps/luciaos_home` |
| `stats/` | [stats.luciaos.com](https://stats.luciaos.com) — what the other four see | `./www/stats/build.sh` | `./www/stats/deploy.sh` | `/opt/apps/luciaos_stats` |

Each site has its own README saying what it is and what its build
guarantees.  `luce/` is the one wired to the language: every fenced
Luce sample on it is compiled and run by the freshly built toolchain
and its printed output compared byte for byte, so `www/luce/build.sh`
builds `build/luce` and `build/loom` first. `lucelang/` reads its format
and ABI versions from the Zig declarations, validates every source link,
and checks its generated hierarchy. `loom/` checks its links
and nothing else, deliberately, and says so. `luciaos/` is a small
hand-written HTML and CSS site whose build collects the shared stylesheet.
`stats/` is the odd one: a site **and the
program that fills it**, because its numbers exist only on the machine
that answers the requests — see its own README.

## Deploying

All five land on the same server, one host serving each static root
with Caddy, which takes the certificates itself. The established sites'
server configuration predates this tree; `lucelang/server/` checks in the
Route 53 change and Caddy block needed to add the new origin.

That shared half — the host, the key, the `rsync --delete` and the
`curl` that checks the live URL afterwards — is **`deploy/publish.sh`**,
written once instead of five times, so moving the server is one edit:

```sh
www/deploy/publish.sh DIRECTORY REMOTE-PATH URL [rsync-option...]
```

Each site's `deploy.sh` is a thin caller of it, and keeps only what it
cannot share: how the site is built, what counts as built (it refuses
to publish an unbuilt tree), where it lands, and the URL that proves
it arrived.  `LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` override the
server and the key for all five; `LUCE_SITE_ROOT`, `LUCELANG_SITE_ROOT`,
`LOOM_SITE_ROOT`, `LUCIAOS_HOME_ROOT`, and `LUCIAOS_STATS_ROOT` override one
site's static root each.

## Layout

```text
www/
  shared/
    core.css       palette, typography, prose, code, and common controls
  deploy/
    publish.sh    mirror a built directory to the edge server, then curl it
  luce/           luce.luciaos.com: generator (src/), content/, assets/
  lucelang/       lucelang.org: hierarchy, articles, diagrams, server setup
  loom/           loom.luciaos.com: pages manifest, content/, assets/
  luciaos/        luciaos.com: landing source and a small copy build
  stats/          stats.luciaos.com: collector (src/), site/, server/
```

Each origin serves its own copy of `shared/core.css`; pages never depend on a
different host for styling. A site's build copies it into that site's output
before deployment, then loads the site-specific layout stylesheet after it.
