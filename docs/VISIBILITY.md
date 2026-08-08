# Public until it says `private` — what an import may reach

> **Built.**  This memo opened with every fence tagged `historical`,
> honestly — the feature did not exist.  `Order`'s last step executed
> the promise the tag carried: every single-file fence now compiles or
> is refused under `tools/doccheck.zig` (`luce` and `luce refused`),
> and the tag survives only where it stays the honest one — the
> multi-file demonstrations, which the doc guard cannot load siblings
> for and which run executably as the site's own fences instead
> (`www/luce/content/ref/modules.md` §Visibility, compiled and compared on
> every build), and the quotations of idioms that no longer exist.
> The "As built" section at the bottom is the run's record.

> **The rule.**  A declaration is **public** unless it says `private`
> — written in full, before `func`, before a top-level `let`, before
> `struct`, and on a struct field's own line position.  `public` may
> also be written anywhere `private` may, and where it restates the
> default it is legal and inert: explicitness is flexibility, never an
> error.  Inside a struct — and only there — `private:` and `public:`
> open an **indented block** of members, fields and funcs alike, the
> way every colon in the language opens an indented block.  `import
> geo` still binds the namespace; what it *reaches* is geo's surface
> minus what geo marked private, and touching a marked name is
> `luce.sema.private`, one sentence: `NAME is private to geo`.  The
> rule is the same for a sibling `math.luc` and for `std.math`,
> because std is ordinary Luce and obeys every language rule.  Within
> one file nothing changes: a file is the trust unit, so a private
> method, field, or constant is reachable from anywhere in its own
> module, including from public declarations — visibility gates the
> *reference site's module*, never the call graph.  Construction
> composes with `docs/ARGS.md`: an outside construction site may name
> unmarked fields only, and every private field must carry a default
> or the struct is not constructible outside its module — the factory
> pattern, named in the diagnostic.  Nothing reaches MIR: **visibility
> dies in stage 4**, exactly where names died, and neither the
> serialized module's `format_version` (24) nor the published host ABI
> (9) moves.

`docs/MEMORY.md` records why scope ownership won; `docs/ARGS.md` why
names are optional and defaults are folded constants — this memo is
run two of the ratified roadmap (`docs/MISSING.md:193`: *"named args,
visibility, bitwise/hex"*, then enums, then union) and composes with
run one at exactly one point, §3.  It closes `docs/MISSING.md`'s
Tier 3 **item 10**, quoted in full because it is the whole warrant:

> **No visibility.**  std leaks `is_space_byte` and `fold_case`.
> Cheap, and matters before userland libraries exist.

That sentence is exact and it undersells the find: the leak is
reachable through **two** spellings — `strings.fold_case(s, 65, 90,
32)` and the method sugar `s.fold_case(65, 90, 32)` — and the second
one is the more embarrassing, because it makes an internal helper look
like a blessed string method.  §1 closes both with one check.

---

## The amendment: the default reversed (owner, 2026-08-06)

This memo was ratified once with **private by default** (the original
R1 and R4, recorded verbatim in *Ratified* below), and the migration
was then sized honestly: roughly **a hundred `public` keywords** to
keep the corpus meaning what it already meant, against **six**
declarations that actually wanted hiding.  The owner read that table
and issued a second ruling, quoted verbatim because it is the law this
revision executes:

> *"I kinda hate that there is now a lot of public word everywhere…
> But also keep private and public keywords.  And things are public by
> default but it gives flexibility to be explicit.  So we'll add
> public and private keywords to methods and variables and also have
> block regions inside structs with indentation obviously."*

Three clauses, and the memo takes each at full weight:

1. **Public by default, everywhere** — module top level (functions,
   top-level `let`), struct fields, struct methods.  This **reverses**
   the ratified R1/R4.  The hundred-marker sweep was the evidence: a
   default that makes the language's own standard library unreadable
   with markers — fifteen `public` in `strings.luc` to hide two names
   — is the wrong default *for this language*, whose modules are small
   files written to be imported.  Explicit `private` on the few
   internals is the honest cost allocation: the exception pays, not
   the rule.
2. **Both keywords, per declaration.**  `public` and `private` on
   functions, top-level constants, struct fields, struct methods.
   Writing `public` where it is already the default is legal and inert
   — the earlier Q5 ruling generalizes: explicitness is flexibility,
   never an error.
3. **Block regions inside structs**: `private:` and `public:` open an
   indented block of members, consistent with the language's rule that
   a colon opens an indented block.  Module level has **no** regions —
   per-declaration keywords only.  §5 carries the details.

**The price, stated so it is paid knowingly.**  What private-by-
default bought was protection *by omission*: the next thousand
userland declarations hidden until their authors decided otherwise, so
a published module could not freeze a helper into its API by accident.
That protection is given up.  Item 10's accident class — a userland
`mathx` freezing `sorted` into its surface because nobody said
otherwise — returns as a possibility, mitigated by three things: the
marker is one cheap word, the standing principle below governs every
surface audit, and std itself now demonstrates the discipline (six
markers, §6).  The memo records this as a trade the owner made with
the evidence in hand, not as a free lunch.

**Two dividends, also stated.**  First, the order of landing inverts
for the better: enforcement can ship *before* any corpus edit, because
an unmarked tree is a fully public tree and the checks are vacuously
green — no coordinated sweep, every commit green by construction
(*Order*).  Second, every privacy diagnostic now points at a line the
author wrote: privacy is always an explicit act, so `sorted is private
to mathx` traces to a `private` marker someone typed, never to a
keyword that was merely absent.  A refusal that can cite its own cause
is strictly better than one that cites a default (§8).

Everything else previously ratified **survives with the default
flipped**, restated clause by clause in the decisions table and argued
at the sections named.  The Rng ruling stands unchanged and is now
expressed with explicit markers (§6).

---

## What stands ratified

The current law, after three rounds (the full record is *Ratified* at
the bottom; the original private-by-default R1/R4 are quoted there).

| | stands | round |
|---|---|---|
| **R1** | **Public by default** — functions, top-level `let` constants, struct fields, struct methods.  `private` is the marked case. | third, reversing the first |
| **R2** | **Two keywords, written in full**: `public` and `private`.  Not `pub`, not `priv`. | first, extended by the third |
| **R3** | **Identifier names start with a letter.**  No leading underscore (or any non-letter) on variables or functions — a language-wide naming rule, independent of visibility.  §7. | first, untouched |
| **R4** | **Regions inside structs**: `private:` / `public:` open an indented member block.  Module level takes per-declaration keywords only. | third |

R3 belongs in this memo because it was decided beside visibility and
is now, under the reversal, *demonstrably* independent of it:
languages that lack a visibility keyword grow a sigil instead —
Python's `_name`, Go's capitalization — and the sigil then means
visibility forever.  Luce has a real `private` keyword, so the
underscore has nothing left to encode; it is refused as a naming rule
(sigils grow folklore meanings the compiler does not enforce), the
same refusal in either default.

---

## Decisions

One read, fifteen answers.  Each argued at the section named.  D13 and
D14 are the owner's second ruling; **D15 bundles the design calls this
revision makes — recommended, owner may veto.**

| | decision | where |
|---|---|---|
| **D1** | **The unit of visibility is the module (file), not the struct.**  Go's model, not Java's: private means "this file", and within a file everything sees everything.  One rule for sibling modules and std alike. | §1 |
| **D2** | **"Exists but private" is said as private, never as unknown.**  One new code, `luce.sema.private`, one sentence shape: `NAME is private to MODULE`.  Did-you-mean offers visible names only. | §1, §8 |
| **D3** | **An outside construction site may name unmarked fields only, and every private field must have a default** — otherwise the struct is not constructible outside its module and the diagnostic names the factory pattern.  A private field's default cannot be overridden from outside.  Composes with ARGS.md D8; the interaction is spelled out clause by clause. | §3 |
| **D4** | **A public declaration's surface may name only public types.**  Rust's rule (E0446), not Go's: a public function whose parameter, result, or public field mentions a private struct is refused at the declaration.  Under public-by-default the refusal fires only when an author marks a type `private` while leaving surfaces public that mention it — the common case is quiet, and the refusal lands on the marker's author, who just created the hole. | §2 |
| **D5** | **An opaque type is field privacy and nothing more.**  A struct with private fields is opaque operationally; the zero value keeps the type inhabitable and the memo says so instead of pretending otherwise.  No `opaque` keyword — scoped out.  Opacity is now always an explicit act: a `private:` region over the fields. | §4 |
| **D6** | **Visibility on a member inside a struct follows the same rule**: the module is still the unit.  A private method called from a public one is ordinary; `public` on a member of a private struct is legal and inert. | §5 |
| **D7** | **`main` never needs marking.**  Entry selection is by name in the root module, not by export.  `public` on `main` is inert-legal like any other restated default; **`private` on `main` is refused with its own sentence** — an entry the world cannot start is a contradiction. | §5 |
| **D8** | **Privacy gates names, never values.**  A public constant may fold from private ones; a public function's parameter default may fold from a private constant — the caller materialises the folded value, not the name. | §1, §3 |
| **D9** | **R3 lands in two small checks**: stage 2 refuses an identifier that begins `_` and is longer than the `_` (`luce.lex.name`), everywhere and for every use; stage 3 refuses the bare `_` as a declared name, because the lone `_` stays what it is — the array-shape wildcard, which is not a name. | §7 |
| **D10** | **Two new diagnostic codes and no more**: `luce.sema.private` and `luce.lex.name`.  The first is a genuinely new refusal class; the second is a genuinely new lexical rule.  The region refusals are parse rules under existing `luce.parse.*` codes; everything else reuses sentences that exist. | §8 |
| **D11** | **Nothing below stage 4 moves.**  `format_version` stays 24, `abi.version` stays 9, MIR, the verifier, the optimizer, `libluce_rt` and the interpreter are untouched.  Stage 2 gains two keywords and one refusal; stage 3 carries the markers and dissolves the regions. | §9 |
| **D12** | **std's surface is this memo's roster** (§6): 87 declarations audited, **6 marked `private`** (`strings.is_space_byte`, `strings.fold_case`, `mathx.sorted`, `math.ln2`, `math.ln10`, `Rng.state`), and math gains one declaration — the public-by-default factory `math.rng(seed)`, which replaces the `Rng(state = 42)` idiom at its ten cross-module sites.  Owner's ruling, standing: **no internal member goes public to save an idiom** — the library gets fixed instead. | §6 |
| **D13** | **Both keywords, per declaration, and restating the default is legal and inert.**  One visibility word per declaration; `public` where public is the default asserts, quietly, what is true — Q5 generalized: explicitness is flexibility, never an error. | §5 |
| **D14** | **Regions inside structs only.**  `private:` / `public:` at member position open an indented block of members; module level has no regions, per-declaration keywords only.  C++'s non-indenting label style is refused: it would be the one colon in the language that does not open a block. | §5 |
| **D15** | **Region semantics** *(recommended, owner may veto)*: labels may repeat and appear in any order — they are grouping, not state machines; members outside any region take the default; a per-declaration marker inside a region is refused (one way to say a thing; the block already said it); an empty region is refused the way every empty block is; a region label at module level is refused with a sentence pointing at per-declaration keywords.  Regions die in stage 3 — the parser resolves each label onto its members' markers, and stage 4 never knows a region existed. | §5 |

---

## What the corpus actually says

The shipped `.luc` corpus is 10 programs, 3 std modules and 6
benchmarks.  Its import graph is small enough to state exactly:

- `programs/stats.luc` imports the sibling `programs/mathx.luc` — the
  **one** userland module in the tree.
- `dice`, `editor`, `sort`, `wordcount`, `bench/stats`,
  `bench/strings` import std modules.
- `std/files.luc` imports `std.strings` — std's one internal edge.
- The site carries three compiled multi-module samples
  (`geometry.luc`, `shapes.luc`, and the `mathx` include) and the spec
  suite carries the fixtures in `specs/modules_spec.zig`,
  `compile/test.zig` and `specs/errors_spec.zig`.

### The leak, demonstrated

`strings.luc` declares seventeen functions; `docs/STD.md` documents
fifteen.  The two it omits — `is_space_byte` and `fold_case` — are
omitted *on purpose* (`docs/MISSING.md`'s Tier 5 audit says so:
*"omitted on purpose because they are internals; that they are
**reachable** anyway is the visibility gap, not a documentation
gap"*).  Both compile today from any program, in both spellings:

```luce refused
import std.strings

func main():
    # the qualified spelling
    print(strings.fold_case("MIXED", 65, 90, 32))
    # and the method sugar, which routes to the same declaration
    # (builder.zig's stringsCall) and makes it look blessed
    print("MIXED".fold_case(65, 90, 32))
```

Nothing in the tree calls either from outside — checked, not assumed:
`grep -rn 'fold_case(\|is_space_byte(' programs/ bench/ www/luce/content
src/luce/specs/` finds prose mentions and zero calls.  The leak has no
victims yet, which is precisely `docs/MISSING.md`'s point: *"matters
before userland libraries exist."*  Under public-by-default the leak
closes not by the default but by two explicit markers — which is the
trade the amendment records: the compiler no longer hides internals
for free, and in exchange the other sixty-odd std declarations say
nothing at all.

### The Rng ruling, standing, now in markers

The most-documented struct construction in the language is:

```luce historical
var rng = math.Rng(state = 42)
```

The ratified resolution (owner, 2026-08-06, round two) **stands**:
`state` is internal and the idiom was the bug — an idiom that only
works by touching a struct's internals is evidence of a missing
constructor, not grounds for keeping the field reachable.  Under the
new frame it is expressed with explicit markers: `Rng.state` is marked
`private` (or sits in a `private:` region, §5), math gains the
public-by-default factory `rng(seed)`, the cross-module
`Rng(state = 42)` sites migrate to `math.rng(42)`, and §3's
construction rule applies to `Rng` exactly as to any other struct.
(The memo as first drafted recommended `public state`; the owner
overruled it, and the general principle is recorded and survives the
reversal verbatim: **no internal member goes public to save an
idiom — the library gets fixed instead.**)

Counted at head rather than remembered: the tree writes `Rng(state`
fourteen times across `programs/`, `www/luce/content/` and `specs/`, and
the honest split matters now — **ten** are cross-module
`math.Rng(state = …)` construction sites that must migrate
(`programs/dice.luc:25`; the compiled site fences at
`www/luce/content/std/math.md:162`, `:174` and
`www/luce/content/tour/modules.md:66`; six `std_spec.zig` rows at 245,
246, 249, 251, 258, 268), **two** are spec fixtures whose `Rng` is a
struct *declared in the same program* (`behavior_spec.zig:2232`,
`errors_spec.zig:1035` — same-module construction, never gated, and
their unmarked `state` is simply public), and **two** are prose lines
on the site's math page (`:149`, `:154`) that move as documentation.
`docs/RETURNS.md`'s `Rng` fences declare their own struct too and are
untouched.

### The evidence that turned the default

This table was drafted under private-by-default as "the honest size of
the sweep", and it is what the owner read before the second ruling.
It survives as the amendment's evidence:

| where | `public` markers the old default demanded | actually internal |
|---|---:|---:|
| `src/luce/std/` (strings 15, math 30 incl. the new `rng` factory, files 10) | **55** | 5 |
| `programs/mathx.luc` | **4** | 1 |
| every other `programs/` and `bench/` file | **0** | — |
| site samples (`geometry.luc` 5, `shapes.luc` 6) | **11** | 0 |
| spec and driver fixtures (`modules_spec`, `compile/test.zig`, `errors_spec`) | **~30** | 0 |

Roughly **a hundred `public` keywords to hide six names** — a ratio of
sixteen to one against the default, paid in the reader's face on every
declaration of the standard library.  A default earns its keep when
marking the exception is cheaper than marking the rule; this tree's
exceptions are the six, and the reversal makes exactly them pay.  The
counter-weight — that the hundred markers were a one-time cost and the
private default protected every *future* module — is real, was argued,
and lost: the owner priced permanent noise on every public surface
against occasional discipline on rare internals, and chose the
discipline.  §10 carries the recomputed migration: six markers, one
factory, ten call sites.

---

## The precedents, and which one Luce is

Two axes decide everything: **what the unit of privacy is**, and
**which way the default points**.

| | unit | default | spelling | levels |
|---|---|---|---|---|
| **Go** | package | private | **capitalization** — `Fold` exports, `fold` does not | 2 |
| **Rust** | module | private | `pub`, plus `pub(crate)`, `pub(super)`, `pub(in path)` | many |
| **Zig** | file (a file is a struct) | private | `pub` per declaration | 2 |
| **Python** | none | public | `_name` convention; `__all__` list; enforced by nobody | 0 |
| **Java** | class | package-private | `public` / `protected` / `private` | 4 |
| **C#** | class | private | six modifiers, `internal` among them | 6 |
| **Swift** | file/module | `internal` | five keywords from `open` to `private` | 5 |
| **OCaml / ML** | module | public, until a signature (`.mli`) restricts | a second file | 2 |
| **Luce** | **file** | **public** | **`public` / `private`, in full** | **2** |

**The reversal is a ruling against the majority precedent, and the
memo says so plainly.**  Go, Rust and Zig — the three languages this
tree otherwise leans on — are all private-by-default, and the memo's
first ratification sided with them.  What their default amortises is a
boundary Luce does not have at their scale: a Go package or a Rust
crate wraps a large internal surface where hiding-by-omission earns
its keep daily.  Luce's unit is a small file written to be imported,
its standard library is sixty-odd declarations of which six are
internal, and the corpus number — sixteen markers of noise per name
actually hidden — is the measured cost of importing their default into
this language.  Luce ends up with **OCaml's default and Zig's
mechanism**: public until restricted, restricted by a per-declaration
word the compiler enforces, with none of the `.mli` second-file
apparatus.

**Go remains the closest relative and the strongest precedent for
D1.**  Its unit is the package, everything inside sees everything, and
privacy means "mine, not yours" between compilation units — no
class-privacy, no friend, no ladder.  Twenty years of Go code has not
produced a movement for finer grain.  What Luce declines from Go is
the *spelling*: capitalization-as-export welds two unrelated decisions
together (what a thing is called, and who may see it), and Luce
already spends capitalization by convention on types.  A keyword says
the visible thing visibly.

**Rust remains the precedent for D4**, whichever way the default
points.  Its `private_in_public` refusal (E0446, now the
`private_interfaces` lint at deny) is the recorded lesson that a
public surface naming private types is a hole, not a flexibility —
callers can be handed a value they cannot name, write down, or
construct.  Go permits returning unexported types and its own `golint`
has flagged it since 2013; Luce takes Rust's side while the corpus
contains zero instances to break.  What Luce declines from Rust is the
ladder: `pub(crate)`, `pub(super)` and `pub(in path)` answer questions
a two-level tree with no packages cannot ask.  One bit.

**Python is the counter-example that sharpened under the reversal.**
Python is public-by-default *and enforces nothing*: `_name` means
private except when it doesn't, `from module import *` respects it
except when `__all__` says otherwise, and PEP 8 has to explain three
underscore prefixes.  Luce now shares Python's default and shares
nothing else: `private` is a compiler-checked word, the underscore
sigil is refused outright (R3), and there is no convention left for
folklore to grow on.  The lesson Python teaches is not "public
defaults rot" — it is "unenforced privacy rots", and Luce's is
enforced.

**Java is the counter-example D7 answers.**  `public static void
main` — a visibility keyword required on a function nothing imports,
taught to every beginner as an incantation.  docs/METHODS.md already
declined Java's mandatory `String[] args` for the entry; this memo
declines the mandatory `public` for the same reason — and under
public-by-default the temptation evaporates: `main` is public like
everything else, an inert `public` may say so, and only `private` on
it is refused, because an entry the world cannot start is a
contradiction (§5).

**C++ is the counter-example D14 answers.**  Its `private:` /
`public:` access labels are stateful, non-indenting line markers —
everything after the label changes meaning until the next label, with
no block structure saying where the region ends.  Luce takes the
region idea and refuses the spelling: a Luce colon opens an indented
block, every time, and the region's extent is its indentation, visible
at a glance and impossible to misread across a long struct.

**Swift's five levels and C#'s six are the ladder refused.**  Every
level past two exists to serve a boundary Luce does not have —
subclassing (`open`/`protected`), assemblies (`internal`), nested
types.  A language with no inheritance, no packages and no separate
compilation gets to keep the bit a bit.

**OCaml's signatures are the road not taken for a structural reason**
even as Luce lands on its default: an `.mli` is a second file that
restates the first's surface — power Luce has no use for (no abstract
types over multiple implementations) at a price docs/ARGS.md already
declined once in another form: two lists of the same names with
nothing checking they agree.  The per-declaration keyword keeps the
declaration and its visibility in one place.

---

## 1. The unit is the module, and what the compiler says (D1, D2, D8)

### What private means

A declaration marked `private` is reachable from its own file and
nowhere else.  `import geo` binds the namespace exactly as today
(`docs/LANGUAGE.md` §Modules); every *reference* through it — a call,
a constant read, a type annotation, a construction, a method on an
imported struct's value, the string-method sugar — checks one bit at
the site where the name resolves.  The check compares the
declaration's module against the referencing module, both of which
stage 4 already holds (`FunctionDeclInfo.module`,
`ConstantInfo.module`, `StructDeclInfo.module` —
`04_semantics/context.zig`), so no new bookkeeping travels anywhere.
An unmarked declaration carries the default and no check ever fires on
it — the fast path is the common case, by construction.

Within one file, the bit is never consulted.  That is D1's content and
it is worth defending rather than assuming: the alternative —
struct-private fields, Java-style — would make a file's own author
write accessors for a struct three lines up.  Luce's file is already
the trust unit everywhere else: one scope, no shadowing, and the
CODING_GUIDE's own rule that a split forcing `pub` for a sibling is a
wrong split.  A file that cannot trust itself is not a file, it is two
files, and Luce has a spelling for that.

### The same rule for std, demonstrated three ways

```luce historical
# 1 — a sibling module; mathx.luc marks `sorted` private (§6)
import mathx

func main():
    print(string(mathx.median([3.0, 1.0, 2.0])))   # unmarked: compiles
    let s = mathx.sorted([3.0, 1.0, 2.0])          # refused:
    # mathx.luc:22: error: sorted is private to mathx [luce.sema.private]
```

```luce refused
# 2 — the standard library, identical rule, identical sentence
import std.strings

func main():
    print(strings.lower("MIXED"))                  # compiles
    print(strings.fold_case("MIXED", 65, 90, 32))  # refused:
    # error: fold_case is private to strings [luce.sema.private]
```

```luce refused
# 3 — the method sugar routes to the same declaration and the same
# refusal, so the leak has no second door
import std.strings

func main():
    print("MIXED".fold_case(65, 90, 32))
    # error: fold_case is private to strings [luce.sema.private]
```

There is no std-specific wording.  A sibling's author can delete the
marker; std's user cannot, and the sentence does not pretend otherwise
by advising an edit — it states the fact, and because privacy is now
always an author's explicit act, the fact has an address: the refusal
traces to the `private` marker in the declaring file, a line someone
wrote.  The did-you-mean machinery (visible names only, D2) supplies
the fix when one is near: `fold_case is private to strings` on a call
the author meant as `lower` gets no suggestion, because the names are
far apart; `strings.trimm` still suggests `trim`, because suggestion
and visibility filter compose.

### Private is not unknown

The refusal fires **after** existence is established, which is what a
new code buys (D10): `geo.helperr` where `helper` is private answers
`unknown function helperr` with visible-only suggestions, and
`geo.helper` answers `helper is private to geo`.  Saying "unknown"
about a name that exists would send the author hunting for a typo that
is not there; every language that made privacy look like absence
(C++'s pre-C++11 overload resolution, early Rust) reversed it.

### Constants, and the folding rule (D8)

A public constant may be *built from* private ones, because folding
happens inside the declaring module and what crosses the boundary is
the value:

```luce historical
# geo.luc
private let seed = 41              # marked: geo's own business
let answer = seed + 1              # public by default; folds to 42 in geo

# main.luc
import geo
func main():
    print(string(geo.answer))      # 42 — the value crossed, not the name
    print(string(geo.seed))        # seed is private to geo
```

The same clause serves ARGS.md's defaults: `func pad(s: string,
fill: string = default_fill)` with a `private let default_fill` is
legal — the caller materialises the folded constant, never the name.
This needs no code: `foldConstant` folds in the declaring module's
context (`declarations.zig`), and the visibility check guards the
*reference paths* (the `geo.pi` arm at `declarations.zig:1190`,
`lowerField`'s namespace arm), not the fold result.

### Where the checks land, named

Five resolution sites in stage 4, one check each, and no sixth:

| reference | site | today |
|---|---|---|
| `geo.helper(…)`, `geo.Struct.f(…)`, `x.f()` on an imported struct | the `function_names.get` funnel — `lowerUserCall` and `structMethod` (`builder.zig:5362`, `:5826`) | resolves by qualified name |
| `geo.pi` in an expression | `lowerField`'s namespace arm (`builder.zig:5634`) | resolves or `failNamespaceMember` |
| `geo.pi` in a constant initializer | `foldConstant`'s field arm (`declarations.zig:1190`) | resolves or `has no constant` |
| `p: geo.Point` in an annotation | `resolveBase`'s dotted arm (`declarations.zig:355`) | resolves or `failUnknownType` |
| `s.split(…)` sugar → `strings.split` | `stringsCall` (`builder.zig:6363`) | routes by name |

Construction and field access check the *field* bits and are §3's.
The f-string spec's synthesized `strings.format_float` call goes
through the first row like any other cross-module call; under
public-by-default `format_float` is public because nothing marks it,
and the positive spec that pins the synthesized call still compiling
survives as the guard against anyone marking it later (§8).

---

## 2. A public surface names public types (D4)

```luce refused
# geo.luc
private struct Inner:              # the author hid the type…
    n: long

func read() -> Inner:              # …but left the function public.  Refused:
    return Inner(n = 1)
# error: read is public and answers Inner, which is marked private in
# geo; mark read private or remove the mark on Inner [luce.sema.private]
```

Refused for parameters, results, and the types of **public** fields
and public constants.  A *private* field's type is not part of the
public surface and may be private — that is what lets an opaque struct
(§4) hide an implementation struct entirely.

Under public-by-default this refusal has a property worth naming: it
can only ever fire on a line's *author*.  Nothing is private until
someone writes `private`, so a public surface naming a private type
means one person marked the type and forgot the surfaces that mention
it — and the diagnostic lands at the moment of the marking, naming
both edits that would restore honesty.  The common case — nobody marks
anything — is quiet by construction.

The alternative is Go's: allow it, and the importer holds a value of a
type it cannot write down — cannot annotate, cannot put in a struct
field, cannot declare a `var` of.  In Go this produces working-but-
unnameable API that `golint` has complained about for a decade.  In
Luce it would be worse, because Luce leans on annotations in places Go
infers (`var x: geo.Inner`, empty list literals, `T?` declarations).
Refusing at the declaration puts the error on the author who can fix
it, once, instead of on every caller who cannot.

The check lands in stage 4's collection passes (`collectFunctions`,
`collectStructs`, `collectConstants` in `declarations.zig`), where
every signature type is already resolved to a `Type` whose struct
index reaches its `StructDeclInfo` — one walk over what is already in
hand.

---

## 3. Construction with private fields (D3)

The flipped default meets ARGS.md's construction clause here, and the
interaction has to be stated precisely because both features are
load-bearing at the same site — `lowerConstruct` (`builder.zig:6107`),
which already resolves names to fields, fills defaults, and reports
every missing field at once.

**The rule, in three clauses:**

1. **An outside construction site may name unmarked fields only.**
   Naming a private field — even one with a default — is refused: a
   default is the module's chosen value for a slot the module kept,
   and overriding it from outside is exactly the access privacy
   removed.
2. **A private field with a default is filled from it, silently** —
   the same fill ARGS.md D8 built, untouched.  Defaults compose with
   privacy rather than fighting it: the module decides the value, the
   outsider does not mention the slot.
3. **A private field with no default makes the struct not
   constructible outside its module**, and the diagnostic names the
   pattern that is: a public namespace function.  Inside the module,
   nothing changes.

```luce historical
# session.luc
struct Session:
    name: string                       # public by default
    private token: long = 0            # marked, defaulted: outsiders never say it
    private id: long                   # marked, required: outsiders cannot build one

func open(name: string) -> Session:
    return Session(name = name, id = next_id())

# main.luc
import session
func main():
    let s = session.open("dy")                  # the factory: compiles
    let t = session.Session(name = "dy")        # refused:
    # error: Session cannot be constructed here: id is marked private
    # in session and has no default; construction belongs to a public
    # function of session [luce.sema.private]
    let u = session.Session(name = "x", token = 7)   # refused:
    # error: token of Session is private to session [luce.sema.private]
```

A struct with **no** marked fields constructs outside exactly as today
(`geometry.Point(x = 0.0, y = 0.0)` — the site's own sample, which
under the new default keeps compiling *without an edit*).  A struct
every one of whose private fields has a default constructs outside
with its unmarked fields only — which includes the all-defaulted
`Options()` ARGS.md ratified.

**Why not the blunter rule** — "construction is module-private as soon
as any field is marked"?  It is simpler to state and it forbids the
most useful shape this feature has: the half-open record, public knobs
in front, private machinery behind, `Session` above.  Zig builds
exactly this compose (private fields with defaults + public fields)
and it is the idiom its `std` options structs live on.  The blunter
rule also forces a factory for structs that need none, and a factory
that merely restates every public field is ceremony.

**Why not the looser rule** — outsiders may name a private field when
it has a default?  Because then a default changes a field's
*visibility*, and two unrelated clauses (`= 0` and `private`) become
one entangled one.  ARGS.md fought precisely this class of
entanglement in Kotlin's non-trailing defaults; the answer is the
same: each clause means one thing.

**Zero values are unchanged and stated out loud**: `var s:
session.Session` still declares the zeroed struct (docs/LANGUAGE.md
§Zero values), private fields and all.  Privacy gates *saying* a
field, not the existence of the value — the same honesty §4 owes
about opacity.  A module whose invariant cannot survive the zero
value documents its factory; that was true before this memo and stays
true, and Go lives the same way.

The `Rng` resolution (§6) is the corpus applying this section as
ratified: `state` carries the marker, and the diagnostic's factory
pattern is not a consolation prize but the design — `math.rng(seed)`
is the constructor the module always owed its callers, and the
`Rng(state = 42)` idiom was ten cross-module sites writing through a
wall that had not been built yet.  The overruled alternative —
`public state` — is recorded in *Refused*.

---

## 4. The opaque boundary (D5)

Can a module export a struct whose shape outsiders cannot see?
**Yes, and it is not a new mechanism** — it is D1 + D3 composing, and
under the new frame opacity is always an explicit act, which the
region spelling (§5) says in one label:

```luce historical
# handle.luc
struct Handle:
    private:
        slot: long                 # no default: not constructible outside
        generation: long

func fresh() -> Handle:
    return Handle(slot = next_slot(), generation = 1)

func alive(h: Handle) -> bool:
    return generation_at(h.slot) == h.generation
```

An importer can hold a `Handle`, copy it (a struct is a value; copying
is not field access), pass it back to `handle.alive`, store it in its
own structs, put it in a `list(handle.Handle)` — and cannot read
`slot`, construct one, or write a field.  Methods and namespace
functions mean across the boundary exactly what they mean inside it:
`h.close()` is `handle.Handle.close(h)` (docs/METHODS.md), the
receiver is an ordinary first argument, and the *method's own body*
runs in its declaring module, where the fields are visible.  That is
the whole story, and it needs no `opaque` keyword, no boxing, and no
second kind of struct.

**What opacity is not, stated so nobody discovers it**: it is not
layout hiding (the struct is a value; its size is its size, copied on
assignment as ever) and it is not invariant enforcement (the zero
value exists, §3).  It is *name* hiding — which, in a language with no
reflection, no field iteration, and `string(x)` refusing structs, is
everything an importer can observe.

**Deferred, by name**: a sealed or invariant-bearing type whose zero
value is unreachable (`var h: handle.Handle` refused) — that is a
genuinely new rule about declarations, it interacts with array
zeroing and struct zeroing, and no corpus code wants it yet.  If it
arrives it arrives as its own memo, and enums/unions (runs four and
five) may reshape the question first.

---

## 5. Inside a struct: members, regions, and the entry (D6, D7, D13–D15)

### Members

A marker on a function inside a struct — method or namespace function
alike — means what it means at file scope: `private` withholds it from
imports.  The module is still the unit, so:

- **A private method called from a public one is ordinary code.**
  `Rng.real` calling a `private` `Rng.next` would be fine were `next`
  marked; visibility is checked where a *program refers to a name*,
  not along the call graph.  The same already holds for functions —
  public `strings.lower` calls private `fold_case` — and a struct
  earns no second rule.
- **`public` on a member of a private struct is legal and inert.**  D4
  keeps the struct out of every public signature, so no importer can
  ever hold a value to call it on; the `public` simply never fires.
  Refusing it would add a rule whose only effect is to make
  *promoting* the struct later a two-step edit.
- **A restated default is legal and inert everywhere** (D13): `public
  func` where public is the default asserts, quietly, what is true.
  Q5's ruling generalizes — a file does not know whether it will be
  imported, an author may want the surface spelled out, and a keyword
  that is an error in one place and meaningful in another would make
  every refactor a sweep.  Exactly **one** visibility word per
  declaration; a second is refused at parse.
- **Fields follow §3**; there is no per-field story beyond it.

### Regions (D14, and the D15 calls — recommended, owner may veto)

Inside a struct body, at member position, `private:` or `public:`
opens an **indented block** of members — fields and funcs alike — and
every member in the block takes the label's visibility:

```luce historical
struct Rng:
    private:
        state: long

    func next(var self) -> long:       # back at member level: public by default
        self.state = self.state * 48271 % 2147483647
        return self.state

    func real(var self) -> double:
        return double(self.next()) / 2147483647.0
```

The label is a colon, so it opens an indented block — the language has
exactly one thing a colon does, and regions are not the exception.
C++'s access labels are the refused alternative: a stateful,
non-indenting `private:` changes the meaning of everything after it
until the next label, with nothing visible saying where the region
ends; in a Luce struct the region's extent *is* its indentation.

The D15 calls, each with its reason:

- **Labels may repeat and appear in any order** — `private:` …
  members … `private:` again is legal, as is `public:` between them.
  Regions are grouping, not state machines: each region's visibility
  is its own label's, members outside any region take the default,
  and no region changes what follows it.  An author groups members by
  topic first and visibility second, and the grammar should not force
  the two orderings to agree.
- **A per-declaration marker inside a region is refused** — `private
  state: long` inside a `private:` block, or `public` inside a
  `public:` one, and the mixed cases too: one way to say a thing, and
  the block already said it.  The refusal is a **parse** rule, the
  honest stage: the parser is what holds the region context, no name
  needs resolving to see the redundancy, and stage 4 never sees
  regions at all (below).  `public func` inside a `private:` region is
  refused the same way rather than resolved — a member half in and
  half out of a block is a contradiction to report, not a precedence
  to invent.
- **An empty region is refused the way every empty block is** — the
  parser already demands an indented block after every colon, and a
  region earns no exemption.
- **A region label at module level is refused** with a sentence
  pointing at per-declaration keywords (§8).  At file scope the
  declarations are long and few and a marker sits naturally on each;
  a file-spanning indented region would put half a module one level
  deep to say one word.
- **Regions die in stage 3.**  The parser resolves each label onto its
  members' markers — `ast` carries per-member visibility (`none` /
  `public` / `private`, three states so inert explicitness is
  representable) and stage 4 never knows a region existed.  No
  downstream stage gains a concept.

### The entry

`main` never needs marking (D7).  The entry is selected by *name* in
the root module (`function_names.get("main")`,
`declarations.zig:190`) and called by the runtime through the ABI —
there is no import edge to gate.  Under public-by-default the two
halves are asymmetric and each gets its own answer:

- **`public` on `main` is inert-legal**, like any restated default.
- **`private` on `main` is refused**, with its own sentence (§8): an
  entry the world cannot start is a contradiction — the one caller
  `main` exists for is the runtime, which no marker can gate, so the
  marker could only assert something false.

Java's `public static void main` remains the counter-precedent — a
visibility keyword as incantation — and the reversal dissolves it
completely: `main` is public because everything is, and nothing need
be written.  An imported module's `main` is just a function named
`main` (`geo.main` is never the entry) and follows the ordinary rules,
marker and all.

### Top-level `var`

There is no top-level `var` (docs/LANGUAGE.md: *"Top-level `var` does
not exist"*), so there is nothing for a marker to mean at file scope,
and the refusal that exists today already answers it — the prefix adds
no arm.  If mutable file scope ever arrives (docs/V2.md's open
question), it arrives into a language whose visibility story is one
word per declaration, and decides its own default then.

### Locals

`public` or `private` on a local `let`/`var`, a parameter, or any
statement is a parse error naming the rule: `visibility applies to
file-scope declarations and struct members`.  Visibility is about the
module boundary; there is no smaller boundary for it to mean anything
at.

---

## 6. std's own surface, audited (D12)

Every declaration in `src/luce/std/*.luc` and `programs/mathx.luc`,
audited against docs/STD.md, the site's std pages, and every call in
the corpus.  **std obeys the same rule it imposes** — `files.luc`
reaches `strings.split`/`join` through the same public surface any
program does.  Under public-by-default the roster inverts its
expression and keeps its content: the six internals carry markers, and
the rest say nothing.

### strings — 17 declarations: 2 marked `private`

| public (unmarked) | marked `private` |
|---|---|
| `find`, `contains`, `starts_with`, `ends_with`, `count`, `trim`, `lower`, `upper`, `replace`, `repeat`, `split`, `join`, `pad_left`, `pad_right`, `format_float` | `is_space_byte`, `fold_case` |

The two markers are the memo's warrant (item 10).  `format_float`
stays public twice over: it is documented, and the f-string `{x:.2f}`
spec lowers to a compiler-synthesized cross-module call to it — a spec
pins that the synthesized call still compiles (§8), which is what
stops anyone marking it in a future audit.  `split` and `join` are
additionally load-bearing for `files.luc`'s own
`read_lines`/`write_lines`.

### math — 33 declarations after the fix: 3 marked `private`

| kind | names |
|---|---|
| constants (3 public, 2 marked) | `pi`, `tau`, `e` unmarked; **`ln2`, `ln10` marked `private`** — internals of `log2`/`log10` |
| scalar functions (10) | `round`, `exp`, `ln`, `log2`, `log10`, `pow`, `ipow`, `sin`, `cos`, `tan` |
| vector functions (12) | `sum`, `mean`, `vmin`, `vmax`, `minmax`, `dot`, `norm`, `variance`, `stddev`, `fill`, `scale`, `axpy` |
| the generator (6) | `struct Rng` unmarked, **field `state` marked `private`** (the struct's one marker — the per-declaration word, not a region, for a single field), methods `next`, `real`, `in_range` unmarked, and the new factory `func rng(seed: long) -> Rng` — public because nothing marks it |

The calls, as ratified in round two and restated in markers:

- **`ln2` and `ln10` are marked `private`.**  The memo drafted them
  public because `www/luce/content/std/math.md:13` documents all five
  constants; the owner overruled: they are internals of
  `log2`/`log10`, and a documented internal is a documentation bug,
  not a public surface.  The site page moves in the same run and stops
  documenting them.
- **`Rng.next` stays public** — unmarked.  Documented on three site
  pages, exercised by `std_spec.zig:248` from a program's `main`, and
  it is the honest raw face the two friendly ones (`real`,
  `in_range`) wrap.  This is API, not internals: a caller who wants
  the raw stream is doing something the module supports.
- **`Rng.state` is marked `private`, and math gains `rng(seed)`.**
  The taught idiom `math.Rng(state = 42)` reached through the type's
  wall, and the owner's ruling is that this evidences a missing
  constructor, not a field that wants exposure: *no internal member
  goes public to save an idiom.*  The factory is four lines in
  `math.luc` (which, being the module itself, may still write
  `Rng(state = seed)`); the ten cross-module call sites become
  `math.rng(42)`.

### files — 10 declarations: no markers

`exists`, `read`, `write`, `read_lines`, `write_lines`,
`append_text`, `append_lines`, `delete`, `rename`, `list`.  No
internals; the module is a thin layer, audits as one, and under the
new default is **zero-edit**.  (The `append_text` reserved-name wart
is item 6's and is **not** closed by this memo: `append` is reserved
by the method table, and visibility does not unreserve names.)

### mathx (userland, `programs/`) — 5 declarations: 1 marked `private`

`mean`, `extremes`, `median`, `deviation` unmarked (stats.luc calls
them); **`sorted` marked `private`** — it is called only by `median`,
and it becomes the tree's first genuinely hidden userland helper: the
showcase, in the flagship multi-module program, of what the marker is
for.  It is also the honest demonstration of the amendment's price:
under the old default `sorted` would have been hidden by silence;
under the new one its author had to say so, and did.

---

## 7. Names start with a letter (R3, D9)

### What the rule touches

The lexer accepts `_` as a word start today
(`02_lex/lexer.zig:1207-1210`), and the lone `_` doubles as the
array-shape wildcard — recognised *contextually* by the type parser
(`03_parse/grammar.zig:700`: an identifier token whose text is `_`).
Nothing else in the language wants a leading underscore, and the
corpus proves it: **zero** identifiers beginning `_` in `programs/`,
`bench/`, `std/`, the site's samples, and the spec fixtures — checked
with `grep -roE '\b_[a-zA-Z][a-zA-Z0-9_]*'` over each.  The rule
lands on a green field.

**The rule is a naming rule, not a privacy convention, and the
reversal makes that unmistakable.**  Under private-by-default a reader
could half-believe the underscore ban existed to protect the default;
under public-by-default there is nothing left for a sigil to encode —
the language has a real `private` keyword, so Python's `_name`
convention is refused for the reason it was always refused: sigils
grow folklore meanings the compiler does not enforce, and a spelling
should carry less hidden meaning, not more.  R3 stands unchanged
through the amendment, which is itself evidence the two decisions were
always independent.

### Where it lands (D9)

Two checks, each where it belongs:

1. **Stage 2 refuses an identifier that begins `_` and is longer than
   the `_`** — everywhere, uses and declarations alike, under a new
   `luce.lex.name`: `a name starts with a letter: _total is not a
   name`.  This is the lexical layer doing what it already does for
   non-ASCII names, `//` comments and hex literals: refusing a
   spelling by name, once, so no later stage needs a rule.  The
   lexer is marked *Locked* in docs/PIPELINE.md; this is a ratified
   language change amending it, one refusal beside the per-character
   diagnostics it resembles, and the fuzz invariants (no byte
   silently dropped) hold — a refused word is a reported word.
   Interior and trailing underscores are untouched: `word_end`,
   `append_text` and `fold_case` are the house style.
2. **Stage 3 refuses the bare `_` as a declared name** — `let _ =
   f()`, `func _()`, a parameter or field `_` — with the sentence
   that teaches the one place `_` is legal: `_ is the array-shape
   wildcard, not a name (array(long, _)); a binding needs a name`.
   The wildcard in type-argument position is untouched, and
   docs/RETURNS.md's refusal of `_` as a discard binding gains the
   enforcement it described: *"a name costs nothing and tells the
   next reader what was ignored."*

The alternative — enforcing only at declaration sites and leaving
`_x` lexable — would let a *use* of `_x` produce `unknown name _x`, a
correct but rule-blind message, and would need the same check
repeated at every declaring production.  One lexical refusal is the
smaller and stricter footprint.

Non-letter starts other than `_` need no new rule: a digit start is
already `luce.lex.number`'s *"a number cannot be followed by
letters"*, and everything else was never a word.

---

## 8. Diagnostics (D2, D10)

Two new codes, each carrying a genuinely new fact:
**`luce.sema.private`** (the name exists and is withheld — no
existing code says that without lying about either existence or
imports) and **`luce.lex.name`** (a spelling rule about words, not
characters or numbers).  The region refusals are parse rules under
existing `luce.parse.*` codes.  Everything else is existing sentences
firing unchanged.  The wording bar is ARGS.md §8's: the mistake's site
gets the caret, the sentence names the fix when there is one, and
every missing thing is named at once.

**The reversal's dividend, stated as policy**: privacy is now always
an explicit act, so every `luce.sema.private` traces to a `private`
marker somebody wrote — the sentences below that used to advise
"mark it public" now state "it is marked private", and the advice
clauses name the marker as the thing to remove.  A refusal that can
cite an authored line is strictly better than one that cites an
absence, and the rework of this table is where that improvement is
banked.

| written | code | said |
|---|---|---|
| `geo.helper()`, marked private | `luce.sema.private` | `helper is private to geo` |
| `strings.fold_case(…)` | `luce.sema.private` | `fold_case is private to strings` |
| `s.fold_case(…)` — the sugar | `luce.sema.private` | `fold_case is private to strings` — same declaration, same sentence |
| `geo.seed`, marked constant | `luce.sema.private` | `seed is private to geo` |
| `p: geo.Inner`, marked struct in an annotation | `luce.sema.private` | `Inner is private to geo` |
| `geo.Inner(…)`, marked struct constructed | `luce.sema.private` | `Inner is private to geo` — the type refusal; construction is never reached |
| `p.slot`, marked field read (or written) outside | `luce.sema.private` | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, marked field named at construction | `luce.sema.private` | `token of Session is private to session` |
| `session.Session(name = "x")`, marked required field, outside | `luce.sema.private` | `Session cannot be constructed here: id is marked private in session and has no default; construction belongs to a public function of session` |
| `func read() -> Inner` public, `Inner` marked | `luce.sema.private` | `read is public and answers Inner, which is marked private in geo; mark read private or remove the mark on Inner` |
| `private func main()` | `luce.sema.private` | `main is the entry and cannot be private: the runtime starts it` |
| `geo.helperr`, typo near a private name | `luce.sema.call` | **unchanged** — `unknown function helperr` with visible-only suggestions; a private name is never suggested |
| `public let x = 1` inside a function | `luce.parse.*` | `visibility applies to file-scope declarations and struct members` |
| `public public func f()`, `public private func f()` | `luce.parse.*` | `one visibility word per declaration` |
| `private:` at module level | `luce.parse.*` | `a visibility region belongs inside a struct; at file scope mark each declaration` |
| `private state: long` inside a `private:` region (any marker in any region) | `luce.parse.*` | `state is inside a private region, which already says it` |
| a region label with no indented member under it | existing empty-block refusal | **unchanged** — the sentence every empty block gets |
| `let _total = 1`, or any `_`-leading word anywhere | `luce.lex.name` | `a name starts with a letter: _total is not a name` |
| `let _ = f()` | `luce.parse.*` | `_ is the array-shape wildcard, not a name (array(long, _)); a binding needs a name` |

**Refusal tests to write** (the executable half, per the house rule
that anything running a program is a spec): one `errors_spec.zig` row
per sentence above, the region rows included; a `compile/test.zig`
case proving the *private* path is checked per-module in a three-file
program (A may see its own privates while B may not, in one compile);
a case proving mutual recursion still crosses files when neither
`check` is marked and is refused by name when one is; a case proving a
`private:` region and a per-declaration `private` produce the same
stage-4 facts; and the two **positive** pins — `{x:.2f}` still lowers
and compiles against unmarked `format_float`, and
`rng.next()`/`math.rng(42)` compile from a program, on both engines,
so the std surface cannot silently over-shrink.  Site `fail` fences
carry the user-facing rows onto the documentation as executable
content, the way ARGS.md sequenced its refusals.

---

## 9. What does not change (D11)

Verified against the pipeline rather than asserted:

| surface | now | after | why |
|---|---|---|---|
| `06_mir` `format_version` (`module.zig:53`) | 24 | **24** | visibility resolves where names resolve — stage 4's lookup — and MIR receives the same fully-resolved program it receives today.  The serialized module carries no name lookup to gate: its rule demands a bump for the instruction set, intrinsics, or trap codes, and none moves |
| `abi.version` (`08_llvm/abi.zig:117`) | 9 | 9 | `LuceHost` gains no slot; no semantic is added to `libluce_rt` |
| MIR instruction set, verifier, `07_optimize` | — | untouched | a private function that is *used* lowers identically; an unused one was already `prune`'s to drop — visibility changes which programs compile, never what a compiled program contains |
| `libluce_rt`, the interpreter | — | untouched | no semantic; the oracle runs the same MIR |
| `artifact.generator` | — | moves | it always moves when the compiler's sources move; stale `.lc`s are refused by name as designed |

What **does** move above stage 4, named so the claim is checkable:

- **Stage 2** gains **two** keywords — `public` and `private`, both
  fully reserved (two rows in `token.zig`'s table; no identifier
  anywhere in the corpus, specs or site spells either word — checked)
  — and `luce.lex.name` (§7).  Reserving both is not optional: a
  contextual `private` would let `private = 1` mean a binding in one
  position and a marker in another, and the language does not do
  context-dependent words.  The keyword rows flow into
  `tools/grammar.zig`'s generated editor grammar and
  `www/luce/src/highlight.zig` automatically; the committed-grammar
  agreement test catches the regeneration.
- **Stage 3** parses the marker onto `ast.FuncDecl`, `ast.ConstDecl`,
  `ast.StructDecl` and the field record — one three-state field each
  (`none` / `public` / `private`, so inert explicitness survives to
  be reasoned about) — parses struct-body regions and dissolves them
  onto their members' markers (§5), and owns the parse refusals in
  §8's table.  Regions are the one genuinely new piece of parser
  surface in this memo.
- **`programs/editor.luc`'s own highlighter** keeps a *manual*
  keyword list (`Words.is_keyword`, `editor.luc:159`) — two more `or
  word == …` clauses, a corpus edit the shell's compile test gates.
- **One severity, unchanged**: an unused private declaration is
  accepted silently, exactly as an unused local is — the language has
  no warnings, `prune` already drops what the entry cannot reach, and
  a "private and unused" diagnostic would be a lint by another name.

There is also **no unused-import interaction**: importing a module
and touching only private things is just the private refusal per
touch; the import itself stays legal as today.

---

## 10. The migration, sized honestly

The reversal collapses this section, and the numbers below are
recounted from the tree at head, not carried over.  There is **no
sweep**: not one `public` marker is needed anywhere, because unmarked
is public and the corpus's meaning is the default's.

| where | edit | count |
|---|---|---:|
| `src/luce/std/strings.luc` | `private` on `is_space_byte`, `fold_case` | 2 |
| `src/luce/std/math.luc` | `private` on `ln2`, `ln10`, and on `Rng.state`; plus the new factory `func rng(seed: long) -> Rng` (~4 lines, unmarked); the module's own head comments stop teaching `Rng(state = 42)` | 3 + 1 decl |
| `programs/mathx.luc` | `private` on `sorted` | 1 |
| `src/luce/std/files.luc`, every `programs/` and `bench/` file besides mathx and dice | nothing | 0 |
| site samples (`geometry.luc`, `shapes.luc`) and spec fixtures (`modules_spec`, `compile/test.zig`, `errors_spec`) | nothing — they compile unchanged under the default | 0 |
| the `Rng` idiom, compiled sites | `math.Rng(state = …)` → `math.rng(…)`: `programs/dice.luc:25`; site fences `std/math.md:162`, `:174`, `tour/modules.md:66`; `std_spec.zig:245`, `:246`, `:249`, `:251`, `:258`, `:268` | 10 |
| prose | `www/luce/content/std/math.md` (the five-constants line 13 becomes three; the `Rng(state:)` table row and prose at 149/154 teach `math.rng`), `docs/STD.md:95`, `docs/RETURNS.md:976`'s table mention, `docs/MISSING.md` (item 10 closed; the Tier 5 "reachable anyway" sentence resolved), `docs/LANGUAGE.md` §Modules gains the rule, `www/luce/content/tour/modules.md` + `ref/modules.md` ("an import reaches the imported file's top level — all of it, unless a declaration is marked `private`"), the status page | ~8 files |

**Six `private` markers, one four-line factory, ten call-site
migrations, and roughly eight prose files** — against the reversed
plan's roughly one hundred keywords and the same ten call sites.  The
two spec fixtures that construct a same-file `Rng` by `state`
(`behavior_spec.zig:2232`, `errors_spec.zig:1035`) are untouched:
their structs are local, same-module construction was never gated, and
their unmarked fields are public.  `docs/RETURNS.md`'s own `Rng`
fences declare a local struct and are likewise untouched.

The behavioral deletions in the whole migration: the two-spelling leak
of `fold_case`/`is_space_byte` closes, `mathx.sorted` stops being
callable from `stats.luc` — which never called it — and
`Rng(state = 42)` stops compiling outside `math.luc`, replaced by the
factory.  Every other program in the tree compiles byte-identically
with zero edits, which no ordering of the private-by-default plan
could have said.

---

## Order

Sequenced after run one (shipped) and before bitwise/hex, which
touches stage 2 for literals and should not race this memo's keyword
edits.  The reversal inverts the old plan's central constraint: there
is no sweep for enforcement to wait behind, because an unmarked tree
is a fully public tree — **enforcement lands green with zero corpus
edits**, and the one behavior-changing step is the six markers
themselves, isolated and reviewable.

1. **R3, the naming rule.**  `luce.lex.name` in stage 2; the bare-`_`
   declaration refusal in stage 3; lexer fuzz corpus extended.
   Independent of everything else and shippable alone — the corpus
   has zero casualties.  *Tests:* lexer rows, two `errors_spec` rows,
   the wildcard pinned still working (`array(long, _)` compiles).
   *~0.5 day.*
2. **The keywords, the markers, and the regions.**  `public` and
   `private` into `token.zig`; stage 3 parses the marker onto the
   four declaration forms and the field record, parses struct-body
   regions and dissolves them onto member markers, and owns every
   parse refusal in §8's table (marker on locals, second word,
   module-level label, marker-in-region, empty region);
   `tools/grammar.zig` regenerated; `editor.luc`'s `is_keyword` rows.
   **No check enforces anything yet** — markers parse and are
   carried, so this step changes no program's meaning.  Regions are
   the new parser surface and take the extra half day.  *Tests:*
   parse-level round trips including region/marker equivalence, the
   grammar agreement test.  *~1.5 days.*
3. **Enforcement.**  The three-state marker onto `FunctionDeclInfo` /
   `ConstantInfo` / `StructDeclInfo` (+ per-field states beside
   `field_defaults`, keeping `types.StructLayout` untouched — the
   ARGS step-5 precedent); the five §1 checks, the §2 surface check
   in collection, the §3 construction clauses in `lowerConstruct`,
   field access in `lowerField` and the place walk; `private main`
   refused; suggestions filtered to visible.  Lands green against the
   unmarked tree — the checks are exercised entirely by spec
   fixtures until step 4.  *Tests:* every §8 row; the per-module
   three-file case; the region-equals-marker case.  *~2 days.*
4. **The six markers and the factory.**  §10's edits: two in
   `strings.luc`, three plus the factory in `math.luc`, one in
   `mathx.luc`; the ten `Rng` call sites migrate to `math.rng`; the
   two positive pins (`{x:.2f}`, `math.rng(42)`) land beside them.
   The one commit in the run that changes what compiles, small enough
   to read whole.  *~0.5 day.*
5. **Docs and site.**  §10's prose list; item 10 closed; the refusal
   fences land as `luce fail` site content; this memo's
   became-current fences drop `historical`; the status page.
   *~0.5 day.*

**Five steps, roughly five days** — the same total as the reversed
plan, with the day the sweep cost spent instead on the region parser.
Steps 1 and 2 are independently useful; step 3 is the feature; step 4
is the whole migration.  Nothing here blocks or is blocked by the enum
memo (run four) — enums will arrive into a language that already knows
how to withhold a name, which is the right order, since an enum's
members inherit whatever visibility story their type has.

---

## Refused, with reasons

**Private by default** (Go, Rust, Zig — and this memo's own first
ratification, R1/R4).  Reversed by the owner with the evidence table
in hand (§"The evidence that turned the default"): roughly a hundred
`public` markers to hide six names, permanent noise on every public
surface of the language's own std against occasional one-word
discipline on rare internals.  What it bought — hiding-by-omission for
future userland — is recorded as the price of the reversal, paid
knowingly.  The full record is in *Ratified*.

**`pub` / `priv` (Zig, Rust).**  Ratified against (R2), and the
reason is the house naming rule generalised: *plain-English names,
never abbreviations* — the CODING_GUIDE refuses `fd` and `buf` in its
own Zig; the language it guards does not then abbreviate its own
keywords.  Seven letters, written at exactly six sites in the whole
migration.

**Export by capitalization (Go).**  Welds naming to visibility, so
renaming a thing can *republish* it; unavailable anyway in a language
whose TitleCase already means "type" by convention; and unteachable
beside R3, which just spent a run making spelling carry *less* hidden
meaning, not more.

**Exactly one visibility word** (this memo's own first-draft position,
reversed by the owner's second ruling).  The draft refused a `private`
keyword under private-by-default — "a keyword for the default is a
second spelling for silence" — and the symmetric argument would refuse
inert `public` now.  The owner ruled the other way both times the
question arose (Q5, then the second ruling): explicitness is
flexibility, never an error.  What survives of the old refusal is its
narrow core: one word *per declaration* — saying it twice is still
refused, because twice is not more explicit, it is a contradiction
waiting to happen.

**C++'s non-indenting access labels.**  `private:` as a stateful line
marker whose region ends at the next label or never — it would be the
one colon in the language that does not open an indented block, and
its extent would be invisible.  Luce's regions indent (D14).

**Region labels at module level.**  A file-spanning indented region
would put half a module one level deep to say one word; file-scope
declarations are few and long and a per-declaration marker sits
naturally on each.  Refused with a sentence pointing there (§8).

**Per-declaration markers inside regions.**  One way to say a thing;
the block already said it.  Allowing agreement (`private` inside
`private:`) invites the disagreement case, and resolving
disagreement — inner wins? outer wins? — is a precedence rule nobody
needs.  Refused at parse, where the region context lives (D15).

**Visibility levels (Swift's five, C#'s six, Rust's `pub(crate)`
family).**  Every level past two serves a boundary Luce lacks:
inheritance, packages, assemblies, crates-within-workspaces.  One
bit, and if a package system ever exists, *that* memo reopens this
table with a new boundary in hand.

**Class-private fields (Java, C++).**  The module is the trust unit
(D1).  Struct-private inside one file would make a file write
accessors for itself; Go's twenty-year experiment says package-level
is enough, and Luce's files are smaller than Go's packages.  A
`private:` region inside a struct is *spelling*, not a new boundary —
its members are private to the module, exactly as a per-declaration
marker would make them, and nothing becomes private to the struct.

**Export lists and signatures (OCaml `.mli`, Haskell's module
header, Python's `__all__`).**  A second list of the same names with
nothing checking they agree — the exact drift ARGS.md §3 documents
the builtin table being rescued from (*"two lists of the same
thirty-nine names… with nothing checking they agreed"*).  The
keyword keeps declaration and visibility adjacent forever.

**`friend` / selective export.**  No corpus demand, and it dissolves
the one-sentence rule ("private to its file") into a graph.  A
module that wants to share internals with a sibling shares a third
module both import.

**Re-exports (`pub use`).**  Already deliberately absent from the
module system (docs/LANGUAGE.md: no re-exports), and visibility does
not reopen it: a name is reached through the module that declares it.

**`public state` on `Rng`** (the draft's own recommendation,
overruled at ratification; the overrule survives the reversal
untouched).  The draft argued the seed is the API and privacy protects
no invariant; the owner's ruling is the stronger principle — an idiom
that needs an internal made public is a design bug in the library, and
the missing constructor (`math.rng(seed)`) was always the honest
shape.  The ten compiled sites and the doc pages migrate once;
named-field construction keeps its showcase in the tour's own structs.

**A "private and unused" diagnostic.**  One severity; an unused
private function is accepted exactly as an unused local is, and
`prune` already ships nothing unreachable.  Griesemer's Pandora's
box (quoted in ARGS.md) is about the compiler legislating style;
this memo declines to open it from the other side.

**Making privacy look like absence** — answering `unknown function`
for a private name.  Reversed by every language that tried it; the
did-you-mean would then either lie (suggesting nothing) or leak
(suggesting the private name).  D2: the fact is "private", so the
sentence is.

---

## Scoped out (not refused — just not now)

- **Sealed / zero-value-proof opaque types** (§4).  Its own memo if
  a module ever needs an uninhabitable-without-factory type; enums
  and unions may reshape it first.
- **Visibility granularity for tests.**  A future in-language test
  story might want to reach privates the way Rust's `#[cfg(test)]`
  modules do (Zig: tests live in the same file and need nothing).
  Luce's specs compile whole programs from outside, so today they
  exercise the public surface — which is the honest thing for an
  executable *specification* to do; the two std internals are proven
  through `lower`/`trim`/`split`, their callers.
- **Visibility for future top-level `var`** — decided by whichever
  memo creates it; it arrives into a language with one visibility
  word per declaration and chooses its own default then.
- **Enum member visibility** — run four's question; the default this
  memo sets (the type's visibility gates the members) is the null
  hypothesis it starts from.

---

## Ratified — three rounds

### Round one: the frame (before the memo)

Settled before the memo was drafted, recorded as it stood:

- **R1 (original): private by default** — functions, top-level `let`
  constants, and struct fields.  *Superseded by round three.*
- **R2: the keyword is written in full** — `public`, not `pub`.
  *Stands, extended to `private` by round three.*
- **R3: identifier names start with a letter** — no leading
  underscore, a language-wide naming rule.  *Stands, untouched.*
- **R4 (original): struct fields are private by default.**
  *Superseded by round three.*

### Round two: ratification of the memo (owner, 2026-08-06)

The six questions were put to the owner; four ratified as drafted, two
overruled:

- **Q1 — OVERRULED: `Rng.state` stays internal.**  The draft
  recommended exposing it; the owner's ruling: *"no internal members
  go public — it shows that the design of these libraries is bad."*
  The fix is the library's: math gains the public factory
  `math.rng(seed)`, and the `Rng(state = 42)` sites plus the doc
  pages migrate.  The draft's recommendation moved to *Refused*.
  *Stands through the reversal, now expressed as an explicit marker.*
- **Q2 — OVERRULED: `ln2` and `ln10` are internal.**  Internals of
  `log2`/`log10`; the site page that documented them as surface is a
  documentation bug and moves in the same run.  *Stands, now two
  markers.*
- **Q3 — ratified as drafted**: defaults gate outside construction;
  the diagnostic names the factory pattern.  *Stands (§3).*
- **Q4 — ratified as drafted**: a public surface may name only
  public types, refused at the declaration (Rust's side).  *Stands
  (§2), with the quiet-common-case note.*
- **Q5 — ratified as drafted**: an inert visibility word is accepted
  silently.  *Stands, and round three generalizes it into D13:
  restating the default is legal everywhere.*
- **Q6 — noted** (not a decision): the two new codes are
  `luce.sema.private` and `luce.lex.name`.  *Stands (D10).*

The standing principle Q1/Q2 established, binding on every future
surface audit and untouched by the reversal: **an idiom that requires
an internal member to be public is evidence of a missing public
constructor or function, never grounds for opening the internal.**

### Round three: the default reversed (owner, 2026-08-06)

Issued after reading the migration table the ratified frame produced
(~one hundred `public` markers to hide six names), verbatim:

> *"I kinda hate that there is now a lot of public word everywhere…
> But also keep private and public keywords.  And things are public by
> default but it gives flexibility to be explicit.  So we'll add
> public and private keywords to methods and variables and also have
> block regions inside structs with indentation obviously."*

Effect, as this revision executes it: R1/R4 reversed — **public by
default everywhere** (module top level, struct fields, struct
methods); **both keywords** exist per declaration with restated
defaults legal and inert (D13); **regions inside structs**, indented,
struct-only (D14).  Every other decision of rounds one and two is
restated in the new frame above, none reopened.  The D15 region
details — repeatable unordered labels, marker-in-region refused,
module-level label refused, empty region refused, both words fully
reserved — are this revision's recommendations and await the owner's
veto window, as the first draft's recommendations did.

---

---

## As built

`Order` executed in five commits on 2026-08-06, one per step, each
landing green on the full suite:

1. **R3** — `luce.lex.name` in stage 2 (uses and declarations alike,
   f-string holes included, since a hole re-lexes through the same
   `lex()`), the bare-`_` refusal at every declaring production in
   stage 3, both fuzz corpora extended.  Zero corpus casualties,
   checked rather than assumed.
2. **The keywords, the markers, and the regions** — `public` and
   `private` fully reserved; the three-state marker on the four
   declaration forms and the field record; regions parsed and
   dissolved onto member markers before stage 3 ends; every §8 parse
   refusal with its sentence.  A marked member inside a region still
   parses, carrying the region's word, so one mistake is one message.
   The editor grammar regenerated (`storage`), `editor.luc` two rows,
   the site highlighter held by its agreement test.
3. **Enforcement** — `luce.sema.private` at the call funnel
   (`lowerUserCall`, `lowerReceiverCall`, `callUser` — the last is
   the strings routing, so the sugar has no second door), the
   namespace constant read in bodies and folds, `resolveBase`'s
   dotted arm, `fieldReachable` beside every `findField`, and both
   construction fronts — `lowerConstruct` *and* `foldConstruct`,
   because the constant folder is a second door to the same struct
   and holds the same policy.  Per-field marks live beside
   `field_defaults`; `types.StructLayout` untouched.  D4 lands in
   collection with "in this file" for the root module.  Every
   did-you-mean filtered to visible names.  Landed green against the
   still-unmarked tree, proven by fixtures alone.
4. **The six markers and the factory** — §10's table verbatim; the
   ten `Rng(state = …)` sites became `math.rng(…)`; the strings-page
   coverage exemptions deleted (marked names are not surface, so the
   roster never sees them); the two positive pins live in the specs
   that run on both engines.
5. **Docs and site** — this memo's checkable fences dropped
   `historical` (`luce` / `luce refused`; the multi-file
   demonstrations run instead as `www/luce/content/ref/modules.md`
   §Visibility's compiled fences, refusals and all), LANGUAGE.md
   §Modules carries the rule, MISSING.md item 10 is closed and its
   Tier 5 sentence resolved, the math page documents three constants
   and the factory, and the status page says shipped.

**One wart the run surfaced, recorded so the next reader is not
puzzled**: §3's `Session` example writes the defaulted `token` before
the required `id`, which the trailing-defaults rule (docs/ARGS.md D3,
fields included) refuses — the shipped fixtures and the site order the
fields legally (`name`, `private id`, `private token = 0`).  The
example above stays as ratified prose; the compilable versions are the
law's spelling of it.

---

*Amended to the second ruling; rounds one and two survive with the
default flipped; D15 rode as recommendations and is built as
recommended.  `Order` executed; the record above is step by step, the
way ARGS.md's was.*

## SELF syntax update — 2026-08-08

Visibility did not change when explicit receivers were superseded.
The current spelling of the region example above is:

```luce
struct Rng:
    private:
        state: long

    func next() -> long:
        self.state = self.state * 48271 % 2147483647
        return self.state

    func real() -> double:
        return double(self.next()) / 2147483647.0
```

Both members are public because they sit outside the private region;
their implied receiver is independent of that visibility decision.

## CONSTANTS syntax update — 2026-08-08

Visibility itself did not change when file-scope constants moved from
the historical `let` spelling in this record to `const`.  The current
forms are `private const name = value` and `public const name = value`;
local `let` and `var` do not take visibility markers.

The existing public-surface check also follows a constant container's
element or map-value type.  A public container cannot expose a private
type; making the constant private or the type public closes the
surface.  Folded values may still be computed from a private constant,
because its name and type do not cross the file boundary.  This check
still dies in stage 4.  Constant containers moved the serialized module
to format 33; the published host ABI remains 13.
