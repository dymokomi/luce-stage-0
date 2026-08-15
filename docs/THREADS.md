# Threads — workers own their world

Luce's concurrency is built on one idea: **workers share nothing**. A
worker runs on its own OS thread against its own runtime, so no object is
ever reachable from two threads at once. Data races are not detected;
they are unrepresentable.

This costs no new machinery, because the runtime is already a parameter
rather than a global. Every run owns its `Runtime` — its heap, its
scopes, its trap channel — so several isolated runtimes in one process is
the shape the tree already had, and a worker's heap is one more of them.

## Spawning a worker

`spawn f(args)` runs `f` on a thread of its own and answers a `task`:

```luce
func sum_to(limit: long) -> long:
    var total: long = 0
    var i: long = 1
    while i <= limit:
        total += i
        i += 1
    return total

func main():
    var a = spawn sum_to(1000000)
    var b = spawn sum_to(2000000)
    print(string(a.wait() + b.wait()))
```

The worker's runtime is its own: its own object heap, its own scope
stack, and a fresh 256-frame depth budget — not what is left of the
spawner's, because a worker's frames belong to its own thread. It
inherits everything about the *program* (the function table, the host's
channels) and nothing about the *thread*.

## What crosses the boundary, and what does not

A worker's arguments cross into its runtime, and the value/reference
split (`docs/MEMORY.md`) decides how:

- A **value type** — the scalars, `string`, a plain `struct`, an `enum`
  — crosses **by copy**, exactly as it copies anywhere else. The worker
  computes over its own copy, and there is nothing left behind to race
  on.
- A **reference type** — a `class`, the containers `list`/`map`/
  `array`/`builder`, or a resource `file`/`task` — **does not cross at
  all**. A reference shared by two threads is the race this design
  exists to prevent, so a reference argument is refused with a sentence
  that names the fix: send the values it is made of, or build it inside
  the worker.

A copied value crosses as a deep copy into the worker's runtime, because
a handle is an index into one table and a string's bytes come from one
allocator — there is no representation two runtimes could share. A
packed `list` of scalars copies as bytes, so even a large value crossing
is a block copy each way plus a little bookkeeping.

## `task`: the handle to a running worker

`spawn` answers a `task`, and a `task` is a **reference-counted
resource** (`docs/MEMORY.md`): created by the spawn, and freed when its
last reference goes away. **Its last release is a join** — waiting for
the worker to finish. Structured concurrency is therefore a consequence
of the lifetime rule rather than a discipline: there is no way to hold a
running worker and not eventually wait for it, so an orphan thread is as
unrepresentable as a leaked object.

A `task` carries the shape its worker will answer, written exactly as it
would be written after `->`:

```text
task            a worker that answers nothing
task(!)         a worker that answers nothing but can fail
task(double)    a worker that answers a double
task(double!)   a worker that answers a double or fails
```

These are four spellings of one resource type; the return shape is part
of the task's type so that a fallible worker and an infallible one are
never the same type.

## Waiting

`t.wait()` joins the worker and moves its answer here, **once**. The task
is consumed: a second `wait` on the same task is refused, so no worker is
ever joined twice.

- If the worker's function answers `T`, `wait()` answers `T`.
- If it answers `T!`, `wait()` answers `T!`, and the worker's raised
  error crosses whole — its code, its message, and the place it was
  raised — so the joiner writes `try` to pass it on or `catch` to handle
  it:

```luce
func classify(n: long) -> string!:
    if n < 0:
        error("negative")
    return "ok"

func main() -> !:
    var t = spawn classify(7)
    print(try t.wait())
```

Only a `wait` observes a worker's outcome. A task that nobody waits on
is still joined when its last reference dies, but its result — and a
trap it raised — is discarded. Fire-and-forget is legitimate: a bare
`spawn f()` statement runs the worker and joins it at the end of that
statement, computing the same answer a plain call would.

## Traps, errors, and exit

An **error** is data: it travels through `wait` as `T!` and is the
worker's own value.

A **trap** is not data. A trap in a worker surfaces **at the join**,
raised with the worker's own frames in front of the joiner's — the trap
happened inside the worker, and the join is only where it is spoken. It
stops the program exactly as any trap does; traps are final in every
thread. Because only a `wait` observes, a program that wants a worker's
trap to stop it must wait for that worker.

If a worker calls `exit(status)`, the program stops at the join carrying
the status the worker chose — the same edge a trap rides, and for the
same reason: there is exactly one point at which a worker's ending can be
spoken, and the join is it.

## What may be spawned

The spawned callable is a function you declared, and every one of its
arguments must be a value type (above). Three shapes are refused by name:

- A **reference argument**, for the reason the whole design exists.
- A **method**, because a method's receiver is a place in the caller's
  frame, and there is nothing a worker could be handed that would still
  be that receiver when it finished. A `static func` member has no
  receiver and is an ordinary spawn target.
- A **multi-value return**, because a task carries one answer and
  `task(A, B)` is not a spelling.

## What is deliberately absent

Locks, atomics, shared mutable state, condition variables, thread
identifiers, `async`/`await` coloring, and priorities do not exist in
Luce. Their jobs are done by isolation, or they do not exist here. There
is shared mutable state *within* a worker — a `class` graph is ordinary
— but never *between* workers, which is the whole promise.

## The host boundary, and the cost of not spawning

Spawning is a machine resource. It enters through two fail-closed slots
on the host table, `worker_spawn` and `worker_join`, implemented on the
platform's threads in the real host. A host that cannot thread answers
no, and the program traps `host_unavailable` at the spawn — the ordinary
fail-closed rule for a withheld service.

Host effects from workers are **serialized**: the host's services are
called from one thread at a time, so `print` from three workers is
line-atomic and no host implementation needs to be thread-safe.
Effect-heavy workers pay for that lock; compute pays nothing.

A program that never spawns pays **nothing at all**: it emits neither the
effect lock, its installation, nor the worker trampoline, and there is
nothing to configure. This is structural, not a matter of measurement —
the rendered module of a spawn-free program contains none of it.

## Both engines thread for real

Concurrency is one semantics on both engines. The interpreter oracle
spawns a self-contained `Machine` per worker through the same host slots;
there is no second implementation. Specs stay deterministic by *shape*:
workers hand their answers back through `wait` in a deterministic order
rather than racing on effects, and the leak census counts every runtime a
program used, so a leak in a worker is a leak in the program and the
two-engine comparison sees one honest total.

## Honest limits

Workers are OS threads: **thousands, not millions**. A
hundred-thousand-connection server is a later composition — an
event-loop wait *inside* a worker — not a green-thread runtime, which
every language reaches only by owning movable stacks, which is to say a
collector or a coloring. Luce takes neither.
