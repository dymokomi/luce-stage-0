# Memory — current ARC contract

Luce has value semantics for values and automatic reference counting for
references. The compiler derives every retain and release from types and
control flow; programs do not spell ownership operations. This page states
the behavior implemented by both execution paths and the limits that remain
for future types.

## The language contract

Every runtime value is either copied as a value or shared as a reference:

| Kind | Current and planned examples | Assignment and passing | Lifetime rule |
|---|---|---|---|
| Value | numbers, `bool`, `string`, `struct`, `enum`, `union` | copy the value | storage leaves with the containing value |
| Reference | `list`, `map`, `array`, `builder`; future `class` and closure environments | retain and share one identity | last strong release destroys the object |
| Resource reference | `file`, `task`, windows, surfaces | retain and share one identity | last strong release closes, joins, or releases the resource |

There are no source-level retain, release, move, clone, borrow, or free
operations. The compiler derives every retain and release from the static type
and control-flow edge.

The rule users need is:

> Values copy. References share identity. ARC keeps references alive. Weak
> breaks cycles. Resources close at the last strong release. Workers never
> share object identity.

## What is implemented

The current tree implements ARC for every built-in reference and resource:

- runtime reference counts and `retain`/`release` operations;
- MIR instructions verified and executed by both the interpreter and LLVM
  path;
- shared reference behavior for assignment, arguments, and returns;
- retain/release emission across locals, replacement, aggregates, optionals,
  unions, failures, loops, interfaces, bound methods, and container stores;
- last-release close for files and join for unfinished tasks;
- graph-preserving worker snapshots with rollback; and
- a zero-live-object gate for every successful differential spec.

For example, both names below observe one list:

```luce
func main():
    let first = [1, 2]
    let second = first
    second.append(3)
    print(str(len(first)))
```

A struct remains a value when it contains a reference. Copying the struct
copies value fields and makes its reference fields name the same objects.
The differential specifications exercise that behavior on both engines.
Malformed serialized modules are separately required to be rejected or run
to a clean outcome without a host-language panic.

## What remains outside the current model

ARC does not collect a strong cycle. Luce does not yet have `weak`, so a
program must avoid strong back-edges in recursive container graphs. Classes
and capturing closures are future reference types; they do not weaken the
current built-in ARC contract. The current interface representation is safe
for read-only dispatch but will be replaced before mutable class dispatch.

## ARC behavior

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
the original binding. A current interface value stores one such bound witness
per method; every witness owns its receiver snapshot safely. The planned
existential representation stores one payload plus metadata and a witness
table, avoiding repeated receiver storage and enabling mutable dispatch.

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

## Release-gate evidence

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
