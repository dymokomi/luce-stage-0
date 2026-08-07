# Vectorizing checked reductions

A decision record, written against the tree at `80c5ba3`, after the
seven-type ladder and the benchmark snapshot that priced it.  Nothing
here is built.  This is the design; the plan at the end is what it
would cost.

The occasion is one row.  `bench/arrays32` sits at **8.14× its C twin
on the compute column** (`docs/CODEGEN.md` is the one place that
number is written down), and the cause is not the 32-bit width, not
the row resolution, and not allocation.  It is that every `+` and
every `*` in Luce carries an overflow test, a checked reduction
therefore has a value-dependent exit on every element, and a loop with
a value-dependent exit does not vectorize.  C's `int32_t` wraps —
undefined behaviour it is free to assume never happens — so LLVM
reassociates the sum and fills four lanes.  Luce is scalar at *both*
integer widths (41.8 ms at `int`, 41.1 ms at `long`); C is vectorized
at both (6.2 and 18.1 ms).

The instruction this memo answers is: *all of it should be vectorized,
and nothing may be sacrificed to get there.*

## The constraint, stated once

`total += xs[i]` traps at the exact element where the running sum
overflows, with trap code `integer_overflow`, the message
`"integer overflow"`, and — in a debug build — the exact
`file:line:column` and the exact call trace, **identically on the
compiled path and on the differential oracle**.  Semantics
bit-identical; traps exact.

Everything below is arranged so that this is preserved *by
construction* rather than by testing, and then tested anyway.  Any
design that weakens it is in [Refused](#refused), including the two
that look most like engineering and are not.

---

## What the measurement actually says

The seeded framing of this problem — and the sentence in
`docs/CODEGEN.md` that gestures at the fix — is "a `long` accumulator
over `int` elements cannot overflow, so prove the check away".  That
is true, and it is **not what `bench/arrays32` is**.  The row reads:

```luce historical
var dot: long = 0
for r in range(0, reps):
    var sum: int = 0
    for i in range(0, n):
        sum += a[i] * b[i]        # a, b: array(int, n)
    dot += sum
```

The hot loop is a **multiply-accumulate with an `int` accumulator over
`int` elements**.  Both facts matter and both kill the proof:

- The accumulator is the *same* width as the elements, so no width
  argument bounds the sum.
- The term is a product of two `int`s, evaluated at `int` (Luce
  unifies both operands to `int`), and `2^31 × 2^31` does not fit in
  an `int`.  The multiply is unprovable before the sum is even
  reached, and widening the accumulator does not help: written as
  `long(a[i]) * long(b[i])`, the product is provable (`2^62 < 2^63`)
  and the *sum* is not — `2^24 × 2^62 = 2^86`.

**A dot product over `int` elements is genuinely unprovable at every
accumulator width Luce has.**  That is arithmetic, not a limitation of
the analysis, and it means Layer 1 does nothing whatsoever for the row
that motivated this memo.  It also means Layer 2 is not the optional
sophisticated half of the design — it is the half that pays.

The rest of what the tree says, checked rather than assumed:

- **MIR has no unchecked add to lower to.**  `06_mir/defs.zig`'s
  `Instruction.Binary` is `{ op, operand_type, left, right }`.  Checkedness is
  not a field; it is implied by `operand_type` being `.int` or
  `.long`.  Every `.binary` with an integer operand type is checked,
  everywhere, on both engines.
- **The check is a branch per operation.**  `lower.zig`'s
  `emitChecked` calls `llvm.sadd.with.overflow` / `ssub` / `smul`,
  extracts the flag, and hands it to `Body.check`, which
  makes a *fresh* pair of blocks — `trap` and `ok` — per operation and
  continues lowering in `ok`.  `arrays32`'s inner loop therefore has
  two side exits per element.
- **The trap path is cold, not `noreturn`.**  It calls
  `luce_rt_raise`, then `luce_rt_unwound(runtime, function, instruction)`,
  then `ret i32 1`.  Both runtime calls are `.cold`
  (`08_llvm/runtime_effects.zig`'s table).  The instruction index it
  reports is `Body.current`, set per MIR instruction as `lower.zig`
  walks the block, and resolved against the per-function
  `luce.origins.{d}` table.
- **There is one arithmetic implementation.**  The oracle executes
  `.binary` by calling the same `runtime/operators.zig`'s `binary` the
  compiled path's semantics come from (`interpreter/machine.zig`'s
  dispatch loop).
  The two arms differ only in *how* the overflow bit is obtained.
- **Both engines see the same post-optimize MIR.**  `compile.zig`'s
  stage 7 runs `optimize.run` and re-verifies, and `compileProject`
  returns the optimized program; `specs/agree.zig`'s `compareProgram`
  hands one `*const mir.Program` to both arms.  No serialization sits between
  them.
- **Nothing in the tree does value-range analysis**, and
  `07_optimize.zig`'s header — "Not for scalar optimization" and "What
  deliberately does not run, and why" — records that two passes which tried
  (`flow` and `values`, ~498 lines) were *deleted* after measuring 0%
  benefit on the compiled path, on the ground that `default<O3>` does
  it better.  Any design that adds a lattice is arguing against a
  written and measured position.
- **`heap.max_array_elements` is `1 << 24`** (`runtime/heap.zig`),
  enforced by `newArray` per dimension and on the product.  It is
  re-exported from the `runtime.zig` barrel and **has no consumers**.
  `docs/TYPES.md` records that it counts elements rather than bytes
  and that this is a known wart left deliberately unfixed.
- **Lists have no cap and no inline indexing.**  A `list` element read
  is a runtime call (`docs/CODEGEN.md`: "`list`, whose buffer moves
  under `append`" is deliberately off the inline path), and a call in
  the loop defeats both view-stability and the vectorizer.  Everything
  below is about `array` and says so.
- **`byte` and `short` are storage, not arithmetic**
  (`support/types.zig`'s `Type`, and its `widensTo`).  `byte + byte`
  is an `int`; the verifier refuses storage-width arithmetic outright
  (`06_mir/verify.zig`, D5: "No operator computes at a storage
  width").  So the integer accumulator widths are
  `int` and `long`, and only those two.
- **`abs` already knows `minInt` is a trap** (`lower.zig`'s `.abs`
  arm, `operators.zig`'s `absolute`).  The witness below must not use it.

---

# Layer 1 — prove the check away

Where the accumulator is provably wide enough that no prefix can
overflow, the checks are dead code.  Remove them and the loop becomes
a plain integer reduction, which LLVM vectorizes with **no fast-math,
no `nsw`, and no reassociation licence of any kind** — because
two's-complement addition is exactly associative and exactly
commutative, so the vectorizer needs no permission it does not already
have.  This is the same reason `llvm.minimumnum` lets an extremum
reduction vectorize (`docs/CODEGEN.md`, "why a `min` reduction
vectorizes"): the operation is associative on the nose, so lane-wise
regrouping computes the identical value.

## Where the proof lives, and why not where it was expected to

The seeded question was "07_optimize with the type and bound facts, or
the lowering?".  The answer is **the lowering**, and it is not a close
call.

**Stage 7 cannot express the result.**  There is no unchecked add in
MIR.  Putting the proof in stage 7 means inventing one — a
`checked: bool` on `Binary`, or an `add_unchecked` op — which bumps
`format_version`, and then puts a flag *that turns a trap into a
silent wrap* into a format `decode` trusts beyond the verifier
(`06_mir/module.zig`: "instruction types beyond the verifier are
trusted — treat a `.lc` like an executable").  A forged or damaged
module could then wrap where the language traps.  The alternative —
re-deriving the proof in the verifier so the flag can be checked — puts
a loop recognizer and a width table inside the thing whose job is to
be small and total.  Neither is acceptable.

**Stage 7 has a written position against this.**  Two range-ish passes
were deleted from it for measuring nothing.  A new one would have to
argue its way past that, and it would be arguing for a lattice this
design does not need.

**Lowering-only is strictly more testable.**  This is the argument
that settles it, and it inverts the worry in the brief.  If the proof
lives in MIR and deletes the check, *both* engines skip it — and a
wrong proof is then invisible, because there is no arm left that would
have trapped.  If the proof lives in the lowering, **the oracle keeps
checking**: it runs `runtime/operators.zig`'s `@addWithOverflow` on
every element, always.  A proof that is wrong by one element produces a
compiled run that wraps and an interpreted run that traps, and
`specs/agree.zig`'s `compare` fails on the trap code, the message, the trace
and the transcript at once.  The differential oracle is the
un-optimized reference this design needs, and it already exists.  It
ships in nothing, so it costs nothing to keep checking.

**And the removal is observationally null anyway.**  A provably dead
check cannot fire.  Removing it on one arm and not the other is not a
divergence; it is the same program with one arm doing less work.  The
engines agree because the check was dead, not because both dropped it.

So: a new `src/luce/08_llvm/reduce.zig`, sibling to `loops.zig`,
computing a plan from verified MIR that `lower.zig` consumes.  That is
exactly `loops.zig`'s contract and exactly its genre — the hoisting
precedent is the model, down to the shape of the `Plan` and the
`find(block, local)` lookup.

One structural consequence: `loops.zig`'s `Graph`, `Loop`, `loops()`
and `preheader()` are private to that file and would now have two
users.  The right move is to lift them into `src/luce/08_llvm/cfg.zig`
— a control-flow graph with dominators, natural loops and preheaders,
behind three functions (`build`, `loops`, `preheader`).  That meets
`docs/CODING_GUIDE.md`'s split rule on its own terms: a subproblem
with a one-to-three-function interface, understandable without the
parent's state, at a boundary you would draw as an API anyway.  It is
not a split made to satisfy a sibling's test.

## The width table

The bound is: with the accumulator entering at a known constant `c`
and `N` terms each of magnitude at most `M`, every prefix satisfies
`|prefix| ≤ |c| + N·M`, and the loop is provably trap-free when
`|c| + N·M ≤ A`, where `A` is the accumulator type's maximum.

`N` is `heap.max_array_elements` = 2^24 = 16,777,216, which bounds the
trip count *only because the loop's bound is that array's own length*
— see [what the proof must see](#what-the-proof-must-see).  `M` comes
from `types.Type.integerRange` (`support/types.zig`), which is the
only bound source this design uses: **type-derived, never
dataflow-derived.**  A type-derived bound needs no lattice and cannot
go stale.

Plain sums, `acc += xs[i]`, with `c = 0`:

| element | M | N·M | `int` acc (2^31−1) | `long` acc (2^63−1) |
|---|---|---|---|---|
| `byte`  | 255 | 4,278,190,080 (≈2^32) | no | **yes** |
| `short` | 32,768 | 549,755,813,888 (2^39) | no | **yes** |
| `int`   | 2^31 | 2^55 | no | **yes** |
| `long`  | 2^63 | 2^87 | no | no |

Three rows qualify, and they collapse to one sentence: **a `long`
accumulator over elements narrower than `long`.**  Since `int` and
`long` are the only integer arithmetic widths Luce has, "strictly
wider than the element" and "the widest accumulator" are the same
condition here, and there is no second rung to get wrong.

Multiply-accumulates, `acc += a[i] * b[i]`, are two obligations: the
product must not overflow *its* arithmetic width, and the running sum
must not overflow the accumulator.  The product is evaluated at
`Type.arithmeticType` of the unified operands — `byte` and `short`
both compute at `int` — so:

| terms | product width | product provable? | P (max \|term\|) | N·P | `long` acc? |
|---|---|---|---|---|---|
| `byte × byte`   | `int` | yes | 65,025 | ≈2^40 | **yes** |
| `byte × short`  | `int` | yes | 8,355,840 | ≈2^47 | **yes** |
| `short × short` | `int` | yes | 2^30 | 2^54 | **yes** |
| `byte × int`    | `int` | **no** (255·2^31 ≫ 2^31−1) | — | — | — |
| `int × int`     | `int` | **no** | — | — | — |
| `long(int) × long(int)` | `long` | yes (2^62) | 2^62 | 2^86 | **no** |
| `long × long`   | `long` | no | — | — | — |

Two things to read off it.  First, **`byte × int` fails for a reason
that is about Luce and not about magnitudes**: the unification lands
the product at `int`, where a 255 and a 2^31 do not fit, even though
their product would fit comfortably in a `long`.  A user who wants
that loop writes `long(a[i]) * b[i]`, which then fails at the sum
instead.  Second, **no `int`-element dot product qualifies at any
width** — which is `bench/arrays32`, and is why Layer 2 exists.

One row deserves its own line, because it is the reason this table
must be *computed* and never written by hand.  `byte` elements
multiplied by `int` elements, if the product were evaluated at `long`,
would give `P = 255 · 2^31 = 547,608,330,240` and
`N·P = 9,187,343,239,835,811,840` against `2^63−1 =
9,223,372,036,854,775,807`.  **It fits, with 0.39% to spare.**  Nobody
gets that right by writing `2^39` in a comment.

## What the proof must see

The recognizer is defined once and both layers use it; it is stated in
full under [Layer 2](#recognition-precisely).  For Layer 1 the
additional requirements are:

- **The trip count is bounded by the cap.**  The loop's limit must be
  a `len` intrinsic on the *same array local* the term indexes, or a
  `dim_size` of it.  A `while`, a `range(0, k)` with `k` not an array
  length, or a loop over one array indexing another, all fail — the
  cap bounds an array's element count, not an arbitrary integer.
- **The accumulator enters at a known constant.**  `|c|` must be
  known, and in practice it is 0 (`var total: long = 0`).  A
  non-constant entry value is unbounded for a `long`, so the proof
  cannot close.  This is a real precondition and it is why the outer
  loop in `arrays32` — `dot += sum`, 400 reps, `dot` starting at 0 but
  `sum` a full-range `int` — would fail even if its trip count were
  array-bounded.
- **The proof is re-derivable from MIR alone.**  A `.lcm` reaches
  stage 8 through `decode` without ever passing the analyzer
  (`loops.zig`'s header makes the same point about block ordering).  Every
  fact used here is either a type in the module or a cap the *runtime*
  enforces at `new array`, so the proof holds for any module that
  reaches the backend, forged or not.

## The cap link, which must be comptime

The proof depends on `heap.max_array_elements`, and `docs/TYPES.md`
already records that this constant is denominated in the wrong unit
and that changing it is somebody's future decision.  A comment saying
"keep these in sync" is not acceptable.  The requirement is:

1. `reduce.zig` imports `runtime.max_array_elements` — becoming its
   first consumer — and computes every row of both tables **in
   `comptime` `i128` arithmetic**, never in `i64`, because `i64` is
   the width the arithmetic is about and a wrapped bound computation
   would report that everything fits.
2. Each row carries a `comptime` assertion, so a cap that invalidates
   a row is a **compile error in the backend**, not a wrong answer at
   runtime.
3. **The call site asks the right question.**  Not
   `max_array_elements` but `heap.maxElements(element: types.Type)`.
   Today it returns the constant for every type.  If the cap ever
   becomes byte-denominated, the answer moves with the element width
   and the proof recomputes itself; with a bare constant, it would
   silently over-count `array(byte, n)` by 8× and the `byte`/`long`
   row would become false.  Adding that one function now is the whole
   cost of making the dependency structural.
4. A test in `reduce.zig` recomputes the table from the cap and
   compares it against the enumerated rows, so the table cannot be
   edited without the arithmetic agreeing.

## What Layer 1 covers today: nothing, and it goes first anyway

Swept across `programs/`, `src/luce/std/` and `bench/`, the compound
additions are float reductions (`math.luc`'s `sum`, `dot`, `variance`,
`norm`), scalar counters in `strings.luc`, and the three benchmark
reductions — none of which is a narrow-element integer reduction into
a `long`.  **Layer 1 moves no existing benchmark row.**

That is not an argument against building it.  It is an argument
against *selling* it as the fix, and against merging it without a
measurement:

- Layer 1 is **exactly Layer 2 minus the witness and the second arm**.
  Building it first builds the recognizer, the `cfg.zig` extraction,
  the comptime table and the spec file, and gets all four reviewed
  against a change that has no runtime guard to reason about.
- It is the compute half of a promise `docs/TYPES.md` made and only
  measured in memory.  The narrow types bought 7.98× on resident set
  and, by that document's own measurement, *nothing* in speed.  This
  is what would make `array(short, n)` faster as well as smaller, and
  until it exists nobody has a reason to write one.
- So it needs a row it does move.  **`bench/arrays16.{luc,c}`** — a
  dot product over `array(short, n)` into a `long`, sized so both
  sides print the same number — added beside the existing rows and
  never substituted for one, per `docs/TYPES.md` D7.  Without it,
  Layer 1 is an unmeasured claim.

---

# Layer 2 — speculate, guard, replay

For everything the proof cannot close: run the reduction unchecked in
wide lanes, guarded by a **sound witness** computed from the data, and
fall back to the ordinary scalar checked loop when the witness fails.

The witness is the entire design.  Get it wrong and the language
silently stops trapping.

## The trap: per-lane overflow flags are unsound

The obvious witness — vectorize the reduction, keep a per-lane
overflow flag, and replay if any lane overflowed — **is wrong, and it
is wrong in the unforgivable direction: it misses traps the language
owes.**

Lanes hold *strided* partial sums, not prefixes.  At four `i64` lanes,
take:

```
x = [ 2^62,  2^62,  2^62,  2^62, −2^62, −2^62, −2^62, −2^62 ]
```

Lane *k* accumulates `x[k] + x[k+4] = 0`.  No lane overflows.  No flag
sets.  The horizontal sum is 0, and the vectorized loop reports
success.

The language's answer is a trap.  The true left-to-right prefixes are
`2^62` then `2^63` — **overflow at element 1**, `integer_overflow`,
at that element, with that line and that trace.  The `i32` analogue is
the same array with `2^30`, and it overflows at element 1 just the
same.

Two adjacent elements land in *different* lanes, which is precisely
why lane-local evidence cannot see a prefix property.  A false
positive would merely be slow; this is a false negative, and it is the
one outcome the constraint forbids.  **No lane-local witness can be
sound for a prefix obligation.**  Any future attempt to shortcut Layer
2 will rediscover this idea first; it is written here so it can be
discarded on sight.

## The witness: sum of magnitudes

Let the accumulator enter the loop with value `c`, let the terms be
`t₀ … t_{n−1}`, and let `S = Σ|tᵢ|`.  The witness is:

> **`|c| + S ≤ A`**, where `A` is the accumulator type's maximum
> (`2^31 − 1` for `int`, `2^63 − 1` for `long`).

**Soundness.**  For any subset `T ⊆ {0 … n−1}` and any order,

```
| c + Σ_{i∈T} tᵢ |  ≤  |c| + Σ_{i∈T} |tᵢ|  ≤  |c| + S  ≤  A
```

from which three things follow, and they are exactly the three things
needed:

- **A.** Every left-to-right prefix is representable, so the scalar
  checked loop would have trapped nowhere.
- **B.** Every lane's partial sum, and every partial horizontal
  combination, is representable, so the vector computation never wraps
  and is exact integer arithmetic throughout.
- **C.** Exact integer addition is associative and commutative, so the
  regrouped vector result *equals* the sequential result — not
  approximately, identically.

The comparison is against `A = 2^(w−1) − 1` and not `2^(w−1)`.  A
value is representable in `i_w` when `−2^(w−1) ≤ v ≤ 2^(w−1) − 1`, so
testing against `A` is exactly right on the positive side and
conservative by one value on the negative.  That off-by-one is a
mutation in the kill table below.

### The lemma that makes multiply-accumulate cheap

For a multiply-accumulate the term is `tᵢ = aᵢ · bᵢ`, and there are
*two* obligations: no product may overflow the arithmetic width, and
no prefix may overflow the accumulator.  The single witness discharges
both, because every `|tᵢ|` is a non-negative summand of `S`:

```
|tᵢ| ≤ S ≤ A   for every i
```

So `S ≤ A` proves no individual product exceeds the accumulator's
maximum, and since the accumulator's width is at least the product's
arithmetic width in every recognized shape, no product overflows
either.  **One witness, two obligations** — no separate product guard,
no max-of-operands pass.

### Computing `S` without overflowing while proving nothing overflows

`S` is computed unchecked and must be *total*: it may not trap, and it
may not itself wrap into a value that makes a false witness true.

- **The magnitude is unsigned, never `abs`.**  `|INT64_MIN|` is not
  representable as an `i64`, and the tree already knows it —
  `lower.zig`'s `.abs` arm checks `held == minInt` before `llvm.abs`
  and `operators.zig`'s `absolute` raises `integer_overflow` there.  The witness
  computes the magnitude as a `u64`: `x < 0 ? 0 − (u64)x : (u64)x`,
  which is exact for `INT64_MIN` (it gives `2^63`) and is two vector
  instructions.  The same expression serves every element width after
  the widening sign-extension.
- **The accumulation saturates where it must.**  Two arms, licensed by
  the same comptime table Layer 1 uses:
  - **Elements narrower than `long`**: `N·M ≤ 2^55`, so `S` in a plain
    `i64`/`u64` cannot overflow, provably, and the accumulation is an
    ordinary vector add.  This is Layer 1's table read as a
    *different* question — "can the witness pass overflow?" rather
    than "can the reduction?" — from the same numbers, which is why
    the two layers share one table.
  - **`long` elements**: `S ≤ 2^24 · 2^63 = 2^87` and does not fit.
    The accumulation is **unsigned saturating** (`llvm.uadd.sat`,
    `uqadd` on AArch64, an add/compare/select triple on x86).  A
    saturated `S` is `u64`-max, which fails the witness, which takes
    the scalar arm.  **Saturation is fail-closed by construction**,
    which is the property that makes it the right primitive: we do not
    need the value of `S`, only the predicate `S ≤ A`, and saturation
    answers that predicate correctly in both directions.
  - The rejected alternative is a 128-bit accumulator for `S`.  It is
    exact, and exactness is not needed; two-limb vector accumulation
    costs more than `uqadd` and buys a number nobody reads.
- **`|c|` joins the same way.**  `|c|` is computed as a `u64`
  magnitude (again exact at `INT64_MIN`) and saturating-added to `S`
  before the comparison.  Omitting the carry is the mutation that
  makes a loop resumed near the ceiling wrap silently; it has a spec.
- **For multiply-accumulate the term is widened before its
  magnitude.**  With `byte`/`short`/`int` elements, `aᵢ · bᵢ` computed
  in `i64` from two sign-extended operands is **exact** (`|t| ≤ 2^62`)
  — a widening multiply, `smull`/`smull2` on AArch64, two `i64` lanes
  per four `i32` inputs.  `long × long` products are not exactly
  computable in `i64` and would need a 128-bit magnitude; **that shape
  is scoped out** and falls to the scalar arm.  It is also the shape
  whose witness would almost always fail on real data, so the scope
  line costs nothing measurable.
- **The witness reads only elements the loop is guaranteed to read.**
  The loop's trip count `n` is compared against the row's resolved
  element count in the preheader; `n >` count takes the scalar arm,
  which then traps `index_bounds` at exactly the element it always
  did.  A dead or null handle likewise takes the scalar arm.  **The
  preheader guard never traps; it only chooses.**  A loop that runs
  zero times over a freed array still traps nowhere, which is the
  invariant `loops.zig` already protects.

## The emitted shape

In the preheader of the recognized loop, after the row resolution
`loops.zig` already lifts there:

```
preheader:
    carry   = local_get acc
    n       = <the loop's trip count>
    alive   = <handle non-null and generation matches>          ; already computed
    inrange = n <= row.count
    S       = magnitudeSum(row, n)          ; vector, unchecked, total
    need    = uadd.sat(magnitude(carry), S)
    ok      = alive & inrange & (need <= A)
    br ok, fast, slow                                            ; .then_likely

fast:                                        ; hand-emitted
    total = carry + reduce_add(elements)     ; plain wrapping adds, no checks
    br join

slow:                                        ; the lowering that exists today
    ... unchanged, including its per-operation `trap`/`ok` blocks,
        its `self.current` origins and its `luce_rt_unwound` frames
    br join

join:
    acc = phi [ total, fast ], [ scalar_total, slow ]
```

`S` and the `fast` reduction share their loads, so the two are emitted
as **one loop with two vector accumulators**, not two passes over
memory.

## Determinism, by construction

1. `slow` is byte-for-byte the lowering that exists today.  Nothing
   about a trap's code, message, location, or trace can differ,
   because nothing about the code that produces them changed.
2. `fast` is entered only when the witness holds.  Under the witness,
   corollary **A** says `slow` would have trapped nowhere and
   corollaries **B**+**C** say `fast` computes the identical integer.
   So on the `fast` path there is nothing to report and nothing to
   differ about.
3. The witness computation raises nothing, reads nothing outside the
   row, and cannot overflow into a false positive (saturation is
   fail-closed).
4. Therefore the loop's observable behaviour is a function of the data
   alone, never of which arm ran.

And the proof of (4) is not a proof, it is a test suite: **the oracle
always runs `slow`'s semantics.**  Every program in `specs/` executes
on both arms and is compared on the transcript, the trap code, the
trap message, the call trace frame for frame, the leak census and the
world left behind (`agree.zig`'s `compare`).  A speculation bug is a
divergence, and a divergence is a red suite.  This needs no new
verification machinery and no compile-time knob to disable
vectorization — **adding such a knob would be the mistake**, since it
would create a second lowering nobody runs, and the un-speculated
reference already exists and is already run on every spec.

## Recognition, precisely

At MIR, a **checked reduction loop** is a natural loop `L` (from the
extracted `cfg.zig`) satisfying all of:

- `L` has a single preheader whose only successor is `L`'s header —
  `loops.zig`'s existing `preheader` test — and the preheader is
  lowered before every block that reads what it emits
  (`loops.zig`'s `emittedFirst`).
- **View-stable.**  `optimize.effects.viewStable` holds for every
  instruction in `L`, with `loops.zig`'s one refinement for
  `index_set` of a plain element.  No call, no allocation, no free —
  which is also what keeps the arrays' rows valid across the witness
  pass and the fast arm.
- **Exactly two exits**: the header's back edge and the header's exit
  edge.  No `ret`, no `trap`, no `unwind`, no other `branch` anywhere
  in `L`.  This excludes `break`, `return` and any `if` in the body.
- **One induction variable**: a local initialised in the preheader,
  compared in the header against a loop-invariant limit, incremented
  by the constant 1 in the latch, and written nowhere else.
- **One accumulator local `acc`** with `local_type` `.int` or `.long`,
  whose only write in `L` is a single `local_set` whose value is a
  `.binary { .add, operand_type == acc's type }` with one operand
  `local_get acc`, and which is **read by nothing else in `L`**.
- **The term** is one of:
  - `index_get(array_local, i)`,
  - a `convert` widening one of those,
  - `.binary { .multiply, index_get(a, i), index_get(b, i) }`.
- **The array locals are not assigned in `L`** (`loops.zig`'s
  `assigned` test) and are `array` heap types, not `list`.
- **The index is the induction variable itself**, not an expression
  over it.
- **Every remaining instruction in `L` is pure**
  (`effects.classify == .pure`) and contributes only to the induction
  update, the term, or the accumulator update.

Disqualifiers, named so a diagnostic or a comment can name them: a
second write to `acc`; any other read of `acc`; a call of any kind; an
early exit; an index that is not the induction variable; a
reassigned array local; a `list` receiver; a `.subtract` accumulation
(`acc -= t` is `acc += (−t)` and `−INT64_MIN` traps, so it is a
separate shape and is not in this design).

Two notes on the shape.  `for x in xs: total += x` and
`for i in range(0, len(xs)): total += xs[i]` are the **same MIR** —
`04_semantics/builder.zig` desugars the first into the second — so one
recognizer covers both spellings.  And recognizing at MIR rather than
at HIR is what makes hand-written loops work, which is the common case
and always will be.

## Cost model, and the prediction to beat

Nothing here is measured; this is a prediction with its arithmetic
shown, so the first measurement can falsify it cleanly.

Per element, in vector operations (AArch64, 128-bit lanes):

| shape | C's ideal | Layer 2 | ratio |
|---|---|---|---|
| `long` sum over `array(long)` | 0.5 load + 0.5 add = **1.0** | + 0.5 magnitude + 0.5 `uqadd` = **2.0** | 2.0× |
| `int` dot over `array(int)` | 0.5 load + 0.25 mla = **0.75** | + 0.5 `smull` + 0.5 magnitude + 0.5 `uqadd` = **2.25** | 3.0× |

Against `arrays32`'s numbers — C 6.2 ms, Luce 41.8 ms — a 3× ratio on
vector work predicts **≈18–20 ms, or ≈3× C on the compute column,
down from 8.14×**.  That is a 2.2× speedup and it is *not* parity, and
the memo says so plainly: a checked reduction pays for its guarantee,
and after this design it pays roughly 3× instead of roughly 8×.

A cheaper witness exists and is deliberately not the design.
`max|aᵢ| · max|bᵢ| · N ≤ A` needs only two 4-lane magnitude-max
reductions (≈1.75 ops/element, ≈2.3× C) and is sound.  It is also far
weaker: on `arrays32`'s own data it gives `99 · 99 · 200000 =
1,960,200,000` against `2,147,483,647` — it passes with 9% to spare,
where the sum-of-magnitudes witness passes with 76%.  A guard whose
answer flips when a benchmark's `n` moves from 200,000 to 220,000 is a
guard that will silently stop paying.  **Tight witness first; the
cheap one is a measured optimization, not a starting point.**

## Step 0: the measurement that can invalidate all of this

Before a line of Layer 2 is written — before Layer 1, in fact —
measure the ceiling:

1. Take `bench/arrays32.luc`, and in a scratch branch remove the
   overflow checks from `emitIntArithmetic` entirely (unsound, never
   merged, thrown away).  Time it.
2. **If it does not approach C's 6.2 ms, the checks are not the whole
   obstruction** and this design is aimed at the wrong thing.  The
   candidates would be the row resolution `loops.zig` lifts, the
   bounds check LLVM versions the loop around, or the `%depth`
   argument's effect on inlining.  Find out which before building a
   witness.
3. Then add only the witness pass to the unchecked build, so the
   guard's own cost is measured separately from the speculation's
   benefit.

This is half a day and it gates a two-week piece of work.  It is the
first task in the plan for that reason.

---

# Layer 3 — the whole-array route, with HIR

`src/luce/05_hir.zig`'s header already ratifies the rule this depends
on: **whole-array operations survive HIR and MIR as single nodes and
are never expanded into a scalar loop.**  When `math.sum` and
`math.dot` arrive at the backend as intrinsics rather than as loops,
`reduce.zig`'s recognizer is not needed for them — the node *is* the
recognition — and the same emitter serves both entries.

A sketch only; the design belongs to HIR's own memo.

- **The intrinsic carries the accumulator type explicitly**, rather
  than inferring it from the element type.  `sum(array(int, _))` into
  a `long` and into an `int` are different obligations, and the node
  must be able to say which.
- **The emitter is shared, not duplicated.**  Layer 2's witness, two
  arms and phi are a function of (element type, accumulator type, term
  shape).  A whole-array node supplies that triple directly; a
  recognized loop supplies it after analysis.  One emitter, two
  front doors.
- **Do not sell Layer 3 as the fix for `arrays32`.**  Every
  whole-array operation in `std/math.luc` today is `double`
  (`sum`, `mean`, `dot`, `norm`, `variance`, `scale`, `axpy`, `fill`),
  and float reductions stay ordered — see below.  Layer 3 buys the
  integer case nothing until integer whole-array operations exist.
  Its value here is representational: it removes the recognition step,
  it makes `a * b + c` fusible (05_hir's own argument, with the
  measurement that LLVM's `LoopFusePass` will not do it), and it is
  the numpy/mlx/GPU on-ramp.
- **Sequencing: Layers 1 and 2 must not be built on HIR.**  A user's
  hand-written `for i in range(0, len(xs))` is the common case
  forever, and it needs the loop recognizer whatever HIR does.  Build
  the emitter against loops; let HIR add the cheaper entrance later.
  In `docs/MISSING.md`'s order-to-work-down, HIR is item 12; this
  work does not wait for it and does not block it.

---

# The neighbours

**Float reductions stay ordered, and that is already parity.**  IEEE
addition is not associative, so a left-to-right float sum cannot be
reassociated — **by C either**.  `bench/arrays` sits at 1.05× for
exactly this reason: both sides are scalar.  No fast-math flag will
ever be emitted; that is a semantics mode wearing a compiler option
(see [Refused](#refused)).  The one thing that could change is a
*language* decision — a separately named unordered reduction — and
`std/math.luc`'s header currently promises left-to-right accumulation
and bit-reproducibility across engines and against the C twins.  Not
decided here.

**Float `min`/`max` already vectorize** and the reason is instructive
for this whole memo: `llvm.minimumnum` is exactly associative and
exactly commutative because NaN is an identity rather than an
absorber, so the vectorizer regroups it with no licence needed.
`math.vmin` over two million elements becomes `fminnm.2d`, and
`bench/stats` went 1.23× → 1.08× (`docs/CODEGEN.md`, "why a `min`
reduction vectorizes").  **Meaning first, speed as a consequence** —
which is the same argument Layer 1 makes for two's-complement addition.

**Multiply reductions are scoped out, and here is the witness that
does exist.**  `prod *= xs[i]` is associative once unchecked, so the
vectorization would be legal; the problem is the guard.
`Σ bitwidth(|xᵢ|) ≤ 63` is **sound** — it bounds `|Π x| < 2^63` — and
cheap enough to vectorize at ≤32-bit lanes.  It is also useless: 64
elements of value `±1` already sum to 64 and fail it.  Tightening it
means finding the first zero (after which every prefix is 0) and
tracking exact powers of two, which is a great deal of machinery for a
population of arrays that is essentially {mostly 0, mostly ±1}.  An
integer product over more than ~63 non-unit elements overflows
whatever you do.  **Sums and multiply-accumulates only**; the honest
sentence is that nobody's hot loop is an integer product.

**Lists were out of scope for both layers when this was written, and
that reason has since expired.**  The sentence here was that a `list`
element read is a runtime call rather than an inline load, so a `list`
reduction is not view-stable and would not vectorize even unchecked.
A `list` is on the inline path now (`docs/CODEGEN.md`, "Inline
access"): the read is a bounds check and a load, and a loop that could
grow one is still refused by `viewStable`, which is what makes the
lifted resolution sound in the first place.  So a `list` reduction is
in the same position as an `array` reduction and this design should
say so when it is next executed — nothing below has been re-measured
against that, and neither layer is built yet.

**The interpreter arm does not change and must not.**  It keeps
calling `runtime/operators.zig`'s `@addWithOverflow` on every element.
It ships in nothing; its whole cost is the ~0.3 s of interpreted arms
inside a four-minute suite (`docs/ENGINE.md`).  What it buys in
exchange is the only thing that makes speculation safe to merge: an
independent implementation that always checks, run on every spec,
compared on everything observable.  **Do not "optimize" the oracle to
match.**

---

# Verification

A new `src/luce/specs/vector_spec.zig`, registered in
`src/luce/specs.zig`'s re-exports and test block.  Everything in it
runs on both engines through `agree.ok` / `agree.trap` /
`agree.prints`, which is the whole point.

**One spec per qualifying pattern** (Layer 1): `byte`→`long`,
`short`→`long`, `int`→`long` sums; `byte × byte`, `byte × short`,
`short × short` dots into `long`.  Each at the empty array, one
element, and — where the allocation is affordable, which for
`array(byte, 1 << 24)` at 16 MB it is — near the cap.

**One spec per *refusal***, because a proof that fires where it should
not is the failure mode: `int × int` into `long` must still trap where
it always did; `long`-element sums must still trap; an `int`
accumulator over `int` elements must trap at the exact element;
`byte × int` must trap rather than being quietly admitted.

**Layer 2 specs**: a witness that passes; a witness that fails and
traps at a known element with a pinned trace; the strided-lane program
from above, which the unsound design would run to completion and the
sound one traps at element 1; an `array(long, _)` containing
`INT64_MIN`; an accumulator entering near the ceiling so the witness
fails on data that would otherwise pass; a loop whose trip count
exceeds the array's length, which must take the scalar arm and trap
`index_bounds` at the same element as today.

**The kill table this work commits to producing.**  `docs/TYPES.md`
step 6 sets the standard — fifteen mutations, and the five that
survived round one were all real holes.  The mutations this design
must be swept with, and what must catch each:

| mutation | killed by |
|---|---|
| the bound table computed in `i64` instead of `i128`, so `N·M` wraps and every row "fits" | the `int`-accumulator-over-`int` overflow spec: compiled wraps, oracle traps, `agree` diverges |
| `max_array_elements` read as a literal `1 << 24` and the cap moved | the comptime assertion, and the table-recomputation test |
| the qualifying test admits an equal-width accumulator | the same overflow spec |
| `byte × int` admitted (the unification width ignored) | the `byte × int` refusal spec |
| the witness replaced by per-lane overflow flags | the strided-lane spec |
| the witness omits `\|c\|` | the near-ceiling carry spec |
| `abs` used instead of the unsigned magnitude | the `INT64_MIN` element spec |
| `<` where `≤` belongs, or `2^(w−1)` where `2^(w−1) − 1` belongs | a spec sitting exactly on the boundary, both sides |
| saturation dropped from the magnitude sum | an `array(long)` whose `Σ\|x\|` exceeds `2^63` |
| the trip-count-versus-length guard removed | the over-long-loop spec |
| recognition admits a second write to the accumulator | a body that also does `acc = acc * 2` |
| recognition admits an early exit | a body with a `break` |
| the `fast` arm entered on a dead handle | a use-after-free spec over a loop that runs zero times |

---

# Refused

**Wrapping operators, `unchecked` blocks, and a `--fast` flag.**
`docs/MODES.md:46-57` is not ambiguous: Zig's `ReleaseFast` turns
integer overflow into undefined behaviour and *Luce refuses the
trade*, so that "there is no 'works in debug, corrupts in release'
class of bug, and release needs no separate testing story".  An
`unchecked` block is the same trade at a smaller scope; a `+%`
operator is the same trade at a smaller scope still.  Each creates a
region where the safety story is conditional, and each makes every
library function's contract depend on which spelling its author
reached for.  (This is not the same thing as `programs/bf.luc`'s
`% 256`, which is a wrap the *program* asked for, computed at full
checked width, and which the `byte` type has since made legible.)

**`nsw` / `nuw` on the reduction's adds.**  This is the metadata that
would actually make LLVM vectorize the loop, and that is exactly why
it is refused: `nsw` says signed overflow is poison, poison is
undefined behaviour, and undefined behaviour deletes the trap.  It is
the wrapping opt-in wearing an attribute.  Note the shape of the
argument, because it is total: *where the proof holds, `nsw` would be
true — and unnecessary, because two's-complement addition is already
exactly associative and the plain `add` vectorizes on its own; where
the proof does not hold, `nsw` would be a lie.*  There is no case in
which emitting it is both safe and useful.

**The metadata route.**  No LLVM metadata makes a value-dependent side
exit vectorizable, and it is worth saying why so nobody retries.
`!llvm.loop.vectorize.enable` is a hint the vectorizer discards for a
loop it cannot prove legal.  TBAA and `!alias.scope` speak about
memory, not control flow — they are what `loops.zig` wanted and could
not have, and even having them would only have moved loads.  Branch
weights change layout, not legality.  The obstruction here is **not
information the compiler is missing**; it is that the loop has an exit
whose condition depends on the accumulated value and whose live-out
*is* that value.  Metadata can describe aliasing, profitability and
intent.  It cannot describe an exit away.

**Early-exit ("multi-exit") vectorization.**  LLVM's early-exit
vectorization handles loops whose exit is a *search*: the live-out is
an index or a boolean, recoverable from lane state.  A checked
reduction fails it twice.  Its live-out is the running sum at the
trapping element, which no lane holds — lanes hold strided partials.
And per-lane overflow detection cannot even locate the trapping
element, for the reason worked through above.  To recover both the
element and the value you must replay from the loop's entry state —
which *is* Layer 2.  So this is not an alternative to Layer 2; it is
Layer 2 with LLVM doing the half that was never the hard part.

**Widening the accumulator behind the user's back.**  Compiling
`sum: int` as an `i64` and range-checking once at the end is tempting,
cheap, and wrong.  The language says the trap is at the element where
the *running* sum overflows.  A late check reports a different
element — or none at all, for a sum that exceeds `2^31` and comes
back.  It is a semantics change wearing an optimization's clothes, and
it is the one in this list most likely to be proposed by someone who
has read only the benchmark.

---

# Scoped out (not refused — just not now)

- **Bounds from anything but types.**  `x % k` with `k` a positive
  constant bounds a term to `0 … k−1`, which would qualify
  `bench/loops`' `total += (i * j) % 7` if its trip count were
  array-bounded.  Every such rule is the first step of the value-range
  lattice `07_optimize` deleted for measuring 0%.  **Type-derived
  bounds only**: they need no dataflow and cannot go stale.
- **`long × long` multiply-accumulate**, which needs a 128-bit product
  magnitude for its witness, and whose witness would fail on
  realistic data anyway.
- **`acc -= t`**, which is `acc += (−t)` except that `−INT64_MIN`
  traps, making it a distinct shape with a distinct proof.
- **`list` reductions**, until `list` indexing is inlined.
- **Integer whole-array operations in `std.math`**, which Layer 3
  wants and which do not exist; and an unordered float reduction,
  which is a language decision `std/math.luc`'s current promise
  forecloses.

---

# The plan

Sized honestly, and placed against the queue: map-upsert (a
`V?`-returning `m.get`, `docs/MISSING.md` item 6) is in flight, the
host surface still owes `exit` and `std.paths` [both shipped since
this was written — the queue moved, the ranking below did not], and
cross-compilation (item 8) is the largest backend item outstanding.  This work goes
**after the two small in-flight items and before cross-compilation**,
because `docs/MISSING.md`'s own summary says the runtime's outstanding
item is speed and names `strings` at 2.74× — and `arrays32` at 8.14×
is now the worse row by a factor of three.

**Step 0 — the ceiling. Half a day. Gates everything.**
Remove the overflow checks from `emitIntArithmetic` in a throwaway
branch, time `arrays32`, and confirm it approaches 6.2 ms.  Then add
the witness pass alone and time that.  If the first number does not
land, stop and find the real obstruction.

**Step 1 — Layer 1. Two to three days.**
Extract `08_llvm/cfg.zig` from `loops.zig` (`Graph`, `Loop`, `loops`,
`preheader`; a pure move, `loops.zig`'s five tests must stay green).
Add `08_llvm/reduce.zig`: the recognizer, the comptime width table
computed in `i128` from `heap.maxElements(element)`, and the
table-recomputation test.  Add `heap.maxElements`.  Teach `lower.zig`
to emit plain arithmetic for a planned reduction (~40 lines).  Add
`specs/vector_spec.zig` with the qualifying and refusal specs.  Add
`bench/arrays16.{luc,c}` and a `docs/CODEGEN.md` row, because
otherwise nothing about this step is measured.  **Moves no existing
benchmark row, and that is stated in the commit.**

**Step 2 — Layer 2. One to two weeks, and the risk is concentrated.**
The witness emission, the two-arm shape, the phi.  The hard part is
not the mathematics — it is above, and it is short — it is making
`lower.zig` emit *two* loops where it has only ever emitted one: the
`blocks: []BlockIndex` map holds only the first LLVM block of each IR
block (`lower.zig`'s `Body`), and every checked operation already
continues into blocks nothing jumps to.  Budget the block bookkeeping,
not the algebra.  Then the Layer 2 specs, then the thirteen-mutation
sweep, then a `docs/CODEGEN.md` snapshot with `arrays32` re-measured
and the prediction above marked kept or missed.

**Step 3 — Layer 3, with HIR (`docs/MISSING.md` item 12).**  Not
before.  When whole-array nodes exist they become a second front door
to Step 2's emitter, and the first integer whole-array operations in
`std.math` become worth writing.

**What success is.**  `arrays32` at ≈3× its C twin on the compute
column instead of 8.14×; `arrays16` at parity; every other row inside
2% under `bench/compare.sh`; 1187 tests plus the new specs green; and
the oracle still trapping on every element it traps on today, which is
the only number that was never negotiable.
