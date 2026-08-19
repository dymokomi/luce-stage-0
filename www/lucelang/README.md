# lucelang — lucelang.org

The engineering atlas for Luce: how source moves through the compiler, how
each language feature is represented, what belongs to Zig and what is written
in Luce, how ARC and workers behave, and how LLVM output becomes a native
artifact.

This is deliberately separate from [luce.luciaos.com](https://luce.luciaos.com).
That site teaches the language and verifies its public samples. This site
explains the implementation. Every implementation link in this atlas is
checked against the repository, its MIR and host ABI numbers are read from the
committed source snapshot during the build, and every internal link and anchor
is validated. Checked feature traces live beside the site source. They
were generated from the small Luce programs in <code>examples/</code>: the Luce
IR printer wrote MIR, a temporary inspection build wrote the textual LLVM
module before general LLVM optimization, and <code>objdump</code> disassembled
the object emitted in the same run.

```sh
./www/lucelang/build.sh
./www/lucelang/deploy.sh
```

The normal site build does not compile Luce or write outside `www/lucelang`.
It copies the checked trace artifacts, then writes `www/lucelang/out`. The
deploy mirrors that directory to `/opt/apps/lucelang_org` through the shared
publisher. `LUCELANG_SITE_ROOT` overrides that path;
`LUCIAOS_EDGE_HOST` and `LUCIAOS_EDGE_KEY` are the same edge overrides used by
the other public sites.

Refreshing traces is intentionally separate. Build an inspection compiler in
a detached Git worktree, then point the maintenance script at that binary:

```sh
LUCELANG_COMPILER=/tmp/luce-traces/build/luce \
  ./www/lucelang/generate-traces.sh
```

The script refuses a compiler located in the shared working tree. Its
inspection build must expose textual LLVM output through `luce ir --llvm`;
that temporary hook is not part of the public CLI.

## Structure

```text
www/lucelang/
  pages             the hierarchy and page metadata
  content/          one HTML article fragment per page
  examples/         small checked programs used by the feature traces
  traces/           checked Luce, MIR, LLVM IR, and assembly artifacts
  assets/           the atlas layout, diagrams, and small interactions
  server/           Route 53 input and the Caddy block for this origin
  generate-traces.sh detached-worktree trace maintenance command
  build.sh          checked traces + fragments -> pages and integrity checks
  deploy.sh         build and publish
```

`@/` in a fragment means the site root. `@repo/` means the repository on
GitHub. A source link also carries `data-source="path"`; the build refuses it
when that path does not exist locally.

## One-time hosting setup

The domain is hosted in Route 53 and the existing LuciaOS Lightsail instance
serves the static tree with Caddy:

```sh
./www/lucelang/server/enable-dns.sh
./www/lucelang/server/enable-site.sh
```

The DNS script uses the AWS CLI and waits for Route 53 to publish the change.
The Caddy script backs up the existing shared Caddyfile, appends only the
checked-in `lucelang.org` block, validates it, and reloads Caddy.
