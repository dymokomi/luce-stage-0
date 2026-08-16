# Memory Management

Luce uses value semantics for values and automatic reference counting for
references. The compiler derives retains and releases from types and control
flow; source code has no ownership operations. The teaching chapter is
[Memory and ARC](/guide/memory/), and [Status](/status/) tracks future types.

## Kinds

### M1 — value types copy {#m1}

Numbers, `bool`, `string`, structs, enums, unions, and plain function values
are value types. Assignment, argument passing, and return copy the value.

A value may contain reference fields. Ordinary current paths copy the value
while making both copies name the same referenced object.

### M2 — built-in reference types share {#m2}

`list(T)`, `map(K, V)`, `array(T, ...)`, `builder`, `file`, and `task(...)` are
reference types. Assignment and ordinary calls share one runtime object.
Mutation through one reference is visible through the others. A `let` prevents
rebinding; it does not make the referenced object immutable.

### M3 — class is not a completed reference type {#m3}

`class` is a front-end scaffold. Current lowering still gives it value-struct
behavior. The intended class rules are design, not executable language.

## ARC operations

### M4 — creation starts with one strong reference {#m4}

A runtime-created container or resource starts with one strong reference. The
runtime exposes retain and release operations, and both execution paths can
execute their MIR instructions.

### M5 — every longer-lived reference is retained {#m5}

The compiler retains a reference stored in a binding, parameter, result,
aggregate field, optional, union, container element, interface witness, or
bound receiver.

### M6 — every abandoned place is released {#m6}

Old contents release on replacement. Locals release when control leaves them
through function return, `return`, `break`, `continue`, or recoverable-error
propagation.

### M7 — the last strong release destroys {#m7}

A zero strong count recursively releases contained references and destroys
the object. A file closes and an unfinished task joins on that same
last-release path.

### M8 — there are no source ownership operations {#m8}

`give`, `copy`, and `free` are not Luce keywords or built-ins. There is no
retain, release, borrow, move, clone, close, or manual-reference annotation in
a function signature.

An API constructs an independent value explicitly when it needs one. List
slices and `map.values()` create a new outer list: value elements copy and
reference elements are retained and remain shared. There is no universal
graph-clone expression.

## Aggregates and control flow

### M9 — aggregates follow their field types {#m9}

Structs, union payloads, optionals, multiple-return layouts, and receiver
layouts are values. Their value fields copy and their reference fields share.
The release walk releases each reference field exactly once.

### M10 — errors release the path they leave {#m10}

`try` must release abandoned locals before propagating a recoverable error. A
handled `catch` releases the failed result before its handler runs. Mutations
already performed through a shared reference remain; error handling is not a
transaction.

A final trap does not promise normal stack cleanup. It ends the run and is
accounted separately by the harness.

### M11 — constants live in the program root {#m11}

A file-scope constant list, map, or rank-one array is materialized once per
runtime in an immutable program root and reclaimed when the runtime ends. A
program cannot mutate it directly.

## Interfaces and function values

### M12 — interface dispatch retains carrying receivers {#m12}

The current interface layout stores one bound function per method. A
value-only concrete receiver is self-contained. Each dispatch value owns its
copied receiver and retains any references that receiver carries, so a stored
or returned interface may outlive the concrete binding that formed it.

The planned owned existential replaces this representation with one payload,
metadata, and witness table.

### M13 — bound methods own their receiver snapshot {#m13}

Reading `receiver.method` into a compatible function place copies the value
receiver. Later writes to the original value fields do not change the bound
snapshot. Reference fields still name the same objects and the bound value
retains them until it is destroyed.

Capture-free lambdas hold no enclosing-local environment.

## Workers and resources

### M14 — object identity never crosses a worker boundary {#m14}

Each worker has its own runtime. Values copy directly; permitted container
graphs are rebuilt recursively in the receiving runtime. The source and
destination share no object identity. A graph carrying a `file`, `task`, or
function value is refused as an argument or result.

The copier preserves aliases within one graph and across separate argument
roots. The caller keeps an independently mutable source graph. Allocation or
transitive-shape refusal rolls the incomplete destination graph back without
leaking either runtime.

`wait()` observes a task result once. Releasing the last task reference joins
an unfinished worker and discards its unobserved result.

## Implementation evidence

- Every successful differential specification requires zero live objects.
- File and ZIP lifecycle programs run on both engines with exact close
  behavior; unfinished tasks join at their last release.
- Bound methods and interface witnesses retain receiver references.
- List slices, `map.values()`, and array fill retain reference elements.
- Worker snapshots preserve aliases and cycles, leave the caller graph alive,
  and roll failed copies back.
- The damaged-module corpus rejects or cleanly runs every mutation without a
  host-language panic.

Changes to retain/release instructions or type tags require a module-format
bump. Changes to a published host-table representation require a host ABI
bump.
