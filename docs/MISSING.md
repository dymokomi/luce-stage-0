# Known bugs

This file tracks confirmed incorrect behavior in the current tree. A report
belongs here only when an existing contract, documented behavior, or supported
workflow is reproducibly wrong.

Feature requests, unratified design questions, broad coverage campaigns,
refactors, optimizations, and deliberate non-goals are not bugs and do not
belong in this file. Their owning references and decision records retain
that context.

Resolved bugs are removed from this file once the fix and its proof land.

## An early control-flow edge in `match` inside `for-in` can panic lowering

Two supported shapes reach `unreachable` in `src/luce/05_hir/lower.zig`
instead of compiling or reporting a diagnostic:

- a `try` in a `match` arm inside a `for-in` whose iterable is a fallible call
  reaches the `replayTry` temporary-floor assertion; and
- a `continue` in that nested arm reaches the corresponding
  `replayBreakContinue` assertion.

Hoisting the fallible iterable before the loop and avoiding an early edge in
the nested arm are current source rewrites, not fixes. Lowering must reconcile
the temporary ledger for every arm exit inside the loop, with differential
regressions for `try`, `return`, `break`, and `continue` rather than repairing
only the two shapes that happened to expose it.

## A damaged compiled module can panic the decoder/runtime path

The single-byte module-mutation hardening test in
`src/luce/06_mir/module.zig` is disabled by `totality_hardening_pending`.
Two mutated inputs can currently escape validation and panic: an invalid
`Value` tag reaches a Zig `switch`, and a decoded struct constant whose layout
and field count disagree can produce a short run that `struct_get` reads past.
The decoder/verifier must reject both shapes before execution. The mutation
test must be re-enabled and run to completion without a host-language panic.
