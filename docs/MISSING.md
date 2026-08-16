# Known bugs

This file tracks confirmed incorrect behavior in the current tree. A report
belongs here only when an existing contract, documented behavior, or supported
workflow is reproducibly wrong.

Feature requests, unratified design questions, broad coverage campaigns,
refactors, optimizations, and deliberate non-goals are not bugs and do not
belong in this file. Their owning references and decision records retain
that context.

Resolved bugs are removed from this file once the fix and its proof land.

## A damaged compiled module can panic the decoder/runtime path

The single-byte module-mutation hardening test in
`src/luce/06_mir/module.zig` is disabled by `totality_hardening_pending`.
Two mutated inputs can currently escape validation and panic: an invalid
`Value` tag reaches a Zig `switch`, and a decoded struct constant whose layout
and field count disagree can produce a short run that `struct_get` reads past.
The decoder/verifier must reject both shapes before execution. The mutation
test must be re-enabled and run to completion without a host-language panic.
