# Enums — a name for every number that is secretly a set

Run four of the ratified roadmap (docs/MISSING.md tier 2), and the
substrate for run five: the owner's direction of 2026-08-04 set the
lean — *"Enums lean C: explicit member values (bytes or numbers) when
written, sequential defaults when not"* — and named the three
questions this memo owes answers to: the backing type, the
conversions, and exhaustive dispatch.  **Union follows and is already
ratified tagged** ("Tagged unions obviously"); its payloads will hang
off the machinery this memo builds, so every decision here is taken
with a payload-carrying member in view.

## The evidence

The corpus has been paying for this hole longer than any other:

- `programs/editor.luc:361-405` — key handling as fifteen string
  comparisons in an `elif` chain with no final `else`.  A misspelled
  `"page_dwon"` compiles and silently does nothing; exhaustiveness is
  exactly the property the chain cannot state.
- `programs/editor.luc:189` — `# 1 keyword, 2 type name, 3 builtin,
  0 plain.`  An enum written as a `long` with a comment.
- `src/luce/std/zip.luc` — written *this week*, under the current
  language, by an author trying to use it well: `method == 8` and
  `kind == 2` against numbers whose names live in a spec PDF;
  `Entry.deflated()` exists only because a `long` cannot be matched
  on; the DEFLATE block dispatch is an `elif` chain over `kind` whose
  "unknown kind" arm is a string error the type system could have
  deleted.
- `std.json`, two runs ahead, begins with a tag: a JSON value is one
  of six things, and the union that models it needs an enum to be its
  discriminant.

## The neighbors

**C** gives members names and then spills them into the enclosing
scope, unqualified and colliding; nothing checks a `switch` covers
them.  **Go** declined enums entirely — `iota` makes constants, every
serious Go shop runs a linter that re-invents exhaustiveness, and the
linter cannot see through an `if` — the cautionary tale.  **Zig** is
the closest relative of the owner's lean: `enum(u8)` with explicit
values, sequential defaults, exhaustive `switch` enforced by the
compiler, `@tagName` for the string.  **Rust** and **Swift** both
made the number→enum direction fallible (`TryFrom`, `init?(rawValue:)`)
— the one lesson every post-C language agrees on, because the number
arrives from a file and the file lies.  **Python**'s `Enum` is late
and bolted on, but its `match` statement is the shape a
Python-indented language wants dispatch to look like.

## Decisions (proposed)

| | decision |
|---|---|
| **D1** | **Declaration mirrors struct**: `enum Method:` then one indented member per line, snake_case members under a TitleCase type name.  A member may carry `= value` where value is a constant integer expression (folded by the stage-4 folder, like every top-level constant); an unvalued member takes the previous member's value plus one, and an unvalued first member is 0 — the C rule, verbatim, per the owner's lean.  Two members with one value are refused by name (an alias is a `let` if a program wants one). |
| **D2** | **An enum is a value type at its backing width.**  Default backing is `int`; `enum Method(byte):` picks another rung of the integer ladder (`byte`, `short`, `int`, `long`).  A member value past the backing width is refused at compile time by the sentence literals already get, naming the width that would hold it. |
| **D3** | **Members are namespaced, always**: `Method.stored`, resolved by the head-names-a-declaration rule that already serves `Struct.func` and `module.name`.  Nothing leaks into the enclosing scope — C's one mistake this design does not inherit. |
| **D4** | **No implicit conversion in either direction.**  Enum to number is spelled with the conversion constructors, which accept an enum operand exactly because they are named for what they produce: `int(m)`, `long(m)`.  Number to enum is the fallible direction — see Q2. |
| **D5** | **`string(m)` answers the member's name** — `"stored"` — and an f-string hole follows, because a hole is a `string(...)` the reader did not write.  The name table is interned per program beside the heap-type shapes and handed to `libluce_rt` the same way. |
| **D6** | **Equality only.**  `==` and `!=` compare members; `<` on enums is refused by a sentence naming `int(m)`.  An enum is a set of names, not a number line; code that means the number says the number. |
| **D7** | **Methods and namespace functions, exactly as structs have them** (docs/METHODS.md, rules carried over whole, `var self` included — an enum is a value and writes back by copy like any value).  `zip.Entry.deflated()` becomes `m == Method.deflated` and stops needing to exist; the ones worth keeping keep working. |
| **D8** | **Enum members fold.**  `let default_method = Method.stored` is a top-level constant by construction — a member *is* a constant — and folds anywhere constants fold. |
| **D9** | **Containers hold enums like any scalar**: `list(Method)`, `map(Method, T)`, `array(Method, n)` work by construction, at the backing width, unboxed where scalars are unboxed. |
| **D10** | **In MIR an enum value is its backing integer** and the type table gains an enum row beside the struct layouts; `format_version` bumps.  No new runtime semantic — `libluce_rt` learns only the name table for D5 — so the two engines agree by sharing what they already share.  Exhaustiveness, conversion checking and member resolution are all stage 4. |

## Ratified (owner, 2026-08-06)

All three questions were put to the owner; all three answered with
the memo's recommendation:

| | ruling |
|---|---|
| **R1** | **`match` arrives with enums**, in the restricted form below — bare member arms, optional `else:`, and without `else` every member must appear, so a member added later turns every non-`else` match that misses it into a compile error naming the member.  Union extends this statement with payload bindings rather than introducing a second one. |
| **R2** | **`Method(n)` answers `Method?`.**  Number→enum is the parse case, not the arithmetic case: the value arrives from a file or a wire, and *unknown member* is precisely what the caller must branch on.  The caller writes `else` or narrows, like every other absence. |
| **R3** | **Arms are bare member names** — `stored:`, not `Method.stored:` and not `case stored:`.  The scrutinee's type is known and the arm namespace is closed, so bare names are unambiguous, and union's payload arms will read `circle(r):` under the same form. |

## The questions, as they were argued

**Q1 — does `match` arrive with enums, or wait for union?**  Without
a dispatch statement an enum is `==` chains — better-named numbers,
but the editor's misspelled-key bug survives, because exhaustiveness
is the property an `elif` chain cannot state.  The full statement —
payload bindings, nested patterns — belongs to union's memo.  The
**recommendation** is the restricted form now:

```
match method:
    stored:
        read_stored(entry)
    deflated:
        read_deflated(entry)
```

Arms are member names of the scrutinee's type and nothing else (the
type is known, the namespace is closed, so bare names are
unambiguous); `else:` is allowed; **without `else` every member must
appear**, and a new member added later turns every non-`else` match
that misses it into a compile error naming the member — which is the
entire point.  A duplicate arm is refused.  Union then *extends* this
statement with payload bindings rather than introducing a second one.

**Q2 — the number→enum direction: optional or trap?**  `Method(8)`
reads as a constructor (an enum has no fields, so the call shape is
free).  Two house precedents pull apart: `byte(300)` **traps**
`conversion_range` — a number that had a home and missed it — while
`parse_int("x")` answers **`T?`**, because "not a number" is the same
reason every time and absence carries all the information.  A number
becoming an enum is the parse case, not the arithmetic case: it
arrives from a file, a wire, a spec field, and *unknown member* is
precisely a value the caller must branch on — zip's `method` is the
live example.  **Recommendation: `Method(n)` answers `Method?`**, and
the caller writes `else` or narrows, like every other absence.

**Q3 — the arm spelling in `match`.**  Bare `stored:` (recommended —
the namespace is closed and the indentation already carries the
structure), qualified `Method.stored:` (says more, says it every
line), or Python's `case stored:` (a second keyword carrying no
information the colon does not).  Union's payload arms would read
`circle(r):` under the bare form, which stays clean.

## Where it lands

Stage 2: `enum` (and `match`, under Q1) join the keyword table —
both verified free of use across std and the corpus.  Stage 3: a
declaration form mirroring struct's, member lists with optional
values; the match statement.  Stage 4: the enum table beside the
struct layouts, member resolution through the existing
head-names-a-declaration path, exhaustiveness, conversions, folding.
MIR: a type-table row, values at backing width, `match` lowered to
the compare-and-branch tree LLVM already turns into jump tables;
`format_version` moves.  Engines: nothing new in `libluce_rt` but
the name table; both arms run the same MIR.  Specs: two-engine rows
for dispatch, conversion (both directions, unknown values included),
folding, `string(m)`; refusal rows for duplicate values, oversize
values, missing arms, duplicate arms, ordering.  Site: a tour page
and the reference, fenced and verified, in the same commit.

---

## As built (2026-08-06)

Built the day it was ratified, in one vertical, on both engines.  The
memo left six things open that the code had to decide; each is here
with the reason, and each has a spec.

| | decision, and where it is proved |
|---|---|
| **A1** | **The width travels in the type.**  `types.Type.enumeration` carries the enum-table index *and* the rung of the integer ladder its members are stored at, because every machine question about an enum — what a register holds, what tag it boxes with, how wide an array cell is, whether a constant fits — is a question about that width and nothing else.  `Type.storage()` is the one sentence saying so, and every engine-side switch starts there, which is what lets its arms answer `unreachable, // answered above` honestly rather than growing a case each.  The *name* stays in the table, because a name is not a machine fact.  `types.zig`'s own test pins both halves. |
| **A2** | **The name table is the constant pool.**  D5 said the table would be "handed to `libluce_rt` the same way heap-type shapes are" — but heap-type shapes are not handed to it at all: the runtime is given a zero value and a rank, never a program's tables.  So `string(m)` lowers to the same compare-and-branch tree `match` is, answering a member name interned in the pool like every other string a program spells.  Nothing new in `libluce_rt`, no table of pointers emitted into an artifact and kept honest by something other than the program, and the two engines agree by running the same MIR — which is what D10 was for. |
| **A3** | **An enum's zero is its first declared member.**  D9 wants `array(Method, n)` to work and OWNERSHIP.md S40 gives every late `var` a zero, so a zero there had to be; zero itself would be a number no member need hold, and the one promise an enum makes is that every value of it is a member.  The first member is what a declaration already put first.  `zeroOf`, `Machine.zeroValue` and `zeroField` all read it from the table. |
| **A4** | **The last arm of an exhaustive match is the fallthrough.**  A2's promise spent: with every member named there is no value left for a final comparison to reject, so `match` emits *n-1* tests and no trap.  A hand-made module that puts a number no member holds in an enum register is refused by the verifier (`isMember`), which is where that promise is defended. |
| **A5** | **Every numeric constructor takes an enum**, not only `int` and `long`: `byte(m)` traps `conversion_range` exactly where `byte(300)` would, and `double(m)` answers the member's number.  One rule instead of a table of pairs, which is the shape `lowerConvert` already gives the seven numeric types.  The MIR is one `convert` whose operand is enum-typed; the verifier admits same-width only from an enum, where the conversion's whole content is the type it lands in. |
| **A6** | **An `else` that covers nothing is refused** — the sentence `a else b` already gets when `a` is never absent.  An arm that catches nothing today would quietly catch the member somebody adds tomorrow, which is the exact mistake a checked `match` exists to make impossible. |

**One place D9's letter did not survive contact**: a map may not be
*keyed* by an enum.  Map keys are `long` or `string` and always have
been — `map(int, V)` is refused the same way — because `hashOf` and
`keyEquals` in `libluce_rt` read exactly those two payloads, and
teaching them a third is the new runtime semantic D10 rules out.  A
`list(Method)`, a `map(K, Method)`, an `array(Method, n)` and a struct
field all hold members as D9 says; the key position refuses one by
name, and the sentence offers `long(m)` and a list indexed by `int(m)`.
It is the narrower reading of "like any scalar" — no scalar but `long`
and `string` may be a key either.

Two smaller calls: an enum member takes no visibility marker (a member
is what the type *is*, and a match arm cannot name one the file it
stands in cannot see — the marker on the *declaration* withholds the
whole set); and `Method(n)` does not fold in constant position,
because it answers `Method?` and a constant is always there — the
refusal names the member the reader wanted.

`format_version` moved to 28, and the wire fingerprint now hashes the
type tags as well as the instruction set: a type travels as its tag's
ordinal, so adding one renumbers the wire while the instruction set
does not move an inch.  That gap was open until this run found it.

The corpus paid for itself immediately.  `std.zip` reads a compression
method through `Method(n)` and dispatches on it, and inflate's
four-way `elif` chain over BTYPE — whose last arm existed only to say
"unknown kind" — became three arms and no else.  Both enums are
private to the module, so zip's published surface did not move and
every zip spec passed untouched.

## SELF syntax update — 2026-08-08

D7 now follows `docs/SELF.md`: every plain enum member function is a
method with implied self, and a namespace member says `static func`.
Whether a method writes the enum receiver is inferred; a writer needs a
bare mutable binding and replaces that enum value in place.  Methods
cannot be values, spawned, or called through the enum type; static
members can.
