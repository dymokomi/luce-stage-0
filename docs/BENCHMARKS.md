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

## The ratio column reads low — know by how much

`time_once` brackets each run with two `date` forks, and the second
one lands *inside* the measured interval: every number here carries
~1ms of that plus the ~1.3ms process floor, **on both columns**.  A
constant added to both sides of a ratio is not neutral — it pulls
the ratio toward 1.  On a fast host the effect is large: the
milestone-4 table below reads `strings 2.8x` where direct-exec
timing of the same binaries reads ~11x.

So: **`native/C` here is a lower bound**, useful for watching one
column move across a change, not for quoting the language's
standing.  `bench/compare.sh` is unaffected — it compares like with
like, and the constant cancels.  docs/SPEED.md §10 has the
direct-exec method.

## Snapshot — 2026-07-31, milestone 4 (string producers)

Illustrative, on the host stamped in the table's run (Apple M4 Max,
Darwin arm64).  `native` is loom's default engine (docs/NATIVE.md);
`interp` forces the reference interpreter with
LOOM_ENGINE=interpreter.  Both Luce columns include process
startup, .lc decode, and (native) the JIT compile — which for a
std-importing program is ~4ms, the largest single line item left in
`strings`:

| benchmark | C      | native  | interp   | native/C (low) |
|-----------|--------|---------|----------|----------------|
| loops     | ~7.0ms | ~8.5ms  | ~418ms   | ~1.2x |
| math      | ~9.9ms | ~11.8ms | ~497ms   | ~1.2x |
| strings   | ~4.1ms | ~11.5ms | ~62ms    | ~2.8x |
| arrays    | ~4.4ms | ~7.6ms  | ~131ms   | ~1.7x |

Milestone 3 made string byte access and rank-1 scalar array
indexing inline machine code (docs/NATIVE.md).  Milestone 4 went
after producing strings rather than reading them — fast services
for `chr`, `str(Int)` and `+`, plus the `append_ascii` and
`find_byte` primitives — for `strings` −27% and an interpreter that
more than doubled on the same bench.  The remaining arrays gap is
what vectorization would buy.

For orientation, measured on the earlier Xeon container (not the
host above): CPython 3.11 ran the loops algorithm in 1228ms and
mandelbrot in 1884ms, where native Luce was ~25-80x faster and the
interpreter alone already edged it.  (CPython's mandelbrot count
matches Luce's exactly — both are strict IEEE.)

**Where we're at**, by direct-exec timing with the process floor
subtracted (docs/SPEED.md §10 — *not* the ratio column above):
compiled Luce runs at **~1.2x full-speed C** on scalar workloads,
~3x on the vectorizable array one, and **~11x** on the string-bound
one, checks and ownership included.  The interpreter remains the
reference implementation, the oracle, and the fallback for
platforms the JIT doesn't cover.

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
2. **Don't compile what is never called** — `import strings` costs
   ~4ms of JIT for 18 functions where a program calls 7, which is
   now the single largest line item in `strings` (docs/SPEED.md
   §10).  Static reachability pruning before lowering, or lazy
   per-function compilation.
3. **`List.append` on the generic path** — what `split` is actually
   bounded by now; element adoption is ownership, so a fast service
   has to carry that.
4. **The self-written Zig backend** — grows unhurried behind the
   same seam, racing MIR under the same oracle and this table;
   sovereignty when it wins.
5. **SIMD / the last 2x** — MIR does not vectorize; `arrays` will
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
3. Size the Luce side to run 1–5 seconds: long enough to swamp
   startup, short enough to keep the suite pleasant.
