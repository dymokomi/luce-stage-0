# Checked reduction vectorization

> **Status: future work.** Luce does not yet vectorize checked integer
> reductions. This plan states the semantic boundary and the smallest design
> that could cross it without weakening the language.

The motivating case is `bench/arrays32`: an `i32` multiply-accumulate loop is
substantially slower than its C twin because every multiplication and addition
has an overflow edge. LLVM cannot vectorize a loop with that value-dependent
side exit.

This is not a reason to make arithmetic wrap. It is a reason to represent the
reduction honestly enough that both engines can preserve checked semantics
while the compiled engine uses vector hardware.

## The contract

Every implementation must preserve all of these facts:

- `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, and `i64` compute at their
  own width;
- concrete operands must have the same type; there is no implicit widening;
- overflow traps with `integer_overflow` at the first source operation that
  overflows;
- a debug build reports the same source location and call trace as the scalar
  program;
- the interpreter and compiled path receive the same verified MIR and agree on
  output, traps, host effects, and the final ARC census; and
- floating reductions keep source order. Reassociation would change IEEE
  results and is outside this plan.

The exact trap point rules out a late range check. A sum can leave a type's
range and later return to it; checking only the final value would miss the
required trap.

## What exists now

`runtime/heap.zig` exposes `maxElements(kind)`. Most element kinds are limited
only by addressable byte size and available memory. Narrow integer kinds also
carry a proof ceiling: the largest element count for which a specific
type-derived magnitude bound still fits in `i64`.

The current proof rows are:

| Element kind | Bound represented by the ceiling |
|---|---|
| `u8` | `N × (255 × 32768) <= max(i64)` |
| `i8` | `N × (128 × 128) <= max(i64)` |
| `u16` | `N × (max(u16)²) <= max(i64)` |
| `i16` | `N × 2³⁰ <= max(i64)` |
| `u32` | `N × max(u32) <= max(i64)` |
| `i32` | `N × 2³¹ <= max(i64)` |

These ceilings are computed in `i128`, tested independently in
`runtime/test.zig`, and enforced before allocation. They are a foundation for
proofs, not evidence that vectorization already exists. `u64` and `i64` have no
useful whole-domain reduction proof, so address space and memory remain their
only container limits.

Arrays are the first target. Their storage is contiguous and compiled indexing
is inline. Lists are excluded until their moving buffer and runtime indexing no
longer obscure the loop from the optimizer.

## Representation before optimization

Do not teach LLVM lowering to recognize a source-looking instruction pattern.
That would give the compiled path a semantic construct the interpreter cannot
see.

Add one verified MIR operation for a checked reduction only after the optimizer
has proved the complete loop shape. The operation must carry:

- operation (`add`, or multiply-then-add when that form is implemented);
- exact element and accumulator types;
- array and range registers;
- initial accumulator;
- source origin for each operation that can trap; and
- the proof kind, or an explicit request for checked replay.

The verifier must reject mismatched widths, non-array storage, mutable aliases,
fallible callbacks, invalid ranges, unsupported operations, and proof claims
that do not follow from the element kind and container ceiling.

Adding the operation changes serialized MIR and therefore bumps
`mir.module.format_version`. It does not change the host ABI.

## Recognition

The first recognizer should accept only a canonical counted loop:

```text
var total: A = initial
for index in range(0, len(values)):
    total += expression(values[index])
```

Acceptance requires all of the following:

- one induction variable and one accumulator;
- a range tied to the same array being indexed;
- no write to the array, accumulator alias, host effect, call, worker action,
  or fallible operation inside the loop;
- no observable value from a partial iteration other than the accumulator;
- an exact supported operation tree; and
- a proof derived from type bounds and `maxElements`, never guessed from
  profiling or an unverified annotation.

Everything else remains ordinary scalar MIR. A narrow recognizer is useful; a
recognizer that is almost right changes semantics.

## Two lowering strategies

### Proven-safe reduction

When the full-domain bound proves that no prefix can overflow, LLVM lowering
may emit ordinary integer operations and a vector reduction. The interpreter
executes the MIR operation scalarly. The proof—not backend optimism—is what
makes both implementations equivalent.

No `nsw` shortcut is needed. Where overflow is impossible, ordinary fixed-width
addition already has the required result; where overflow is possible, `nsw`
would be a lie.

### Checked fast path with replay

Useful `i32 × i32` dot products cannot be proven safe over the full domains. A
later implementation may process a chunk with widened vector lanes, detect
whether the chunk could contain the first overflow, and replay only that chunk
scalarly from its entry accumulator. Replay is what recovers the exact source
operation and element.

This path is acceptable only after a proof shows that the vector witness cannot
miss cancellation or cross-lane prefix overflow. If that proof is not simple
and reviewable, keep the loop scalar.

## Tests that make the feature real

The implementation is incomplete until all of these are present:

- optimizer unit tests for every accepted shape and every near miss;
- verifier tests for forged reduction instructions and forged proof kinds;
- differential programs for every integer width, empty and one-element arrays,
  positive and negative inputs, exact limits, and each overflow direction;
- tests that identify the first trapping element after cancellation;
- source-location and call-trace agreement on a replayed trap;
- ARC and aliasing cases proving no retained array or closure escapes;
- module round-trip and hostile-byte mutation coverage;
- emitted-IR or assembly evidence that the proven-safe case actually
  vectorizes; and
- benchmark results recorded beside the existing benchmark table, including
  regressions on non-reduction loops.

The differential suite proves semantics. The emitted-code check proves the
optimization happened. Both are required.

## Refused shortcuts

- wrapping arithmetic, saturating arithmetic, or a release-only semantic mode;
- widening an accumulator behind the user's back and checking once at the end;
- fast-math or reassociation for floating reductions;
- backend-only pattern recognition;
- profile-guided claims that overflow is unlikely;
- a user annotation that bypasses verification; and
- list reductions before list indexing has an optimizer-visible stable shape.

## Exit condition

The first milestone is complete when one narrow, proven-safe array reduction
uses vector instructions on supported targets, both engines still agree on the
entire checked-arithmetic corpus, hostile MIR is refused, exact trap locations
remain stable, and the benchmark demonstrates a material improvement without a
regression elsewhere.
