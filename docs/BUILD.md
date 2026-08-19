# The build system — bare `luce build`, `luce install`, and `std.build`

**Status: plan.** Ratified direction (owner, 2026-08-19): one build
system, no second engine — a `build.luc` is **compiled and run**, cached
like any program, never interpreted. This document records the design
and its phases; nothing here is current reference until it lands and
moves to [PACKAGES.md](PACKAGES.md) or the Guide.

The foundations this stands on are already real: the `luce.yaml`
manifest with an exact-version want list, the `.luce/packages/` store and
`LUCE_LIB` shelves, root-token import resolution, the source-hash compile
cache, `luce package` authoring, `std.files` (complete: stat facts, copy,
move, removals), `std.http`, `std.zip`, `std.json`, `os.Process`, and
`channel[T]` for a parallel runner later.

## Phase A — bare `luce build` (and the manifest entry point)

`luce build` with no file, run anywhere under a governing `luce.yaml`,
builds the project's entry program. The manifest gains one optional
top-level key:

```text
name: atlas
version: 0.3.0
main: src/atlas.luc     # what a bare `luce build` builds
```

- With `main:` present, bare `luce build [options]` is exactly
  `luce build <root>/src/atlas.luc [options]` — same flags, same
  defaults, the executable named after the source.
- Without `main:`, a bare build refuses and names the remedy: "add
  `main:` to luce.yaml or name a file". No convention scan — a build
  that guesses `main.luc` today will guess wrong the day two candidates
  exist, and the manifest is where resolution decisions live.
- `luce build FILE.luc` is unchanged forever: the file form is the
  primitive the bare form expands to.

Phase A is CLI + manifest work only: no new language surface, no ABI or
MIR movement.

## Phase B — `luce install`: filling the store

The want list learns where a package comes from. A row may carry a
`url:` beside its version, and a fetched row **must** carry `sha256:` —
an unverifiable download is refused, not warned about (Zig's
url-plus-hash rule; the hash is the trust protocol until a registry
exists):

```text
packages:
  geo: 1.2.0 url:https://pkg.example.com/geo-1.2.0.zip sha256:9f2a...
  ansi: 0.4.1 path:../ansi           # local rows never fetch
```

`luce install`:

1. reads the want list; every row already satisfied by the store (hash
   verified when present) is reported and skipped — install is
   idempotent, `make_directory`'s rule again;
2. fetches each `url:` row (https only) into a temporary directory,
   verifies the archive's content hash **before** unpacking anything
   into the store, then unpacks `<name>-<version>/` into
   `.luce/packages/` — write-then-rename, so a killed install never
   leaves half a package where the resolver probes;
3. verifies the unpacked directory's own `luce.yaml` agrees on name and
   version, exactly as the resolver would;
4. refuses a row with `url:` but no `sha256:`, naming the missing hash.

The fetch lives in the `luce` binary (Zig, `std.http.Client`): install
configures import resolution, so like the manifest parser it must not
depend on any Luce code having been built. The archive format is `.zip`
first (std.zip already speaks it for the Luce side; the host uses Zig's).
A registry — names without URLs, publishing, yanking, scopes — stays in
PACKAGES.md's "not yet built" list; `url:` rows are the lock-file-honest
subset that needs no server of ours.

## Phase C — `std.build`: the compiled build script

For projects that need more than "compile my entry file" — generated
sources, C/Zig objects, linking against system libraries — a project may
hold a `build.luc` beside its `luce.yaml`. The Zig model, deliberately:

- **The script is a program.** `luce build` compiles `build.luc` (through
  the ordinary compile cache, so an unchanged script costs one hash) and
  runs it. It is ordinary Luce: it can read files, branch on `os`
  facts, and fail with ordinary errors.
- **The script declares; the tool executes.** Running the script
  produces a *plan* — a graph of steps — which the `luce` binary then
  executes with its own scheduler. The script never spawns the compiler
  itself: separating declaration from execution is what makes the graph
  cacheable, parallelizable (workers + `channel[T]`), and honest in
  `--dry-run`.
- **`std.build` is the vocabulary** the script uses to build that plan:
  a `Build` class handed to the script's entry function; step
  constructors for compiling a Luce program (`b.program(...)`), a C
  or Zig object (`b.object(...)`), linking objects into an artifact the
  Luce program links against; dependency edges between steps; install
  targets. The plan crosses back to the tool as data (the runtime/host
  seam it crosses is a Phase C design decision to settle first —
  the candidates are a JSON plan on the script's stdout, or plan
  intrinsics — and the choice belongs with the effect-lock rules).
- With both `main:` and `build.luc` present, `build.luc` governs; the
  simple manifest key is the no-script fast path, not a second system.

C/C++/Zig compilation shells out to the host toolchain (`LUCE_CC`, the
driver the test suite already uses), each step's command and inputs
recorded in the plan so caching can key on them.

## Order and non-goals

A → B → C, each phase landing green with specs and docs before the next
starts. Non-goals throughout: a registry protocol, version ranges and a
solver, build-time network access from `build.luc` (the script reads the
tree it is in; `install` is the only fetcher), and any interpreter path
for build scripts — one engine, everywhere.
