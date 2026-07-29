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
