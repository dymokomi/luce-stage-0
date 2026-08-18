# Visibility: `public` and `private`

Every declaration in a Luce file is **public** unless it says `private`.
Visibility controls one thing: what a program in another file may reach
through an `import`. It gates the *reference site's module*, never the
call graph, and it is resolved entirely during checking — nothing about
it survives into the compiled program.

## The rule in one paragraph

A file-scope `func`, `alias`, `const`, `struct`, `interface`, `enum`, or
`union` is public by default; write `private` before it to withhold it from
importers. A struct field is public by default; write `private`
before the field, or place it in a `private:` region, to withhold it. An
`import` binds the module's namespace either way; what it *reaches* is the
module's surface minus everything marked private, and touching a marked
name from another file is `luce.sema.private`, one sentence:
`NAME is private to MODULE`. The unit of visibility is the **file**: a
private declaration is reachable from anywhere in its own file, including
from public declarations — so a file always trusts itself, and privacy
only means "not visible across the module boundary."

## The unit is the file

Luce follows Go's model, not a class-private one: `private` means "this
file," and within a file everything sees everything. A private helper is
reachable from a public function in the same file, a private field is
reachable from a method in the same file, and a private constant folds
into a public one in the same file. The check compares the declaration's
module against the referencing module — both of which the checker already
holds — and fires only when they differ. An unmarked declaration carries
the default and no check ever runs on it.

The same rule governs sibling modules and the standard library alike: the
standard library is ordinary Luce source and obeys every language rule,
so `strings.fold_case` — marked `private` inside `std/strings.luc` — is
refused from any other file exactly as a sibling's private helper is.
There is no standard-library-specific wording.

## Writing the marker

`private` (and, where you want to state the default aloud, `public`) is
written in full — never abbreviated — immediately before the declaration:

```luce
private const scale: i64 = 10
public const limit: i64 = scale * 4
private alias InternalId = i64
public alias UserId = i64

private func helper(x: i64) -> i64:
    return x + scale

func main():
    print(str(limit))
    print(str(helper(2)))
```

Restating the default is legal and inert: `public func f()` where public
is already the default simply asserts what is true. Exactly **one**
visibility word may appear per declaration; a second (`public public`,
`public private`) is a parse error, `one visibility word per
declaration`.

On a struct field, the marker goes on the field's own line:

```text
struct Session:
    name: str
    private id: i64
    private token: i64 = 0
```

### Regions inside struct bodies

Inside a `struct` body — and only there — `private:` and
`public:` open an **indented block** of members, fields and methods
alike, the way every colon in the language opens an indented block. Every
member in the block takes the label's visibility:

```luce
struct Rng:
    private:
        state: i64

    func next() -> i64:
        self.state = self.state * 48271 % 2147483647
        return self.state

    func real() -> f64:
        return f64(self.next()) / 2147483647.0

func main():
    var r = Rng(state = 42)
    print(str(r.real()))
```

Here `state` is private and both methods are public, because they sit
outside the region. Regions are grouping, not state machines: labels may
repeat and appear in any order, members outside any region take the
default, and no region changes the meaning of what follows it. A
per-declaration marker inside a region is refused (`state is inside a
private region, which already says it`) — one way to say a thing, and the
block already said it. An empty region is refused the way every empty
block is, and a region label at file scope is refused with a sentence
pointing at per-declaration keywords: `a visibility region belongs inside
a struct; at file scope mark each declaration`.

Regions are a parser convenience: the parser dissolves each label onto
its members' markers before checking begins, so no later stage ever knows
a region existed. A `private:` region and a per-declaration `private`
produce identical results.

## A public surface names only public types

A public declaration's surface — a function's parameter or result type,
a public field's type, a public constant's type — may name only public
types. Marking a type `private` while leaving a public surface that
mentions it is refused at the declaration:

```luce refused
private struct Inner:
    n: i64

func read() -> Inner:
    return Inner(n = 1)

func main():
    print(str(read().n))
```

```text
read is public and answers Inner, which is marked private in this file;
mark read private or remove the mark on Inner
```

The refusal names both edits that would restore honesty. The common case
— nobody marks anything — is quiet by construction, and this refusal can
only ever land on the author who created the hole: a public surface can
name a private type only because someone marked the type and left the
surface public.

The alternative would let an importer hold a value of a type it cannot
write down — cannot annotate, cannot store in a field, cannot declare a
`var` of. A *private* field's type is not part of the public surface and
may be private; that is what lets an opaque struct hide an
implementation type entirely.

## Construction with private fields

When a struct has private fields, construction from another file
follows three rules:

1. **An outside construction site may name unmarked fields only.** Naming
   a private field — even one with a default — is refused: a default is
   the module's chosen value for a slot the module kept, and overriding it
   from outside is exactly the access privacy removed.
2. **A private field with a default is filled from it, silently.** The
   module decides the value; the outsider does not mention the slot.
3. **A private field with no default makes the struct not constructible
   outside its module.** The diagnostic names the pattern that is: a
   public function of the declaring module — a factory.

```text
# session.luc
struct Session:
    name: str                       # public by default
    private token: i64 = 0            # marked, defaulted: outsiders never say it
    private id: i64                   # marked, required: outsiders cannot build one

func open(name: str) -> Session:
    return Session(name = name, id = next_id())

# main.luc
import session

func main():
    let s = session.open("dy")                  # the factory: compiles
    let t = session.Session(name = "dy")        # refused:
    # Session cannot be constructed here: id is marked private in session
    # and has no default; construction belongs to a public function of session
    let u = session.Session(name = "x", token = 7)   # refused:
    # token of Session is private to session
```

A struct with no marked fields constructs from anywhere exactly as
before. A struct all of whose private fields carry defaults constructs
outside with its unmarked fields only. Within the declaring file, nothing
changes — every field is reachable.

Zero values are unchanged: `var s: session.Session` still declares the
zeroed struct, private fields and all. Privacy gates *naming* a field,
not the existence of the value; a module whose invariant cannot survive
the zero value documents its factory.

## Opaque types

A module can export a struct whose shape outsiders cannot see, simply by
placing its fields in a `private:` region with no defaults — this is field
privacy composing with the construction rule, not a new mechanism:

```text
# handle.luc
struct Handle:
    private:
        slot: i64                 # no default: not constructible outside
        generation: i64

func fresh() -> Handle:
    return Handle(slot = next_slot(), generation = 1)

func alive(h: Handle) -> bool:
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

## The entry, members, and locals

**`main` never needs marking.** The entry is selected by name in the root
file and called by the runtime — there is no import edge to gate.
`public` on `main` is inert-legal; `private` on `main` is refused with its
own sentence, `main is the entry and cannot be private: the runtime starts
it`, because an entry the world cannot start is a contradiction. An
imported module's function named `main` is just an ordinary function.

**A member marked inside a struct** means what a marker means at file
scope: the module is still the unit. A private method called from a public
one in the same file is ordinary code; `public` on a member of a private
struct is legal and inert, because the private struct never reaches any
public surface for an importer to call it on.

**Locals cannot be marked.** `public` or `private` on a local `let`/`var`,
a parameter, or any statement is a parse error, `visibility applies to
file-scope declarations and struct members`. Visibility is about the
module boundary; there is no smaller boundary for it to mean anything at.

## Privacy gates names, never values

A public constant may be built from private ones, because folding happens
inside the declaring file and what crosses the boundary is the value:

```text
# geo.luc
private const seed: i64 = 41      # geo's own business
const answer: i64 = seed + 1      # public by default; folds to 42 in geo

# main.luc
import geo

func main():
    print(str(geo.answer))      # 42 — the value crossed, not the name
    print(str(geo.seed))        # seed is private to geo
```

The same clause serves parameter defaults: a public function whose default
folds from a private constant is legal, because the caller materialises
the folded value, not the name. The public-surface check does follow a
public constant *container's* element or map-value type — a public
`const` cannot expose a private type through its container — but the folded
scalar value crosses freely.

## Names start with a letter

Independent of visibility but decided beside it: an identifier starts with
a letter. A leading underscore is refused at the lexer with
`luce.lex.name` (`a name starts with a letter: _total is not a name`),
everywhere and for every use. The lone `_` is the array-shape wildcard
(`array[i64, _]`) and declares nothing; using it as a name — `let _ =
f()`, `func _()` — is refused with a sentence teaching the one place `_` is
legal. Interior and trailing underscores are the house style (`word_end`,
`fold_case`) and are untouched.

Luce has a real `private` keyword, so the underscore has nothing left to
encode as a privacy sigil; refusing it keeps spelling from growing folklore
meanings the compiler does not enforce.

## Diagnostics

Visibility introduces two diagnostic codes. **`luce.sema.private`** says a
name exists and is withheld — the refusal fires *after* existence is
established, so a genuine typo near a private name still answers
`unknown …` (with visible names only in the did-you-mean), and only a real
reference to a real private name says "private." **`luce.lex.name`** is the
identifier-spelling rule above. The region and marker parse refusals reuse
existing `luce.parse.*` codes.

| written | code | said |
|---|---|---|
| `geo.helper()`, marked private | `luce.sema.private` | `helper is private to geo` |
| `s.fold_case(…)` — the method sugar and the qualified call alike | `luce.sema.private` | `fold_case is private to strings` |
| `geo.seed`, marked constant | `luce.sema.private` | `seed is private to geo` |
| `p: geo.Inner`, marked struct in an annotation | `luce.sema.private` | `Inner is private to geo` |
| `geo.Inner(…)`, marked struct constructed | `luce.sema.private` | `Inner is private to geo` |
| `p.slot`, marked field read or written from outside | `luce.sema.private` | `slot of Handle is private to handle` |
| `session.Session(token = 7)`, marked field named at construction | `luce.sema.private` | `token of Session is private to session` |
| `session.Session(name = "x")`, required marked field, outside | `luce.sema.private` | `Session cannot be constructed here: id is marked private in session and has no default; construction belongs to a public function of session` |
| `func read() -> Inner` public, `Inner` marked | `luce.sema.private` | `read is public and answers Inner, which is marked private in geo; mark read private or remove the mark on Inner` |
| `private func main()` | `luce.sema.private` | `main is the entry and cannot be private: the runtime starts it` |
| `public let x = 1` inside a function | `luce.parse.*` | `visibility applies to file-scope declarations and struct members` |
| `public public func f()` | `luce.parse.*` | `one visibility word per declaration` |
| `private:` at file scope | `luce.parse.*` | `a visibility region belongs inside a struct; at file scope mark each declaration` |
| a per-declaration marker inside a matching region | `luce.parse.*` | `state is inside a private region, which already says it` |
| `let _total = 1`, or any `_`-leading word | `luce.lex.name` | `a name starts with a letter: _total is not a name` |
| `let _ = f()` | `luce.parse.*` | `_ is the array-shape wildcard, not a name (array[i64, _]); a binding needs a name` |

Because privacy is always an explicit act, every `luce.sema.private`
traces to a `private` marker someone wrote — the refusal can cite an
authored line, never an absence.

## The standard library's own surface

The standard library obeys the same rule it imposes, and demonstrates the
discipline: an internal is marked, everything else says nothing.

- `strings` marks `fold_case`, `is_space_byte`, and its UTF-8 scanning
  helpers `private`; `find`, `trim`, `lower`, `split`, `join`,
  `format_float`, and the rest are public.
- `math` marks the constants `ln2`, `ln10` (internals of `log2`/`log10`)
  and the field `Rng.state` `private`; the generator is constructed
  through its own `init` — `math.Rng(seed)` — never by reaching
  at the state.
- `files` marks its mode numbering `private`.
  Its `Builtin.NAME` calls are not declarations at all: they are a
  compiler-only capability of embedded standard source and cannot enter a
  program's namespace.

The standing principle behind these calls: an idiom that requires an
internal member to be public is evidence of a missing public constructor
or function, never grounds for opening the internal — the library gets
fixed instead.

## Where visibility lives

Visibility is resolved during checking (stage 4), exactly where names are
resolved. The parser reserves `public` and `private`, carries a
three-state marker (`none` / `public` / `private`, so restated defaults
survive to be reasoned about) on each declaration and field, and dissolves
struct-body regions onto their members. The checker compares modules at
each reference site and at the construction and surface checks. Nothing
below stage 4 gains a concept: the serialized module, MIR, the verifier,
the optimizer, `libluce_rt`, and the interpreter are untouched. An unused
private declaration is accepted silently, exactly as an unused local is —
the language has no warnings, and the optimizer already drops what the
entry cannot reach.
