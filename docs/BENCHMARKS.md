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

## Snapshot — 2026-07-30

x86_64 Linux container, zig cc (clang 21), interpreter at
ReleaseSafe.  Luce times are stable run to run (±5%); the C times
are so small that container noise moves them ±40%, which is most of
the spread in the ratio:

| benchmark | C       | Luce     | Luce/C  | CPython 3.11 |
|-----------|---------|----------|---------|--------------|
| loops     | 16–26ms | ~0.97s   | 40–60x  | 1228ms       |
| math      | 18–22ms | ~1.1s    | 50–60x  | 1884ms       |
| strings   | 5–6ms   | ~0.45s   | 80–95x  |              |
| arrays    | 8–10ms  | ~0.38s   | 40–45x  |              |

(The CPython column is the same algorithm in plain Python on the
same machine, for orientation; its mandelbrot count matches Luce's
exactly — both are strict IEEE.)

**Where we're at:** 40–95× slower than full-speed C, and **faster
than CPython 3.11** on the loop-bound workloads (~1.3× on loops,
~1.7× on math).  That is respectable territory for a
safety-checked, ownership-tracking IR interpreter with zero tuning
so far.

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

## The path to C-class speed, honestly

1. **Interpreter tuning** (the current engine, kept as the reference
   implementation): threaded/computed-goto dispatch, batched
   step-budget accounting, fusing common instruction pairs.
   Realistic landing zone: 15–30× C.  Interpreters do not beat that
   band without JIT machinery.
2. **A compiled backend** — the real answer, and the language was
   shaped for it: statically typed, monomorphic, no GC, no dynamic
   dispatch, verified IR with explicit blocks.  Lowering Luce IR to
   native code (directly, or through Zig/C and an existing
   optimizer) puts checked code in Zig-ReleaseSafe territory —
   **1–2× C** — and closes the SIMD gap on `arrays`, because the
   optimizer vectorizes compiled loops.  Semantics never change:
   same traps, same codes, same IEEE results; a backend is a swap
   behind `backend.zig`, invisible to programs.

Interpreter levers in the order they would pay, until then:

1. **Dispatch and step accounting** — the fixed per-instruction
   costs dominate `loops` and `math`.
2. **Interpreted std strings** — `strings.upper` pays the full
   dispatch loop per byte; `strings` carries the widest ratio.
   Faster dispatch helps it first; native fast paths for hot std
   internals only with evidence, since that reverses a deliberate
   design bet.
3. **SIMD** — out of scope for an interpreter; the `arrays` ratio
   records what the compiled backend reclaims.

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
