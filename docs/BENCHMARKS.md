# Benchmarks — Luce against C, as a speed regression guard

```sh
./build.sh && bench/run.sh
```

Every `bench/NAME.luc` has a `bench/NAME.c` twin: the **same
algorithm**, printing the **same output**.  The harness refuses to
time anything whose outputs disagree, so the suite doubles as a
cross-language correctness check.  C compiles with
`zig cc -O3 -march=native` — full optimizer, auto-vectorization on —
plus `-ffp-contract=off`, because Luce's determinism guarantee is
strict IEEE with no fused multiply-add, and C must play by the same
float rules for the checksums to be comparable (they genuinely
diverge otherwise: FMA changes mandelbrot membership by a few
pixels).  Luce compiles `--release` and runs under `loom run`.  Both
timings include process startup; best of three.

## What each pair stresses

- **loops** — tight nested integer loops: multiply, remainder,
  compound accumulate.  Pure dispatch overhead.
- **math** — a mandelbrot membership count: float multiply/add and
  comparisons in a data-dependent inner loop.  No library calls on
  either side.
- **strings** — build ~200 KB with a Builder, then split, count,
  upper, replace.  On the Luce side all of that is `import strings`
  — pure Luce over `byte_at` and slices — so this measures the cost
  of the "std is written in Luce" bet.
- **arrays** — fill two 200k-element Float arrays, repeated dot
  product.  The workload a C compiler vectorizes (SIMD); the
  interpreter runs it scalar, and the ratio is the honest measure of
  that gap.

## The interpreter's own build mode matters most

The single biggest factor in these numbers is not Luce at all — it
is the optimize mode of the **interpreter binary**.  A Debug-mode
`zig build` interpreter is 4–5× slower than an optimized one, which
is why `./build.sh` now defaults to ReleaseSafe and passing
`-Doptimize=Debug` binaries to this harness is the one way to get
meaningless numbers.  Measured across modes (loops):

| interpreter build      | loops   | vs C |
|------------------------|---------|------|
| Debug (never bench)    | ~3.9s   | ~240x |
| ReleaseSafe (default)  | ~0.97s  | ~60x |
| ReleaseFast            | ~0.87s  | ~53x |

ReleaseSafe keeps Zig's own overflow/bounds checks inside the
interpreter — defense in depth behind the `.lc` trust boundary — at
~15% over ReleaseFast.  That is the ship default; ReleaseFast is
one flag away when it matters.

## Snapshot — 2026-07-31, with the native engine

x86_64 Linux container, zig cc (clang 21), loom at ReleaseSafe.
`native` is loom's default engine (docs/NATIVE.md — the vendored
MIR JIT compiling the verified IR at load); `interp` forces the
reference interpreter with LOOM_ENGINE=interpreter.  Both Luce
columns include process startup, .lc decode, and (native) the
~millisecond JIT compile:

| benchmark | C       | native   | interp  | native/C |
|-----------|---------|----------|---------|----------|
| loops     | ~11ms   | ~33ms    | ~810ms  | **~2.9x** |
| math      | ~12ms   | ~19ms    | ~920ms  | **~1.5x** |
| strings   | ~3.5ms  | ~66ms    | ~330ms  | **~19x** |
| arrays    | ~5ms    | ~31ms    | ~270ms  | **~5.5x** |

Since milestone 2 every benchmark runs native: collections,
ownership, and strings route through the service tiers
(docs/NATIVE.md), which puts the collection-bound benches 5-9x
ahead of the interpreter.  The remaining strings/arrays gap to C is
the per-element service call; the recorded next lever is unboxed
native storage for scalar arrays and strings.

For orientation: CPython 3.11 runs the loops algorithm in 1228ms
and mandelbrot in 1884ms on this machine — native Luce is ~25-80x
faster than CPython on these, and the interpreter alone already
edges it.  (CPython's mandelbrot count matches Luce's exactly —
both are strict IEEE.)

**Where we're at:** compiled Luce runs at **1.5–3x full-speed C**
on scalar workloads and **5–19x** on collection- and string-bound
ones, checks and ownership included.  The interpreter (40–95x)
remains the reference implementation, the oracle, and the fallback
for platforms the JIT doesn't cover.

## Why runtime checks are not the cost

It is tempting to blame the runtime checks and want them moved to
compile time.  Most already are: types, ownership classes, poisoning,
return paths, arity — all static.  What remains at runtime is what
*cannot* be static (bounds of a dynamic index, overflow of runtime
values — exactly the set Zig's ReleaseSafe keeps) plus the ownership
serial bookkeeping, and each of those is a predictable branch or a
store.  The measured ceiling for all checking combined is the
ReleaseSafe-vs-ReleaseFast gap: ~15%.

The real cost is **interpretation itself**.  A Luce `+` costs a trip
around the dispatch loop — instruction fetch, tagged-union switch,
register-array reads and writes, step-budget decrement — some 15–30
machine instructions where C spends one.  Deleting every check would
take ~60× to ~50×, not to 1×.  The path to C is not fewer checks;
it is not dispatching at all.

## The path from here

The compiled backend predicted by the first edition of this file
shipped as the native engine (docs/NATIVE.md) and landed where the
MIR experiment said it would.  What remains, in value order:

1. ~~Milestone 2 of the native core~~ — shipped: every benchmark
   and real program runs native.  Next lever, on demand: unboxed
   native storage for scalar arrays and strings (inline
   bounds-checked access instead of a service call per element).
2. **The self-written Zig backend** — grows unhurried behind the
   same seam, racing MIR under the same oracle and this table;
   sovereignty when it wins.
3. **SIMD / the last 2x** — MIR does not vectorize; `arrays` will
   plateau a few x above C until an LLVM-backed engine is ever
   judged worth its 200MB.  Whole-array std intrinsics (dot, fill)
   are the cheap VEX-style alternative when a real program wants
   them.

## The regression-guard workflow

Run `bench/run.sh` before and after any change to the interpreter,
analyzer lowering, or std internals.  **Ratios are the number to
watch** — absolute times move with the machine and this container is
noisy (±20% between runs is normal; best-of-three tames but does not
eliminate it).  A step change in a ratio (say 1.5× on one benchmark)
is a regression or a win to explain in the commit message.  Update
the snapshot table when the numbers move for a *reason*.

`zig build test` compiles every `bench/*.luc` (not timed), so the
benchmarks themselves cannot rot.

## Adding a pair

1. `bench/NAME.luc` and `bench/NAME.c` — same algorithm, same
   printed output; integer outputs only (float formatting differs
   between the languages; cast through `Int(...)`/`(long)`).
2. Add NAME to `names` in `bench/run.sh` and to `benches` in
   `build.zig`.
3. Size the Luce side to run 1–5 seconds: long enough to swamp
   startup, short enough to keep the suite pleasant.
