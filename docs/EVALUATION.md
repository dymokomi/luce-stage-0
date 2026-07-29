# The push/pull evaluation engine

How the Fabric becomes a hybrid system, in LOOM.md's words: **"Push
invalidates. Pull evaluates."**  Pull stays the value semantics — demand
walks upstream, evaluators are pure, caches are disposable, nothing
recomputes merely because it exists.  Push is a *notification* layer
only: a change tells interested parties which texels are stale, and they
decide whether to demand again.  A dirty-mark never evaluates anything,
and no value ever travels through a Fiber by push.

The engine change is additive.  Demand semantics, evaluator purity,
acyclicity, and Store atomicity do not change.

## Demand roots

A lazy graph cannot start itself; every evaluation begins at a demand
root (LOOM.md).  The terminal maps onto that taxonomy directly:

- **One-shot demand** — `pull`: resolve an output once, now.
- **Event-activated demand** — `watch`: re-demand when a subscribed
  dependency is marked dirty.
- **Standing demand** — a presented View: kept current while visible;
  the shell demands a frame when dirtiness plus a presentation
  opportunity coincide.
- **Scheduled demand** — later: durable demand Texels compiled into
  timer wake-ups (see Later, below).

## The pieces

```text
commit → ChangeSet ─→ FiberIndex.downstream ─→ Spool.advance ─→ re-demand
         (fabric)       (loom, disposable)      (loom)           (app: watch)
```

### 1. ChangeSet — the Store tells what a commit touched

`fabric/persistence`.  A Transaction already funnels every mutation
through `put_changed` and `remove`; both record the touched `TexelId` in
a `touched` set.  On commit the Store keeps the delta in a small ring of
recent commits:

```cpp
struct ChangeSet {
    U64         generation;   // the generation this commit produced
    TexelIdList changed;      // texels put or removed by it
};

// Union of deltas in (generation, current].  False when the ring no
// longer covers that span — the caller must then assume everything
// changed and rebuild.
bool Store::changes_since(U64 generation, TexelIdList *changed) const;
```

The ring (64 entries) is bounded, in-memory, and never persisted: losing
it costs a rebuild, never correctness.  The Store still knows nothing
about fibers or evaluation.

### Volatile observations feed the same ring

LOOM.md: transient observations remain volatile unless a Texel
deliberately captures them.  A mouse move must not cost a durable
commit, so the Store gains a second, non-durable way to change:

```cpp
// Update an observed Output Port in the in-memory table only: set the
// source value, advance the port, texel, and logical generation, and
// record a ChangeSet entry.  Nothing reaches the volume; restart
// reverts to the last durable snapshot.
bool Store::observe(const TexelId &texel, const char *output, const Value &value);
```

`generation()` becomes the *logical* generation — advanced by both
durable publishes and volatile observations — which is all the Spool
ever compares against.  Recovery restores the last durable state, which
is exactly right for a stale observation.  Deliberate capture is just an
ordinary durable commit that copies an observed value into durable
state (a State texel, or any texel that stores it).

Until `observe` lands, the terminal's keyboard observation commits
durably per line — a working stopgap, marked as such in `boundary.h`.

### 2. FiberIndex — the reverse index, disposable machinery

`loom/evaluation/fiber_index.h`.  LOOM.md: an Output Port does not own a
durable consumer list, but Loom may build the reverse index as
disposable machinery.  This is that machinery:

```cpp
class FiberIndex {
public:
    bool build(const Store *store);                              // full scan
    bool apply(const Store *store, const TexelIdList &changed);  // refresh rows
    bool downstream(const TexelIdList &changed, TexelIdSet *dirty) const;
};
```

Granularity is the texel, not the port: a changed texel dirties every
transitive consumer of any of its outputs.  Conservative is the rule —
a false dirty costs one cheap revalidation, a missed dirty would be a
correctness bug.  Per-output precision is a later refinement if this
proves too coarse.

Soundness of `apply` then `downstream`: rewiring always rewrites the
*consumer* texel (connect, disconnect, and port moves go through
`put_changed` on the input side), so every topology change appears in
the ChangeSet itself.  Applying the delta before computing the closure
therefore sees the new wiring, and the rewired consumer is already in
the dirty set because it changed.

### 3. Spool.advance — one long-lived cache instead of one per pull

The Spool is already correct across commits: every record carries
`checked_generation` and revalidates lazily against store revisions.
Today the terminal sidesteps that by building a fresh Spool per pull,
which throws the cache away.  The session instead keeps **one Spool**,
and after each commit tells it what survived:

```cpp
// Stamp every cached record whose texel is not dirty as already checked
// against the current generation.  Dirty records are left stale and
// revalidate lazily on next demand.
void Spool::advance(U64 generation, const TexelIdSet &dirty);
```

- A **clean** endpoint demands in O(1): its record is pre-stamped, no
  store walk at all.
- A **dirty** endpoint revalidates exactly as today: walk upstream,
  compare revisions, and — because `ComputeRecord` keeps
  `input_revisions` — skip the evaluator when inputs turn out unchanged
  (early cutoff survives; that is why advance stamps rather than
  erases).

Cache budget is a later, separate concern (LOOM.md rule 4): `clear()`
already exists as the pressure valve.

### 4. Watch — subscriptions close the loop in the app

The terminal session owns the FiberIndex, the long-lived Spool, the last
generation it reconciled, and a watch list of endpoints with the last
effective revision each subscriber saw.  Once per command loop, after
dispatch:

```text
if store.generation != seen:
    covered = store.changes_since(seen, &changed)
    if not covered:  index.build(store);  spool.clear();  dirty = all
    else:            index.apply(changed);  index.downstream(changed, &dirty)
                     spool.advance(generation, dirty)
    for each watched endpoint in dirty:
        re-demand through the session Spool
        print "name.output = value" when its effective revision moved
    seen = store.generation
```

Commands: `watch OUTPUT` / `unwatch OUTPUT` on the selected texel.
`pull` switches to the session Spool.  Boundary texels need nothing new:
a keyboard observation is a commit, so a watch over anything downstream
of `keyboard.line` fires on every typed line.  That is the whole
push/pull story working end to end.

## Worked example: mouse to view, in realtime

A code texel T takes inputs from the mouse boundary texel and computes
outputs X and Y; a view V presents X and Y.  The principle: **the device
pushes observations, the screen is a standing demand, and the frame loop
is the metronome — sample, commit, mark, pull, draw.**

```text
mouse moves (many, push)           host events, free-running
   ↓ latest wins
one volatile observe per drain     ChangeSet = {mouse}; nothing durable
   ↓ FiberIndex.downstream
dirty = {mouse, T, V}              marks only, nothing evaluated
   ↓ V is presented — standing demand
Spool re-demands V.interface       T evaluates once, V evaluates once
   ↓ interface revision moved
shell redraws that surface         the effect, performed once
```

What this buys:

- A view that is not presented costs nothing: mouse motion re-marks an
  already-dirty texel and stops there.
- Coalescing is free.  Thirty mouse events between drains are one
  commit and one pull that reads the latest observation — push carries
  no values, so there is no queue of stale frames and no backpressure.
  The world is sampled at frame rate, not streamed at event rate.
- Only the dirty path runs; the rest of the Fabric stays stamped clean.

Observe-then-sample is required by LOOM.md rule 8: transient data stays
transient.  Raw mouse events are never durable history; the observation
is volatile, and only deliberate capture makes it durable state.  This
also satisfies the vision's proof criterion of processing high-rate
pointer input without recomputing an invisible View.  Today's terminal
is this loop at line granularity — each typed line is one drained frame;
raw-mode input later raises the drain rate without changing the model.

## Invariants

1. **Push never evaluates.**  A dirty-mark marks; only demand computes.
2. **Marking is conservative.**  Over-marking wastes a revalidation;
   under-marking is forbidden.
3. **The pulse drains at defined points** — end of each terminal
   command.  No notification reentrancy, no evaluation mid-commit.
4. **Everything push-side is disposable.**  Ring overflow, a lost index,
   or a cleared Spool degrade to rebuild-and-full-revalidate, never to
   wrong values.
5. **Single-threaded now, thread-shaped later.**  The ChangeSet feed is
   the future thread boundary: an evaluation worker would drain the same
   ring the terminal loop drains today.

## Implementation order

1. `Transaction::touched` + `Store::changes_since` ring, with
   `store_test` cases (delta per commit, span union, overflow).
2. `FiberIndex` with `fiber_index_test` (build, apply, transitive
   closure, rewiring via delta, removed texels), registered in
   CMakeLists.
3. `Spool::advance` with `spool_test` cases (persistent spool across
   commits; clean endpoints stay cached; dirty path recomputes; early
   cutoff still skips evaluators when values did not move).
4. Terminal: session-owned Spool, the reconcile step above, `watch` /
   `unwatch`, and a `loom_terminal` script proving a watch fires on
   `set` and stays quiet on unrelated commits.
5. `Store::observe` — the volatile observation path with its logical
   generation, `store_test` cases (observation invisible after reopen,
   generation advances, delta recorded), and the keyboard boundary
   switched from durable commits to observations.
6. Later, in order of need: per-output dirty granularity, bounded event
   streams beside latest-value observations (the pointer example in
   LOOM.md), scheduled demand as durable, visible demand Texels compiled
   into timer wake-ups with occurrence identities, Spool cache budget,
   threading the drain.
