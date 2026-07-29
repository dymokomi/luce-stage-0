# The Zig engine

Decision: **Loom is written in Zig; LuciaOS is not required to be.**
Zig 0.16 is pinned (`build.zig.zon`).  C is the constitutional border:
the engine exports a stable C ABI (`abi/loom.h`), and platform shells
(Swift, Objective-C++, Metal-cpp, browser engines) live outside it in
whatever language the platform speaks best.  The `loom` terminal is
written in Zig and speaks the engine module directly; the ABI is for
shells that cannot.

Why Zig fits Loom: no hidden allocation or control flow, explicit
allocators, tagged unions over class hierarchies, errors as values,
freestanding-capable, and 0.16's `std.Io` — anything that may block is
passed an explicit I/O interface, which is LOOM.md's effect-boundary rule
expressed as a language feature.  `FileVolume` and `FileProjection` carry
their `Io`; the rest of the engine never touches the host.

## Layout

```text
build.sh               zig build --prefix build; the terminal lands at build/lucia
build.zig              the build graph; zig build test proves
build.zig.zon          pins Zig 0.16
loom/
  loom.zig             module root, re-exports every package
  abi.zig              implements the C ABI border
  storage/volume.zig   MemoryVolume, FileVolume, the Volume union
  fabric/              texel_id, value, texel, encode, store
  evaluation/          spool, fiber_index, state
  organization/        arrangement
  effects/             effect intents, boundary, receipts
  authority/           capability tokens and the grant table
  view/                view evaluators and the shell runtime
  projection/          manifest and file projection
  first_lucia_test.zig the acceptance proof from LOOM.md
abi/
  loom.h               the constitutional C border
  smoke_test.c         drives the client lifecycle from C
apps/lucia/             the lucia terminal
testdata/              golden image fixtures
```

Tests are `test` blocks beside the code they prove, run with
`zig build test` (any host OS — the engine is platform-free; the
terminal and projection reach the host only through explicit `std.Io`).

## The format contract

The port began beside a C++ reference implementation, and the **on-disk
image format was the frozen contract** between the two trees: descriptor
pages (`LUSTORE`), snapshot encoding (`LUTEXEL`), FNV-style checksums,
the four-word blob identifier, and the LUCAP/LUAUTH, LARR, and
LUEFINT/LUEFOBS content encodings, byte-identical in both.  The C++ tree
is retired (it lives in git history), but the contract survives it: the
golden fixture `testdata/golden_store.bin` was written by the C++ binary
and must always open unchanged, and neither the encodings nor the
checksums may drift.  Nothing ever persists raw struct layouts.

## Status

**The port is complete** — the engine, the view runtime, the file
projection, and the terminal are all Zig, tested and leak-checked:

- `storage/volume.zig` — MemoryVolume, FileVolume, the Volume union.
- `fabric/texel_id.zig`, `value.zig`, `texel.zig` — the model; Value is
  a tagged union; ports live in name-sorted tables.
- `fabric/encode.zig` — LUTEXEL snapshot encoding.
- `fabric/store.zig` — Store, Transaction, ChangeSet ring, volatile
  observe, blobs, LUSTORE descriptor pages.  The golden fixture opens
  here in a test.
- `evaluation/fiber_index.zig`, `evaluation/spool.zig` — the push/pull
  hybrid engine: reverse index, demand with early cutoff, advance,
  cached error outcomes, cycle detection.
- `evaluation/state.zig` — State/Delay creation and
  TemporalRuntime.advance; the counter test drives a real feedback loop
  through the Spool.
- `organization/arrangement.zig` — LARR content encoding,
  inspect/validate, and add/rename/reorder/remove.
- `authority/capability.zig` — Capability tokens, the Authority grant
  table (deterministic by sorted token), issue with entropy through the
  explicit Io.
- `effects/effect.zig` — effect intents and observations, the executor
  registry, and the once-only Boundary: verify the connected
  capability, run the executor, persist the receipt under the request
  identity, and replay from it forever after.
- `view/evaluators.zig`, `view/shell.zig` — prose and table interface
  renderers over name-sorted text inputs, and the trusted,
  non-persistent shell: surfaces, focus, compose, accessibility
  labels, and edits routed back as ordinary transactions.
- `projection/manifest.zig`, `projection/projection.zig` — the
  validated output-to-filename map and the controlled host boundary:
  export, tree verification (symlinks, extra hard links, and
  unexpected files refuse the operation), guarded import as one
  transaction.
- `first_lucia_test.zig` — the acceptance proof: material in two
  arrangements, computation, two Views, shell edits, an outside tool
  through the projection, restart.

**The C ABI exists**: `abi/loom.h` is the constitutional border,
implemented by `loom/abi.zig` and built as `libloom.a` (`zig build`
installs it under `zig-out/lib/`).  Version 0 covers identity, store
lifecycle and inspection, operation-style transactions, volatile
observation, the change feed, the fiber index, and demand through the
spool with client-supplied C evaluators (emit-callback style, so no
allocation crosses the border).  Effects, capabilities, arrangements,
and blobs surface in the header when a client needs them.
`abi/smoke_test.c` drives the whole client lifecycle from C and runs
under `zig build test`.

**The terminal is Zig** (`apps/lucia/`): it imports the engine module
directly, builds as the `lucia` executable — Loom is the engine, lucia is the executable, and its read-dispatch loop
is tested in-process with scripted sessions.

## Porting rules (kept for the next port)

- Port bottom-up along the dependency chain, tests first, one package a
  commit: storage → fabric model → encode → store → evaluation → the
  layers above.
- Zig std is consumed through a thin surface (allocators, ArrayList,
  Io.File); anything volatile gets a Lucia-owned wrapper before it
  spreads.
- Ownership is explicit: every heap-holding type has `clone` and
  `deinit`; tests run under `std.testing.allocator`, which fails on
  leaks.
- The scheduler and evaluation semantics belong to Loom, never to Zig
  async; `std.Io` implements boundaries, it does not define them.
- Style is `docs/CODING_GUIDE.md`: plain names, section comments, small
  files, one clear idea per file.
