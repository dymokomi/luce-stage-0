# Private until it says `public` — what an import may reach

> **Every Luce block here is tagged `historical`, and that is the
> honest tag** — the same arrangement `docs/ARGS.md` opened with, for
> the same reason.  `tools/doccheck.zig` compiles every fenced `luce`
> sample in the documents it knows about, and `historical` is its one
> exemption: *"a syntax that was proposed and refused, or a fragment
> quoted out of a program nobody wrote."*  A memo written before its
> feature exists is entirely the second of those — half the samples
> show a `public` the compiler refuses today, and half quote code that
> is about to change.  `docs/VISIBILITY.md` registers in
> `tools/documents.zig`'s `records` list with the memo (the ARGS
> precedent: registered on landing, every fence exempt honestly), and
> the fences that become current drop the tag in `Order`'s last step,
> which is the only state in which the tag would be a lie.

> **The rule.**  A declaration is **private to its file** unless it
> says `public` — written in full, before `func`, before a top-level
> `let`, before `struct`, and on a struct field's own line position.
> `import geo` still binds the namespace; what it *reaches* is geo's
> public surface, and touching anything else is `luce.sema.private`,
> one sentence: `NAME is private to geo`.  The rule is the same for a
> sibling `math.luc` and for `std.math`, because std is ordinary Luce
> and obeys every language rule.  Within one file nothing changes:
> a file is the trust unit, so a private method, field, or constant is
> reachable from anywhere in its own module, including from public
> declarations — visibility gates the *reference site's module*, never
> the call graph.  Construction composes with `docs/ARGS.md`: an
> outside construction site may name public fields only, and every
> private field must carry a default or the struct is not
> constructible outside its module — the factory pattern, named in the
> diagnostic.  Nothing reaches MIR: **visibility dies in stage 4**,
> exactly where names died, and neither the serialized module's
> `format_version` (24) nor the published host ABI (9) moves.

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

## What the owner has already ratified

Settled before this memo was written.  Recorded here and built on;
nothing below reopens them.

| | ratified |
|---|---|
| **R1** | **Private by default** — functions, top-level `let` constants, and struct fields. |
| **R2** | **The keyword is `public`, written in full.**  Not `pub`.  `public func`, `public let name`, `public` on a struct field. |
| **R3** | **Identifier names start with a letter.**  No leading underscore (or any non-letter) on variables or functions — a language-wide naming rule, not a visibility convention.  §7. |
| **R4** | **Struct fields are private by default.**  Same default as everything else; §3 is what construction means under it. |

R3 belongs in this memo because it is the other half of one decision:
languages that lack a visibility keyword grow a sigil instead —
Python's `_name`, Go's capitalization — and the sigil then means
visibility forever.  Luce takes the keyword and retires the sigil in
the same run, so `_helper` never acquires a folklore meaning the
compiler does not enforce.

---

## Decisions to ratify

One read, twelve answers.  Each argued at the section named.

| | decision | where |
|---|---|---|
| **D1** | **The unit of visibility is the module (file), not the struct.**  Go's model, not Java's: private means "this file", and within a file everything sees everything.  One rule for sibling modules and std alike. | §1 |
| **D2** | **"Exists but private" is said as private, never as unknown.**  One new code, `luce.sema.private`, one sentence shape: `NAME is private to MODULE`.  Did-you-mean offers public names only. | §1, §8 |
| **D3** | **An outside construction site may name public fields only, and every private field must have a default** — otherwise the struct is not constructible outside its module and the diagnostic names the factory pattern.  A private field's default cannot be overridden from outside.  Composes with ARGS.md D8; the interaction is spelled out clause by clause. | §3 |
| **D4** | **A public declaration's surface may name only public types.**  Rust's rule (E0446), not Go's: a public function whose parameter, result, or public field mentions a private struct is refused at the declaration. | §2 |
| **D5** | **An opaque type is field privacy and nothing more.**  A public struct with private fields is opaque operationally; the zero value keeps the type inhabitable and the memo says so instead of pretending otherwise.  No `opaque` keyword — scoped out. | §4 |
| **D6** | **`public func` inside a struct follows the same rule**, and so does a public field: the module is still the unit.  A private method called from a public one is ordinary; `public` on a member of a private struct is legal and inert. | §5 |
| **D7** | **`main` is never marked.**  Entry selection is by name in the root module, not by export; Java's `public static void main` is the counter-precedent, already refused once in docs/METHODS.md for the parameter and refused here for the keyword. | §5 |
| **D8** | **Privacy gates names, never values.**  A public constant may fold from private ones; a public function's parameter default may fold from a private constant — the caller materialises the folded value, not the name. | §1, §3 |
| **D9** | **R3 lands in two small checks**: stage 2 refuses an identifier that begins `_` and is longer than the `_` (`luce.lex.name`), everywhere and for every use; stage 3 refuses the bare `_` as a declared name, because the lone `_` stays what it is — the array-shape wildcard, which is not a name. | §7 |
| **D10** | **Two new diagnostic codes and no more**: `luce.sema.private` and `luce.lex.name`.  The first is a genuinely new refusal class; the second is a genuinely new lexical rule.  Everything else reuses sentences that exist. | §8 |
| **D11** | **Nothing below stage 4 moves.**  `format_version` stays 24, `abi.version` stays 9, MIR, the verifier, the optimizer, `libluce_rt` and the interpreter are untouched.  Stage 2 gains one keyword and one refusal; stage 3 carries one flag. | §9 |
| **D12** | **std's public surface is this memo's roster** (§6): 87 declarations audited, 6 go private (`strings.is_space_byte`, `strings.fold_case`, `mathx.sorted`, `math.ln2`, `math.ln10`, `Rng.state`), and math gains one declaration — the public factory `math.rng(seed)`, which replaces the `Rng(state = 42)` idiom at its 14 sites.  Owner's ruling: **no internal member goes public to save an idiom**; a library whose idiom needs internals has a design bug, and the fix is the library's. | §6 |

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

```luce historical
import std.strings

func main():
    # the qualified spelling
    print(strings.fold_case("MIXED", 65, 90, 32))
    # and the method sugar, which routes to the same declaration
    # (builder.zig's stringsCall) and makes it look blessed
    print("MIXED".fold_case(65, 90, 32))
```

Nothing in the tree calls either from outside — checked, not assumed:
`grep -rn 'fold_case(\|is_space_byte(' programs/ bench/ site/content
src/luce/specs/` finds prose mentions and zero calls.  The leak has no
victims yet, which is precisely `docs/MISSING.md`'s point: *"matters
before userland libraries exist."*  A `mathx.luc` published today
would freeze `sorted` into its API by accident.

### The pressure point the ratified frame creates

R4 says fields are private by default.  The most-documented struct
construction in the language is:

```luce historical
var rng = math.Rng(state = 42)
```

Fourteen sites across `programs/`, `site/content/` and `specs/` write
it; `docs/STD.md`, `site/content/std/math.md` and `docs/LANGUAGE.md`'s
own examples teach it.  Under R4, `state` is private and every one of
those sites stops compiling.  **Ratified resolution (owner, 2026-08-06):
`state` stays private and the idiom was the bug** — an idiom that only
works by touching a struct's internals is evidence of a missing
constructor, not grounds for opening the field.  math gains the public
factory `math.rng(seed)`, the fourteen sites and three documentation
pages migrate to `var rng = math.rng(42)`, and §3's construction rule
applies to `Rng` exactly as to any other struct.  (The memo as drafted
recommended `public state`; the owner overruled it, and the general
principle is recorded: **no internal member goes public to save an
idiom — the library gets fixed instead.**)

### The honest size of the sweep

Visibility prices only the import surface, and the import surface is
small.  Counted declaration by declaration (§6 and §10 carry the
tables):

| where | `public` markers needed | stays private |
|---|---:|---:|
| `src/luce/std/` (strings 15, math 30 incl. the new `rng` factory, files 10) | **55** | 5 |
| `programs/mathx.luc` | **4** | 1 |
| every other `programs/` and `bench/` file | **0** | — |
| site samples (`geometry.luc` 5, `shapes.luc` 6) | **11** | 0 |
| spec and driver fixtures (`modules_spec`, `compile/test.zig`, `errors_spec`) | **~30** | 0 |

Roughly **a hundred `public` keywords**, six declarations actually
hidden, and one idiom rewritten (the fourteen `Rng(state = 42)` sites
move to `math.rng(42)` — same behavior, honest constructor).  That
ratio is the cost of private-by-default in a tree whose modules were
written to be imported, and it is paid once, in daylight, by the run
that ships the feature.  What it buys is every module
anyone writes afterwards: the default that makes the *next* thousand
declarations private until their author decides otherwise.

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
| **Luce** | **file** | **private** | **`public`, in full** | **2** |

**Go is the closest relative and the strongest precedent for D1.**
Its unit is the package, everything inside sees everything, and
`private` means "mine, not yours" between compilation units — no
class-privacy, no friend, no ladder.  Twenty years of Go code has not
produced a movement for finer grain.  What Luce declines from Go is
the *spelling*: capitalization-as-export welds two unrelated decisions
together (what a thing is called, and who may see it), and Luce
already spends capitalization by convention on types.  A keyword says
the visible thing visibly.

**Rust is the precedent for the default and for D4.**  Private by
default is the position Rust has never regretted; its
`private_in_public` refusal (E0446, now the `private_interfaces` lint
at deny) is the recorded lesson that a public surface naming private
types is a hole, not a flexibility — callers can be handed a value
they cannot name, write down, or construct.  Go permits returning
unexported types and its own `golint` has flagged it since 2013
(*"exported func returns unexported type … which can be annoying to
use"*); Luce takes Rust's side while the corpus contains zero
instances to break.  What Luce declines from Rust is the ladder:
`pub(crate)`, `pub(super)` and `pub(in path)` answer questions a
two-level tree with no packages cannot ask.  One bit.

**Zig is the precedent for the mechanism.**  `pub` per declaration,
file-scoped, checked at resolution — and the CODING_GUIDE already
imports the principle into this tree's own Zig: *"A file boundary in
Zig is a privacy boundary."*  Luce declines only the abbreviation, by
ratified R2.

**Python is the counter-example R3 answers.**  A convention the
compiler does not enforce becomes a dialect: `_name` means private,
except when it doesn't, and `from module import *` respects it, except
when `__all__` says otherwise.  PEP 8 itself has to explain three
different underscore prefixes.  Luce's answer is that the compiler
enforces the rule (so no convention is needed) and the sigil is
refused outright (so no convention can form).

**Java is the counter-example D7 answers.**  `public static void
main` — a visibility keyword required on a function nothing imports,
taught to every beginner as an incantation.  docs/METHODS.md already
declined Java's mandatory `String[] args` for the entry; this memo
declines the mandatory `public` for the same reason: the entry is
found by name, by the runtime, and marking it teaches something false
about who calls it.

**Swift's five levels and C#'s six are the ladder refused.**  Every
level past two exists to serve a boundary Luce does not have —
subclassing (`open`/`protected`), assemblies (`internal`), nested
types.  A language with no inheritance, no packages and no separate
compilation gets to keep the bit a bit.

**OCaml's signatures are the road not taken for a structural reason.**
An `.mli` is a second file that restates the first's surface — power
Luce has no use for (no abstract types over multiple implementations)
at a price docs/ARGS.md already declined once in another form: two
lists of the same names with nothing checking they agree.  The
per-declaration keyword keeps the declaration and its visibility in
one place.

---

## 1. The unit is the module, and what the compiler says (D1, D2, D8)

### What private means

A declaration without `public` is reachable from its own file and
nowhere else.  `import geo` binds the namespace exactly as today
(`docs/LANGUAGE.md` §Modules); every *reference* through it — a call,
a constant read, a type annotation, a construction, a method on an
imported struct's value, the string-method sugar — checks one bit at
the site where the name resolves.  The check compares the
declaration's module against the referencing module, both of which
stage 4 already holds (`FunctionDeclInfo.module`,
`ConstantInfo.module`, `StructDeclInfo.module` —
`04_semantics/context.zig`), so no new bookkeeping travels anywhere.

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
# 1 — a sibling module
import mathx

func main():
    print(string(mathx.median([3.0, 1.0, 2.0])))   # public: compiles
    let s = mathx.sorted([3.0, 1.0, 2.0])          # refused:
    # mathx.luc:22: error: sorted is private to mathx [luce.sema.private]
```

```luce historical
# 2 — the standard library, identical rule, identical sentence
import std.strings

func main():
    print(strings.lower("MIXED"))                  # public: compiles
    print(strings.fold_case("MIXED", 65, 90, 32))  # refused:
    # error: fold_case is private to strings [luce.sema.private]
```

```luce historical
# 3 — the method sugar routes to the same declaration and the same
# refusal, so the leak has no second door
import std.strings

func main():
    print("MIXED".fold_case(65, 90, 32))
    # error: fold_case is private to strings [luce.sema.private]
```

There is no std-specific wording.  A sibling's author can add
`public`; std's user cannot, and the sentence does not pretend
otherwise by advising an edit — it states the fact, and the
did-you-mean machinery (public names only, D2) supplies the fix when
one is near: `fold_case is private to strings` on a call the author
meant as `lower` gets no suggestion, because the names are far apart;
`strings.trimm` still suggests `trim`, because suggestion and
visibility filter compose.

### Private is not unknown

The refusal fires **after** existence is established, which is what a
new code buys (D10): `geo.helperr` where `helper` is private answers
`unknown function helperr` with public suggestions, and `geo.helper`
answers `helper is private to geo`.  Saying "unknown" about a name
that exists would send the author hunting for a typo that is not
there; every language that made privacy look like absence (C++'s
pre-C++11 overload resolution, early Rust) reversed it.

### Constants, and the folding rule (D8)

A public constant may be *built from* private ones, because folding
happens inside the declaring module and what crosses the boundary is
the value:

```luce historical
# geo.luc
let seed = 41                      # private
public let answer = seed + 1       # public; folds to 42 in geo

# main.luc
import geo
func main():
    print(string(geo.answer))      # 42 — the value crossed, not the name
    print(string(geo.seed))        # seed is private to geo
```

The same clause serves ARGS.md's defaults: `public func pad(s: string,
fill: string = default_fill)` with a private `default_fill` is legal —
the caller materialises the folded constant, never the name.  This
needs no code: `foldConstant` folds in the declaring module's context
(`declarations.zig`), and the visibility check guards the *reference
paths* (the `geo.pi` arm at `declarations.zig:1190`, `lowerField`'s
namespace arm), not the fold result.

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
through the first row like any other cross-module call, which is why
`format_float` must be public (§6) and why one spec pins it.

---

## 2. A public surface names public types (D4)

```luce historical
# geo.luc
struct Inner:                      # private
    n: long

public func read() -> Inner:       # refused at the declaration:
    return Inner(n = 1)
# error: public read answers Inner, which is private to geo;
# mark Inner public or make read private [luce.sema.private]
```

Refused for parameters, results, and the types of **public** fields
and public constants.  A *private* field's type is not part of the
public surface and may be private — that is what lets an opaque struct
(§4) hide an implementation struct entirely.

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

The ratified frame (R4) meets ARGS.md's construction clause here, and
the interaction has to be stated precisely because both features are
load-bearing at the same site — `lowerConstruct`
(`builder.zig:6107`), which already resolves names to fields, fills
defaults, and reports every missing field at once.

**The rule, in three clauses:**

1. **An outside construction site may name public fields only.**
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
public struct Session:
    public name: string
    token: long = 0            # private, defaulted: outsiders never say it
    id: long                   # private, required: outsiders cannot build one

public func open(name: string) -> Session:
    return Session(name = name, id = next_id())

# main.luc
import session
func main():
    let s = session.open("dy")                  # the factory: compiles
    let t = session.Session(name = "dy")        # refused:
    # error: Session cannot be constructed here: id is private to
    # session and has no default; construction belongs to a public
    # function of session [luce.sema.private]
    let u = session.Session(name = "x", token = 7)   # refused:
    # error: token of Session is private to session [luce.sema.private]
```

A struct **every** one of whose fields is public constructs outside
exactly as today (`geometry.Point(x = 0.0, y = 0.0)` — the site's own
sample, once `x` and `y` say `public`).  A struct every one of whose
private fields has a default constructs outside with its public
fields only — which includes the all-defaulted `Options()` ARGS.md
ratified, public fields or none.

**Why not the blunter rule** — "construction is module-private unless
every field is public"?  It is simpler to state and it forbids the
most useful shape this feature has: the half-open record, public
knobs in front, private machinery behind, `Session` above.  Zig
builds exactly this compose (private fields with defaults + public
fields) and it is the idiom its `std` options structs live on.  The
blunter rule also forces a factory for structs that need none, and a
factory that merely restates every public field is ceremony.

**Why not the looser rule** — outsiders may name a private field when
it has a default?  Because then a default changes a field's
*visibility*, and two unrelated clauses (`= 0` and `public`) become
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
ratified: `state` stays private, and the diagnostic's factory pattern
is not a consolation prize but the design — `math.rng(seed)` is the
constructor the module always owed its callers, and the
`Rng(state = 42)` idiom was fourteen sites writing through a wall that
had not been built yet.  The overruled alternative — `public state` —
is recorded in *Refused*.

---

## 4. The opaque boundary (D5)

Can a module export a struct whose shape outsiders cannot see?
**Yes, and it is not a new mechanism** — it is D1 + R4 composing:

```luce historical
# handle.luc
public struct Handle:
    slot: long                     # private; no default: not constructible outside
    generation: long

public func fresh() -> Handle:
    return Handle(slot = next_slot(), generation = 1)

public func alive(h: Handle) -> bool:
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

## 5. Inside a struct, and the entry (D6, D7)

### Members

`public` on a function inside a struct — method or namespace function
alike — means what it means at file scope: reachable through an
import.  The module is still the unit, so:

- **A private method called from a public one is ordinary code.**
  `Rng.real` (public) calling `Rng.next` would be fine were `next`
  private; visibility is checked where a *program refers to a name*,
  not along the call graph.  The same already holds for functions —
  public `strings.lower` calls private `fold_case` — and a struct
  earns no second rule.
- **A public member of a private struct is legal and inert.**  D4
  keeps the struct out of every public signature, so no importer can
  ever hold a value to call it on; the `public` simply never fires.
  Refusing it would add a rule whose only effect is to make
  *promoting* the struct later a two-step edit.
- **`public` in the root module is legal and inert** for the same
  reason: a file does not know whether it will be imported, and the
  same `mathx.luc` is a program's sibling today and a library
  tomorrow.  A keyword that is an error in one role and required in
  the other would make every promotion a sweep.
- **Fields follow §3**; there is no per-field story beyond it.

### The entry

`main` is not marked, and marking it is legal-and-inert like any
other root declaration, never required.  The entry is selected by
*name* in the root module (`function_names.get("main")`,
`declarations.zig:190`) and called by the runtime through the ABI —
there is no import edge to gate, so `public` would assert something
no boundary checks.  Java's `public static void main` is the standing
counter-precedent: a visibility keyword as incantation, already
declined once in this tree when docs/METHODS.md refused the mandatory
`args` parameter with the sentence that covers both: *a program that
never [needs it] says nothing about it, and a reader learns nothing
false.*  An imported module's `main` is just a function named `main`
(`geo.main` is never the entry), and stays private like anything else
unless exported.

### Top-level `var`

There is no top-level `var` (docs/LANGUAGE.md: *"Top-level `var` does
not exist"*), so there is nothing for `public var` to mean at file
scope, and the refusal that exists today already answers it — the
`public` prefix adds no arm.  If mutable file scope ever arrives
(docs/V2.md's open question), it arrives into a language where the
default is already private, which is the right order to decide those
two in.

### Locals

`public` on a local `let`/`var`, a parameter, or any statement is a
parse error naming the rule: `public applies to file-scope
declarations and struct members`.  Visibility is about the module
boundary; there is no smaller boundary for it to mean anything at.

---

## 6. std's own surface, audited (D12)

Every declaration in `src/luce/std/*.luc` and `programs/mathx.luc`,
audited against docs/STD.md, the site's std pages, and every call in
the corpus.  **std obeys the same rule it imposes** — `files.luc`
reaches `strings.split`/`join` through the same public surface any
program does.

### strings — 17 declarations: 15 public, 2 private

| public | private |
|---|---|
| `find`, `contains`, `starts_with`, `ends_with`, `count`, `trim`, `lower`, `upper`, `replace`, `repeat`, `split`, `join`, `pad_left`, `pad_right`, `format_float` | `is_space_byte`, `fold_case` |

The two privates are the memo's warrant (item 10).  `format_float`
must be public twice over: it is documented, and the f-string
`{x:.2f}` spec lowers to a compiler-synthesized cross-module call to
it — a spec pins that the synthesized call still compiles (§8).
`split` and `join` are additionally load-bearing for `files.luc`'s
own `read_lines`/`write_lines`.

### math — 33 declarations after the ratified fix: 30 public, 3 private

| kind | names |
|---|---|
| constants (3 public, 2 private) | `pi`, `tau`, `e` public; **`ln2`, `ln10` private** — internals of `log2`/`log10` |
| scalar functions (10) | `round`, `exp`, `ln`, `log2`, `log10`, `pow`, `ipow`, `sin`, `cos`, `tan` |
| vector functions (12) | `sum`, `mean`, `vmin`, `vmax`, `minmax`, `dot`, `norm`, `variance`, `stddev`, `fill`, `scale`, `axpy` |
| the generator (6) | `struct Rng` public, **field `state` private**, methods `next`, `real`, `in_range` public, and the new public factory `func rng(seed: long) -> Rng` |

The calls, as ratified by the owner (2026-08-06):

- **`ln2` and `ln10` go private.**  The memo drafted them public
  because `site/content/std/math.md:13` documents all five constants;
  the owner overruled: they are internals of `log2`/`log10`, and a
  documented internal is a documentation bug, not a public surface.
  The site page moves in the same run.
- **`Rng.next` stays public.**  Documented on three site pages,
  exercised by `std_spec.zig:248` from a program's `main`, and it is
  the honest raw face the two friendly ones (`real`, `in_range`)
  wrap.  This is API, not internals: a caller who wants the raw
  stream is doing something the module supports.
- **`Rng.state` stays private, and math gains `rng(seed)`** — the §3
  pressure point resolved the other way from the draft.  The taught
  idiom `math.Rng(state = 42)` reached through the type's wall, and
  the owner's ruling is that this evidences a missing constructor,
  not a field that wants to be public: *no internal member goes
  public to save an idiom.*  The factory is four lines in `math.luc`
  (which, being the module itself, may still write
  `Rng(state = seed)`); the fourteen call sites become
  `math.rng(42)`.

### files — 10 declarations: all public

`exists`, `read`, `write`, `read_lines`, `write_lines`,
`append_text`, `append_lines`, `delete`, `rename`, `list`.  No
internals; the module is a thin layer and audits as one.  (The
`append_text` reserved-name wart is item 6's and is **not** closed by
this memo: `append` is reserved by the method table, and visibility
does not unreserve names.)

### mathx (userland, `programs/`) — 5 declarations: 4 public, 1 private

`mean`, `extremes`, `median`, `deviation` public (stats.luc calls
them); **`sorted` private** — it is called only by `median`, and it
becomes the tree's first genuinely hidden userland helper: the
showcase, in the flagship multi-module program, of what the feature
is for.

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
characters or numbers).  Everything else is existing sentences firing
unchanged.  The wording bar is ARGS.md §8's: the mistake's site gets
the caret, the sentence names the fix when there is one, and every
missing thing is named at once.

| written | code | said |
|---|---|---|
| `geo.helper()`, private function | `luce.sema.private` | `helper is private to geo` |
| `strings.fold_case(…)` | `luce.sema.private` | `fold_case is private to strings` |
| `s.fold_case(…)` — the sugar | `luce.sema.private` | `fold_case is private to strings` — same declaration, same sentence |
| `geo.seed`, private constant | `luce.sema.private` | `seed is private to geo` |
| `p: geo.Inner`, private struct in an annotation | `luce.sema.private` | `Inner is private to geo` |
| `geo.Inner(…)`, private struct constructed | `luce.sema.private` | `Inner is private to geo` — the type refusal; construction is never reached |
| `p.slot`, private field read (or written) outside | `luce.sema.private` | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, private field named at construction | `luce.sema.private` | `token of Session is private to session` |
| `session.Session(name = "x")`, private required field, outside | `luce.sema.private` | `Session cannot be constructed here: id is private to session and has no default; construction belongs to a public function of session` |
| `public func read() -> Inner`, private type in public surface | `luce.sema.private` | `public read answers Inner, which is private to geo; mark Inner public or make read private` |
| `geo.helperr`, typo near a private name | `luce.sema.call` | **unchanged** — `unknown function helperr` with public-only suggestions; a private name is never suggested |
| `public let x = 1` inside a function | `luce.parse.*` | `public applies to file-scope declarations and struct members` |
| `public public func f()` | `luce.parse.*` | `public is written once` |
| `let _total = 1`, or any `_`-leading word anywhere | `luce.lex.name` | `a name starts with a letter: _total is not a name` |
| `let _ = f()` | `luce.parse.*` | `_ is the array-shape wildcard, not a name (array(long, _)); a binding needs a name` |

**Refusal tests to write** (the executable half, per the house rule
that anything running a program is a spec): one `errors_spec.zig` row
per sentence above; a `compile/test.zig` case proving the *private*
path is checked per-module in a three-file program (A may see its own
privates while B may not, in one compile); a case proving mutual
recursion still crosses files when both `check`s are public and is
refused by name when one is not; and the two **positive** pins —
`{x:.2f}` still lowers and compiles against public `format_float`,
and `rng.next()`/`math.rng(42)` compile from a program, on
both engines, so the std surface cannot silently over-shrink.  Site
`fail` fences carry the user-facing rows onto the documentation as
executable content, the way ARGS.md sequenced its refusals.

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

- **Stage 2** gains the `public` keyword (one row in
  `token.zig`'s table — no identifier anywhere in the corpus or site
  spells `public`, checked) and `luce.lex.name` (§7).  The keyword
  row flows into `tools/grammar.zig`'s generated editor grammar and
  `site/src/highlight.zig` automatically; the committed-grammar
  agreement test catches the regeneration.
- **Stage 3** parses the prefix onto `ast.FuncDecl`, `ast.ConstDecl`,
  `ast.StructDecl` and the field record — one `public: bool` each —
  and owns the three parse refusals in §8's table.
- **`programs/editor.luc`'s own highlighter** keeps a *manual*
  keyword list (`Words.is_keyword`, `editor.luc:159`) — one more `or
  word == "public"` clause, a corpus edit the shell's compile test
  gates.
- **One severity, unchanged**: an unused private declaration is
  accepted silently, exactly as an unused local is — the language has
  no warnings, `prune` already drops what the entry cannot reach, and
  a "private and unused" diagnostic would be a lint by another name.

There is also **no unused-import interaction**: importing a module
and touching only private things is just the private refusal per
touch; the import itself stays legal as today.

---

## 10. The migration, sized honestly

Counted, with the commands to re-derive:

| where | edit | count |
|---|---|---:|
| `src/luce/std/strings.luc` | `public` on 15 of 17 | 15 |
| `src/luce/std/math.luc` | `public` on 30 of 33 (3 constants, 22 functions + the new `rng` factory, `Rng` + 3 methods); `ln2`, `ln10`, `state` stay private; 14 corpus sites move to `math.rng(seed)` | 30 |
| `src/luce/std/files.luc` | `public` on all 10 | 10 |
| `programs/mathx.luc` | `public` on 4 of 5 — `sorted` stays | 4 |
| every other `programs/`, `bench/` file | nothing — single-module programs export nothing | 0 |
| `site` samples: `tour/modules.md` `geometry.luc` (struct + 2 fields + `unit` + `distance`), `ref/modules.md` `shapes.luc` (`unit` + struct + 2 fields + `area` + `square`) | `public` markers | 11 |
| spec fixtures: `specs/modules_spec.zig` (geo ×7, area, even/odd, a/b/c, config ×6), `compile/test.zig`'s `geo_module` and friends, `errors_spec.zig` | markers | ~30 |
| docs prose: `docs/LANGUAGE.md` (§Modules, §Scope, §File-scope constants gain the rule; "Deliberately absent" loses nothing), `docs/STD.md` (the roster), `docs/MISSING.md` (item 10 closed; the Tier 5 "reachable anyway" sentence resolved), `site/content/tour/modules.md` + `ref/modules.md` ("an import reaches the imported file's **public** top level"), `std/*` pages, the status page | edits | ~10 files |

Roughly **a hundred keywords and ten prose files**, all mechanical,
all in daylight, each commit leaving the tree green because the
`public` prefix is parsed before the checks are enforced (see
*Order*).  Programs change meaning nowhere: every marker makes legal
what was legal; five of the six privatisations hide names with zero
external callers (checked in §"What the corpus actually says"), and
the sixth — `Rng.state` — has exactly the fourteen seeding sites,
which migrate to `math.rng(seed)` in the same run.

The behavioral deletions in the whole sweep: the two-spelling leak of
`fold_case`/`is_space_byte` closes, `mathx.sorted` stops being
callable from `stats.luc` — which never called it — and
`Rng(state = 42)` stops compiling outside `math.luc`, replaced by the
factory.

---

## Order

Sequenced after run one (shipped) and before bitwise/hex, which
touches stage 2 for literals and should not race this memo's keyword
edit.  Each step leaves the tree green; the enforcement step is
deliberately **after** the corpus sweep, so no intermediate commit has
a compiler stricter than its own std.

1. **R3, the naming rule.**  `luce.lex.name` in stage 2; the bare-`_`
   declaration refusal in stage 3; lexer fuzz corpus extended.
   Independent of everything else and shippable alone — the corpus
   has zero casualties.  *Tests:* lexer rows, two `errors_spec` rows,
   the wildcard pinned still working (`array(long, _)` compiles).
   *~0.5 day.*
2. **The keyword and the flag.**  `public` into `token.zig`; stage 3
   parses it onto the four declaration forms; the three parse
   refusals; `tools/grammar.zig` regenerated; `editor.luc`'s
   `is_keyword` row.  **No check enforces anything yet** — `public`
   parses and is carried, so this step changes no program's meaning.
   *Tests:* parse-level round trips, the grammar agreement test.
   *~1 day.*
3. **The corpus sweep.**  §10's markers: std, `mathx`, site samples,
   spec fixtures — mechanical, reviewable, green under the
   still-permissive compiler.  *~1 day.*
4. **Enforcement.**  The bits onto `FunctionDeclInfo` /
   `ConstantInfo` / `StructDeclInfo` (+ per-field bits beside
   `field_defaults`, keeping `types.StructLayout` untouched — the
   ARGS step-5 precedent); the five §1 checks, the §2 surface check
   in collection, the §3 construction clauses in `lowerConstruct`,
   field access in `lowerField` and the place walk; suggestions
   filtered to public.  *Tests:* every §8 row; the per-module
   three-file case; the two positive pins (`{x:.2f}`,
   `math.rng(42)`).  *~2 days.*
5. **Docs and site.**  §10's prose list; item 10 closed; the refusal
   fences land as `luce fail` site content; this memo's
   became-current fences drop `historical`; the status page.
   *~0.5 day.*

**Five steps, roughly five days.**  Steps 1 and 2 are independently
useful; step 4 is the feature; nothing here blocks or is blocked by
the enum memo (run four) — enums will arrive into a language that
already knows how to withhold a name, which is the right order, since
an enum's members inherit whatever visibility story their type has.

---

## Refused, with reasons

**`pub` (Zig, Rust).**  Ratified against (R2), and the reason is the
house naming rule generalised: *plain-English names, never
abbreviations* — the CODING_GUIDE refuses `fd` and `buf` in its own
Zig; the language it guards does not then abbreviate its own
keywords.  Six letters, written at ~100 sites in the whole migration.

**Export by capitalization (Go).**  Welds naming to visibility, so
renaming a thing can *republish* it; unavailable anyway in a language
whose TitleCase already means "type" by convention; and unteachable
beside R3, which just spent a run making spelling carry *less* hidden
meaning, not more.

**A `private` keyword.**  Private is the default; a keyword for the
default is a second spelling for silence, and the language has been
here before — ARGS.md refused optionality markers for the same
shape of reason.  There is exactly one visibility word.

**Visibility levels (Swift's five, C#'s six, Rust's `pub(crate)`
family).**  Every level past two serves a boundary Luce lacks:
inheritance, packages, assemblies, crates-within-workspaces.  One
bit, and if a package system ever exists, *that* memo reopens this
table with a new boundary in hand.

**Class-private fields (Java, C++).**  The module is the trust unit
(D1).  Struct-private inside one file would make a file write
accessors for itself; Go's twenty-year experiment says package-level
is enough, and Luce's files are smaller than Go's packages.

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
overruled at ratification).  The draft argued the seed is the API and
privacy protects no invariant; the owner's ruling is the stronger
principle — an idiom that needs an internal made public is a design
bug in the library, and the missing constructor (`math.rng(seed)`)
was always the honest shape.  The fourteen sites and three doc pages
migrate once; named-field construction keeps its showcase in the
tour's own structs.

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
- **`public` granularity for tests.**  A future in-language test
  story might want to reach privates the way Rust's `#[cfg(test)]`
  modules do (Zig: tests live in the same file and need nothing).
  Luce's specs compile whole programs from outside, so today they
  exercise the public surface — which is the honest thing for an
  executable *specification* to do; the two std internals are proven
  through `lower`/`trim`/`split`, their callers.
- **Visibility for future top-level `var`** — decided by whichever
  memo creates it, into a default that is already private.
- **Enum member visibility** — run four's question; the default this
  memo sets (the type's visibility gates the members) is the null
  hypothesis it starts from.

---

## Ratified (owner, 2026-08-06)

The six questions were put to the owner and every decision above now
reads as ratified, with two overruled:

- **Q1 — OVERRULED: `Rng.state` stays private.**  The draft
  recommended `public state`; the owner's ruling: *"no internal
  members go public — it shows that the design of these libraries is
  bad."*  The fix is the library's: math gains the public factory
  `math.rng(seed)`, and the fourteen `Rng(state = 42)` sites plus
  three doc pages migrate.  The draft's recommendation moved to
  *Refused*.
- **Q2 — OVERRULED: `ln2` and `ln10` go private.**  Internals of
  `log2`/`log10`; the site page that documented them as surface is a
  documentation bug and moves in the same run.
- **Q3 — ratified as drafted**: defaults gate outside construction;
  the diagnostic names the factory pattern.
- **Q4 — ratified as drafted**: a public surface may name only
  public types, refused at the declaration (Rust's side).
- **Q5 — ratified as drafted**: inert `public` is accepted silently;
  promoting a file to a module stays a zero-edit change.
- **Q6 — noted** (not a decision): the two new codes are
  `luce.sema.private` and `luce.lex.name`.

The standing principle Q1/Q2 established, binding on every future
surface audit: **an idiom that requires an internal member to be
public is evidence of a missing public constructor or function, never
grounds for opening the internal.**

---

*Ratified in full; `Order` executes.  The "As built" section lands
here, step by step, the way ARGS.md's did.*
