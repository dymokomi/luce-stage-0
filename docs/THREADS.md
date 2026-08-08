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

## As built (2026-08-07)

Built in one run, on both engines, the same day the design was
ratified.  D1–D11 hold as written; every decision the code had to make
that the design left open is below, with the reason and the spec that
proves it (`src/luce/specs/threads_spec.zig`, 24 two-engine programs).

The two numbers the run was asked for, measured on an Apple M4 Max
with `--release` artifacts (`bench/crossing.luc`):

- **Crossing a 1,000,000-element `list(long)` into a worker and its
  answer back: 2–3 ms.**  A packed list copies as bytes, so the
  crossing is one 8 MB `@memcpy` each way plus the row.
- **The same arithmetic over 200,000 elements, one worker against
  four: 47–61 ms against 13 ms — about 4×.**  Four workers use four
  cores; there is no shared state for them to contend on, which is the
  point.

The eight benchmark rows held within noise across the change, which
D11 predicted and which the two IR tests below make structural rather
than statistical.

| | decision, and where it is proved |
|---|---|
| **T1** | **`task(...)` holds a *return shape*, written exactly as it would be after `->`.**  `task`, `task(!)`, `task(double)`, `task(double!)` — the last two say what `-> double` and `-> double!` say.  The design said `spawn` answers `task(T)` and left the fallible case unspelled; spelling it any other way would have made two tasks that differ only in whether their wait must say `try` into one type, and a `list(task(double))` able to hold both.  `HeapType.task` carries `{result, fallible}`, which does **not** make `T!` a type (docs/FAILURE.md): `types.Type` is untouched, and the flag sits beside the result exactly as `Function.fallible` sits beside `Function.return_type` — a task is a call in flight and carries its function's attributes. |
| **T2** | **A worker's entry closure is a function index and a run of boxed arguments, because no closure exists.**  `spawn` names a top-level declaration, so nothing that could capture anything is ever built.  The compiled artifact generates one internal `@luce.worker(host, rt, which, args, count, out, depth)` that switches on the index and makes a *direct* call — so the callee stays a static target LLVM can still inline into, and no function pointer to a Luce function exists anywhere.  The oracle's arm of the same channel builds a `Machine`. |
| **T3** | **Two channels, and the split between them is the architecture.**  `worker_spawn`/`worker_join` are the *host's* (D8) and carry no Luce vocabulary at all — start this C function on a thread, wait for it.  How a runtime is *made* for a worker and how one function is *run* in it is the **engine's**, and is `runtime.workers.Nursery`, filled by each engine rather than by a host: a compiled artifact hands over the trampoline and lets `libluce_rt` open the runtime, the oracle hands over its own allocator and `Machine`.  It is deliberately not a host slot, because a host is a machine and this is not machinery. |
| **T4** | **Storage crosses by a deep re-own, and that is the floor rather than a placeholder.**  `Runtime.copyFrom(source, value)` is `deepCopy` generalized to two runtimes — every read is the source's, every allocation is the target's — because a handle is an index into *one* table and a string's bytes come from *one* allocator, so there is no representation two runtimes could share.  Writing the walk twice would have been two places for one semantic; the one-runtime case is now the special case of the two-runtime one.  Measured above. |
| **T5** | **A worker takes the *caller's* two steps on its own answer, on its own thread.**  A `ret` hands its storage to the caller, who copies it (`own_storage`) and releases what it was handed — and a worker has no caller standing at its `ret`.  So `workers.body` does both, in the worker's runtime, the moment the run comes back: after it the answer is unambiguously the worker's runtime's, which is what lets the join move it across and lets the release free it without either having to know whether the bytes were an allocation or a borrow of a program constant.  Getting this wrong is a free of the artifact's own data in one direction and a leak in the other; both were seen before it was right. |
| **T6** | **The census is one number, rolled up as each worker's runtime closes.**  `Runtime.inherited_leaks` accumulates a worker's `live` plus whatever it inherited, and `Runtime.leaked()` is what `luce_rt_leaked` and the oracle both answer.  A leak in a worker is a leak in the program, and the two-engine comparison sees one honest total. |
| **T7** | **Only a `wait` observes.**  A release — `free(t)`, the end of the owning scope, the run's own sweep of what a program leaked — joins the worker and discards *everything*, a trap included.  D4 already said the result is discarded; this extends it to the trap for one reason: the ownership walk is total and must stay total.  It runs inside `freeObject`, from a scope's end, from an unwind that is already carrying a trap, and from the sweep at the end of a run, and not one of those three has anybody to report a second trap to.  A program that wants a worker's trap to stop it waits for the worker. |
| **T8** | **`exit` from a worker stops the program at the join, carrying the status the worker chose.**  The same edge a trap rides, at the same place, because there is exactly one point at which a worker's ending can be spoken and this is it.  Killing the process from the worker's thread was the alternative and it is not available honestly — other threads are mid-flight, and the leak census and the two-engine comparison both end. |
| **T9** | **What may be spawned is a function you declared, and every object parameter of it must say `give`.**  A method is refused by name: a method's receiver is a place in the caller's frame — and `var self` writes back into it — so there is nothing a worker could be given that would still be the receiver when it finished.  A borrow parameter is refused for the reason D2 exists: a worker cannot borrow from another runtime, and the diagnostic says so and names the fix.  A multi-value return is refused because a task carries one answer and `task(A, B)` is not a spelling. |
| **T10** | **A bare `spawn f()` statement is legal and joins at the end of that statement.**  No new rule: a task nobody binds is a statement temporary (S3/S19), and a temporary's death point is the end of its statement, and a task's death point is a join.  It computes the same answer a plain call would; fire-and-forget across a loop wants a binding, which is what D4 describes. |
| **T11** | **The effect lock is recursive, and a spawn-free program does not contain one.**  Recursive because effects nest — `f.read(buffer)` is a `libluce_rt` call that reaches a host slot — and a coarser guard higher up would deadlock a plain mutex at the inner one.  Absent because the lowering emits `luce_rt_effects_enter`/`leave` only when the program contains a `spawn`, and the interpreter's guard is a load and a branch on a pointer that stays null: **`08_llvm/test.zig` proves the module of a spawn-free program contains neither the lock, the install, nor the trampoline.**  That is D11 kept structurally rather than measured, which is a stronger promise than "within noise". |
| **T12** | **`libluce_rt` takes the platform's own mutex.**  `std.Thread` has no mutex in Zig 0.16 and `std.Io.Mutex` needs an `Io`, which a C ABI over Luce's semantics does not have and must not acquire — so `pthread_mutex_t` on the POSIX arm and `SRWLOCK` on Windows, both zero-initialized because both platforms' static initializers are.  The one thing it must not be is a spin: the lock is held across `read_line` and `key_read`, which block for a person. |
| **T13** | **A worker's trap trace crosses through `Runtime.unwound`, which both engines fill.**  A frame names a function and a file out of the *program*, which outlives every runtime in it, so nothing is copied; only a `trap("…")`'s own words are, into the joiner's run-lifetime storage, because those die with the worker.  The oracle gained `recordUnwind` for it and its `traceback` puts adopted frames in front of the live stack's — the trap happened inside the worker, and the join is only where it was spoken. |

**What did not move.**  The ownership rules are OWNERSHIP.md's,
unchanged, and every thread spec is written against the existing
clauses.  No trap code arrived: a host that cannot thread is
`host_unavailable` like every other withheld service, and a second wait
is `use_after_free` like every other use of a spent name.  `std` is
untouched — nothing here is a module, it is the language.

**Two bugs fell out of the run**, both older than it and both fixed
where they were:

- `copy m` on a `map(string, T)` whose keys were longer than a value
  holds gave the copy the *original's* key bytes, so the two maps
  shared one run and freed it twice.  `Runtime.copyFrom`'s map arm now
  takes its own key, which the cross-runtime walk needed anyway.
- `file_methods` never reached `tools/grammar.zig`, so `f.read(…)`
  and its two siblings were not highlighted in the editor grammar the
  language generates for itself.  The re-export was missing;
  `task_methods` went in beside it.

**What is next is D12.**  Channels — typed pipes whose `send(give x)`
moves an object between workers — build on exactly the machinery this
run wrote: `Runtime.copyFrom`'s two-runtime walk, the effect lock, and
the host's two thread slots.  Nothing about a channel needs a third.

## SELF clarification — 2026-08-08

T9's conclusion survives the receiver redesign: a method cannot be
spawned because its receiver is a place in the caller's frame.  What
changed is the spelling and the positive counterpart.  Methods have
implied self and no `var self`; a `static func` member has no receiver
and is an ordinary function value and worker target.
