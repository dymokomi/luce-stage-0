# Receivers, and the arguments `main` is handed

> **Spellings, since this was decided.**  The builtin type names are
> lowercase (`long`, `double`, `string`, `list`, `map`, `array`,
> `builder` — docs/TYPES.md D8), and the two numeric types became four:
> `int` and `float` are 32 bits and are what a literal takes with
> nothing to tell it otherwise, `long` and `double` are the 64-bit
> types this memo calls `Int` and `Float`.  A fenced block tagged
> `luce historical` is shown as it was written and is not compiled;
> every other one in this file is (`tools/doccheck.zig`).

> **The rule.** A function names what it operates on. The program's
> arguments stop being an ambient service and become `main`'s
> parameter; a function that works on a struct stops carrying its
> receiver as a convention in the first parameter's *name* and says
> `self`. Nothing else changes: `x.foo()` is still sugar for a plain
> call with the receiver first, and there is still no dispatch, no
> reference type, and no function value.  [The last clause has since
> lapsed — `docs/FUNCTIONS.md`; see the supersession note at the end.]

`docs/MISSING.md`'s **"The order to work down"** item 10 reads
*"Decide receivers and multiple returns — one memo each."*  (This memo
first called it "Tier 4 item 10"; that list is in no Tier at all, and
`docs/NUMERICS.md` invented a different Tier for the same line.  Both
are corrected here and in that file.)  This is the
receivers memo, and it carries the entry's arguments with it because
the two decisions are the same sentence said twice.

---

## What the corpus actually says, and where the brief was wrong

This memo was commissioned on the claim that *"10/10 functions in
`struct Text` take the struct first"* and that 87 call sites are
waiting to become method calls. Both halves are wrong, and the
correction changes the shape of the feature, so it goes first.

`struct Text`'s functions take **`value: String`** first, not `Text`.
`Text` has no fields. Across the whole `.luc` corpus:

| | count |
|---|---|
| structs declared | 12 |
| fieldless structs used as namespaces | 9 |
| structs with fields and no functions | 3 |
| structs with **both** fields and functions | **0** |
| functions declared inside a struct | 44 |
| …whose first parameter is the **enclosing** struct | **0** |
| …whose first parameter is *some* struct (`state: State`) | 6 |
| …whose first parameter is a `String` | 21 |
| namespaced `Struct.func(…)` call sites | **88**, not 87 |

`docs/MISSING.md:220-226` already had this right — *"nine of twelve
structs in `examples/` have **no fields at all** — namespaces
impersonating types"* — and `docs/audit/DOCS.md:445` already recorded
the count as 88.

**So `self` converts nothing mechanically.** Not one function in the
corpus is the `Struct.f(self: Struct, …)` shape that a receiver
attaches to. The 88 namespaced calls are calls on *folders*, and they
stay namespaced calls, because a folder has no receiver. What the
feature buys is the ability to **restructure**: `Handle`'s four
functions and two of `Draw`'s take `state: State` and live in a
different struct from the type they operate on, so they can move into
`struct State` and become methods; `std/math.luc:237`'s
`random_step(rng: List(Int))` carries its state in a one-element list
*purely* to get mutation through a reference, and can become a struct.
That is the whole immediate harvest: **two merges and one deleted
workaround.**

This is worth saying plainly because it sets the schedule. Shipping
`self` and rewriting `editor.luc` are two separate, separately
reviewable pieces of work, and the second is the one that proves the
first.

The site, meanwhile, already teaches the shape the programs never use
— `www/luce/content/tour/functions.md:72` and
`www/luce/content/examples/structs.md:7` both show `struct Rect` with
`func area(r: Rect)` — and both pages promise in prose that `self`
does not exist. Those two sentences are the smallest true measure of
what this memo changes.

---

# Part I — `func main(args: List(String))`

## Both forms stay legal

```luce historical
func main():                              # a program that ignores them
func main(args: List(String)):            # a program that reads them
func main() -> !:                         # and each with `-> !`
func main(args: List(String)) -> !:
```

Four shapes, one extra arm in `checkEntry`
(`04_semantics/declarations.zig:1411`) and one diagnostic.

Forcing the parameter on every program was considered and refused.
Java is the standing experiment: `public static void main(String[]
args)` makes every hello-world carry a parameter it does not use, and
it is the most-cited barrier in teaching the language. C allows both
`int main(void)` and `int main(int, char**)` and nobody is confused by
the choice. Go and Rust have no parameter at all and reach the command
line through a library call — which is the arrangement Luce has today
and is moving away from.

"People are not confused" is served by the declaration being explicit
**where it is used**, not by being mandatory where it is not. A
program that never reads its arguments says nothing about them, and a
reader learns nothing false.

## `args[0]` is the first user argument

Today's `arg(0)` is the first thing the user typed after the program
path — `src/apps/start.zig:59-70` says so, `loom run PROG a b` agrees,
and every one of the corpus's eight `arg(…)` sites assumes it.
**`args[0]` keeps that meaning exactly.** The program's own name is
not element zero.

The alternative is C's `argv[0]`, and it is a wart every language
since has worked around: Python's tutorials slice `sys.argv[1:]`, Go's
`os.Args[0]` is skipped by every flag package, Rust's `env::args()`
includes it and `clap` drops it. Luce's host knows the difference
already and has no reason to hand over a value whose first act is to
be discarded. A program that wants its own name can have a host
service for it later; that is not this memo.

`len(args)` replaces `arg_count()`, and it is the same length on the
page.

## Ownership: `args` is an owned binding, and needs one new clause

`args` is a fresh `List(String)` nobody else names. `main`'s scope
owns it and frees it at exit — S1's death point, reached through
S15's kind of binding (a parameter that arrived owning its object).
The only genuinely new fact is *who gave it*: a runtime rather than a
call site. S13 says `give` appears at both ends, and the entry has one
end, so the signature carries no verb.

That fact deserves a number, because `docs/OWNERSHIP.md` S33
enumerates the owner kinds and this is a provenance none of them
names. Proposed, as a clarifying clause that changes no rule:

> **S44. The entry's arguments are handed in, and `main`'s scope owns
> them.**
> ```luce
> func main(args: List(String)):
>     for name in args:
>         print(name)
>     # scope ends: the list is freed here, like any owned binding
> ```
> Decision: `main`'s `args` is an owned binding of the kind S15
> describes — a parameter that arrived owning its object — and the
> caller that gave it is the runtime rather than a call site, which is
> why the signature carries no `give` and why S13 has no second end to
> echo at. Everything else follows unchanged: `args` may be read,
> iterated, indexed, sliced, given away or freed like any owned name,
> and whatever it still owns when `main` returns is freed by `main`'s
> scope (S1, S33). A host that supplies no arguments supplies an
> **empty** list, never a null one (S41 stays impossible to write).

`func main(args: give List(String)):` is refused. The verb would be
noise on a signature with nobody to say it back.

**The host gate does not apply.** `allow_host` covers the builtins a
program calls; `args` is handed to it. A program compiled without the
gate gets an empty list and touches nothing, which is exactly what
"a program given no host computes and touches nothing" already
promises — and it is strictly better than `arg(0)` under the same
conditions, which traps `host_unavailable`.

## `arg()` and `arg_count()` retire

Keeping them would leave two ways to read the command line, which is
the thing this codebase does not do. Retiring them also deletes
things, which is the better test of a feature:

* **One trap code goes.** `argument_bounds` exists only because
  `arg(i)` had no length to check against. `args[i]` out of range is
  `index_out_of_bounds`, which already exists. Luce goes from 18 trap
  codes to 17, and `docs/FAILURE.md`'s bounded set gets smaller
  rather than larger.
* **Two names leave `reserved_names`** (`04_semantics/context.zig:162`),
  so `arg` becomes an ordinary word a program may use.
* **Every consumption idiom gets shorter or stays level.** The loop
  `for index in range(0, arg_count()): … arg(index)` — three sites —
  becomes `for name in args:`. The guard `if arg_count() > 0:`
  becomes `if len(args) > 0:`. And `args` composes with everything
  `List` already has: `args.contains("-v")`, `args[1:]`,
  `strings.join(args, " ")`, none of which `arg(i)` could ever reach.

The migration surface, enumerated:

| where | sites |
|---|---|
| `examples/hello/hello.luc:6-10` | guard + `arg(0)` |
| `examples/stats/stats.luc:8-19` | the `range(0, arg_count())` loop |
| `examples/dice/dice.luc:17-23` | two positional optionals |
| `examples/wordcount/wordcount.luc:43-50` | `arg(0)` + optional `arg(1)` |
| `examples/editor/editor.luc:417-421` | exact-arity check |
| `examples/calc/calc.luc:116-120` | `arg_count() == 0` as a mode switch |
| `bench/*.luc`, `src/luce/std/*.luc` | **none** |
| `docs/FAILURE.md:107`, `docs/LANGUAGE.md:169,196,460,490`, `docs/V2.md:93` | 6 |
| `www/luce/content/` | `tour/host.md:13-33`, `tour/hello.md:46`, `examples/hello.md:14-38`, `examples/files.md:84`, `examples/optionals.md:49`, `tour/absence.md:91`, `index.md:8`, `ref/builtins.md:83-84`, `ref/failure.md:42` |

Site samples declare their arguments in the fence (`luce run args=3
fig`) and are executed by `www/luce/src/verify.zig`, so the site build is
the test for that column.

**One retirement diagnostic ships with it**, and only one release of
it: `arg` and `arg_count` stay in the intrinsic table mapped to a
`luce.sema.retired` message naming the replacement. Four lines. The
site is public documentation and a bare `unknown function arg` points
nowhere; this is the one place where a pointer is worth more than the
purity of having deleted the row. It is a table to empty, never to
grow.

## The ABI does not move

Arguments already cross the boundary. `abi.Host` carries `arg_count`
at slot 7 and `arg` at slot 8 (`08_llvm/abi.zig:466-467`), `arg_count`
cannot fail, and `arg` borrows its bytes for the duration of the call.
So the entry builds the list from the services that are already there:

* **the compiled arm** — `08_llvm/lower.zig:1034-1060` already
  synthesises the `luce_main` wrapper and pushes `{host, rt, limit}`
  before calling the entry. It gains a fourth pushed value, produced
  by emitted IR ahead of the call. **`abi.version` stays 9.**
* **the oracle** — `interpreter/machine.zig:324` calls
  `pushFrame(entry, &.{}, 0)` with an empty argument slice, and gains
  the mirror image.
* **one implementation of the semantic**, per the standing rule: the
  list is built by `libluce_rt`, not twice. `luce_rt_names_list`
  (`runtime/exports.zig:340`) already turns NUL-separated bytes into
  an owned `List(String)` — it is how `dir_list` works today — so the
  shim is a join plus one existing call, on both arms.
* a host that supplies no `arg_count` yields an **empty list**, not a
  trap. The entry cannot fail before `main` starts.

The alternative — a real argv marshalling, `luce_main(const LuceHost*,
i32 argc, char** argv)` — is refused. It changes the signature of the
one exported symbol, bumps `abi.version`, forces `src/apps/start.zig`
and loom's loader to move together, and duplicates a channel that
already exists and already works. The published ABI is append-only
precisely so that a change like this does not have to be one.

## Diagnostics

The name is **free** and the type is **fixed**. `func main(argv:
List(String)):` is legal and so is `func main(command_line:
List(String)):` — there is no misspelling of `args` to diagnose,
because `args` is a binding like any other. All `luce.sema.main`:

| written | said |
|---|---|
| `func main(n: Int):` | `main's parameter is the command line and must be List(String); it is Int here` — caret on the type |
| `func main(a: List(String), b: Int):` | `main takes at most one parameter, the command line; it has 2` — caret on the second |
| `func main(args: give List(String)):` | `main's parameter takes no verb; the runtime hands the list to main's scope [OWNERSHIP.md S44]` |
| `func main() -> Int:` | unchanged |
| missing `main` | unchanged |

The existing message — *"main takes no parameters; a program reads its
command line with `arg_count()` and `arg(index)`"*
(`declarations.zig:1427`) — is deleted along with the builtins it
names. It is pinned verbatim by `specs/errors_spec.zig:577-624`, which
moves with it.

A program that declares `args` and is run with none gets an empty
list. That is not an error, and `args[0]` on it traps
`index_out_of_bounds` with a line number, which is the language's
existing answer and the reason `len(args)` is right there.

---

# Part II — `self`

## The precedents, and which one Luce is

| | receiver | mutation | cost Luce will not pay |
|---|---|---|---|
| Python | explicit `self` | everything is a reference | no static model at all |
| Go | `func (p Point)` / `func (p *Point)` | pointer receiver | pointers as a type |
| Rust | `self` / `&self` / `&mut self` | borrow taxonomy | a borrow checker |
| Zig | none — `a.foo()` finds `T.foo(a, …)` | explicit `*T` | pointers as a type |
| **Swift** | implicit `self`, `mutating func` | **`inout`: copy in, write back** | — |

Zig's rule is the minimal design and it is nearly right: `a.foo()`
resolves to `T.foo(a, …)` when the first parameter is `T`, and that is
*already* what `lowerValueMethod` does for built-in receivers —
`builder.zig:3911` says so in a comment: *"`x.f(y)` is sugar for a
plain typed operation with the receiver first — there is no
dispatch."* But Zig gets mutation from `*T`, and Luce has no pointer
to offer.

**Swift is the language whose struct model is Luce's** — values that
copy, a `let`/`var` distinction on the binding, no references at the
surface — and its answer is the one that fits: `self` is a copy, a
`mutating` method writes it back to the receiver's place, and a
mutating method cannot be called on a `let`. Luce arrives at the same
place from a different direction, and gets there without a second
keyword.

## The declaration

```luce historical
struct Point:
    x: Float
    y: Float

    func length(self) -> Float:              # a method: reads self
        return sqrt(self.x * self.x + self.y * self.y)

    func scale(var self, factor: Float):     # a method: writes self back
        self.x = self.x * factor
        self.y = self.y * factor

    func origin() -> Point:                  # a namespace function
        return Point(x = 0.0, y = 0.0)
```

* **`self` is a keyword**, bare, its type implied as the enclosing
  struct. `self: Point` is refused — inside `struct Point` it can be
  nothing else, and writing it invites writing a different one.
  Reserving the word breaks nothing: `grep -rniw self --include=*.luc`
  over the repository returns **zero hits**.
* **A function is a method exactly when its first parameter is
  `self`.** Everything else in a struct stays the namespace function
  it is today, and `Text.continuation(byte: Int)` needs no edit ever.
  That is the natural rule and it is also the only one that keeps 44
  existing declarations compiling untouched.
* **`var self` marks a method that writes its receiver back.** No new
  keyword: parameters are immutable today
  (`04_semantics/declarations.zig:11`), `var` already means "this
  binding may be reassigned", and the symmetry is the teachable part —
  **`var self` needs a `var` receiver.** `self = Point(x = 0.0, y =
  0.0)` inside such a method is legal and means what it says.

`var` on an ordinary parameter stays refused. `self` is the one
parameter whose argument is required to be a place; every other
argument is an expression, and a write-back would have nowhere to go.

## The call

`p.length()` means `Point.length(p)`. Not "is compiled like" —
**means**, as the same MIR call, resolved in stage 4.

The hook already exists and needs no new table. `methodNamespace`
(`builder.zig:3855`) returns `.value` when the head is a local, and
`lowerValueMethod` then tries String, then `heapOf(...)`, then fails
with `"{s} has no methods"` at `builder.zig:3963`. A struct branch
slots in ahead of that failure, keyed on `receiver.value_type ==
.strukt` → `function_names.get("{StructName}.{method}")` — which is
**already the registered key** (`declarations.zig:1326-1345` mangles
struct members to exactly `Struct.func`).

**`Point.length(p)` stays callable**, and that is deliberate. It keeps
the method form pure sugar with one semantics underneath, it is Zig's
rule, and it makes migration incremental: adding `self` to a
declaration does not break the call sites that spell it the long way,
so a struct can be converted one function at a time.

**`Point.scale(p, 2.0)` is refused.** A `var self` method writes back
through its receiver, and the static form has no receiver to write
back to — it would take a copy, mutate it, and discard it, silently.
That is the one place where allowing both spellings would mean two
semantics rather than one, so it gets a diagnostic instead.

### What the receiver has to be

The receiver of a `var self` method must be a **place whose root is a
mutable local** — which is not a new rule to invent, but the rule
`lowerAssignChain` (`builder.zig:1749-1762`) already enforces for
`cells[0].value = 3`. Reusing it exactly means a receiver is legal in
precisely the positions an assignment target is legal, and the two can
never drift:

```luce historical
var p = Point(x = 1.0, y = 2.0)
p.scale(2.0)                  # a var local
cells[0].scale(2.0)           # an element of a var root
box.corner.scale(2.0)         # a field of a var root

let q = Point(x = 1.0, y = 2.0)
q.scale(2.0)                  # refused: q is let-bound
Point.origin().scale(2.0)     # refused: a call result has no place
```

### Resolution order, pinned

A struct value can **never** be the receiver of a built-in method, and
this is true by construction rather than by check:
`types.StructLayout` (`support/types.zig:141-151`) has no functions
field, and `heapOf` (`declarations.zig:380`) returns null for
`.strukt`, so `objectMethod` is unreachable for a struct. The new
branch is a fourth arm beside String and heap objects and can never
race one. There is no collision to order, today or after this change.

The existing precedence is untouched: a head that names a local is a
value method, a head that names a declaration is a namespace call
(`methodNamespace`, checked in that order at `builder.zig:3864`).

## Mutation: the hard point, and why it needs no reference

`self` is a **copy**, like every value parameter in the language. For
a `var self` method, the copy is written back to the receiver's place
on the way out. In one line:

> `p.scale(2.0)` means `p = Point.scale(p, 2.0)`.

That sentence is not a new mechanism. It is **transcribed from the
corpus**, which writes it by hand at every mutation site it has
(`examples/editor/editor.luc:332-415`):

```luce historical
    func vertical(state: State, target_line: Int) -> State:
        var moved = state
        ...
        moved.cursor = Text.at_column(moved.content, start, wanted)
        return moved
```

called as `state = Handle.vertical(state, line - 1)`
(`editor.luc:366`). The compiler is being asked to write the two
halves the programmer is writing already — `var moved = state` and
`return moved` on one side, `state =` on the other.

### It is not observably by-reference

Copy-in/copy-out and by-reference differ under aliasing, so the
absence of aliasing has to be shown rather than assumed. Inside a
method the only inputs are its parameters; struct values copy on every
store; there are no globals, no references, no closures and no
threads. **No expression inside the callee can name the receiver's
place.** Therefore the two lower to the same answers on every program
that can be written — with two edges worth stating out loud:

1. **A method that raises leaves its receiver as it was.** The
   write-back stands on the returning edge only, which is what the
   existing lowering for `x = f() catch:` already does — otherwise
   `opening = files.read(path) catch:` (`editor.luc`) would clobber
   `opening`. It is also what `docs/FAILURE.md` already guarantees
   from the other side: *"a fallible function empties `%out` on its
   errored edge"*. All-or-nothing is what copy-out gives for free, and
   it is the property a reader can hold.
2. **Mutation *through* an object field is immediate, not deferred.**
   A struct copy aliases the objects it carries (S26), so
   `self.items.append(1)` is visible at once. That is S38 unchanged
   and it is the same caveat `docs/FAILURE.md` already records for a
   partially-mutated borrowed container.

### `var self` requires a struct that carries no objects

This reads like a restriction invented for the feature. It is not: it
is where S17 and S28 already put the corpus.

`state = Handle.key(state, …)` works today because `State` carries
only `String`, `Int` and `Bool` — all values. Had `State` carried a
`List`, the pattern would already be refused: `return moved` where
`moved` aliases a borrowed parameter is S17
(`builder.zig:2555-2582`), and an object-carrying struct assigned
wholesale must yield ownership (S21/S25). `var self` inherits that
wall exactly, and a diagnostic that cites S17 and S28 is telling the
truth about where it came from.

The consequence is a happy one: **the written-back value can contain
no object handles**, so the write-back is a pure value store — no
release, no bind, no double-free to reason about. `docs/OWNERSHIP.md`
needs **no new clause** for `self`. A struct that does carry objects
mutates through its fields from a plain `self` (S38), which is the
right way to write it and needs no write-back at all.

### `var self` methods return nothing

> **Corrected once built.**  This restriction was **never shipped**.
> `docs/RETURNS.md` landed *with* this work rather than after it, so
> `func next(var self) -> Int:` was legal on the day `var self` was:
> a method's results are `[receiver] ++ declared` and they travel in
> one return shape, which is the sense in which `self` was always
> waiting for that memo (`docs/RETURNS.md` §5, which asked in as many
> words that the refusal below never exist in the tree).  The
> reasoning is kept because it is what made the restriction's end
> schedulable, and a restriction with a scheduled end is the only kind
> worth writing down.

`func next(var self) -> Int:` was to be refused. Luce had one return
channel and the receiver was travelling in it.

This is the feature's real cost and it should be paid in the open.
The canonical loser is the mutate-and-answer method — a random number
generator, a scanner's `take()`. `std/math.luc:237`'s
`random_step(rng: List(Int))` becomes:

```luce historical
struct Rng:
    state: Int

    func step(var self):
        self.state = self.state * 48271 % 2147483647
```

— two calls at the use site (`rng.step()` then `rng.state`) where the
workaround had one. Against that: no references, no new MIR
instruction, no ABI field, no new concept in the IR, and a struct
where there was a one-element `List(Int)` pretending to be one.

**And the restriction lifts on its own.** `docs/MISSING.md` Tier 4
item 10 files receivers and **multiple returns** as neighbouring
decisions. When multiple returns land, `var self` methods return
alongside their receiver and nothing about `self` is revisited. It is
a restriction with a scheduled end, which is the only kind worth
shipping.

## What `self` must not smuggle in

**First-class functions stay absent.** `let f = p.length` is refused,
as `let f = Point.length` already is: functions are not values, a name
in call position denotes a function statically, and a *bound* method
value would be a closure over `p` — the exact thing
`docs/LANGUAGE.md`'s "deliberately absent" list refuses first. The
diagnostic composes with the existing namespace-member path
(`failNamespaceMember`, `builder.zig:472-509`) and is pinned:
`luce.sema.value` — `functions are not values; call it, or pass what
it needs`.

**`self` is not a storable thing.** It is a parameter binding of the
struct's own type, and reading `self` yields a struct value that
copies like any other. There is no expression that produces a
reference, because there is no reference.

**`give self` and `free(self)`** need nothing new: a plain `self` is a
`borrow_param` and inherits the three refusals that already exist
(`builder.zig:3049`, `4660`, `2566`), each of which already cites S12
or S17 and already reads correctly.

## Diagnostics — the ones the owner named

New code `luce.sema.self`, plus two improvements to existing messages.

| written | said |
|---|---|
| `p.foo()` where `Point.foo` takes no `self` | `Point.foo is a namespace function, not a method; it takes no self — call it as Point.foo(p, …)` |
| `p.foo()` where `Point` has no `foo` at all | `Point has no method foo; did you mean length?` / `Point has no method foo` — **replacing** today's `Point has no methods` (`builder.zig:3963`), and matching the List/Map/Builder family |
| `self` in a top-level `func` | `self is only a parameter of a function declared inside a struct` |
| `func f(a: Int, self)` | `self must be the first parameter of f` |
| `func f(self: Point)` | `self takes no type annotation; inside struct Point it is Point` |
| `Point.scale(p, 2.0)` | `scale takes var self and writes back to its receiver; call it as p.scale(2.0)` |
| `q.scale(2.0)`, `q` let-bound | `q is let-bound; scale takes var self and writes back to its receiver — use var` (`luce.sema.let`, composing with the existing wording) |
| `Point.origin().scale(2.0)` | `scale takes var self, so its receiver must be a variable, a field, or an element — not a call result` |
| `var self` on an object-carrying struct | `Bag carries objects, so it cannot be written back; take self and mutate through the field, or write a namespace function [OWNERSHIP.md S17, S28]` |
| `let f = p.length` | `functions are not values; call it, or pass what it needs` |

The second row is the one that pays immediately: today `p.foo()` on a
struct says *"Point has no methods"*, which was true and will stop
being.

## One clarifying clause, and no rule changes

`docs/OWNERSHIP.md` needs nothing new for `self` — the section above
shows why — but S39 should say out loud what it already implies,
because the receiver rule leans on it:

> **Clarified for receivers.** S39 governs the binding, and for a
> *value* the binding is the whole of it: `let p = Point(x = 1)`
> already refuses `p.x = 5` (`luce.sema.let`), because a struct value
> has nothing underneath the name the way a `List` has an object
> underneath it. So a method declared `var self`, which writes back to
> its receiver's place, is refused on a `let` receiver by the rule
> that was already there and for the same reason. Heap objects are
> unchanged: `let xs = [1, 2]` still takes `xs.append(3)`, because the
> name is pinned and the object is not.

## The migration hazard, named

`examples/editor/editor.luc:380` reads:

```luce historical
                next.cursor = Text.previous_boundary(state.content, next.cursor)
```

`state.content`, not `next.content` — deliberately, because the line
above has already shortened `next.content` and this needs the length
before the erase. Under `var self` there is no `state`: `self` *is*
`next`, and the free "before" snapshot the copy-and-return pattern
gave away disappears. Converting this function requires an explicit
`let before = self.content` at the top.

This is one line in the flagship program and it would change behaviour
silently. It is the reason the corpus rewrite is a separate step with
its own test, and the spec must contain exactly this shape.

---

## What this costs

**Decision 1** touches five sites, all named above: `checkEntry`, the
`if (!is_entry)` parameter-type skip (`declarations.zig:1376`), the
`if (!info.is_entry)` parameter-binding skip
(`declarations.zig:1507`), the `luce_main` wrapper
(`lower.zig:1034-1060`), and `pushFrame(entry, &.{}, 0)`
(`machine.zig:324`). **No ABI field, no `abi.version` bump.** The
serialized module's `format_version` moves because the intrinsic set
loses two entries and the trap set loses one.

**Decision 2 lowers nothing new.** `p.length()` resolves in stage 4 to
the call `Point.length(p)` that MIR already has instructions for;
`p.scale(2.0)` resolves to that call plus the store an assignment
already emits. **Zero new MIR instructions, zero new intrinsics, zero
runtime functions, zero ABI change**, and the oracle needs no edit at
all — which is precisely why it is the arm that proves the sugar
resolved correctly. The work is entirely in `02_lex` (one keyword),
`03_parse` (one parameter form), and `04_semantics` (a receiver on
`FunctionDeclInfo`, a branch in `lowerValueMethod`, and the write-back
at the call site).

The parameter plumbing is already shaped for it: `ast.Parameter.mode`,
`FunctionDeclInfo.parameter_modes`, and the `class`/`bind` pair in
`lowerFunction` (`declarations.zig:1507-1533`) are three adjacent,
parallel places, and `self` is a synthesised parameter 0 among them.

---

## Order

Each step is independently shippable and leaves the tree green.
Decision 1 goes first because it is smaller, it forecloses nothing, and
it retires machinery Decision 2 would otherwise have to keep working.

1. **The entry accepts a parameter.** `checkEntry`'s four shapes, the
   two `is_entry` skips, and the diagnostics table above. The
   parameter is bound and typed; nothing fills it yet.
   *Tests:* `specs/errors_spec.zig` for each new message, and the
   existing 577-624 block rewritten. *Docs:* none yet. **~half a day.**
2. **The list gets built, on both arms.** `luce_rt_args` over
   `luce_rt_names_list`, the `luce_main` wrapper's fourth push, the
   interpreter's mirror, empty-list-when-no-service. S44 into
   `docs/OWNERSHIP.md` with its `/ref/ownership/#s44` anchor.
   *Tests:* `specs/agree.zig` with and without arguments — both arms
   compared on prints, leak census and the world left behind.
   **~1 day.**
3. **`arg`/`arg_count` retire.** The intrinsics, the `argument_bounds`
   trap code, the two `reserved_names` rows, the retirement
   diagnostic, `format_version`. *Tests:* errors_spec for the
   retirement message; the trap-code coverage test in `www/luce/src`.
   **~half a day.**
4. **The corpus and the documentation follow.** Six programs, six
   `docs/` sites, nine site pages, `ref/builtins.md` and
   `ref/failure.md` rows, `docs/LANGUAGE.md`'s entry and builtin
   sections, `docs/V2.md:93`, CLAUDE.md's entry paragraph.
   *Tests:* the site build, which runs every sample. **~1 day.**
5. **`self` parses.** The keyword into `02_lex/token.zig` and into
   `www/luce/src/highlight.zig`'s `keywords` **and** its `lexed`
   agreement test — those move in the same commit or the site test
   fails. Bare `self`, `var self`, first-position and
   no-annotation rules. *Tests:* `03_parse/test.zig`,
   `specs/errors_spec.zig` rows 3-5. **~1 day.**
6. **Methods resolve, read-only.** `self` as synthesised parameter 0,
   a receiver on `FunctionDeclInfo`, the struct branch in
   `lowerValueMethod`, `Struct.method(x, …)` still legal, and the
   `has no methods` → `has no method foo` replacement with its
   did-you-mean. *Tests:* `specs/behavior_spec.zig` for `p.length()`
   against `Point.length(p)`; errors_spec rows 1, 2, 11.
   **~1.5 days.**
7. **`var self` writes back.** The place rule reusing
   `lowerAssignChain`'s root check, the returning-edge-only store, the
   carries-no-objects rule (**not** the returns-nothing rule:
   `docs/RETURNS.md` §5 says do not build it, and it was not). S39's clarifying
   paragraph. *Tests:* `specs/ownership_spec.zig` for the write-back
   and for the raising method that leaves its receiver alone;
   `specs/agree.zig` for both arms; errors_spec rows 6-10; **and the
   `editor.luc:380` shape as its own named test.** **~2 days.**
8. **The corpus restructures.** `Handle` and two of `Draw` merge into
   `struct State`; `std/math.luc`'s `random_step` becomes `struct
   Rng`. Separate and separately reviewable, because this is where the
   `:380` hazard is met. *Tests:* the existing editor and std suites,
   unchanged, plus `bench` unchanged. **~1 day.**
9. **The documentation says what is true.** `docs/LANGUAGE.md` gains a
   Methods subsection under structs and loses *"user-defined
   methods/receivers (`x.f()` is builtin sugar, not dispatch)"* from
   "deliberately absent"; CLAUDE.md loses *"no receivers, methods"*;
   `docs/MISSING.md` Tier 3 item 3 and Tier 4 item 10 close. Site:
   `ref/expressions.md`'s method-sugar section, `ref/statements.md`,
   `ref/lexical.md`'s keyword table, `tour/functions.md` and
   `examples/structs.md` — **including the two sentences that promise
   `self` does not exist**. **~1 day.**

**Nine steps, roughly nine days**, of which two are documentation and
one is a corpus rewrite that could slip without blocking anything.

### The paragraph the confusion earned

Step 9 owes the site one paragraph that does not exist today, and the
brief that commissioned this memo is the evidence it is needed — it
read 88 namespace calls as 88 waiting method calls. It should say:
`Struct.func(x)` is a **namespace** call; the struct is a folder and
`x` is an ordinary first argument. `x.foo()` is a **method** call; the
struct is a type and `x` is its receiver. Luce has both, they share a
syntax, and the difference is visible in exactly one place — whether
the declaration's first parameter is the word `self`.

---

## Refused, with reasons

**A mandatory `args` parameter.** Java's experiment, above. The cost
lands on every program that never reads a command line, which is most
of them.

**`argv[0]` as the program name.** A wart every language since C has
worked around, and the corpus assumes otherwise at all eight sites.

**Keeping `arg()` beside `args`.** Two ways to do one thing. It also
keeps a trap code alive that has no other reason to exist.

**A real argv marshalling through `luce_main`.** Changes the one
exported symbol, bumps a version, moves `start.zig` and the loader
together, and duplicates a working channel. The ABI is append-only so
that this kind of change does not have to happen.

**Pointer receivers (Go) or a borrow taxonomy (Rust).** Both need a
reference to be a thing the type system knows about, and both would
make `self` storable the moment a user found the syntax. The standing
rule is that there are no reference types, and this feature is not
where it gets relitigated. Copy-in/copy-out reaches the same answers
on every program that can be written here, and the proof is short
because the language is small.

**A `mutating` keyword (Swift's spelling).** `var` already means
"reassignable", the receiver rule reads as `var self` needs a `var`
receiver, and one keyword is cheaper than two.

**Inferring mutation from the body.** It works — `Function.fallible`
is exactly that shape — but it makes a callee's body silently decide
its callers' obligations. `give` appears at both ends for the same
reason (S13), and this is the same kind of promise.

**`var` on ordinary parameters.** An argument is an expression and a
write-back needs a place. `self` is the one parameter guaranteed to
have one.

**`self: Point` as the annotation.** It can be nothing else, and
allowing it means allowing someone to write something else.

**`Point.scale(p, 2.0)` for a `var self` method.** It would compile to
a mutation that is thrown away. The read-only static form stays,
because there it means exactly what the method form means.

**Shipping `self` without `var self`.** It would leave the corpus's
one real mutation pattern — four functions and seven call sites in
`editor.luc` — unable to convert, which is the entire immediate
harvest of the feature.

**Bound method values (`let f = p.dist`).** A closure over `p` by
another name, and first among the things `docs/LANGUAGE.md`
deliberately does not have.

## Superseded receiver design — 2026-08-08

This record's `main(args)` decision shipped and remains current.  Its
receiver design did not lock: `docs/SELF.md` superseded explicit
`self`/`var self`, copy-in/copy-out, and type-qualified method calls.
The implemented language gives every plain struct or enum member an
implied `self`; a namespace member says `static func`.  Writer status
is inferred transitively, and a writer aliases one bare owning `var`
binding in place.  Reads accept lets and temporaries, pre-error writes
remain, and borrowed object-content mutation remains a read.  Methods
are neither values nor worker targets and cannot be called through the
type; static members can do all three.  `docs/SELF.md`'s as-built
appendix records the format-32 / ABI-13 implementation seam.
Separately, the rule's "no function value" is superseded by
`docs/FUNCTIONS.md`: named functions and capture-free lambdas are
values now, while methods still are not — that exclusion is the
surviving half of the sentence.
