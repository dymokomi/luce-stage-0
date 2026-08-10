# Answering more than one thing

> **Spellings, since this was decided.**  The builtin type names are
> lowercase (`long`, `double`, `string`, `list`, `map`, `array`,
> `builder` — docs/TYPES.md D8), and the two numeric types became four:
> `int` and `float` are 32 bits and are what a literal takes with
> nothing to tell it otherwise, `long` and `double` are the 64-bit
> types this memo calls `Int` and `Float`.  A fenced block tagged
> `luce historical` is shown as it was written and is not compiled;
> every other one in this file is (`tools/doccheck.zig`).

> **Later-polish amendment (as built).** Owner-ratified evidence after
> this memo reopened one deliberately provisional refusal:
> `a, b = f()` now receives one return shape into two or more distinct
> existing mutable bare names. The right side may be a direct,
> namespace or method call and may use `try` or a `catch:` block. Every
> target is checked and every answer prepared before any replacement
> store; on failure, the catch handler runs with none of those stores
> performed. Ordinary side effects from evaluating the right side are
> not rolled back. Fields, indexes, compound forms, `_`, tuple values,
> `catch VALUE`, and direct return pass-through remain refused. The
> original boundary and its rationale below remain as the frozen
> decision record rather than being rewritten after the fact.

> **The rule.** A function may answer more than one value —
> `-> (Float, Float)`, `return low, high`, `let low, high = minmax(xs)`.
> **There is no tuple.** `(Float, Float)` is a shape a *signature* has,
> not a type a program can name: it cannot annotate a binding, fill a
> field, nest inside itself, or be written as an expression. A call
> that answers more than one value may stand in exactly two places —
> the right of a destructuring `let`/`var`, and a statement of its own
> — and nowhere else. This is Go's line, and it is the line that keeps
> a language with no generics and no first-class functions from
> acquiring an anonymous product type by the back door.

`docs/MEMORY.md` records why scope ownership won; `docs/FAILURE.md`
why there are three failure mechanisms and not one; `docs/NUMERICS.md`
why `Int` promotes. This is the memo for the hole those three left
alone and `docs/METHODS.md` walked up to and stopped at.

It is `docs/MISSING.md`'s **"The order to work down"** item 10, in part
— *"Decide receivers, multiple returns, and integer-division spelling —
one memo each"* — and it closes **Tier 3 item 4** outright.

> **A citation that had already rotted.** That item lives under
> `docs/MISSING.md`'s *"The order to work down"* (`MISSING.md:645`), a
> numbered list of its own that is in **no Tier at all**.
> `docs/METHODS.md:11` calls it *"Tier 4 item 10"* and
> `docs/NUMERICS.md:17` calls it *"Tier 5 item 10"*; both are wrong,
> in different directions, and no mechanism is offered here for how
> they got that way — the honest statement is that two memos in a
> series each invented a Tier for a list that has none, and neither
> was checked. `docs/audit/DOCS.md:810` predicted the class of it —
> *"essentially every line reference and corpus count"* — and the third
> memo in the series is the right place to stop repeating it. The two
> older citations should be corrected in this memo's docs step.

## What the owner decided, and why it is the second half of a sentence

> *"so that we can do proper self"*

`docs/METHODS.md` shipped `self` with one restriction, and named it as
a debt with a date on it (`METHODS.md:460-489`):

> ### `var self` methods return nothing
>
> `func next(var self) -> Int:` is refused. Luce has one return channel
> and the receiver is travelling in it.
>
> […] **And the restriction lifts on its own.** `docs/MISSING.md` Tier
> 4 item 10 files receivers and **multiple returns** as neighbouring
> decisions. When multiple returns land, `var self` methods return
> alongside their receiver and nothing about `self` is revisited. It is
> a restriction with a scheduled end, which is the only kind worth
> shipping.

This memo is that end. The reader should hold one sentence through all
of it, because it is the design in miniature and §5 shows it is
literally true of the lowering:

> **A `var self` method's receiver is result zero.**

The second thing to hold is `docs/FAILURE.md`'s refusal, which this
memo is bound by rather than overturning (`FAILURE.md:377-379`):

> Go's value-plus-error — Luce has no multiple returns, and adding them
> *for* errors is the tail wagging the dog.

That still stands. Errors keep their own channel and their own
grammar; nothing below spends a return position on one. What changes
is only that the sentence's premise — *"Luce has no multiple
returns"* — stops being true, for reasons that have nothing to do with
errors. §2 is the whole of what the two features owe each other.

---

## What the corpus actually says

Twelve structs are declared in the whole `.luc` corpus. Nine have no
fields at all — namespaces impersonating types. Two are real domain
types. **One exists to carry a return**, and it is the exhibit
`docs/MISSING.md:227-229` filed:

```luce historical
# examples/calc/calc.luc:20-22
struct Step:
    value: Int
    at: Int
```

No methods, no invariant, no meaning outside a parser's signature: a
scanner hands back *what it read* and *where it stopped*. Constructed
at eight sites (`calc.luc:38, 49, 51, 63, 65, 67, 76, 82`) and taken
apart by **twenty-five field reads over fourteen lines**, binding seven
names that exist only to be dismantled on the next line.

> **The public number is wrong and should be corrected either way.**
> `www/luce/content/status/index.md:140` says *"constructed at 8 sites and
> destructured at 15."* `docs/MISSING.md:229` says 25 field reads and
> is right; the site is stale, as `docs/audit/DOCS.md:810` predicted of
> *"essentially every line reference and corpus count."* Eight
> constructions is exact.

The shape of the destructures is the part that decides the design, and
it is **not** that the pair is short-lived. `Parse.expression`
(`calc.luc:42-53`) holds one in `var left` across a whole `while` loop
and returns it, and `Parse.expression`, `Parse.term`, `Parse.factor`
and `Scan.number` are all declared `-> Step!`. A first draft of this
memo claimed `Step` was "never stored, never held past the statement
that produced it", and that is simply false — the loop is right there
in the file. §6 rebuilds the rule on what is actually true.

What *is* true, and what decides it, is that **the pair is never an
input.** No function in `calc.luc` takes a `Step`: `Parse.term(text:
String, at: Int)` takes the two halves separately, and the accumulator
is only ever read field-wise — `left.at` alone feeds
`Scan.skip_spaces`, `left.value` alone feeds the arithmetic. `Step`
flows outward and is taken apart; it is never handed to anything as a
thing. It is a return, spelled as a type because there was no other
spelling.

**And it is not the only shape the hole takes.** The corpus works
around a missing second return four more ways, and only one of them
looks like a struct:

| where | the workaround |
|---|---|
| `std/math.luc:229-239` | **a heap object as a mutable cell.** `seed` allocates a one-element `List(Int)` so that `random_step` can write the new state through a borrow while the draw goes out through `return`. Two values, two channels, one allocation whose entire purpose is to give an `Int` reference semantics. |
| `editor.luc:212-221` | **the second value dropped, and the caller guessing it.** `Draw.emit` walks from `at` and **clips at `remaining` columns**, so it knows both how many columns it used and where in the text it actually stopped — and can return only the first. Each of its six call sites (`:230, 246, 253, 268, 274` inside `Draw.line`'s per-token loop, and `:299` in the status bar) sets `at` from a bound it computed *itself* (`finish`, `close`, `stop`), which is right only because the outer `while` exits on the same clip. |
| `wordcount.luc:34-41` | **the second value thrown away and fetched again.** `heaviest` computes `best` and `best_count`, returns `best`, and the caller does a second map lookup at `:65` for the count the function already had. |
| `bench/stats.luc:34-35` | **two traversals for one pass.** `math.vmin` and `math.vmax` (`std/math.luc:159-174`) walk the same array twice. There is no `minmax` in std, and there could not have been one: writing it would have meant inventing a bag struct in the standard library. |

Five workarounds, four distinct disguises, and every one of them is
the same missing sentence. `random_step`'s costs a heap allocation;
`Draw.emit`'s costs a correctness argument, which is worse — the code
is right, but it is right for a reason that has to be reconstructed
from two functions at once.

That is the honest size of the feature: **it removes one struct, one
allocation, one redundant hash lookup, one whole traversal of an
array, and one piece of reasoning that currently lives only in the
reader's head.** It is not a large harvest and it should not be sold
as one. What makes it worth building is §5.

---

## The precedents, and which one Luce is

| | the pair | can it be stored? | discard | the cost |
|---|---|---|---|---|
| **Go** | multiple returns, **no tuple type** | no | `_`, mandatory | `_` everywhere; a carve-out in the spec for `g(f())` |
| Python | tuples, first class | yes, everywhere | `_` by convention | `namedtuple` and `dataclass` had to be invented to give the pair its names back |
| Zig | none — an anonymous struct return | yes (it is a struct) | `_` | the caller writes `r.min`, not `min` |
| Swift | tuples, first class | yes, everywhere | `_` | a structural type with no name: no methods, no protocol conformance without a compiler special case, no way to extend |

**Luce is Go, and the reason is arithmetic on the rest of the language.**
A tuple is an anonymous, structural, generic product type. Luce has no
generics, no first-class functions, no sum types and exactly one
subtyping relation (`T <: T?`). Adding an anonymous product type is not
adding a feature; it is adding the *first* structural type, and every
structural type asks the same follow-up questions: does it nest, can a
`List` hold one, does it compare, does it have a `len`. Each answer is
either "yes" — and the type system has doubled — or "no", and the type
is a wart. Python and Swift both answered yes and both then had to
build the thing a tuple is not: Python's `namedtuple` and `dataclass`
exist because `t[0]` and `t[1]` lose the names that `low` and `high`
had, and Swift's tuples still cannot be extended or conform to a
protocol without the compiler being told about them by hand.

Go's answer is that the multiple values exist only *in flight*. They
are produced by a `return` and consumed by an assignment, and there is
no moment in between at which a program can hold them. That is
precisely the property Luce needs, and it is the property this memo
spends §"There is no tuple" enforcing.

**Zig is the evidence for the lowering, not for the surface.** Zig has
no multiple returns and tells you to return an anonymous struct; §4
shows that Luce's answer is to write exactly that struct for you and
never show it to you. Zig's own destructuring (`const a, const b = …`)
is a real precedent for the bind and it is where the one genuinely
close call in §1 comes from.

**Go's costs are real and this memo pays two of them.** The `_`
proliferation is one, and §1 refuses `_` for a reason Go does not
have. The other is the `g(f())` pass-through, which forced Go's
specification to say that if a multi-valued call is used as arguments
it must be *the only* arguments — a carve-out that exists purely
because the pass-through exists. Luce refuses the pass-through and
therefore never writes that sentence.

---

## 1. The surface

### The declaration

```luce historical
func minmax(xs: Array(Float, _)) -> (Float, Float):
    var low = xs[0]
    var high = xs[0]
    for i in range(1, len(xs)):
        low = min(low, xs[i])
        high = max(high, xs[i])
    return low, high
```

A parenthesised, comma-separated list of **two or more** types after
`->`. Today the grammar after `->` is exactly one `typeName`
optionally followed by `!`, or a bare `!`
(`03_parse/grammar.zig:822-830`), and `typeName` begins
unconditionally with `expect(.identifier, "a type name")`
(`grammar.zig:661-713`) — so `(` in that position is today
`expected a type name, found '('`, an error nobody has hit on purpose.
The new production is one `if` at that one site.

Four shapes are refused at the same place, and each gets its own
sentence rather than falling into the generic one:

| written | `luce.parse.type` says |
|---|---|
| `-> ()` | `a function that answers nothing writes no arrow` |
| `-> (Int)` | `one value needs no parentheses: write -> Int` |
| `-> ((Int, Int), Int)` | `return shapes do not nest: there are no tuples` |
| `-> (Int, Int)?` | `'?' marks a value that may be absent, and a return shape is not a value` |

`-> (Int, Int)!` is **legal** and is §2.

**A limit, stated once.** The list is capped at the same place every
other width in the language is: a return shape is a struct once it is
lowered (§4), and `helpers.max_struct_values` is 4096. A signature that
approaches it has other problems, but the bound should be the same
bound and not a second number.

### The bind

```luce historical
let low, high = minmax(temperatures)
var row, column = grid.find(target)
```

Two or more names, then `=`, then a call whose arity matches. Today
`binding` (`grammar.zig:933-1002`) takes exactly one name and
`let a, b = f()` dies at `expected '=' with an initial value, found ','`.

**One keyword governs the whole bind.** `let a, b` makes both
immutable; `var a, b` makes both reassignable. `let a, var b = f()` is
refused.

Zig is the argument on the other side and it is a good one: Zig's
destructuring lets each element carry its own `const` or `var`, and it
buys exactness at one token. It loses here for two reasons. The first
is that every binding statement in Luce begins with the keyword that
governs it, and the parser's statement dispatch reads that keyword at
position zero; a per-name form re-enters binding mode in the middle of
a list, which is a second shape for a reader to learn about a
statement they already know. The second is that it forecloses nothing:
`let a, var b = f()` is a strict superset of the one-keyword rule, so
if the corpus asks for it, it can be added later and no program
written before then changes meaning. Refusing first is reversible;
allowing first is not.

The cost is named: a bind whose two values want different mutability
takes `var` for both, and the reader loses one bit. In exchange the
statement reads the way every other binding does.

**Type annotations.** `let low: Float, high: Float = minmax(xs)` is
refused — `luce.parse.type`, *`a destructuring bind takes its types
from the call`*. There is one place a return shape is written and it is
the signature. (An annotation on a *single* `let` stays exactly as it
is.)

**No shadowing still applies**, so two destructures of the same shape
in one scope need distinct names. That is not new — `let x = f()`
twice is already refused — but it is the first construct that makes a
reader want it twice in a row, and it is worth a sentence on the page.

### Where a multi-return call may stand

Two places, and they are enumerable:

```luce historical
let low, high = minmax(xs)      # 1. the right of a destructuring bind
rng.next()                      # 2. a statement, all values discarded
```

Everything else is `luce.sema.call`:

```luce historical
print(minmax(xs))               # refused
let x = minmax(xs) + 1.0        # refused
return minmax(xs)               # refused, even from -> (Float, Float)
xs.append(minmax(ys))           # refused
low, high = minmax(xs)          # refused: assignment, not a bind
```

**The `return f()` pass-through is refused deliberately**, and it is the
one place this memo is stricter than Go. Go allows `return f()` when
the arities match, and Go allows `g(f())` on the same principle — and
then has to legislate that if `f()`'s results are used as arguments
they must be the *only* arguments, because there is no coherent way to
mix a multi-valued expression with ordinary ones. That carve-out is the
whole cost of the pass-through, and the pass-through's whole benefit is
one saved line:

```luce historical
let low, high = minmax(xs)
return low, high
```

One line, zero special cases, and a reader who never has to learn where
the exception applies.

**Plain multi-assignment (`low, high = f()`) is refused**, and the
reason is specific to Luce rather than general. In Go the dominant use
of multi-assignment is `v, err = f()` — reassigning a loop-carried
`err`. **Luce has no `err`**: `docs/FAILURE.md` put the error in its
own channel precisely so it would never occupy a return position. What
is left is loop-carried state, which is the case `var self` methods now
serve directly (§5), and the residue is one extra name:

```luce historical
let value, next = Scan.number(text, position)
position = next
```

It also keeps `catch`'s attachment rule intact. `docs/FAILURE.md`
pinned that the `catch:` block form takes *"a call, and a plain
assignment whose value is a call — and no others."* A multi-target
assignment would be a third shape asking to be admitted, and admitting
it means answering what a handler does when two places are half
written. Refusing the statement refuses the question.

Both refusals reopen on the same evidence: a corpus that writes the
extra line often enough to be noise.

### Discarding one value: there is no `_`

Go needs `_` because Go makes an unused local an **error**. Luce does
not — there is no unused-value and no unused-binding diagnostic
anywhere in stage 4, and a call whose result is discarded at statement
position is accepted silently today. The reason for `_` therefore does
not exist here, and what is left is a name:

```luce historical
let word, count = heaviest(counts)
print(word)                       # count is simply not used
```

`count` is freed by scope ownership at the end of its block exactly as
a discarded value would be, and the next reader learns what was
ignored, which `_` does not tell them.

The character is also not free. `_` is a plain identifier everywhere in
the language (`02_lex/token.zig:26`) and is recognised as the array-shape
wildcard by **text comparison inside `typeName`'s argument list**
(`grammar.zig:683-702`), counted into `ast.TypeName.wildcards`. Giving
it a second job in binding position means deciding whether `let _ = f()`
works, whether `for _ in xs:` works, and — because two `_`s in one
scope collide under no-shadowing — writing the language's first
exemption from the no-shadowing rule. That is a feature with a tail,
for a problem the language does not have.

**Refused, with the reopening condition named:** if the corpus grows
binds whose discarded names are invented noise, `_` returns as a
binding-position wildcard exempt from shadowing, and nothing above
changes.

### There is no tuple

Stated as a rule, because every clause of it is a diagnostic:

> A return shape is written in exactly one place: after `->` in a
> function's declaration. It is not a type. It cannot annotate a
> binding, a parameter, a struct field, a container element or a Map
> value; it cannot nest inside another return shape; it cannot take a
> `?`; and there is no expression that produces one.

The parser already says the last clause, and says it well
(`03_parse/expressions.zig:540-555`):

```zig
// `(1, 2)` — there are no tuples, and "expected ')' to
// close '(', found ','" does not say so.
try self.report(
    "luce.parse.expression",
    self.peek().span,
    "there are no tuples: group values in a list '[a, b]' or a struct",
    .{},
);
```

That message was written before the feature was designed and it is
still exactly right afterwards, which is a good sign. It needs one
sibling in type position:

| written | says |
|---|---|
| `let p: (Int, Int) = …` | `(Int, Int) is a return shape, not a type: a pair that travels together is a struct` |
| `func f(p: (Int, Int)):` | the same |
| a struct field, a `List((Int, Int))` | the same |

The sentence to keep is the second half. **A pair that travels together
is a struct** — that is the line §6 draws, and the diagnostic teaches
it at the moment someone tries to cross it.

---

## 2. `T!`, `T?`, and what `catch` can and cannot supply

`docs/FAILURE.md` settled that fallibility is an attribute of the
function and never of a type — *"`T!` is not a type"* — and that the
error travels out of band: the outcome word is the compiled function's
`i32` return, the value travels in `%out`, and `errored` is one `icmp`
in the caller. **The two channels are already orthogonal**, and a
return shape is a value-channel fact. So:

```luce historical
func read_pair(path: String) -> (Int, Int)!:
    let text = try file_read(path)
    …
    return first, second

func main() -> !:
    let a, b = try read_pair("bounds.txt")
```

`-> (A, B)!` is legal and needs no new mechanism: the callee's `%out`
carries the return shape, the `i32` says whether `%out` means anything,
`errored` still names one `call` instruction, and *"a fallible function
empties `%out` on its errored edge"* holds unchanged because the shape
is one value in the slot (§4).

`try` therefore composes for free, and it is the only composition that
does.

### `catch EXPR` is refused on a multi-return call

`let a, b = f() catch 0, 0` is refused (`luce.sema.fallible`):

> `f answers 2 values, and catch can supply only one — write try, or handle it as a statement`

The reason is the whole of §1 said once more. A fallback for two values
is a comma list standing to the right of an operator, and `catch` binds
between the comparisons and `+` and associates right
(`docs/LANGUAGE.md`) — so `f() catch 0, 0` has no reading that does not
first invent a tuple expression and then give it a precedence. `catch
(0, 0)` is the same request with parentheses on it, and it meets the
`there are no tuples` message the parser already prints. Admitting
either one is admitting the tuple through the error mechanism, which is
the exact shape of the mistake `docs/FAILURE.md` refused when it turned
down Go's value-plus-error.

### The block form needs no new rule, and already forbids the hard case

`docs/FAILURE.md` pinned the `catch:` block to *"a call [written as a
statement], and a plain assignment whose value is a call"*, and
explicitly not to a `let`:

> A `let` is deliberately not among them: the handler would have to
> supply the value the name binds, and only `catch EXPR` can say that.

A destructuring bind is a `let`, so it is already excluded, for a
reason that is doubly true when there are two names. What remains is
legal and useful:

```luce historical
rng.reseed_from(path) catch:              # a statement; values discarded
    print("keeping the old seed")
```

### The honest hole, named

**A fallible multi-return call cannot be handled with values.** It can
be propagated (`try`) or discarded (statement, with or without a
handler), and there is no third thing. The corpus has no site that
wants one — the fallible functions in the tree are `files.read`,
`files.write` and friends, all single-valued or void — but the hole is
real and should be written down rather than discovered.

It closes on the multi-assignment form, if that ever lands: given
`low, high = f() catch:`, the handler has two places already declared
and can write both. That is the same reopening condition §1 gave, from
the other side.

### `T?` positions

`Int?` is an ordinary type — absence *is* a value (`docs/FAILURE.md`'s
table says so, and S43 says holding `none` owns nothing) — so it needs
no rule at all:

```luce historical
func lookup(m: Map(String, Int), k: String) -> (Int?, Bool):
```

is legal because every element of a return shape is an ordinary type
and `Int?` is one. `-> (Int, Int)?` is refused in §1 for the opposite
reason: the `?` would be marking the *shape*, and the shape is not a
value that can be absent.

### `else` on a multi-return call is refused

`minmax(xs) else …` is `luce.sema.absent`:

> `else supplies a value when one is absent, and minmax answers 2`

`else` is the null-coalescing operator and it operates on a `T?`
*value*. A multi-return call is not a value at all — that is the whole
of §1 — so there is nothing for `else` to stand on. Per-element
fallbacks are written on the names, where they read better anyway:

```luce historical
let first, second = parse_pair(line)
let a = first else 0
```

---

## 3. Ownership: one clarifying clause, one new check, no rule changes

`return` is a move (S16). `return a, b` is that move said twice, and
`docs/OWNERSHIP.md` needs **no rule changed** to say so. What follows
is the whole of the ownership content, clause by clause.

**S16 applies per value.** Each returned object moves independently to
the caller; the caller's two names each own one. No verb, as ever.

**S1 applies per name.** `let low, high = f()` creates two fresh
bindings, each owning what it received, each freed by its scope.

**S17 applies per position.** `return xs, ys` where `xs` is a borrowed
parameter is the existing compile error, naming `xs`, with the existing
words (`04_semantics/builder.zig`):

> `xs is a borrowed parameter; return copy xs, or take the parameter as give [OWNERSHIP.md S17]`

**S3/S19 apply to a discarded call.** `f()` as a statement produces
values nobody bound; each is a temporary and dies at the end of the
statement. **This machinery already exists and already does exactly
this for a single return** — `lowerBlock` (`builder.zig:1453-1465`)
records a temporaries floor per statement and flushes above it, and
`lowerExpression` parks every ownership-yielding value into a hidden
local for that flush. Under §4's lowering the discarded value is one
struct, so the walk that already releases an object-carrying struct
temporary releases the whole return shape, and the count of things to
release is one whatever the arity. Nothing extends; it is already
general.

**S28 applies to the shape as a whole.** Returning objects in a return
shape moves the whole tree, which is what S28 says about a struct and
which is what the shape lowers to.

### The one genuinely new fact

Only a comma can write this:

```luce historical
func bad(xs: give List(Int)) -> (List(Int), List(Int)):
    let alias = xs
    return xs, alias        # one object, two moves
```

Two positions in one return can name **the same object**, and two
moves of one handle would give two caller bindings ownership of it and
free it twice. S23 already forbids that outcome; nothing before now
could express the attempt.

**Half of it needs no new check, and half of it needs exactly one.**
This is worth getting right, because the tempting claim — "the
positions are walked in order, so the second one meets a poisoned
name" — is **false**, and the source says why.

`lowerReturn` (`04_semantics/builder.zig:2519`, and its object arm at `:2550-2585`) does not poison
what it returns. It records one `moved: ?LocalId` so that the unwinder
below it does not free the object it just handed over, and that is all
it needs to do, **because `return` is a terminator**: with one value
there is nothing after it in the block that could touch the name
again, so poisoning would have been ceremony. `Poison` is
`enum { given, freed }` (`04_semantics/context.zig:281`) and has no
third member for exactly this reason.

The comma is what puts something after a return for the first time. So:

| written | caught by | says |
|---|---|---|
| `return xs, alias` | **the existing check, unchanged** — `lowerReturn`'s `.alias` arm | `alias aliases an object it does not own; return copy alias or return the owning name [OWNERSHIP.md S16, S17]` |
| `return xs, borrowed` | **the existing check, unchanged** — the `.borrow_param` arm | `borrowed is a borrowed parameter; return copy borrowed, or take the parameter as give [OWNERSHIP.md S17]` |
| `return xs, xs` | **one new check** | `xs is returned twice; one object cannot be owned twice [OWNERSHIP.md S23, S45]` |

That the alias message already ends in *"or return the owning name"* —
written for a language with one return channel — is good evidence that
the ownership model was general all along and the channel was the only
narrow thing. But the same-name case is genuinely unreachable today and
is genuinely a double free tomorrow, and a memo that claimed it fell
out for free would be wrong in the one place it matters most.

**The check is small and it is where `moved` already is.** `moved`
becomes a small list — one entry per returned position — because the
unwinder must now skip every object it handed over rather than one.
A name already in that list is the diagnostic above. The list is the
check; there is no separate pass.

### The clause

Proposed for `docs/OWNERSHIP.md`, on `docs/METHODS.md` S44's model —
a clarifying clause that changes no rule, appended so no anchor moves
(`www/luce/content/ref/ownership.md` fixes `{#s44}`-style anchors and the
compiler quotes the numbers):

> **S45. A multiple return moves each value, left to right, and no
> object may travel twice.**
> ```luce
> func halves(text: give String) -> (List(String), List(String)):
>     var head = text[0:middle].split(" ")
>     var tail = text[middle:len(text)].split(" ")
>     return head, tail        # both move; the caller's two names own them
>
> func bad(xs: give List(Int)) -> (List(Int), List(Int)):
>     let alias = xs
>     return xs, alias         # COMPILE error: one object, two moves
> ```
> Decision: `return a, b` is S16 said once per value and nothing more.
> Each value moves independently, a borrowed parameter or an alias in
> any position is S17 exactly and says so with the words it already
> had, and a destructuring bind creates one owning binding per name
> (S1). The one fact the single-value channel never had to state is
> that **the values must be distinct objects**: two moves of one handle
> would leave two bindings owning it and free it twice, which S23
> forbids and which only a comma can now write. It is also the one
> thing here that is genuinely new to check, because `return` is a
> terminator and therefore never had to poison what it moved — with one
> value there was nothing after it. A call whose values nobody binds is
> a statement temporary per S3/S19, released whole at the end of its
> statement.

---

## 4. MIR and both engines: the hidden struct

Two designs were weighed. The recommendation is **(b)**, and the
evidence is below rather than asserted, including the one place (b) is
not free.

### (a) Multiple result registers on `call` and `ret`

`Instruction` (`06_mir/defs.zig:158-199`) has `ret: ?Register` — one
optional register — and a register *is* the index of the instruction
that produced it, with one type per instruction in
`Function.result_types`. So (a) is not a small change: `call` grows a
result list, `ret` grows a value list, `result_types` stops being one
type per instruction, and the verifier, the deterministic printer, the
serializer, the interpreter's register file and the LLVM lowering all
follow. `format_version` bumps; the instruction fingerprint at
`06_mir/module.zig:903-921` moves.

**What kills it is not the size. It is that LLVM has no multiple
returns either.** LLVM has aggregate returns — an `llvm.func` answers
one value, and `{i64, i64}` is how two get home. So (a) builds a
multi-result instruction set in stage 6 that stage 8 immediately
collapses back into a product type. It is machinery for a shape the
target does not have.

### (b) A compiler-synthesized struct

`(Float, Float)` **is** a two-field product value. Lower it as one.
The layout is created by the compiler, has no source declaration, and
is never named by a program: `return low, high` is a `struct_make`, and
`let low, high = …` is two `struct_get`s.

Everything it rides on is already there and already proved:

| what | status |
|---|---|
| `struct_make` / `struct_get` / `struct_set` | exist (`defs.zig:158-199`) |
| `ret` of a `.strukt` register | exists; verified by `expectType(actual, function.return_type)` (`verify.zig:382-390`) |
| a `call` whose result is a struct | exists; verified by `if (!result.eql(callee.return_type))` (`verify.zig:341-350`) |
| struct value in `%out` | exists; `resultSize` says `.strukt => 8` (`08_llvm/lower.zig:899-903`) — the same slot an `Int` uses |
| the outcome channel | untouched; `errored` names the `call` instruction and never looks at its type |
| copy-on-store for a returned struct | exists (`docs/STRINGS.md`) |
| struct returns on the interpreter | exist (the `struct_make`/`struct_get` arms at `interpreter/machine.zig:374-385`) |
| the oracle | **needs no edit at all**, which is why it is the arm that proves the sugar resolved right |

**Verifier: no change.** It never reads `layout.name`, never checks
name uniqueness, never requires a non-empty field list, and has no tie
of any kind to a source-level `StructDecl` — the only such link,
`Analyzer.struct_decls`, lives in stage 4's temporary memory and dies
with it.

**Printer: no change, and one decision.** `06_mir/print.zig:18-25`
prints `struct {name}:` and its fields; `:112` prints
`struct_get r{d}, {s}.{s}`.
A synthesized layout wants a name, and the right name is **the shape as
written**: `(Float, Float)`. It reads correctly in `luce ir`, it reads
correctly if it ever escapes into a diagnostic through
`types.typeName`, and it is **unforgeable from source** — user struct
names are identifiers, qualified with a module prefix, so nothing a
program can declare collides with a name containing `(`. Two functions
with the same shape intern to one layout, as heap type shapes already
do.

**`format_version` does not move.** It is **18**
(`06_mir/module.zig:37`), and the struct section is already a dynamic
count with per-layout name and field blobs (`module.zig:67-75`); a
synthesized layout is a few tens of bytes of ordinary payload. No
instruction encoding changes, so the fingerprint hash
(`module.zig:903-921`) does not move. This feature therefore requires
**no bump of its own**; if it ships after the numerics work it simply
finds 19 already there, for that work's reasons and not this one's
(`docs/NUMERICS.md:688-692`).

**`abi.version` does not move either.** It is **9**
(`08_llvm/abi.zig:117`); nothing here touches the `LuceHost` vtable,
and a return shape occupies the 8-byte `%out` slot a struct already
occupies. `docs/NUMERICS.md:694` says the same of the numerics work,
so the two land back to back without the published ABI moving once.

**`valueCount` and the 4096 bound are fine, but must be fed.**
`max_struct_values` (`04_semantics/helpers.zig:16-30`) bounds the
*flattened leaf count of one struct type* — it exists because `zeroOf`
emits one instruction per counted leaf. A two- or three-scalar return
shape contributes two or three and is nowhere near it. But `valueCount`
and `carriesObjects` index `struct_shapes` directly by layout index
(`declarations.zig:446-451`, `:393`), so a synthesized layout without a
shape entry is an out-of-bounds read the first time `lowerReturn` asks
whether it carries objects.

**Debug/release parity is unaffected.** No new instruction means no new
origin; origins are recorded per instruction and never read on the
execution path, so both modes still run at identical speed, and a trap
inside a multi-returning function reports `file:line:column` and a call
trace exactly as it does today.

### The three hazards, all in stage 4

These are what will actually break, and they are worth naming here so
the implementation does not discover them:

1. **Three arrays are indexed by layout index in lockstep** —
   `structs`, `struct_decls`, `struct_shapes` (`declarations.zig:112-122`).
   `struct_decls` is walked by index against `structs.items.len`
   (`:554-560`) and a synthesized layout has no `StructDecl`. Either
   `StructDeclInfo.declaration` becomes optional, or synthesis happens
   after that walk — and `struct_shapes` must be extended either way.
2. **`Lowering.structs` is a snapshot slice captured per function**
   (`declarations.zig:1487-1494`), documented as *"settled before any
   lowering runs"* (`06_mir/build.zig:105-106`). Appending a layout
   *during* body lowering reallocates the list and leaves the in-flight
   slice stale and short. **Synthesis therefore belongs in a pass
   between `collectFunctions` and lowering**, driven off the collected
   signatures, where every shape a program can return is already known.
3. **`carriesObjects` must be right on the synthesized layout**, because
   S28 and the ownership walk read it. It falls out of `sumShape`
   (`:861-869`) provided the shape entry exists — which is hazard 1
   again, and is the reason to state it twice.

### The one thing that is not free, said plainly

**A struct value's field run is a real allocation.**
`luce_rt_struct_make` (`runtime/exports.zig:571`) calls
`Runtime.makeStruct` (`runtime/heap.zig:1066-1074`), which does
`self.objects.alloc(Value, fields.len)` — and `objects` is documented
as *"an ordinary freeing allocator"* precisely because struct field
runs have a death point (`heap.zig:85-93`). So a function that returns
two values under design (b) costs one allocation and one free per call,
where a function returning one `Int` today costs neither. `libluce_rt`
is an opaque external library, so LLVM's O3 pipeline does not see
through the make/get/free triple and delete it.

That is a real cost and it should not be waved at. Two things about it,
one reassuring and one not:

**It is not a regression against what the corpus writes today.**
`calc.luc` allocates a `Step` at eight sites already; `editor.luc`
returns a `State` from every `Handle.*`. The programs that want this
feature are *already* paying exactly this allocation by hand, and (b)
does not add it — it moves it into the compiler and deletes the
declaration. Against the workaround, (b) is a wash on speed and a large
win on the page.

**It is a regression for the two workarounds that return scalars.**
`math.random_step` returns an `Int` in a register today and writes its
state through a `List` allocated once by `seed`; as
`func next(var self) -> Int` it would allocate per draw. `Draw.emit`
returns an `Int` per call, and its five call sites sit in a
per-**token** loop (`editor.luc:226-275`), so a highlighted line of N
tokens is N calls and a frame is that times the visible rows. Those
two — the mutate-and-answer method and the tight scanner — are exactly
the shapes §5 is built for, so the feature's motivating case is the one
that pays. That is worth knowing before it is measured, not after.

### The fix, scheduled and backend-only

The synthesized layout has a property no user struct has: it is created
by the compiler, **provably never stored, never a field, never a
container element, and destructured at exactly the one site that
consumes the call**. So the backend may return it flat.

`%out` is already a per-type-sized slot — `resultSize` answers 1 for a
`Bool`, 8 for an `Int`, 16 for a `String`, 24 for a `String?`. A return
shape's slot is `sum(resultSize(Ti))`, the callee writes the values
into the caller's `alloca` directly, and `struct_get` on that call's
result reads a field of the slot. No `luce_rt_struct_make`, no
allocation, no free. The interpreter's mirror is to write N registers
where it writes one.

**This changes nothing above stage 6**: no MIR instruction, no wire
format, no ABI field, no semantics, and no diagnostic. It is the same
kind of change as `07_optimize`'s `ownership` pass — deleting something
LLVM structurally cannot see through, because we know a fact about it
that the target does not. It is step 7 of the plan, it is measurable
against `bench/compare.sh`, and it is the one step that may honestly be
skipped if the benchmark says the allocation does not show.

**Recommendation: (b), with the flat return scheduled and the
allocation written down in the meantime.** (b) is correct on day one,
changes no instruction, bumps no version, and is proved by an oracle
that needs no edit. (a) is a larger change that ends at the same
aggregate and would have to be undone to get the same optimisation.

---

## 5. `var self`, completed

This is why the memo exists. The RNG, end to end.

### Today

```luce historical
# src/luce/std/math.luc:229-239
func seed(from: Int) -> List(Int):
    var folded = from % 2147483646
    if folded < 0:
        folded += 2147483646
    return [folded + 1]

func random_step(rng: List(Int)) -> Int:
    rng[0] = rng[0] * 48271 % 2147483647
    return rng[0]
```

A one-element `List(Int)` allocated by `seed` and kept alive for the
life of `main` (`dice.luc:25`), whose entire purpose is to give an
`Int` reference semantics so that the *state* can go out through a
borrow while the *draw* goes out through `return`. The module header
(`math.luc:13-15`) documents the workaround as if it were a design.

### Under `docs/METHODS.md` alone

```luce historical
struct Rng:
    state: Int

    func step(var self):
        self.state = self.state * 48271 % 2147483647
```

The List is gone and the struct is honest, but the call site went from
one call to two — `rng.step()` then `rng.state` — because the receiver
was occupying the only return channel there was.

### Under this memo

```luce historical
struct Rng:
    state: Int

    func next(var self) -> Int:
        self.state = self.state * 48271 % 2147483647
        return self.state

    func in_range(var self, low: Int, high: Int) -> Int:
        if high <= low:
            trap("in_range needs low < high")
        return low + self.next() % (high - low)
```

and the call site:

```luce historical
var rng = Rng(state = 42)
let roll = rng.in_range(1, 7)
```

**One call. No allocation in `seed`. No List pretending to be an
`Int`.** The write-back is invisible at the call site, which is the
whole point: `rng` is a `var`, the method says `var self`, and the
receiver's new value goes where it came from.

### The two channels compose, literally

`docs/METHODS.md` specified the receiver write-back as one sentence:

> `p.scale(2.0)` means `p = Point.scale(p, 2.0)`.

With a return value it becomes, internally:

> `let roll = rng.next()` means `rng, roll = Rng.next(rng)`.

And under §4 that is not a second channel at all. **The method's
results are `[receiver] ++ declared`**, and they travel in one
synthesized layout:

```
struct (Rng, Int):
    field0: Rng
    field1: Int
```

`Rng.next` lowers to a function with return type `.strukt` of that
layout; its `return self.state` becomes `struct_make(self, state)`;
the call site emits one `call`, one `struct_get 0` stored back into
`rng`'s place, and one `struct_get 1` bound to `roll`. There is no
receiver mechanism separate from the return mechanism, which is the
sense in which `self` was always waiting for this memo.

Four consequences, each of which is a rule someone will test:

1. **A `var self` method with no declared return is unchanged.** Its
   results are `[receiver]` — arity one, the single return the language
   has today. `func step(var self):` lowers exactly as `docs/METHODS.md`
   said it would, and this memo does not touch it.
2. **At statement position the write-back still happens.** `rng.next()`
   as a statement discards the *declared* results and stores result
   zero, because the receiver is not a value the program can receive —
   it is where the call puts its receiver back. §1's "a statement
   discards all values" means all *declared* values.
3. **The receiver is not destructurable.** `let r, roll = rng.next()`
   is refused, `luce.sema.self`:
   > `next answers 1 value; its receiver is written back, not returned`

   The declared arity is the arity at the call site. If the receiver
   were nameable at the call site it would be a second way to spell
   `rng`, and `docs/METHODS.md` refused `Point.scale(p, 2.0)` for
   exactly that reason.
4. **A raising method still leaves its receiver as it was.**
   `func next(var self) -> Int!:` puts the shape in `%out` and the
   outcome in the `i32`. `docs/FAILURE.md` guarantees that *"a fallible
   function empties `%out` on its errored edge"*, and the write-back
   reads result zero out of `%out` on the returning edge only. All or
   nothing, for free, by the mechanism that was already there.

**`var self`'s object restriction survives untouched and needs no
extension.** `docs/METHODS.md` requires a `var self` receiver's struct
to carry no object handles, so the write-back is a pure value store.
That is a fact about result zero. The *declared* results may carry
objects freely and move under S16/S28 like any other return — a method
may answer a fresh `List` while writing back a value-only receiver, and
the two facts do not interact.

### One coordination note for the implementer

`docs/METHODS.md`'s ordered plan, step 7, includes building the
diagnostic *"a var self method returns nothing; its receiver is its
result"*. **Do not build it.** If the methods work and this work are in
flight together — and the owner has asked for `self` complete — that
refusal should never exist in the tree, and the row should come out of
`METHODS.md`'s diagnostics table rather than in and then out again.
That is the only edit this memo makes to the previous one.

---

## 6. The corpus, and where the line is

### What converts

| where | today | after |
|---|---|---|
| `calc.luc:20` | `struct Step` + 8 constructions + 25 field reads | `-> (Int, Int)`; the struct is **deleted** |
| `std/math.luc:229-251` | `seed` allocating a `List(Int)`; `random_step`, `random`, `random_int` all taking it | `struct Rng` with `func next(var self) -> Int` (§5) |
| `dice.luc:25-30` | `math.seed(seed)` + `math.random_int(rng, 1, 7)` | `Rng(state = seed)` + `rng.in_range(1, 7)` — since spelled `math.rng(seed)`, once `state` took its `private` marker (docs/VISIBILITY.md §6) |
| `wordcount.luc:34-41, 65` | `heaviest -> String`, count re-looked-up | `heaviest -> (String, Int)`; one hash lookup deleted |
| `std/math.luc:159-174` | `vmin` and `vmax`, two traversals | a `minmax -> (Float?, Float?)` beside them, one traversal; `bench/stats.luc:34-35` and `examples/stats/stats.luc:21-24` become its users, the second losing a whole sort |
| `editor.luc:212-299` | `Draw.emit -> Int`; six call sites set `at` from a bound they computed themselves | `Draw.emit -> (Int, Int)` — the columns used *and* where it stopped; the clip argument stops being load-bearing |

Six sites, and only the first deletes a declaration.

**`editor.luc`'s is the weakest of the six and is listed last on
purpose.** Nothing there is duplicated and nothing is wrong: the
caller's `at = stop` is correct, and returning the reached offset
would only let it stop being correct *by coincidence*. It is a
readability change with a latent-correctness argument behind it, not a
deletion, and if the `editor.luc` step runs out of budget this is the
row to drop. Saying so is cheaper than discovering it during the
rewrite.

### What does not convert, and the line

`Theme` (`editor.luc:13`) and `State` (`editor.luc:199`) stay structs
and are not close calls. But "a Point stays a Point" is not a rule, and
without one every two-field struct in the language erodes one commit at
a time.

> **Corrected while this memo was being checked.** The rule first
> written here was *"a struct becomes a return shape only when no site
> stores it, passes it, or holds it past the statement that produced
> it."* It is wrong, and the way it is wrong is instructive: applied
> literally it **disqualifies `Step`**, the memo's own exhibit, because
> `Parse.expression` holds one in `var left` across a `while` loop
> (`calc.luc:43-53`). A rule that refuses the one case the feature was
> commissioned for is not a strict rule, it is a broken one. The error
> was reaching for *lifetime* — how long the value lives — when the
> thing that actually distinguishes a bag from a type is **direction**.

The rule is mechanical, and it is about which way the value travels:

> **A struct becomes a return shape when it is never an input** — never
> a parameter, never a struct field, never a container element — and is
> only ever read field-wise. It may be held, reassigned and carried
> across a loop; two `var`s do that as well as one. The moment some
> function takes it *as a thing*, it is a thing, and a thing has a
> name.

It is greppable, which is the point: the question "is this a bag?" is
answered by `grep ': Step'`, not by taste about the name.

- **`Step` qualifies.** No function in `calc.luc` takes one —
  `Parse.term(text: String, at: Int)` takes the halves separately — and
  no `Step` is ever a field or an element. Its 25 field reads are all
  `left.value` / `right.at`, never a whole `Step` handed on.
- **`State` disqualifies** on its first parameter position
  (`Handle.key(state, …)`), which is exactly why `docs/METHODS.md`
  wants it to grow methods instead.
- **`Theme` disqualifies** on the file-scope constant that holds one and
  the `Draw` functions that take it.

**Loop-carried is not disqualifying, and it is worth showing why**,
because it is the case the broken rule tripped on. `Parse.expression`'s
accumulator becomes two `var`s, and the body gets *shorter*, because
only the value differed between the arms:

```luce historical
func expression(text: String, at: Int) -> (Int, Int)!:
    var value, here = try Parse.term(text, at)
    var scan = Scan.skip_spaces(text, here)
    while scan < len(text) and (text.byte_at(scan) == 43 or text.byte_at(scan) == 45):
        let operator = text.byte_at(scan)
        let right_value, right_at = try Parse.term(text, scan + 1)
        if operator == 43:
            value = value + right_value
        else:
            value = value - right_value
        here = right_at
        scan = Scan.skip_spaces(text, here)
    return value, here
```

against today's `left = Step(value = left.value + right.value, at =
right.at)` twice over. **This is also the memo's own refusals being
paid for in public**: the two `here = right_at` lines are what
refusing plain multi-assignment costs, and they are the honest price
of §1's "two allowed positions" having no exceptions.

**Two corollaries worth stating on the page**, because they are the two
mistakes the rule prevents:

- **A pair that gets a third field later was a struct all along.** If a
  return shape has grown twice, the growth is telling you it is a type.
  Three is not a hard limit, but it is the number at which the question
  should be asked again.
- **A return shape cannot be documented.** A struct's fields have names
  and can carry a comment; `(Int, Int)` has positions. If the two values
  need a sentence each to be usable, they need names, and names are what
  a struct is.

### What this memo does not touch

`std/strings.luc`'s `find -> long` returns `-1` for "not found" — a
sentinel where `long?` would now serve. That is a genuine
wart, it is the same *kind* of wart, and it is **not this feature**:
optionals already shipped and the fix is `-> Int?`, not `-> (Bool, Int)`.
Writing it as a pair would be the Go `comma, ok` idiom, which exists in
Go because Go has no optionals. Luce has them. Listing it here so that
the migration commit does not reach for the new hammer.

---

## 7. Diagnostics

The wording bar for a count mismatch is set at
`04_semantics/builder.zig:3742-3749` and is `NAME takes N thing{s}, got M`:

```zig
try self.fail("luce.sema.call", span, "{s} takes {d} argument{s}, got {d}", .{ … });
```

Everything below is parallel to it. **One new code, `luce.sema.shape`**
— it is the arity of a bind against the arity of a call, which is not
what any of the twenty-six existing `luce.sema.*` codes is about.
Everything else composes with a code that exists: `luce.parse.assign`
already covers the shape of an assignment statement — its one message
today is `cannot assign to this expression`
(`03_parse/grammar.zig:1299`) — and `luce.sema.self` is the code
`docs/METHODS.md` introduces, which this memo reuses rather than adding
a second one beside it.

| written | code | said |
|---|---|---|
| `let a, b, c = minmax(xs)` | `luce.sema.shape` | `minmax answers 2 values, got 3 names` |
| `let a = minmax(xs)` | `luce.sema.shape` | `minmax answers 2 values, got 1 name — write let a, b = minmax(…)` |
| `return a` in `-> (Int, Int)` | `luce.sema.return` | `minmax answers 2 values, got 1` |
| `return a, b` in `-> Int` | `luce.sema.return` | `count answers 1 value, got 2` |
| `return a, b` in a func with no `->` | `luce.sema.return` | `this function returns nothing` — existing, unchanged |
| `print(minmax(xs))`, `f() + 1`, `xs.append(f())` | `luce.sema.call` | `minmax answers 2 values, and only a let or a var can receive them` |
| `return minmax(xs)` from `-> (Float, Float)` | `luce.sema.call` | `minmax answers 2 values, and only a let or a var can receive them — bind them, then return them` |
| `low, high = minmax(xs)` | `luce.parse.assign` | `a destructuring bind declares its names: write let low, high = minmax(…)` |
| `let a, var b = f()` | `luce.parse.assign` | `one let or one var governs the whole bind` |
| `let a: Int, b: Int = f()` | `luce.parse.type` | `a destructuring bind takes its types from the call` |
| `-> ()` | `luce.parse.type` | `a function that answers nothing writes no arrow` |
| `-> (Int)` | `luce.parse.type` | `one value needs no parentheses: write -> Int` |
| `-> ((Int, Int), Int)` | `luce.parse.type` | `return shapes do not nest: there are no tuples` |
| `-> (Int, Int)?` | `luce.parse.type` | `'?' marks a value that may be absent, and a return shape is not a value` |
| `let p: (Int, Int) = …`, a parameter, a field, `List((Int, Int))` | `luce.parse.type` | `(Int, Int) is a return shape, not a type: a pair that travels together is a struct` |
| `(1, 2)` as an expression | `luce.parse.expression` | `there are no tuples: group values in a list '[a, b]' or a struct` — **exists already**, unchanged |
| `let a, b = f() catch 0, 0` | `luce.sema.fallible` | `f answers 2 values, and catch can supply only one — write try, or handle it as a statement` |
| `minmax(xs) else …` | `luce.sema.absent` | `else supplies a value when one is absent, and minmax answers 2` |
| `let r, roll = rng.next()` | `luce.sema.self` | `next answers 1 value; its receiver is written back, not returned` |
| `return xs, xs` | `luce.sema.own` | `xs is returned twice; one object cannot be owned twice [OWNERSHIP.md S23, S45]` — the one genuinely new ownership check (§3) |
| `return xs, alias` | `luce.sema.own` | `alias aliases an object it does not own; return copy alias or return the owning name [OWNERSHIP.md S16, S17]` — **exists already** |
| `return xs, borrowed` | `luce.sema.own` | `borrowed is a borrowed parameter; return copy borrowed, or take the parameter as give [OWNERSHIP.md S17]` — **exists already** |

Four of the twenty-two are already written word for word, which is
the measure of how much of this feature the tree was shaped for — and
one, the double move, is new for a reason §3 spends a paragraph on
rather than assuming.

---

## 8. Docs, site, and the grammar

### `docs/`

- **`docs/LANGUAGE.md`** — a new `## Answering more than one thing`
  section, placed after `## Failure: T!, try, catch` because §2 is the
  half a reader will look up. It carries the declaration, the bind, the
  two allowed positions, the no-tuple rule, and one line on `var self`.
- **`docs/LANGUAGE.md`'s "Deliberately absent (for now)"** — add
  **tuples** by name. The list does not mention them today, and after
  this memo the absence is a decision rather than an omission.
- **`docs/OWNERSHIP.md`** — S45, appended (§3).
- **`docs/METHODS.md`** — delete the `## var self methods return
  nothing` section's refusal, delete its row from the diagnostics
  table, and delete step 7's clause that builds it. Leave the section's
  *history* as a correction note, in the house's `> **Corrected once
  built**` form, because the reasoning is worth keeping.
- **`docs/MISSING.md`** — Tier 3 item 4 closed; "The order to work
  down" item 10 loses its second third.
- **`docs/METHODS.md:11` and `docs/NUMERICS.md:17`** — one word each:
  both cite item 10 by a Tier it is not in, and disagree with each
  other. Correct them in the same commit, so the series stops
  propagating it.
- **`docs/PIPELINE.md`** — no stage changes status; nothing to do.

### `www/luce/`

The table of contents is hand-written (`www/luce/src/site.zig`), so a new
page is a file plus one row. Pages that need editing:

| page | why |
|---|---|
| `www/luce/content/ref/statements.md` | `## func` (L17) gains the return list; `## let and var` (L47) gains the destructuring bind; `## Assignment` (L60) says that multi-assignment is not one |
| `www/luce/content/ref/types.md` | the load-bearing one: a return shape is **not** a type, and this is the page that says so |
| `www/luce/content/ref/expressions.md` | `## Calls` (L123) gains the two allowed positions; `## Operators Luce does not have` (L88) gains the tuple |
| `www/luce/content/ref/ownership.md` | S45, with a `{#s45}` anchor — appended, never renumbered, because `main.zig`'s `checkLinks` fails the build on a dead anchor and the compiler quotes the numbers in diagnostics |
| `www/luce/content/ref/failure.md` | `catch` cannot supply a shape; `try` composes |
| `www/luce/content/tour/functions.md` | the tutorial half of the declaration |
| `www/luce/content/tour/values.md` | the tutorial half of the bind |
| `www/luce/content/status/index.md` | item 4 (L139) closes — **and its "destructured at 15" is wrong today and must be corrected in the same commit**; the work list's item 3 (L188) loses a third; the "Deliberately absent, permanently" list (L67) gains tuples |

**Every sample must run.** `www/luce/src/verify.zig` compiles and executes
each fenced `luce run` block with the freshly built toolchain and
compares the claimed output byte for byte, and a fence that declares no
mode is a build error. So the site cannot document this ahead of the
implementation except as ` ```luce fail ` — which asserts that
`luce check` *rejects* the sample, and is therefore exactly the right
fence for the refusals in §1 and §7. **Write the refusal samples
first**: they are executable specification of the tuple rule and they
can land with step 1.

**Nothing forces the prose.** `www/luce/src/coverage.zig` checks named
surfaces — builtins, methods, trap and error codes, std exports, CLI
options — and has no check that a *syntax* rule is documented. A new
language form slips past it entirely. That is a known gap, not one this
memo should close in passing, but it means the site edits above are a
discipline rather than a build failure and should be in the same commit
as the feature.

### The grammar, for highlighters

**The site's highlighter needs nothing.** `www/luce/src/highlight.zig` is a
deliberately forgiving byte scanner with eight token classes; `(`, `)`
and `,` fall through its final arm and are emitted escaped and
unclassified, which is already how `List(Int)` renders. `let` is a
keyword, `Int` and `Float` are in `type_names`, and destructured names
fall through as plain — the highlighter never marked names after `let`
anyway. The one guard that could fire is
`test "every name the language spells has a class here"`, and it
cannot: **this feature introduces no new word.** That is worth saying
out loud, because it is the strongest single piece of evidence that the
surface is small — a language change that adds no token and no keyword.

**`examples/editor/editor.luc`'s own highlighter needs nothing** either.
`Words.classify` dispatches on keywords, capitalisation and builtins,
and `(`, `)`, `,` already land in `Draw.line`'s final `else` arm as
`theme.punct`. (`editor.luc` is separately a *consumer* of the feature —
§6 — and that rewrite is build-gated by the compile test in
`src/apps/loom/shell.zig` and by `build.zig`.)

**The VS Code grammar had one rule that was genuinely wrong**, in a
file that was then hand-maintained and already stale:
`tools/vscode-luce/syntaxes/luce.tmLanguage.json` matched a return type
with `(:|->)\s*([A-Za-z_][A-Za-z0-9_]*)\b`, which `(` blocks, and it
still listed removed v1 Fabric builtins (`create_image`,
`create_texel`, `texel_*`) while its keyword list was missing `give`,
`copy`, `free`, `new`, `import`, `try`, `catch` and `none`. Fixing the
one rule this feature breaks without fixing the rest would have been a
stopgap; the honest scope was one commit that re-derives the whole file
from the tables it claims to follow, and a generator with a test is
what would stop it rotting again.

> **Since built (2026-08-10).** `tools/grammar.zig` now generates the
> grammar from the compiler's own tables — the lexer's keywords, the
> builtin and method tables, the type names — and
> `test "the committed grammar is what the generator emits"` pins the
> committed file byte for byte, so the drift this paragraph describes
> cannot recur.

---

## Order

Sequenced **after** the numerics implementation, because §4's layout
synthesis and stage 4's `fit` both live in the same walk and neither
wants the other in flight, and **with** the methods implementation,
because step 4 is what the owner asked for and step 5 cannot be written
without both. Each step leaves the tree green.

1. **Multiple returns on plain functions, end to end.** The parser's
   return list and the four shape refusals; `binding`'s name list;
   `FunctionDeclInfo.return_type` becomes `returns: []Type`; the
   synthesized-layout pass between `collectFunctions` and lowering,
   with §4's three hazards; `lowerReturn` emitting `struct_make`; the
   destructuring bind emitting `struct_get`; statement-position
   discard; §7's diagnostics. Both engines get it at once and the
   oracle needs no edit. *Tests:* one `specs/` program per legal shape,
   run on both arms; one `errors_spec.zig` case per refusal; one
   `06_mir` printer test pinning the synthesized layout's name.
2. **`T!` and `T?` composition.** `-> (A, B)!`, `try`, the `catch:`
   block on a statement, and the two refusals. Most of this falls out
   of step 1; the tests are the deliverable, and they belong in
   `specs/errors_spec.zig` beside the existing `catch` cases.
3. **Ownership.** S45 in `docs/OWNERSHIP.md` and
   `www/luce/content/ref/ownership.md`; `lowerReturn`'s `moved` becoming a
   list, which is both what the unwinder needs and where the
   double-move check lives (§3); the two existing diagnostics reached
   per position; the discarded-statement temporary. *Tests:*
   `specs/ownership_spec.zig` for each of the three return-position
   refusals, and the agree arm's **leak census** is what actually
   proves the good cases — a double move is a double free, and the
   census is the thing that catches it if the check is ever wrong.
4. **`var self` returns.** Results become `[receiver] ++ declared`;
   statement-position write-back; the receiver-not-destructurable
   refusal; the raising edge. **`docs/METHODS.md`'s "returns nothing"
   refusal is never built** (§5). *Tests:* the `Rng` of §5 as a program
   in `specs/`, run on both arms, including the statement-position
   call.
5. **The corpus.** §6's six sites, each in its own commit with its own
   test: `calc.luc`'s `Step` deleted, `std/math.luc`'s `Rng`,
   `dice.luc`, `wordcount.luc`'s `heaviest`, `math.minmax` with
   `bench/stats.luc` and `examples/stats/stats.luc` as its users,
   `editor.luc`'s `Draw.emit`. The `editor.luc` one goes last and
   alone, because its six call sites are the change most able to go
   quietly wrong — and it is also the row §6 says to drop first if the
   step runs long, since it deletes nothing.
6. **Docs and site.** §8's list, including the status page's stale
   "15", `LANGUAGE.md`'s absent list gaining tuples, and `MISSING.md`
   item 4 closed. The refusal samples from step 1 land here as
   ` ```luce fail ` fences.
7. **The flat return** — backend and interpreter only, no surface, no
   MIR, no wire, no ABI (§4). Measured with `bench/compare.sh` against
   step 6's commit, with `dice.luc` and `editor.luc` as the rows that
   should move. **This step may honestly be skipped** if the numbers
   say the allocation does not show, and the memo would rather say so
   now than have someone build it on faith.

Steps 1 through 3 are one feature and should not be released apart.
Step 4 is the one the owner asked for. Steps 5 and 6 are what make the
first four true of something. Step 7 is optional and measured.

---

## Refused, with reasons

**Tuples as a type.** The whole of §1, and the reason is not taste: an
anonymous structural product type would be the first structural type in
a language with no generics, no sum types and one subtyping relation,
and every structural type asks whether it nests, whether a container
holds it, and whether it compares. Python and Swift both said yes and
both then had to build the thing a tuple is not — `namedtuple`,
`dataclass`, and a compiler special case to let a Swift tuple conform
to `Equatable` at all. A pair that travels together is a struct.

**`return f()` pass-through, and `g(f())`.** Go has both and pays for
them with a clause in its specification saying that a multi-valued
call used as arguments must be the *only* arguments. The benefit is one
saved line. Refusing it means the "two allowed positions" rule has no
exceptions, which is the kind of rule a reader can hold.

**Plain multi-assignment `a, b = f()`.** Go needs it because Go's
dominant multi-return is `v, err = f()`, and Luce has no `err` —
`docs/FAILURE.md` put the error in its own channel on purpose. What is
left is loop-carried state, which `var self` now serves. Reopens if the
corpus writes the extra line often; closing the §2 hole is the argument
that would do it.

**`_` as a discard.** Go's reason for it is that Go makes an unused
local an error; Luce has no unused-value or unused-binding diagnostic
at all, so the reason does not transfer. Adding it means deciding
`let _ = f()` and `for _ in xs:` and writing the language's first
exemption from no-shadowing. A named binding is freed at the same
moment and tells the reader more.

**`catch` with a fallback per value.** `catch 0, 0` is a comma list to
the right of an operator that binds between the comparisons and `+`;
`catch (0, 0)` is the tuple with parentheses on it. Either one admits
the tuple through the error mechanism, which is the shape of the
mistake `docs/FAILURE.md` refused when it turned down Go's
value-plus-error. The hole this leaves is written down in §2 rather
than papered over.

**Named return values** (Go's `func f() (low, high Float)`). Go's own
style guidance is to use them only for documentation, its `naked
return` is widely regarded as a mistake, and the names shadow into the
body as pre-declared variables — which in Luce would be file-scope
`var` at function scope, a thing the language does not have. If a
return shape needs its positions explained, §6's rule says it is a
struct.

**Multiple result registers in MIR** (option (a), §4). It is a real
instruction-set change with a format bump behind it, and it ends at an
LLVM aggregate return, because LLVM has no multiple returns either. It
would build in stage 6 a shape stage 8 has to collapse, and the
optimisation it appears to buy is available to option (b) as a
backend-only change with no surface consequences at all.

**Spending a return position on errors.** `docs/FAILURE.md:377-379`
refused Go's value-plus-error, and this memo does not reopen it. `T!`
keeps the outcome channel, `try` and `catch` keep their grammar, and
no signature in this memo answers `(T, Error)`. That multiple returns
now exist is precisely why the sentence has to be said again: the
premise changed and the conclusion did not.

## SELF supersession — 2026-08-08

`docs/SELF.md` retired this record's hidden receiver-at-result-zero
convention before lock.  A writing method now mutates one bare owning
`var` binding in place through MIR `call_inout`; its declared zero, one,
or many results are exactly the results the caller receives.  If the
method errors, receiver writes already performed remain visible.  The
multiple-return surface and its parallel existing-binding assignment
are otherwise unchanged.
