# Ownership: the canonical situations

This is the specification of Luce's memory model — every situation
that defines the rules, numbered, with the decision and example
code.  **Ratified 2026-07-30: S1–S43 approved as written.
Implemented the same day** — the compiler and `libluce_rt` enforce
every situation below, diagnostics quote the S-numbers, and
`src/luce/specs/ownership_spec.zig` is the executable form of this
document.  Optionals (`T?`) are Phase 3, designed together with
error handling; global scope is Phase 2 (see docs/V2.md).

Vocabulary used throughout:
- **object** — a heap value: `List`, `Map`, `Array`, `Builder`.
  Everything else (`Int`, `Float`, `Bool`, `String`, structs)
  is a *value*: copied freely, never freed by the program — the
  runtime reclaims a value's storage when the place holding it dies
  (docs/STRINGS.md) — never verbed.
- **fresh** — an object expression nobody has named yet: `new ...`,
  a literal `[1, 2]`, a slice `xs[a:b]`, a call result, `s.split(x)`,
  `m.keys()`, `pop()`.
- **owned name** — a binding that received a fresh object, a `give`,
  or a `give` parameter.
- **alias** — any other name for an object; reading through it is
  free.
- **poisoned** — a name the compiler refuses to evaluate after
  `give`/`free`, from that line to the end of its scope.

**On the numbering.**  The sections below are ordered by *topic*, and
the numbers were assigned as situations were ratified, so the two do
not run together: section G2 opens at S36 and section H closes at S35.
That is deliberate — a situation belongs beside the ones it is about,
and a number, once a compiler diagnostic quotes it (`[OWNERSHIP.md
S21]`), is not something to renumber.  The site's
[ownership reference](https://luce.luciaos.com/ref/ownership/)
presents the same 43 in numeric order with a stable `#sNN` anchor
each, which is what those diagnostics point at.

---

## A. Creating and dropping

**S1. Fresh object bound to a name — the name's scope owns it.**
```luce
func main():
    var xs = [1, 2, 3]        # xs owns the list
    xs.append(4)
    # scope ends: the list is freed automatically.  No memory words.
```
Decision: this is the default that makes casual code effortless.

**S2. Fresh object in an inner block dies at that block's end.**
```luce
func main():
    if true:
        let inner = new Builder()
        inner.append("hi")
        # inner's block ends: builder freed here
    print("later")            # builder long gone
```
Decision: scope means *lexical block*, not function.

**S3. Unbound temporary dies at the end of its statement.**
```luce
func main():
    for word in "a b c".split(""):   # the list is never named
        print(word)
    # the split list is freed when the for statement completes
    print(String(len("xy".split(""))))  # freed at the end of this line
```
Decision: expression temporaries live exactly as long as the
statement that created them.  Precise wording: "end of the
outermost statement containing the expression."

**S4. Early exits unwind scopes.**
```luce
func first_line(path: String) -> String!:
    var lines = (try file_read(path)).split("\n")   # `try` is one too
    if len(lines) == 0:
        return ""             # lines is freed on the way out
    return copy lines[0]      # (S22: element out via copy — String is
                              # a value, so plain `return lines[0]` is
                              # fine here; shown for shape only)
```
Decision: `return`, `break`, `continue` — and `try`, which arrived
with errors — free what the scopes they exit still own.  No
single-exit contortions, ever.

`try` is the fourth of them and needed no fifth rule: it emits the
same three lines `return` does — release the temporaries, release the
scopes innermost first, terminate — with one terminator changed
(docs/FAILURE.md).  The one difference is what it *keeps*: `return`
passes the returned binding as moved and skips freeing it, and `try`
passes nothing, because it hands back no value.  That one bit is the
whole of what Zig spells `errdefer`, and it was already a parameter of
this unwinder.

**S5. Reassigning an owning `var` frees the old object immediately.**
```luce
func main():
    var grid = new Array(Bool, 10, 10)
    grid = World.step(grid)   # old grid freed right here, new one owned
```
Decision: drop-on-reassign.  This deletes the `let old = grid /
free(old)` dance from life.luc.

**S6. `free(x)` survives as early release.**
```luce
func main():
    var big = file_read("huge.bin").split("\n")
    let count = len(big)
    free(big)                 # done early, on purpose
    # big is poisoned from here on: `big[0]` is a COMPILE error
    print(String(count))
```
Decision: `free` is legal only on owned names and poisons the name
like `give`.  Casual code never needs it.

**S7. A fresh object created inside a loop dies every iteration.**
```luce
func main():
    for i in range(0, 1000):
        var row = new Array(Int, 512)   # fresh each iteration
        row.fill(i)
        # row freed here, every time around — memory stays flat
```
Decision: loop bodies are scopes like any other.

---

## B. Aliasing

**S8. `let x = y` — two names, one object.  No move, no ceremony.**
```luce
func main():
    var xs = [1, 2, 3]
    let view = xs             # alias; xs still owns
    view.append(4)            # mutates the one shared list
    assert(len(xs) == 4)
    # scope end: freed once, via xs's ownership
```
Decision: aliasing is free and untracked.  (Casual users never meet
ownership here.)

**S9. An alias used after the owner is gone traps at use.**
```luce
func main():
    var xs = [1, 2]
    let view = xs
    free(xs)                  # owner releases early
    let bad = view[0]         # RUNTIME trap: use_after_free
```
Decision: this is the accepted cost of no borrow checker.  The trap
is deterministic and names the faulting line.  There is no build mode
that omits it: docs/MODES.md settles that Luce is always ReleaseSafe
and `--release` only strips origin tables.  The check was also measured
free once container access is inlined -- what costs is the control
dependence it creates, not the branch.

The promise is about the *object*, not about the storage it sat in.
The runtime hands a freed object's table row to the next `new`
(docs/MEMORY.md), and a handle names one occupant of a row rather than
the row itself, so `view` above traps identically whether or not
something else has since moved in -- and never reads the newcomer.
Generations do not wrap: a row that runs out of them is retired rather
than reused, because a one-in-four-billion aliasing hole is not a
price S9 pays.

**S10. `let x = give y` — transfer between names; the giver dies.**
```luce
func main():
    var temp = [1, 2, 3]
    let final_hits = give temp   # final_hits owns now
    print(String(temp[0]))          # COMPILE error: temp was given away
```
Decision (yours, verbatim): after `give y`, touching `y` is a compile
error.  People who write `give` know what they are doing.

---

## C. Calls

**S11. Passing an object to a function is a borrow.  Free, silent.**
```luce
func total(values: List(Int)) -> Int:
    var sum = 0
    for v in values:
        sum = sum + v
    return sum

func main():
    var xs = [1, 2, 3]
    print(String(total(xs)))     # no verb; xs still owned by main
```
Decision: borrows are the default at every call.  Mutating through a
borrow is allowed (`values.append(...)` inside would be legal —
borrows are about *lifetime*, not immutability).

**S12. A callee cannot keep a borrowed parameter.**
```luce
func stash(index: Map(String, List(Int)), hits: List(Int)):
    index["latest"] = hits    # COMPILE error: hits is borrowed;
                              # give it at the call site (S13) or
                              # store `copy hits`
```
Decision: keeping (storing into a container/struct, returning,
giving, freeing) requires ownership; borrows can only read, mutate
contents, and pass along as borrows.

**S13. Taking ownership is declared in the signature and echoed at
the call site.**
```luce
func stash(index: Map(String, List(Int)), hits: give List(Int)):
    index["latest"] = give hits    # legal: this function owns hits

func main():
    var index = new Map(String, List(Int))
    var mine = [1, 2]
    stash(index, give mine)   # caller says it out loud too
    print(String(len(mine)))     # COMPILE error: mine was given away
```
Decision: `give` appears at **both ends** — the parameter type and
the call site.  Ownership handoffs are never invisible.

**S14. A fresh argument satisfies a `give` parameter with no verb.**
```luce
    stash(index, [7, 8])      # fresh: nobody owns it yet, no verb
    stash(index, copy mine)   # or: hand over a duplicate, keep mine
```
Decision: verbs mark the transfer of *named* things; fresh values
flow into ownership silently everywhere (bindings, containers,
give-parameters alike).

**S15. A `give` parameter the callee does not pass on dies with the
callee.**
```luce
func consume(xs: give List(Int)):
    print(String(len(xs)))
    # xs freed here — the callee owned it and let it die
```
Decision: a `give` parameter is an owned binding like any other.

---

## D. Returns

**S16. Returning something you own moves it to the caller.  No verb.**
```luce
func load_lines(path: String) -> List(String):
    var lines = file_read(path).split("\n")
    return lines              # moves out; caller's binding owns it

func main():
    var lines = load_lines("notes.txt")   # main owns lines now
    # freed at main's end
```
Decision: `return` is an automatic move — the one place transfer
needs no keyword, because it is unambiguous.

**S17. Returning a borrowed parameter is a compile error.**
```luce
func pick(xs: List(Int)) -> List(Int):
    return xs                 # COMPILE error: xs is borrowed;
                              # `return copy xs`, or take `xs: give List(Int)`
```
Decision: whatever a function returns, the caller owns — no
exceptions, so the guarantee of S16 is absolute.

This is a rule about objects.  A String return copies instead of
erroring, because a String has no verb to demand (S32): `strings.trim`
ends `return s[first:last]`, a view of its parameter, and what comes
out is a copy the caller owns (docs/STRINGS.md).

**S18. Returning a `give` parameter is legal (you own it).**
```luce
func sorted(values: give List(Float)) -> List(Float):
    values.sort()
    return values             # owned in, owned out
```

**S19. An ignored returned object is a temporary (S3).**
```luce
func main():
    load_lines("notes.txt")   # nobody binds it: freed end of statement
```
Decision: no leak, no warning needed.  (Style may frown; memory
doesn't care.)

---

## E. Containers

**S20. Containers adopt fresh values silently.**
```luce
func main():
    var index = new Map(String, List(Int))
    index["a.luc"] = [12, 40]         # map owns the list
    index["b.luc"] = "1 2 3".split("")  # map owns the split result
    var grid = new List(List(Int))
    grid.append(new List(Int))       # outer owns inner
    # freeing/dropping index and grid frees everything they own
```
Decision: container adoption of fresh objects is automatic, and
freeing a container frees the objects it owns, recursively.

**S21. Storing a bare name is a compile error — say what you mean.**
```luce
func main():
    var index = new Map(String, List(Int))
    var hits = [12, 40]
    index["a.luc"] = hits         # COMPILE error:
                                  #   hits is owned by its binding;
                                  #   `give hits` to transfer or `copy hits`
    index["a.luc"] = give hits    # transfer: index owns, hits poisoned
    var template = [0, 0]
    index["b.luc"] = copy template  # duplicate: template stays usable
```
Decision (yours): the rule is hard.  Consequence: **containers always
own their object elements** — a dangling element is unrepresentable.

**S22. Reading elements is borrowing; taking one out is `pop`, an
element overwrite frees the old element.**
```luce
func main():
    var rows = new List(List(Int))
    rows.append([1, 2])
    let peek = rows[0]        # borrow; rows still owns the element
    var taken = rows.pop()    # ownership moves OUT to taken  [NEW]
    rows.append([9, 9])
    rows[0] = [7]             # the [9, 9] list is freed right here
    rows.remove(0)            # removing an owned element frees it
    rows.clear()              # frees all owned elements
```
Decisions: `pop()` hands the element to the receiver (fresh-like);
`remove`/`clear`/overwrite free the owned element immediately.
**[NEW]**: all three of those "container frees the old element"
behaviors.

Implementation addendum (audit 2026-07-30): every container door
enforces S21 — element stores, `append`/`insert`, struct
construction, field assignment, give-parameters, **and list
literals** (`[xs]` is a store like any other).  `fill` on an array
of objects is a compile error outright: one value cannot own every
slot — store per slot instead.  Verbs are likewise refused in pure
borrow positions (builtin arguments, non-adopting method arguments,
operator operands): a give must always have an owner to receive it.

**S23. One object cannot end up owned twice.**
```luce
func main():
    var a = new List(List(Int))
    var b = new List(List(Int))
    var item = [1]
    a.append(give item)       # a owns it; item poisoned
    b.append(give item)       # COMPILE error: item was given away
```
And the alias dodge is caught dynamically:
```luce
    var item2 = [2]
    let alias = item2
    a.append(give item2)      # fine; item2 poisoned
    b.append(give alias)      # RUNTIME trap: object is container-owned
                              # (the one dynamic ownership check)
```
Decision: static poisoning catches the direct case; `give` verifies
binding-ownership at run time for the alias case — trap in safe
builds.

---

## F. Structs

**S24. Structs are values; object fields follow the same verb rule at
construction.**
```luce
struct Bag:
    label: String
    items: List(Int)

func main():
    var bag = Bag(label = "a", items = [1, 2])   # fresh: bag's binding
                                                 # owns the list through
                                                 # the struct
    var loose = [3, 4]
    var bag2 = Bag(label = "b", items = give loose)  # or copy loose
    var bag3 = Bag(label = "c", items = loose)   # COMPILE error (S21)
    # scope end: bag's and bag2's lists freed via their bindings
```
Decision: **own-at-construction** — the binding that receives the
struct owns the objects put into it fresh or by verb.

**S25. Field assignment follows the verb rule; the old owned field
value is freed.**
```luce
    bag.items = [5, 6]        # old list freed, new fresh one owned
    bag.items = give loose2   # transfer into the field
    bag.items = loose3        # COMPILE error (S21)
```

**S26. Struct copies alias the same objects.**
```luce
    let copy_of_bag = bag     # struct copies by value;
    copy_of_bag.items.append(9)
    assert(len(bag.items) == 3)   # same list — aliases (S8)
```
Decision: copying a struct value never duplicates or moves objects;
ownership stays where it was.  (Want independence? `copy` the fields
you care about into a new construction.)

Object fields alias; value fields — Strings and nested plain structs
— copy, so a struct copy is O(bytes of its value fields)
(docs/STRINGS.md).

**S27. A struct that carries objects is itself subject to the verb
rule when *kept*.**
```luce
func main():
    var bags = new List(Bag)
    var bag = Bag(label = "x", items = [1])
    bags.append(bag)          # COMPILE error: Bag carries a List;
                              # `give bag` or `copy bag`
    bags.append(give bag)     # ownership of bag's list moves into bags
    bags.append(Bag(label = "y", items = [2]))   # fresh: silent
```
Decision: the rule is type-driven — any struct type transitively
containing object fields is "object-carrying" and needs a verb to be
kept; plain-value structs (`Point(x, y)`) never do.  `copy` on a
carrying struct deep-copies its owned objects.

**S28. Returning an object-carrying struct moves the whole tree.**
```luce
func make_bag() -> Bag:
    var bag = Bag(label = "n", items = [1, 2])
    return bag                # struct value + owned list move together

func main():
    var mine = make_bag()     # mine's binding owns the list now
```

---

## G. give/copy mechanics

**S29. Poisoning is source-order and branch-insensitive.**
```luce
func main():
    var xs = [1]
    var sink = new List(List(Int))
    if len(xs) > 0:
        sink.append(give xs)  # give inside a branch...
    print(String(len(xs)))       # ...still a COMPILE error after the if:
                              # give poisons to end of scope, period
```
Decision: blunt and predictable beats flow-sensitive and clever.
`copy` is always the escape hatch.

**S30. Giving an outer name from inside a loop is a compile error.**
```luce
func main():
    var xs = [1]
    var sink = new List(List(Int))
    for i in range(0, 3):
        sink.append(give xs)  # COMPILE error: the second iteration
                              # would use a given-away name
    # fix: create fresh inside the loop, or copy
```

**S31. `copy` is a deep copy and is always legal on readable objects.**
```luce
    var nested = new List(List(Int))
    nested.append([1, 2])
    let dup = copy nested     # copies the outer list AND its owned
                              # children; dup is fully independent
    let dup2 = copy borrowed_param   # copying a borrow is fine
```
Decision: `copy` duplicates the object and everything it owns,
recursively.  Its cost is visible at the call site — that is the
point.

**S32. Values never take verbs.**
```luce
    let name = "loom"         # String is a value
    let title = name          # plain copy; both live independently
    give name                 # COMPILE error: give applies to
                              # List/Map/Array/Builder (and carrying
                              # structs), not to values
```

---

## G2. Clarifications from review (round 1)

**S36. Assigning into an outer-declared variable: the object lives in
the variable's declaration scope.**
```luce
func main():
    var report = new Builder()      # declared (and initialized) here
    if verbose:
        report = new Builder()      # old freed (S5); new one owned by
        report.append("details")    # report — which lives in MAIN's scope
    print(report.build())              # object survives the if: ownership
                                    # follows the BINDING, and the binding
                                    # lives where it was DECLARED
```
Decision: ownership hoists naturally through assignment to
outer-declared variables.  The "declare now, create later" story is
S40.

**S37. Values into containers: no ownership, no verbs, ever.**
```luce
func main():
    var x: List(Int) = []
    for i in range(0, 10):
        x.append(i)                 # appends a COPY of the Int value;
                                    # i "dying" each iteration is
                                    # irrelevant — values are copied,
                                    # never owned
    var names: List(String) = []
    names.append("ada")             # String is a value: same story
```
Decision: `give`/`copy`/ownership apply to objects (List, Map,
Array, Builder, carrying structs) only.  Values — Int, Float, Bool,
String, plain structs — copy into containers with zero
ceremony.

**S38. A borrowed parameter may mutate contents — borrows restrict
keeping, not editing.**
```luce
func fill_list(xs: List(Int)):      # borrow
    for i in range(0, 10):
        xs.append(i)                # editing contents: always legal

func main():
    var x: List(Int) = []
    fill_list(x)                    # no verb at either end
    assert(len(x) == 10)            # main still owns x
```
Decision: the borrow/own distinction is purely about *lifetime* —
who frees, and who may extend the object's life (store/return/
give/free).  Content mutation through borrows is the normal way
functions do work.  (Immutability-through-`let` is a separate,
undecided question — see below.)

**S40. Late initialization: `var name: Type` with no value.**
```luce
func main():
    var inner: Builder          # declares name, type, and SCOPE;
                                # holds the null object until assigned
    if condition:
        inner = new Builder()   # the only new; inner (outer scope) owns it
        inner.append("details")
    # condition true:  builder freed at the end of THIS scope
    # condition false: inner is still null — nothing freed, and
    #                  inner.append(...) would trap null_object
```
Decision: the annotation is required (nothing to infer); the
declaration establishes the binding and its scope, assignment fills
it.  Before assignment the variable holds its type's **zero value**
— null for objects (use traps `null_object`, the same state array
elements already start in), 0 / 0.0 / false / "" / zeroed struct for
values.  One rule everywhere: an unfilled slot holds its type's
zero.  The first assignment has no old object to drop; `let` still
requires an initializer (a never-reassignable empty name is a
contradiction).  This is zero-initialization, not `nil` semantics:
a slot that may genuinely hold nothing is a `T?` and says so (S43).

**S39. `let` vs `var` freezes the binding, not the object.**
```luce
func main():
    let xs = [1, 2]
    xs.append(3)                    # legal today: let pins the NAME,
                                    # not the object's contents
    xs = [9]                        # COMPILE error: let cannot re-point
```
Decision (current, needs explicit ratification): `let`/`var` govern
reassignment of the binding only — JavaScript's `const`, not Swift's
`let`.  The alternative (let freezes contents) buys read-only
guarantees at the cost of a const-ness type system; deliberately not
chosen for now.

---

## G3. Null (review round 2)

**S41. "Uninitialized" is a state, not a value — and it cannot be
said.**
```luce
var inner: Builder            # unfilled slot (S40)
# There is NO null literal, no `inner == null`, no nullable returns.
# A parameter or return typed Builder is ALWAYS a real Builder —
# every signature stays trustworthy, nobody checks.
inner.append("x")             # RUNTIME trap: null_object — a bug with
                              # a line number, like index out of bounds
```
Decision: the unfilled state is non-denotable and trapping.  The
"did I set it?" information always already exists as ordinary
program state — the Bool you branched on — and that is where it
belongs:
```luce
var report: Builder
if verbose:
    report = new Builder()
if verbose:
    print(report.build())        # guarded by the same condition; no null
                              # concept needed anywhere
```

**S42. Verbs and borrows on unfilled slots.**
```luce
var inner: Builder
free(inner)                   # RUNTIME trap: null_object (freed nothing)
sink.append(give inner)       # RUNTIME trap: null_object (gave nothing)
helper(inner)                 # passing does NOT trap; the callee traps
                              # at first USE — same as null array
                              # elements today
```
Decision: `give`/`copy`/`free` demand an object and trap on null;
borrows trap at use, not at handoff.  (The alternative — eager trap
at the call site — is stricter but inconsistent with array
elements; flagged for review.)

**S43. Absence owns nothing: nullable memory management needs no
rules.**
- Scope exit or reassignment of an unfilled slot frees nothing.
- Freeing a container skips null elements (already true for fresh
  object-typed Arrays).
- Optionals inherit S1–S42 unchanged: a `Builder?` holding an object
  owns it like any binding; holding `none` owns nothing.  Nothing in
  this document changed when `T?` arrived, which is the strongest
  thing that can be said about it.

**Errors, as they shipped** (docs/FAILURE.md, docs/LANGUAGE.md).
Nothing in this document changed for them either, and the reason is
S4: the unwinder was already static, already emitted at compile time,
and already knew the one thing an error path needs to know.  What a
`try` releases is what a `return` on the same line would release.  The
two shapes that did have to be settled were both about *where*, not
*what*.  A fallible call's value crosses the branch on its outcome
through a hidden slot, and that slot is the one that **owns** it (S3):
one place rather than two, with the statement's temporary recorded on
the returning side, so the failing side never releases what it never
stored.  And one value is parked once, because `try f()` hands back
what `f()` produced and two hidden locals claiming one String's bytes
free them twice.

**Optionals, as they shipped** (docs/FAILURE.md, docs/LANGUAGE.md).
When absence is part of a *contract* — `parse_int(s)` on text that is
not a number — the answer is a distinct type, not implicit
nullability: `Builder?` is not `Builder`, and `none` is legal only
where a `T?` is expected, so a plain type can never hold it and the
billion-dollar mistake stays impossible.  A `T?` is tested
(`x == none`) and **narrowed** — inside `if x != none:` the name *is*
its payload — or read with a fallback (`x else 0`).  There is no
force-unwrap sigil; `x else trap("…")` is the assert-unwrap, and it
is greppable.  What that costs ownership is nothing: `give`, `copy`
and `free` demand a value that is there and so demand narrowing
first, and every runtime walk already no-ops on absence.

---

## H. Program edges

**S33. Nothing can leak.**  Every object is owned by a binding, a
container, or is a statement temporary; all three have defined death
points.  loom's "leaked N objects" report becomes an internal
assertion (it should never fire; if it does, the *runtime* has a bug,
not the program).

**S34. The call-depth budget and traps still abort cleanly.**  On any
trap, teardown reclaims everything regardless of ownership state:
whatever the unwind never released, the runtime releases when the run
ends.  Ownership never leaks because a program failed.

An **error** is the other case and gets no such safety net, because it
does not end the run: a `catch` resumes with the program still going.
So error propagation releases precisely, the way `return` does (S4),
and never the way a trap does.  The leak census is what proves it —
`agree` compares it after a caught error, and a frame that forgot
something would show up there as a number.

**S35. File scope owns nothing, so a constant is a value.**  The three
owner kinds in S33 are a binding, a container, and the statement
temporary — every one of them lives inside a function.  A top-level
`let` has no scope to die at, so it cannot own, and therefore cannot
be or carry an object: `new`, list literals, slices and indexing are
all refused there, as is a struct whose layout carries objects.  What
remains — scalars, String, and object-free structs — folds at compile
time and inlines at its use sites, which is why an unused constant
costs nothing to ship.

This is the rule the analyzer already cites when it refuses a
file-scope object; the restriction is ownership, not an arbitrary
limit on what constants may say.

---

## Deliberately excluded from v1

- `share` (opt-in refcounted islands) — **refused permanently, not
  deferred.**  Reference counting is off the table at every layer of
  Luce, in the language and in the runtime alike (`docs/MEMORY.md`).
  A program that needs genuinely shared ownership restructures, or
  uses indices into a container it owns.
- Weak references — only meaningful once `share` exists, so never.
- Arenas as a *language* feature — the runtime may use them as an
  optimization invisibly.
- `defer` — no longer needed for memory; may return later for host
  cleanup (files, terminal), as a separate decision.
