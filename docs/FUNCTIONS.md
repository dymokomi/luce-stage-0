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
| **D3** | Function values compare with `==`/`!=` (same function or not), have no ordering, and `string(f)` answers the function's name.  They are values: copy freely, no verbs, nothing to free. |
| **D4** | The visibility rule rides along: a lambda may name what its file may name; a function value crossing a module boundary is the *value* crossing, already-resolved — visibility gates the reference site, exactly as ratified. |
| **D5** | A `give`-taking function is spawnable and passable like any other; the *call through the value* checks argument verbs exactly as a direct call does.  Nothing about ownership moves. |
| **D6** | The std customers land in the same run: `xs.sort_by(f)`, `xs.keep(f)`, `xs.map_to(f)`-shaped helpers where the design review says they earn their keep — each a `luce.sema.import`-routed std function per the strings precedent, not new builtins. |

## Questions for ratification

**Q1 — the arrow form as proposed** (`(a, b) -> expr`, one expression,
types inferred from the landing site)?

**Q2 — method references refused** (D1), with the diagnostic teaching
the capture line?

**Q3 — which std customers ship with it** — `sort_by` alone, or the
small family (`sort_by`, `keep`, first-class `find_by`)?
