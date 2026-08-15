# Known bugs

This file tracks confirmed incorrect behavior in the current tree. A report
belongs here only when an existing contract, documented behavior, or supported
workflow is reproducibly wrong.

Feature requests, unratified design questions, broad coverage campaigns,
refactors, optimizations, and deliberate non-goals are not bugs and do not
belong in this file. Their owning references and decision records retain
that context.

Resolved bugs are removed from this file once the fix and its proof land.

## A `try` inside a `match` arm inside a `for-in` loop panics the compiler

A fallible call written directly as the iterable of a `for-in` loop and then
used with a `try` inside a `match` arm — the shape
`for e in files.entries(...)` where the body `match`es `e` and calls `try`
in an arm — reaches `unreachable` in `src/luce/05_hir/lower.zig` (`replayTry`,
a `temps_floor` assertion) rather than compiling or reporting a diagnostic.
Binding the fallible result to a `let` before the loop is a working
rewrite. The lowering must handle a `try` whose temporary floor is opened
inside a loop-and-match nest.
