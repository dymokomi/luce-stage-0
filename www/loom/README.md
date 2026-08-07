# loomsite — loom.luciaos.com

The documentation for **loom**, the environment that runs compiled
Luce: what it is, how it starts a program, the shell, the editor, the
host boundary — and one page about where the tool is going.

It lives in this repository so that it changes with the tool.

## Why this is not `site/`

`site/` is luce.luciaos.com, and its generator is wired to the
language: every fenced Luce block on every page is compiled and run by
the freshly built toolchain, and the printed output is compared byte
for byte against what the program actually produced.  That machinery
is the right machinery for a language reference and the wrong
machinery for a page of shell transcripts about a binary.

So this is a separate tree with a separate build.  The two sites share
a visual identity — `assets/style.css` here is `site/assets/style.css`
with the same custom properties, value for value — and cross-link in
both bars, but neither build can break the other.

## The contract

**Every page except `direction` describes the binary as it is built
from this repository.**  Where a page shows a shell transcript, that
transcript was produced by running the command against a freshly built
toolchain and pasting what it printed; where it shows Luce source,
that source was checked with `build/luce check`.  Each content file
says so in an HTML comment at the top, naming what was verified and
how.

`direction` is the one page that talks about things that are not
built, it says so in its first paragraph, and every unbuilt thing on
it carries an `ahead` label.

**Nothing on this site is verified by the build.**  That is the
honest difference from `site/`, and the line to watch: the moment
there are enough samples that a hand is the wrong instrument for
keeping them true, the checking belongs in `build.sh`, and
`site/src/verify.zig` is how it is done.

## Build

```sh
./loomsite/build.sh
```

It writes `loomsite/out`, then walks every generated page and checks
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
loomsite/
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
./loomsite/deploy.sh          # build, then publish
./loomsite/deploy.sh --fast   # publish what is already in out/
```

It builds (which is what checks the links), mirrors `loomsite/out` to
the static root, and curls the live URL afterwards.
`LOOM_SITE_HOST`, `LOOM_SITE_KEY` and `LOOM_SITE_ROOT` override the
target.

**The default target is a single host** — the same EC2 instance
luciaos.com and luce.luciaos.com are served from, with Caddy serving
`/opt/apps/loom_docs` for `loom.luciaos.com` and taking the
certificate itself.  There is no infrastructure-as-code for it and no
record of the Caddy configuration in this repository; moving the site
means editing that one line and knowing where the certificate comes
from.  Written down here because it is the one thing about this site
that is not reproducible from the tree.
