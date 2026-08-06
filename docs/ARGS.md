# Naming an argument, and not writing the one that never changes

> **Every Luce block here is tagged `historical`, and that is the
> honest tag.** `tools/doccheck.zig` compiles every fenced `luce`
> sample in the documents it knows about, and `historical` is its one
> exemption — *"a syntax that was proposed and refused, or a fragment
> quoted out of a program nobody wrote."* A memo written before its
> feature exists is entirely the second of those: half the samples
> quote code that is about to change and half show a syntax the
> compiler will reject today. So **`docs/ARGS.md` is not in
> `doccheck`'s `documents` list yet**, and the last step of `Order` is
> where it joins — at which point the forward-looking fences lose the
> tag and start being checked, which is the only state in which the
> tag would be a lie.

> **The rule.** Every parameter has a name, and a call site may use it:
> `term_style(theme.gutter, bold = false)`. Positional arguments come
> first and fill slots left to right; **the first named argument ends
> the positional run**, and everything after it is named. A parameter
> may declare a default — `func find(s: string, needle: string, start:
> long = 0)` — and a default is a **folded compile-time constant**,
> evaluated once at the declaration by the folder that already folds
> file-scope `let`. Defaults are trailing: a parameter with one may be
> followed only by parameters with one. **Struct fields take the same
> clause**, which is what finally makes `struct` the options record it
> has been one clause away from being. Arguments are evaluated in the
> order they are *written* and bound to the slots they *name* — the two
> may differ, and that is the price of reordering. Nothing reaches MIR:
> **names and defaults are resolved away in stage 4**, the `call`
> instruction stays positional, and neither the serialized module's
> `format_version` nor the published host ABI moves.

`docs/MEMORY.md` records why scope ownership won; `docs/TYPES.md` why
there are seven numbers; `docs/RETURNS.md` how a function answers more
than one thing without acquiring a tuple. This is the smallest memo in
the series and the one with the least new machinery behind it — which
is worth saying at the top, because the interesting part is not the
feature. It is that **Luce's two closest relatives both refused this
feature, both for good reasons, and every one of those reasons turns
on something Luce does not have.**

It is `docs/MISSING.md`'s Tier 3 **item 7** (`MISSING.md:302-304`),
quoted in full because it is the whole warrant:

> **No default or named arguments.** `term_style(fg, bg, bold)` is
> called 15 times across `programs/`; 14 end in the same noise word
> `false`.

That count is exact — `docs/audit/DOCS.md`'s finding **F13** already
caught and corrected an earlier over-claim of *"16 times / 13"*,
settling on 15 and 14 across `programs/` and 12 and 11 inside
`editor.luc` alone — and it is re-derived below. What it does *not* say, and what changes the shape
of the feature, is that `term_style` is a **builtin**, not a function,
and lives in a table with no parameter names in it at all
(`04_semantics/builder.zig:104`). **The headline evidence for this
feature is not collected by the obvious form of it.** §3 is about
that, and it is why this memo has four argument paths where it
expected one.

It is the first of the ratified roadmap's runs (`MISSING.md:185`:
*"the ratified roadmap (named args, visibility, bitwise/hex)"*), and
it goes first because it is the only one that touches nothing below
stage 4.

---

## What the owner asked for

The standing process — careful planning, review before implementation
— and, for this memo, two instructions:

> deep research into other languages, and grounding in our individual
> implementations and overall architecture

Both were load-bearing, and they pulled in the same direction. The
research found that the three strongest published arguments against
this feature — Go's, Zig's and Dart's — all rest on premises Luce
falsifies, which is the subject of §"Three reasons Luce may take what
Go and Zig refused". The grounding found three places in stage 4 that
refuse a named argument in three different sentences, and a fourth
that *requires* names and has been quietly running the exact algorithm
this feature needs since struct construction shipped.

Four of the brief's own premises came back corrected by the research
and are corrected here rather than carried:

- **There is no Go FAQ entry on default arguments.** The FAQ's only
  adjacent entry is on *overloading*, and that is what maintainers
  cite when declining. The real rationale is the 2012 SPLASH article
  §10, quoted in §"The precedents", and it is a much better argument
  than the FAQ would have been.
- **Kotlin relaxed positional-after-named in 1.4, not 2.2.** The 2.2
  release notes say nothing about argument order; the Kotlin
  specification's own note pins the boundary at 1.3→1.4.
- **PEP 671 was never rejected.** It is still an open Draft on the PEP
  index, targeting a 3.12 that shipped without it. It is stalled, not
  adjudicated, and the PEP records no counter-arguments at all — there
  is no objections section in it. Cite it for the proposal; attribute
  no rejection to anyone.
- **The *"35-sentence standard METHODS set"* does not exist.**
  `docs/METHODS.md` has two diagnostics tables of 5 and 10 rows;
  `docs/RETURNS.md` has one of 22 and is the larger bar. §8 is written
  to the 22.

---

## Decisions to ratify

One read, twelve answers. Each is argued at the section named.

| | decision | where |
|---|---|---|
| **D1** | **Names are optional at every call site, never required.** Kotlin/C#'s position, not Swift's. A parameter name is a convenience for the reader of the *call*, not part of the function's identity. | §1, Refused |
| **D2** | **A default is a folded compile-time constant**, evaluated once at the declaration by `foldConstant`, materialised at each call site. Not a call-time expression, not callee-side. | §2 |
| **D3** | **Defaults are trailing.** A parameter with a default may be followed only by parameters with defaults. Same for struct fields. | §1 |
| **D4** | **The first named argument ends the positional run.** Kotlin 1.3's rule, not Kotlin 1.4's. | §1 |
| **D5** | **Named arguments may be written in any order**, and **arguments are evaluated in the order written**, not the order declared. Already true of struct construction; now said out loud. | §1, §4 |
| **D6** | **No positional-only and no keyword-only markers.** No `/`, no `*`, no `{}` section. One kind of parameter. | Refused |
| **D7** | **`self` is not a nameable argument and cannot have a default.** | §1 |
| **D8** | **Struct fields take defaults**, on the same clause and through the same folder. Construction stays **named-only** — it does not gain positional arguments. | §1, §"The Zig question" |
| **D9** | **`none` becomes a constant when something says what it is absent *of*.** `ConstantValue` gains an `absent` arm, and `let x: long? = none` becomes legal at file scope too — a gap `T?` left behind. | §2 |
| **D10** | **All four argument paths are served, in three tiers.** User functions and struct fields get names and defaults; free builtins get both from a widened table; builtin *value methods* get neither, because their tables hold types and not names. | §3 |
| **D11** | **Names die in stage 4.** MIR's `call` stays positional, `format_version` does not move, and stages 5–8, `libluce_rt` and the host ABI are untouched. | §6 |
| **D12** | **A `give` parameter cannot have a default**, and this needs no new rule — it falls out of two that exist. It gets a sentence anyway. | §5 |

---

## What the corpus actually says

The shipped Luce corpus is **1,822 lines, 128 `func` declarations and
618 calls** across `programs/`, `src/luce/std/` and `bench/`. Its
arity ≥ 3 population is **46 calls** — 36 at arity 3, 10 at arity 4.
Everything below is measured against that, and the embedded test
corpus (1,342 more declarations inside `.zig` test blocks) is reported
separately where it disagrees, because a test fixture is not idiom.

### The headline number is right, and points at the wrong machinery

`term_style` is written 16 times in `programs/`. One is a string
comparison inside the editor's own highlighter (`editor.luc:183`), so
**15 are calls** — `MISSING.md:302` is exact. Fourteen end in `false`;
the fifteenth (`editor.luc:413`, the keyword colour) ends in `true`.

| what repeats | count |
|---|---|
| `term_style` calls in `programs/` | **15** |
| …ending in the literal `false` | **14** |
| …passing `-1` for the background | **13** |
| …whose last two arguments are `-1, false` | **12** |
| `term_style` as a share of all arity-3 calls in shipped Luce | **15 of 36 — 42%** |

```luce historical
# programs/editor.luc:352, 381, 397, 404, 415, 417, 419, 425, 431, 433
term_style(theme.gutter, -1, false)
term_style(theme.comment, -1, false)
term_style(theme.text, -1, false)
```

Ten of the fifteen are that exact shape. Under
`term_style(fg, bg = -1, bold = false)` every one of them becomes
`term_style(theme.gutter)`.

And one fact the gap list did not have, which is the strongest single
number in this survey:

> **Every boolean literal argument in the entire shipped Luce corpus
> is `term_style`'s third argument.** Fifteen of fifteen. No other
> call in `programs/`, `src/luce/std/` or `bench/` passes a bare
> `true` or `false` to anything.

The corollary is just as sharp. Userland Luce declares exactly **one**
`bool` parameter — `Draw.gutter(number: long, current: bool)`
(`editor.luc:429`) — it has one call site, and that site passes a
computed predicate (`line_index == cursor_line`), not a literal. **The
boolean-flag problem in this codebase is entirely a host-builtin
problem**, in a builtin the user cannot re-declare.

**But `term_style` is not a function.** It is row 27 of a table:

```zig
// src/luce/04_semantics/builder.zig:104
.{ .name = "term_style", .kind = .term_style, .arity = 3, .host = true },
```

`Builtin` carries a name, an intrinsic, an **arity** and two flags
(`builder.zig:55-65`). There is nowhere in it for a parameter to have
a name, let alone a default. So defaults on `func` declarations — the
feature as ordinarily understood — collect **none** of the fifteen
sites the gap list filed. That is not a reason to refuse the feature;
it is the reason §3 exists and the reason `Order` stages it as it
does.

### Where names buy something, and it is not where defaults do

Of 1,473 declarations across shipped and embedded Luce, **five** have
arity ≥ 4, and all five are in shipped code:

| arity | site | declaration | what a name fixes |
|---|---|---|---|
| 5 | `editor.luc:314` | `status(self, rows: long, cols: long, line: long, column: long)` | **four adjacent `long`s**; `rows`/`cols` and `line`/`column` are each swappable with no type error |
| 4 | `editor.luc:364` | `Draw.emit(value: string, from: long, to: long, remaining: long) -> long` | three adjacent `long`s, six call sites |
| 4 | `editor.luc:375` | `Draw.line(content: string, start: long, finish: long, width: long)` | three adjacent `long`s |
| 4 | `editor.luc:239` | `State.key(var self, name: string, inserted: string, visible: long)` | two adjacent **`string`s**, silently swappable |
| 4 | `strings.luc:90` | `fold_case(s: string, first: long, last: long, shift: long)` | called `fold_case(s, 65, 90, 32)` and `fold_case(s, 97, 122, -32)` — **three bare integers, no name anywhere** |

`fold_case` is the strongest readability case in the corpus and it is
in the standard library:

```luce historical
# src/luce/std/strings.luc:85, 88 — today
return fold_case(s, 65, 90, 32)
return fold_case(s, 97, 122, -32)

# with names
return fold_case(s, first = 65, last = 90, shift = 32)
return fold_case(s, first = 97, last = 122, shift = -32)
```

Two call sites. That is the honest size of the *names* harvest in a
1,822-line corpus, and it is the right size to expect: names pay off
as declarations grow, and this corpus has five declarations that are
large enough to notice.

### Where defaults buy something in user code

Exactly one pair of declarations is a wrapper supplying a constant
tail:

```luce historical
# src/luce/std/strings.luc:42-46
func find(s: string, needle: string) -> long:
    return find_from(s, needle, 0)

func contains(s: string, needle: string) -> bool:
    return find_from(s, needle, 0) >= 0
```

`find` is a default argument written as a function. Under this memo it
is deleted and `find_from` becomes `find(s, needle, start: long = 0)`
— **and that closes a bug `docs/MISSING.md:172-178` already filed
against the pair**, because the two disagree today about what a
`start` outside the string means: `find_from` answers `-1`, which is
an argument error, and `find` passes `0` and can never reach that
branch. Merging them makes there be one answer to give. `find_from`'s
own callers pass an explicit `0` at **five of eight** sites
(`strings.luc:43, 46, 63, 119, 157`), which the merge also cleans.
`contains` changes its return type and stays.

Four other pairs *look* like this and the memo declines to count them,
because a survey that does is over-counting the feature by half:

| pair | why it does not convert |
|---|---|
| `strings.lower` / `strings.upper` | both call `fold_case`, with **different** constants (65/90/32 against 97/122/−32). Merging means writing three named arguments at both sites — worse |
| `strings.pad_left` / `pad_right` | different bodies, not a constant tail |
| `math.log2` / `log10` | `ln(x)/ln2` and `ln(x)/ln10`. A `log(x, base = e)` would be `ln(x)/ln(base)` — a runtime `ln` where a folded constant sits today |
| `files.write` / `append_text` | they call **different builtins** (`file_write`, `file_append`). An `append: bool = false` parameter buys a branch in the body, not a deletion — and it is tangled with the reserved-name scar `files.luc:52-55` documents, which is run two's business, not this memo's |

The other trailing-literal patterns the survey turned up are small and
real: `term_move(x, 0)` at four of five sites, and `clamp(x, 0, hi)`
at three of five. Neither is worth a design decision on its own; both
come free.

### The densest site is not a call at all

```luce historical
# programs/editor.luc:449-458
var state = State(
    path = path,
    content = opening,
    cursor = 0,
    scroll = 0,
    dirty = false,
    message = greeting,
    quit_pending = false,
    quit = false,
)
```

Five of eight fields set to the zero of their type, at the struct's
**only** construction site. With field defaults the declaration
absorbs all five:

```luce historical
struct State:
    path: string
    content: string
    cursor: long = 0
    scroll: long = 0
    dirty: bool = false
    message: string = ""
    quit_pending: bool = false
    quit: bool = false

# …
var state = State(path = path, content = opening, message = greeting)
```

Ten lines to one — and, worth more than the lines, an invariant moves
from a construction site to a declaration, where a *second*
construction site could not get it wrong.

The corpus's other multi-field construction is `Theme`
(`editor.luc:29-43`, thirteen `long`s, one site) and it is unaffected:
none of its thirteen values is a default, which is the correct outcome
and worth checking rather than assuming.

### The language already ships the syntax, and it is used 214 times

Positional struct construction is a **compile error**
(`builder.zig:6136`, pinned by
`specs/errors_spec.zig:2953`). So every struct construction in the
tree is named:

| corpus | named-field constructions | positional |
|---|---|---|
| shipped `.luc` | 3 | 0 |
| embedded tests | 175 | 0 (one negative test) |
| site samples | 36 | 0 |
| **total** | **214** | **0** |

That is not evidence that readers *prefer* names — they have no
alternative. What is evidence is the two lines eleven apart in the
same file by the same author:

```luce historical
# programs/editor.luc:328
term_style(theme.status_fg, theme.status_bg, false)
# programs/editor.luc:454
    dirty = false,
```

Same literal, same file, same hand. One reads and one does not, and
the only difference is which side of a rule that has no reason behind
it the value happens to fall on.

### The honest total

**One declaration deleted, ten lines deleted, and roughly forty noise
arguments deleted.** It is a small harvest and should not be sold as a
large one. What makes the feature worth building is §"The Zig
question", and what makes it worth building *now* is §6.

---

## The precedents, and which one Luce is

### Binding time — the axis that decides everything

| | when the default runs | who runs it | may it see other arguments? | the price |
|---|---|---|---|---|
| **Python** | once, when `def` executes | the definition site | no | a shared mutable object; the `None`-sentinel dance in every codebase |
| **Ruby / JS** | per call, in the callee's scope | the callee | **yes**, earlier parameters | JS had to make the parameter list **its own scope**, parent to the body, with TDZ rules between them — and `Function.length` stops counting defaulted parameters |
| **Swift** | per call | the caller, via an emitted default-argument generator | no | little — and it buys the least |
| **Kotlin** | per call | **the callee**, via a synthetic `$default` bridge | **yes**, earlier parameters | a foreign-ABI tax: `@JvmOverloads` and a generated telescoping overload set |
| **C#** | never — it is a constant | **the caller**, baked in at compile time | no | a stale constant frozen into every already-compiled caller |
| **Dart / Zig** | never — `comptime`/compile-time constant only | — | no | the least power, and **no fork to be on the wrong side of** |
| **Luce** | once, at the declaration, into a `ConstantValue` | the folder | no | Dart and Zig's row |

Python's row is the one everybody knows and the one whose *reason* is
least often stated. The language reference is explicit that it is a
consequence rather than a choice — a `def` is an executable statement
producing a function object, and defaults are ordinary values stored
on it, so they are evaluated when the statement runs. The Programming
FAQ's only positive argument for keeping it is memoisation via
`_cache={}`, followed immediately by *"You could use a global variable
containing a dictionary instead; it's a matter of taste."* That is a
weak defence, and PEP 671 exists because it is.

The Ruby/JS row is the honest cost of getting the *other* answer
right. MDN states the contrast in as many words — *"The default
argument is evaluated at call time. Unlike with Python (for example),
a new object is created each time the function is called"* — and then
spends a section on the consequence: *"The default parameter
initializers live in their own scope, which is a parent of the scope
created for the function body,"* so that `function f(a = go()) {
function go() {…} }` throws at run time. Python bought
declaration-time evaluation and got the famous bug; JavaScript bought
call-time evaluation and paid for it with an extra scope in the
specification. **Neither is free, and the constants-only answer is not
on the fork at all.** Dart and Zig both took it independently.

The C# row is the one that looks like Luce's and is not. Eric
Lippert, from the C# design team:

> the default value is baked in to the **caller**; the code on the
> callee side is untouched […] if you change the default value of a
> library method without recompiling the callers of that library, the
> callers don't change their behaviour just because the default
> changed.

Microsoft's own library guidance files it as **DISALLOWED: Changing
the default value of a property, field, or parameter**, and names the
sharp edge in the platform's vocabulary — *"not a binary break"* —
which is the hazard restated from the other side: the old caller keeps
running because it is carrying the old value inside itself. Lippert
reports the feature "was a controversial feature for the design team,
which had resisted adding this feature for almost ten years."

### Names — required, optional, or absent

| | may a call name an argument? | is the name part of the function's identity? | may a call reorder? |
|---|---|---|---|
| **Swift** | **must**, by default (`_` opts out) | **yes** — `insertSubview(_:at:)` *is* the name (SE-0021), though never part of the *type* (SE-0111) | **no** — allowed once, removed by SE-0060 |
| **Python** | yes, outside `/` | no | yes, freely, in the keyword zone |
| **Kotlin / C#** | yes | no | yes, with everything after the permutation named |
| **Dart** | only inside a `{}` section | no | yes, within the section |
| **Go / Zig** | **no** — refused outright | — | — |
| **Luce** | yes, anywhere | **no** | yes, and evaluation stays in written order |

**Swift is the strongest opinion in the field and Luce is not it**, for
a reason that is arithmetic rather than taste: Swift's labels are part
of a declaration's *name* because Swift has **overloading**, and the
label is what tells `f(from:)` from `f(at:)`. SE-0021 exists precisely
so an overload set can be indexed by writing the full name —
`UIButton.init(type:)`. Luce has no overloading. A label here could
disambiguate nothing, because there is nothing to disambiguate: one
name is one function, always. Mandatory labels would be Swift's syntax
without Swift's problem, and they would refuse every call site in the
corpus on the day they landed — including `min(a, b)`, which Swift's
own guidelines say should carry no labels.

Swift's *second* opinion is answered in *Refused*: **SE-0060 removed
argument reordering**, on the grounds that it *"complicates the
language for little benefit"*, that *"few users know this is possible,
and many have expressed surprise or disgust that it's possible"*, and
on the Cocoa principle that *"the same API call looks similar in
different users' code."*

### Go's refusal, which is about API decay

There is no Go FAQ entry on defaults; the argument lives in *Go at
Google: Language Design in the Service of Software Engineering* §10,
and it is the best-stated case against the feature anywhere:

> This was a deliberate simplification. Experience tells us that
> defaulted arguments make it too easy to patch over API design flaws
> by adding more arguments, resulting in too many arguments with
> interactions that are difficult to disentangle or even understand.
> The lack of default arguments requires more functions or methods to
> be defined, as one function cannot hold the entire interface, but
> that leads to a clearer API that is easier to understand. Those
> functions all need separate names, too, which makes it clear which
> combinations exist.

Rob Pike, declining `golang/go#21909`, adds the scale qualifier that
is the actual claim:

> the designers of the language disagree with that claim when applied
> to **large code bases**. As code with default arguments grows, it too
> often becomes harder to understand, not easier, as functions and
> their invocations become more intricate and more entangled.

**This memo does not have a refutation, and says so.** Pike is
describing a real failure mode, and the answer is not that he is
wrong; it is that the claim is explicitly about large codebases with
many authors, and Luce's is 1,822 lines with one. What the memo owes
in return is a **tripwire**, and §"The risk, and the tripwire" is it.

Robert Griesemer's separate rejection of *named* arguments in the same
thread is a different argument and deserves a different answer:

> One thing to consider is what programming style should be enforced
> once a language provides named arguments (and people invariably
> *will* want to enforce a style): Must they always be named? Never?
> Only when there's more then 3 arguments? Can some names be left out?
> Does the order matter? […] It opens a Pandorra's box of questions.

Every one of those questions has an answer in the decision table
above, and the answers are the same answer: **the compiler does not
enforce a style.** D1 says names are never required, D4 and D5 say
where they may go, and no lint is proposed. The box does not open
because nothing in this memo invites anybody to legislate.

Ian Lance Taylor's closure of `#21909` is worth recording separately,
because it is the same conclusion Zig reached independently: he closed
it *"in favor of #12854"* — type-inferred composite literals. **Go's
official answer to named arguments is `f(T{Name: v})`.** Which is to
say: named struct construction. Which Luce has.

### Zig's refusal, and the asymmetry that is the point

`ziglang/zig#484`, *"function parameters with default values"*, is
closed and unaccepted. Andrew Kelley:

> I think not having optional parameters is pretty reasonable. It
> makes all these considerations go away, keeps the language smaller,
> and it's pretty easy to do something like: […]
> `fn foo_with_one_default(a: i32) { return foo_no_defaults(a, 0); }`
> […] I do this in C/C++ code and I don't miss optional parameters at
> all.

`ziglang/zig#982`, *"Optional argument names in function calls"*, is
closed with **"Solved by #485 + #685"** — that is, *named arguments
are not a language feature in Zig; they are anonymous struct literals
with defaulted fields.*

And `ziglang/zig#485` — **default struct field values** — is
**accepted and shipped**. Kelley's accept ledger is the single most
useful citation in this memo, because the second item on his list of
reasons *in favour* is:

> * ability for functions to provide default arguments as
>   @thejoshwolfe pointed out

**Zig accepted field defaults knowing and intending that they would be
the substitute for parameter defaults.** The asymmetry — fields yes,
parameters no — is deliberate, argued, and documented. The rest of the
ledger is worth having too, because Luce inherits both halves of it:

> Against: someone could put multiple defaults that depend on each
> other, and then at the initialization site, only one is specified,
> and then the other default doesn't make sense. […]
> Decisions: The values must be `comptime` known. […] Best practice
> is: don't create defaults for multiple values that depend on each
> other.

That "against" bullet is promoted to a documented rule in the Zig
language reference, under the heading *Faulty Default Field Values*:

> Default field values are only appropriate when the data invariants
> of a struct cannot be violated by omitting that field from an
> initialization.

**Luce should adopt that sentence as guidance**, in `docs/LANGUAGE.md`
and on the site, and it applies to parameters exactly as it applies to
fields. It is not a rule a compiler can check; it is the rule a
reviewer checks, and it is worth writing down because the failure it
describes — two knobs whose defaults are only jointly sensible — is
the one real way this feature goes wrong in code that compiles.

### The one Zig argument this memo has to answer

`ziglang/zig#3721`'s rejection, from @ikskuh, is not about semantics
at all. It is about **visibility**:

> it's good that the function requires some syntactical difference
> (the anonymous struct) to normal function calls.

> if i read a code like `formatNumber(someInt)`, i assume the function
> has only one argument, but if later there is
> `formatNumber(someOtherInt, 10)`, i wonder: What is the default
> argument value, now i actually have to look up the function
> definition instead of "relying on the name of the function"

Zig accepted the semantics of defaults and rejected their invisibility:
`foo(.{ .a = 1 })` looks different from `foo(1)`, and a defaulted
parameter does not.

**The answer is that Luce's corpus has the complaint in the other
direction, and can be shown so.** Reading `term_style(theme.comment,
-1, false)` today, you do not know what `-1` means either — it is the
host's "use the default background" sentinel, documented in
`docs/V2.md:112` and nowhere in the call. Both spellings send the
reader to the declaration; the difference is *how often*. The
defaulted form sends you there when you want to know what was omitted;
the written-out form sends you there to find out what the value you
are looking at means. In a language where the declaration is always
one name away and always available as source, the second is the worse
trade.

The other half of ikskuh's objection is sharper and has to be granted:

> As soon as zig would allow default args in a normal function call,
> we could also just add full featured function overloading (as
> default args are just a subclass of overloading)

He is right that a defaulted signature is an overload set written
compactly — `f(a, b = 0)` is `f(a)` and `f(a, b)`. What makes it safe
here is that the set is generated by **suffix truncation only** (D3),
so it is totally ordered by arity and every member has the same types
in the same positions. That is not overloading; it is one signature
with a shorter legal spelling, and it introduces no resolution
question, because a call's argument count picks exactly one member.
The moment defaults stopped being trailing (Kotlin's rule), that would
stop being true — which is a second reason for D3 beyond the one §1
gives.

### OCaml, and why it is inapplicable

OCaml is the one precedent that does not transfer, and it is worth a
paragraph rather than a silence, because *why* it does not transfer is
itself a design fact about Luce.

OCaml's labels (`~label:`) and optional arguments (`?label:`) are
shaped almost entirely by **currying**. Every function is unary, so
"the argument was not supplied" and "the argument has not been
supplied *yet*" are the same observation, and the language has to
invent a syntactic trigger for defaulting. The manual states it:

> A function taking some optional arguments must also take at least
> one non-optional argument. The criterion for deciding whether an
> optional argument has been omitted is the non-labeled application of
> an argument appearing after this optional argument in the function
> type.

Which is why `let test ?(x = 0) ?(y = 0) () ?(z = 0) ()` — with two
dummy `unit` parameters whose only job is to trigger defaulting — is
the manual's own worked example. The bill for the feature, in one
list: a mandatory trailing `()` in every such signature, a `?x` relay
form so an optional argument can be forwarded at all, type inference
that *cannot* infer labels (*"they cannot be inferred as completely as
the rest of the language"*), a silent coercion that passes `None` for
every optional parameter when a labelled function meets an unlabelled
function type, and **four dedicated compiler warnings** — 6
`labels-omitted`, 16 `unerasable-optional-argument`, 43
`nonoptional-label`, 48 `eliminated-optional-arguments`.

Luce has no currying, no partial application, and no first-class
functions. A call is complete or it is a diagnostic. **None of that
bill is payable here, and that is worth stating affirmatively rather
than leaving implicit** — it is the first of the three structural
reasons in the next section.

---

## Three reasons Luce may take what Go and Zig refused

The refusals above are good arguments, and the temptation is to weigh
them against the harvest and call it a judgement. That would be the
wrong shape. **Each of the three decisive published arguments turns on
a language property Luce does not have**, and they should be checked
off rather than balanced.

### 1. There are no first-class functions, so a default has no type to not-be-part-of

This is the argument that actually settled it for Go, Zig and Dart,
and it is a type-system argument rather than a style one. Bob
Nystrom, Dart's designer, rejecting `= value` as an optionality
marker:

> There are other places where you write a function type and need to
> be able to indicate which parameters are optional […] In those
> places, you can't specify a default value. **The default value isn't
> part of the type, and putting a default value there wouldn't be
> meaningful.**

> Dart is a little special in that we almost have "first-class
> overloads". When you take a reference to a function that takes
> optional parameters, you get an object that you can call at runtime
> with multiple different signatures.

Zig hit the same wall from the other side: the first objection on
`#484` is *"Combination of default parameters with function pointers
can get confusing. Can function pointer have default parameter value?
Can it be assigned with a function of different signature?"* Swift
resolved the same tension by amputation — SE-0111 removed argument
labels from function *types* entirely, so a Swift function value is
called without them.

**Luce has no function types.** `docs/LANGUAGE.md`'s *"Deliberately
absent"* list opens with *"First-class functions, closures"*, and
`site/content/ref/expressions.md:136` says *"Functions are not values
— a name in call position denotes a function, statically."* There is
nowhere in Luce to write a function type, so there is nowhere for a
default to fail to appear. The question that forced Dart into `{}` and
`[]` sections, and that made Zig nervous enough to decline, **cannot
be asked here.**

### 2. There is no separate compilation, so a baked-in default cannot go stale

C#'s hazard is the caller carrying a value the callee has since
changed. Luce has no separate compilation, no binary libraries and no
distribution format for a module: `.lcm` is *"a seam, not a
deliverable"* (CLAUDE.md), std ships as `@embedFile`d source inside
the compiler, and a `.lc` is a whole program's machine code keyed on
`abi.sourceHash` of the program that made it, refused by name if the
generator identity has moved. **There is no such thing as a caller
compiled against an older callee.** The versioning hazard that made
C# resist this for a decade is structurally absent, which is why Luce
may take the simplest possible design where C# had to take a dangerous
one.

The same fact answers PEP 570's headline rationale for `/` — *"Library
authors would have the flexibility to change the name of
positional-only parameters without breaking callers"* — and C#'s
**DISALLOWED: Renaming a parameter**. In Luce, renaming a parameter
breaks call sites in the same build, and the compiler names each one
with a did-you-mean. That is the entire cost of making a parameter
name public.

### 3. There is no overloading, so a name cannot collide and a default cannot be ambiguous

Swift needs labels *in the name* to index an overload set. C# needs
tie-break rules for *"a candidate that doesn't have optional
parameters for which arguments were omitted."* Lippert documents C#'s
worst case — a class and the interface it implements declaring
**different** defaults, so which you get depends on the static type of
the reference you hold — and Kotlin forbids overrides from restating
defaults to close the same hole from the other side.

Luce has one function per name, no inheritance, no interfaces and no
dispatch. A name resolves against exactly one parameter list; a
did-you-mean has exactly one candidate list; there is no resolution to
perturb and no static-versus-dynamic gap for a default to fall into.
This is the simplification the design should spend, rather than
writing the general thing.

**Three properties, three arguments retired.** Not one of them is a
matter of taste, and none of them is likely to change: first-class
functions, separate compilation and overloading are each independently
refused in `docs/LANGUAGE.md` and CLAUDE.md. If any one of them ever
returns, this memo should be reread before it is.

---

## The question this memo owes an honest answer to: is the Zig answer already in the language?

Zig refuses parameter defaults and named arguments and tells you to
pass an options struct: `Stringify.value(x, .{ .whitespace =
.indent_2 }, writer)`. That works, for one reason easy to miss: **Zig
struct fields have default values.** `.{}` means "every field at its
default." The options struct is not a workaround for defaults — it
*is* defaults, moved one declaration sideways, which is exactly what
Kelley's accept ledger on `#485` says out loud.

Luce has the other half already. Struct construction is named-field
only and has been since it shipped:

```zig
// src/luce/04_semantics/builder.zig:6135-6138
const name = argument.name orelse {
    try self.fail("luce.sema.construct", argument.span,
        "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
    return null;
};
```

So the tempting conclusion is that the Zig answer is here today and
the feature is unnecessary. **It is not, and the gap is exactly one
clause wide.** Luce struct fields have no defaults, so `lowerConstruct`
requires every field (`builder.zig:6184-6194`), so an options struct
in Luce costs *more* than the positional call it replaces, at every
site:

```luce historical
# what the Zig pattern would actually cost today
struct Style:
    fg: long
    bg: long
    bold: bool

term_style_of(Style(fg = theme.gutter, bg = -1, bold = false))
```

Longer than `term_style(theme.gutter, -1, false)`, with a struct
declaration and a construction expression bought and nothing sold. The
Zig pattern is not available to Luce. It is *visible* to Luce, one
feature away.

Which reframes the question, and this is the memo's most important
sentence:

> **The choice is not whether to have defaults. It is whether defaults
> attach to struct fields, to parameters, or to both — and they are
> the same mechanism either way.**

- **Fields only** (pure Zig, and Go's `#12854` answer) buys the
  many-knob configuration case and makes the three-argument case
  worse. The corpus has one site of the first kind and fifteen of the
  second.
- **Parameters only** (everyone else) cashes `term_style` and
  `find_from`, cashes nothing on `State`, and leaves struct
  construction requiring every field forever — a wart with its own
  corpus site.
- **Both** is one folder, one `default: ?*Expression` on two AST nodes
  that already look alike, and two fill-in sites in stage 4 that
  already have the same shape. `ast.Parameter`
  (`03_parse/ast.zig:330-341`) and the struct field record
  (`03_parse/grammar.zig:779-796`) are parsed forty lines apart by
  nearly the same loop.

D8 takes both, and the argument for it is that the second half is
nearly free once the first is built. That is not a reason to build a
feature; it is a reason not to build half of one and call it done.

---

## 1. The surface

### Names at the call site

Nothing in the grammar changes, because **the parser has parsed named
arguments since struct construction shipped.** `argumentList`
(`03_parse/expressions.zig:621-644`) is shared by plain calls, method
calls and construction, and its doc comment already says so:

> The shared `( ... )` argument list: positional values, or
> `name = value` for struct construction.

It reads `IDENT` `=` on a one-token lookahead
(`expressions.zig:627`) and hands `ast.Argument{ name: ?[]const u8,
value, span }` to stage 4 in every case (`03_parse/ast.zig:64-70`).
Stage 4 then refuses it in four places, in four sentences:

| site | sentence |
|---|---|
| `builder.zig:4987` | `function arguments are positional` |
| `builder.zig:5205` | `method arguments are positional` |
| `builder.zig:6370` | `builtin arguments are positional` |
| `builder.zig:6212` | folded into `{s}(value) takes one argument`, for the conversions |

Four refusals to delete or reword, and no grammar work at all. **This
feature adds no token and no keyword** — the same thing
`docs/RETURNS.md` was able to say about multiple returns, and for the
same reason: the shape was reserved.

The `=` spelling is safe here in a way it is not everywhere.
Assignment in Luce is a **statement**, never an expression, so
`f(x = 1)` cannot be read as "pass the value of assigning 1 to x" —
there is no such value. Comparison is `==`, a distinct token, and the
parser's own test pins the one ambiguity a reader might imagine:
`f(a = 1 == 2)` is one named argument whose value is a comparison
(`03_parse/test.zig:799`). Python needed the walrus to be a *different*
operator for this reason, and PEP 671 rejected `:=` as a
late-default spelling because *"it may be misinterpreted as
`target:int=expr` with the annotation omitted in error."* Luce has no
walrus and no inline annotation, so `=` is unclaimed.

### The positional run, and where it ends (D4)

> Positional arguments fill parameters left to right from zero. **The
> first named argument ends the positional run**; every argument after
> it must be named.

```luce historical
term_style(theme.gutter, bold = false)     # ok
term_style(theme.gutter, -1, bold = false) # ok
term_style(fg = theme.gutter, -1, false)   # refused
```

This is Kotlin 1.3's rule. Kotlin 1.4 relaxed it — a named argument
*sitting in its own position* no longer ends the run, so
`reformat("s", uppercaseFirstLetter = false, '-')` became legal — and
C# has the relaxed rule too (*"valid as long as they're not followed
by any positional arguments, **or they're used in the correct
position**"*).

Luce takes the strict one, because the relaxed rule is not one
sentence. It requires the reader to know that a name may or may not
consume its position depending on whether it *agrees* with the
position it is written at, so answering "where does the third argument
go?" means first checking whether the second one's name matched.
Kotlin needed the relaxation for parameter lists where naming one
argument in the middle is the only readable option; Luce's longest
declaration takes four, and naming the middle one plus everything
after it is two extra words.

If the corpus writes those two extra words often, the rule relaxes to
Kotlin's later and nothing already written breaks. That is the right
direction for a rule to be able to move in.

### Reordering, and the clause it costs (D5)

Named arguments may be written in any order. This is less a new
decision than one the language already made and never wrote down:
`Point(y = 2.0, x = 1.0)` compiles today, and `lowerConstruct` fills
`registers[field_index]` rather than `registers[i]`
(`builder.zig:6182`) precisely so it can.

What that costs, said plainly and ratified:

> **Arguments are evaluated in the order they are written, and bound
> to the slots they name.** When a call reorders, evaluation order and
> parameter order differ.

`f(b = one(), a = two())` calls `one()` first. Python behaves exactly
this way, C# states the same rule normatively (*"the arguments are
evaluated in the order in which they appear in the argument list, not
the parameter list"*), and it has not been a reported source of bugs
in either, because the two orders coincide in every call anybody
writes. But it is a fact about the language and it belongs in
`docs/LANGUAGE.md` beside the *"evaluated left to right"* sentence
that is already there.

The alternative — Swift's, refusing reordering outright (SE-0060) — is
argued in *Refused*.

### Defaults in the signature (D2, D3)

```luce historical
func find(s: string, needle: string, start: long = 0) -> long:
```

One new production, in the one place a parameter is parsed
(`03_parse/grammar.zig:875-886`): an optional `= EXPRESSION` after the
type. The expression is stored on `ast.Parameter` and folded in stage
4; §2 is the fold.

**Trailing only.** A parameter with a default may be followed only by
parameters with defaults. Python has the same rule and calls it *"a
syntactic restriction that is not expressed by the grammar"*; Ruby has
it and raises a `SyntaxError` (*"arguments with defaults must be
grouped together"*); Kotlin does **not**, and pays for the difference
with a case worth looking at:

```kotlin
fun greeting(userId: Int = 0, message: String) { }
greeting(message = "Hello!")   // ok — 0 for userId
greeting("Hello!")             // error: No value passed for parameter 'message'
```

A parameter that must *always* be named, in a language where naming is
optional. That is PEP 3102's `*` arriving by accident, through a hole
in the ordering rule rather than through a marker anybody chose. D6
refuses the marker; **D3 is what stops the language growing one by the
back door.** Kotlin's own specification gives the other half of the
reason — a non-trailing default would need *"an ambiguity of which
argument for position i is the correct one"* resolved, and there is no
good resolution — and §"The one Zig argument this memo has to answer"
gives a third: only suffix truncation keeps a defaulted signature from
being a genuine overload set.

The trailing rule also has an ABI-shaped virtue worth noting even
though Luce does not need it today. Kotlin's `@JvmOverloads`
generates its telescoping set *"with that parameter and all parameters
to the right of it removed"* — right-to-left only, because
**suffix-shaped defaults are the only ones expressible across a
boundary that has no notion of them.** Luce's boundaries are
`libluce_rt`'s C ABI and `LuceHost`, and neither has any notion of
them. Nothing in this memo reaches either (§6), but a design that
*could* not is a better one than a design that happens not to.

### Struct fields take the same clause (D8)

```luce
struct State:
    path: string
    content: string
    cursor: long = 0
    dirty: bool = false
```

Same production, same folder, same trailing rule, same ownership rule.
`lowerConstruct`'s missing-field check becomes a
**missing-required-field** check: a field with a default that is not
written is filled from it, and `writeMissingFields`
(`04_semantics/context.zig:139`) reports only the ones that remain.

Two boundaries that should be stated rather than discovered:

- A struct **every** one of whose fields has a default may be written
  `State()`. That is not confusable with a namespace struct, which is
  refused one check earlier for having no value fields at all
  (`builder.zig:6114-6122`).
- Construction stays **named-only**. It does not gain positional
  arguments in this memo, and *Refused* argues it should not later.

**And the Zig langref's rule comes with it**, as guidance rather than
a check: a default belongs on a field whose omission cannot violate an
invariant. Zig's worked counter-example is a `Threshold { minimum:
f32 = 0.25, maximum: f32 = 0.75 }` where `.{ .maximum = 0.20 }`
silently breaks `maximum >= minimum`. Luce's `State` passes the test —
its eight fields are independent — and `Theme`'s thirteen colours
would too, which is part of why neither wanted defaults before now.

### `self` is not a nameable argument (D7)

`self` is a keyword, not an identifier, and in the method form it is
not an argument at all — `p.length()` writes no receiver. In the
namespace form `Point.length(p)` the receiver is argument zero and
positional; there is no name to write, because `self` names the
*receiver* rather than a parameter a caller supplies.

So the receiver is never named and never defaulted on either
spelling. This needs no check on the method form (there is no slot to
name) and one on the namespace form. A `var self` method is
unaffected: it already refuses the namespace spelling outright
(`builder.zig:4948-4963`), so the only way to call one is `x.f(…)`,
where the receiver is not an argument.

### What a default may be, in one list

Anything `foldConstant` folds, at the parameter's own type: integer
and float literals at the declared width, `true`/`false`, string
literals, other file-scope constants (`pi`, `geo.pi`), fields of
constant structs, arithmetic and comparison over all of those, string
concatenation, `long(x)`/`double(x)` conversions, value-struct
construction — and, new in D9, `none`.

Not: objects (`new list(long)`, `[1, 2, 3]`), calls, or another
parameter. §2 says why for each.

---

## 2. Where a default is evaluated (D2, D9)

### The folder already exists and is most of the implementation

`foldConstant` (`04_semantics/declarations.zig:1107`) folds file-scope
`let` today, with a landing type, lazy evaluation, cross-module
references and cycle detection (`ConstantInfo.state`,
`04_semantics/context.zig:314-322`). Its doc comment is already the
specification for what a default may be:

> Fold a constant expression: literals, other constants (`pi`,
> `geo.pi`, struct-constant fields), arithmetic and comparisons,
> string concatenation, `long`/`double` conversions, and value-struct
> construction. **Objects and calls are not constants.**

A default is that, called with the parameter's declared type as
`wanted`. The result is a `ConstantValue`, stored on the parameter, and
materialised at each call site as the constant register the same
literal would have produced had it been written there. **The lowered
program is byte-identical to the one with the argument written out.**

That is a strong property and worth naming: a default introduces no
code path, no branch, no second entry point, and nothing for the
verifier to check that it was not checking before. It also means the
constants-only choice is not a compromise between Python's fork and
JavaScript's — it is Dart's and Zig's position, which is not on the
fork.

### The mutable-default trap cannot be written here, for three independent reasons

Python's trap is the one thing everybody knows about defaults, and it
deserves working through rather than dismissing, because two of the
three reasons it cannot happen here are ones a careless design could
give up.

1. **Values copy.** A `string` or value-struct default is a value, and
   Luce has no way to observe two uses of one value as the same value.
   This is the reason people cite, and **it is the weakest of the
   three**, because it says nothing about objects.
2. **A default cannot be an object.** `foldConstant` refuses `new`,
   list literals and calls, so no expression produces a `list`, `map`,
   `array` or `builder` and is also a constant. The thing Python's
   trap is *about* — one heap object shared across calls — has no
   spelling.
3. **Even if it did, ownership would ask who owns it, and there is no
   answer.** A `list(long)` default would be an object with no
   binding, created at a declaration and used by every call: it could
   not be scope-owned (whose scope?), given (to whom?), or freed (by
   which caller?). It is not a hard question with a clever answer; it
   is a question with none, and scope ownership is what makes it
   un-askable.

Any one suffices. That they are independent is the point: a future
memo widening defaults to call-time expressions would lose (2) and
keep (1) and (3), and would still be safe. A memo allowing object
defaults would lose (2) and (3) at once and would be inventing a
second lifetime model. **The line to hold is objects, not evaluation
time.**

PEP 671's late-bound defaults exist to fix a trap Luce does not have.
Its three motivating workarounds — a `None` sentinel that breaks when
`None` is legitimate, a module-level sentinel object that clutters
documentation, and the `*args` trick that lies about arity — are all
consequences of the shared-object problem. Luce writes `= none` and
means it (D9).

### Kotlin's callee-side evaluation, and why its advantage is zero here

Kotlin is the most powerful design in the table and the one this memo
turns down most deliberately. It is the only one both late-bound and
dependency-capable:

```kotlin
fun read(b: ByteArray, off: Int = 0, len: Int = b.size) { }
```

`len: Int = b.size` is genuinely useful and Luce will not have it.
Kotlin gets it by evaluating defaults **in the callee**, through a
synthetic `$default` bridge, and two consequences follow that Luce
cannot use:

- **Changing a default is invisible to compiled callers**, because the
  caller never held the value. This is Kotlin's real advantage over
  C#, and it is worth **nothing** here: there are no compiled callers,
  and a changed default recompiles every use site in the same build.
- **The default expression stays an implementation detail.** Also
  worth nothing: std is `@embedFile`d source inside the compiler and a
  sibling module is a file on disk. There is no reader of a Luce
  signature who cannot read its body.

The cost is not zero. Callee-side evaluation means either a second
entry point per defaulted function or a supplied-arguments mask
threaded through the call — in a MIR whose `call` is
`{ function: u32, arguments: []Register }` (`06_mir/defs.zig:248`) and
whose verifier checks argument count against the callee's arity. An
instruction-set change with a `format_version` bump behind it, bought
to purchase two advantages worth nothing. D11 is what this paragraph
defends.

### `none` becomes a constant when something says what it is absent of (D9)

Today `foldConstant` refuses `none` flatly:

```zig
// src/luce/04_semantics/declarations.zig:1134-1136
.none_literal => |literal| {
    return self.constantError(literal.span,
        "none is not a constant; a constant is a value that is there", .{});
},
```

The message is right about the reason and wrong about the scope. The
reason is that `none` has no type of its own and *"the place it is
written into supplies one"* — and at file scope, folding happens
before anything can supply it. **A parameter supplies one.** `start:
long? = none` has a landing type written three tokens to its left.

So `ConstantValue` (`04_semantics/context.zig:301-307`) gains an
`absent` arm, and the refusal becomes conditional on there being no
`wanted`. That is the one genuinely new piece of storage in this memo,
and it is one union member.

It also closes a small existing gap, and the memo would rather take
that deliberately than by accident: **`let x: long? = none` becomes
legal at file scope too.** It is refused today only because the folder
was written before `T?` existed, and with an annotation the landing
type is as available there as on a parameter. Doing it in the same
step is one condition instead of two; *not* doing it would ship a
language where a parameter may default to `none` and a constant may
not, a distinction with nothing behind it.

`none` is also the default a `T?` parameter almost always wants, which
is what makes it worth the union member. Every language with optionals
found the same thing — including Dart, whose specification simply says
*"If no default is explicitly specified for an optional parameter an
implicit default of `null` is provided."* Luce does **not** take that
last step: an omitted default is not an implicit `none`, because a
parameter with no default is required, and `T?` is a type you have to
write.

---

## 3. The four argument paths, and what each one gets (D10)

Stage 4 checks arguments in four places, and they differ in what they
know about a slot. This is the load-bearing table for the
implementation and for `Order`:

| path | resolved by | what it knows about a slot | names | defaults |
|---|---|---|---|---|
| **user functions** — plain, `module.f`, `Struct.f`, and `x.f()` on a struct | `lowerUserCall` (`builder.zig:4922`) | `FunctionDeclInfo.declaration` is the whole `ast.FuncDecl` — **names are already there**, at zero storage cost | **yes** | **yes** |
| **struct construction** | `lowerConstruct` (`builder.zig:6107`) | `StructLayout.fields`, each with a name | **already required** | **yes** |
| **free builtins** | `lowerIntrinsic` (`builder.zig:6322`) | `Builtin{ name, kind, arity, host, pure }` — **an arity and nothing else** | yes, after the table is widened | **yes** |
| **builtin value methods** — `xs.append`, `m.get`, `s.byte_at` | `methodParameters` (`builder.zig:5679`) → `methodTakes` (`:5751`) | `[]const Type`, **computed from the receiver's element type** | no | no |

### User functions cost nothing to give names to

`FunctionDeclInfo` already holds `declaration: *const ast.FuncDecl`
(`04_semantics/context.zig:235`), and `ast.Parameter` already holds
`name` and `name_span`. Every call site in the compiler can already
see every parameter name of the function it is calling. Nothing needs
collecting, storing, or keeping in step — which is exactly the failure
mode the rest of this section is organised around avoiding.

That is true for **all four spellings** of a user call, because they
funnel through one function: a plain `f(x)`, a namespaced
`math.round(x)`, a static `Point.length(p)`, and — through
`lowerReceiverCall` (`builder.zig:5324`) — a method `p.length()`. One
implementation, four surfaces, which is the property `docs/METHODS.md`
bought when it made `p.f()` *mean* `Point.f(p)`.

### Free builtins: the table is the signature

To collect the fifteen `term_style` sites, `Builtin` grows from an
arity to a slot list:

```zig
// what it becomes
pub const Slot = struct { name: []const u8, default: ?Constant = null };
.{ .name = "term_style", .kind = .term_style, .host = true, .parameters = &.{
    .{ .name = "fg" },
    .{ .name = "bg", .default = .{ .long = -1 } },
    .{ .name = "bold", .default = .{ .boolean = false } },
} },
```

`arity` becomes `parameters.len`, and the 39 rows are a mechanical
edit. The principle it rests on, stated so it is a rule rather than an
exception:

> **A builtin is a declaration the compiler writes in a table instead
> of in Luce, and the table is its signature.**

That is already how the tree treats it. `builtins` is `pub` with a
comment saying why — *"Published […] because it is what the language
spells: `tools/grammar.zig` generates the editor grammar from these
tables rather than from a copy of them"* — and the same comment
records the failure that made it one table: *"two lists of the same
thirty-nine names, 3,375 lines apart in this file, with nothing
checking they agreed."* Adding names to the one table is in the
direction that comment points.

**And it should be pinned to the documentation rather than merely
written.** `site/src/coverage.zig` already fails the build when the
compiler has a builtin the reference does not name; extending it to
parameter names is the same check one level down, and it is what stops
the table and the prose drifting the way the old grammar drifted.
Whether every builtin *wants* a name has an easy answer: they all get
one, because `arity` is being replaced and a slot has to be called
something. Only the ones the corpus asks for get a **default**, and
today that is `term_style` and nothing else.

### Builtin value methods get neither, and the reason is the tables

`methodParameters` has no names to give. It computes a `[]const Type`
from the receiver — `list(T)`'s `append` takes `T`, `map(K,V)`'s `get`
takes `(K, V)` — allocating in the arena because *"the element and key
types in one are the receiver's and not compile-time constants"*
(`builder.zig:5736-5740`). Adding names means five method tables
gaining a parallel name list with nothing checking the two agree,
which is **exactly** the failure the `builtins` comment records and
exactly the drift `methodTakes`'s doc comment exists to prevent.

And the corpus does not ask. The one site that looks like it wants a
default is `m.get(key, default)`, and `docs/MISSING.md:161-164` has
already established that a default is the **wrong** answer there:

> a default of `0` is indistinguishable from a stored `0`

What `wordcount.luc` wants is a `V?`-returning `get`, which is an
optionals question and not this memo's. So: not refused, **scoped
out**, with the one site that would reopen it named.

This is the asymmetry the feature ships with, and it is real:
`xs.append(v)` cannot name its argument while `p.push(v)` can. The
defence is that the second is a declaration a reader can open and the
first is not, which is the same line D10 draws everywhere else.

---

## 4. Landing, and the order it forces

This is the section the implementation lives or dies on, and it is why
the design has as few moving parts as it does.

### The landing type is chosen before the argument is lowered

Luce literals have no type until they meet one (`docs/TYPES.md` D3), so
stage 4 pushes the type an argument will land on **before** lowering
it. `lowerOperandsInto` asks `landsOn` per operand, in order
(`builder.zig:1738-1806`), and a call passes
`.places = info.parameter_types` — the whole list, up front, because
*"a call's parameters are written down in front of it"*
(`builder.zig:1719-1720`).

**Named arguments must therefore be resolved to slots before anything
is lowered**, because which slot an argument fills is what says what
type it lands at. Get the order wrong and `f(width = 1)` with a
`double width` reads `1` as a `long` and widens it — *"a different
number"*, as `builder.zig:1728` puts it.

### `lowerConstruct` has been doing exactly this since construction shipped

The algorithm is already written, sixteen hundred lines further down,
with a comment that reads as though it were written for this memo:

```zig
// src/luce/04_semantics/builder.zig:6128-6151
// Which field each argument fills is settled before any of them
// is lowered: it is what says what type the argument lands in,
// and a bare `none` has no type until something says.
```

Name → slot, a `seen[]` array for duplicates, `expected_types[i]` built
by permutation, one `lowerOperandsInto(expressions, .{ .places =
expected_types })`, then `registers[field_index] = …` so evaluation
runs in source order and binding lands by name.

`lowerUserCall`'s change is to do the same: build `places` by
permutation instead of by identity, and index `registers` by parameter
rather than by argument. Everything downstream — `fit`, the ownership
checks, the type diagnostics — already indexes by parameter position.
**Named arguments do not fight the landing machinery; they use the
copy of it that has been running the whole time.**

### The one arm that does not fit, and the wart it exposes

`Landing` has a `.method` arm for the case where parameter types are
*not* known up front: `xs.append(0.1)` takes its type from `xs`, which
is operand zero of the same batch (`builder.zig:1748-1753`). It
answers through `methodParameters(values[0].value_type, name)`.

For a **struct** receiver, `methodParameters` returns null —
`receiver == .string` is false and `heapOf(.strukt)` is null by
construction (`declarations.zig:414-417`). So:

> **A struct method's arguments get no landing type today.**
> `p.f(none)` and `Point.f(p, none)` are documented to *mean the same
> thing* (`docs/METHODS.md`) and do not agree about what literals they
> accept, because the first takes the `.method` arm and the second
> takes `.places`.

A pre-existing wart, not caused by this feature — and this feature
cannot be built cleanly on top of it: `p.f(factor = 2.0)` needs the
permutation, the permutation needs the parameter list, and the
parameter list is what `methodParameters` declines to supply.

The fix is to **make `methodParameters` answer for struct receivers**,
by looking `Struct.name` up in `function_names` and returning
`info.parameter_types[1..]`. A handful of lines; it closes the wart
independently; and it must land **before** the named-argument work
rather than inside it, which is why `Order` step 1 is a bug fix and
not the feature.

The alternative considered and rejected: splitting the batch, lowering
the receiver alone, then the arguments. `lowerOperandsInto`'s doc
comment refuses it in advance —

> Splitting the batch in two would have answered it as well, and would
> have given up the cross-operand analysis that copies a borrowed
> string before a later operand can free it (docs/STRINGS.md). One
> batch, asked as it goes.

— and a correctness property is not worth a permutation's convenience.

### Evaluation order stays source order

Because the batch is lowered in the order the arguments were written
and only the *destination index* is permuted, nothing about evaluation
moves. D5's clause is a property of the implementation rather than a
rule imposed on it.

---

## 5. Ownership: no new rule, one better sentence (D12)

A `give` parameter takes ownership of an object. A default is a folded
constant. An object is never a constant. So **a `give` parameter can
never have a default**, and the refusal is already implied by two
checks that exist:

```zig
// src/luce/04_semantics/declarations.zig:1703-1711
if (parameter.mode == .give and !self.carriesObjects(resolved)) {
    try self.fail("luce.sema.own", parameter.span,
        "give applies to objects (list, map, array, builder, object-carrying structs), not values [OWNERSHIP.md S32]", .{});
```

`give` requires an object-carrying type; `foldConstant` refuses every
expression that produces one. A default on a `give` parameter is
already refused — but by `luce.sema.const` saying something about
constants, which is true and unhelpful. §8 gives it a sentence that
names the actual rule.

The same reasoning covers struct fields: S24 says the binding that
receives a struct owns its object fields, and a defaulted field is one
nobody wrote at the construction site. A default on an object-carrying
field is refused for the identical reason, and the diagnostic cites
S21 and S24 the way `lowerConstruct` already does
(`builder.zig:6172-6177`).

**No situation is added to `docs/OWNERSHIP.md`.** This is the first
memo in the series to add none, and that is the correct outcome rather
than an oversight: it adds no way to create, alias, move or release an
object.

---

## 6. MIR, the serialized module, and the ABI: nothing moves (D11)

MIR's call instruction is one line:

```zig
// src/luce/06_mir/defs.zig:248
pub const Call = struct { function: u32, arguments: []Register };
```

Every slot is filled by stage 4 — a positional argument from where it
was written, a named one from where it was named, a defaulted one from
a constant register emitted at the call site. Stage 6 receives the
same fully-applied call it receives today, from a stage 4 that
resolved more before emitting it.

Therefore, and each of these is worth checking rather than assuming:

- **`06_mir/module.zig`'s `format_version` does not move.** The
  instruction set, the intrinsics and the trap codes are unchanged, so
  the rule that requires a bump is not triggered.
- **`06_mir/verify.zig` needs no case.** It checks argument count
  against the callee's arity; the count is still exactly the arity.
- **`07_optimize` sees nothing new.** A defaulted argument is a
  constant register, and `prune`/`ownership`/`dead` treat it as one.
- **`08_llvm/lower.zig`, `emit.zig` and `abi.zig` are untouched.**
  `abi.version` does not move, `LuceHost` gains no slot, and the
  `generator` identity does not change — so no installed artifact goes
  stale.
- **`libluce_rt` is untouched.** No semantic is added.
- **The interpreter is untouched.** The oracle runs the same MIR, so
  every `specs/` program compares on both arms with no harness change.
- **`luce ir` prints the same thing** for a defaulted call as for the
  call written out — which is a check the implementation should
  actually make. One `06_mir` printer test asserting the two are
  byte-identical is the cheapest possible proof that names died where
  they were supposed to.

**The whole feature is stages 3 and 4.** In a compiler with eight
numbered stages, a published C ABI, a versioned module format and a
differential oracle, that is the entire blast radius, and it is the
strongest argument for building it now rather than after enums.

---

## 7. The risk, and the tripwire

Pike's argument is the one this memo cannot refute, only bound:
defaults *"make it too easy to patch over API design flaws by adding
more arguments."* The mechanism is real and it is not hypothetical —
it is how `AutoFormat` came to take seven optional parameters, and it
is the reason C#'s optional arguments began life as a COM-interop
feature and escaped.

Three things bound it here, and none of them is a guarantee:

- **The trailing rule (D3) means a new parameter can only be
  appended.** There is no way to slip one into the middle, which is
  the shape that makes an argument list unreadable fastest.
- **There is no overloading**, so the "add another overload" pressure
  that turns into "add another default" has nowhere to build.
- **One author, 128 declarations.** Pike's claim is explicitly about
  large codebases.

The tripwire, written down so the claim is falsifiable rather than
reassuring:

> **Shipped Luce's arity histogram is the measurement.** Today, over
> the 128 declarations in `programs/`, `src/luce/std/` and `bench/`:
> **14** at arity 0, **54** at 1, **47** at 2, **8** at 3, **4** at 4,
> **1** at 5, and nothing above. **If the count at arity ≥ 5 reaches
> double figures, or any single declaration passes seven, this memo
> was wrong** and the right answer is a struct, not another default.
> The embedded test corpus is excluded on purpose: a fixture is not
> idiom, and it is where a `pick(first: bool, second: bool)` lives
> legitimately. That is a number a future reader can re-derive in one
> command, which is the only kind of caution worth writing down.

Zig's *Faulty Default Field Values* rule is the second tripwire and
the one a reviewer can apply per-declaration: a default belongs on a
slot whose omission cannot violate an invariant. Both go in
`docs/LANGUAGE.md` as guidance, not as checks — a compiler cannot see
either.

---

## 8. Diagnostics

The wording bar is `builder.zig:4976-4984`, `NAME takes N argument{s},
got M`, and everything below is parallel to it. **No new code.**
`luce.sema.call`, `.method`, `.construct`, `.type`, `.own`, `.struct`
and `.const` say all of it — itself evidence about the size of the
feature, since `docs/RETURNS.md` needed a new code for a smaller
surface.

Two house rules this table obeys. **Count mistakes point at the call;
type and name mistakes point at the argument.** And **every missing
required slot is named at once**, never the first only — the reason is
written down at `04_semantics/context.zig:128-137`:

> Reporting only the first hole made a fourteen-field struct take
> thirteen compile rounds to finish, one field revealed per round.

| written | code | said |
|---|---|---|
| `f(x = 1)` where `f` has no `x` | `luce.sema.call` | `f has no parameter x; did you mean width?` |
| …with nothing close enough | `luce.sema.call` | `f has no parameter x (takes width, height)` |
| `f(1, width = 2)` and `width` is parameter 1 | `luce.sema.call` | `width was given twice, by position and by name` |
| `f(width = 1, width = 2)` | `luce.sema.call` | `width was given twice` |
| `f(width = 1, 2)` | `luce.sema.call` | `a positional argument cannot follow a named one; write height = 2` |
| `f(1)` where `f` takes `(a, b, c = 0)` | `luce.sema.call` | `f is missing b` |
| `f()` where `f` takes `(a, b, c = 0)` | `luce.sema.call` | `f is missing a and b` |
| `f(1, 2, 3, 4)` where `f` takes 3 | `luce.sema.call` | `f takes 3 arguments, got 4` — **exists already**, unchanged |
| `f(1, 2, 3, 4)` where `f` takes `(a, b, c = 0)` | `luce.sema.call` | `f takes 2 arguments and 1 with a default, got 4` |
| `f(width = "x")` | `luce.sema.type` | `width of f is long, got string` — the positional sentence with the name in place of `argument 3 of` |
| `Point.scale(p, self = q)` | `luce.sema.call` | `self is the receiver, not a parameter: write Point.scale(q, …)` |
| `p.scale(factor = 2.0)` on a namespace function | `luce.sema.self` | unchanged — the receiver check fires first |
| `xs.append(v = 1)` | `luce.sema.method` | `append is a builtin method and its arguments are positional` — **replacing** today's bare `method arguments are positional` (`builder.zig:5206`) |
| `len(x = 1)` | — | *deleted* — `len(value = 1)` becomes legal (§3) |
| `term_style(bold = true, 1)` | `luce.sema.call` | the positional-after-named sentence, on a builtin |
| `Point(x = 1)` missing `y` | `luce.sema.construct` | `Point is missing y` — **exists already**, unchanged |
| `Point(1, 2)` | `luce.sema.construct` | `Point is built with named fields: Point(field = ...)` — **exists already**, unchanged |
| `func f(a: long = 0, b: long)` | `luce.sema.call` | `a has a default, so b needs one too — the parameters with defaults come last` |
| `struct S:` with `a: long = 0` before `b: long` | `luce.sema.struct` | the same sentence, about fields |
| `func f(a: long = g())` | `luce.sema.const` | `a default is a constant: g(…) is a call` |
| `func f(a: list(long) = [])` | `luce.sema.const` | `a default is a constant, and an object is not one` |
| `func f(a: long, b: long = a)` | `luce.sema.const` | `a default cannot use a: it is folded before any call is made` |
| `func f(give xs: list(long) = …)` | `luce.sema.own` | `a give parameter takes ownership of an object, and an object is never a default [OWNERSHIP.md S13, S32]` |
| `struct S:` with `items: list(long) = …` | `luce.sema.own` | `S.items keeps its object, and an object is never a default [OWNERSHIP.md S21, S24]` |
| `func f(a: int = 99999999999999999999)` | `luce.sema.const` | the existing range sentence, unchanged (`context.rangeMessage`) |
| `func f(self = …)` | `luce.sema.self` | `self is the receiver and takes no default` |

Twenty-five sentences: **five already exist word for word**, four are
edits to sentences that exist, and one is a deletion. The did-you-mean
machinery is `helpers.Suggestion` (`04_semantics/helpers.zig:283-316`)
used exactly as `failUnknownField` uses it (`builder.zig:673-687`) —
`init`, `offer` each parameter name, `best()`, and the
enumerate-the-surface fallback when nothing is close enough, which is
the house pattern everywhere. Note that `Suggestion`'s tolerance is
`wanted.len / 3`, so a one- or two-character parameter name suggests
nothing at all — deliberate, and a mild argument for naming parameters
in full.

---

## 9. The corpus, rewritten

| site | change | what it deletes |
|---|---|---|
| `src/luce/std/strings.luc:16-46` | `find_from` becomes `find(s, needle, start: long = 0)`; `find` deleted, `contains` retargeted | one declaration, five explicit `0`s, and the `-1`-for-a-bad-`start` disagreement `MISSING.md:172-178` files |
| `programs/editor.luc:212-220, 449-458` | five `State` fields gain defaults | ten lines at the construction site, and an invariant that lived there |
| `programs/editor.luc:328-433` | twelve `term_style` calls lose their tail | eleven `-1`s and eleven `false`s |
| `programs/life.luc:68-74` | three `term_style` calls | two `-1`s and three `false`s |
| `src/luce/std/strings.luc:85, 88` | `fold_case`'s two call sites gain names | nothing; it buys the corpus's worst three-magic-number call |
| `programs/editor.luc:314-354` | `State.status` gains names at its one call site | nothing; it buys four adjacent `long`s |

**And four rows deliberately not in the table** — `lower`/`upper`,
`pad_left`/`pad_right`, `log2`/`log10`, `write`/`append_text` — each
argued above. A survey that counts them over-counts the feature by
half, and the memo would rather say so than be quoted later.

---

## 10. Docs, site, and the grammar

### `docs/`

- **`docs/LANGUAGE.md`** — the function and method material gains
  defaults and names; the evaluation-order clause (D5) beside the
  existing left-to-right sentence; `## File-scope constants` gains
  `none` (D9); and the two tripwires from §7 as guidance.
- **`docs/LANGUAGE.md`'s "Deliberately absent (for now)"
  (`:1112-1124`)** — nothing to remove (defaults were on `MISSING.md`,
  not here); add **positional-only and keyword-only markers** by name,
  so their absence is a decision rather than an omission.
- **`docs/MISSING.md`** — Tier 3 item 7 closed. Item 6's
  `files.append_text` note is **not** closed by this memo and must not
  be marked so; it is the visibility question, which is run two.
- **`docs/STD.md`** — `strings.find_from` disappears; `strings.find`
  grows a parameter.
- **`docs/OWNERSHIP.md`** — nothing (§5).
- **`docs/PIPELINE.md`** — no stage changes status.
- **`docs/README.md`** — one row in the decision-record table.
- **`tools/doccheck.zig`** — `docs/ARGS.md` joins `documents`, and
  this memo's forward-looking fences drop `historical` in the same
  commit (the note at the top of this file). Worth doing with eyes
  open: `docs/VECTOR.md` is **not** in that list either, and nothing
  says so — an unregistered memo is invisible to the guard rather than
  exempted by it, which is a quieter failure than the one `historical`
  was invented to prevent. Registering this one is a chance to notice
  that; fixing `VECTOR.md` is not this memo's business, but naming it
  is.

### `site/`

Two pages carry the claim this memo falsifies, and one of them carries
a second claim that is *already* false:

| page | why |
|---|---|
| `site/content/ref/expressions.md:135-136` | *"Arguments are positional […] There are no default values, no named arguments, and no variadics."* — the first two clauses go, variadics stays |
| `site/content/ref/statements.md:36-37` | *"There are no default values, no named arguments, no variadics, no receivers and no first-class functions."* — **"no receivers" has been wrong since `docs/METHODS.md` shipped** and must be corrected in the same commit, exactly as `docs/RETURNS.md` corrected the status page's stale "15" |
| `site/content/ref/builtins.md` | `term_style`'s signature gains its defaults; every builtin gains its parameter names, and `coverage.zig` is extended to require them (§3) |
| `site/content/ref/types.md` | struct field defaults |
| `site/content/tour/functions.md` | the tutorial half |
| `site/content/status/index.md` | item 7 closes; its copy of the `term_style` count goes with it |

**Write the refusal samples first.** ` ```luce fail ` asserts that
`luce check` rejects a sample, so §8's table can land as executable
site content with step 3 and before the feature is finished — the way
`docs/RETURNS.md` sequenced the same thing.

### The grammar, for highlighters

**`tools/grammar.zig` needs a look and probably no change.** It reads
five word tables out of the compiler, one being `builtins`, and §3
changes that table's *shape*. The generator reads `.name` off each row
and nothing else, so it should compile unchanged — and
`test "the committed grammar is what the generator emits"` is what
catches it if that turns out to be wrong. Let it.

**`site/src/highlight.zig` needs nothing** and **`programs/editor.luc`'s
own highlighter needs nothing**: `=`, `(`, `)` and `,` already fall to
the punctuation arm, and this feature introduces **no new word**. The
guard that could fire —
`test "every name the language spells has a class here"` — cannot, for
that reason.

---

## Order

Sequenced **before** visibility and bitwise/hex (runs two and three)
because it touches only stages 3 and 4 and neither of those does;
**after** the map-upsert work in flight, because that lands in
`objectMethod` and `methodParameters` and step 1 rewrites the latter.
Nothing here collides with catch-binding, the host-surface run, or the
vector layers — those are stage 4, stage 4-and-host, and stage 8, and
this memo reaches only the first with a permutation.

Each step leaves the tree green.

1. **The struct-method landing fix — a bug, not the feature.**
   `methodParameters` answers for a struct receiver by looking
   `Struct.name` up and returning `info.parameter_types[1..]` (§4).
   *Tests:* a `behavior_spec.zig` pair proving `p.f(none)` and
   `Point.f(p, none)` now agree on both arms — the assertion
   `docs/METHODS.md`'s *"the same call"* claim has been making without
   one behind it. **Ship this alone**; it is correct on its own and it
   is the only step that could change the meaning of an existing
   program. *~0.5 day.*

2. **`none` as a constant (D9).** `ConstantValue.absent`; the
   `.none_literal` arm becomes conditional on `wanted`; `let x: long?
   = none` at file scope. *Tests:* `behavior_spec.zig` for the
   constant, `errors_spec.zig` for the still-refused bare `let x =
   none`. *~0.5 day.*

3. **Names on user functions, end to end.** The four refusals deleted
   or reworded; the permutation in `lowerUserCall`, with `places`
   built by it and `registers` indexed by parameter; the duplicate,
   unknown-name and positional-after-named checks; §8's rows. Reaches
   all four spellings at once because they funnel through one
   function. *Tests:* one `behavior_spec.zig` program per legal shape
   on both arms; one `errors_spec.zig` case per refusal; and the
   `06_mir` printer test asserting a named call and a positional call
   emit byte-identical IR (§6). **Rewrite** `errors_spec.zig:2778`,
   `:2804` and `:2820`, which pin the three refusals being deleted.
   *~1.5 days.*

4. **Defaults on user functions.** `ast.Parameter.default`; the
   trailing rule in stage 3; the fold at collection time with the
   parameter type as `wanted`; the fill-in in `lowerUserCall`; §5's
   `give` sentence. *Tests:* the shape of step 3, plus one proving the
   fold happens once — a default of `1 / 0` is a compile error at the
   declaration even if the function is never called. *~1.5 days.*

5. **Defaults on struct fields.** The same clause in the field parser;
   `lowerConstruct`'s missing check becomes missing-required; `S()`
   when every field defaults; the S21/S24 sentence. *Tests:*
   `behavior_spec.zig` for the fill-in, `errors_spec.zig` for the
   object default. *~1 day.*

6. **Names and defaults on free builtins.** `Builtin.arity` becomes
   `parameters`; the 39 rows; `term_style`'s two defaults;
   `coverage.zig` extended to require each parameter name on the
   builtin page; the `len(x = 1)` refusal deleted. *Tests:* an
   `errors_spec.zig` case for a wrong builtin parameter name with its
   did-you-mean; the grammar generator's agreement test is what proves
   the reshape did not disturb it. *~1 day.*

7. **The corpus.** §9's six rows, each in its own commit:
   `strings.find_from` merged (with `docs/STD.md`), `State`'s five
   fields, `fold_case`'s two call sites, `editor.luc`'s twelve
   `term_style` calls, `life.luc`'s three, `State.status`'s names. The
   `editor.luc` rows go last and separately, build-gated by the
   compile test in `src/apps/loom/shell.zig` and by `build.zig`.
   *~1 day.*

8. **Docs and site.** §10's list, including the stale *"no receivers"*
   on `statements.md:37`, which is owed regardless. *~0.5 day.*

**Eight steps, roughly seven and a half days**, of which the first two
are bug fixes worth having whether or not the rest is built and the
last is documentation. Steps 3 and 4 are one feature and should not be
released apart — names without defaults would permit
`term_style(fg = x, bg = -1, bold = false)`, which is *more* noise,
not less. Step 5 is the one §"The Zig question" argues is the point.
Step 6 is what the gap list's own headline needs, and it is the step
to drop first if the run goes long: it deletes the most characters and
changes the least about the language.

---

## Refused, with reasons

**Mandatory argument labels (Swift).** The strongest opinion in the
field, resting on something Luce does not have. Swift's labels are
part of a declaration's *name* (SE-0021) because Swift has
overloading, and the label is what tells `insertSubview(_:at:)` from
its siblings. One function per name means a label could disambiguate
nothing. What is left is a style rule enforced by the compiler — and
one that would refuse every call site in the corpus on the day it
landed, including `min(a, b)`, which Swift's own guidelines say should
have no labels. A convention this memo endorses and does not enforce:
name the boolean.

**Distinct external and internal parameter names** (`func f(from
source: String)`). Two names per parameter earns its cost when the
external one is frozen at a package boundary and the internal one is
free — Swift's situation. Luce's callee is always source the reader
can open, and the compiler names every affected call site when a
parameter is renamed. One name.

**Refusing reordering (Swift SE-0060).** The genuinely close call, and
its reasons are good: it *"complicates the language for little
benefit"*, *"few users know this is possible"*, and a call should look
the same in everyone's code. Two things decide it the other way. The
ecosystem argument does not transfer — there is no third-party Luce
code to look similar to. And Luce would have to refuse reordering in
**struct construction** too, or keep two rules: `Point(y = 2, x = 1)`
compiles today, `lowerConstruct` is written to permit it, and taking
it away would be a new refusal of working code with no corpus demand
behind it. Reopens if a reordered call ever confuses anybody, which is
a thing the corpus can report.

**Kotlin 1.4's relaxed positional-after-named.** *"as long as they
remain in the correct order"* is a rule about agreement between a name
and a position, and it makes "where does the third argument go?"
depend on whether the second one's name matched. Kotlin needed it for
long parameter lists; Luce's longest takes four. Reopens cheaply and
breaks nothing when it does.

**Callee-side defaults (Kotlin's `$default` bridge).** The most
powerful design available, and the one whose two advantages are worth
exactly zero here: invisibility to compiled callers (there are none)
and keeping the default expression an implementation detail (the
implementation is always readable source). The cost is a second entry
point or a supplied-arguments mask in a MIR whose `call` is one line
and whose `format_version` would have to move for it. §2.

**Call-time defaults, and defaults referencing earlier parameters**
(`len: Int = b.size`). Genuinely useful, and refused for now on three
grounds. It makes a signature a program: `f(a: long, b: long =
expensive(a))` has a cost the call site cannot see and the signature
does not disclose. It forces the callee-side question above, because a
default reading `a` must run where `a` exists. And the observable
price is documented: JavaScript had to give the parameter list **its
own scope**, parent to the body and with TDZ rules between them, to
make it sound. The corpus asks for it nowhere — every default the
survey found is a literal. **Scoped out rather than refused**; if it
returns it returns as its own memo, and (1) and (3) of §2's three
reasons still hold.

**Object defaults.** `func f(xs: list(long) = [])`. No owner, no
scope, no answer to who frees it. The one line in the design that must
not move, and the one that makes Python's trap unwritable rather than
merely unlikely (§2).

**Positional-only (`/`) and keyword-only (`*`) markers.** Four
rationales in PEP 570 and one in PEP 3102, none of which applies —
worked through in §"Three reasons". One kind of parameter, and D3 is
what stops a keyword-only parameter arriving by accident anyway.

**Dart's `{named}` section.** The same feature with a syntactic
partition instead of a per-parameter clause, and it buys **required
named** parameters — a slot that must be written and must be named.
Flutter proves that is worth something at scale. It is not free: two
kinds of parameter, two arities, and a second answer to every question
the first kind already answers. And Dart's *reason* for the section
does not transfer — Nystrom's argument is that named parameters form
a **set** whose members are independent while positional parameters
form a **sequence** where omission shifts everything after, so the two
algebras need different brackets. Luce's trailing rule (D3) makes
omission suffix-only, which keeps the sequence a sequence and needs no
second algebra. Luce's answer to "this argument must be named" is a
better name for it.

**Positional struct construction** (`Point(1, 2)`). The symmetric
question to giving calls names, and the answer is no. Construction is
named-only deliberately, and the failure it prevents — transposing two
same-typed fields silently — is the one this memo spends
`State.status` and `fold_case` complaining about in the other
direction. Making construction *more* like a call moves the wrong way.

**Names on builtin value methods** (`xs.append(value = 1)`). Not
refused — **scoped out** (§3). The tables hold types computed from the
receiver and no names, and adding names means five parallel lists with
nothing checking they agree, which is the exact drift the one-table
comment at `builder.zig:67-77` records. `m.get(key, default)` would
reopen it, and `docs/MISSING.md:161-164` has already established that
what it wants is a `V?`-returning `get`, not a default.

**A new diagnostic code.** Seven existing `luce.sema.*` codes say all
twenty-five sentences in §8. A feature that needs no new code is
telling you something about its size, and the right response is to
listen.

---

## Scoped out (not refused — just not now)

- **Defaults that read earlier parameters.** Above; its own memo if
  the corpus ever asks.
- **Names on builtin value methods.** §3; reopens with `map.get`'s
  optional form.
- **Required-named parameters.** Dart's `required`. The mechanism
  would be a parameter with a name and no default that may not be
  filled positionally — which is PEP 3102's `*` under another
  spelling, and D6 refused the marker. Worth revisiting if the
  language ever grows a twelve-parameter surface; today the longest is
  four, and Nystrom's own survey of Flutter found that *"the wide
  majority of named arguments were not required"* even there.
- **Defaults on `main`.** `func main(args: list(string) = …)` is
  meaningless — the runtime supplies the list (OWNERSHIP.md S44) and
  there is no call site. Already refused by the entry checks
  (`declarations.zig:1779-1795`) without a word added.
- **A lint that requires names past N arguments.** Griesemer's
  Pandora's box, and the memo declines to open it. The tripwire in
  §7 is a measurement a person takes, not a rule a compiler
  enforces.

---

## As built

Recorded per step, against `Order` above.  Where the memo and the
code disagreed, the code won and the disagreement is written down
here rather than quietly fixed.

### Step 1 — the struct-method landing fix (`cfb983e`)

As specified, plus one piece the memo's citation implied but did not
say: `lowerOperandsInto` asked only `.places` where a bare `none`
may land, so answering the `.method` landing was not enough — the
`none` path now takes its type from `landsOn` for every batch kind,
which is the same answer for `.places` and the newly-real one for
`.method`.  Two behavior specs pin both halves (`p.pick(none)` and
the binary32/binary64 literal disagreement).

**Superseded in step 3**: `methodParameters` answering
`parameter_types[1..]` positionally cannot serve a *named* argument,
so the struct branch moved out of it into `structMethod`, and the
landing asks `argumentSlot` — the same slot function the checker
asks, so the two cannot disagree.  `methodParameters` is builtin
methods (and the string primitives) again, as its doc comment now
says.

### Step 2 — `none` as a constant (`37232e2`)

As specified: `ConstantValue.absent`, one union member carrying
nothing.  `let x: long = none` gets the lowering walk's own sentence
("long is always there; only long? is ever none") under
`luce.sema.const`, and the bare form's refusal now names the fix.

### Step 3 — names on user functions (`a7662b7`)

As specified, with one resolver (`resolveSlots`) behind all four
spellings and one slot function (`argumentSlot`) behind both it and
the landing.  Deviations and boundaries:

- **The too-few count sentence gave way everywhere.**  §8 shows `f is
  missing b` only for the defaulted rows; as built, *any* under-full
  call names its open slots at once — including builtin and method
  calls, so `min(1)` says `min is missing b`.  Too many is still the
  count sentence.  One pinned spec updated each.
- **The routed string spelling is a fifth surface the memo did not
  enumerate.**  `s.find(needle = "x")` is refused — the batch lands
  those arguments from the receiver, not from `strings.find`'s
  declaration, so a reordered literal would land at the wrong width —
  with a sentence naming the spelling that does take names:
  `write strings.find(…)`.
- The positional-after-named hint writes `write height = …` and stops
  short of echoing the argument's text (§8's `write height = 2`); the
  fix is named, the value is not re-quoted.
- The MIR identity test pins a *same-order* named call byte-identical
  to the positional one.  A reordering call evaluates in written
  order (D5), so its constants are emitted in a different order and
  the dump differs by register numbering — the same program, not the
  same bytes, exactly as D5 promises.

### Step 4 — defaults on user functions (`29fd687`)

As specified: `ast.Parameter.default`, folded at collection with the
parameter type as landing, filled in as a constant register and — for
a struct default — parked as the statement temporary a written
construction would be.  Deviations:

- **The trailing rule lives in stage 4**, not stage 3 as `Order`'s
  step 4 line says: §8 assigns it `luce.sema.call` / `luce.sema.struct`,
  and the sema codes won.  The parser only parses the clause.
- **`func f(self = …)` is `luce.parse.self`**, not §8's
  `luce.sema.self`: the `=` is refused where `self` is parsed, beside
  the annotation refusal it mirrors.
- **`Point.scale(p, self = q)` is `luce.sema.self`**, not §8's
  `luce.sema.call`: naming the receiver slot is a `self` mistake
  wherever it is made, so it answers with the `self` sentence rather
  than the unknown-name one.
- **§8's fold-once example `1 / 0` does not refuse** — `/` widens and
  folds to `inf` (docs/NUMERICS.md §2).  The executable spec pins
  `1 // 0`, which is the refusal the language actually has.
- **A `T?` parameter defaults to `none` and nothing else**:
  `start: long? = 5` is refused (`start is long? and its default is
  int`), because `widensTo` deliberately has no `T <: T?` hop in the
  folder.  The memo's list ends at `none` for optionals, so this is a
  boundary stated rather than a promise broken.
- The default-vs-declaration sentences fold through one
  `fold_subject` field on the Analyzer, saved and restored across
  nested folds so a constant read *from* a default still speaks of
  constants.

### Step 5 — defaults on struct fields (`1619761`)

As specified, plus one mechanism the memo did not spell out: field
defaults fold **lazily with cycle detection** (`ConstantInfo`'s state
machine — a default may construct another struct and lean on its
defaults, and `A.x = B().y` / `B.y = A().x` is caught as "depends on
itself") and are **driven eagerly** after the constants settle, so a
bad default is a compile error whether or not anything constructs the
struct — the promise parameter defaults already keep.  Nothing joined
`types.StructLayout`: defaults live on `StructDeclInfo`, stage 4's
own, which is what keeps the serialized module untouched.

### Step 6 — names and defaults on free builtins (`836220c`)

As specified — `arity` became `parameters`, the 39 rows, term_style's
two defaults and no others — with the resolver generalised over
`CallSlot` so builtins share the user-call machinery outright rather
than growing a copy.  Deviations:

- **The conversions took the name `value`** and folded `ord` takes
  `text` — the fourth refusal site reworded rather than merely
  deleted, since `{s}(value) takes one argument` already spelled the
  name.
- `term_move`'s `col` became `column` on the way into the table, per
  the plain-English naming rule.
- `coverage.zig` reads the table by row indent (a slot must not read
  as a builtin) and holds the `ref/builtins.md` line that shows each
  signature to every parameter name the table declares.

### Step 7 — the corpus (`5a68ec0`)

§9's six rows, in one commit rather than six — the site's strings
pages compile against the fresh toolchain, so the `find_from` merge
and every page that spelled it had to move together.  The merge keeps
`find_from`'s body (a `start` outside the string answers `-1`), which
is the one answer the memo said the pair owed.

### Step 8 — docs and site (this commit)

§10's list, including the stale *"no receivers"* on
`ref/statements.md`.  Two notes against the memo's own preamble:

- **`docs/ARGS.md` was already in `tools/documents.zig` when this run
  began** — registered, with every fence `historical`, when the memo
  landed — so "the last step of `Order` is where it joins" had
  already happened.  What this step did instead is audit the fences:
  the one that now compiles as written (the `struct State` clause
  under D8) lost the tag, and every other keeps it honestly — each is
  an earlier language's spelling or a fragment quoted out of a
  program nobody wrote, which is the exemption's charter.
- **`docs/VECTOR.md` is registered too**, so the quiet-failure worry
  in §10 (an unregistered memo invisible to the guard) had already
  been fixed in the tree; it is named here so the worry has an
  answer on record.

The tripwires of §7 went into `docs/LANGUAGE.md`'s new "Calls"
section as guidance, beside the evaluation-order clause and D9's
`none` under "File-scope constants".
