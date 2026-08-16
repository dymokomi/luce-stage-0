# Memory Management

Luce is moving from explicit single-owner operations to automatic reference
counting. The source syntax has completed that pivot; the implementation has
not completed every last-release path. This page states both the current
behavior and the contract that must be proved before ARC is marked complete.
The teaching chapter is [Memory and ARC](/guide/memory/), and [Status](/status/)
tracks the ordered work.

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

### M5 — retaining every longer-lived reference is incomplete {#m5}

The completed contract retains a reference stored in a binding, parameter,
result, aggregate field, optional, container element, interface payload, or
bound receiver. Many ordinary paths do this today, but current bound methods
do not retain reference fields inside their receiver copy.

### M6 — releasing every abandoned place is incomplete {#m6}

The completed contract releases old contents on replacement and releases
locals left by scope exit, `return`, `break`, `continue`, and recoverable-error
propagation. Current common paths are wired, but the repository still disables
reclamation and file-lifecycle tests around missing edges.

### M7 — last-release destruction is the target gate {#m7}

The required rule is that a zero strong count recursively releases contained
references and destroys the object. A file closes and an unfinished task joins
on that same last-release path.

Do not depend on exact mid-run file close or task join timing in the current
development build. Runtime teardown remains a backstop while Phase 0 closes
the skipped lifecycle tests.

### M8 — there are no source ownership operations {#m8}

`give`, `copy`, and `free` are not Luce keywords or built-ins. There is no
retain, release, borrow, move, clone, close, or manual-reference annotation in
a function signature.

An API constructs an independent value explicitly when it needs one. Current
list slices and `map.values()` recursively copy copyable reference elements;
the completed ARC collection rule will retain those elements instead. There is
no universal graph-clone expression.

## Aggregates and control flow

### M9 — aggregates follow their field types {#m9}

Structs, union payloads, optionals, multiple-return layouts, and receiver
layouts are values. Their value fields copy and their reference fields share.
The completed release walk releases each reference field exactly once.

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

## Current completion blockers

- Four byte/zip tests are skipped by `resource_close_pending`.
- Two language specs relax their zero-live-object assertion.
- An early edge from `match` inside `for-in` can panic HIR lowering.
- The damaged-module mutation test is skipped around verifier panic paths.

ARC is complete only when those gates are removed, all normal differential
specs end with zero live objects, resource close/join counts are exact, and the
damaged-module corpus rejects or runs every mutation without a host panic.

Changes to retain/release instructions or type tags require a module-format
bump. Changes to a published host-table representation require a host ABI
bump.
