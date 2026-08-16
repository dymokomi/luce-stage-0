# www/loom — loom.luciaos.com

The documentation for **loom**, the environment that runs compiled
Luce: what it is, how it starts a program, the shell, the editor, the
host boundary — and one page about where the tool is going.

It lives in this repository so that it changes with the tool.

## Why this is not `www/luce/`

`www/luce/` is luce.luciaos.com, and its generator is wired to the
language: every fenced Luce block on every page is compiled and run by
the freshly built toolchain, and the printed output is compared byte
for byte against what the program actually produced.  That machinery
is the right machinery for a language reference and the wrong
machinery for a page of shell transcripts about a binary.

So this is a separate tree with a separate build.  The two sites share
a visual identity — `assets/style.css` here is `www/luce/assets/style.css`
with the same custom properties, value for value — and cross-link in
both bars, but neither build can break the other.

## The contract

**Every page except `direction` describes the binary as it is built
from this repository.** Each content file says which implementation and
product tests its claims were checked against. Exact public language APIs stay
on luce.luciaos.com, whose generator verifies them; this site explains loom's
tool and host boundaries without keeping a second API roster.

`direction` is the one page that talks about things that are not built. It says
so in its first paragraph, marks every planned phase with an `ahead` label, and
derives the order from `docs/ROADMAP.md`.

**Nothing on this site is verified by the build.**  That is the
honest difference from `www/luce/`, and the line to watch: the moment
there are enough samples that a hand is the wrong instrument for
keeping them true, the checking belongs in `build.sh`, and
`www/luce/src/verify.zig` is how it is done.

## Build

```sh
./www/loom/build.sh
```

It writes `www/loom/out`, then walks every generated page and checks
that each internal `href` resolves to a file in the output tree **with
the anchor it names**.  A broken link fails the build.

There is no toolchain step: this site does not run Luce.

## Add a page

1. A row in `pages`: `SLUG`, nav label, title, description, separated
   by tabs.  Order in the file is the order of the tabs and the order
   the Previous/Next links walk.
2. A file at `content/SLUG.html` holding the body of the article —
   everything after the `<h1>`, which the build writes from the
   title.
3. An HTML comment at the top of that file saying how its claims were
   verified.

Nothing else lists the pages.

Inside a fragment, **`@/` means the site root** — write
`href="@/host/#keys"`.  A fragment does not know how deep the page it
becomes will sit, and `out/` has to open from a `file://` path as well
as from a domain root, so neither an absolute `/` nor a hand-counted
`../` would do.

## Layout

```text
www/loom/
  build.sh      manifest + fragments -> out/, then check the links
  deploy.sh     publish out/
  pages         the manifest: slug, nav label, title, description
  content/      one HTML fragment per page (the article body)
  assets/       style.css, site.js, mark.svg — copied verbatim
  out/          generated; not committed
```

The shell every page wears — the bar, the tab list, the
Previous/Next links, the footer — is written out longhand in
`build.sh`.  Six pages did not warrant a template language, and a
reader of `build.sh` can see the whole page from one place.

## Deploy

```sh
./www/loom/deploy.sh          # build, then publish
./www/loom/deploy.sh --fast   # publish what is already in out/
```

It builds (which is what checks the links), then hands `www/loom/out`
to `www/deploy/publish.sh`, which mirrors it to the static root and
curls the live URL afterwards.  `LOOM_SITE_ROOT` overrides the static
root; the host and the key are shared with the other sites and are
`LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY`.

**The default target is a single host** — the same instance
luciaos.com and luce.luciaos.com are served from, with Caddy serving
`/opt/apps/loom_docs` for `loom.luciaos.com` and taking the
certificate itself.  It is named in `www/deploy/publish.sh` and
nowhere else; see `www/README.md`.  There is no infrastructure-as-code
for it and no record of the Caddy configuration in this repository;
moving the site means editing that one line and knowing where the
certificate comes from.
