# luciaos — luciaos.com

The LuciaOS landing page: a hand-written `index.html` and
`style.css`, published by `deploy.sh` through
`www/deploy/publish.sh`. There is nothing to build.

```sh
./www/luciaos/deploy.sh
```

It mirrors this directory — minus `deploy.sh` and this README — to
`/opt/apps/luciaos_home` on the edge server, then curls the live URL.
`LUCIAOS_HOME_ROOT` overrides the static root; `www/README.md` names
the rest.
