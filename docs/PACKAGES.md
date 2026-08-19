# Packages: finding and loading code you did not write

A Luce project can depend on packages: named, versioned bundles of Luce
source resolved from a store on disk. The consuming and local-authoring paths
are complete: a project can resolve exact versions, use a direct source
folder, and create or version that folder with `luce package`. The networked
distribution half — a registry, trust model, fetch/update client, and actual
upload — is not built. `luce package publish` validates the local boundary and
then refuses rather than claiming it contacted a registry that does not exist.

## Two import namespaces

Imports live in two disjoint namespaces:

1. `import std.NAME` — the standard library, embedded in the compiler.
   `std.` is reserved: nothing shadows it and it shadows nothing, and a
   package named `std` is refused.
2. `import NAME` and `import NAME.SUB` — the host loader, resolving to a
   file in the project tree or inside a declared package.

A single directory of `.luc` files with no project file behaves exactly
as it always has: `import geo` finds a sibling `geo.luc`. Everything below
activates only when a project file is present.

## The project file: `luce.yaml`

A file named `luce.yaml` in the project root anchors resolution. It is
found by walking up from the *lexical* directory of the source file the
user named — never a resolved symlink target — to the filesystem root, the
way `go.mod` is found. There is no `$HOME` special case: a stop condition
that depends on the environment would resolve differently on different
machines. A program compiled from standard input, having no path, gets no
discovery and compiles rootless wherever it is piped from.

When a `luce.yaml` governs, *every* project-tree import is
project-root-relative: `import geo` means the same file whether it is
written in `src/main.luc` or `src/tools/x.luc`. Sibling-relative
resolution survives only for rootless programs.

The manifest is a strictly defined subset of YAML — scalars, one level of
nesting, string values, `#` comments; no anchors, aliases, flow style,
multiple documents, or type tags. A manifest that uses YAML the subset
refuses is refused by name, never half-read. The toolchain parses it in
Zig, because the manifest configures import resolution and so is read
before any Luce code could run.

```yaml
name: atlas
version: 0.3.0
main: src/atlas.luc                 # what a bare `luce build` builds

packages:
  geo: 1.2.0
  ansi: 0.4.1 sha256:9f2a...        # hash verified when present
  mathx: 1.1.0 path:../mathx        # development override
```

- `name` and `version` are the project's own identity — both required.
- `main` is optional: the project-root-relative source a bare
  `luce build` (no file named) compiles, run from anywhere under the
  root.  Without it the bare form refuses and names the key — no
  convention scan, because a build that guesses `main.luc` today
  guesses wrong the day two candidates exist ([BUILD.md](BUILD.md)
  phase A).  `luce build FILE.luc` is unchanged: the file form is the
  primitive the bare form expands to.
- `packages` is the *want list*. **A version is exact** — no ranges, no
  `^`/`~`. Upgrading a dependency is editing the number. A package not
  named here is unresolvable from any store, so a stray install cannot
  change what a program means.
- The optional `sha256:` hash is the SHA-256 content hash of the package
  directory — every regular file in sorted relative-path order, each
  contributing its path, a NUL, its length, and its bytes. It is verified
  when present; a mismatch is refused. With it, `luce.yaml` plus a
  populated store is reproducible; without it, the build is reproducible
  only as far as the store's bytes are.
- The optional `path:` entry is a development override: resolve this
  package from a directory instead of the store, and say so on every
  build. It keeps every resolution decision in the one file — an
  environment variable is not allowed to decide what a program means.

An `override:` section, in the same row shape, resolves a disagreeing
diamond by the consumer's stated decision (below). `path:` and `override:`
belong to the root manifest alone; a package's own manifest carrying
either is refused.

## Imports: dots map to directories

- `import geo` reads `geo.luc` under the project root, or the entry module
  of package `geo`.
- `import geo.shapes` reads `geo/shapes.luc` under the project root, or
  `shapes.luc` inside package `geo`. The binding is the last segment,
  `shapes` — matching `import std.math` binding `math`.
- `import geo.shapes as gs` binds the module under a chosen name. Two
  packages will independently contain a `util` or a `shapes`; aliasing is
  how a program uses both without forking one. (`as` is not available for
  `std.` imports, whose names are language surface.)

- `from geo import Point, area` loads the module the same way and binds
  the named public members bare, leaving the module namespace unbound;
  a per-member `as` renames one. Members work across a package boundary
  and key under the package's root identity exactly as the qualified
  spelling would.

Dots map to directories and nothing else — no index files, no implicit
re-export; a directory is not a module, only a file is. Every path segment
is matched case-exactly, per directory level. A module is one module
however it was spelled: a file reached as `geo.shapes` by a consumer and
as `shapes` from inside `geo` unifies to one type across the boundary.

## Resolution: probe everything, one answer or refuse

For each import under a `luce.yaml`, the loader probes **all** of:

1. the project's own tree — a root-relative file or directory;
2. the store, `<project>/.luce/packages/<name>-<version>/`, for a `name`
   in the want list at exactly the version stated (a `path:` override
   replaces this probe for that package);
3. every directory on `LUCE_LIB` (colon-separated; semicolon on Windows),
   same `name-version` layout, same want-list gate.

**Exactly one probe may answer.** Two answers — a project file versus a
declared package, two `LUCE_LIB` shelves, a shelf and a `path:` override —
is `luce.import.ambiguous`, naming every answering path. There is no
precedence and no first-hit: precedence would be silent shadowing behind a
lookup order. Probing every tier is a handful of directory stats per
import.

A package resolved from `LUCE_LIB` or through `path:` prints one line to
standard error on every build: those bytes are outside the project's
control, and a resolution the project file alone cannot predict is at
least made visible.

## What a package is on disk

A package is a directory whose name carries `name-version`, holding its
own `luce.yaml`:

```text
geo-1.2.0/
├── luce.yaml         # name: geo, version: 1.2.0
├── geo.luc           # the entry module: `import geo` reads this
└── shapes.luc        # `import geo.shapes` reads this
```

- The directory name and the inner `luce.yaml` must agree on both `name`
  and `version`, or the package is refused.
- A package's own internal imports resolve **inside the package first** —
  its files, then its own declared dependencies, with the same
  no-precedence rule (two answers is ambiguous). Two packages each
  carrying a private `util.luc` never collide, because each one's `import
  util` is answered inside its own root.
- **Source only.** A package ships `.luc` files; a package links into its
  consumer by source.
- **Flat, single-identifier names.** No scopes.
- **One version of a name in a whole build.** Major versions do not
  coexist. A package may name its own dependencies; the transitive set
  resolves at exact versions, and a diamond whose two requiring edges
  disagree is refused (`luce.import.diamond`, naming both edges). The
  remedy is in the consumer's hands: an `override:` row in the root
  `luce.yaml` resolves the named diamond by decision — no auto-pick, no
  highest-wins, and no fork-to-fix.
- **Every file is importable and every public declaration is consumer
  surface.** A package-level export boundary belongs to the publishing
  half, not here.

## The `.luce` directory

`<project>/.luce/` (gitignored by convention, created on demand) holds two
things:

```text
.luce/
├── packages/         # the store: one name-version directory each
└── cache/            # compile cache, keyed as artifacts already are
```

- **`packages/` is the store** the resolver probes. Today it is filled by
  hand — vendoring is just the store with no tooling — which is how the
  machinery stays testable before any fetch protocol exists.
- **`cache/` is the project compile cache.** Under a governing `luce.yaml`,
  loom keeps a program's artifact at the program's own relative spot,
  mirrored under the cache: `src/tools/x.luc` caches at
  `.luce/cache/src/tools/x.lc`, so one program has one artifact and a
  rebuild replaces it by name. The key is the source hash over the encoded
  module, which the front end rebuilds from *every* loaded source under
  its root-qualified names — so an edited package file misses the cache,
  and so does a `luce.yaml` edit that changes resolution. `luce build`
  itself is unchanged: `-o` and the beside-the-source default are the
  compiler's deliverable, not loom's cache.

## Authoring a package

A package under active authorship is ordinary source in a direct child
directory of the project — `geo/` beside `main.luc` — named by a root want
with a `path:geo` override. That directory is edited and committed with
the project and does not carry the `NAME-VERSION` store suffix; promotion
to `.luce/packages/NAME-VERSION/` is the installed boundary. Both forms
carry the package's `luce.yaml`, so a source-form package can be checked
against its own name/version identity before any registry exists.

Two local commands own this workflow:

- `luce package NAME() [VERSION]` creates the source folder, its
  `luce.yaml`, its entry module, and the root `path:` want (bootstrapping a
  root manifest if the tree is still rootless).
- `luce package version NAME VERSION` updates the package manifest and the
  root want together.
- `luce package publish NAME` validates the source boundary but refuses,
  because no registry or upload protocol exists — a refusal is preferable
  to reporting a publish that contacted no server.

## Diagnostics

Package resolution reports what was looked for, every place probed, and
what was found — verbatim paths, and the project root that governed the
probe. The `luce.import.*` family carries: `ambiguous` (every answering
path named), `version` (a store, `luce.yaml`, or manifest disagreement, or
a hash mismatch, all numbers named), `diamond` (both requiring edges
named, `override:` named as the remedy), `collision` (one binding meaning
two modules, the alias named as a remedy where the consumer can rename),
plus the existing `reserved`, `standard`, `self`, `missing`, `limit`, and
`unreadable`.

## The loader seam

The compiler never learns what a package is; all of it lives behind the
host loader, names in and bytes out. Four properties make that hold:

1. **Every loaded file carries an opaque root token** — for a package,
   `name-version` (`geo-1.2.0`), never a filesystem path, so the same
   program hashes identically across machines and across
   store/shelf/`path:` locations. The token is recorded per file and
   handed back on every load that file causes.
2. **The module registry keys `(root, name)`**, so package A's `util` is
   never answered to package B's `import util`; deduplication, cycle
   termination, self-import, and collision are all per-importing-root.
3. **A refusal travels as a stable code**, not free text: an ambiguous or
   version refusal arrives with structured content the diagnostics render.
4. **Serialized module names are qualified by root token** (a package
   module serializes as `geo-1.2.0/util.twice`), so two `util` modules
   from two packages cannot merge in a serialized module, and the source
   hash the cache keys on is stable across machines.

## Not yet built

- **Fetching** — no network, no registry, and no lockfile. Exact versions plus
  optional hashes are the lock until registry metadata justifies anything
  more. Future install/update commands belong in the `luce` binary and need a
  specified registry and trust protocol first; local project bootstrapping is
  already handled by `luce package new`.
- **Registry publishing** — mandatory hashes, signatures, yanking, scoped
  names, and a package-level export boundary.
- **Version ranges and a solver** — a solver needs registry metadata, so
  it waits on the registry.

Whatever those become, the resolver described here is what their files must
load.
