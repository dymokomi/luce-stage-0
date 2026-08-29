# Visibility: `pub`

Every declaration in a Luce file is **private** unless it says `pub`.
Visibility controls one thing: what a program in another file may reach
through an `import`. It gates the *reference site's module*, never the
call graph, and it is resolved entirely during checking — nothing about
it survives into the compiled program.

## The rule in one paragraph

A file-scope `func`, `alias`, `const`, `struct`, `interface`, `enum`, or
`union` is private by default; write `pub` before it to expose it to
importers. A struct field is private by default; write `pub` before the
field to expose it. An `import` binds the module's namespace either way;
what it *reaches* is the module's surface — everything, and only what, is
marked `pub` — and touching an unexposed name from another file is
`luce.sema.private`, one sentence: `NAME is private to MODULE`. The unit
of visibility is the **file**: a private declaration is reachable from
anywhere in its own file, including from `pub` declarations — so a file
always trusts itself, and privacy only means "not visible across the
module boundary."

## The unit is the file

Luce follows Go's model, not a class-private one: private means "this
file," and within a file everything sees everything. A private helper is
reachable from a `pub` function in the same file, a private field is
reachable from a method in the same file, and a private constant folds
into a `pub` one in the same file. The check compares the declaration's
module against the referencing module — both of which the checker already
holds — and fires only when they differ, and only on a declaration the
author never marked `pub`. Within a file, `pub` is inert: it marks the
boundary and there is no boundary inside one file.

The same rule governs sibling modules and the standard library alike: the
standard library is ordinary Luce source and obeys every language rule,
so `strings.fold_case` — left unmarked inside `std/strings.luc` — is
refused from any other file exactly as a sibling's private helper is.
There is no standard-library-specific wording.

## Writing the marker

`pub` is the one visibility word, written immediately before the
declaration it exposes:

```luce
const scale: i64 = 10             # private: geo's own business
pub const limit: i64 = scale * 4  # exposed; folds to 44

alias InternalId = i64            # private
pub alias UserId = i64            # exposed

func helper(x: i64) -> i64:       # private
    return x + scale

pub func answer() -> i64:         # exposed
    return helper(2) + limit
```

Exactly **one** `pub` may appear per declaration; a second (`pub pub`) is
a parse error, `one `pub` per declaration`. There is no word for the
default — a declaration is private by saying nothing, the way a local is
immutable by saying nothing.

On a struct field, the marker goes on the field's own line:

```luce
pub struct Session:
    pub let name: str
    let id: i64
    let token: i64 = 0
```

Here `name` crosses the boundary and `id`/`token` do not. There is no
region form: each member states its own visibility, so reading any one
line tells the whole truth about that member.

## A public surface names only public types

A `pub` declaration's surface — a function's parameter or result type, a
`pub` field's type, a `pub` constant's type — may name only `pub` types.
Leaving a type private while exposing a surface that mentions it is
refused at the declaration:

```luce refused
struct Inner:
    let n: i64

pub func read() -> Inner:
    return Inner(n = 1)

func main():
    print(str(read().n))
```

```text
read is public and answers Inner, which is private in this file;
remove pub from read or mark Inner pub
```

The refusal names both edits that would restore honesty. The common case
— nobody exposes anything — is quiet by construction, and this refusal
can only ever land on the author who created the hole: a `pub` surface
can name a private type only because someone wrote `pub` on the surface
and not on the type.

The alternative would let an importer hold a value of a type it cannot
write down — cannot annotate, cannot store in a field, cannot declare a
`var` of. A *private* field's type is not part of the public surface and
may stay private; that is what lets an opaque struct hide an
implementation type entirely.

## Construction with private fields

When a struct has private fields, construction from another file follows
three rules:

1. **An outside construction site may name `pub` fields only.** Naming a
   private field — even one with a default — is refused: a default is the
   module's chosen value for a slot the module kept, and overriding it
   from outside is exactly the access privacy removed.
2. **A private field with a default is filled from it, silently.** The
   module decides the value; the outsider does not mention the slot.
3. **A private field with no default makes the struct not constructible
   outside its module.** The diagnostic names the pattern that is: a
   `pub` function of the declaring module — a factory.

```text
# session.luc
pub struct Session:
    pub name: str                   # exposed
    token: i64 = 0                  # private, defaulted: outsiders never say it
    id: i64                         # private, required: outsiders cannot build one

pub func open(name: str) -> Session:
    return Session(name = name, id = next_id())

# main.luc
import session

func main():
    let s = session.open("dy")                  # the factory: compiles
    let t = session.Session(name = "dy")        # refused:
    # Session cannot be constructed here: id is private in session
    # and has no default; construction belongs to a public function of session
    let u = session.Session(name = "x", token = 7)   # refused:
    # token of Session is private to session
```

A struct all of whose fields are `pub` constructs from anywhere. A struct
whose private fields all carry defaults constructs outside with its `pub`
fields only. Within the declaring file, nothing changes — every field is
reachable.

Zero values are unchanged: `var s: session.Session` still declares the
zeroed struct, private fields and all. Privacy gates *naming* a field,
not the existence of the value; a module whose invariant cannot survive
the zero value documents its factory.

## Opaque types

A module can export a struct whose shape outsiders cannot see, simply by
exposing the struct and leaving its fields private with no defaults —
this is field privacy composing with the construction rule, not a new
mechanism:

```text
# handle.luc
pub struct Handle:
    slot: i64                       # private, no default: not constructible outside
    generation: i64

pub func fresh() -> Handle:
    return Handle(slot = next_slot(), generation = 1)

pub func alive(h: Handle) -> bool:
    return generation_at(h.slot) == h.generation
```

An importer can hold a `Handle`, pass it back to `handle.alive`, store it
in its own structs, and put it in a `list[handle.Handle]` — and cannot
read `slot`, construct one, or write a field. Methods mean across the
boundary exactly what they mean inside it, because a method's own body
runs in its declaring file, where the fields are visible.

This is *name* hiding, not layout hiding or invariant enforcement — which,
in a language with no reflection and no field iteration, is everything an
importer can observe. A sealed type whose zero value is unreachable is not
part of the language.

## The entry, members, tests, and locals

**`main` never needs marking.** The entry is selected by name in the root
file and called by the runtime — there is no import edge to gate, so the
default (private) is exactly right, and `pub` on `main` is inert-legal. An
imported module's function named `main` is just an ordinary function.

**A test must be `pub`.** `luce test` calls a `pub func test_*()` the way
an importer calls any public function; an unmarked `test_*` is a test that
would never run, and is refused rather than skipped — `test_x is not
public and would never run; mark it pub, or rename it if it is a helper`.
The `test_` prefix says *this is a test*; `pub` says *expose it to the
runner*.

**A member is marked like any declaration.** A private method called from
a `pub` one in the same file is ordinary code; `pub` on a member of a
private struct is legal and inert, because the private struct never
reaches any public surface for an importer to call it on. `deinit` takes
no visibility — it is called only by ARC at the class's last strong
release.

**Locals cannot be marked.** `pub` on a local `let`/`var`, a parameter, or
any statement is a parse error, `visibility applies to file-scope
declarations and struct members`. Visibility is about the module boundary;
there is no smaller boundary for it to mean anything at.

## Privacy gates names, never values

A `pub` constant may be built from private ones, because folding happens
inside the declaring file and what crosses the boundary is the value:

```text
# geo.luc
const seed: i64 = 41              # geo's own business
pub const answer: i64 = seed + 1  # folds to 42 in geo

# main.luc
import geo

func main():
    print(str(geo.answer))      # 42 — the value crossed, not the name
    print(str(geo.seed))        # seed is private to geo
```

The same clause serves parameter defaults: a `pub` function whose default
folds from a private constant is legal, because the caller materialises
the folded value, not the name. The public-surface check does follow a
`pub` constant *container's* element or map-value type — a `pub` `const`
cannot expose a private type through its container — but the folded scalar
value crosses freely.

## Names start with a letter

Independent of visibility but decided beside it: an identifier starts with
a letter. A leading underscore is refused at the lexer with
`luce.lex.name` (`a name starts with a letter: _total is not a name`),
everywhere and for every use. The lone `_` is the array-shape wildcard
(`array[i64, _]`) and declares nothing; using it as a name — `let _ =
f()`, `func _()` — is refused with a sentence teaching the one place `_` is
legal. Interior and trailing underscores are the house style (`word_end`,
`fold_case`) and are untouched.

Privacy is the default and `pub` is its only lever, so a leading
underscore has nothing left to encode as a privacy sigil; refusing it
keeps spelling from growing folklore meanings the compiler does not
enforce.

## Diagnostics

Visibility introduces two diagnostic codes. **`luce.sema.private`** says a
name exists and is withheld — the refusal fires *after* existence is
established, so a genuine typo near a private name still answers
`unknown …` (with visible names only in the did-you-mean), and only a real
reference to a real private name says "private." **`luce.lex.name`** is the
identifier-spelling rule above. The marker parse refusals reuse existing
`luce.parse.*` codes.

| written | code | said |
|---|---|---|
| `geo.helper()`, not `pub` | `luce.sema.private` | `helper is private to geo` |
| `s.fold_case(…)` — the method sugar and the qualified call alike | `luce.sema.private` | `fold_case is private to strings` |
| `geo.seed`, private constant | `luce.sema.private` | `seed is private to geo` |
| `p: geo.Inner`, private struct in an annotation | `luce.sema.private` | `Inner is private to geo` |
| `geo.Inner(…)`, private struct constructed | `luce.sema.private` | `Inner is private to geo` |
| `p.slot`, private field read or written from outside | `luce.sema.private` | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, private field named at construction | `luce.sema.private` | `token of Session is private to session` |
| `session.Session(name = "x")`, required private field, outside | `luce.sema.private` | `Session cannot be constructed here: id is private in session and has no default; construction belongs to a public function of session` |
| `pub func read() -> Inner`, `Inner` private | `luce.sema.private` | `read is public and answers Inner, which is private in this file; remove pub from read or mark Inner pub` |
| `test_x` left unmarked in a test file | `luce.parse.*` | `test_x is not public and would never run; mark it pub, or rename it if it is a helper` |
| `pub let x = 1` inside a function | `luce.parse.*` | `visibility applies to file-scope declarations and struct members` |
| `pub pub func f()` | `luce.parse.*` | `one `pub` per declaration` |
| `pub:` at file scope | `luce.parse.*` | `` `pub` marks one declaration; write it before each name, not as a region `` |
| `static pub func f()` inside a struct | `luce.parse.static` | `visibility comes before static: write 'pub static func', not 'static pub func'` |
| `let _total = 1`, or any `_`-leading word | `luce.lex.name` | `a name starts with a letter: _total is not a name` |
| `let _ = f()` | `luce.parse.*` | `_ is the array-shape wildcard, not a name (array[i64, _]); a binding needs a name` |

Because exposure is always an explicit act, every `luce.sema.private`
traces to the absence of a `pub` someone would have to add — the refusal
teaches the one edit that opens the name.

## The standard library's own surface

The standard library obeys the same rule it imposes, and demonstrates the
discipline: an internal says nothing, everything meant to cross is `pub`.

- `strings` leaves `fold_case`, `is_space_byte`, and its UTF-8 scanning
  helpers private; `find`, `trim`, `lower`, `split`, `join`,
  `format_float`, and the rest are `pub`.
- `math` leaves the constants `ln2`, `ln10` (internals of `log2`/`log10`)
  and the field `Rng.state` private; the generator is constructed through
  its own `init` — `math.Rng(seed)` — never by reaching at the state.
- `files` leaves its mode numbering private. Its `Builtin.NAME` calls are
  not declarations at all: they are a compiler-only capability of embedded
  standard source and cannot enter a program's namespace.

The standing principle behind these calls: an idiom that requires an
internal member to be `pub` is evidence of a missing public constructor or
function, never grounds for exposing the internal — the library gets fixed
instead.

## Where visibility lives

Visibility is resolved during checking (stage 4), exactly where names are
resolved. The parser reserves `pub` and carries a two-state marker
(`private` / `public`, defaulting to `private`) on each declaration and
field. The checker compares modules at each reference site and at the
construction and surface checks. Nothing below stage 4 gains a concept:
the serialized module, MIR, the verifier, the optimizer, `libluce_rt`, and
the interpreter are untouched. An unused private declaration is accepted
silently, exactly as an unused local is — the language has no warnings, and
the optimizer already drops what the entry cannot reach.
