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

## Phase A — bare `luce build` (**landed**)

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

## Phase B — `luce install`: filling the store (**landed**)

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

`luce install` reads the want list and brings each row to its installed
state: a row already in the store is re-verified and reported, never
re-fetched (idempotent, `make_directory`'s rule again); a `url:` row is
fetched, unpacked into a staging directory beside its final name,
tree-hashed, checked against its own inner `luce.yaml` identity, and
only then renamed into `.luce/packages/NAME-VERSION/` — so a killed
install never leaves half a package where the resolver probes.

Three decisions this phase settled, each recorded in the code and
PACKAGES.md:

- **One hash, one meaning.** The `sha256:` on a `url:` row is the same
  tree hash the resolver already verifies, computed over the *unpacked*
  staging tree.  An archive hash would have been a second meaning for
  the same key.
- **`https` everywhere except loopback.** `http://127.0.0.1`,
  `localhost`, and `[::1]` are allowed, which is how the product test
  serves a real archive through the real client without owning a
  certificate authority.
- **The archive is a zip**, read by Zig's `std.zip` in the `luce`
  binary: install configures import resolution, so like the manifest
  parser it cannot depend on any Luce code having been built.

A registry — names without URLs, publishing, yanking, scopes — stays in
PACKAGES.md's "not yet built" list; `url:` rows are the lock-file-honest
subset that needs no server of ours.

## Phase C — `std.build`: the compiled build script (**landed, v1**)

For projects that need more than "compile my entry file" — generated
sources, C/Zig helpers, several artifacts — a project holds a
`build.luc` beside its `luce.yaml`. The Zig model, deliberately:

- **The script is a program.** A bare `luce build` compiles `build.luc`
  through the ordinary compile cache (the executable and its source-hash
  stamp live under `.luce/cache/`, so an unchanged script costs one
  hash), runs it in the project root, and reads what it prints.
- **The script declares; the tool executes.** The seam is **one JSON
  document on standard output**, versioned by its `plan` field.
  `std.build` is a *pure Luce* module — `Plan` collects steps,
  `Step.needs` connects them, `emit()` prints — so the compiler
  pipeline never learns what a build is: no ABI slot, no intrinsic, no
  MIR movement. The plan is inspectable by eye, by a spec, or by any
  other tool, which is what separating declaration from execution buys.
- **Two step kinds, each a whole world.** A `luce` step is one source
  compiled to one artifact by the tool itself (`exe`, `library`, or
  `object`, with `output` and `release`); a `command` step is one host
  command run in the project root, argv as given — no shell, no
  splitting — which is how a C compiler or a code generator joins the
  graph. Only the chosen step's dependency closure runs, in postorder;
  a cycle, a missing edge, or a failing step stops the plan and names
  itself.
- With both `main:` and `build.luc` present, `build.luc` governs; the
  manifest key is the no-script fast path, not a second system. A
  scripted build takes no options — the script decides everything.

Still ahead, in this order when a customer arrives: parallel step
execution (workers and `channel[T]` are ready for it), step-level
caching keyed on content (never on stamps), and linking foreign objects
into a Luce artifact — which waits on a C FFI design, because a linked
symbol nothing can call is dead weight.

## Order and non-goals

A → B → C each landed green with specs and docs before the next
started. Non-goals throughout: a registry protocol, version ranges and a
solver, build-time network access from `build.luc` (the script reads the
tree it is in; `install` is the only fetcher), and any interpreter path
for build scripts — one engine, everywhere.
