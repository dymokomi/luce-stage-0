# Functions as values — the capture line

**Drafted for ratification, 2026-08-07.**  The owner asked, during the
threads ratification: *"passing a function as a parameter would make
it even cleaner, like functions without actual func — lambdas?"*  The
assessment that framed this memo: the feature divides at **capture**,
and the half on the near side fits Luce exactly.

## The line

An inline function that touches **only its own parameters** is a
function pointer wearing clean syntax — no environment, no hidden
state, and in a language with scope ownership and no collector, **no
new ownership questions at all**.  An inline function that reaches a
variable from its enclosing scope — a *closure* — is an invisible
object holding references with no owner.  Rust needed three closure
traits and `move` semantics there; everyone else pays with a garbage
collector.  Luce's honest spelling of behavior-plus-state already
exists: **a struct with a method**, the state explicit, owned, and
visible.

So: **function values and capture-free lambdas in; capture refused**,
with the struct-method answer written into the diagnostic.

## The syntax proposal

**S1 — a named function is a value where a function type is
expected:**

```text
func by_score(a: Player, b: Player) -> bool:
    return a.score < b.score

xs.sort_by(by_score)
```

The bare name, no call parentheses.  Resolution through the
head-names-a-declaration path that already serves `Struct.func`.

**S2 — function types, spelled the way a signature already reads:**

```text
func sort_by(xs: list(Player), before: func(Player, Player) -> bool):
```

`func(T, ...) -> R` in type position — parameter types only (no
names), `-> R` optional exactly as it is on declarations.  It may
annotate a parameter or a `let`; it may not be a container element or
a struct field in this run (each is a real question — a struct
carrying behavior is dispatch — and neither is needed by the
customers; recorded as deferred, not refused).

**S3 — the lambda: a parenthesized parameter list, an arrow, one
expression:**

```text
xs.sort_by((a, b) -> a.score < b.score)
tasks.append(spawn crunch(give chunk))     # threads: named functions already serve
numbers.keep((n) -> n % 2 == 0)
```

- **Parameters are bare names.**  Their types come from the function
  type the lambda lands on — *a literal has no type until it lands on
  one*, the rule the language already lives by, applied to one more
  literal.  A lambda in a position that expects no function type is
  refused ("a lambda needs a place that expects a function").
- **One expression, no block.**  A body that wants statements is a
  named function wanting a name.  This keeps the form honest (an
  expression cannot secretly grow state) and sidesteps the
  return-inside-lambda question entirely.
- **The parse is unambiguous where it matters**: `(a, b)` can open
  nothing else — there are no tuples — and the single-parameter case
  `(x) -> …` resolves at the arrow, one token after the close.
- **No capture**: the body may name its parameters, module-level
  constants, and visible functions — the same set a top-level
  function's body may name.  Reaching an enclosing local is refused:
  *"a lambda carries no environment; state that travels with behavior
  is a struct with a method."*

**Alternatives considered and not proposed**: Python's
`lambda a, b: …` (a second keyword, and its colon fights the
block-colon the eye is trained on); `|a, b| …` (the pipes are
bitwise-or now); a `=>` arrow (a second arrow spelling when `->`
already means "answers").

**Block-bodied anonymous functions, asked about and declined**
(owner, same sitting: *"anonymous function definition right as
function parameter, or is it too much JavaScript?"*).  The blocker is
grammatical before it is aesthetic: an indentation language cannot
put a statement block inside a call's parentheses — this is exactly
why Python's `lambda` is one expression, after years of rejected
multi-line proposals.  JavaScript affords it with braces and owns the
captures with a collector; Luce has neither, on purpose.  The one
shape that fits indentation languages is the **trailing block**
(Swift, Ruby, Kotlin) — the body after the call, indented normally —
and it is declined *because it works*: a body with room for
statements immediately wants the enclosing scope, which is capture.
Recorded as the shape this would take if a future corpus bleeds for
it (a `spawn:` block is the plausible customer); the door is marked,
not bricked up.

## Decisions

| | decision |
|---|---|
| **D1** | Named top-level functions and namespace functions (`Struct.func`, `module.func`) are values in function-type positions.  **Methods are not** — a method reference is a closure over `self`, which is the far side of the line.  The refusal names the workaround (`(p) -> p.length()` … which itself needs no capture only when it re-receives the receiver; the sentence shows the honest form). |
| **D2** | A lambda lowers to a compiler-named top-level function — it *is* S1 after the analyzer runs; MIR gains function-pointer values and an indirect-call shape, `format_version` bumps.  Both engines dispatch through the same table; `libluce_rt` learns nothing. |
| **D3** | Function values have no equality or ordering, and `string(f)` answers the function's name.  They are values: copy freely, no verbs, nothing to free. |
| **D4** | The visibility rule rides along: a lambda may name what its file may name; a function value crossing a module boundary is the *value* crossing, already-resolved — visibility gates the reference site, exactly as ratified. |
| **D5** | A `give`-taking function is spawnable and passable like any other; the *call through the value* checks argument verbs exactly as a direct call does.  Nothing about ownership moves. |
| **D6** | The std customers land in the same run: `xs.sort_by(f)`, `xs.keep(f)`, `xs.map_to(f)`-shaped helpers where the design review says they earn their keep — each a `luce.sema.import`-routed std function per the strings precedent, not new builtins. |

## Ratified (owner, 2026-08-07)

*"Ok then just lambdas then. Lambdas are good."*  The proposal as
drafted: the arrow form, one expression, types from the landing site,
no capture, method references refused with the teaching diagnostic.
"Just lambdas" is read as the minimal std surface — `sort_by` ships
as the proving customer; `keep`/`find_by` join only if the build
finds them trivially clean, and otherwise wait for the corpus to ask.

## The questions, as they were held

**Q1 — the arrow form as proposed** (`(a, b) -> expr`, one expression,
types inferred from the landing site)?  **Ratified.**

**Q2 — method references refused** (D1), with the diagnostic teaching
the capture line?  **Ratified.**

**Q3 — which std customers ship with it** — `sort_by` alone, or the
small family (`sort_by`, `keep`, first-class `find_by`)?  **Minimal:
`sort_by`, with the family at the build's honest discretion.**

## As built (2026-08-08)

S1–S3 and D1–D5 shipped as ratified.  Function values are program
indices, lambdas synthesize distinct source-positioned function names,
and both engines dispatch through the same program table.  D6 shipped
at the ratified minimum: `std.lists` provides stable O(n log n)
`xs.sort_by(before)` for every list element type, routed through method
syntax after `import std.lists`; `keep` and `find_by` remain deferred.

## BINDING amendment — 2026-08-11

**D1's second sentence is retired.**  Methods *are* function values
now, bound to the receiver they were written on: `receiver.method`
where a `func(T, ...) -> R` lands is a value whose environment is that
receiver, with the receiver's parameter dropped from the written type.
The capture line D1 drew is unmoved — the environment is a struct the
program declared, with a name, a layout and an ownership class — and
what changed is that Luce now spells the struct-with-a-method answer as
a value rather than only recommending it.  docs/BINDING.md is the
design and its *As built* section is what shipped; the lambda's refusal
of capture (S3, D10 there) stands permanently.

D2's "a function value is an index" is likewise one version old: it is
now the pair `{function, receiver}`, carried as a two-slot field run.
The run's *shape* is a struct's; its **tag is its own**, because a
function value owns the run and never the objects inside it, so every
ownership walk in `libluce_rt` has to stop at one rather than re-own
somebody else's graph (docs/BINDING.md, third *As built*).  That is
the one semantic the runtime learns about function values, and it is
what makes a stored bound method safe.

**D3's equality is retired** (docs/BINDING.md D6, 2026-08-11).  "Same
function or not" was the whole answer while a function value *was* a
function; it is now the function and the receiver it may carry, and
its type cannot say which — so `f == g` would call two binds of one
method equal whatever they carry.  `==` and `!=` on a function value
are refused with that sentence, beside the ordering refusal D3 already
made, and `string(f)` is how a program asks what a value names.  The
rest of D3 stands: function values copy freely and take no verbs.

**S2's "where a function type may stand" is widened** (docs/BINDING.md
D7, 2026-08-11).  A function value is **storable**: a struct field, a
list element, an array cell and a union payload field hold one as
`(func(...) -> R)?`, absence is the zero, and calling through one takes
the narrowing or the `else` any other optional takes.  A map value is
written **bare** — `m.get(k)` already answers `V?`, so the absence is
the missing key and a second `?` would be a `V??`.  A bare `func` type
still stands where a value is always present: a parameter, a `let`, a
return.

The spelling is the **parenthesized type**, and the rule is uniform:
`(T)` is `T`, wherever a type may stand.  Parentheses group and are
never required — `func(string) -> long?` is unchanged and still means
*a function answering a `long?`*, which is how `parse_int` is written
as a value, and `(func(string) -> long)?` is the optional function.
`(long)?` is legal and says nothing extra, which is the price of
having one rule instead of a special case.

**D5's worker sentence is narrowed** by the same fact: a function
value borrows the receiver it may carry, a borrow cannot cross into a
runtime that has nothing to borrow *from*, and the type cannot say
whether this one carries anything — so a function value is refused as
a spawned function's parameter and as its result.  A call through a
value still checks argument verbs exactly as a direct call does, which
is what D5 was really about.

## As built — the call suffix, 2026-08-12

**A call is a postfix operator.**  `EXPR(args)` parses wherever
`EXPR[i]` does — one more suffix in the postfix loop, beside the index
and the field access — and calls the value the expression in front of
it answers.  Until this ran, a call was accepted only on a bare name
or on `receiver.method`, so `chooser()(5)`, `m["a"](1)` and `(f)(x)`
were **parse** errors and every call through a stored function value
had to launder its callee through a local first.  That was an
unfinished corner of D7's storability, not a decision: no memo ever
restricted calls to names.

The typing rule is one sentence: **a call suffix applies to any
expression whose type is a `func(...)`**, and it is checked exactly as
a call through a named value always was — the interned signature says
the arity, the argument types and the verb each object argument
travels by, a function type has no parameter names and no defaults, so
a named argument is refused where it is written.  `give` and `copy`
are the signature's business and the callee's spelling changes nothing
about them (D5): a `give`-taking parameter demands the verb through a
call suffix exactly as through a name.

**The head-names-a-declaration forms are untouched and still win.**
`f(x)`, `Struct.helper(x)`, `module.func(x)`, `receiver.method(x)`,
`Union.member(field = v)`, `Enum(n)` and every builtin resolve through
the written text they always did, because only the written text can
name a declaration; the suffix takes what is left over, which is
exactly the set that had no grammar before.

**An absent callee stays refused.**  A `(func(...) -> R)?` is callable
where the flow analysis has proved the value is there, and only a
local or a parameter is ever proved — a field or an element can change
between the test and the use (docs/LANGUAGE.md), so narrowing one
would be a promise the language cannot keep.  `rows.render(3)` on a
field is therefore still an error, but it now teaches the fix instead
of claiming the struct has no such method:

```text
rows.render is (func(long) -> string)? and may hold none; only a local
or a parameter narrows, so bind it first (let render = rows.render),
test it (if render != none:), then call render(…) [BINDING.md D7]
```

A call through a value is never **fallible**, because a function type
carries no `!` (docs/BINDING.md D8 is not built), so `try EXPR(args)`
is refused by name as `luce.sema.fallible`.  `spawn` still takes a
declared call and nothing else, and refuses a call suffix in the
parser.

**It removed a special case rather than adding one.**  The tree keeps
exactly the two call paths it already had — the declaration's and the
value's — and the value's stopped being local-only: `05_hir`'s
`ResolvedCallee.Indirect` now carries the callee **node** instead of a
`LocalId` plus a `narrowed` flag, so a narrowed name records the same
`narrowed_get` every other read of it records and the storable form
needs no bookkeeping of its own.  The callee is the call's **first**
operand in evaluation order, the way a method's receiver is, and it
rides the same spill machinery the arguments do.  `format_version` did
not move: nothing about MIR changed, and `call_indirect` always took a
register.

## SELF clarification — 2026-08-08

D1 is unchanged under implied self: methods still cannot be function
values because doing so would carry a receiver.  The namespace members
that can become values now say `static func`; static members, like
top-level functions, may also be spawned.  A method may be called only
through its value receiver, never through the enclosing type.
