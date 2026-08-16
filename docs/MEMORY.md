# Memory — current ARC contract

Luce has value semantics for values and automatic reference counting for
references. The compiler derives every retain and release from types and
control flow; programs do not spell ownership operations. This page states
the behavior implemented by both execution paths, including classes and
capturing closures.

## The language contract

Every runtime value is either copied as a value or shared as a reference:

| Kind | Examples | Assignment and passing | Lifetime rule |
|---|---|---|---|
| Value | numbers, `bool`, `char`, `str`, `bytes`, `struct`, `enum`, `union` | copy the value | storage leaves with the containing value |
| Reference | `class`, `list`, `map`, `array`, `builder`, closure environments | retain and share one identity | last strong release destroys the object |
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
- graph-preserving worker snapshots with rollback;
- zeroing `weak` locals and fields for built-in ARC objects and classes, with owned
  upgrades and generation-safe object-table reuse; and
- final class identity, shared mutation, interface dispatch, and deterministic
  `deinit`;
- ARC closure environments, shared mutable cells, strong/weak/snapshot
  captures, nested closures, and returned function values; and
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

## What ARC deliberately does not do

ARC does not collect a strong cycle. A program must make at least one
back-edge weak when a graph would otherwise keep itself alive. The compiler
diagnoses the direct case where a class stores a closure that strongly
captures the same `self`; indirect application cycles remain the program's
responsibility.

The current interface representation is a hidden set of bound witnesses. It
owns struct receiver snapshots and retains class identities safely. A class
witness may mutate its shared object; a writing value-struct witness remains
refused until interfaces use one owned payload and a witness table.

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

A bound method copies a value receiver and retains reference fields in that
copy. A class bound method retains and shares its receiver identity. The
function value can therefore be returned or stored independently of the
original binding. A current interface value stores one bound witness per
method; a struct witness owns its receiver snapshot, while a class witness
retains the shared object.

Capturing closure environments are ARC objects. Immutable value captures are
snapshots, mutable local captures use one shared cell, and reference captures
are strong unless a capture list says `weak` or requests an explicit snapshot.
Copying a function value retains its environment; the last release destroys
the environment and releases each capture once.

## Workers

Each `spawn` creates a runtime and heap of its own. Scalars and value fields
copy directly. Permitted container graphs are rebuilt recursively in the
receiving runtime, preserving relationships within the copied graph but
sharing no object identity with the sender.

Resources, classes, function values, and values containing weak storage are
refused transitively. A weak handle, class identity, or closure environment
names one runtime's object table and therefore cannot be copied into another.
A worker may construct and destroy its own classes and closures inside its
private runtime. That boundary makes ordinary data races over Luce objects
unrepresentable without introducing a second ownership language.

## Cycles and weak references

ARC does not collect a strong cycle. `weak` makes a storage place non-owning:

```luce
struct Link:
    weak root: list[Link]?

func main():
    let root: list[Link] = [Link()]
    root[0].root = root
    let snapshot = root[0].root else [Link()]
    assert(len(snapshot) == 1)
```

A weak place always has an explicit optional type and initializes to `none`.
Current targets are `class`, `list`, `map`, `array`, and `builder`. Assigning a live
target records its handle without retaining it; assigning `none` clears the
place. After the target's last strong release, every later read answers
`none`, even if the object-table row is reused.

A successful read is an owned strong snapshot. It keeps the target alive for
the ordinary lifetime of that expression or binding. Because another strong
reference may disappear between reads, testing a weak place does not
permanently narrow it; bind one read and unwrap that snapshot before using it.

Weak storage is a property of a local or field, not a `weak[T]` value type.
Weak value types, resources, function values, interfaces, and ordinary value
structs are rejected as targets. A value containing a weak field has no
implicit equality or collection-search behavior, because the hidden handle is
not a semantic value. Weak handles never cross worker runtime tables.

Closure capture lists use the same weak path. `[weak name]` records a
non-owning reference in the closure environment and exposes an optional
snapshot inside the closure body. Interface values and resources are not weak
targets.

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
- Weak fields and locals break recursive container cycles, upgrade live
  targets to owned snapshots, zero after final release, and never revive when
  an object-table row is reused.
- Class aliases share mutation and identity; `deinit` runs once before fields
  release on success, recoverable error, trap unwinding, and worker-local
  teardown.
- Returned and nested closures retain immutable captures, share mutable cells,
  preserve function/interface dispatch, break object cycles with weak capture,
  and finish at zero live objects on both engines.
- The damaged-module corpus is total: reject or run cleanly, never panic.

A change to retain/release instructions or type tags bumps the module format.
A change to a published host-table representation bumps the host ABI.
