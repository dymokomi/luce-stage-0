# The memory model decision

> **Decided and implemented.**  The situation-by-situation
> specification distilled from this memo lives in `docs/OWNERSHIP.md`
> (ratified S1–S43) and is live in the compiler and in `libluce_rt`,
> the one runtime both the interpreter and compiled code call
> (`docs/CODEGEN.md`), proven by `src/luce/specs/ownership_spec.zig`.  This memo is kept as the
> record of the options weighed and why scope ownership + `give` won.

Luce *had* **manual explicit memory**: objects created with
`new`/literals, released with `free(x)`, use-after-free and
double-free trapping deterministically, loom reporting leaks after
every run.  That was safe and honest — but `free` at every exit path
was the single biggest source of friction in real programs
(docs/CODEGEN.md), so the question was what the *permanent* model
should be.  This memo held the options and trade-offs so the decision
was made once, with eyes open.  Option 3 won.

One fact makes every option cheaper than usual: the interpreter
already tracks every object and traps on dead references.  Luce can
afford *dynamic* enforcement of rules other languages must prove
statically — safety is guaranteed under every model below; the choice
is about ergonomics, predictability, and implementation cost.

## The candidates

### 1. Manual free + leak reports (today)
- **For:** dead simple to implement and explain; maximum Zig spirit;
  zero hidden behavior.
- **Against:** every early return is a leak; single-exit contortions;
  the AUDIT's top friction.  Nobody's favorite endgame.

### 2. `defer` on top of manual free (Zig's answer)
- **For:** tiny addition (compiler emits deferred calls on scope
  exits, including break/continue/return edges); exactly Zig; also
  useful beyond memory (files, terminal restore).
- **Against:** still a line of ceremony per object; still forgettable
  (leak reports keep catching that); doesn't compose with returning
  objects (you cancel the defer by hand — Zig's `errdefer` split
  exists for a reason and Luce has no error unions yet).

### 3. Scope ownership + `give` (the "Rust, not psychotic" sketch)
Every object is owned by the binding that received it fresh; scope
exit frees what the binding still owns; `return` moves to the caller;
storing a *fresh* object in a container moves ownership into it
(freeing the container frees its children); handing off to a callee
or container from an existing binding is explicit: `xs.append(give
item)`, `helper(give xs)`.  Aliases are borrows; a borrow outliving
its owner traps at use (dynamically) instead of failing to compile.
- **For:** `free` disappears from ~95% of code while staying fully
  deterministic (drop points are readable from the source, like
  Rust); leak reports become structurally impossible; the `give`
  keyword makes ownership transfer *visible*, which is the Zig value;
  dynamic checks mean no borrow checker, no lifetimes, no fight.
- **Against:** the most design-sensitive option — move-on-rebind,
  drop-on-reassign, and container adoption rules must be nailed and
  taught; moderate interpreter/compiler work (owner tracking, scope
  unwinding on break/continue, return-walks through struct fields);
  aliasing mistakes surface at run time, not compile time.

### 4. Full Rust (static borrow checking)
- **For:** compile-time guarantees, zero runtime cost.
- **Against:** the psychotic option — lifetimes and aliasing rules are
  the opposite of "Python ease"; enormous compiler work; explicitly
  ruled out.

### 5. Reference counting (Swift/CPython)
- **For:** best pure ergonomics — objects just die when the last
  reference goes; still mostly deterministic; no syntax at all.
- **Against:** cycles leak (a List holding its holder) unless weak
  refs or a cycle collector arrive — real complexity; frees stop
  being visible in source (aliases keep things alive at a distance),
  which erodes the explicit-memory identity; refcount traffic on
  every copy/scope in the interpreter and later in native code.

### 6. Tracing GC
- **For:** zero user burden, handles cycles.
- **Against:** off-brand entirely — nondeterministic reclamation,
  pauses, hidden machinery.  Ruled out by the project's values.

### 7. Arenas/regions (per-phase bulk free)
- **For:** matches the interpreter's internals; brilliant for
  request/frame-shaped programs (free everything per editor frame).
- **Against:** not a general model — long-lived structures need
  something else anyway; region annotations get academic fast.
  Interesting later as an *optimization* under option 3.

## How they score against the vibe

| | Python ease | Zig explicitness | Deterministic | Impl cost | Safety |
|---|---|---|---|---|---|
| 1 manual | ✗ | ✓✓ | ✓✓ | done | ✓ (traps) |
| 2 defer | ✗/✓ | ✓✓ | ✓✓ | small | ✓ |
| 3 scope + give | ✓✓ | ✓ (`new`/`give` visible) | ✓✓ | medium | ✓ |
| 4 borrow checker | ✗✗ | ✓✓ | ✓✓ | huge | ✓✓ |
| 5 refcount | ✓✓✓ | ✗ | ✓ (mostly) | medium | ✓ (cycles leak) |
| 6 GC | ✓✓✓ | ✗✗ | ✗ | large | ✓ |
| 7 arenas | ✓ | ✓ | ✓✓ | medium | ✓ |

## Current lean (not a decision)

Option 3, with option 2's `defer` available anyway for non-memory
cleanup (terminal state, files).  It is the only column that scores
on both identity axes at once, and the dynamic-trap safety net means
its worst failure mode (an alias outliving its owner) is a loud,
stable, debuggable trap — the same failure mode manual free already
has today.  Option 5 is the strongest challenger if maximum Python
ease wins the argument; its cycle story is the thing to be honest
about before choosing it.

Questions to settle before implementing option 3, whichever way:
1. Does rebinding (`let y = x`) move or borrow?
2. Does reassigning an owning `var` free the old object immediately?
3. Do containers adopt fresh objects implicitly, or is `give`
   required everywhere?
4. What do struct fields own, if anything?
5. Is `free` kept for early release?

## Design sketch: gradual ownership ("fresh-or-said")

Where the thinking currently is, after weighing the constraints:
LuciaOS's language must be systems-grade (no GC; ARC rejected as a
default — refcount traffic taxes everything and hides frees), must
not be Rust-convoluted, must be effortless for casual users, and
should have a sensible default with explicit verbs underneath.

**Default (casual users write zero memory words):**
- A *fresh* object — `new`, a literal, a slice, a `split()` result —
  is owned by the binding that receives it; it dies at that binding's
  scope exit or reassignment.  Deterministic, readable from source.
- `return xs` moves to the caller automatically.
- Storing a *fresh* object into a container hands ownership to the
  container; freeing the container frees what it owns.
- Passing to a function, reading, iterating: borrows — free, no
  ceremony.
- Unbound statement temporaries die at the end of their statement's
  scope.

**The verbs (the intricate 10%):**
- `give x` — transfer ownership (into a call or container); free.
- `copy x` — deep clone; independence made visible and O(n).
- `free x` — early release; rare.
- later, maybe: `share x` — an opt-in refcounted island for genuine
  shared ownership; cost confined to objects that ask for it.
  Explicitly not in the first version.

**The one rule replacing the borrow checker:** *keeping* a named
object — storing a bare variable into a container or an outliving
struct — requires `give` or `copy`.  Fresh expressions keep
themselves.  The distinction (bare name vs fresh expression) is
purely syntactic, so the rule is enforceable on the AST with a
fix-it diagnostic: no lifetimes, no dataflow, nothing to fight.

**Safety is a build mode, not a semantic:** the runtime checks every
access through generation-tagged handles, so a borrow outliving its owner is a
deterministic `use_after_free` trap at the faulting line.  A future
ReleaseFast lowers handles to raw pointers and the checks cost zero —
Zig's exact posture, applied to ownership.

**Prior art to steal from:** Vale (generational references — the
same trap mechanism Luce already has), Mojo (ownership + transfer
sigils without lifetime annotations), Nim ARC (move-on-last-use as a
pure optimization later), Lobster/Perceus (compile-time RC elision if
`share` ever needs to get fast).

**Decided (July 2026):**
- The default is the clean version: fresh objects belong to the
  binding that receives them, die at scope exit or reassignment,
  `return` moves, containers adopt fresh values.  Casual code has
  zero memory words.
- `let x = y` — two names for the same object; no move, no ceremony.
- `give` is for people who know what they are doing, so it is
  strict: after `give y` (including `let x = give y`), touching `y`
  is a **compile error**.  Because storing a bare name is never
  legal (only `give`, `copy`, or fresh), containers always own their
  object elements — dangling container elements are unrepresentable.

**Still open, most important first:**
1. Function boundaries: parameters take ownership only when the
   signature says so (`hits: give List(Int)`) and the call site must
   match (`store(give my_hits)`); borrows are the default.
   Recommended; Mojo-precedent.  A callee may only `give`/keep/
   return what it owns.
2. Returning borrows: forbidden — return what you own, or
   `return copy xs`.  Recommended.
3. Struct fields: own-at-construction (`var bag = Bag(items = [1,
   2])` owns the list through the struct); field assignment follows
   the verb rule (`bag.items = give xs`); struct copies alias.
   Recommended over "structs never own", which cripples real data
   structures.
4. `give` under control flow: conservative source-order poisoning
   (from the `give` line to end of scope, branch-insensitive), and
   giving an outer-declared name from inside a loop body is a
   compile error.  `copy` is always the out.
5. The one dynamic backstop: aliases can dodge static poisoning
   (`let y = xs`, give `xs` away, then `give y`), so `give` verifies
   binding-ownership at run time — trap in safe builds, UB in a
   future ReleaseFast, exactly Zig's posture.
6. Confirmations pending: reassigning an owning `var` frees the old
   object immediately; `free` survives as early release on owned
   names and poisons like `give`; `share` stays out of v1; final
   naming (`give`/`move`, `copy`/`clone`).
7. Exact statement-scope definition for unbound temporaries, and
   whether `defer` still arrives separately for host cleanup.

---

## Addendum, 2026-08-02: values get counted storage

The candidates above were weighed for **objects**, and scope ownership
won for objects and still holds.  Values — Strings and struct field
runs — were left on a run-lifetime arena, and that has now been
measured against a real program: `programs/editor.luc` peaks at
**976 MB after 20,000 keystrokes into a 40 KB file**, because
`Editing.splice` copies the whole buffer twice per keystroke and
nothing is ever reclaimed.  Any program with a main loop has the same
shape.

### There are two problems here, not one

*Transient* garbage — a loop that builds and discards a string and
retains nothing — leaks ~18 bytes per iteration.  *Retired* garbage —
the editor's old `state.content`, replaced by a newer version — is
dead but unprovably so.  They have different fixes, and conflating
them is how you pick the wrong one.

### Option 7 (regions) is refused as the answer

A per-statement scratch arena, exploiting S3's "an unbound temporary
dies at the end of its statement", reclaims exactly the intermediate
in `a + b`.  For the editor that is `cursor` bytes out of
`cursor + len` — **33% relief mid-file, 50% at end of file**, still
dead linear.  It does not make the editor survivable.

Three structural obstacles besides: the analyzer has no record of
string temporaries (`carriesObjects` answers false for `.string`, so
`registerTemp` never sees one); **MIR has no statement, scope or
region concept** to reset against; and resetting would dangle every
view already stored, because containers, struct fields, `s[a:b]` and
`m[k]` all hold borrows of bytes they did not allocate.  Whether a
string escapes cannot be decided at the producer, because the producer
is usually a *borrow* of something whose region is not known there.

Regions remain interesting as a later optimization *under* counting,
which is where this document already filed them.

### Option 5 (reference counting) is adopted, for values only

The three objections recorded above were all reasoned about objects,
and none survives the move to values:

- *Cycles leak* — **impossible here.**  A String is immutable bytes
  with no outgoing reference, and struct field runs are acyclic
  because the analyzer rejects struct cycles.  Counting is *complete*
  on this set, not partial.
- *Frees stop being visible in source* — values have no visible frees
  today either.  S32 forbids verbs on values by design.
- *Traffic on every copy and scope* — real, and confined.  The parity
  benchmarks that reach 0.97–1.07× C — matmul, arrays, stats, loops,
  math — **contain no Strings and pay literally zero.**  This is the
  decisive difference from Swift, which counts every class instance
  including in hot loops; PACT '18 measures that at 32% of execution
  time on average, and non-atomic still costs ~20% of a string-heavy
  program.  Luce has no threads, so the counts are non-atomic, and
  only byte buffers carry them.

Nothing in the language changes.  No verb, no trap, no diagnostic, no
change to the leak census.  S1–S43 are untouched.  A program cannot
observe the difference except in RSS — that is the test, and it is
what makes this an implementation decision rather than a model change.

Projected: the churn loop goes flat, and the editor goes from 976 MB
to **under ~1 MB of string storage, flat in keystrokes**.

### Object identity: generational handles

Separately and first, because it is small and self-contained: bits
32–63 of `Value.bits` are unused, so an object handle becomes
`{index, generation}` and rows go on a free list.  `alive` disappears
— a row is dead iff its generation differs from the handle's.  The
fast path is unchanged in shape: one load and one compare, as today.

**Generations do not wrap.**  slotmap accepts wraparound after 2³¹
reuses and EnTT's 12-bit version wraps routinely; Luce retires the row
instead.  S9 is a safety guarantee here, not an ECS convenience, and
trading a leak for a one-in-four-billion aliasing hole is exactly the
bargain this project does not take.  Cost: at most one 128-byte row
leaked per four billion frees of that same row.

Nothing serialises an object handle, so there is no `.lc` format bump.
`07_optimize/ownership.zig` already pessimises for row reuse — the
optimizer was written for this — and can be *relaxed* afterwards,
since a stale handle can no longer name someone else's object.

### Tracing GC stays out, and the reason has changed

The original argument was about brand — nondeterministic reclamation,
pauses, hidden machinery.  There is now a measured engineering
argument, which is stronger.

**There is no root set, and acquiring one costs precisely what the
backend just bought.**  Compiled code holds Strings as unboxed
`{ptr, len}` SSA aggregates in whatever registers LLVM chose, and
holds Array element pointers hoisted into loop preheaders.  Making
those enumerable means stack maps or a shadow stack at every
safepoint — store traffic in exactly the loops `08_llvm/loops.zig`
exists to keep clean.  That file has the number: resolution inside the
loop is 52 ms, lifted out it is 10 ms, against 10 ms for C.  A
safepoint-bearing loop hands that back.  Conservative scanning avoids
the maps and makes *retention* nondeterministic, which a language that
reports a leak census cannot absorb.

So `docs/LANGUAGE.md`'s "deliberately absent" line needs splitting
rather than reaffirming: garbage collection is absent and stays
absent; reference counting is absent **from the language** — objects
are scope-owned and values take no verbs — while the storage behind
values is runtime-managed and unobservable.
