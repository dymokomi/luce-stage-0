# Deadlines and cancellation — design draft for ratification

**Status: plan, awaiting owner ratification** (docs/SELFHOST.md Phase 0,
owner ruling 4). Nothing here is current behavior. The pre-freeze audit
named the absence of any deadline/cancel story the exclusion most
likely to force a post-freeze *language* change: a blocked `receive`,
`accept`, or socket `read` parks a worker forever, so robust servers
are currently unwritable rather than inconvenient.

## The shape of the problem

Luce already has one deadline: `channel[T].receive_timeout(ms)`. It is
the right *kind* of answer — absence on expiry, never an error — but it
is a per-method special case. Sockets have nothing, `accept` has
nothing, `task.wait` has nothing, and composing "give up after 200 ms
across these three steps" is impossible because each step would need
its own arithmetic and the blocked step cannot be interrupted at all.

The deliberate limits stay deliberate: no async/await coloring, no
thread identity, no shared-memory signaling, no interruption of
*compute* (a spinning loop is the program's own business — this design
cancels *waits*, not work).

## Proposal: the deadline is a value, and closing is the cancel

Two pieces, no new statement forms, no function coloring:

1. **`deadline` is a small value type in `std.os`** — constructed from
   a duration (`os.deadline(ms)`), carried like any value, passed to
   the blocking operations that today take nothing:

   ```text
   let stop = os.deadline(200)
   let request = try inbox.receive(stop)      # channel, deadline form
   let peer = try door.accept(stop)           # listener, deadline form
   let landed = try wire.read(buffer, stop)   # socket read, deadline form
   ```

   Expiry answers **absence** (`T?`) exactly as `receive_timeout`
   answers today — a deadline running out is the same fact every time
   and carries no news. One deadline value naturally spans several
   steps: each call checks what is *left* of it, so "200 ms for the
   whole exchange" is one construction, not arithmetic at every call.
   `receive_timeout(ms)` becomes sugar for the one-step case and stays.

2. **Close is the cancel, and it already exists.** Channels are closed;
   the close drains and then refuses — that is a cancellation protocol,
   already shipped and spec'd. The design extends the same rule to the
   other blocking resources: **closing a listener or socket from
   another worker wakes every blocked operation on it with the
   `channel_closed`-shaped recoverable error.** A server's shutdown is
   then: close the door; every parked accept/read/receive wakes and
   unwinds; workers join. No signal type, no cancellation tokens, no
   new concept — the resource's own lifecycle is the cancellation
   surface, which is the ARC-shaped answer.

## What this deliberately does not add

- No cancellation of computation, only of waits.
- No `select` — a program that waits on two channels still structures
  around one (a fan-in channel is the idiom); select is a separate
  decision the rulings queue (#24) holds.
- No monotonic-deadline arithmetic surface beyond construction; the
  deadline is opaque and the clock it reads is `os.clock_ms`'s.
- No task cancellation: `task.wait` joining is the worker model's
  contract. A worker that should stop early watches a channel its
  spawner closes — the close-is-cancel rule again.

## Cost accounting (change-map rows)

Deadline parameter on `receive`/`accept`/`read`: std method surfaces +
the runtime rows' timed waits (the channel row already has one; the
socket half needs poll-with-timeout in the host slots, which is an ABI
bump for the two socket slots or one appended timed variant each).
Cross-worker close waking blocked operations: the channel registry
already does this; sockets need close-wakes-reader in the host
contract. Both-engine specs for expiry, cross-step budgets, and
close-wakes. Docs: THREADS.md, NETWORK.md, the failure page's absence
column.

## The ratification question

Is "deadlines are values; closing is the cancel" the frozen story? If
yes, implementation sequences after FFI Tier 1 (it touches the same
host-slot region and should share the ABI bump). If no, the fallback
is the audit's "reserve only" option: write the non-promise that
blocked operations' behavior under any future cancellation is
unspecified.
