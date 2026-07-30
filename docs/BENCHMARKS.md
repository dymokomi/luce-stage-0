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

## Snapshot — 2026-07-30

x86_64 Linux container, zig cc (clang 21).  Luce times are stable
run to run (±3%); the C times are so small that container noise
moves them ±40%, which is most of the spread in the ratio:

| benchmark | C       | Luce    | Luce/C    | CPython 3.11 |
|-----------|---------|---------|-----------|--------------|
| loops     | 16–26ms | ~3.9s   | 150–240x  | 1228ms       |
| math      | 18–22ms | ~5.2s   | 240–290x  | 1884ms       |
| strings   | 5–6ms   | ~1.6s   | 280–310x  |              |
| arrays    | 8–9ms   | ~1.5s   | 170–180x  |              |

(The CPython column is the same algorithm in plain Python on the
same machine, for orientation; its mandelbrot count matches Luce's
exactly — both are strict IEEE.)

**Where we're at:** the interpreter runs 150–300× slower than
full-speed C, and roughly 3× slower than CPython 3.11 on the
loop-bound workloads.  For a young, safety-checked, ownership-
tracking IR interpreter that is a sane starting point, not a crisis:
CPython's interpreter has decades of tuning (adaptive specialized
opcodes since 3.11) and Luce spends real work per step on things the
language promises — checked arithmetic, bounds and boundary checks,
statement-temporary bookkeeping.

Known levers, in the order they would pay:

1. **Dispatch and step accounting** — the inner loop's fixed costs
   (budget decrement, tagged-union switch) dominate `loops`.
2. **Interpreted std strings** — `strings.upper` pays the full
   dispatch loop per byte where C pays one instruction.  If string
   throughput ever matters, the fix is faster dispatch first, and
   only then reconsider native fast paths for the hottest std
   internals — moving code back into the compiler reverses a
   deliberate design bet and needs that much evidence.
3. **SIMD** — out of scope for an interpreter; the `arrays` ratio
   simply records what a future compiled backend could reclaim.

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
