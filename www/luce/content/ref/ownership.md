# Ownership

The memory model, as ratified: forty-six numbered situations, each
with a fixed anchor. The compiler quotes these numbers in its
diagnostics — a message ending `[OWNERSHIP.md S21]` points at
[S21](#s21) below — and an executable specification in the repository
runs every one of them.

[Memory without a collector](/guide/memory/) is the rationale;
[the tour chapter](/tour/ownership/) is the introduction. This page is
the rules.

## Vocabulary

**container object** — one of `list`, `map`, `array`, `builder`. It
owns the elements it keeps and may be deep-copied when its complete
type graph carries no resource.

**resource** — a scope-owned heap handle with one external thing behind
it: `file` or `task`. It moves with `give` or `return` and releases with
`free` or scope end, but cannot be copied: two handles would mean two
owners of one file or worker.

The established clause titles below use **object-carrying struct** for
any struct carrying an owned thing. That legacy term includes resources;
the clause text states where a resource's no-copy rule is stricter.

Numbers, `bool`, `string`, enums, function values and structs carrying
no object or resource are **values**: copied freely, never freed by the
program, never verbed. A struct that carries an object or resource
follows that owned thing's rules when it is kept. The runtime reclaims
a value's storage when the place holding it dies.

**fresh** — an admitted owned expression nobody has named yet: `new ...`, a
literal `[1, 2]`, an admitted slice `xs[a:b]`, a call result, `s.split(x)`,
`m.keys()`, `pop()`, `files.open(path)` or `spawn f()`.

**owned name** — a binding that received a fresh owned thing, a `give`, or
a `give` parameter.

**alias** — any other name for an object or resource. Reading through
one is free.

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
    print(string(len("xy".split(""))))  # freed at the end of this line
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

Reassignment still needs a genuinely new owner. A resource-bearing
`x = x` or `x = alias_of_x` is refused as a redundant same-graph
assignment; `x = give x` would make one binding both the poisoned source
and the receiving destination.

### S6 — `free(x)` survives as early release {#s6}

Legal only on an owned container or resource handle, and it poisons the
name like `give`. A carrying struct still releases its fields at scope
end; explicitly freeing the whole struct is not in the current surface.
Casual code never needs it.

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
    print(string(bad))
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
func stash(index: map(string, list(long)), hits: list(long)):
    index["latest"] = hits

func main():
    var index = new map(string, list(long))
    stash(index, [1, 2])
```

```output
luce: compile failed
main.luc:2:5: a container keeps its owned elements; hits is a borrowed parameter and can never be given away — store copy hits, or take hits as give in the signature [OWNERSHIP.md S12, S21] [luce.sema.own]
        index["latest"] = hits
        ^~~~~~~~~~~~~~~~~~~~~~
```

### S13 — taking ownership is declared in the signature and echoed at the call site {#s13}

`give` appears at **both** ends. Ownership handoffs are never
invisible.

For a resource graph this means the complete handoff: change the
borrowing parameter to `give`, make every caller pass an owning name
with `give` (or a fresh value without a verb), and move the parameter at
the retaining site. A field/index view or an alias with no available
live owner can remain a borrow, but cannot be copied or given; an
adopting use needs a distinct owned graph or a restructured handoff.

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
`xs: give list(long)`.

This is a rule about **objects**. A `string` return copies instead of
erroring, because a `string` has no verb to demand ([S32](#s32)):
`strings.trim` ends `return s[first:last]`, a view of its parameter,
and what comes out is a copy the caller owns.

### S18 — returning a `give` parameter is legal {#s18}

Owned in, owned out.

### S19 — an ignored returned object is a temporary {#s19}

[S3](#s3) applies: no leak, no warning.

---

## E. Containers

### S20 — containers adopt fresh values silently {#s20}

Releasing a container recursively releases the container objects and
resources it owns. An object cannot be adopted by itself or one of its
descendants: a visible same-root handoff is a compile error, while an
alias-hidden retaining store traps `ownership_cycle` before mutation.

### S21 — storing a bare name is a compile error {#s21}

Say what you mean: `give` to transfer, or `copy` to duplicate a
resource-free graph. The consequence is that **containers always own
their owned elements** — container objects, resources, or carrying
structs — so a dangling element is unrepresentable.

```luce fail
func main():
    var index = new map(string, list(long))
    var hits: list(long) = [12, 40]
    index["a.luc"] = hits
```

```output
luce: compile failed
main.luc:4:5: a container keeps its owned elements; write give hits to hand it over, or copy hits to keep your own [OWNERSHIP.md S21] [luce.sema.own]
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
overwriting an element release the owned element immediately.

```luce run
func main():
    var rows = new list(list(long))
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

Static poisoning catches the direct case: a name that was given away
cannot be given again.

```luce fail
func main():
    var a = new list(list(long))
    var b = new list(list(long))
    var item: list(long) = [1]
    a.append(give item)
    b.append(give item)
```

```output
luce: compile failed
main.luc:6:14: item was given away and cannot be touched again in this scope [OWNERSHIP.md S10, S29] [luce.sema.own]
        b.append(give item)
                 ^~~~~~~~~
```

The alias dodge — a second name for the same object, given away after
the first one was — is caught the same way. An alias owns nothing, and
the compiler knows it is one where it stands:

```luce fail
func main():
    var a = new list(list(long))
    var b = new list(list(long))
    var item: list(long) = [1]
    let alias = item
    a.append(give item)
    b.append(give alias)
```

```output
luce: compile failed
main.luc:7:14: alias aliases an object it does not own; give the owning name, or copy alias [OWNERSHIP.md S8, S23] [luce.sema.own]
        b.append(give alias)
                 ^~~~~~~~~~
```

Where the owner is still an owner, the refusal names it:

```luce fail
func take(xs: give list(long)) -> long:
    return len(xs)

func main():
    var xs = [1, 2]
    let view = xs
    let n = take(give view)
```

```output
luce: compile failed
main.luc:7:18: view aliases an object it does not own; give xs (the owner), or copy view [OWNERSHIP.md S8, S23] [luce.sema.own]
        let n = take(give view)
                     ^~~~~~~~~
```

The two fixes it names both work: `give xs` hands over the owner, and
`copy view` makes a second object so both names have one.

```luce run
func take(xs: give list(long)) -> long:
    return len(xs)

func main():
    var xs: list(long) = [1, 2]
    let view = xs
    print(string(len(view)))
    print(string(take(give xs)))
```

```output
2
2
```

This was a run-time check until 2026-08-04 — the one dynamic
ownership check, trapping `not_owned`. It is a compile error now.
The trap remains in the runtime as defense against a module the
compiler did not produce, and **no source program can reach it**.

---

## F. Structs

### S24 — a struct's value representation copies; owned fields follow the verb rule at construction {#s24}

Own-at-construction: the binding that receives the struct owns the
container objects or resources put into it fresh or by verb. Its
plain-value fields still copy as values do.

### S25 — field assignment follows the verb rule; the old owned field value is freed {#s25}

### S26 — struct copies alias the same objects {#s26}

Assigning a struct value never duplicates or moves an owned field;
container and resource handles alias and ownership stays where it was.
Value fields — `string`s and nested plain structs — copy, so the
assignment costs the bytes of those fields.

### S27 — a struct carrying a container object or resource is subject to the verb rule when kept {#s27}

The rule is type-driven: any struct type transitively containing
container objects or resources is object-carrying in the compiler's
established term and needs a verb to be kept. Plain-value structs never
do. `give` moves either kind. `copy` deep-copies only a resource-free
carrying struct; one carrying `file` or `task` cannot be copied.

```luce fail
struct Bag:
    label: string
    items: list(long)

func main():
    var bags = new list(Bag)
    var bag = Bag(label = "x", items = [1])
    bags.append(bag)
```

```output
luce: compile failed
main.luc:8:17: a container keeps its owned elements; write give bag to hand it over, or copy bag to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        bags.append(bag)
                    ^~~
```

### S28 — returning an object-carrying struct moves the whole tree {#s28}

---

## G. give and copy mechanics

### S29 — poisoning is source-order and branch-insensitive {#s29}

`give` inside a branch still poisons the name after the `if`. Blunt
and predictable beats flow-sensitive and clever. For a resource-free
graph, `copy` is the escape hatch; a resource graph must instead be
created inside the branch or moved only once.

### S30 — giving an outer name from inside a loop is a compile error {#s30}

The second iteration would use a given-away name. Create fresh inside
the loop, or copy a resource-free graph.

### S31 — `copy` is a deep copy of a readable copyable object {#s31}

It duplicates the object and everything it owns, recursively,
including through a borrowed parameter. Its cost is visible at the
call site — that is the point. A `file`, a `task`, or anything carrying
one cannot be copied: there is one resource, so `give` of a live owning
name is what moves it. A borrowed or ownerless view has nothing it may
hand over.

### S32 — values never take verbs {#s32}

`give` applies to container objects, resources and carrying structs.
`copy` applies only where [S31](#s31) can make an independent owner.
Values take neither: they copy by themselves.

```luce fail
func main():
    let name = "loom"
    let title = give name
    print(title)
```

```output
luce: compile failed
main.luc:3:17: give applies to containers and resources (list, map, array, builder, file, task) and structs that carry them, not values [OWNERSHIP.md S32] [luce.sema.own]
        let title = give name
                    ^~~~~~~~~
```

---

## H. Program edges

### S33 — nothing can leak {#s33}

Every ordinary run-created object or resource is owned by a binding, a
container, or a statement temporary, and all three have defined death
points.
[S46](#s46)'s constant containers have the program root as their
fourth owner and die at runtime teardown. The runtime's leak census is
an internal assertion: if it fires, the *runtime* has a bug, not the
program.

Every retaining store preserves those death points. Stage 4 refuses a
visible attempt to give an owning graph into itself or one of its
descendants. If aliases or parameters hide the ancestry, the runtime
walks the target's exact owner chain and traps `ownership_cycle` before
mutation. Trees may be arbitrarily deep, but they cannot become cycles
with no owner outside them.

### S34 — traps and the depth budget abort cleanly {#s34}

On any trap, teardown reclaims everything regardless of ownership
state. Ownership never leaks because a program failed.

An **error** is the other case and gets no such safety net, because it
does not end the run: a `catch` resumes with the program still going.
So error propagation releases precisely, the way `return` does
([S4](#s4)), and never the way a trap does. The leak census is what
proves it.

### S35 — folded file-scope constants are values {#s35}

The three user owner kinds in [S33](#s33) live inside a function.
Folded file-scope values therefore inline and own nothing. The program
root introduced by [S46](#s46) is the separate owner for the flat
constant containers that deliberately live for the whole runtime.

---

## G2. Clarifications

### S36 — assignment into an outer-declared variable keeps the object in the declaring scope {#s36}

Ownership follows the **binding**, and the binding lives where it was
declared.

### S37 — values into containers need no ownership and no verbs, ever {#s37}

`long`, `double`, `bool`, `string` and plain structs copy into
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
typed `builder` is always a real `builder`, so every signature stays
trustworthy and nobody checks. Using an unfilled object slot traps
`null_object` — a bug with a line number, like an index out of bounds.

```luce trap
func main():
    var report: builder
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
`builder?` holding an object owns it like any binding, and holding
`none` owns nothing.

Nothing in this document changed when `T?` arrived, which is the
strongest thing that can be said about it. Nothing changed for errors
either, and the reason is [S4](#s4): the unwinder was already static,
already emitted at compile time, and already knew the one thing an
error path needs to know.

### S44 — the entry's arguments are handed in, and `main`'s scope owns them {#s44}

```luce run args=fig date
func main(args: list(string)):
    for name in args:
        print(name)
    # scope ends: the list is freed here, like any owned binding
```

```output
fig
date
```

`main`'s `args` is an owned binding of the kind [S15](#s15) describes —
a parameter that arrived owning its object — and the caller that gave
it is the runtime rather than a call site, which is why the signature
carries no `give` and why [S13](#s13) has no second end to echo at.
Everything else follows unchanged: `args` may be read, iterated,
indexed, sliced, given away or freed like any owned name, and whatever
it still owns when `main` returns is freed by `main`'s scope
([S1](#s1), [S33](#s33)). A host that supplies no arguments supplies an
**empty** list, never a null one.

`func main(args: give list(string)):` is refused. The verb would be
noise on a signature with nobody to say it back.

### S45 — a multiple return moves each value, and no object twice {#s45}

```luce run
func halves(n: long) -> (list(long), list(long)):
    var head = [n]
    var tail = [n + 1]
    return head, tail        # both move; the caller's two names own them

func main():
    let head, tail = halves(7)
    print(f"{head[0]} {tail[0]}")
    free(head)
    free(tail)
```

```output
7 8
```

`return a, b` applies [S16](#s16)/[S17](#s17) to each value, then adds
the facts that exist only across slots. A destructuring bind creates one
owning binding per name ([S1](#s1)), so returned object graphs must be
distinct. Stage 4 resolves visible roots before lowering the shape: an
owner beside its alias, a repeated borrow, and `return x, give x` are
one graph trying to fill two results. The repair is distinct owned
graphs or a changed return shape, never another spelling that repeats
the same graph.

The existing-name form `a, b = f()` adds [S5](#s5) on the receiving
side. Every object-carrying target must still be a live owning `var`;
an alias is refused by [S8](#s8), and a target already `give`n or
`free`d — including one consumed by the call on the right — remains
poisoned by [S10](#s10). All answers are extracted, fitted and made
safe to store before any old target is released. Only then does S5
release each old owner and adopt each new answer, left to right. If a
guarded call fails, none of those replacement releases or stores runs.
Ordinary side effects from evaluating the right side have already
happened and are not rolled back.

Evaluation order adds one more cross-slot rule. Stage 4 records an owning
bare name's replacement revision when that operand is staged. A writing
operation to the left is legal: the later bare name stages the replacement.
A later result may not give away or replace a name whose old value is
already staged, including through a nested ownership-taking call or a
writing method. Put that operation first, then return distinct current
values.

```luce fail
func bad(xs: give list(long)) -> (list(long), list(long)):
    return xs, xs

func main():
    var mine: list(long) = [1]
    let a, b = bad(give mine)
    free(a)
    free(b)
```

```output
luce: compile failed
main.luc:2:16: xs is returned twice; one object cannot be owned twice [OWNERSHIP.md S23, S45] [luce.sema.own]
        return xs, xs
                   ^~
```

A call whose values nobody binds is a statement temporary per
[S3](#s3)/[S19](#s19), released whole at the end of its statement.

### S46 — a constant container belongs to the program root {#s46}

A flat list, map or rank-1 array declared with file-scope `const` is
folded into the module, materialized before any function executes and
held until that runtime is torn down. The program root is a real owner
with a real death point. Its rows are excluded from the user leak
census while deliberately live. Every worker runtime materializes its
own roots, so roots never cross between runtimes.

```luce run
const TABLE: list(long) = [3, 1, 2]
const SAME = TABLE

func first(values: list(long) = TABLE) -> long:
    return values[0]

func main():
    assert(TABLE == SAME)
    var editable = copy TABLE
    editable.sort()
    print(f"{editable[0]} {first()}")
```

```output
1 3
```

Aliasing, importing, passing and a borrowing parameter default keep
the same root handle. A separately written equal construction has a
different identity. `copy TABLE` answers a fresh mutable object with
an ordinary binding owner.

`give`, `free`, returning the root or retaining it in another owner
would move or end the program root, so each is a compile error that
recommends `copy`. Direct and aliased mutation is refused too. A
borrow through a parameter can hide the root's identity from the
analyzer, so every runtime mutation path traps `immutable_object`
before writing. Neither boundary silently copies or drops the write.

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
