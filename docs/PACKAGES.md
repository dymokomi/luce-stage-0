# Packages: using and loading (design)

**Status: PROPOSED — nothing below is built.**  This memo designs the
consuming half of packages — how a program *finds and loads* code it
did not write — and deliberately stops before authoring and
publishing.  The machinery for using packages has to be solid before a
registry, a manifest format for publishing, or a fetch protocol means
anything: every one of those produces files that this memo's resolver
has to load, so this memo comes first.  The durable direction was set
in conversation on 2026-08-10: subfolder-aware imports, a search path
for installed packages (`LUCE_LIB`), a `.luce/` directory inside the
project for the compile cache and downloaded packages, and versions
carried by packages from day one.  A first draft was adversarially
reviewed the same day; the review's two blockers (a self-contradictory
resolution rule, and isolation promised of a seam that could not
deliver it) and its should-fixes are incorporated below, each at the
decision it changed.

The prior art this leans on is named per decision, because every
mistake below has been made publicly by somebody: Python's `sys.path`
(order-dependent shadowing), Node's `node_modules` (resolution by
directory crawling), Go's modules (exact versions, minimal version
selection, walk-to-root discovery), Rust's Cargo (one lockfile,
`[patch]` overrides, packages immutable once downloaded), and Zig's
`build.zig.zon` (content hashes, no registry).

---

## Where imports stand today, and what holds

Two namespaces, disjoint (`01_source/load.zig`):

1. `import std.NAME` — the standard library, embedded in the compiler.
2. `import NAME` — the host's `Loader`: `NAME.luc` in the root file's
   directory, exact-case, regular files only.

What holds, unchanged, after this design:

- **The two-namespace rule.**  `std.` stays reserved and embedded;
  nothing shadows it and it shadows nothing.  A *package* named `std`
  is refused by name in the want list and in every store.
- **The `Loader` seam's contract**: names in, bytes out, everything
  about *how* is the host's.  The seam grows one dimension (D7) and
  keeps both obligations (exact-case at every segment, regular files).
- **`luce.import.collision`** — one binding meaning two modules is
  refused; package resolution adds new ways for that to happen, each
  named below, and D2 adds the remedy.

## D1. The project file: `luce.zon` marks the root and names the needs

Resolution needs an anchor better than "the directory of the file the
user typed" the moment subfolders exist.  A file named **`luce.zon`**
in the project root is that anchor.

- **Found by walking up** from the root source file's directory — the
  *lexical* directory of the path as typed, never a `realpath`, so a
  symlink shim resolves against the tree the author addressed — to the
  filesystem root, the way `go.mod` is found.  No `$HOME` special
  case: a stop condition that depends on an environment variable is a
  resolution that differs between machines.  The discovered root is
  printed in every resolution diagnostic (D6), so an accidental
  capture by a stray `luce.zon` is observable the moment it changes
  anything.
- **A pathless root gets no discovery.**  `luce build -` (stdin)
  anchors to the cwd only if a `luce.zon` is found by walking from the
  cwd; the in-memory loader loom uses for the embedded editor
  (`files.zig`'s `MemoryLoader`) does no discovery at all — `loom
  edit` inside somebody's project must not resolve the editor's own
  imports against that project's packages.
- **Absent is fine and means the current behaviour**: no project file,
  no subfolder imports, no packages — a single directory of `.luc`
  files stays exactly as cheap as it is today.
- **One anchor per mode.**  When a `luce.zon` governs, *every*
  project-tree import is project-root-relative — `import geo` from
  `src/tools/x.luc` and from `src/main.luc` mean the same file, which
  is the point of having a root.  Sibling-relative resolution survives
  only for rootless programs.  (First-draft blocker: two anchors in
  one mode reintroduced the disagreement the root exists to kill.)
- **Shape** (ZON — the notation the toolchain already speaks; one
  small parser, no new format dependency):

```zon
.{
    .name = "atlas",
    .version = "0.3.0",
    .packages = .{
        .geo = .{ .version = "1.2.0" },
        .ansi = .{ .version = "0.4.1", .hash = "..." },
        .mathx = .{ .version = "1.1.0", .path = "../mathx" },
    },
}
```

- `.name`/`.version` are the project's own identity — required.
- `.packages` is the *want list*: **a version is exact**.  No ranges,
  no `^`/`~`: ranges are a solver, a solver needs registry metadata,
  and both belong to the publishing half.  Upgrading is editing the
  number.
- `.hash` is optional and **verified when present** — the content hash
  of the package directory, computed the way `artifact.zig` already
  hashes (one algorithm, stated in the manifest value's prefix).
  Hand-vendoring stays cheap without it; with it, `luce.zon` + a
  populated store *is* reproducible.  Without it the build is
  reproducible only as far as the store's bytes are — said plainly
  here because the first draft claimed more than it checked.  The
  publishing half will make hashes mandatory for fetched packages;
  the field exists from day one so it never has to be retrofitted.
- `.path` is the development override, Cargo's `[patch]` / Go's
  `replace` in Luce shape: resolve this package from a directory
  instead of the store, loudly (D6).  It keeps every resolution
  decision in the one file — an environment variable is not allowed
  to decide what a program means (D3).

## D2. Subfolder imports: `import geo.shapes` maps dots to directories

- `import geo` — under a `luce.zon`: `geo.luc` under the project root,
  or the entry module of package `geo` (D4).  Rootless: a sibling
  `geo.luc`, as today.
- `import geo.shapes` — `geo/shapes.luc` under the project root, or
  `shapes.luc` inside package `geo`.  The binding is the last segment
  (`shapes`), matching `import std.math` binding `math`.
- **`import geo.shapes as gs`** binds the module under a chosen name.
  This ships in the same step as subfolder imports, not later: two
  packages will independently contain `shapes`, `util`, `json` in
  week one, last-segment collisions are certain, and without aliasing
  the only remedy is forking a package — a fork the D4 agreement
  check deliberately makes painful.  One grammar rule, the binding
  machinery unchanged, and `luce.import.collision`'s message gains
  the alias as its named remedy.  (First-draft deferral, reversed by
  review: an escape hatch the design's own collision rule needs may
  not be deferred.)
- **Dots map to directories and nothing else** — no `__init__`
  protocol, no index files, no implicit re-export.  A directory is
  not a module; only files are.
- Case-exact at **every** segment — the directory scan `files.zig`
  does per file happens per directory level, with listings cached per
  compile (Python's `_fill_cache`, cited there, does exactly this).

## D3. Resolution: probe everything, one answer or refuse

For each import under a `luce.zon`, the loader probes **all** of:

1. the project's own tree (root-relative file or directory),
2. the store: `<project>/.luce/packages/<name>-<version>/` for a
   `name` in the want list, at exactly the version the want list
   states (a `.path` override replaces this probe for that package),
3. every directory in `LUCE_LIB` (colon-separated; semicolon on
   Windows), same `name-version` layout, same want-list gate.

**Exactly one probe may answer.**  Two answers — project file vs.
declared package, two `LUCE_LIB` shelves, anything — is
`luce.import.ambiguous`, with every answering path named.  There is
no precedence and no first-hit: precedence is silent shadowing with a
table, `sys.path`'s mistake, and the first draft contradicted itself
here by claiming both an order and an ambiguity rule.  Probing every
tier is a handful of directory stats per import, cached per compile.

A package resolved from `LUCE_LIB` or through `.path` says so, one
line to standard error, every build: those bytes are outside the
project's control, and a resolution the project file alone cannot
predict must at least be visible.  The want list stays the gate
everywhere: a package not named in `luce.zon` is unresolvable from
any store or shelf, so a stray install cannot change what a program
means — and neither can a stray file, because a stray file that
collides with a declared package is refused, not preferred.

## D4. What a package is on disk: a directory with its own `luce.zon`

```text
geo-1.2.0/
├── luce.zon          # .name = "geo", .version = "1.2.0"
├── geo.luc           # the entry module: `import geo` reads this
└── shapes.luc        # `import geo.shapes` reads this
```

- **The directory name carries `name-version`**, and the `luce.zon`
  inside must agree with both halves, or the package is refused by
  name — the artifact tag's tell-the-truth-or-be-refused rule.
- A package's own internal imports resolve **inside the package
  first** (its files, then its own dependencies), never in the
  consumer's project: two packages each carrying a private `util.luc`
  never collide, because each one's `import util` is answered inside
  its own root.  What this costs the seam is stated honestly in D7 —
  the first draft claimed it "falls out of the loader"; it does not.
- **Visibility, v1**: every file in a package is importable and every
  public declaration in it is consumer surface.  Said out loud
  because the publishing half inherits it: semver over "the entire
  file tree" is fiction, so a package-level export boundary
  (entry-file-only, or a module-level `private`) is a *named
  deferral* to the publishing memo, not an oversight.
- A package's `luce.zon` may name its own `.packages`.  **v1 resolves
  the transitive set with exact versions and refuses diamonds that
  disagree** — with the remedy in the *consumer's* hands: an
  `.override = .{ .mathx = .{ .version = "1.1.0" } }` entry in the
  root `luce.zon` resolves a named diamond by stated decision, loudly
  (D6).  No auto-pick, no highest-wins — but no fork-to-fix either,
  because the person hitting the refusal owns neither manifest.
  (First-draft gap: refusal with no consumer remedy breaks the first
  time two packages share a lagging dependency.)
- **Major versions do not coexist.**  One `name`, one version in the
  whole build — the diamond rule with no exception.  Go's `/v2`
  import-path answer is deliberately not taken and the road back is
  open (a future major could rename); this is a decision, recorded,
  not an omission.
- **Source only.**  A package ships `.luc` files; compiled `.lc`
  artifacts stay programs.  Compiled library artifacts join the
  shared-`libluce_rt` question (MISSING.md), not this memo.
- **Flat single-identifier names, v1.**  No scopes (`@user/geo`).
  The registry half inherits the squatting and coordination questions
  flat names carry; scoped names would change import spelling, so if
  scoping is ever wanted, it is wanted *before* a public registry —
  recorded here so the publishing memo starts from the question.

## D5. `.luce/`: the project's own dot-directory

`<project>/.luce/` (gitignored by convention, created on demand):

```text
.luce/
├── packages/         # the store: one name-version directory each
└── cache/            # compile cache, keyed as artifacts already are
```

- **`packages/` is the store** D3 probes.  In this memo it is filled
  by hand — `cp -r` a checkout, a git submodule; vendoring is just
  the store with no tooling — which is how the machinery stays
  testable before any fetch protocol exists.
- **`cache/` takes over the compile cache** for projects.  The keying
  already works unchanged: `artifact.sourceHash` hashes the encoded
  module, which the front end rebuilds from *all* loaded sources —
  so a changed package file, or a `luce.zon` edit that changes
  resolution, changes the key.  Beside-the-source caching survives
  for rootless programs, and loom's distinct-name-per-writer
  discipline (`runner.zig`) carries over to the shared directory.
- One consequence named now: `bench/compare.sh` checks out an old ref
  whose gitignored store is empty — the moment a benchmark imports a
  package, the authoritative A/B breaks.  Benchmarks therefore import
  nothing outside the project tree, stated in `bench/`'s README the
  day step 3 lands.

## D6. Diagnostics name the resolution, not the mechanism

Every refusal says what was looked for, every place probed, and what
was found — verbatim paths, and the project root that governed the
probe.  `luce.import.*` gains: `ambiguous` (every answering path
named), `version` (store/`luce.zon`/manifest disagreement, all
numbers named), `diamond` (both requiring edges named, `.override`
named as the remedy).  The collision family stays, its message
growing the alias remedy (D2) and a package-aware variant (a package
file cannot be renamed by the consumer).  The first draft's
`luce.import.outside` is dropped: import segments are identifiers, so
nothing can spell a path that escapes the root, and a code nothing
can fire is a lie in the taxonomy.

## D7. What the seam pays: four changes, named

The review's second blocker, adopted as the implementation contract:

1. **The `Loader` signature grows a root token.**  `Found.text`
   gains an opaque, host-chosen root identifier; stage 1 records it
   per `FileId` and hands it back on every `load` that file causes:
   `load(context, arena, name, from_root)`.  The compiler never
   learns what a root *is*; names-in-bytes-out holds.
2. **The module registry keys `(root, name)`, not `name`.**  Today
   `sources.find(name)` is program-global, which under D4 would
   answer package A's `util` to package B's import — silent
   cross-package aliasing.  Dedup, cycle termination, self-import,
   and `luce.import.collision` all move to the pair key; collision
   becomes per-importing-namespace.
3. **`Found` gains `.ambiguous`**, carrying every answering path, so
   D3's refusal arrives as a stable code with structured content
   rather than free text through `.unreadable`.
4. **The serialized module qualifies internal names by root**, so two
   `util` modules from two packages cannot merge in a `.lcm`.  This
   is a `format_version` bump, taken in step 3 below.

## Deliberately absent from this memo

- **Fetching** — no network, no registry, no lockfile (exact versions
  plus optional hashes in `luce.zon` are the lock until transitive
  ranges exist).
- **Authoring/publishing** — manifests beyond the fields above,
  mandatory hashes, signatures, yanking, scoped names, the package
  export boundary: each named above at the decision that defers it.
- **Version ranges and a solver** — after a registry with metadata
  exists, if the exact-version corpus demands them.

## Implementation order (each step lands green on its own)

1. `luce.zon` discovery + parse; the D7 seam changes land **first and
   alone** — root tokens threaded, registry re-keyed, `.ambiguous`
   added — with today's behaviour proven unchanged for rootless
   programs (the whole existing suite is that proof) plus new
   `files.zig` tests for discovery edges (symlinked root, stdin, no
   project file).
2. Subfolder imports + `import ... as` (D2) inside the project tree,
   with the collision/ambiguity diagnostics and site/docs pages.
3. The store, `LUCE_LIB`, `.path` and `.hash` (D3/D4): hand-vendored
   packages resolve end to end, package-internal isolation proven by
   two packages shipping same-named files, diamond + `.override`,
   the format_version bump for root-qualified names.
4. `.luce/cache/` (D5) for project builds; loom keeps beside-source
   caching for rootless files.
5. Specs throughout: `modules_spec.zig` grows a packages section;
   `product.zig` drives a vendored package the way a person would.
