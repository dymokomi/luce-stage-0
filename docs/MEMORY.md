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
