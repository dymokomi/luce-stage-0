# Threads — workers own their world

**Ratified by the owner, 2026-08-07** (*"Ohh this is really good!
Let's implement it"*), at the end of the deliberation
`docs/CONCURRENCY_RESEARCH.md` framed and the host-architecture
conversation sharpened.  The north star, in the owner's words:
*beautiful and effortless for people, very clean syntax, high
performance, and save users from race conditions.*  The design answers
with one sentence: **the ownership model is the concurrency model** —
races are not detected, they are unrepresentable.

The load-bearing fact, measured rather than assumed: the runtime is
already a parameter, not a global.  Every run owns its `Runtime`
instance, so several isolated runtimes in one process is the tree's
existing shape, and a worker's heap costs no new mechanism.

## The model

A **worker** runs a function on its own OS thread, against its own
`Runtime` — its own heap, its own scopes, its own 256-frame depth
budget.  No object is ever reachable from two workers, and the
compiler enforces it with rules it already has.

```text
func crunch(chunk: give list(double)) -> double:
    ...

func main():
    var tasks = new list(task(double))
    for chunk in chunks:
        tasks.append(spawn crunch(give chunk))
    var total = 0.0
    for t in tasks:
        total += t.wait()
```

## Decisions

| | decision |
|---|---|
| **D1** | **A worker is a second runtime.**  Own heap, own scope stack, own depth budget, on an OS thread.  Share-nothing is structural: nothing allocated in one runtime is addressable from another. |
| **D2** | **`spawn f(args)` is a call whose arguments cross a boundary, and borrows cannot cross.**  Every object argument must say `give` or `copy` — a bare object name is refused with a sentence naming the rule, because a borrow held by two threads is the race this design exists to prevent.  Values copy as they always do.  `give` poisons the sender's name at compile time (S23 machinery, unchanged), so after the spawn there is nothing left behind to race on.  The moved object's storage transfers into the worker's runtime. |
| **D3** | **`spawn` answers `task(T)`** — `T` the function's return type, bare `task` when it answers nothing — and **a task is a scope-owned resource**, the `file` precedent exactly: created by `spawn`, released by its owning scope, `give`/`return`/`free` meaning what OWNERSHIP.md says.  A new resource row beside `file` in `types.HeapType`; no `new task`, no `copy t` (one worker, one owner). |
| **D4** | **`t.wait()` moves the result to the caller, once.**  A second wait on the same task is refused the way a second `give` is — the task is consumed.  If `f` answers `T!`, `wait` answers `T!` and the worker's raised error crosses whole (code, message, origin).  An **unwaited task joins silently at scope end and the result is discarded** — a fire-and-forget worker is legitimate (ratified with the design; cheap to revisit). |
| **D5** | **Scope end joins.**  Releasing a task means waiting for the worker to finish — structured concurrency as a *consequence of scope ownership*, not a discipline: an orphan thread is as unrepresentable as a leaked list.  `free(t)` is an early join.  Join blocks; that is what owning a running worker means. |
| **D6** | **A trap in a worker surfaces at the join**, with the worker's own trace, and stops the program exactly as a trap does — traps are final in every thread.  (An *error* travels as data through D4; a trap was never data.) |
| **D7** | **Deliberately absent from the surface, permanently**: locks, atomics, shared mutable state, condition variables, thread IDs, `async`/`await` coloring, priorities.  None of these exist in Luce; their jobs are done by ownership transfer or do not exist here. |
| **D8** | **Spawning is a machine resource and enters through the host table**: appended fail-closed slots (`worker_spawn`, `worker_join`, and what the run finds they need), implemented on `std.Thread` in the hosts, `abi.version` bumped once.  A host that cannot thread answers no and the program traps `host_unavailable` at the spawn — the fail-closed rule, unchanged.  The OS stays invisible to programs. |
| **D9** | **Host effects from workers are serialized.**  The host table's services are called from one thread at a time — a serialization layer where the channel installs (`libluce_rt`), so `print` from three workers is line-atomic and no host implementation needs to be thread-safe.  Effect-heavy workers pay the lock; compute pays nothing. |
| **D10** | **Both engines thread for real.**  The interpreter spawns a `Machine` per worker — self-contained by construction — through the same host slots; there is no second semantics.  Specs stay deterministic by *shape*: workers answer values through `wait` (a deterministic order) rather than racing effects; the census counts every runtime. |
| **D11** | **A program that never spawns pays nothing.**  No runtime change on the spawn-free path, no new cost in generated code, nothing to configure.  (The Swift 6 lesson, honored structurally.) |
| **D12** | **Channels are run two.**  Typed pipes whose `send(give x)` moves objects between workers, with the network server as the motivating customer.  `spawn`/`wait` alone covers data parallelism and ships first; the channel design builds on this run's boundary-crossing machinery. |

## Honest limits, stated up front

Workers are OS threads: **thousands, not millions**.  The
hundred-thousand-connection server is a later composition — the
event-loop wait *inside* a worker, the handle-plus-wait shape the file
channel already established — not a green-thread runtime, which every
language reaches only by owning movable stacks, which is to say a
collector or a coloring.  Luce takes neither.

## Where it lands

`spawn` joins the keyword table; `task` the reserved type names.  New
MIR shapes for spawn and wait bump `format_version`.  Stage 4 checks
D2 at the call boundary with the give/copy machinery it has.  The task
resource sits beside `file` in the heap-type table; scope release
lowers to join.  `abi.version` moves once for the worker slots.  The
two-engine specs prove: result movement at every width and shape,
error crossing, trap-at-join with the worker's trace, give-poisoning
across spawn, borrow refusal, scope-end join, free-as-early-join,
unwaited discard, census across runtimes, and the fail-closed row.
The site gains a tour chapter; STD.md is untouched (nothing here is a
module — it is the language).
