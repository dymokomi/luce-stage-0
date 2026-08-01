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

## Measurement discipline: the machine is not stable

This project benchmarks inside shared containers whose hosts change
between sessions — and once changed *under* a session mid-day,
moving every number including the C column.  Two rules follow, and
the harness enforces both:

1. **Never compare absolute times across tables.**  Every table is
   stamped with the host it ran on; a snapshot from another machine
   or another day is an illustration, not a baseline.
2. **The authoritative regression check is a same-host A/B**:
   `bench/compare.sh GIT-REF` builds the base ref in a scratch
   worktree and the working tree side by side, compiles each side's
   benches with its own toolchain, and times both interleaved
   round-robin on the current host.  Deltas within a few percent
   are noise; the milestone-3 validation run read loops +0.6%,
   math -0.2%, strings -19.1%, arrays -32.9% — signal and noise
   cleanly separated on a host that had just invalidated every
   absolute number we had.

`bench/run.sh` itself times in interleaved rounds (best of five)
so slow host drift lands on every column equally — sequential
timing on a bursty container biased whole columns by 2-3x.

## The floor row, and why the benchmarks are big

Every timing here carries a fixed cost neither language is being
measured for: process startup on both sides, and on loom's side the
JIT compile of the program and of every std function it imports.
`time_once` adds ~1ms of its own on top, because it brackets each
run with two `date` forks and the second lands *inside* the
interval.  **A constant added to both columns is not neutral — it
pulls a ratio toward 1.**

Both fixes are applied.  The `floor` row times a do-nothing program
through the same harness, so the reader can see what is not
computation; and the benchmarks are sized so that floor is a small
fraction of every row.  Since the native image landed
(docs/NATIVE.md milestone 5b), best-of-N timing measures warm-cache
runs: the first round JITs and writes the `.lci`, later rounds map
it and run with zero codegen — the same accounting C gets, whose
compile is never timed at all.  They were once sized for a ~1s *interpreter*
run, which the native engine then made 10ms — small enough that
fixed cost dominated and `strings` read ~2.8x where the honest
figure was ~11x.  Sizing rule now: **native should run ~100ms, so
the floor is under ~10%**.  A std-importing program pays a few ms
more floor than the row shows (that compile is per-program).

Because the sizes changed, `bench/compare.sh` cannot cross this
commit — each side compiles its own `bench/*.luc`, so an older base
runs the older, smaller workload.  It is exact for any two refs on
the same side of the resize.

## Snapshot — 2026-07-31, milestone 4 (string producers)

On the host stamped in the table's run (Apple M4 Max, Darwin
arm64).  `native` is loom's default engine (docs/NATIVE.md);
`interp` forces the reference interpreter with
LOOM_ENGINE=interpreter:

| benchmark | C        | native   | interp    | native/C |
|-----------|----------|----------|-----------|----------|
| loops     | ~81ms    | ~90ms    | ~8.5s     | **~1.1x** |
| math      | ~140ms   | ~158ms   | ~10.1s    | **~1.1x** |
| strings   | ~20ms    | ~74ms    | ~1.1s     | **~3.6x** |
| arrays    | ~44ms    | ~81ms    | ~4.7s     | **~1.8x** |
| floor     | ~3.9ms   | ~4.3ms   | —         | — |

Milestone 3 made string byte access and rank-1 scalar array
indexing inline machine code (docs/NATIVE.md).  Milestone 4 went
after producing strings rather than reading them — fast services
for `chr`, `str(Int)` and `+`, plus the `append_ascii` and
`find_byte` primitives.  The remaining arrays gap is what
vectorization would buy.

For orientation, measured on the earlier Xeon container (not the
host above): CPython 3.11 ran the loops algorithm in 1228ms and
mandelbrot in 1884ms, where native Luce was ~25-80x faster and the
interpreter alone already edged it.  (CPython's mandelbrot count
matches Luce's exactly — both are strict IEEE.)

**Where we're at:** compiled Luce runs at **~1.1x full-speed C** on
scalar workloads, ~1.8x on the vectorizable array one, and **~3.6x**
on the string-bound one, checks and ownership included.  The
interpreter remains the reference implementation, the oracle, and
the fallback for platforms the JIT doesn't cover.

(An earlier edition of this line said ~11x for strings.  That was
measured on a workload too small to amortize startup and JIT — the
honest computational figure is the one above; docs/SPEED.md §11.)

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

1. ~~Milestone 2 (full native core)~~, ~~milestone 3 (unboxed
   access)~~, and ~~milestone 4 (string producers: fast services for
   `chr`/`str(Int)`/`+`, the `append_ascii` and `find_byte`
   primitives)~~ — shipped.
2. ~~**Don't compile what is never called**~~ — shipped as
   `ir.prune`, dead-code elimination in the compiler: an unused
   `import strings` went from 12308 to 178 bytes of `.lc` and from
   +4.11ms of load-time compile to free (docs/SPEED.md §12).
3. ~~**Hermetic codegen (M1)**~~ and ~~**the native image (M2)**~~
   — shipped (docs/NATIVE.md milestone 5; docs/SPEED.md §14-15).
   `loom run` now caches machine code in a `.lci` beside the `.lc`
   and warm runs do zero codegen, so compile time left these
   numbers the way C's did: by not happening at run time.  The
   tables above are warm-cache numbers by construction (best-of-N
   timing; the first round writes the image).
4. ~~**`List.append` on the generic path**~~ — shipped: value-typed
   elements (scalars, String) adopt nothing, so they take a direct
   service like the Builder's; strings read −12.2% on the A/B.
   Object-element lists keep the generic path (ownership).
5. **The self-written Zig backend** — M0 and M1 shipped
   (`codegen.zig`, LOOM_ENGINE=zig): aarch64, single-function
   integer core, every trap identical, and with M1's allocator it
   runs loops **at parity with MIR** (zig/MIR ≈ 1.00).  Next: the
   rest of the language, x86-64 Linux, then Windows; it becomes the
   default per-program when it wins this table (docs/SPEED.md
   §16-17).
6. **SIMD / the last 2x** — MIR does not vectorize; `arrays` will
   plateau a few x above C until an LLVM-backed engine is ever
   judged worth its 200MB.  Whole-array std intrinsics (dot, fill)
   are the cheap VEX-style alternative when a real program wants
   them — `find_byte` is the first of that family to ship.

## The regression-guard workflow

Before landing any change to an engine, the analyzer lowering, or
std internals:

```sh
bench/compare.sh HEAD        # working tree vs last commit
bench/compare.sh main~3      # or any base worth comparing against
```

A delta beyond a few percent on any benchmark is a regression or a
win to explain in the commit message.  `bench/run.sh` remains the
cross-language view (Luce vs C vs the interpreter, with the
output-equality check); its ratios are meaningful within one table,
its absolute times only on the host stamped above them.  Update the
snapshot when the numbers move for a *reason*, and record the host
with them.

`zig build test` compiles every `bench/*.luc` (not timed), so the
benchmarks themselves cannot rot.

## Adding a pair

1. `bench/NAME.luc` and `bench/NAME.c` — same algorithm, same
   printed output; integer outputs only (float formatting differs
   between the languages; cast through `Int(...)`/`(long)`).
2. Add NAME to `names` in `bench/run.sh` and to `benches` in
   `build.zig`.
3. Size it so the **native** side runs ~100ms — long enough that the
   `floor` row (startup plus JIT) stays under ~10% of it, short
   enough to keep the suite pleasant.  Sizing to the interpreter
   instead is how these got too small to measure honestly.  Prefer a
   knob that scales work without scaling retained data (`arrays`
   scales its repeat count, not its arrays).
