# Memory Management

Luce uses value semantics for values and automatic reference counting for
references. The compiler derives retains and releases from types and control
flow; source code has no ownership operations. [Memory and
ARC](/guide/memory/) is the teaching chapter.

## Kinds

### M1 — value types copy {#m1}

Numbers, `bool`, `char`, `str`, `bytes`, structs, enums, unions, and function
values are value types. Assignment, argument passing, and return copy the
value.

A value may contain references. Copying it copies value fields and retains
reference fields. A copied function value similarly retains its bound receiver
or captured ARC environment.

### M2 — reference types share {#m2}

Classes, `list[T]`, `map[K, V]`, `array[T, ...]`, `builder`, `file`, and
`task[...]` are reference types. Assignment and ordinary calls retain and
share one runtime object. Mutation through one reference is visible through
the others. A `let` prevents rebinding; it does not freeze the object.

### M3 — classes have identity and deterministic teardown {#m3}

A class reference names one ARC object. `is` compares two values of the same
nominal class type for identity. A class may declare one `deinit` body. The
last strong release runs that body exactly once while every field is live,
then releases the fields and storage.

`deinit` may inspect and mutate fields or call methods. It may not create a new
strong reference to its dying `self`; compile-time checks reject resurrection
and the runtime traps damaged MIR with `class_resurrection`.

### M3a — weak storage observes without owning {#m3a}

`weak var`, weak fields, and `[weak name]` closure captures hold an optional
class, list, map, array, or builder without retaining it. Weak locals start at
`none`; weak fields have an implicit `none` default. Assignment records a
generation-checked handle.

Reading a live weak place retains and answers an owned `T?` snapshot. Reading
after final strong release answers `none`. Reusing an object-table row cannot
revive the old handle. Weak storage is a place property, not a type, and
separate reads do not persistently narrow one another.

Weak targets exclude values, value structs, interfaces, function values,
files, and tasks. A value containing a weak field has no implicit equality or
collection-search semantics. Weak handles cannot cross worker runtimes.

## ARC operations

### M4 — creation starts with one strong reference {#m4}

A runtime-created container, class, closure environment, interface dispatch
value, or resource starts with one strong reference. Both execution paths use
the same runtime retain and release operations through MIR instructions.

### M5 — every longer-lived reference is retained {#m5}

The compiler retains a reference stored in a binding, parameter, result,
aggregate field, optional, union, container element, interface witness, bound
receiver, or closure environment.

### M6 — every abandoned place is released {#m6}

Old contents release on replacement. Locals and temporaries release when
control leaves them through fallthrough, function return, `return`, `break`,
`continue`, or recoverable-error propagation.

### M7 — the last strong release destroys {#m7}

A zero strong count recursively releases contained references and destroys
the object. A class runs `deinit`; a file closes; an unfinished task joins and
discards an unobserved result; a closure releases every capture.

### M8 — there are no source ownership operations {#m8}

`give`, `copy`, and `free` are not Luce keywords or built-ins. There is no
retain, release, borrow, move, clone, close, or manual-reference annotation in
a function signature.

An API constructs an independent outer object explicitly when it needs one.
List slices and `map.values()` create a new list: value elements copy and
reference elements are retained and remain shared. There is no universal
graph-clone expression.

## Aggregates and control flow

### M9 — aggregates follow their field types {#m9}

Structs, union payloads, optionals, multiple-return layouts, receiver layouts,
and class storage retain every reference field and copy every value field as
their own kind requires. A teardown walk releases each owned reference exactly
once.

### M10 — errors release the path they leave {#m10}

`try` releases abandoned locals before propagating a recoverable error. A
handled `catch` releases the failed result before its handler runs. Mutations
already performed through a shared reference remain; error handling is not a
transaction. Class `deinit` bodies run as the final releases unwind.

A final trap does not promise normal stack cleanup. It ends the run and is
accounted separately by the harness.

### M11 — constants live in the program root {#m11}

A file-scope constant list, map, or rank-one array is materialized once per
runtime in an immutable program root and reclaimed when the runtime ends. A
program cannot mutate it directly or through hidden provenance.

## Interfaces and function values

### M12 — interface dispatch owns its receiver {#m12}

An interface value stores one owned payload and a static witness identity. A
structure conformer is copied into that payload and its reference fields are
retained. A class conformer retains the shared class identity, so a mutable
class witness changes the same object every alias observes. A `mutating`
requirement permits a writing value-struct witness; the call must name a
mutable bare local so the updated payload can be written back.

A stored or returned interface may outlive the concrete binding that formed
it. Copying the interface retains the payload's reachable objects, and the
last copy releases them.

### M13 — bound methods and closures own their environments {#m13}

Reading `receiver.method` into a compatible function place copies a structure
receiver or retains a class receiver. Reference fields in a structure snapshot
remain shared and retained. Later value-field writes do not change a structure
snapshot; later class mutation is visible through the bound method.

An expression lambda has no environment. A block closure owns an ARC
environment. Immutable captures are retained snapshots; captured mutable
locals share one promoted cell with the declaring scope and sibling closures.
Snapshot capture-list expressions evaluate once at creation. Weak captures use
M3a. Releasing the last function value releases the environment.

## Workers and resources

### M14 — object identity never crosses a worker boundary {#m14}

Each worker has its own runtime. Values copy directly; permitted container
graphs are rebuilt recursively in the receiving runtime. The source and
destination share no object identity. A graph carrying a class, `file`,
`task`, function value, interface, or weak field is refused as an argument or
result. A worker may construct and use those values locally.

The copier preserves aliases within one graph and across separate argument
roots. The caller keeps an independently mutable source graph. Allocation or
transitive-shape refusal rolls the incomplete destination graph back without
leaking either runtime.

`wait()` observes a task result once. Releasing the last task reference joins
an unfinished worker and discards its unobserved result.

## Implementation evidence

- Every successful differential specification requires zero live objects.
- Class aliases, identity, nested mutation, interfaces, weak edges, errors,
  `deinit`, and resurrection refusals agree on both engines.
- Closure environments, shared cells, snapshot and weak captures, nested
  closures, storage, bound receivers, and error paths agree on both engines.
- File and ZIP lifecycle programs close exactly once; unfinished tasks join at
  their last release.
- List slices, `map.values()`, and array fill retain reference elements.
- Worker snapshots preserve aliases and cycles, leave the caller graph alive,
  and roll failed copies back.
- Weak storage upgrades live reads, zeroes after final release, and cannot
  revive on object-table reuse.
- The damaged-module corpus rejects or cleanly runs every mutation without a
  host-language panic.

Changes to retain/release instructions or type tags require a module-format
bump. Changes to a published host-table representation require a host ABI
bump.
