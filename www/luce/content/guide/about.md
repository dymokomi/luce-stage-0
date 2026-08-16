# About Luce

Luce is a small, statically typed language for native programs that should be
easy to read and predictable to run. Its indentation and everyday expression
syntax are familiar to Python programmers, while types, failure, effects, and
object identity remain visible in source.

The goal is not to collect every feature found in another language. It is to
make the common path pleasant without hiding the rules that matter when a
program grows.

## Familiar source, checked meaning

A Luce program uses indentation for blocks, `let` and `var` for bindings, and
ordinary `if`, `for`, and `while` statements:

```luce run
import std.strings

func average(values: list[f64]) -> f64?:
    if len(values) == 0:
        return none
    var total: f64 = 0.0
    for value in values:
        total += value
    return total / f64(len(values))

func main():
    let score = average([8.0, 9.5, 10.0]) else 0.0
    print(f"average {score:.1f}")
```

```output
average 9.2
```

The surface is concise, but the compiler does not guess about representation:
`f64` states the width, `list[f64]` states the element type, and `f64?` states
that an answer may be absent. A condition must be `bool`; numbers and strings
do not acquire truthiness. Changing numeric width or signedness is explicit.

These rules are intended to make code easier to review. The type annotation
at a boundary is also a compact description of what callers may rely on.

## Values and identity

Luce has one memory rule:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.

Numbers, text, bytes, structures, enumerations, and unions are values. Lists,
maps, arrays, classes, files, tasks, windows, and GPU surfaces are references.
A value can contain a reference: copying the outer value copies its own fields
and retains the referenced object.

There are no source-level retain, release, borrow, clone, or free operations.
The compiler inserts ARC operations from the concrete type and control flow.
When shared identity is useful, declare a final `class`; when independent
copies are useful, declare a `struct`. The difference is a design choice in
the type declaration rather than a surprise at a call site.

[Structures](/guide/structures/), [Classes](/guide/classes/), and [Memory and
ARC](/guide/memory/) build this model in stages.

## Absence, failure, and traps

Luce gives three different outcomes three different forms:

- `T?` means a value may be absent and there is no failure to explain;
- `T!` means a valid operation can fail and carries a reason; and
- a trap means the program violated a checked precondition or cannot continue
  safely.

An empty search result is absence. A file the operating system refuses to
open is a recoverable error. An out-of-bounds index is a trap. Keeping these
separate makes the caller’s responsibility visible: narrow or provide a
fallback for absence, `try` or `catch` a recoverable error, and fix a trap in
the program.

## Effects cross one boundary

Printing, environment access, clocks, files, terminals, workers, windows, and
GPU drawing are explicit host effects. They pass through one versioned host
table rather than allowing the compiler or standard library to reach the
machine through unrelated paths.

A missing host service traps `host_unavailable`. Hosted standard-library APIs
use ordinary `T!` results when the world can refuse a request. Pure modules,
such as path manipulation or most string operations, remain ordinary Luce
source.

This separation keeps programs testable. The differential specifications can
give both execution engines the same scripted host and compare output,
errors, traps, resources, and the final live-object census.

## Concurrency without shared objects

`spawn` starts a named function in a worker with its own runtime and heap.
Permitted values and container graphs are copied into that runtime; aliases
inside the graph remain aliases, but no object identity is shared with the
caller. `wait()` copies the answer back and joins the worker.

The model intentionally omits a shared heap, locks, atomics, and asynchronous
function coloring. A class or live resource does not cross a worker boundary.
This is a smaller concurrency model whose ordinary object programs cannot
contain data races.

## A deliberately bounded language

Luce currently has no class inheritance, interface default methods, operator
overloading, unsafe pointers, reflection, macros, tracing garbage collector,
or shared mutable worker state. User-defined generics are planned but not
implemented. Interfaces are usable today; one representation improvement is
still planned before writing structure methods can dispatch through them.

Those boundaries are documented because a user should never have to infer
whether a missing feature is unsupported, unfinished, or merely hidden in a
different spelling. [Status](/status/) is the dated public inventory, and the
repository’s bug ledger contains reproduced bugs only.

## How to read this book

The [Tour](/tour/) shows the whole language in one sitting. The Language Guide
then teaches one idea at a time, in the order the ideas depend on each other.
Examples begin with the common case, explain the choice being made, and then
cover mutation, lifetime, failure, and common mistakes where they become
relevant.

The Language Reference at the end of this same Guide is intentionally dry. Use
it when you need the exact grammar, precedence, type form, diagnostic, or
memory rule. Imported APIs live in the [Library](/library/), while installation,
the compiler, editor, packages, and tests live under [Tools](/tools/).

Continue with [Version Compatibility](/guide/compatibility/) if you are
installing a pre-1.0 release, or go directly to [The Basics](/guide/basics/) to
write a program.
