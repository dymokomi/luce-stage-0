# luciaos — luciaos.com

The LuciaOS landing page: a hand-written `index.html` and site-only
`style.css`. `build.sh` copies those and `www/shared/core.css` into `out/`,
which `deploy.sh` publishes through `www/deploy/publish.sh`.

```sh
./www/luciaos/build.sh
./www/luciaos/deploy.sh
```

It mirrors `out/` to `/opt/apps/luciaos_home` on the edge server, then curls
the live URL. The shared stylesheet is always a fresh copy of its single
source; the ignored `core.css` beside this README is only an old build copy.
`LUCIAOS_HOME_ROOT` overrides the static root; `www/README.md` names
the rest.
