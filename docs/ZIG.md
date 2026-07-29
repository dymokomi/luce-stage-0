# The Zig port

Decision: **the Loom engine is written in Zig; LuciaOS is not required to
be.**  Zig 0.16 is pinned (`zig/build.zig.zon`).  C is the constitutional
border: the engine will export a stable C ABI (`abi/loom.h`, forthcoming),
and platform shells (Swift, Objective-C++, Metal-cpp, browser engines)
live outside it in whatever language the platform speaks best.

Why Zig fits Loom: no hidden allocation or control flow, explicit
allocators, tagged unions over class hierarchies, errors as values,
freestanding-capable, and 0.16's `std.Io` — anything that may block is
passed an explicit I/O interface, which is LOOM.md's effect-boundary rule
expressed as a language feature.  `FileVolume` carries its `Io`; the rest
of the engine never touches the host.

## Layout

```text
zig/
  build.zig            zig build test runs the engine suite
  src/
    loom.zig           module root, re-exports every package
    storage/volume.zig MemoryVolume, FileVolume, the Volume union
    fabric/            texel_id, value, texel, encode, store
    loom/              spool, fiber_index
  testdata/            golden image fixtures written by the C++ tree
```

Tests are `test` blocks beside the code they prove, run with
`zig build test` (any host OS — the engine is platform-free).

## The contract with the C++ tree

The C++ implementation under `src/` remains the reference during the
port.  The **on-disk image format is the frozen contract**: descriptor
pages (`LUSTORE`), snapshot encoding (`LUTEXEL`), FNV-style checksums,
and the four-word blob identifier are byte-identical in both
implementations, proven by a golden fixture in `zig/testdata/` that the
C++ binary wrote and the Zig store must open.  Neither implementation
ever persists raw struct layouts.

## Status

**The engine is fully ported** — every C++ package below the ABI border
now exists in Zig, tested and format-compatible (41 leak-checked tests,
`zig build test`):

- `storage/volume.zig` — MemoryVolume, FileVolume, the Volume union.
- `fabric/texel_id.zig`, `value.zig`, `texel.zig` — the model; Value is
  a tagged union; ports live in name-sorted tables.
- `fabric/encode.zig` — LUTEXEL snapshot encoding, byte-identical.
- `fabric/store.zig` — Store, Transaction, ChangeSet ring, volatile
  observe, blobs, LUSTORE descriptor pages.  The golden fixture
  (`testdata/golden_store.bin`, written by the C++ binary) opens in the
  Zig store; a Zig-written image was verified to open in the C++
  terminal.
- `loom/fiber_index.zig`, `loom/spool.zig` — the push/pull hybrid
  engine: reverse index, demand with early cutoff, advance, cached
  error outcomes, cycle detection.
- `loom/state.zig` — State/Delay creation and TemporalRuntime.advance;
  the counter test drives a real feedback loop through the Spool.
- `loom/arrangement.zig` — LARR content encoding, inspect/validate, and
  add/rename/reorder/remove.
- `realm/capability.zig` — Capability tokens, the Authority grant table
  (LUCAP/LUAUTH encodings, deterministic by sorted token), issue with
  entropy through the explicit Io.
- `loom/effect.zig` — effect intents and observations (LUEFINT/LUEFOBS
  encodings), the executor registry, and the once-only Boundary: verify
  the connected capability, run the executor, persist the receipt under
  the request identity, and replay from it forever after.

**The C ABI exists**: `zig/abi/loom.h` is the constitutional border,
implemented by `src/abi.zig` and built as `libloom.a` (`zig build`
installs it under `zig-out/lib/`).  Version 0 covers identity, store
lifecycle and inspection, operation-style transactions, volatile
observation, the change feed, the fiber index, and demand through the
spool with client-supplied C evaluators (emit-callback style, so no
allocation crosses the border).  Effects, capabilities, arrangements,
and blobs surface in the header when a client needs them.
`abi/smoke_test.c` drives the whole client lifecycle from C and runs
under `zig build test`.

**The terminal runs on the Zig engine.**  `apps/loom/` speaks only
`abi/loom.h` (through the thin RAII wrappers in `apps/loom/engine.h`)
and links `libloom.a`; CMake drives `zig build` automatically, so
building the app requires a Zig 0.16 toolchain on PATH.  Terminal
evaluators are C callbacks; declared outputs they do not emit fall back
to stored sources behind the border, which is how the name port rides
beside computed outputs.

The C++ engine under `src/` is now the **reference implementation**: it
builds and its tests keep running as the format's second opinion, but
the terminal no longer links it.  Still C++ and still above the border:
the view runtime and file projection, which migrate when Views reach
the terminal.

## Porting rules

- Port bottom-up along the dependency chain, tests first, one package a
  commit: storage → fabric model → encode → store → evaluation.
- Zig std is consumed through a thin surface (allocators, ArrayList,
  Io.File); anything volatile gets a Lucia-owned wrapper before it
  spreads.
- Ownership is explicit: every heap-holding type has `clone` and
  `deinit`; tests run under `std.testing.allocator`, which fails on
  leaks.
- The scheduler and evaluation semantics belong to Loom, never to Zig
  async; `std.Io` implements boundaries, it does not define them.
- Style carries over from `docs/CODING_GUIDE.md` in spirit: plain names,
  section comments, small files, one clear idea per file — expressed in
  Zig's own conventions (camelCase functions, TitleCase types).
