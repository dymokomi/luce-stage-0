# Memory — current ARC transition and final contract

This document separates what the compiler proves today from the memory model
Luce is committed to finishing. That distinction is load-bearing: source-level
manual ownership has been removed, but last-release reclamation is not yet
complete on every path. The ordered completion work is Phase 0 of
[ROADMAP.md](ROADMAP.md).

## The language contract

Every runtime value is either copied as a value or shared as a reference:

| Kind | Current and planned examples | Assignment and passing | Completed lifetime rule |
|---|---|---|---|
| Value | numbers, `bool`, `string`, `struct`, `enum`, `union` | copy the value | storage leaves with the containing value |
| Reference | `list`, `map`, `array`, `builder`; future `class` and closure environments | retain and share one identity | last strong release destroys the object |
| Resource reference | `file`, `task`, windows, surfaces | retain and share one identity | last strong release closes, joins, or releases the resource |

There are no source-level retain, release, move, clone, borrow, or free
operations. A completed compiler derives every retain and release from the
static type and control-flow edge.

The sentence users should eventually need is:

> Values copy. References share identity. ARC keeps references alive. Weak
> breaks cycles. Resources close at the last strong release. Workers never
> share object identity.

## What is implemented now

The current tree has the structural pieces of ARC:

- runtime reference counts and `retain`/`release` operations;
- MIR instructions verified and executed by both the interpreter and LLVM
  path;
- shared reference behavior for ordinary assignment and calls;
- retain/release emission across many locals, replacements, returns,
  aggregates, optionals, errors, loops, and container stores; and
- a zero-live-object gate for ordinary differential specs.

For example, both names below observe one list:

```luce
func main():
    let first = [1, 2]
    let second = first
    second.append(3)
    print(string(len(first)))
```

A struct remains a value when it contains a reference. Copying the struct
copies value fields and makes its reference fields name the same objects.
Current common-path specs exercise that behavior on both engines.

## What is not implemented completely

The repository itself records these open gaps:

- Four byte/zip file tests are skipped behind `resource_close_pending`
  because function-exit cleanup does not reliably close the handle yet.
- The synthesized Luce test entry and the adventure specification relax their
  zero-census assertion around remaining container reclamation gaps.
- An early control-flow edge in a `match` nested inside `for-in` can panic HIR
  lowering instead of compiling or reporting a diagnostic.
- The module damage hardening test is skipped around two decoder/verifier
  panic paths; [MISSING.md](MISSING.md) tracks the bug.

Until Phase 0 closes these gaps, code must not rely on a file closing at the
exact last-release point. Runtime teardown is a backstop, not proof that
mid-run ARC is complete. Public documentation must not describe the
implementation as release-ready ARC.

## Completed ARC behavior

When Phase 0 exits, the following rules hold without qualification.

### Calls, returns, and replacement

Passing a value gives the callee a value copy. Passing a reference retains the
same object for the callee's lifetime. Returning follows the same type rule.

Replacing a `var` releases its old reference before storing the new one.
Temporaries release at the end of their statement unless a longer-lived place
retains them. `return`, `break`, `continue`, and recoverable-error propagation
release every local they leave behind.

The optimizer may remove a retain/release pair only when doing so cannot
change destruction order, resource behavior, traps, or another observable
result.

### Aggregates and collections

Copying a value aggregate recursively copies value storage and retains every
reference field. Storing a reference in a field, optional, union payload,
list, map, or array retains it. Removing or replacing that place releases it.

A list slice and `map.values()` create a new outer list. Value elements copy;
reference elements retain and remain shared. There is no universal graph clone
operator. The worker boundary is the deliberate exception: it recursively
rebuilds a permitted graph in another runtime because identity cannot be
shared between workers.

### Resources

`file` and `task` use the same strong count as other references. The last file
release closes its host handle. The last release of an unfinished task joins
its worker. `task.wait()` observes the result once; task aliases share that
one-shot state.

### Bound methods, interfaces, and closures

A bound method copies its value receiver and retains reference fields in that
copy. The function value can therefore be returned or stored independently of
the original binding. A completed interface existential owns one payload and
uses metadata plus a witness table; it follows the payload's value/reference
semantics without duplicating the receiver once per method.

Capturing closure environments are ARC objects. Immutable value captures are
snapshots, mutable local captures use a shared cell, and reference captures
are strong unless a capture list says `weak` or requests an explicit snapshot.

## Workers

Each `spawn` creates a runtime and heap of its own. Scalars and value fields
copy directly. Permitted container graphs are rebuilt recursively in the
receiving runtime, preserving relationships within the copied graph but
sharing no object identity with the sender.

Resources and function values are refused transitively. Future classes, weak
references, and capturing closure environments are non-sendable in this
milestone. That boundary makes ordinary data races over Luce objects
unrepresentable without introducing a second ownership language.

## Cycles and weak references

ARC does not collect a strong cycle. A recursive struct can already form one
through a container, although the current language has no `weak` syntax to
break it. The target weak storage therefore covers built-in ARC objects as
well as classes and reference-backed interface values. Resources and function
values stay strong-only in the first model. Classes and capturing closures
make back-edges common, so `weak` must ship before those features are called
complete. Debug leak reporting must make an accidental surviving cycle
diagnosable rather than silently treating it as collection.

## Proof required to call ARC complete

- No feature-related test skip or relaxed leak assertion remains.
- Every normal differential spec ends with zero live objects.
- Direct runtime tests cover exact reference counts and destruction order.
- Files close and unfinished tasks join exactly once at the last release.
- Success, error, trap, allocation rollback, worker transfer, and teardown all
  release the correct graph on both engines.
- A worker argument copy leaves the caller graph live and independently
  mutable, with zero leaked objects across both runtimes.
- Bound methods and interface values keep carrying receivers alive.
- Slices of lists, map value lists, and array fill obey ordinary ARC element
  semantics.
- The damaged-module corpus is total: reject or run cleanly, never panic.

A change to retain/release instructions or type tags bumps the module format.
A change to a published host-table representation bumps the host ABI.
