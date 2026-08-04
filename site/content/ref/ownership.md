# Ownership

The memory model, as ratified: forty-three numbered situations, each
with a fixed anchor. The compiler quotes these numbers in its
diagnostics — a message ending `[OWNERSHIP.md S21]` points at
[S21](#s21) below — and an executable specification in the repository
runs every one of them.

[Memory without a collector](/guide/memory/) is the rationale;
[the tour chapter](/tour/ownership/) is the introduction. This page is
the rules.

## Vocabulary

**object** — a heap value: `List`, `Map`, `Array`, `Builder`.
Everything else (`Int`, `Float`, `Bool`, `String`, structs)
is a **value**: copied freely, never freed by the program, never
verbed. The runtime reclaims a value's storage when the place holding
it dies.

**fresh** — an object expression nobody has named yet: `new ...`, a
literal `[1, 2]`, a slice `xs[a:b]`, a call result, `s.split(x)`,
`m.keys()`, `pop()`.

**owned name** — a binding that received a fresh object, a `give`, or
a `give` parameter.

**alias** — any other name for an object. Reading through one is free.

**poisoned** — a name the compiler refuses to evaluate after `give` or
`free`, from that line to the end of its scope.

---

## A. Creating and dropping

### S1 — a fresh object bound to a name is owned by that name's scope {#s1}

The default that makes casual code effortless. Casual code writes no
memory word at all.

### S2 — a fresh object in an inner block dies at that block's end {#s2}

Scope means *lexical block*, not function.

### S3 — an unbound temporary dies at the end of its statement {#s3}

Precisely: at the end of the outermost statement containing the
expression.

```luce run
import std.strings

func main():
    for word in "a b c".split(""):   # the list is never named
        print(word)
    # the split list is freed when the for statement completes
    print(String(len("xy".split(""))))  # freed at the end of this line
```

```output
a
b
c
1
```

### S4 — early exits unwind scopes {#s4}

`return`, `break`, `continue` and `try` free what the scopes they
exit still own. No single-exit contortions, ever.

`try` needed no rule of its own: it emits the same three lines
`return` does — release the temporaries, release the scopes innermost
first, terminate — with one terminator changed. The one difference is
what it *keeps*: `return` passes the returned binding as moved and
skips freeing it, and `try` passes nothing. That single bit is the
whole of what Zig spells `errdefer`.

### S5 — reassigning an owning `var` frees the old object immediately {#s5}

Drop-on-reassign.

### S6 — `free(x)` survives as early release {#s6}

Legal only on owned names, and it poisons the name like `give`. Casual
code never needs it.

### S7 — a fresh object created inside a loop dies every iteration {#s7}

Loop bodies are scopes like any other, so memory stays flat.

---

## B. Aliasing

### S8 — `let x = y` is two names for one object {#s8}

No move, no ceremony, no tracking. Aliasing is free.

### S9 — an alias used after the owner is gone traps at use {#s9}

`use_after_free`, deterministic, naming the faulting line. This is the
accepted cost of having no borrow checker, and there is no build mode
that omits it.

The promise is about the **object**, not the storage. The runtime
hands a freed object's table row to the next `new`, and a handle names
one occupant of a row rather than the row itself, so an alias traps
identically whether or not something else has since moved in — and
never reads the newcomer. Generations do not wrap: a row that runs out
of them is retired rather than reused.

```luce trap
func main():
    var xs = [1, 2]
    let view = xs
    free(xs)
    let bad = view[0]
    print(String(bad))
```

```output
loom: trap: object used after free [use_after_free]
    at main (main.luc:5:5)
```

### S10 — `let x = give y` transfers; the giver dies {#s10}

After `give y`, touching `y` is a compile error.

---

## C. Calls

### S11 — passing an object to a function is a borrow {#s11}

Free and silent. Borrows are the default at every call.

### S12 — a callee cannot keep a borrowed parameter {#s12}

Keeping means storing into a container or struct, returning, giving,
or freeing. A borrow may read, mutate contents, and pass along as a
borrow.

```luce fail
func stash(index: Map(String, List(Int)), hits: List(Int)):
    index["latest"] = hits

func main():
    var index = new Map(String, List(Int))
    stash(index, [1, 2])
```

```output
luce: compile failed
main.luc:2:5: a container keeps its object elements; hits is a borrowed parameter and can never be given away — store copy hits, or take hits as give in the signature [OWNERSHIP.md S12, S21] [luce.sema.own]
        index["latest"] = hits
        ^~~~~~~~~~~~~~~~~~~~~~
```

### S13 — taking ownership is declared in the signature and echoed at the call site {#s13}

`give` appears at **both** ends. Ownership handoffs are never
invisible.

### S14 — a fresh argument satisfies a `give` parameter with no verb {#s14}

Verbs mark the transfer of *named* things. Fresh values flow into
ownership silently everywhere — bindings, containers and `give`
parameters alike.

### S15 — a `give` parameter the callee does not pass on dies with the callee {#s15}

A `give` parameter is an owned binding like any other.

---

## D. Returns

### S16 — returning something you own moves it to the caller {#s16}

`return` is an automatic move — the one place transfer needs no
keyword, because it is unambiguous.

### S17 — returning a borrowed parameter is a compile error {#s17}

Whatever a function returns, the caller owns; no exceptions, so
[S16](#s16) is absolute. Write `return copy xs`, or take
`xs: give List(Int)`.

This is a rule about **objects**. A `String` return copies instead of
erroring, because a `String` has no verb to demand ([S32](#s32)):
`strings.trim` ends `return s[first:last]`, a view of its parameter,
and what comes out is a copy the caller owns.

### S18 — returning a `give` parameter is legal {#s18}

Owned in, owned out.

### S19 — an ignored returned object is a temporary {#s19}

[S3](#s3) applies: no leak, no warning.

---

## E. Containers

### S20 — containers adopt fresh values silently {#s20}

Freeing a container frees the objects it owns, recursively.

### S21 — storing a bare name is a compile error {#s21}

Say what you mean: `give` to transfer, `copy` to duplicate. The
consequence is that **containers always own their object elements** —
a dangling element is unrepresentable.

```luce fail
func main():
    var index = new Map(String, List(Int))
    var hits = [12, 40]
    index["a.luc"] = hits
```

```output
luce: compile failed
main.luc:4:5: a container keeps its object elements; write give hits to hand it over, or copy hits to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        index["a.luc"] = hits
        ^~~~~~~~~~~~~~~~~~~~~
```

Every container door enforces this: element stores, `append`,
`insert`, struct construction, field assignment, `give` parameters,
**and list literals** — `[xs]` is a store like any other. `fill` on an
array of objects is refused outright, because one value cannot own
every slot; store per slot instead.

### S22 — reading elements borrows; taking one out is `pop`; overwriting frees the old one {#s22}

`pop()` hands the element to the receiver. `remove`, `clear` and
overwriting an element free the owned element immediately.

```luce run
func main():
    var rows = new List(List(Int))
    rows.append([1, 2])
    let peek = rows[0]        # a borrow; rows still owns it
    print(f"peek {len(peek)}")

    var taken = rows.pop()    # ownership moves out
    print(f"taken {len(taken)}, rows {len(rows)}")

    rows.append([9, 9])
    rows[0] = [7]             # the [9, 9] list is freed right here
    rows.remove(0)            # removing an owned element frees it
    rows.clear()
    print(f"rows {len(rows)}")
```

```output
peek 2
taken 2, rows 0
rows 0
```

### S23 — one object cannot end up owned twice {#s23}

Static poisoning catches the direct case. The alias dodge is caught
dynamically: `give` verifies binding-ownership at run time and traps
`not_owned`. It is the one dynamic ownership check.

---

## F. Structs

### S24 — structs are values; object fields follow the verb rule at construction {#s24}

Own-at-construction: the binding that receives the struct owns the
objects put into it fresh or by verb.

### S25 — field assignment follows the verb rule; the old owned field value is freed {#s25}

### S26 — struct copies alias the same objects {#s26}

Copying a struct value never duplicates or moves objects; ownership
stays where it was. Object fields alias; value fields — `String`s and
nested plain structs — copy, so a struct copy costs the bytes of its
value fields.

### S27 — an object-carrying struct is subject to the verb rule when kept {#s27}

The rule is type-driven: any struct type transitively containing
object fields is object-carrying and needs a verb to be kept.
Plain-value structs never do. `copy` on a carrying struct deep-copies
its owned objects.

```luce fail
struct Bag:
    label: String
    items: List(Int)

func main():
    var bags = new List(Bag)
    var bag = Bag(label = "x", items = [1])
    bags.append(bag)
```

```output
luce: compile failed
main.luc:8:17: a container keeps its object elements; write give bag to hand it over, or copy bag to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        bags.append(bag)
                    ^~~
```

### S28 — returning an object-carrying struct moves the whole tree {#s28}

---

## G. give and copy mechanics

### S29 — poisoning is source-order and branch-insensitive {#s29}

`give` inside a branch still poisons the name after the `if`. Blunt
and predictable beats flow-sensitive and clever; `copy` is always the
escape hatch.

### S30 — giving an outer name from inside a loop is a compile error {#s30}

The second iteration would use a given-away name. Create fresh inside
the loop, or copy.

### S31 — `copy` is a deep copy and is always legal on readable objects {#s31}

It duplicates the object and everything it owns, recursively,
including through a borrowed parameter. Its cost is visible at the
call site — that is the point.

### S32 — values never take verbs {#s32}

`give` and `copy` apply to `List`, `Map`, `Array`, `Builder` and
carrying structs, and to nothing else.

```luce fail
func main():
    let name = "loom"
    let title = give name
    print(title)
```

```output
luce: compile failed
main.luc:3:17: give applies to objects (List, Map, Array, Builder, object-carrying structs), not values [OWNERSHIP.md S32] [luce.sema.own]
        let title = give name
                    ^~~~~~~~~
```

---

## H. Program edges

### S33 — nothing can leak {#s33}

Every object is owned by a binding, a container, or a statement
temporary, and all three have defined death points. The runtime's
leak census is an internal assertion: if it fires, the *runtime* has a
bug, not the program.

### S34 — traps and the depth budget abort cleanly {#s34}

On any trap, teardown reclaims everything regardless of ownership
state. Ownership never leaks because a program failed.

An **error** is the other case and gets no such safety net, because it
does not end the run: a `catch` resumes with the program still going.
So error propagation releases precisely, the way `return` does
([S4](#s4)), and never the way a trap does. The leak census is what
proves it.

### S35 — file scope owns nothing, so a constant is a value {#s35}

The three owner kinds in [S33](#s33) all live inside a function. A
top-level `let` has no scope to die at, so it cannot own, and
therefore cannot be or carry an object: `new`, list literals, slices
and indexing are all refused there, as is a struct whose layout
carries objects.

---

## G2. Clarifications

### S36 — assignment into an outer-declared variable keeps the object in the declaring scope {#s36}

Ownership follows the **binding**, and the binding lives where it was
declared.

### S37 — values into containers need no ownership and no verbs, ever {#s37}

`Int`, `Float`, `Bool`, `String` and plain structs copy into
containers with zero ceremony. A loop variable "dying" each iteration
is irrelevant: values are copied, never owned.

### S38 — a borrowed parameter may mutate contents {#s38}

The borrow/own distinction is purely about *lifetime* — who frees, and
who may extend the object's life. Content mutation through a borrow is
the normal way functions do work.

### S39 — `let` and `var` freeze the binding, not the object {#s39}

JavaScript's `const`, not Swift's `let`.

### S40 — `var name: Type` declares now and fills later {#s40}

The annotation is required, since there is nothing to infer. The
declaration establishes the binding and its scope; assignment fills
it. Before assignment the slot holds the type's **zero value** — null
for objects, and `0`/`0.0`/`false`/`""`/a zeroed struct for values.
The first assignment has no old object to drop.

---

## G3. Null and absence

### S41 — "uninitialized" is a state, not a value, and it cannot be said {#s41}

There is no null literal and no `x == null`. A parameter or return
typed `Builder` is always a real `Builder`, so every signature stays
trustworthy and nobody checks. Using an unfilled object slot traps
`null_object` — a bug with a line number, like an index out of bounds.

```luce trap
func main():
    var report: Builder
    report.append("x")
```

```output
loom: trap: null object reference [null_object]
    at main (main.luc:3:5)
```

### S42 — verbs demand a filled slot; borrows trap at use {#s42}

`give`, `copy` and `free` trap `null_object` on an unfilled slot.
Passing an unfilled slot does **not** trap; the callee traps at first
use.

### S43 — absence owns nothing {#s43}

Scope exit or reassignment of an unfilled slot frees nothing. Freeing
a container skips null elements. Optionals inherit S1–S42 unchanged: a
`Builder?` holding an object owns it like any binding, and holding
`none` owns nothing.

Nothing in this document changed when `T?` arrived, which is the
strongest thing that can be said about it. Nothing changed for errors
either, and the reason is [S4](#s4): the unwinder was already static,
already emitted at compile time, and already knew the one thing an
error path needs to know.

---

## Deliberately excluded

- **`share`** — opt-in reference-counted islands. Refused
  **permanently**, not deferred. Reference counting is off the table
  at every layer of Luce, in the language and in the runtime alike.
- **Weak references** — only meaningful once `share` exists, so never.
- **Arenas as a language feature** — the runtime may use them as an
  invisible optimisation.
- **`defer`** — no longer needed for memory. It may return later for
  host cleanup, as a separate decision.
- **`errdefer`** — refused, with reasons; see [S4](#s4).
