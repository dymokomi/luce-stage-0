# Threads — workers own their world

Luce workers share no mutable Luce object. `spawn` starts a named function on
an OS thread with its own `Runtime`: heap, program roots, scopes, trap channel,
and call-depth budget. `wait()` is the single point that joins the worker and
observes its answer.

The important boundary is not “references cannot cross.” Copyable reference
graphs do cross. They are rebuilt in the receiving runtime, so their identity
does not cross and no object is reachable from both threads.

The worker boundary and explicit `wait()` behavior are implemented, but a
current ARC bug in container-argument transfer can invalidate the caller's
reference and leak the transferred object. Automatic join at the task's exact
last release is also part of the incomplete ARC lifecycle gate described in
`docs/MEMORY.md`.

## Spawning

`spawn f(args)` evaluates the arguments in the caller, copies the permitted
argument graph into a new runtime, starts `f`, and answers a `task`:

```luce
func sum_to(limit: long) -> long:
    var total: long = 0
    for value in range(1, limit + 1):
        total += value
    return total

func main():
    let first = spawn sum_to(1000000)
    let second = spawn sum_to(2000000)
    print(string(first.wait() + second.wait()))
```

The target is a declared top-level or static function. An instance method is
not a spawn target because it carries a receiver. A worker may spawn another
worker.

## What crosses

The boundary copier recursively rebuilds permitted data in the destination
runtime:

- numbers, `bool`, strings, enums, and plain value fields copy;
- structs, unions, optionals, lists, maps, arrays, and builders copy as a
  graph, preserving relationships inside the copied graph but sharing no
  object with the source runtime; and
- the caller keeps its original argument graph.

That final bullet is the contract, not reliable current behavior for a
container argument. Until Phase 0 fixes the bug in `docs/MISSING.md`, do not
reuse a reference argument after `spawn` or treat a clean result as proof of a
clean census.

The same rule runs in the other direction when `wait()` receives a result.
This is an internal boundary operation, not a source-level clone operator.

Three shapes are refused transitively:

- a `file` belongs to the runtime whose host channel opened it;
- a `task` owns a worker attached to the runtime that spawned it; and
- a function value may carry a bound receiver, so its environment is not a
  sendable value.

A struct, union, optional, container, or interface carrying one of those
shapes is refused too. Current interface values contain bound dispatch
functions, so they do not cross. Future classes, weak references, and capturing
closure environments remain non-sendable unless a later design introduces a
separate explicit snapshot abstraction.

## `task`: an ARC resource

`spawn` returns a reference-counted `task`. Its type records the worker's
return shape:

```text
task            answers nothing and cannot fail
task(!)         answers nothing or a recoverable error
task(double)    answers a double
task(double!)   answers a double or a recoverable error
```

Task references may be stored in fields, optionals, containers, and unions.
They all name one worker. The completed ARC contract joins an unfinished task
when its last reference is released. Current development builds still have
feature-gated lifecycle tests, so this is not yet an unconditional timing
guarantee.

## Waiting

`task.wait()` joins and observes the outcome once. Every alias sees the same
one-shot state.

- A normal `T` answer is copied into the joiner's runtime.
- A `T!` answer preserves the recoverable error; the join site uses `try` or
  `catch`.
- A trap observed through an explicit wait is re-raised with the worker's
  frames before the joiner's frame.
- Completed last-release cleanup joins an unobserved task, then discards its
  answer, error, or trap.

A task cannot carry a multi-value return because there is no corresponding
`task(A, B)` shape. Wrap the values in a struct. A worker return graph also may
not transitively contain a file, task, or function value.

## Isolation and effects

No Luce object identity is shared across runtimes. Ordinary data races over
lists, maps, arrays, builders, future classes, or closure environments are
therefore unrepresentable.

Host effects are process services rather than Luce objects. The runtime
serializes them, so a host callback never has to be entered concurrently and a
printed line is atomic with respect to other workers. Worker publication and
joining use a separate registry lock because they are lifecycle operations,
not language-visible shared state.

The host table exposes fail-closed `worker_spawn` and `worker_join` slots. If a
host withholds threading, `spawn` traps `host_unavailable` before publishing a
task. A program that never spawns emits none of the worker trampoline or effect
lock setup.

## Verification obligations

Worker behavior is one semantics on both execution paths. The differential
oracle creates a real `Machine` on a real thread through the same host slots as
a compiled artifact. Specs compare output, errors, traps, trace frames, host
world, and the live-object census across all runtimes.

Coverage must include:

- scalar, string, value-struct, and nested container arguments and results;
- independence of the caller graph after a spawn snapshot;
- transitive refusals for files, tasks, function values, and interface values;
- normal, fallible, trapped, and unobserved completion;
- task aliases, aggregates, last-release joining, and exactly-one wait;
- nested workers and teardown under allocation and host failure; and
- graph-copy rollback with no leaked rows in either runtime.

The existing suite proves most result and explicit-wait cases. Direct nested
container-argument snapshot coverage and the feature-gated ARC lifecycle tests
are named Phase 0 gaps in `docs/ROADMAP.md`.

## Deliberate limits

Workers are OS threads: thousands, not millions. Locks, atomics, shared heaps,
condition variables, thread identities, priorities, and `async`/`await`
coloring are absent. An event loop may later run inside a worker, but it does
not change this isolation contract.
