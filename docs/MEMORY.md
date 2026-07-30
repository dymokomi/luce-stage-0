# The memory model decision

Luce currently has **manual explicit memory**: objects are created
with `new`/literals, released with `free(x)`, use-after-free and
double-free trap deterministically, and loom reports leaks after every
run.  That is safe and honest — but `free` at every exit path is the
single biggest source of friction in real programs (docs/AUDIT.md),
so the question is what the *permanent* model should be.  This memo
holds the options and trade-offs so the decision is made once, with
eyes open.  Until then, manual free stays.

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
