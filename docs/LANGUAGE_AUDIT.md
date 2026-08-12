# Luce language audit

Status: living review index, started 2026-08-12.

This document turns the language into a set of reviewable paths.  A
feature is not complete because its happy-path syntax works: its value,
ownership, failure, and host implications must be settled at the same
semantic seam, lowered on both execution paths, and exercised at the
boundaries where the representation changes.

The design rule behind the audit is simple: the analyzer decides meaning,
`src/luce/runtime/` owns dynamic semantics, and the interpreter and LLVM
backend are two consumers of those decisions.  A fix belongs at the
earliest layer that can state the invariant, with later layers retaining a
cheap backstop rather than a second policy.

## Pipeline review

Every feature should be walked through this sequence:

```text
source bytes
  -> lex / parse
  -> semantic analysis and flow
  -> typed tree / MIR
  -> verifier and optimization
  -> interpreter + LLVM lowering
  -> shared runtime / host effects
```

The useful question at each arrow is “what is the first layer that can
reject this, and what proves that the next layer cannot receive it?”

| Failure or invariant | First authority | Later proof | Test shape |
|---|---|---|---|
| Bad bytes, tokens, or grammar | `01_source`–`03_parse` | recovery and diagnostic rendering | malformed fragments and source spans |
| Names, types, flow, ownership verbs | `04_semantics` | typed nodes and MIR types | accepted programs plus one diagnostic per refusal |
| Damaged or hand-written modules | `06_mir/verify.zig` | total LLVM/interpreter dispatch | decode/verify hostile module fixtures |
| Dynamic bounds, stale handles, ownership cycles | `runtime/` | trap code/message on both engines | direct runtime tests and Luce specs |
| Allocation failure and partial construction | runtime operation’s transaction | allocator-failure matrix | failing allocator around every allocating door |
| Interpreter/compiled divergence | `src/luce/specs/agree.zig` | prints, ending, trace, leaks, world | every runnable Luce spec on both engines |
| Host state divergence | `specs/hosts.zig` and `sameWorld` | complete file/task/world snapshot | effect transcript plus handle/open-state checks |

## Hardening pass — 2026-08-12

The first test-led slice concentrates on the union/function-value seam, where
one value can carry a tagged payload, an optional callback, and a borrowed
bound receiver at the same time.

- `union_spec.zig` copies a list of unions containing optional function
  values, dispatches both the present and absent choices, and traps through a
  callback while the union still owns a list payload.
- `binding_spec.zig` copies a list containing a union-held bound method and
  proves both copies see the receiver's later mutation; a second case proves
  that a borrowed receiver reports `use_after_free` at invocation time.
- `runtime/test.zig` runs the allocation-failure matrix across a function
  run, its carrying receiver, and outside string storage.
- `06_mir/module.zig` serializes hostile bound values with an out-of-range or
  wrong-typed receiver register and proves the verifier refuses both before
  either engine can execute them.

These probes are deliberately split across the source, runtime, and module
boundaries.  They do not make bound receivers owning or introduce captured
closures; they pin the current borrowing contract while those future designs
remain open in `MISSING.md`.

## Feature matrix

The “composition probes” column is deliberately more interesting than a
list of isolated examples.  These are the cases most likely to expose a
boundary that has acquired a special case.

| Feature | Positive behavior to keep | Adversarial boundaries | Composition probes | Current test anchor |
|---|---|---|---|---|
| Numerics | landing-directed literals, promotion, checked arithmetic, floor pair | min/max literals, zero divisors, overflow, non-finite literals, float `%`, large trig inputs | numeric fields in structs/unions and numeric callbacks | `numeric_spec.zig`, `runtime/operators.zig` |
| Strings | UTF-8 values, inline/outside storage, methods and formatting | empty text, continuation-byte offsets, empty needle, replacement no-op, long-lived copies | strings in maps, struct fields, union payloads, bound methods | `std_spec.zig`, `runtime/test.zig` |
| Lists and arrays | packed storage, value storage, indexing, iteration, slices | empty/pop/index bounds, retained capacity, rank/shape mismatch, deep graphs | lists of structs/unions/functions; arrays of optional values | `containers_spec.zig`, `runtime/test.zig` |
| Maps and builders | insertion order, typed keys/values, byte construction | missing keys, duplicate keys, empty maps, failed insertion, builder/string ownership | maps of unions/function values; `values()` followed by mutation | `containers_spec.zig`, `runtime/test.zig` |
| Struct values | defaults, nested places, field reads/writes, value copying | missing required fields, cycles, partial construction, private fields | struct containing union/list/function/file/task | `structs_spec.zig`, `binding_spec.zig` |
| Enums, unions, optionals | exhaustive match, payload aliases, `T?` absence | missing arm, wrong payload binding, nested absence, invalid discriminant | union payload list passed to a method with optional callback | `enums_spec.zig`, `unions_spec.zig`, `binding_spec.zig` |
| Functions and methods | exact signatures, lambdas, bound receiver, optional function slots | untyped function landing, arity/type mismatch, no-capture rule, receiver lifetime | union payload method plus stored callback; function field in a copied struct | `functions_spec.zig`, `binding_spec.zig` |
| Ownership and copy | scope release, `give`, `free`, deep copy, container adoption | stale handles, direct/indirect cycles, alias after move, partial-copy rollback, deep release | copied list/map/array of nested structs and resources | `ownership_spec.zig`, `runtime/test.zig` |
| Errors, traps, exit | `T!`, `try`/`catch`, trap trace, explicit exit | uncaught error, trap after output, release during unwind, exhaustion | failure in a nested union/method call with live objects | `errors_spec.zig`, `agree.zig` |
| Files and workers | host-gated files, task ownership, join at scope end | open/read/write refusal, stale/closed handle, child failure, join order | file/task nested in struct or attempted cross-runtime transfer | `files_spec.zig`, `threads_spec.zig`, `hosts.zig` |
| Constants and packages | folded scalar/container constants, isolated imports | empty/invalid constant shapes, visibility, version ambiguity | constant union/struct values passed through a function value | `constants_spec.zig`, `packages_spec.zig` |
| Artifact and dual engines | verified module, same runtime semantics, complete host ABI | wrong format/ABI/machine, damaged MIR, backend unsupported tag | every feature above through interpreter and compiled artifact | `agree.zig`, `06_mir/verify.zig`, `08_llvm/` |

## Review protocol for a new feature

Before calling a feature complete, add or locate all of these:

1. One ordinary program showing the smallest useful behavior.
2. Boundary programs for empty, maximum, missing, moved, aliased, and
   failure states where those states make sense.
3. At least one composition program crossing its ownership and value
   boundaries with another feature.
4. A semantic rejection at the earliest layer that has enough information,
   plus a runtime/verifier backstop only where malformed input can bypass
   that layer.
5. An allocation-failure or partial-construction test for every operation
   that publishes a new object or stores owned value data.
6. A differential spec whenever the behavior is observable from Luce.

The audit is not a promise that every open design choice should be
implemented.  The current deliberate remainder is in `MISSING.md`: typed
channels, fallible function types, owning bound methods, the large-angle
`sin`/`cos` decision, assertion narrowing, escape additions, direct string
iteration, and a few library/type-surface questions.  Those need decisions
before code, not increasingly clever patches.

## Invariants worth preserving during refactors

- A container owns its stored object graph; a function value borrows its
  receiver graph.
- A copy or cross-runtime move is transactional: a failure leaves the
  destination's live rows, free rows, and owned storage consistent.
- Runtime release and graph walks do not depend on native stack depth.
- `agree` compares ending status, diagnostics, trace, leak census, and host
  world—not just printed bytes.
- One semantic rule has one owner.  A backend optimization may specialize
  representation, but it must not invent language behavior.
