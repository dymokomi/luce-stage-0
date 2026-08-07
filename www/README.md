# www — the three sites

Everything this project publishes to the web, one directory per site,
plus the one script that sends any of them.

| Directory | Site | Build | Deploy | Static root |
| --- | --- | --- | --- | --- |
| `luce/` | [luce.luciaos.com](https://luce.luciaos.com) — the language's documentation | `./www/luce/build.sh` | `./www/luce/deploy.sh` | `/opt/apps/luce_docs` |
| `loom/` | [loom.luciaos.com](https://loom.luciaos.com) — the tool's documentation | `./www/loom/build.sh` | `./www/loom/deploy.sh` | `/opt/apps/loom_docs` |
| `luciaos/` | [luciaos.com](https://luciaos.com) — the landing page | none; the page is one file | `./www/luciaos/deploy.sh` | `/opt/apps/luciaos_home` |

Each site has its own README saying what it is and what its build
guarantees.  `luce/` is the one wired to the language: every fenced
Luce sample on it is compiled and run by the freshly built toolchain
and its printed output compared byte for byte, so `www/luce/build.sh`
builds `build/luce` and `build/loom` first.  `loom/` checks its links
and nothing else, deliberately, and says so.  `luciaos/` is a single
hand-written `index.html`.

## Deploying

All three land on the same server: a Lightsail instance serving each
static root with Caddy, which takes the certificates itself.  There is
no infrastructure-as-code for it and no record of the Caddy
configuration here.

That shared half — the host, the key, the `rsync --delete` and the
`curl` that checks the live URL afterwards — is **`deploy/publish.sh`**,
written once instead of three times, so moving the server is one edit:

```sh
www/deploy/publish.sh DIRECTORY REMOTE-PATH URL [rsync-option...]
```

Each site's `deploy.sh` is a thin caller of it, and keeps only what it
cannot share: how the site is built, what counts as built (it refuses
to publish an unbuilt tree), where it lands, and the URL that proves
it arrived.  `LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` override the
server and the key for all three; `LUCE_SITE_ROOT`, `LOOM_SITE_ROOT`
and `LUCIAOS_HOME_ROOT` override one site's static root each.

## Layout

```text
www/
  deploy/
    publish.sh    mirror a built directory to the edge server, then curl it
  luce/           luce.luciaos.com: generator (src/), content/, assets/
  loom/           loom.luciaos.com: pages manifest, content/, assets/
  luciaos/        luciaos.com: index.html
```
