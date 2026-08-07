# What Luce could mean by "one of these"

> **This is research, not a decision, and it must not be read as one.**
> `union` is run five of the ratified roadmap and its *one* deciding
> question is already answered — the owner, 2026-08-04: *"Tagged unions
> obviously"* (`docs/MISSING.md` Tier 2).  Everything else about it is
> open, and this file gathers rather than rules.  It surveys how the
> field does sum types and pattern matching, prices each shape against
> the invariants Luce has already ratified, recommends where there is
> one honest answer, and ends with the questions that genuinely need
> the owner.  **Every fenced block in it is `text`**: these are
> sketches of syntax that does not exist, and `tools/doccheck.zig`
> would be right to refuse them as Luce.

The occasion is `docs/ENUMS.md`, which is being built as this is
written.  That memo took every decision *"with a payload-carrying
member in view"* and handed three of them forward: members are
namespaced (`Method.stored`, D3), a `match` statement arrives with
enums in a restricted form (R1), and its arms are **bare member
names** — *"union's payload arms will read `circle(r):` under the same
form"* (R3).  So union does not get to choose a dispatch statement; it
gets to extend one.  What it must choose is what a member may carry,
what carrying it means for memory, and what binding it in an arm means
for ownership.

Two customers are waiting, and they ask for different things.

**`std.json` is the motivating one.**  A JSON value is one of six
things — null, bool, number, string, array, object — and two of those
six are heap objects that contain more JSON values.  It is therefore
the recursion case and the payload-ownership case at once, and it is
the program that will decide whether the design is honest.

**`std.zip` is the dogfooding one**, written this week under the
current language by an author trying to use it well, and it names two
pressures that are not the same pressure:

- **Sum-typed errors.**  Forty `error(...)` sites in 828 lines, every
  one of them collapsing into `user_error` plus a sentence
  (`docs/FAILURE.md` allows exactly two codes, `io_failed` and
  `user_error`).  They fall into five families a caller might actually
  branch on — *truncated / not an archive*, *unsupported* (encrypted,
  method 12), *corrupt* (over-subscribed table, failed CRC), *refused
  by our own limits* (name too long, more than 65535 entries), and
  *not text*.  A `catch` today can read the message and nothing else,
  by design (`docs/FAILURE.md`: *"`reason` is a `string`, and the code
  and the origin are not in it"*).
- **Aggregates that cannot be written back.**  `zip.luc:507` declares
  `struct Stream: private position: long` with the comment *"It
  carries no objects, which is what lets every method write the
  advanced cursor back through `var self`"* — `docs/METHODS.md`'s
  restriction, inherited from S17 and S28.  The consequence is
  visible three functions down: a canonical Huffman table is a
  `counts`/`symbols` pair of `list(long)`, and it is threaded through
  every call as two parameters rather than one name.
  `Stream.codes(var self, data, out, lit_counts, lit_symbols,
  dist_counts, dist_symbols)` is seven parameters where four would do.
  **That is not a union pressure** — a struct would fix it — but it is
  the wall a union with object-carrying members walks straight into,
  and §Q3 is where it lands.

---

## 1. What union would be walking into

Nine facts about this tree, each with the file that holds it.  Every
design below is priced against these and nothing else.

**1.1 The dispatch statement is already specified, and it is not
union's to design.**  `docs/ENUMS.md` R1: bare member arms, `else:`
optional, and *"without `else` every member must appear, so a member
added later turns every non-`else` match that misses it into a compile
error naming the member."*  R3 fixes the spelling: `stored:`, not
`Method.stored:` and not `case stored:`.  Union extends this
statement; it does not introduce a second one.

**1.2 Values copy, objects are owned by scope, and there is no
automatic memory manager — permanently.**  `docs/OWNERSHIP.md`'s
vocabulary is the whole of it: an **object** is a `list`, `map`,
`array` or `builder`; everything else — scalars, `string`, structs —
is a **value**, *"copied freely, never freed by the program"*.
`docs/MEMORY.md` closes the door on the alternative in the strongest
terms the project uses: *"Reference counting is absent, at every
layer: not in the language, not in the runtime, not behind values.
Scope ownership is the whole story, and anything that reclaims memory
does it because a scope ended, not because a counter reached zero."*

**1.3 A struct value is already an out-of-line, exclusively-owned,
deep-copied and deep-freed field run.  This is the single most
important fact in this document.**  `runtime/value.zig`: `strukt` is a
tag whose *"`bits` addresses `length` fields"*, and *"struct storage is
never mutated in place — `struct_set` allocates a fresh array — so
sharing one array between copies is safe."*  On the compiled path the
same thing: `08_llvm/lower.zig:349` maps `.strukt => .ptr`.  The
copy and the free already exist and are already recursive —
`runtime/heap.zig`'s `ownValue` walks a struct's fields and duplicates
each one's storage, and `dropStorage` walks them and frees each one's,
both stopping dead at object handles because *"objects are left alone:
they have their own death point, and a struct copy shares them"* (S26).
**So Luce already boxes; it simply never had to say so.**  What Rust
spells `Box` and OCaml gets from its collector, this tree has as
`Memory.objects` — *"an ordinary freeing allocator"* — plus one owner
per allocation and a static death point.

**1.4 Recursion in value types is a solved problem, and the solution is
`?`.**  `docs/LANGUAGE.md`: *"A struct field typed `Struct?` is how a
value struct holds one of itself: the recursion stops at absence
rather than at a layout, so a linked list of value structs needs no
new machinery and no reference counting."*  The rule behind it is
stated at two scales in `04_semantics/helpers.zig`: *"a struct's
**unconditional** expansion must be finite, and small"* — 4096 values
— and *"an optional field counts as one whatever it holds, because its
payload starts absent and arrives only when a program builds one."*
A struct that contains itself unconditionally is refused for being
infinite; `?` is what turns "must hold" into "may hold".

**1.5 `T?` and `T!` are not the same kind of thing, and neither is a
sum type today.**  `T?` **is** a `types.Type` arm — `optional:
Payload`, where `Payload` is *"a union of its own rather than a
`*Type`, so `T??` and `None?` are unrepresentable rather than merely
refused"*.  `T!` is **not a type at all**: `docs/FAILURE.md` is
explicit — *"`T!` is not a type — fallibility is a function
attribute"* — and `docs/MISSING.md` records that this survived
contact: *"`T!` really did leave `types.Type` untouched — fallibility
is a bool on `mir.Function`, and not one `Type` switch grew an arm."*
`T?` is also *narrowed*, not matched: five flow-sensitive shapes make
the name *be* its payload, with **no unwrapping operator and no second
spelling** (`docs/LANGUAGE.md`).

**1.6 `types.Type` is a closed union with a great many exhaustive
switches over it, and the house style forbids `else` arms on them.**
`docs/MISSING.md` Tier 4 calls it *"a closed union with twenty
exhaustive switches depending on it"*; `docs/TYPES.md` §11 counted
*"roughly 55–65 switch sites — about 35 of them in `lower.zig`"* when
seven numeric types landed, and notes that this is a **feature**: the
Zig compiler enumerates every site rather than letting one fail
silently.  A union type would be a `strukt`-shaped arm — an index into
a per-program table — which is the cheapest possible way in.

**1.7 The two predicates that drive ownership are already the right
shape for a union.**  `04_semantics/declarations.zig`:
`carriesObjects` is `true` for `.heap`, the *shape's* `carries` flag
for `.strukt`, and recurses through `.optional`; `ownsStorage` is
`true` for `.string` and `.strukt` — *"a struct owns its field run
whatever is in it"* — and recurses through `.optional`.  A union
would answer `ownsStorage = true` (it has a payload run) and
`carriesObjects = OR over its members`.  §Q3 is entirely about what
that OR costs.

**1.8 There are no generics, no first-class functions and no tuples,
and each absence was argued rather than deferred.**  `docs/MISSING.md`
Tier 4: *"`types.Type` is a closed union with twenty exhaustive
switches depending on it, and `list(T)` is a monomorphic heap object
rather than a generic. `T?` did become a variant of `Type` — one,
whose payload is a union of its own so `T??` is unrepresentable — and
it opened no door at all: nothing about it generalizes."*
`docs/RETURNS.md` is the tuple refusal and its reasoning is the one
this memo inherits most directly: *"Adding an anonymous product type is
not adding a feature; it is adding the *first* structural type, and
every structural type asks the same follow-up questions: does it nest,
can a `list` hold one, does it compare, does it have a `len`."*

**1.9 Two engines share one implementation of every semantic, and the
specs are a comparison.**  `libluce_rt` is the semantics;
`interpreter/machine.zig` keeps *"only the dispatch loop, the frame
stack, the traceback, and host effects"*; `specs/agree.zig` runs every
spec program on both and compares prints, trap code, trap message,
call trace frame for frame, **leak census** and the world left behind.
For a memory feature that is the strongest tool in the tree: a payload
that leaks or double-frees shows up as a number.

**And the version surfaces, so nothing is guessed.**
`06_mir/module.zig` `format_version` is **27**; `08_llvm/abi.zig`
`version` is **11**.  `enum`, `match` and `union` are **not** in
`02_lex/token.zig`'s 28 keywords as this is written, which is the
literal sense in which none of this exists yet.

---

## 2. The field

Seven readings, each for one question: **what did this language pay,
and in what currency?**  Every claim carries its source, because a
research memo whose facts about other languages cannot be checked is
one that cannot be trusted about its own.

### 2.1 OCaml, Haskell, Standard ML — the original shape, and what boxing buys

**The declaration is two forms in one.**  OCaml's manual states it
exactly: *"The constructor declaration `constr-name of typexpr₁ * … *
typexprₙ` declares the name `constr-name` as a non-constant
constructor, whose arguments have types `typexpr₁ …typexprₙ`.  The
constructor declaration `constr-name` declares the name `constr-name`
as a constant constructor"*
([typedecl](https://ocaml.org/manual/5.2/typedecl.html)) — so a
payload-less member is not a second concept, it is a constructor with
no `of`.  Haskell's grammar says the same with `constr → con [!]
atype1 … [!] atypek (arity con = k, **k ≥ 0**)`
([Report 2010, §4.2.1](https://www.haskell.org/onlinereport/haskell2010/haskellch4.html)).

**Named payloads arrived later, and the reason is boxing.**  OCaml
4.03 added *inline records*: *"The arguments of sum-type constructors
can now be defined using the same syntax as records"*, with the
restriction that carries the whole point — *"the record cannot escape
the scope of the binding and can only be used with the dot-notation to
extract or modify fields or to build new constructor values"*, and the
error is *"This form is not allowed as the type of the inlined record
could escape"*
([inlinerecords](https://ocaml.org/manual/5.2/inlinerecords.html)).
The record cannot escape **because there is no separate record block to
hand out**: the fields live in the constructor's own block.  Haskell's
record syntax has the opposite property and it is a known wart —
*"Field names share the top level namespace with ordinary variables and
class methods and must not conflict with other top level names in
scope"* (Report §4.2.1).  Two data points, one lesson: **payload field
names should be scoped to the member, not to the file.**

**The representation is the finding.**  OCaml's C-interface chapter
states the layout without ceremony: a constant constructor is
*"represented by the unboxed integer equal to its constructor number"*;
a non-constant one is *"represented by a block of size n, tagged with
the constructor number; the n fields contain its arguments"*; and
*"the constant constructors and the non-constant constructors for a
given concrete type are numbered separately, starting from 0, in the
order in which they appear"*
([intfc](https://ocaml.org/manual/5.2/intfc.html)).  So an
all-constant variant costs **nothing** and any payload costs **one
heap block**.  The escape from that is deliberately tiny:
`[@unboxed]` may be used *"on a type definition if the type is a
single-field record or a concrete type with a single constructor that
has a single argument"*
([attributes](https://ocaml.org/manual/5.2/attributes.html)) — one
constructor, one field, and no general layout-control surface.  GHC's
`{-# UNPACK #-}` is the same lesson from the other side: it *"removes
a level of indirection"* but *"may not always be an optimisation"* and
*"has no effect without `-O`"*
([GHC pragmas](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/pragmas.html)).

**And recursion is free precisely because of that boxing.**  OCaml's
own tutorial writes `type 'a btree = Empty | Node of 'a * 'a btree *
'a btree` and calls it *"the most common usage of variant types"*
([coreexamples](https://ocaml.org/manual/5.2/coreexamples.html)).  No
indirection is written because `Node` *is* a block and a collector
reclaims it.  **Remove either half and the syntax stops meaning what it
means** — which is the sentence to carry into §Q8.

**Exhaustiveness is a warning, and the Definition of Standard ML says
so on purpose.**  SML §4.11: *"In the context `fn match`, the match
must also be exhaustive… **The compiler must give warning on violation
of these restrictions, but should still compile the match.**"*
([Definition, revised](https://smlfamily.github.io/sml97-defn.pdf)) —
and §6.5 adds that *"the exception `Match` can only be raised for a
match which is not exhaustive, and has therefore been flagged by the
compiler."*  OCaml inherits it: warning 8, *"Partial match: missing
cases in pattern-matching"*, on by default and non-fatal by default —
*"The default setting is `-warn-error -a` (no warning is fatal)"*
([comp](https://ocaml.org/manual/5.2/comp.html)).  GHC is worse:
`-Wincomplete-patterns` is **not** in the default set —
*"This option isn't enabled by default because it can be a bit noisy,
and it doesn't always indicate a bug in the program"*
([GHC warnings](https://downloads.haskell.org/ghc/latest/docs/users_guide/using-warnings.html)).

**Why the ML family warns rather than errors is a cost that Luce does
not have.**  GHC's checker assigns symbolic models per pattern and
*"can be exponential in the arity of the pattern and in the number of
guards in some cases"*, which is why `-fmax-pmcheck-models` exists with
a default of 30 (same page).  A checker over **flat member arms with no
guards and no nested patterns is linear**, which is the whole reason
`docs/ENUMS.md` R1 can make missing arms a compile error where four
older languages could only warn.

**And the structural alternative is priced.**  OCaml's polymorphic
variants are the closest thing the field has to an anonymous sum type,
and the manual is candid: *"More important is the fact that polymorphic
variants, while being type-safe, result in a weaker type discipline"*,
*"you must be more careful about making types explicit"*, and *"beware
also that some idioms make trivial errors very hard to find"*
([polyvariant](https://ocaml.org/manual/5.2/polyvariant.html)).
*Real World OCaml* lists three downsides by name — **complexity**
(*"the typing rules for polymorphic variants are a lot more complicated
than they are for regular variants"*), **error-finding** (*"the typing
discipline that they impose is, by dint of its flexibility, less likely
to catch bugs in your program"*) and **efficiency** (*"OCaml can't
generate code for matching on polymorphic variants that is quite as
efficient"*) — and concludes *"In reality, regular variants are the more
pragmatic choice most of the time"*
([RWO, Variants](https://dev.realworldocaml.org/variants.html)).
A language with no inference to speak of cannot pay the first cost
because it cannot have the mechanism; **nominal is the only shape on
the table, and that is a relief rather than a limitation.**

**One thing the ML family gives up, and it should be named.**  Wadler's
statement of the expression problem is the citation: *"The goal is to
define a datatype by cases, where one can add new cases to the datatype
and new functions over the datatype, without recompiling existing code,
and while retaining static type safety"*
([Wadler, 1998](https://homepages.inf.ed.ac.uk/wadler/papers/expression/expression.txt)).
Sum types make adding a *function* cheap and adding a *case* expensive.
For an AST, a token, a key event or a JSON value — a fixed set of cases
per program — that is the right side of the trade, and Luce's corpus is
entirely such programs.

### 2.2 Rust — payload ownership done properly, and a decade of ergonomics debt

**Declaration.**  The Reference is explicit that a variant is a
constructor, not a type: *"An enumeration… is a simultaneous definition
of a nominal enumerated type as well as a set of constructors"*, and
*"Enum constructors can have either named or unnamed fields"*
([enumerations](https://doc.rust-lang.org/reference/items/enumerations.html)).
A payload-less member is not special-cased in the grammar — *"an enum
where no constructors contain fields is called a field-less enum"* —
and it is worth noticing that `Tuple()` is field-less but not
*unit-only*, so Rust already needs two predicates where a
smaller language needs none.

**Construction, and why the positional form is not available to Luce.**
*"Each variant defines its type in the type namespace, though that type
cannot be used as a type specifier.  Tuple-like and unit-like variants
also define a **constructor in the value namespace**"* — and the
function-item page confirms what that means: *"the constructor of a
tuple-like struct or enum variant, yields a zero-sized value of its
function item type"*
([function-item](https://doc.rust-lang.org/reference/types/function-item.html)).
`Some` is a callable.  Meanwhile the **struct-expression** form
generalises over all three variant kinds: `UnitLike {}`, `TupleLike {
0: 123 }`.  So the named form is the general one and the positional
form is the one that needs function values — which
`docs/MISSING.md` Tier 4 does not have.

**Exhaustiveness is an error and the diagnostic names the missing
case.**  E0004: *"This error indicates that the compiler cannot
guarantee a matching pattern for one or more possible inputs to a match
expression"*, and the Book's sentence is the one everybody quotes:
*"Matches in Rust are exhaustive: We must exhaust every last
possibility in order for the code to be valid"*
([E0004](https://doc.rust-lang.org/error_codes/E0004.html),
[Book 6.2](https://doc.rust-lang.org/book/ch06-02-match.html)).  The
message reads `error[E0004]: non-exhaustive patterns: 'None' not
covered`.  That is exactly the shape `docs/ENUMS.md` R1 ratified.

**Ownership at match time is where the decade went.**  The rule as
written: *"By default, identifier patterns bind a variable to a copy of
or move from the matched value depending on whether the matched value
implements `Copy`"*, changed by `ref`/`ref mut`, and modulated by a
hidden **default binding mode** that *"starts in 'move' mode"* and is
mutated as the pattern descends — *"each time a reference is matched
using a non-reference pattern, it will automatically dereference the
value and update the default binding mode"*
([patterns](https://doc.rust-lang.org/reference/patterns.html)).  So
whether `Some(x)` moves or borrows depends on three things, **none of
which is written at the binding site**: whether the payload is `Copy`,
whether the scrutinee is a place expression, and how many references
the pattern has walked through.

Mixing modes gives a **partial move** — *"parts of the variable will be
moved while other parts stay… the parent variable cannot be used
afterwards as a whole"*
([RBE](https://doc.rust-lang.org/rust-by-example/scope/move/partial_move.html))
— and reading a payload out of a borrow is E0507, whose enum-flavoured
form is literally *"cannot move out of `self.x` as enum variant `Some`
which is behind a shared reference"*
(`rustc_borrowck/src/diagnostics/move_errors.rs`).

**The bill.**  RFC 2005 introduced default binding modes because
*"getting the correct combination of `*`, `&`, and `ref` to satisfy the
type and borrow checkers is a common problem, and one which is often
encountered early by Rust beginners"*, and because *"the `ref` keyword
is a pain for Rust beginners, and a bit of a wart for everyone else"*
([RFC 2005](https://rust-lang.github.io/rfcs/2005-match-ergonomics.html)).
Seven years later RFC 3627 had to undo three of its consequences —
*"`mut` resets the binding mode to by-value, which users do not
expect"*; *"users have no general mechanism to 'cancel out' an
inherited reference"*; *"adding a single `&` to the pattern can remove
two `&`s from the type of the binding"*
([RFC 3627](https://rust-lang.github.io/rfcs/3627-match-ergonomics-2024.html))
— shipping as an edition break with a lint and `cargo fix --edition`
([edition guide](https://doc.rust-lang.org/edition-guide/rust-2024/match-ergonomics.html)).
**Every one of those mechanisms exists because a Rust payload binding
may be the payload itself rather than a copy of it.**

**Layout: unspecified on purpose, with one guarantee.**  The
Rustonomicon states the classic case — *"an enum consisting of a single
outer unit variant (e.g. `None`) and a (potentially nested)
non-nullable pointer variant (e.g. `Some(&T)`) makes the tag
unnecessary… `size_of::<Option<&T>>() == size_of::<&T>()`"* — and
argues that *"it is especially desirable that we leave enum layout
unspecified today"*
([nomicon](https://doc.rust-lang.org/nomicon/repr-rust.html)).  The
Reference's tagged-union model appears only under `repr(C)`: *"a
`repr(C)` struct with two fields… 'the tag'… 'the payload'"*
([type layout](https://doc.rust-lang.org/reference/type-layout.html)).
The Book states the size rule in prose: *"the most space a `Message`
value will need is the space it would take to store the largest of its
variants"*
([Book 15.1](https://doc.rust-lang.org/book/ch15-01-box.html)).

**Recursion: the user's problem, and the compiler names the fix.**
*"A value of a recursive type can have another value of the same type
as part of itself… Rust needs to know at compile time how much space a
type takes up"*, and E0072 is the refusal: *"any use of the type being
defined from inside the definition must occur behind a pointer (like
`Box`, `&` or `Rc`)"*
([E0072](https://doc.rust-lang.org/error_codes/E0072.html)).  The
diagnostic reads `recursive without indirection` with
`help: insert some indirection (e.g., a 'Box', 'Rc', or '&') to break
the cycle`.  **Rust refuses to insert indirection silently**, and the
payoff is that `Box<List>` is visibly an owned heap pointer that
participates in ownership and drop like anything else.

**Generics are load-bearing to the ergonomics, and this matters.**
`?` needs `From`: *"error values that have the `?` operator called on
them go through the `from` function, defined in the `From` trait"*, and
*"we're only allowed to use the `?` operator in a function that returns
`Result`, `Option`, or another type that implements `FromResidual`"*
([Book 9.2](https://doc.rust-lang.org/book/ch09-02-recoverable-errors-with-result.html)).
The chain is `?` → `FromResidual`/`Try` → `From` → generic
`Result<T, E>`.  **A language with no generics and no traits gets a
shape for domain sum types out of an enum feature, and gets none of
`Option`, `Result`, `?`, or `From`-based error widening.**  Luce
already answered those with `T?` and `T!` as *language* features, which
is precisely the design that survives the absence of generics.

**And the open want.**  RFC PR 2593 asks that variants be types in
their own right, naming the three workarounds users write instead:
passing a known variant and matching with `unreachable!()` arms;
passing individual fields; duplicating the variant as a standalone
`struct`.  It was **postponed**, not rejected
([rust-lang/rfcs#2593](https://github.com/rust-lang/rfcs/pull/2593)).
Three separate attempts at *anonymous* sum types
([#402](https://github.com/rust-lang/rfcs/pull/402),
[#1154](https://github.com/rust-lang/rfcs/pull/1154),
[#2587](https://github.com/rust-lang/rfcs/pull/2587)) all failed on
*"complexity associated with these extra features as well as possible
ambiguities and undesired interactions"*.

### 2.3 Swift — value semantics make binding trivial, and `indirect` hides a refcount

**Value semantics is the whole story for pattern binding.**  *"All
structures and enumerations are value types in Swift"*, and value types
*"are always copied when they're passed around in your code"*
([TSPL, Classes and
Structures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures)).
So `case .circle(let r)` binds a **copy** — no `ref`, no binding mode,
no partial move — and the specification of pattern binding is an order
of magnitude shorter than Rust's.  Both spellings exist, `case
.upc(let a, let b)` and `case let .upc(a, b)`, the second permitted
*"if all of the associated values for an enumeration case are extracted
as constants, or if all are extracted as variables"*
([TSPL, Enumerations](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations)).

**Labelled payloads are real but come from the proposal, not the
book.**  SE-0155: *"In Swift 3, associated values of an enum case are
represented by a tuple.  This implementation causes inconsistencies in
case declaration, construction and pattern matching"*, resolved by
*"associated values' labels should be part of the enum case's
constructor name"*
([SE-0155](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0155-normalize-enum-case-representation.md)).
The correction it made — from tuple to named argument list — is the
same correction §Q1 recommends taking on day one.

**`indirect` is the recursion answer and its cost is exactly the thing
Luce has refused.**  *"A recursive enumeration is an enumeration that
has another instance of the enumeration as the associated value for one
or more of the enumeration cases.  You indicate that an enumeration
case is recursive by writing `indirect` before it, **which tells the
compiler to insert the necessary layer of indirection**"*, with the
rules *"an indirect case must have an associated value"* and *"to
support recursion, the compiler must insert a layer of indirection"*
(TSPL Enumerations and Declarations).  A value-semantics type over a
shared heap box requires either a reference count or a deep copy;
Swift's SIL box is documented as *"a reference-counted `@box` on the
heap"*
([SIL Instructions](https://github.com/swiftlang/swift/blob/main/docs/SIL/Instructions.md)),
though no Swift document states in so many words that `indirect` is
refcounted.  **The fork is clean: explicit boxed recursion (Rust) or a
compiler-inserted refcounted box (Swift), and `docs/MEMORY.md` closes
one of the two doors permanently.**

**Exhaustiveness, and the one cost Luce structurally cannot incur.**
*"Every `switch` statement must be exhaustive"* (TSPL, Control Flow).
But SE-0192 had to weaken it across library boundaries: *"adding a new
case to an enum is a source-breaking change"*, *"library authors must
have a way to add new cases to enums without breaking binary
compatibility"*, so `@unknown default` was introduced and *"the
compiler will produce a **warning** if all known elements of the enum
have not already been matched… This is a warning rather than an error
so that adding new elements to the enum remains a source-compatible
change"*
([SE-0192](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0192-non-exhaustive-enums.md)).
**Exhaustiveness and independent library evolution are directly
opposed, and Swift resolved it with two flavours of enum and a
warning-shaped escape hatch.**  Luce compiles whole programs from
source with no stable ABI for user types, so it can make exhaustiveness
an error, always, with no `@unknown` and no `@frozen`.  That is a real
*non-cost* and worth recording as one.

**The reflection hole to design around.**  `CaseIterable` is
synthesized *"if and only if… the enum contains only cases without
associated values"*
([SE-0194](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0194-derived-collection-of-enum-cases.md)),
because once a case carries a payload, "all cases" is no longer a
finite set of *values* — only of *tags*.  Swift never shipped a way to
name the tags separately, and the request recurs.  §Q1's tag-reuse
question is the same hole, seen before it is dug.

**Layout is specified, in five strategies, because the ABI is
stable.**  `docs/ABI/TypeLayout.rst`: *"In laying out enum types, the
ABI attempts to avoid requiring additional storage to store the tag for
the enum case.  The ABI chooses one of five strategies"* — empty,
single-case (*"the enum type has the exact same layout as its case's
data type"*), C-like (*"an integer tag with the minimal number of bits
to contain all of the cases"*), single-payload (*"if the data type's
binary representation has **extra inhabitants**… they are used to
represent the no-data cases"*, else *"a tag bit is added"*), and
multi-payload (*"the ABI will first try to find common **spare
bits**"*, else *"additional bits are added"*)
([TypeLayout.rst](https://github.com/swiftlang/swift/blob/main/docs/ABI/TypeLayout.rst)).
Swift *had* to write this down; Rust deliberately did not.  A language
that compiles whole programs can take Rust's freedom and implement
something near Swift's table whenever it wants to.

### 2.4 Zig — the closest sibling, and the two answers it gives that Luce cannot take

**Declaration, both forms.**  *"Unions can be declared with an enum tag
type.  This turns the union into a tagged union, which makes it
eligible to use with `switch` expressions"*, and *"unions can be made
to infer the enum tag type"* — the two spellings being
`union(ComplexTypeTag)` over a declared enum and `union(enum)` with the
tag inferred, where *"void can be omitted when inferring enum tag
type"* so a payload-less member is written bare
([langref 0.16.0, Tagged
union](https://ziglang.org/documentation/0.16.0/#Tagged-union)).

**Tag reuse has three rules and a scar, and none of the rules is in the
language reference.**  `src/Sema.zig` enforces them with three
diagnostics: `no field named '{f}' in enum '{f}'`, `enum field(s)
missing in union` with a note `field '{f}' missing, declared here`, and
— under the comment *"Enforce the enum fields and the union fields
being in the same order"* — `union field '{f}' ordered differently than
corresponding enum field`.  That third rule exists because a version
without it **miscompiled**: *"This only occurs because the enum/union
field names *match* and are in *a different order*"*
([ziglang/zig#12543](https://github.com/ziglang/zig/issues/12543)).

**The untagged escape hatch, and why it is refused here.**  *"A bare
union defines a set of possible types that a value can be as a list of
fields.  Only one field can be active at a time.  The in-memory
representation of bare unions is not guaranteed…  Accessing the
non-active field is safety-checked Illegal Behavior"*
([union](https://ziglang.org/documentation/0.16.0/#union)), reported as
`error: access of union field 'float' while field 'int' is active` at
compile time and the same sentence as a panic at run time — *"This
safety is not available for `extern` or `packed` unions"*
([Wrong Union Field
Access](https://ziglang.org/documentation/0.16.0/#Wrong-Union-Field-Access)).
And the check is **mode-dependent**: *"safety checks are disabled by
default in the `ReleaseFast` and `ReleaseSmall` optimization modes…
When safety checks are disabled, Safety-Checked Illegal Behavior
behaves like Unchecked Illegal Behavior"*
([Illegal
Behavior](https://ziglang.org/documentation/0.16.0/#Illegal-Behavior)).
**`docs/MODES.md` forbids exactly that**: *semantics are identical in
both modes — safety is the language, never a mode*.  The owner's
"tagged unions obviously" is the same ruling arrived at from the front.

**`switch` captures, and the sharp edges.**  `.ok => |value|` by value,
`|*value|` by pointer — *"in order to modify the payload of a tagged
union in a switch expression, place a `*` before the variable name"* —
plus a second capture for the tag, `|_, tag|`.  Exhaustiveness is an
error: *"When a switch expression does not have an `else` clause, it
must exhaustively list all the possible values.  Failure to do so is a
compile error"*, reading `error: switch must handle all possibilities`
with `note: unhandled enumeration value: 'off'`
([Exhaustive
Switching](https://ziglang.org/documentation/0.16.0/#Exhaustive-Switching)).
The edges are worth knowing before designing arms: a capture on a
**non-inline `else`** binds the whole union rather than a payload, and
the reporter of
[#18151](https://github.com/ziglang/zig/issues/18151) concluded *"maybe
these non-inline else captures should be removed as they can be
misleading and are a duplicate of the switch target"*; and a pointer
capture spanning **several tags** has no single tag, which is
[#15504](https://github.com/ziglang/zig/issues/15504) —
*"`hello` has changed from `U.b` to `U.a`, but only the payload should
have been modified."*

**Layout: nothing is guaranteed, deliberately.**  There is no "size of
a union" clause in the reference at all; `extern union` is *"guaranteed
to be compatible with the target C ABI"* and `packed union` has
*"well-defined in-memory layout"* with *"all fields… the same
`@bitSizeOf`"* — and neither may carry a tag (`{t} union does not
support enum tag type`).  **Tagged and laid-out are mutually exclusive
axes in Zig.**

**`?T` is a built-in, not a union, in a language that has generics.**
*"Null references are the source of many runtime exceptions… Zig does
not have them.  Instead, you can use an optional pointer.  This
secretly compiles down to a normal pointer, since we know we can use 0
as the null value"*, and the guarantee is stated: *"An optional pointer
is guaranteed to be the same size as a pointer.  The null of the
optional is guaranteed to be address 0"*
([Optionals](https://ziglang.org/documentation/master/#Optionals),
[Optional
Pointers](https://ziglang.org/documentation/master/#Optional-Pointers)).
Zig **could** have written `Optional(T)` with comptime generics and did
not, because only a built-in can promise that layout.  §Q5 rests on
this.

**Error sets: a sum-typed error channel with no type parameters at
all.**  *"An error set is like an enum.  However, each error name across
the entire compilation gets assigned an unsigned integer greater than
0.  You are allowed to declare the same error name more than once, and
if you do, it gets assigned the same integer value"*; the type
*"defaults to a u16"*; *"you can coerce an error from a subset to a
superset"* but not the reverse; and `||` merges two sets — *"the Zig
standard library uses `LinuxFileOpenError || WindowsFileOpenError` for
the error set of opening files"*
([Error Set
Type](https://ziglang.org/documentation/master/#Error-Set-Type),
[Merging Error
Sets](https://ziglang.org/documentation/master/#Merging-Error-Sets)).
Errors are **interned names with global integers, not types** — a sum
type with subtyping and no generics.  The price is inference: *"when a
function has an inferred error set, that function becomes generic and
thus it becomes trickier to do certain things with it, such as obtain a
function pointer, or have an error set that is consistent across
different build targets.  Additionally, **inferred error sets are
incompatible with recursion**"*, and the docs' own advice is *"it is
recommended to use an explicit error set"*
([Inferred Error
Sets](https://ziglang.org/documentation/master/#Inferred-Error-Sets)).
`docs/FAILURE.md` already refused inference by name; this is the
primary source for why.

**And the JSON program, which is the one Luce is about to write.**
`lib/std/json/dynamic.zig` declares

```text
pub const ObjectMap = StringArrayHashMap(Value);
pub const Array = std.array_list.Managed(Value);
pub const Value = union(enum) {
    null, bool: bool, integer: i64, float: f64,
    number_string: []const u8, string: []const u8,
    array: Array, object: ObjectMap,
};
```

Two things about it are the whole lesson.  **The recursion travels
through the collections** — `Value` never contains a `Value` directly;
it contains an `ArrayList(Value)` or a `StringArrayHashMap(Value)`,
both pointer-backed, so the container *is* the indirection and there is
no `Box` and no `recursive_wrapper`.  And **`Value` has no `deinit` at
all**: ownership lives one level up in `Parsed(T)`, which is
`{arena: *ArenaAllocator, value: T}` whose `deinit` drops the whole
arena, with the documentation *"You must call `deinit()` of the
returned object to clean up allocated resources"* and the alternative
entry point named `parseFromSliceLeaky`, documented as *"Allocations
made during this operation are not carefully tracked and may not be
possible to individually clean up"*
([dynamic.zig](https://github.com/ziglang/zig/blob/master/lib/std/json/dynamic.zig),
[static.zig](https://github.com/ziglang/zig/blob/master/lib/std/json/static.zig)).
Luce takes the first half and cannot take the second.

### 2.5 TypeScript — the poor man's version, and what it proves

**The mechanism.**  *"When every type in a union contains a common
property with literal types, TypeScript considers that to be a
*discriminated union*, and can narrow out the members of the union"*
([handbook,
narrowing](https://www.typescriptlang.org/docs/handbook/2/narrowing.html#discriminated-unions)).
The passage that matters is the diagnosis of the *non*-discriminated
encoding — one interface with optional fields: *"The problem with this
encoding of `Shape` is that the type-checker doesn't have any way to
know whether or not `radius` or `sideLength` are present based on the
`kind` property.  We need to communicate what we know to the type
checker."*  That is the argument for a real tag, made by a language
that has to fake one.

**Exhaustiveness is an idiom, not a feature.**  *"The `never` type is
assignable to every type; however, no type is assignable to `never`…
This means you can use narrowing and rely on `never` turning up to do
exhaustive checking in a `switch` statement"*, written by hand as
`const _exhaustiveCheck: never = shape;` at every switch (same page).
It leaks into runtime code and can be forgotten.

**The tag is not real, and this is a stated non-goal.**  TypeScript's
design goals list, under Non-goals: *"Add or rely on run-time type
information in programs, or emit different code based on the results of
the type system"*
([design
goals](https://github.com/microsoft/TypeScript/wiki/TypeScript-Design-Goals)).
The discriminant is an ordinary property the author wrote; the type
system only checks that it agrees with the shape.

**And there is no match statement.**  TC39's pattern-matching proposal
(Stage 1) names the gap: `switch` *"may not appear in expression
position; an explicit `break` is required in each `case` to avoid
accidental fallthrough; scoping is ambiguous… the only comparison it
can do is `===`"*, while `if/else` *"is overly verbose even for common
cases, requiring the author to explicitly list paths into the value's
structure multiple times"*
([tc39/proposal-pattern-matching](https://github.com/tc39/proposal-pattern-matching)).
Two of its stated priorities are worth lifting whole: *"If the
developer wants to ignore certain possible cases, they should specify
that explicitly.  A development-time error is less costly than a
production-time error"*, and *"If the developer wants two cases to
share logic… they should specify it explicitly.  Implicit fall-through
inevitably silently accepts buggy code."*

### 2.6 Python — the syntax neighbourhood, and the biggest pattern-design trap on record

**The grammar Luce lives next door to.**
`match_stmt: "match" subject_expr ':' NEWLINE INDENT case_block+ DEDENT`
and `case_block: "case" patterns [guard] ':' block`
([PEP 634](https://peps.python.org/pep-0634/#the-match-statement)) —
note that this is **two levels of indentation** where an `if`/`elif`
chain expressing the same thing is one, which is a real argument for
`docs/ENUMS.md` R3's decision to drop the `case` keyword.

**Class patterns mirror construction, on purpose.**  *"The syntax of
class patterns is based on the idea that de-construction mirrors the
syntax of construction.  This is already the case in virtually any
Python construct…  In all these cases, we find that the syntax for
sending and that for receiving 'data' are virtually identical"*
([PEP 635](https://peps.python.org/pep-0635/#class-patterns)).  Luce's
§Q2/§Q7 pairing — `Shape.circle(radius = 2.0)` to build and
`circle(radius):` to take apart — is the same principle.

**Why Python could not do the ADT thing, in its own words.**  *"It is
thereby very tempting to write, e.g., `case Node(left, right):`… **While
this indeed works well for languages with strict algebraic data types,
it is problematic with the structure of Python objects.**  When dealing
with general Python objects, we face a potentially very large number of
unordered attributes… the interpreter cannot reliably deduce the
ordering of attributes"* (PEP 635) — hence `__match_args__`.  **Luce is
on the other side of that sentence**: a union member's fields are
declared, ordered and closed, so the machinery Python needed is
machinery Luce does not.

**The trap, and it is the most instructive failure in this survey.**  A
bare name in a Python pattern is a **capture**, not a comparison:
*"A capture pattern always succeeds.  It binds the subject value to the
name"* (PEP 634).  Constants must therefore be dotted: *"**The main
issue that arises here is how to distinguish capture patterns (variable
bindings) from value patterns.**…  We therefore only adopted the rule
that any dotted name (i.e., attribute access) is to be interpreted as a
value pattern…  **This precludes, in particular, local variables and
global variables defined in the current module from acting as
constants**"* (PEP 635).  Explicit capture markers (`?x`, `$x`, `=x`)
were rejected on the grounds that they *"betray the objective of the
proposed pattern matching syntax"* and that the request *"is based on
the misconception that pattern matching was an extension of *switch*
statements"*.

PEP 642 was written to undo that and was **rejected**.  Its criticism is
the one to keep: the aim was *"to make interpretation of simple names in
patterns a **local activity**"*, against three ambiguities it names —
`ATTR=TARGET_NAME` *"binds to the right without using the `as` keyword,
and uses the normal assignment-to-the-left sigil (`=`) to do it"*,
`KEY: TARGET_NAME` likewise, and `TARGET_NAME_1 as TARGET_NAME_2`
giving *"an odd 'binds to both the left and right' behaviour"*.  Its
process argument is the one that reads like this project's own guiding
principle: *"If we start with an explicit syntax, we can always add
syntactic shortcuts later…  while if we start out with only the
abbreviated forms, then we don't have any real way to revisit those
decisions in a future release"*
([PEP 642](https://peps.python.org/pep-0642/)).  And PEP 642 quotes a
PEP 634 author conceding the clash: *"we have different
cultures/intuitions fundamentally clashing here.  In particular, so
many programmers welcome pattern matching as an 'extended switch
statement' and find it therefore strange that names are binding and not
expressions for comparison."*

**Python's `match` is not exhaustiveness-checked at all.**  The word
"exhaust" appears **zero times** in PEPs 634, 635 and 636.  The rule is
*"If no case blocks qualify the match statement is complete"* (PEP 634)
and the tutorial's plainest form: *"If no case matches, none of the
branches is executed"*
([tutorial](https://docs.python.org/3/tutorial/controlflow.html#match-statements)).
A missed case is a silent fall-through.  There is also declared
undefined behaviour: *"the binding of variables by capture patterns
that are followed (in the same case block) by another pattern that
fails… may happen earlier or later depending on the implementation
strategy"* — restated in the reference as *"do not rely on bindings
being made for a failed match."*

**One footnote Luce should notice.**  PEP 635 records that `_` is the
wildcard *"in every programming language with pattern matching that we
could find"* and lists thirteen.  `docs/RETURNS.md` refused `_` as a
binding-position wildcard, and `_` is already the array-shape wildcard
in `typeName`.  A match design that never needs a wildcard — because
`else:` is the catch-all (`docs/ENUMS.md` R1) — sidesteps the question
entirely, and PEP 635's own reason for having no `else:` is that *"there
would be two plausible indentation levels for an else block"*, which is
a problem `match` without `case` does not have.

### 2.7 Sum types without generics — Ada, C, and the design Go wanted and could not have

This is the section that answers §Q9 directly, and it has a better
precedent than the memo expected.

**Ada's variant records are nominal, statically checked, and older than
generics being needed for any of it.**  ARM 3.8.1: *"A record type with
a `variant_part` specifies alternative lists of components.  Each
variant defines the components for the value or values of the
discriminant covered by its `discrete_choice_list`"*, with the
**discriminant an ordinary named field of a discrete type** that the
program can read.  The coverage rule is a **Legality Rule** — an error,
not a warning: *"each value of that subtype that satisfies its
predicates shall be covered by some `discrete_choice` (either
explicitly or by `others`)"*, and *"**two distinct `discrete_choice`s of
a `variant_part` shall not cover the same value**"*.  A payload-less
member is spelled `null`: *"If the `component_list` of a variant is
specified by `null`, the variant has no components."*  Access to a
component of an inactive variant is a **run-time** check, and default
initialization with an uncovered discriminant *"raises
`Constraint_Error`"*
([ARM 2022
§3.8.1](http://www.ada-auth.org/standards/22rm/html/RM-3-8-1.html)).

Every property `docs/ENUMS.md` and this memo want is in that one
section — nominal tags, a readable discriminant, static exhaustiveness
as an error, static overlap refusal, payload-less members, dynamic
refusal of wrong-arm access — **and generics appear nowhere in it.**

**C is the same shape with the checking removed.**  ISO C §6.7.2.1 ¶16:
*"The size of a union is sufficient to contain the largest of its
members.  The value of at most one of the members can be stored in a
union object at any time"*
([N1570](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)).
No tag, no discipline, no check; the struct-wrapping-a-union idiom is
entirely convention.  That is the baseline Ada and this proposal
improve on, and it is what `docs/MISSING.md` Tier 2 means by *"a raw
overlay would have been an unchecked cast in a language whose every
guarantee assumes values are what they say."*

**Go refused, and its reasons do not transfer — which is the useful
part.**  Ian Lance Taylor, 2017: *"The past consensus has been that sum
types do not add very much to interface types.  Once you sort it all
out, what you get in the end is an interface type where the compiler
checks that you've filled in all the cases of a type switch.  That's a
fairly small benefit for a new language change"*
([golang/go#19412](https://github.com/golang/go/issues/19412#issuecomment-284301017)).
The two blockers Go names are **its own and not Luce's**:

*The zero value.*  *"Since the sum type must record somewhere the type
of the value that it currently holds, I believe it means that **the
zero value of the sum type is not all-bytes-zero, which would make it
different from every other type in Go**"*
([#19412](https://github.com/golang/go/issues/19412#issuecomment-288525373));
and in the 2023 revival, *"the zero value of an interface type with an
embedded union would be `nil`… **So this is a form of sum type in which
there is always another possible option, namely `nil`.  Sum types in
most languages do not work this way, and this may be a reason to not add
this functionality to Go**"*
([#57644](https://github.com/golang/go/issues/57644)).  §Q8's
zero-value question is exactly this one, and Luce has the answer Go
could not take: it has no `nil`, and S40 already says every place holds
its type's zero.

*The layout, and the collector.*  Taylor sketches the layout everyone
wants — *"we could use a small code, typically a single byte, to
indicate the type stored in the interface… We could store the values
directly, rather than boxed…  the equivalent of `struct { code byte;
value [8]byte }`…  The advantage of this would be reducing memory
allocations"* — and then names why Go can only sometimes take it:
*"**the current garbage collector implementation has to be able to very
very quickly know which fields in that value are pointers**"*, via a
per-type pointer bitmask (#57644).  **Luce has no collector scanning
anything**, so the layout Go describes as a conditional optimisation is
simply the layout Luce would always be free to use.  That is the single
most encouraging finding in this survey and it belongs in §Q4.

### 2.8 What the seven have in common

Six patterns, and they are the reason to read §2 before §3.

1. **Every language with recursive sum types either collects garbage or
   makes the indirection explicit.**  OCaml and Haskell box everything
   and collect; Swift inserts a refcounted box behind `indirect`; Rust
   demands `Box` and says so in the diagnostic; C++ needs
   `recursive_wrapper` because *"even if C++ syntax were different… the
   type would need to be of infinite size"*
   ([Boost.Variant](https://www.boost.org/doc/libs/1_86_0/doc/html/variant/tutorial.html));
   Zig's `std.json` routes recursion through owning containers and hands
   the tree to an arena.  **Luce already has the last of these without
   the arena**, because a container is scope-owned (§Q8).
2. **Exhaustiveness is an error only where the language can see the
   whole set.**  Ada errors; Rust errors; Zig errors.  ML and OCaml warn
   because their checkers are expensive; GHC's is off by default because
   it is exponential in the worst case.  Swift had to weaken it at the
   library boundary.  Python does not check at all.  **Luce's flat
   member arms make the check linear and the boundary problem
   nonexistent.**
3. **Named payload fields win, and the languages that started positional
   added them later.**  OCaml's inline records (4.03), Swift's labels
   (SE-0155), Rust's struct-like variants, Ada's component lists.
   Positional payloads are a tuple, and `docs/RETURNS.md` already
   refused the tuple.
4. **The move-or-borrow question at a match arm is where the ergonomics
   debt lives, and it only exists if bindings can be the payload
   itself.**  Rust has `ref`, default binding modes, partial moves,
   E0507, two RFCs and an edition break.  Swift, whose enums are value
   types that copy, has one sentence and two spellings.
5. **The tag must belong to the language, not the programmer.**
   TypeScript's discriminant is a property the author wrote and the type
   system merely checks; Zig's untagged `union` is a check that
   *disappears in release modes*; C has nothing.  A language whose
   guarantee is "values are what they say" has one option here, which is
   why "Tagged unions obviously" was one sentence.
6. **A bare name in a pattern is the field's most expensive syntax
   decision.**  Python spent two PEPs and a rejection on it and still
   warns readers in the tutorial.  Restricting arms to member names of a
   closed namespace — which `docs/ENUMS.md` R3 already did — removes
   the question rather than answering it, and keeping it removed is a
   decision worth making on purpose.


---

## 3. The nine questions

Each one gets the same three parts: **the field's answers** (pointing
back at §2 rather than repeating the citations), **what each costs
against §1**, and a **recommendation** — which is a recommendation and
not a ruling.  §5 sorts them into the ones with one honest answer and
the ones that need the owner.

### Q1 — declaration syntax, and whether a payload-less member is just an enum member

**The field.**  Rust, Swift, OCaml and Haskell put payload-carrying and
payload-free constructors in **one** declaration form under **one**
keyword (§2.1–2.3); Zig splits them, `enum` for tags and
`union(enum)` for tags with payloads, and lets a union name an existing
enum as its tag (§2.4).  Rust's vocabulary is worth noticing, because
it says the answer to the second half of this question out loud: a
payload-less member is not a separate concept, it is *"a field-less
enum"* — a variant that simply has no field list (§2.2).

On the payload's own shape the field splits differently and more
usefully: **positional** payloads (Rust's tuple variants, OCaml's `of
float * float`, Haskell's `data`) versus **named** ones (Rust's
struct-like variants, OCaml's inline records, Swift's labelled
associated values).  Rust shipped both and its Reference shows the
named form generalising over all three variant kinds — `UnitLike {}`,
`TupleLike { 0: 123 }` — while the positional call form is the special
case that needs a *constructor function in the value namespace*, which
is a thing only a language with function values can have (§2.2).

**What it costs here.**  `docs/RETURNS.md` already refused the
positional option, in advance and for this exact reason: a positional
multi-payload member is an anonymous product type, and *"adding an
anonymous product type is not adding a feature; it is adding the
*first* structural type"*.  `circle(double, double)` is a tuple with a
name in front of it, and the parser already prints *"there are no
tuples: group values in a list `[a, b]` or a struct"* at the sight of
one.  **Named payload fields cost nothing** — they are struct fields,
`04_semantics` already has the machinery, and `docs/ARGS.md` D8 already
made struct construction named-only.

On the keyword: `docs/ENUMS.md`'s enum is a **numbered** thing.  D1
gives members `= value`, D2 a backing width, D4 `int(m)`, R2
`Method(n) -> Method?`, D5 `string(m)`.  None of those five means
anything for a member carrying a `list`, so folding payloads into
`enum` would give the language one keyword with two halves of its
surface that do not apply to each other.  Zig's split is the precedent
and it is the honest one here for a reason Zig does not have: Luce's
enum was specified as C's enum first.

**Recommendation.**  A second declaration form mirroring struct's and
enum's:

```text
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)
```

**A payload-less member is exactly an enum member with no number** —
legal, needed (`Json.null`), and spelled bare.  Payload fields are
**named, always**; a positional payload is refused with the sentence
the parser already prints.  What it does *not* get, and this is the
line: no `= value`, no backing width, no `Shape(n)`, because a union
member is not a number and pretending otherwise would give the type two
identities.  Whether `string(u)` answers the member name is a small
open question — D5's mechanism (an interned name table handed to
`libluce_rt`) would serve it unchanged.

**The one thing genuinely worth the owner's ruling** is Zig's tag
reuse: `union Shape(Kind):` naming an already-declared enum as the
discriminant, so a program can hold, store and compare the tag without
the payload.  It is real machinery with a real user — a decoder that
reads a kind byte, validates it with `Kind(n) -> Kind?`, and only then
builds the payload — and it is the one union feature that the enum work
being built tonight would make nearly free.  Zig's version of it comes
with three checked rules and a scar: names must correspond both ways,
**and the two declaration orders must agree**, enforced by three
separate diagnostics in `Sema.zig` that appear nowhere in its language
reference — because a version that allowed divergent orders miscompiled
(`ziglang/zig#12543`, §2.4).  If Luce takes tag reuse it should take
the ordering rule with it and write the rule down where a reader can
find it.

### Q2 — construction syntax, and named arguments

**The field.**  Rust's tuple variants are *constructor functions* (a
consequence of first-class functions, which Luce does not have);
its struct variants use braced named syntax and are not values.
Swift's associated values are constructed by a call with the case's
labels.  Zig uses either `.{ .circle = payload }` or `@unionInit`.
OCaml applies the constructor to a value.  (§2.1–2.4.)

**What it costs here.**  Nothing, because the shape already exists
twice over.  `docs/ENUMS.md` D3 namespaces members — `Method.stored`,
*"resolved by the head-names-a-declaration rule that already serves
`Struct.func` and `module.name`"* — and `docs/ARGS.md` D8 makes struct
construction **named-only** (positional struct construction is a
compile error, `builder.zig`'s *"function arguments are positional"*
family notwithstanding).  So `Shape.circle(radius = 2.0)` is
`Bag(label = "a", items = [1, 2])` with a namespace in front of it, and
it needs no new resolution path, no new diagnostic family, and no
decision about positional-versus-named that has not already been taken.

**Recommendation.**  `Shape.circle(radius = 2.0)`; `Json.null` with no
parentheses, because parentheses mean a payload and a payload-less
member has none.  Defaults on payload fields fall out of ARGS D8 for
free and should be allowed for the same reason struct fields have them,
unless someone can name a case where a defaulted variant payload is a
trap.

Two consequences worth writing down now rather than discovering:
`Shape.circle` **without** parentheses, where a payload is expected, is
a `luce.sema.construct` naming the fields it wants — not a function
value, because `docs/MISSING.md` Tier 4 has no function values and the
existing diagnostic for a bare declaration name already says so.  And a
union member is **not** a type: `let c: Shape.circle` is refused the way
`(long, long)` is, for `docs/RETURNS.md`'s reason.  Rust made the same
refusal — its Reference says a variant *"defines its type in the type
namespace, though that type cannot be used as a type specifier"* — and
has an eight-year-old postponed RFC asking to undo it, whose motivation
is a list of three workarounds users write instead (§2.2).  Refusing it
on day one costs nothing and reopens cleanly; it is worth knowing that
the pressure is real and that Rust has not resolved it.

### Q3 — ownership of payloads: the hard one

Four questions live inside this one and they have different answers.

#### (a) Is a union with an object-carrying member an object-carrying type?

**The field.**  Rust answers by ownership: an enum owns its payload, and
dropping the enum drops whatever the active variant holds.  Swift and
OCaml answer with a collector.  **Zig ducks the question entirely, and
the evidence is the exact program Luce is about to write.**
`lib/std/json/dynamic.zig`'s `Value` is a `union(enum)` with `array:
Array` and `object: ObjectMap` members — and **it has no `deinit` at
all**.  Ownership lives one level up, in `Parsed(T)`, which is *"`arena:
*ArenaAllocator, value: T`"* with a `deinit` that drops the whole arena;
the alternative entry point is named, in the standard library, with the
word in it: `parseFromSliceLeaky`, documented as *"Allocations made
during this operation are not carefully tracked and may not be possible
to individually clean up"* (§2.4).

**Luce cannot take that answer**, and it is worth being exact about
why.  `docs/MEMORY.md` files arenas as a *runtime* device — *"the
runtime may use them as an optimization invisibly"* — and a
program-visible arena would be a second reclamation mechanism beside
scope ownership, which is the one thing that memo forbids acquiring.
So the question Zig's most famous recursive union does not answer is
the one this memo has to.

**What it costs here.**  `carriesObjects` (§1.7) is a **static,
type-level** predicate: `.strukt` answers the shape's `carries` flag,
which is the OR over its fields.  A union's answer must be the OR over
its *members*, because the compiler does not know which member a value
holds.  So `Json` is object-carrying **unconditionally at the type
level**, and S27 applies to every `Json` — including `Json.number(3)`,
which owns nothing at all:

```text
var values = new list(Json)
var j = Json.number(3.0)
values.append(j)              # refused by S21/S27: give j, or copy j
```

That is a real ergonomic cost and it should be stated rather than
discovered.  It is also **exactly the cost `T?` already pays**, and
`carriesObjects`'s `.optional` arm is where it is paid: a `list(long)?`
holding `none` owns nothing, and the type still demands a verb.  S43
records the resolution — *"Optionals inherit S1–S42 unchanged: a
`builder?` holding an object owns it like any binding; holding `none`
owns nothing.  Nothing in this document changed when `T?` arrived,
which is the strongest thing that can be said about it."*

**The static predicate is conservative and the runtime walk is exact,
and both already exist.**  `dropStorage` switches on the *value's* own
tag, so freeing a `Json.number` frees nothing and freeing a
`Json.array` frees a list — no new code, because it is the same walk
that already no-ops on absence.  This is the strongest single argument
that union's ownership story is `T?`'s generalised from one payload to
N, and that `docs/OWNERSHIP.md` may again need **no new rule** — which
would be the second time, and would be the thing to check hardest
rather than the thing to assume.

#### (b) What does binding a payload in a match arm mean?

**The field, and it is the cautionary tale of this memo.**  In Rust,
whether `Some(x)` moves or borrows is decided by three interacting
things none of which is written at the binding site: whether the
payload is `Copy`, whether the scrutinee is a place expression, and the
**default binding mode** at that depth of the pattern — itself a
function of how many references the pattern has walked through.  The
history is the warning: `ref`/`ref mut`, then RFC 2005's default
binding modes to delete them, then RFC 3627 and edition-2024
reservations, a lint and an automated migration to make the mode
legible again (§2.2).  Mixing modes in one pattern gives a **partially
moved** value, and reading a payload out of a borrow is E0507 —
literally *"cannot move out of `self.x` as enum variant `Some` which is
behind a shared reference"*.

Swift's `case let .circle(r)` binds a **copy**, because *"all
structures and enumerations are value types"* and value types *"are
always copied when they're passed around"* — no `ref`, no mode, no
partial move, and a specification an order of magnitude shorter (§2.3).
Zig's `switch` captures **by value** unless you write `|*payload|`, and
its own issue tracker has the cases where that bites (§2.4).

**What it costs here.**  Luce already has one answer for "read
something out of a place you do not own", and it has it three times:
S11 (passing an object is a borrow), S22 (*"reading elements is
borrowing"*), S8 (*"aliasing is free and untracked"*).  A match arm's
payload binding is a read of the scrutinee.  There is no reason for it
to be anything else, and every reason for it not to be: moving out
would leave the scrutinee partially moved, which is a flow analysis
Luce does not have and `docs/OWNERSHIP.md` S29 explicitly refuses the
shape of (*"blunt and predictable beats flow-sensitive and clever"*).

**Recommendation.**  **A payload binding is an alias.**  Reading
through it is free; keeping it needs `copy`; `give` on it is refused
with the sentence S23 already prints — *"`view` aliases an object it
does not own; `give xs` (the owner), or `copy view`"* — with the arm's
scrutinee named as the owner.  For a *value* payload (`double`,
`string`, a plain struct) the binding is an ordinary copy and S32/S37
mean no verb exists to write.  Nothing new; four existing situations
reached from one new place.

The consequence to write down: an arm binding is a name in a nested
scope, exactly like `catch NAME:`, and `docs/LANGUAGE.md` says of that
one *"the name obeys the no-shadowing rule"*.  So `circle(radius):`
inside a function that already has a `radius` is a compile error, and
either the language grows a rename form in patterns or match arms
become the first exemption from no-shadowing.  That is a genuine
question and it is §Q7's.

#### (c) What do `give`, `copy` and `free` mean for a union?

Follow the carrying-struct rules, unchanged:

- **`give u`** moves the whole value, whatever member it holds.  The
  runtime walk is by tag; a payload-less member moves nothing.
- **`copy u`** is S31 verbatim — *"copy duplicates the object and
  everything it owns, recursively"* — and `ownValue` already is that
  walk (§1.3).
- **`free u`** is S6's early release on an owned name, poisoning it.
- On a union with no object-carrying member, **no verb exists at all**,
  by S32: it is a value like a `Point`, and casual code says nothing.

#### (d) Does a union in a struct field change the struct's value-copy story?

**No, and this is checkable rather than argued.**  S26: *"copying a
struct value never duplicates or moves objects; ownership stays where
it was"*, and `ownValue`'s `.strukt` arm duplicates each field's
*storage* while passing object handles through untouched.  A union
field is one slot in the run; copying the struct copies the slot, which
duplicates a value payload and aliases an object payload.  That is S26
already, stated about one more payload shape.

What *does* change is the struct's `carries` flag, by (a) — and
therefore whether it may be a `var self` receiver.  `docs/METHODS.md`
requires *"a struct that carries no objects"* so the write-back is a
pure value store, and `std/zip.luc:507`'s `struct Stream` says so in a
comment.  **A struct with a `Json` field can never be a `var self`
receiver**, whatever member the field happens to hold.  That is the
same wall zip's Huffman tables hit, arriving from the union side, and
it is worth knowing before `std.json` is written against it.

### Q4 — memory layout, with no collector and scope ownership

**The field.**  Three answers.  **Inline: tag plus the largest
payload** — C's rule verbatim (*"the size of a union is sufficient to
contain the largest of its members"*, §2.7), Swift's specified
five-strategy table which spends *extra inhabitants* and *spare bits*
before it will add a tag byte (§2.3), and Rust's, which is
deliberately **unspecified** for `repr(Rust)` and guarantees exactly one
thing — `size_of::<Option<&T>>() == size_of::<&T>()` (§2.2).
**Uniform boxing** — OCaml's constant constructors as unboxed integers
and non-constant ones as tagged blocks, Haskell's boxed constructors —
which makes recursion free and every construction an allocation the
collector cleans up (§2.1).  **A pointer you write yourself** — Rust's
`Box`, C++'s `recursive_wrapper` — which is uniform boxing with the
ownership made explicit (§2.2, §2.8).

**And one language wrote down the layout it wanted and could not
have.**  Go's own sum-type proposal sketches *"the equivalent of
`struct { code byte; value [8]byte }`… The advantage of this would be
reducing memory allocations"*, and then names the blocker: *"the
current garbage collector implementation has to be able to very very
quickly know which fields in that value are pointers"* (§2.7).  **That
constraint is a collector's, and Luce does not have one.**  It is worth
holding on to while reading the rest of this section: the cheap layout
is available here in a way it is not available to Go.

**What it costs here, and the finding that decides it.**  Luce already
has the third one and has had it since struct values existed.  §1.3:
`Value.strukt` addresses a field run, `08_llvm/lower.zig:349` maps
`.strukt => .ptr`, `resultSize` says `.strukt => 8`, and `ownValue` /
`dropStorage` are the recursive copy and the recursive free, each with
exactly one owner and a static death point.  **Luce boxes, without a
collector, today.**  So the layout question is not "how do we afford a
box" but "where does the tag go".

A concrete proposal that costs no version number it would not cost
anyway:

- **A union value is a tag plus a field run** — the run being the
  active member's payload fields, in declaration order.  A
  payload-less member carries a **null run**, and `dropStorage`'s
  existing `if (held.bits == 0 or held.length == 0) return;` already
  makes that free.
- **On the interpreter, `Value` does not grow.**  `Tag` uses 12 of 256
  values, and every non-string value leaves `inline_head`'s six bytes
  untouched — so a `union` tag with the member index in `inline_head`,
  `bits` addressing the run and `length` counting it keeps
  `sizeOf(Value)` at 24, which `value.zig`'s layout test asserts.
- **On the compiled path a union is `{i32 member, ptr run}`** — 16
  bytes, the shape `resultSize` already gives a `string`.
- **`ownValue` and `dropStorage` need no member table.**  They walk a
  run and switch on each slot's own tag; they never ask what layout the
  run belongs to.  The tag beside the run is for the *program*, not for
  the walk.

The cost is one allocation per construction of a payload-carrying
member, and it is the same cost `docs/RETURNS.md` §4 priced for the
synthesized return struct, with the same honest note: *"`libluce_rt` is
an opaque external library, so LLVM's O3 pipeline does not see through
the make/get/free triple and delete it."*  And the same scheduled,
backend-only, measurable escape: a union all of whose payloads are
scalars and small can go inline in a fixed-width slot with no
allocation, changing nothing above stage 6 — which is what
`docs/RETURNS.md` step 7 is and what `07_optimize/ownership.zig` is.
**Recommendation: the run on day one, the inline case scheduled and
measured, and the measurement written down before anyone builds it on
faith.**

`docs/TYPES.md`'s narrow widths are the one place this is not free: a
run is a run of `Value`s, so `circle(radius: half)` costs 24 bytes for
two.  Arrays are where narrow widths pay (§10 of that memo), and a
union payload is not an array.

### Q5 — does `T?` become a two-member union?

**The field is genuinely split, and both halves are principled.**
Rust's `Option<T>`, Haskell's `Maybe`, OCaml's `option` and — the
sharpest data point — **Swift's `Optional`, which really is
`enum Optional<Wrapped>` in the standard library with `?` as pure
sugar** (§2.3).  Against them: Kotlin, where *"the type system
distinguishes between types that can hold `null` (nullable types) and
those that cannot"* — a type-system feature with smart-casting and no
`Some`/`None` at all
([null safety](https://kotlinlang.org/docs/null-safety.html)) — and
Zig, whose `?T` is a built-in with a promise a library type could not
make: *"an optional pointer is guaranteed to be the same size as a
pointer.  The null of the optional is guaranteed to be address 0"*
(§2.4).

The pattern is legible and it is not about taste.  **Languages with
parametric polymorphism make `T?` a two-case ADT, because they can
write `Optional<Wrapped>` once and get every `T` for free.  Languages
without it — or that want a layout guarantee — keep it built in.**  And
the decisive data point is Zig, which *has* comptime generics and still
chose the built-in.

**What it costs here.**  Five things, and they run one way.

1. **`T?` is narrowed, not matched.**  `docs/LANGUAGE.md`: *"After a
   test, the name *is* its payload: no unwrapping operator, no second
   spelling"*, over five flow-sensitive shapes.  Every `parse_int` in
   the corpus is `x else 0` or an `if x != none:`.  If `T?` were a
   union, either narrowing survives as a special case — in which case
   the merge bought nothing and cost one more thing to explain — or the
   corpus rewrites to `match`, which is a large ergonomic regression on
   the language's most-used shape.
2. **`T??` is *unrepresentable*, not refused.**  `types.Type.Payload`
   is *"a union of its own rather than a `*Type`"* precisely so that
   *"there is one level of absence and no way to write a second"*.  A
   general union has no such property; `Shape??` would need a rule
   where today there is a representation.
3. **The two have opposite container rules.**  `T?` *"may not be a
   container element or a map value"*.  `list(Json)` is the entire
   point of a union.  Merging them either lifts the optional
   restriction — a real language change that wants its own memo — or
   imposes it on unions, which kills the motivating customer.
4. **The representations are not the same and the cheaper one is
   `T?`'s.**  `{T, i1}` with `resultSize` down to two bytes for a
   `bool?`; a union is a tag and a run.  Merging makes every optional
   pay the union's price.
5. **It would force generics.**  An `Optional(T)` union is a
   parameterised type, which `docs/MISSING.md` Tier 4 refuses and §Q9
   prices.  `T?` avoiding that is not an accident: *"`T?` did become a
   variant of `Type` — one, whose payload is a union of its own — and
   it opened no door at all: nothing about it generalizes."*

`docs/MISSING.md` posed this and named the evidence that would settle
it: *"what the corpus does with `T?` from here is what should settle
it."*  What the corpus has done since is `parse_int`, `parse_float`,
`key_read`, `read_line`, `m.get(k, default)` and five `double?`
reductions in `std/math.luc` — all `else` and narrowing, not one of
them wanting a match arm.

**Recommendation: `T?` stays its own mechanism, and this should be
recorded as settled rather than left open a third time.**  The
*converse* is the cheap and useful half: **`Shape?` should be
writable**, which is one arm on `types.Type.Payload` beside `strukt`
and `heap`, and gives recursion its terminator (§Q8).

### Q6 — can `T!`'s reasons become sum-typed?

**The field gives a clean answer to the narrow question, and it is
yes.**  Zig's error sets are a sum-typed error channel with **no type
parameters anywhere**: errors are interned names with globally
consistent integers, the set defaults to a `u16`, subset coerces to
superset, and `||` merges — *"the Zig standard library uses
`LinuxFileOpenError || WindowsFileOpenError` for the error set of
opening files"* (§2.4).  So an error channel can be sum-typed without
generics, and this is the existence proof.

The other two answers cost more.  Rust's `Result<T, E>` is generic and
its ergonomics need `From`, `?` and `FromResidual` on top (§2.2).
Swift shipped untyped `throws` first and typed throws only in SE-0413,
whose own text warns *"resist the temptation to use typed throws
because there is only a single kind of error that the implementation
can throw"* and names the evolution cost: *"an API that uses typed
throws cannot make its thrown error type more general (or untyped)
without breaking existing clients"* (§2.3).  Zig's set *union* is
exactly the evolution direction Swift says typed throws blocks, which
is the strongest thing that can be said for the error-set shape.

And Sutter's P0709 is the outside statement of the three-way split
Luce already implements: *"an alternate result is never an 'error' (it
is success, so report it using return)"*; *"a programming bug or
abstract machine corruption is never an 'error'… so they should never
be reported to the calling code as errors that code could somehow
handle"*
([P0709R4](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2019/p0709r4.pdf)).
That is `docs/FAILURE.md`'s rule arrived at independently, and it says
that if the error channel *is* sum-typed the sum should contain only
the middle category.

**What it costs here.**  `docs/FAILURE.md` refused three of these by
name, and it is worth separating which of its reasons union removes and
which it does not.

*Removed:* the stated reason for refusing `Result<T, E>` was *"no
generics, no tagged unions"*.  Half of that premise is about to change.

*Not removed, and load-bearing:* an error in Luce **unwinds through
releases**.  S34 draws the line — a trap ends the run and the runtime
reclaims everything, while *"an error… does not end the run: a `catch`
resumes with the program still going.  So error propagation releases
precisely, the way `return` does (S4)"*.  That is why `Runtime.raise`
**copies** the message's words: *"`error("x: " + string(n))` hands over
bytes a statement temporary is about to give back."*  A value-only
union payload is storage, and `ownValue` copies storage — so a reason
that is a union of **value-only** members is mechanically free, by the
line of code that already copies the message.  An **object-carrying**
reason is not: the unwind releases the objects it is carrying out.

*Also not removed:* `docs/FAILURE.md`'s own argument for two codes
applies one level down and it applies to typed errors too — *"every
`catch` in the tree guards exactly one call… and a call raises with one
code, so branching on `io_failed` versus `user_error` asks a question
the call already answered."*  `std.zip`'s forty raise sites are the
counter-evidence worth weighing, because its five families are five
things a *caller* might do differently.  But zip's callers do not exist
yet, which is the honest state of that evidence.

And the memo's closing quote is exactly on point and is the field's
own warning: SE-0413's *"Resist the temptation to use typed throws
because there is only a single kind of error that the implementation
can throw."*

**Recommendation: not in this run, and not by widening the channel.**
If it reopens, the shape that fits is the one that keeps
`docs/FAILURE.md`'s design intact — fallibility stays a **function
attribute**, and the attribute grows a named error enum or union:
`-> list(Entry)!ZipError`, with `catch reason:` binding a value the
handler can `match`.  The rule that falls out is small and checkable:
**an error reason may be a union of value-only members**, refused
otherwise, for S34's reason.  Whether even that is wanted is a ruling
(§5), and Zig's **inferred** sets are the trap to avoid —
`docs/FAILURE.md` already named their cost as *"unsupported recursion,
unstable type identity"*, and Zig's own reference confirms every word
of it: *"when a function has an inferred error set, that function
becomes generic and thus it becomes trickier to do certain things with
it, such as obtain a function pointer, or have an error set that is
consistent across different build targets.  Additionally, inferred
error sets are incompatible with recursion"*, with the advice *"it is
recommended to use an explicit error set"* (§2.4).  A memo that reopens
this should take the explicit half and refuse the inference.

### Q7 — match arm syntax for payload binding

**The field.**  Rust: `Shape::Circle { radius }` for struct variants,
`Shape::Circle(r)` for tuple ones, with a field-name shorthand that is
the ergonomic winner (§2.2).  Swift: `case .circle(let r)` or
`case let .circle(r)`, two spellings of one thing (§2.3).  Zig:
`.circle => |radius|`, the capture after the arrow rather than inside
the pattern (§2.4).  Python: `case Point(x=0, y=0)` with
`__match_args__` for positional, and **the capture-versus-comparison
ambiguity that PEP 635 spends pages on and PEP 642 was written to
undo** (§2.6).

**What it costs here.**  The Python lesson is the one that transfers,
and Luce is already mostly immune to it: `docs/ENUMS.md` R3 fixed arms
as **bare member names of a closed namespace**, so the head of an arm
is never a name that might be a capture.  The ambiguity Python has —
*is `case foo:` matching the value of `foo`, or binding `foo`?* — can
only arise if Luce admits literal patterns or nested patterns.  **It
should not, and R1's restricted statement is already the decision not
to.**

**Recommendation.**

```text
match shape:
    empty:
        print("nothing")
    circle(radius):
        print(f"r={radius}")
    rect(width, height):
        print(f"{width}x{height}")
```

Each payload field binds a local of the **field's own name** — Rust's
shorthand, which reads best in an indented language and needs no
second token.  Every field is named or none is (`circle:` with a
payload is legal and binds nothing, for the arm that only cares which
member it is); a partial list is refused, naming the missing fields the
way struct construction already does.  No literal patterns, no nested
patterns, no guards, no or-patterns in this run — each of them is a
separate decision and each of them is where Python's and Rust's
ergonomics debt came from.  PEP 642's process argument is the one to
adopt wholesale, and it is this project's own guiding principle in
someone else's words: *"If we start with an explicit syntax, we can
always add syntactic shortcuts later… while if we start out with only
the abbreviated forms, then we don't have any real way to revisit those
decisions in a future release"* (§2.6).

**Two shapes to refuse now because Zig's tracker says why.**  A capture
on `else:` should bind **nothing** — Zig's non-inline `else` capture
binds the whole union rather than a payload, and the reporter of
`ziglang/zig#18151` concluded it *"should be removed as they can be
misleading"* (§2.4).  And **one arm covering several members should
either be refused or bind nothing**, because a binding shared across
members has no single set of fields; Zig's `#15504` is that bug with a
pointer capture, and `#2812`/`#1107` are years of argument about the
typing rule.  `docs/ENUMS.md` R1 allows no multi-member arm today, and
keeping it that way is free.

**The one genuine problem is no-shadowing.**  `radius` bound in an arm
collides with any enclosing `radius`, and Luce has no shadowing
anywhere (`docs/LANGUAGE.md`; the `catch NAME:` binding obeys the same
rule).  Three ways out, none free: a rename form in the pattern
(`circle(radius as r):` — a new keyword in a new position); making
match arms the language's first shadowing exemption (`docs/RETURNS.md`
refused `_` partly for the cost of *"writing the language's first
exemption from the no-shadowing rule"*); or leaving it, and letting the
collision be an ordinary duplicate-name diagnostic that names the
outer declaration, which the tree already does well.  **The third is
the recommendation** — it costs nothing, it is honest, and the corpus
will say within a week whether it hurts.

### Q8 — recursion, without a collector and without `Box`

**The field.**  OCaml and Haskell get recursion free because every
non-constant constructor is a heap block and a collector reclaims it —
*"remove either half and the syntax stops meaning what it means"*
(§2.1).  Rust must break the cycle by hand: E0072 says *"any use of the
type being defined from inside the definition must occur behind a
pointer"* and the diagnostic prints `recursive without indirection`
with `help: insert some indirection` (§2.2).  Swift has `indirect`
cases, a compiler-inserted box with a refcount behind it (§2.3).  C++
needs `recursive_wrapper` for the same reason Boost states outright:
*"even if C++ syntax were different such that the above example could
be made to 'work,' `expression` would need to be of infinite size,
which is clearly impossible"* (§2.8).  And Zig routes recursion through
owning containers and hands the whole tree to an arena (§2.4).

**Two independent no-GC ecosystems arrived at "an explicit named
indirection", and one arrived at "the container is the indirection".**
Luce can take the third and skip the first two, which is what the rest
of this section shows.

**What it costs here, and it costs less than the field would predict.**
JSON's recursion in Luce does not go through the union's layout at all:

```text
union Json:
    null
    boolean(value: bool)
    number(value: double)
    text(value: string)
    array(items: list(Json))
    object(fields: map(string, Json))
```

`list(Json)` and `map(string, Json)` are **heap objects** — one handle
each — so `Json`'s unconditional size is finite by construction, and
the recursion is carried by containers that scope ownership already
frees recursively (S20: *"freeing a container frees the objects it
owns, recursively"*).  **The container is the box, and it already has
an owner.**  There is no `Box`, no `indirect`, no arena, and no
collector, and `specs/agree.zig`'s leak census is what proves it.

Direct self-containment — `union List: nil / cons(head: long, tail:
List)` — is infinite for exactly the reason a struct containing itself
is: `06_mir/build.zig`'s `zeroOf` emits an instruction per leaf and
would not terminate, and `04_semantics/helpers.zig` states the rule at
two scales, *"a struct's unconditional expansion must be finite, and
small"*.  The fix is the one `docs/LANGUAGE.md` already prescribes and
already has a spec compiling: `tail: List?`, because *"the recursion
stops at absence rather than at a layout"*.  That is §Q5's converse
cashed — `Shape?` must be writable, or unions get no linked list.

**One question falls out and it is real: what is a union's zero?**
S40 says `var j: Json` holds its type's zero and S41 says the unfilled
state is non-denotable.  For a struct the zero is every field's zero,
recursively; for a union it can only be **one** member's.  The natural
answer is **the first declared member**, which makes `zeroOf`
terminate exactly when the first member is not the recursive one — and
which is why `nil` and `null` come first in every ADT anyone writes.
Whether that is a rule (*the first member is the zero*), a constraint
(*a union's first member may not be recursive, and here is the
diagnostic*), or a refusal (*a union has no zero; `var j: Json` needs
an initializer*) is a ruling, and it is the sharpest small question in
this memo.

**It is also the question that killed Go's sum types twice, which is
worth knowing before answering it.**  Ian Lance Taylor, on the same
"first member is the zero" proposal in 2017: *"since the sum type must
record somewhere the type of the value that it currently holds, I
believe it means that the zero value of the sum type is not
all-bytes-zero, which would make it different from every other type in
Go"*; and in 2023, of the interface-based revival, *"this is a form of
sum type in which there is always another possible option, namely
`nil`.  Sum types in most languages do not work this way, and this may
be a reason to not add this functionality to Go"* (§2.7).  **Neither
objection is Luce's.**  Luce has no all-bytes-zero requirement — S40
already says an unfilled slot holds *its type's zero*, and for an
object that zero is a handle that traps on use — and it has no `nil`
lurking beside the members.  The question here is genuinely open rather
than blocked; it just needs an answer.

### Q9 — does union force parametric polymorphism?

**The field.**  Rust's and Swift's sum types are inseparable from
generics — `Option<T>`, `Result<T, E>`, and Rust's `?` operator needs
`From` on top of both (§2.2).  OCaml and Haskell likewise.  **But sum
types do not require generics and there is a clean precedent that
proves it: Ada's variant records** (§2.7).  Everything this memo has
been asking for is in one section of that language's reference manual,
with no type parameter anywhere in it — a nominal variant part, a
discriminant that is *an ordinary named field* the program can read,
payload-less members spelled `null`, full coverage as a **Legality
Rule** rather than a warning (*"each value of that subtype… shall be
covered by some `discrete_choice`"*), non-overlap likewise (*"two
distinct `discrete_choice`s of a `variant_part` shall not cover the same
value"*), and `Constraint_Error` for reading an inactive variant.  Ada
83 predates every generics-based sum type in this survey.

C's tagged struct-plus-union idiom is the same shape with the checking
removed (§2.7).  And Go's refusal is not about generics at all — its
stated blockers are the `nil` zero value of an interface and the
collector's pointer bitmap (§2.7, §Q4, §Q8), neither of which Luce has.

**What it costs here.**  `std.json` needs **no** generics: `Json` names
`list(Json)` and `map(string, Json)` concretely, and `list(T)` is
already *"a monomorphic heap object rather than a generic"*.  A
concrete union is exactly as parameterised as a `struct` is, which is
to say not at all.

What union does *not* fix is the pressure that already exists and is
already written down: `docs/TYPES.md` D6 — *"Seven numeric types and no
generics means every numeric library function is written once per
element type or refuses six of them"* — which it calls *"the strongest
argument this tree will ever assemble for element-generic functions"*.
Union adds nothing to that pile and takes nothing off it.

**Recommendation.**  Concrete unions, monomorphic, no type parameters,
and `std.json` written as a `Json` union with concrete containers.
Two things to refuse explicitly on the way past, because each is a door
that looks small: a generic `Option(T)` (§Q5) and a generic
`Result(T, E)` (§Q6).  Refusing both is what keeps `types.Type` a
closed union with one new arm rather than a type constructor.

---

## 4. The one page

Read the columns, not the rows.  **Costs** is measured against §1;
**precedent** is who has already paid it; **forecloses** is what taking
the recommendation makes hard to take back.

| | recommendation | costs | precedent | forecloses |
|---|---|---|---|---|
| **Q1 declaration** | `union Shape:` beside `enum`; payload-less members legal and bare; payload fields **named** | one keyword, one declaration form; no `= value`, no backing width, no `Shape(n)` | Zig's two keywords; OCaml inline records; Rust struct-like variants | nothing.  Folding into `enum` later is a superset |
| **Q2 construction** | `Shape.circle(radius = 2.0)`; `Json.null` bare | none — D3's namespacing and ARGS D8's named-only construction both already exist | Swift SE-0155's correction from tuple to labels; Python's "de-construction mirrors construction" | variant-as-a-type, which Rust wants and has not shipped |
| **Q3 ownership** | payload binding is an **alias** (S8/S22); `give`/`copy`/`free` follow the carrying-struct rules; `carriesObjects` is the OR over members | a `Json.number(3)` still needs a verb to be kept, because the *type* carries objects — the same cost `T?` already pays | Swift's copies (one sentence) vs Rust's `ref` + binding modes + partial moves + two RFCs | moving a payload out of a scrutinee, which would need partial-move analysis |
| **Q4 layout** | tag + an owned field run, exactly what a struct value already is; null run for payload-less members | one allocation per payload-carrying construction; `Value` does not grow, `sizeOf` stays 24 | OCaml's tagged blocks; the `struct {code, value}` Go wanted and its collector refused | nothing — the inline-when-all-scalar case is a backend-only change, as `docs/RETURNS.md` step 7 is |
| **Q5 `T?`** | stays its own mechanism; add `Shape?` as a `Type.Payload` arm | one more arm on a closed union; the two mechanisms stay separate and must both be taught | Kotlin and **Zig, which has generics and still chose the built-in** | merging later, which is a language change either way |
| **Q6 sum-typed errors** | not this run; if reopened, an enum/union **in the function attribute**, value-only members | leaves zip's forty raise sites collapsed into one code and a sentence | Zig error sets (works, no generics); Swift SE-0413 (works, warns you off) | nothing — `T!` stays a function attribute under every option |
| **Q7 arm syntax** | `circle(radius):` binding by field name; all fields or none; no literals, no nesting, no guards, no multi-member arms | a payload name colliding with an enclosing local is an ordinary duplicate-name error | Rust's field shorthand; PEP 642's "explicit first, shortcuts later"; Zig's `else`-capture bug | nothing.  Every restriction here reopens as a superset |
| **Q8 recursion** | through **containers** — `list(Json)`, `map(string, Json)`; direct self-containment refused with `?` as the named fix | one ruling needed on what a union's zero is | `std.json.Value` does exactly this; Rust's `Box` and C++'s `recursive_wrapper` are what it avoids | a non-container recursive member (`cons(tail: List)`) unless `?` covers it, which it does |
| **Q9 generics** | concrete, monomorphic unions; `Json` is a type, not a template | numeric libraries still written once per element type — an existing debt, not a new one | **Ada variant records**: every property wanted, zero type parameters | a later generic `Option`/`Result`, deliberately |

---

## 5. Questions for the owner

Split as asked: the ones with one honest answer, which want confirming
rather than deciding, and the ones that genuinely need a ruling.

### 5a. One honest answer — confirm and move on

**A1 — Payload fields are named, never positional.**  A positional
payload is a tuple with a name in front of it, and `docs/RETURNS.md`
refused the tuple in advance and in detail; the parser already prints
the refusal.  Every language that started positional added the named
form later (§2.8).  There is no second option here that is consistent
with the language as it stands.

**A2 — Construction is `Shape.circle(radius = 2.0)`.**  D3's namespace
rule and `docs/ARGS.md` D8's named-only struct construction between
them leave exactly one spelling.

**A3 — A match arm binding is an alias, not a move.**  S8, S11 and S22
already say what reading out of a place you do not own means; `copy`
keeps it and `give` is refused with the words S23 has.  The alternative
is Rust's partial-move machinery, which is a flow analysis S29
explicitly refuses the shape of.

**A4 — Exhaustiveness stays a hard error, with no `@unknown` and no
frozen/non-frozen split.**  Swift needed both because an enum can cross
an independently-versioned ABI boundary; Luce compiles whole programs
from source and has no stable ABI for user types.  ML and GHC warn
because their checkers are expensive; a checker over flat member arms
is linear.  **This is a cost the field pays and Luce structurally does
not**, and it is worth recording as a non-cost rather than leaving it
to look like an oversight.

**A5 — `T?` stays its own mechanism**, and `Shape?` becomes writable.
Five independent reasons in §Q5, and the field's own split runs on
whether a language has generics.  `docs/MISSING.md` has left this open
twice; the corpus has now answered it.

**A6 — Unions are concrete and monomorphic.**  Ada is the proof that
this is a complete design and not a compromise.

### 5b. Genuinely needs a ruling

Ranked by how much else they gate.

**Q-OWNER-1 — What is a union's zero?**  This gates `var j: Json`
(S40), late initialization, array elements, `map` values, and whether a
recursive union is declarable at all.  Three coherent answers: *the
first declared member* (which makes `zeroOf` terminate exactly when the
first member is non-recursive, and is why `nil` and `null` come first in
every ADT anyone writes); *a union's first member may not carry a
payload*, making the zero always free; or *a union has no zero and a
union-typed place must be initialized*, which is a new rule in a
language whose S40 currently has no exceptions.  Go could not answer
this and lost the feature twice over it (§2.7); Luce can, and it is the
first thing to settle because §Q8's recursion depends on it.

**Q-OWNER-2 — Does the object-carrying rule apply per type or per
value?**  A `Json` is object-carrying because *one* of its six members
is, so `values.append(j)` needs a verb even when `j` is
`Json.number(3)`.  That is exactly the cost `T?` already pays and it is
consistent — but `Json` is the type a program will write a hundred
times, where `list(long)?` is written rarely.  If the answer is "yes,
per type, consistency wins", the memo says so once and nobody
relitigates it.  If it is not, the alternative is a flow analysis over
tags, which is a much larger feature than union.

**Q-OWNER-3 — Does a union get Zig's tag reuse?**  `union Shape(Kind):`
naming an already-declared enum as its discriminant, so a program can
hold and compare the tag without the payload.  It has a real user (a
decoder that validates a kind byte before building anything), it is
nearly free while the enum work is in flight and expensive afterwards,
and Swift's `CaseIterable` hole is what not having it looks like ten
years on (§2.3).  If yes, it comes with Zig's three checked rules
including the **ordering** one, which exists because a version without
it miscompiled.

**Q-OWNER-4 — Does the roadmap end at union, or does `std.json` get to
ask for one more thing?**  `docs/MISSING.md` records the owner's *"and
I think we're good"* after union.  §Q6 shows that union removes the
*stated* reason `docs/FAILURE.md` refused typed errors and not the
load-bearing one, and `std.zip`'s forty collapsed raise sites are the
strongest evidence in the corpus that something is still missing.  The
honest framing is not "should errors be sum-typed" but **"is the
roadmap closed, or is one more question allowed to be asked after
`std.json` is written against a concrete union?"**  Everything in §Q6
is designed to be answerable later without moving anything.

**Q-OWNER-5 — Is `string(u)` on a union a thing?**  D5 gives an enum
member its name as a string through an interned table handed to
`libluce_rt`.  Extending it to a union member's *name* costs the same
table and nothing else; extending it to the payload would be a
formatting protocol, which is a different feature and should be refused
by name here so nobody assumes it.

**Q-OWNER-6 — Match arm bindings and no-shadowing.**  `circle(radius):`
inside a function with an enclosing `radius` collides.  Leaving it as
an ordinary duplicate-name error costs nothing and is the
recommendation; the alternatives are a rename form in patterns (a new
keyword in a new position) or the language's first shadowing exemption,
which `docs/RETURNS.md` priced when it refused `_`.  It is listed here
because it is the one recommendation in §Q7 a week of real code could
overturn.

---

## 6. Non-goals — what this memo asks nobody to decide

- **Whether `union` ships.**  It is on the ratified roadmap and it is
  ratified tagged.  This is the briefing for its design memo.
- **The final syntax.**  Every fence above is `text` and every keyword
  in them is a placeholder.  `union` versus a payload-carrying `enum`,
  the exact arm spelling, the diagnostic wording — all of that is the
  design memo's business, and §5 is what it needs answered first.
- **Anything about enums or `match` that `docs/ENUMS.md` already
  ratified.**  R1's restricted statement, R2's `Method(n) -> Method?`
  and R3's bare arms are inputs here, not open questions.  Where this
  memo touches them it extends them.
- **Reopening `T!` as a type.**  `docs/FAILURE.md` settled that
  fallibility is a function attribute and `docs/MISSING.md` records
  that it survived contact with the implementation.  §Q6 prices what a
  *typed reason* would cost inside that design; it does not propose
  moving the attribute.
- **Reopening ARC, refcounting or GC.**  `docs/MEMORY.md` says *"Do not
  relitigate this section."*  Nothing here does; where a surveyed
  design depends on collection — OCaml's boxing, Swift's `indirect` —
  that is recorded as a cost of the design, not as a reason to
  reconsider the ruling.
- **`std.json`'s API.**  It is the motivating customer and it is
  deliberately not sketched: a `Json` union is what it wants, and what
  its functions look like is a design memo of its own, written after
  §5's answers rather than guessing at them.
- **Generics.**  §Q9 concludes union does not force them and
  `docs/TYPES.md` D6's numeric-tranche debt is unaffected either way.
  That debt is real and it is not this memo's.

---

*Gathered, not decided.  Nothing in the tree moved to write this: no
keyword, no host slot, no version number, not one line of Zig.  The
next thing that should happen to this file is answers to §5 — after
which it becomes the evidence section of a design memo, and that memo
gets a **Ratified** banner like every other one in `docs/`.*
