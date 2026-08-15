# Unions — one of these, and the language always knows which

> **Status (2026-08-10): built**, the day it was scheduled, in one
> vertical, on both engines.  The eighteen decisions shipped as
> written, the three held questions were taken as their written
> recommendations, and the two places the code departed from this
> memo are recorded in "As built" at the bottom.

Run five of the ratified roadmap (`docs/MISSING.md` Tier 2), and the
last of it: with this built the owner's *"and I think we're good"* is
the whole remaining language.  Its one deciding question was answered
before the memo was written — owner, 2026-08-04: *"Tagged unions
obviously"* — so this is not a memo about whether the tag exists.  It
is about what a member may carry, what carrying it means for memory,
and what binding it in an arm means for ownership.

`docs/UNION_RESEARCH.md` is the evidence and this memo does not
re-argue it: where a claim about another language is load-bearing the
section is cited (§2.4, §Q8) and the citation is where the primary
source lives.  What this memo adds is the decisions, taken against
this tree as it stands today rather than as it stood when the survey
was gathered — three things landed in between and two of them move a
recommendation.

**Every fenced block here is `text`**, because none of it compiled
when the memo was written.  It all compiles now; the verified samples
live on the site and in `specs/union_spec.zig`, and these fences stay
`text` because a design memo's examples are the design's, not the
build's.

---

## The evidence

**`std.json` is the customer, and it is the whole specification.**  A
JSON value is one of six things — null, bool, number, string, array,
object — and two of the six are heap objects containing more JSON
values.  It is the recursion case and the payload-ownership case at
once, and a design that serves it honestly serves everything smaller.
Nothing else in the corpus is waiting: `editor.luc`'s fifteen-way key
chain and `std.zip`'s `method == 8` were *enum* debts and enums
collected them on the day they landed (`docs/ENUMS.md`, as built).
What is left over from that run is exactly the part that carries
something.

**The research's headline finding is the one that decides the shape.**
§1.3: a struct value is already an out-of-line, deep-copied and
deep-freed field run — `Value.strukt`'s *"`bits` addresses `length`
fields"*, `.strukt => .ptr` on the compiled path, `ownValue` and
`dropStorage` as the recursive copy and the recursive release.  **Luce
already boxes; it simply never had to say so.**  What OCaml gets from a
collector and Rust spells `Box`, this tree has as a reference-counted
allocation freed at its last release.  So the layout question was never
"how do we afford a box".

**Three things landed after the survey was gathered, and two of them
move an answer.**

- **`docs/BYTES.md` B2: `new list(T)` is handed the element zero**, as
  `new array` already was.  That turns §Q8's zero question from a
  matter of taste into a constraint: a union with *no* zero cannot be
  a list element at all, and `list(Json)` is the entire point of the
  feature.  The research could not have known this; it is decisive.
- **`docs/ENUMS.md` as built A2 and A3.**  A2 spent the name table:
  `string(m)` is a compare-and-branch tree over the tag answering an
  interned constant, *"nothing new in `libluce_rt`"*.  A3 settled that
  an enum's zero is its first declared member.  Union inherits both
  rather than inventing beside them.
- **`luce_rt_struct_make(runtime, fields, count, out)` takes a
  count.**  The one export that builds a field run already builds a
  run of any length, which is the difference between a union needing
  a runtime and a union needing none.

**And the two blockers that killed this feature elsewhere are not
here.**  Go refused sum types twice, on the zero value not being
all-bytes-zero and on the collector's need for a pointer bitmap (§2.7).
Luce gives every unfilled slot its type's zero value, whatever that
zero is, and has no collector scanning anything.  Neither objection
transfers, and the layout Go sketched and could not have is simply the
layout available here.

## The neighbors, in one paragraph each

**Ada** is the proof that none of this needs generics (§2.7): a
variant part with a readable discriminant, payload-less members,
coverage as a *Legality Rule* rather than a warning, and no type
parameter anywhere in the section.  **Rust** is where payload
ownership was done properly and where a decade of ergonomics debt
lives — `ref`, default binding modes, partial moves, E0507, two RFCs
and an edition break, all of it because a payload binding may be the
payload itself rather than a copy of it (§2.2, §2.8 pattern 4).
**Swift** is the counterweight: enums are value types, so `case
let .circle(r)` binds a copy and the specification is one sentence
(§2.3) — and its `indirect` recursion is a compiler-inserted
refcounted box, where Luce lets the recursion travel through its
reference-typed containers instead, so no special case is needed.
**Zig** is the closest sibling and gives two answers
Luce cannot take — the untagged `union` whose safety check disappears
in release modes (`docs/MODES.md` forbids exactly that), and an
arena-owned `std.json.Value` with **no `deinit` at all** (§2.4, §Q3a).
What Luce *does* take from Zig's JSON is the half that works: the
recursion travels through reference-typed containers, so the container
is the indirection and there is no `Box`.  **Python** is the cautionary tale
about bare names in patterns — two PEPs and a rejection (§2.6) — and
`docs/ENUMS.md` R3 already removed the question rather than answering
it.  **OCaml and Haskell** price the alternative: uniform boxing makes
recursion free and a collector mandatory (§2.1).

## Decisions

| | decision |
|---|---|
| **D1** | **Declaration mirrors `struct` and `enum`**: `union Shape:` then one indented member per line, snake_case members under a TitleCase type name.  A member carries a parenthesized **field list** — `circle(radius: double)` — or nothing at all, and a payload-less member is spelled bare.  Payload fields are **named, always**; a positional payload is refused with the sentence the parser already prints, because `circle(double, double)` is a tuple with a name in front of it (`docs/RETURNS.md`, and §Q1).  What a union does *not* get, and this is the line: no `= value`, no backing width, no `Shape(n)`.  A union member is not a number, and giving it two identities is how a type stops being legible. |
| **D2** | **At least one member must carry a payload.**  A union of bare members *is* an enum — cheaper in every way, with a backing width, `int(m)`, `Method(n)` and no allocation — and writing one is refused by a sentence naming `enum`.  This is not tidiness: it is what keeps D8's cost off the one shape that would feel it. |
| **D3** | **Members are namespaced, always** — `Shape.circle`, `Json.null` — through the head-names-a-declaration path that already serves `Struct.func`, `module.name` and `Method.stored` (ENUMS D3, unchanged).  **A member is not a type**: `let c: Shape.circle` is refused for `docs/RETURNS.md`'s reason.  Rust made the same refusal and has an eight-year-old postponed RFC asking to undo it (§2.2); refusing it on day one costs nothing and reopens cleanly. |
| **D4** | **Construction is a namespaced call with named arguments**: `Shape.circle(radius = 2.0)`, `Json.null` with no parentheses because parentheses mean a payload.  This is `Bag(label = "a", items = [1, 2])` with a namespace in front of it — `docs/ARGS.md` D8's named-only struct construction, reached through D3's resolution — so it needs no new path and no new diagnostic family.  Defaults on payload fields fall out of D8 for free and are allowed.  `Shape.circle` bare where a payload is expected is `luce.sema.construct` naming the fields it wants, never a function value (`docs/MISSING.md` Tier 4 has none). |
| **D5** | **`match` extends ENUMS R1/R3; it does not fork.**  An arm is a bare member name, and a payload arm names its fields: `circle(radius):` binds a local per field, **by the field's own name** (Rust's shorthand, which reads best in an indented language and needs no second token).  `circle:` with a payload is legal and binds nothing — the arm that only cares which member it is.  A *partial* field list is refused, naming the missing fields the way struct construction already does.  Exhaustiveness, `else`, duplicate arms and the "this else can never run" refusal are R1's, unchanged, and the diagnostics are the ones already written. |
| **D6** | **No literal patterns, no nested patterns, no guards, no or-patterns, no multi-member arms, and no capture on `else`.**  Each is a separate feature and each is where Python's and Rust's ergonomics debt came from; Zig's own tracker says why the last two are traps (§2.4, §Q7).  PEP 642's process argument is the house's own principle in someone else's words: *"if we start out with only the abbreviated forms, then we don't have any real way to revisit those decisions"* (§2.6).  Every restriction here reopens as a superset. |
| **D7** | **`match` is the only door.**  There is no field access on a union value, no tag test operator, and no way to name a payload outside an arm.  So *wrong-arm access is unrepresentable* rather than checked: Ada raises `Constraint_Error` for it and Zig panics, and this design has no such run-time check to define because no program can ask the question. |
| **D8** | **A union value is a struct value whose field 0 is the tag.**  The run is the member index followed by the active member's payload fields in declaration order; `luce_rt_struct_make` builds it unchanged, `ownValue` copies it, `dropStorage` frees it, and the runtime never learns that unions exist.  On the compiled path a union is `.ptr` and `resultSize` is 8; on the interpreter it is `Value.strukt`, so `sizeOf(Value)` stays 24 and no thirteenth tag is spent.  **This is the memo's one departure from the research's layout (§Q4) and the argument is below.** |
| **D9** | **A union is a value type, and ARC needs no new rule.**  A union value is a struct-shaped value: it copies when assigned or passed, and a payload field that is a **reference type** (a `list`, a `map`, a `class`) is shared exactly as that reference is anywhere else — ARC retains it when the union is copied and releases it when the last reference goes.  A payload that is a **value type** is copied with the union.  There are no ownership verbs, because a value type never had any (`docs/MEMORY.md`). |
| **D10** | **A payload binding names the payload.**  For a **reference** payload the arm's binding is another reference to the same object — reading or mutating through it is seen by whoever else holds it, exactly as any shared reference is.  For a **value** payload the binding is an ordinary copy.  There is nothing to move and no verb to write; ARC keeps a bound reference alive for as long as the binding lives, which is what removed the machinery Rust spent `ref`, binding modes, E0507 and two RFCs on (§2.2). |
| **D11** | **An arm binding is an ordinary name in the arm's scope** — like `catch NAME:` — and obeys the no-shadowing rule.  A payload field colliding with an enclosing local is the duplicate-name diagnostic the tree already prints well.  No rename form, and no first exemption from no-shadowing (`docs/RETURNS.md` priced that when it refused `_`). |
| **D12** | **A union's unconditional expansion is `1 + the largest member's`**, counted by `valueCount` into the same `max_struct_values = 4096` bound and the same strongly-connected-component check that refuses struct cycles.  *Largest*, not the sum, because only one member is ever live — but every member is counted, so a member that unconditionally contains the union makes the type infinite whichever member it is.  The refusal names `?` and the containers as the two fixes, exactly as the struct-cycle diagnostic already does. |
| **D13** | **A union's zero is its first declared member, with every payload field at its own zero** — ENUMS A3 generalized, the zero-value rule honored, and forced by BYTES B2 (a type with no zero cannot be a container element, and `list(Json)` is the point).  **No ordering constraint is needed**, and the argument is below: D12 has already refused every member that could make the zero recurse. |
| **D14** | **`T?` stays its own mechanism, and `Shape?` becomes writable.**  Five independent reasons in §Q5 and the field's own split runs on whether a language has generics; Zig has them and still chose the built-in.  The converse is the cheap half: one arm on `types.Type.Payload` beside `strukt` and `heap`, which is what gives a union a recursion terminator that is not a container.  `Shape??` stays unrepresentable, because `Payload` is a union of its own. |
| **D15** | **Containers, fields and keys.**  `list(Json)` and `map(string, Json)` work by construction; a union element keeps the 24-byte boxed cell, exactly as a struct element does (BYTES B1's `.value` kind).  A union may **not** be a map *key* — keys are `long` and `string` and always have been, for `hashOf`'s reason, which is the same narrowing ENUMS' D9 met on
contact.  A struct field may be a union, and a method may mutate a receiver holding one exactly as it mutates any other value field. |
| **D16** | **`string(u)` answers the member's name**, by ENUMS A2's mechanism unchanged — a compare-and-branch over the tag answering an interned constant, nothing new in `libluce_rt`.  **The payload is never formatted**: that is a formatting protocol, it is a different feature, and it is refused here by name so nobody assumes it.  `==` on unions is refused in this run by a sentence naming `match` — **and the refusal is transitive**, because a struct's `==` is field-by-field `==`: see *D16's `==`, as it had to be corrected* below. |
| **D17** | **Methods and namespace functions carry over whole** from `docs/METHODS.md`, as they did for enums (D7 there): `Json.parse(text)` is a namespace function, `j.kind()` a method, told apart by whether the first parameter is `self`.  A method may mutate its receiver whether or not the union holds a reference payload, because a union is a value.  A member name and a declaration name colliding inside one union is the duplicate-name refusal two members already get. |
| **D18** | **Inside the compiler the word is `variant`.**  The language keyword is `union`; Zig's own `union` keyword takes the name in the one place it must not be dodged around — `types.Type`'s arm — so the arm is `.variant: u32`, the table is `Program.variants`, and the three instructions are `variant_make` / `variant_tag` / `variant_field`.  One word inside, one word outside, the `strukt` precedent, and one sentence in `types.zig` saying so.  Diagnostics say `union`, because a diagnostic speaks the language's vocabulary and not the compiler's. |

---

## The shape of a value, and why the runtime learns nothing

The research proposed (§Q4) a representation of its own: a thirteenth
`Value.Tag` with the member index in `inline_head`, `bits` addressing
the payload run, and `{i32 member, ptr run}` on the compiled path.
**This memo takes a different one, and the reason is that the other one
costs a semantic and this one costs a field.**

A union value is a run of `Value`s whose slot 0 holds the member index
and whose remaining slots hold the active member's payload fields:

```text
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)

Shape.empty                        run = [ 0 ]
Shape.circle(radius = 2.0)         run = [ 1, 2.0 ]
Shape.rect(width = 3, height = 4)  run = [ 2, 3.0, 4.0 ]
```

Read the consequences off the existing code rather than off this page:

- **`luce_rt_struct_make` already builds it.**  Its signature is
  `(runtime, fields, count, out)` — a run of any length — so
  `variant_make` is the struct path with one more register in front.
  No new export, and the header's promise that *"the run that backs it
  is never written to after it is built"* holds unchanged, because a
  union value is built whole and never assigned into.
- **`ownValue` and `dropStorage` need no member table and no new
  arm.**  They walk a run and switch on each *slot's* own tag; slot 0
  is an `int` and no-ops in both walks.  Releasing a `Shape.circle`
  releases nothing, releasing a `Json.array` releases its list
  reference — the static predicate is conservative, the runtime walk is
  exact, and both already exist.
- **Nothing new crosses the C boundary.**  `boxTag` answers `.strukt`,
  a union element in a `list` is the boxed cell a struct element is,
  and a union crossing into `libluce_rt` is a pointer to a run — which
  is what the runtime has read since struct values existed.
- **Reading a payload is an inline load.**  `struct_get` is a `gep`
  plus an unbox with no runtime call; `variant_field` is the same at
  `1 + field`, and `variant_tag` is the same at 0.  A `match` over a
  union costs one load and the compare-and-branch tree ENUMS already
  emits.
- **The engines grow arms, not code.**  About six switches answer
  `.variant` with exactly what they answer `.strukt` — `valueType`
  → `.ptr`, `resultSize` → 8, `boxTag` → `.strukt`, the box and unbox
  paths, and stage 4's `ownsStorage` → true.  What they may *not* do is reach the same
  table: a variant index names a row in `Program.variants` and a
  struct index a row in `Program.structs`, which is why `Type.storage()`
  answers `.variant` with itself rather than pretending it is a
  `.strukt` with a different index.  That pretence would have made
  every one of those switches free and exactly one of them silently
  wrong, which is the trade this house does not take.

**What it costs, stated rather than discovered.**  One allocation per
construction, *including* a payload-less member, whose run is one slot
where the research's shape would have made it a null pointer and free.
That is the price of the whole design being one mechanism, and D2 is
what keeps it off the shape that would feel it: a union of bare members
is refused, so the allocating payload-less members are the `Json.null`
kind — one member among five that all allocate anyway — and never the
enum somebody wrote with the wrong keyword.

It is the same cost `docs/RETURNS.md` §4 priced for the synthesized
return struct, with the same honest note (*libluce_rt is an opaque
external library, so LLVM's O3 pipeline does not see through the
make/get/free triple*) and the same scheduled escape: a union all of
whose payloads are scalars and small can go inline in a fixed-width
slot, changing nothing above stage 6.  **That escape is scheduled and
not taken, and it should be measured before it is built** — `bench/`
has the harness, and the row that would move does not exist yet.

`docs/TYPES.md`'s narrow widths are the one place this is not free: a
run is a run of `Value`s, so `circle(radius: half)` costs 24 bytes for
two.  Arrays are where narrow widths pay, and a union payload is not
an array.

## Memory: a value with reference payloads

Nothing in `docs/MEMORY.md` changes.  A union is a value type, so it
copies when assigned or passed; a payload field that is a reference
type is shared like any reference, and ARC retains and releases it with
the union.  There are no ownership verbs and no situations to
enumerate — the two kinds do what they do everywhere, which is the
thing to check hardest rather than assume, and which is what the
two-engine leak census is for.

**Construction stores the payload.**  A payload field is an ordinary
place: a value payload is copied in, a reference payload is shared.

```text
var kids = new list(Json)
let a = Json.array(items = kids)             # a and kids share one list
kids.append(Json.null)                       # seen through a as well
let c = Json.array(items = new list(Json))   # a fresh list, held here
```

**Keeping a member is ordinary.**  Because a union is a value, storing
one in a list or a field copies the value; a reference payload inside
it is retained, so the object it names stays alive for as long as any
copy does:

```text
var values = new list(Json)
var j = Json.number(value = 3.0)
values.append(j)               # j is a value; the list holds its own copy
```

The research listed this as a question for the owner (Q-OWNER-2), and
ARC answers it without a rule: a union is a struct with a tag, a struct
is a value, and a value copies.  A `Json.number(value = 3.0)` holds no
reference, so copying it copies bytes; a `Json.array` holds a list
reference, so copying it retains that list.  The compiler needs to know
only whether a union *could* contain a reference — for the worker
boundary and for where ARC inserts retain/release — and that is the OR
over the members' fields, the same conservative question `T?` answers.

**A payload binding names the payload** (D10).  A reference binding is
another reference to the same object; a value binding is a copy:

```text
match doc:
    array(items):
        items.append(Json.null)  # items is the same list doc holds;
                                  # the append is seen through doc too
    text(value):
        label = value            # a value payload: an ordinary copy
    else:
        label = "other"
```

The scrutinee may be any expression of union type; a temporary one
lives to the end of the statement, and the `match` *is* the statement,
so an arm's binding is valid for the whole arm.

**And the runtime walks are exact.**  Copying a union copies its value
payloads and retains its reference payloads; its last release drops
those references; a payload-less member holds and releases nothing,
because `ownValue` and `dropStorage` switch on each slot's own tag.

## Finiteness, recursion, and the zero

**The recursion goes through the containers, and they already have
owners.**

```text
union Json:
    null
    boolean(value: bool)
    number(value: double)
    text(value: string)
    array(items: list(Json))
    object(fields: map(string, Json))
```

`list(Json)` and `map(string, Json)` are reference objects — one handle
each — so `Json`'s unconditional expansion is finite by construction,
and a container's last release freeing the objects it held, recursively,
is the whole of the reclamation story.  No `Box`, no `indirect`, no
arena, no tracing collector.  Zig's `std.json` reaches the same shape
and then hands the tree to an arena because it has nowhere else to put
the reclamation (§2.4); here ARC frees the tree at its last reference,
and `specs/agree.zig`'s leak census is what proves it.

**Direct self-containment is infinite and is refused.**  `union List:
nil / cons(head: long, tail: List)` is infinite for exactly the reason
a struct containing itself is, and D12's counting rule says so through
the machinery that already exists: `sumShape` and the
strongly-connected-component walk in `declarations.zig` take union
nodes in the same graph as struct nodes, and a cycle collapses to the
same refusal.  The fix is the one `docs/LANGUAGE.md` already
prescribes — `tail: List?`, *"the recursion stops at absence rather
than at a layout"* — and D14 is what makes it writable.

**And that is why the zero needs no ordering rule.**  The research
called this the sharpest small question in its survey and offered three
answers (§Q8, Q-OWNER-1).  Two of them are now closed by things the
survey did not have:

- *"A union has no zero; a union-typed place must be initialized"* is
  **refuted, not disfavoured.**  BYTES B2 hands `new list(T)` the
  element zero, and `new array(T, n)` fills every cell with it.  A
  union with no zero could not be a list element, and `list(Json)` is
  the motivating program.
- *"The first member may not carry a payload"* buys nothing.  It would
  make the zero cheap, and cheap is not the problem; `Json.null` is
  first because every ADT anyone writes puts the empty case first, and
  a language that *requires* it is a language that refuses
  `union Shape: circle(...) / rect(...)` for no reason a reader could
  give.

So: **the zero is the first declared member with every payload field
at its own zero**, which is ENUMS A3 one level up.  `zeroOf` recurses
into the first member's fields and terminates, and it terminates for
every union the compiler accepted — because the only recursion that
survives D12 goes through a `?` (whose zero is `none`) or a container
(whose zero is the null reference), and neither recurses.  **The
"recursive first member, refused with a sentence naming the reorder"
rule that looked necessary is not**, and writing it would have been a
diagnostic that can never fire.

One property to name rather than leave implicit: `var s: Shape` is
`Shape.circle(radius = 0.0)` — a real value of a member the programmer
did not choose.  That is the zero-value rule doing exactly what it does
for a struct (`var p: Point` is a zeroed `Point`) and for an enum (A3),
and its corollary applies unchanged: the "did I set it?" information is
the bool you branched on, and it belongs in the program.

## The worked example

```text
union Json:
    null
    boolean(value: bool)
    number(value: double)
    text(value: string)
    array(items: list(Json))
    object(fields: map(string, Json))

func write(out: builder, j: Json):
    match j:
        null:
            out.append("null")
        boolean(value):
            out.append(string(value))
        number(value):
            out.append(string(value))
        text(value):
            out.append(quoted(value))
        array(items):
            out.append("[")
            var first = true
            for item in items:
                if not first:
                    out.append(",")
                write(out, item)
                first = false
            out.append("]")
        object(fields):
            out.append("{")
            var first = true
            for key in fields.keys():
                if not first:
                    out.append(",")
                out.append(quoted(key))
                out.append(":")
                write(out, fields.get(key, Json.null))
                first = false
            out.append("}")
```

Six things in that program are worth pointing at, because each is a
decision above doing its job.  The arms are exhaustive and there is no
`else`, so the day a seventh member arrives this function stops
compiling and names it (R1).  `value` is bound three times in three
arms and each is a different type — the fields are scoped to the
member, which is the lesson OCaml's inline records teach and Haskell's
top-level field names are the warning about (§2.1).  `items` and
`fields` name the scrutinee's own containers, so iterating them reads
shared references and copies nothing (D10).  `write(out, item)` passes
a `Json` value and recurses through the container, not through the
layout.  The `Json.null` handed to `fields.get` is a default value that
costs one run.  And `string(value)` on the `boolean` and `number` arms
is the ordinary conversion constructor — nothing here is a formatting
protocol, which D16 refuses by name.

Building one reads the way taking it apart does, which is Python's
stated principle for class patterns (§2.6) and Swift's correction in
SE-0155:

```text
var fields = new map(string, Json)
fields.put("name", Json.text(value = "luce"))
fields.put("tags", Json.array(items = [Json.number(value = 1.0)]))
let doc = Json.object(fields = fields)
```

The last line shares the map into the value: `fields` and the object
`doc` holds now name the same map, and ARC keeps it alive for as long
as either does.  Written inline — `Json.object(fields = new map(string,
Json))` — the map is simply created in place.

## Three boundaries this run does not cross

**`T!` does not move, and this run promises `std.json` nothing about
error shapes.**  Errors stay a function attribute with two codes and a
message (`docs/FAILURE.md`), and a parse failure is `user_error` plus a
sentence.  §Q6 is careful about which half of FAILURE's refusal union
removes: the *stated* reason for refusing `Result<T, E>` was *"no
generics, no tagged unions"*, and half of that premise changes here —
but the load-bearing reason does not.  An error **unwinds and ARC
releases each reference on the way out**, so a reason that named a
reference object would have the unwind dropping it as it passed, and a
value-only reason is already safe because `Runtime.raise` copies the
message's words.  If it ever reopens, the shape that fits keeps
FAILURE's design intact —
fallibility stays an attribute and the attribute grows a named error
type, `-> list(Entry)!ZipError`, with `catch reason:` binding something
a handler can `match`, and **an error reason may be a union of
value-only members** or nothing.  Zig's *inferred* sets are the trap on
that road and FAILURE already named their cost in the words Zig's own
reference uses (§2.4).  Whether the question may be asked at all is
R3 below.

**No generics enter, and `std.json` needs none.**  `Json` names
`list(Json)` and `map(string, Json)` concretely, and `list(T)` is
already *"a monomorphic heap object rather than a generic"* — a
concrete union is exactly as parameterised as a `struct`, which is to
say not at all.  Ada is the proof that this is a complete design and
not a compromise (§Q9).  Two doors stay explicitly shut on the way
past: a generic `Option(T)` (D14) and a generic `Result(T, E)`
(above).  Refusing both is what keeps `types.Type` a closed union with
one new arm rather than a type constructor.  What union does *not* fix
is the pressure already written down — `docs/TYPES.md` D6's *"every
numeric library function is written once per element type or refuses
six of them"* — and it adds nothing to that pile either.

**Zig's tag reuse is not taken in this run** (R2 below).  `union
Shape(Kind):`, naming an already-declared enum as the discriminant so a
program can hold and compare a tag without a payload, has a real user
and it is nearly the only union feature the enum work made cheap.  It
also has three checked rules and a scar: Zig enforces name
correspondence both ways *and declaration-order agreement*, in three
diagnostics that appear nowhere in its language reference, because a
version without the third miscompiled (§2.4).  The decoder case it
serves is already writable — declare the enum, validate the byte with
`Kind(n) -> Kind?`, match on it, and construct the union member in the
arm — and taking it later is a superset, because a member index is not
serialized anywhere and no artifact records it.

## Where it lands

**Stage 2**: one keyword, `union`, verified free of use across std and
the corpus first.  `match` is already there.

**Stage 3**: a declaration form mirroring struct's, with a member list
whose entries carry an optional parenthesized field list; match arms
grow an optional field-name list.  Nothing else in the grammar moves.

**Stage 4**: the variant table beside the struct layouts and the enum
table; member resolution through the existing head-names-a-declaration
path; construction through `docs/ARGS.md` D8's named-argument checker;
`sumShape`/`valueCount`/the cycle walk extended per D12; the
contains-a-reference check per D9; arm binding scopes beside
`catch NAME:`'s; exhaustiveness reusing the `luce.sema.match`
diagnostics already written, whose *"match dispatches over an enum, and
X is not one"* sentence learns a second word.  New diagnostic family:
`luce.sema.union`.

**MIR**: one `types.Type` arm and one `Type.Payload` arm; one table
(`Program.variants`); three instructions —

```text
variant_make  { variant: u32, member: u32, fields: []Register }
variant_tag   { target: Register }            -> the member index
variant_field { target: Register, variant: u32, member: u32, field: u32 }
```

— each with a verifier rule: a `variant_make`'s registers match the
member's declared field types, a `variant_field` reads a register of
that union type, and a tag out of range is refused the way ENUMS'
`isMember` refuses a number no member holds — which is where A4's
fallthrough promise is defended.  The printer prints them.
`match` over a union lowers to `variant_tag` and the compare-and-branch
tree enums already emit, with the last arm of an exhaustive match as
the fallthrough (A4, unchanged); payload binds are `variant_field`
reads in the arm's own block.  **`format_version` moves 29 → 30**, and
the wire fingerprint moves with it whether or not anyone remembers,
because ENUMS' run made it hash the type tags as well as the
instruction set — a type travels as its tag's ordinal, so an arm
appended to `types.Type` renumbers the wire.

**Engines**: `libluce_rt` learns **nothing** — no export, no semantic,
no table (D8).  `08_llvm/lower.zig` grows three instruction arms and
the six type-switch arms named above.  `interpreter/machine.zig` grows
the same three, calling the same runtime helpers.  **`abi.version` does
not move**: no host service is involved, and a union never crosses the
host boundary as anything but a value the program already had.

**Specs** (`specs/`, both engines, compared on prints, trap code, trap
message, call trace, **leak census** and the world left behind):
construction and dispatch for every member shape; payload binding of a
value and of a reference; a union whose reference payload is shared,
retained and released, including a caught error unwinding past one,
which is where a missed release shows up in the leak census; the zero
of a late `var`, of an `array(Shape, n)` and of a `list(Json)` element;
recursion through a container built, walked and released; `Shape?`
narrowed; `string(u)`.  And
refusal rows for each of D1's positional payload, D2's all-bare union,
D3's `let c: Shape.circle`, D5's partial field list and missing member,
D12's self-containing union, D15's union map key and D16's `==`.

**Site**: a tour page and the reference in the same commit, fenced and
verified, and `docs/MEMORY.md` gains no clause — which is the claim
the specs are there to keep honest.

## Sequencing

**After the list-speed run** — in flight when this was written, and
since landed: it changed how a `list` element is reached from
generated code (`docs/CODEGEN.md`'s `bench/lists` row, 29.10x then,
2.60x now), and union's motivating program is a tree of lists and
maps.
Racing two runs through `lower.zig`'s container path is the one way to
lose both — the BITWISE.md lesson, and BYTES.md took it too.  Union
moves `format_version` and no ABI; the list run moves neither; they do
not collide on a version number, only on a file.

**On the current builder, not behind HIR.**  `src/luce/05_hir.zig` is a
barrel with no code and a price tag: six couplings hold check and lower
together in `builder.zig`, and the honest cost of union going first is
that it adds to two of them.  `producesFreshStorage` and
`borrowsStoredValue` answer by reading emitted instructions back off
the tape, so they grow a `variant_make` arm and a `variant_field` arm —
two more sites the eventual move must carry — and an arm's payload
bindings are a fifth scope-introducing form in a file that already has
four.  Neither is a new *kind* of coupling, which is the whole test:
union needs no new question of the checker that `struct_make` and
`catch NAME:` do not already ask.

The argument the other way is real and should be stated: HIR phase 2
has to reproduce today's MIR byte for byte, and every instruction added
first is more surface for that move to be identical over.  It loses
anyway, on two grounds.  Stage 5 has no code at all and no schedule,
and deferring the last run of a ratified roadmap behind an unwritten
stage is how a roadmap stops being one.  And the part of HIR that is an
*improvement* rather than a relocation — moving those three tape-reading
predicates onto node kinds — is self-contained, can be done before or
after union with the MIR unchanged, and is strictly easier to do
against a stable instruction set than against one that is about to
grow three.

So: list-speed, then union on the current builder, then HIR when it is
its turn, carrying two more arms than it would have.

---

## For ratification

Three, and only the ones that genuinely need the owner.  The research's
§5a — named payloads, namespaced construction, payload bindings, hard
exhaustiveness, `T?` staying its own mechanism, monomorphic unions —
had one honest answer each and this memo took them as decisions (D1,
D4, D5, D9, D10, D14, and the generics boundary above) rather than
spending a question on each.  Two of §5b's six are
answered above instead of asked: the per-type reference question (ARC
answers it — a value copies, a reference is retained), and
match-arm shadowing (leave it as the ordinary duplicate-name error, D11
— it costs nothing and the corpus will say within a week whether it
hurts).  A third, `string(u)`, is D16; it is the one D-row that could
be dropped whole if the owner wants union's surface minimal in this
run, and nothing else in the memo moves if it goes.

| | question | recommendation |
|---|---|---|
| **R1** | **What is a union's zero?**  It gates `var j: Json` (the zero-value rule), array elements, list element zeros (BYTES B2), and whether a recursive union is declarable at all.  It is the question Go could not answer and lost the feature over, twice (§2.7). | **The first declared member, with every payload field at its own zero** (D13) — ENUMS A3 one level up, and the only answer BYTES B2 leaves standing, since a type with no zero cannot be a container element.  **No ordering constraint comes with it**: D12 has already refused every member that could make the zero recurse, so a "recursive first member" rule would be a diagnostic that can never fire.  This is a departure from the research's framing and the argument is above. |
| **R2** | **Does a union get Zig's tag reuse** — `union Shape(Kind):` naming an already-declared enum as its discriminant, so a program can hold and compare a tag without a payload? | **Not in this run.**  Its user — a decoder that validates a kind byte before building anything — is served today by an enum, `Kind(n) -> Kind?` and a match arm that constructs the member; and it comes with Zig's three checked rules including the ordering one, which exists because a version without it miscompiled.  The research called it nearly free *while the enum work was in flight*; that moment has passed, and it now costs what a feature costs.  It reopens as a superset — no member index is serialized, so nothing is foreclosed. |
| **R3** | **Is the roadmap closed after union, or may `std.json` ask one more question?**  `docs/MISSING.md` records *"and I think we're good"* after union.  §Q6 shows union removes the *stated* reason `docs/FAILURE.md` refused typed errors and not the load-bearing one, while `std.zip`'s forty raise sites collapsed into one code and a sentence are the strongest evidence in the corpus that something is still missing. | **This run promises nothing**: errors stay `T!`, two codes, a message — the first of the three boundaries above.  The recommendation is that the *question* be allowed to be asked once `std.json` is written against a concrete union and its callers exist — because zip's five error families are five things a caller might branch on, and zip's callers do not exist yet.  Everything in §Q6 is designed to be answerable later without moving anything, and SE-0413's warning is the reason not to answer it early: *"Resist the temptation to use typed throws because there is only a single kind of error that the implementation can throw."* |

## Non-goals

- **Whether `union` ships.**  Ratified, and ratified tagged.
- **A second dispatch statement.**  `match` is ENUMS R1's and this memo
  extends it; ENUMS R3's bare arms are an input, not an open question.
- **Reopening `T!` as a type**, or the memory model — value types,
  reference types, or ARC (`docs/MEMORY.md`).  Where a surveyed design
  depends on a tracing collector — OCaml's uniform boxing — that is
  recorded as a cost of the design.
- **`std.json`'s API.**  It is the customer and it is deliberately not
  sketched beyond the type and the walk: what its functions look like
  is a memo of its own, written after this one is ratified.
- **The inline representation** for small all-scalar unions.  Scheduled,
  backend-only, and to be measured before it is built.

## SELF amendment — 2026-08-08

D17's receiver spelling is superseded before union is implemented.
Union members follow the built struct/enum rule from `docs/SELF.md`:
plain member functions have implied self, namespace members say
`static func`, and receiver writing is inferred.  A method may mutate
its receiver whether or not the union holds a reference payload — a
union is a value, mutated by writing its binding — so there is no
receiver restriction to revive.

---

## As built (2026-08-10)

Built the day it was scheduled, in one vertical, on both engines.  The
eighteen decisions shipped as written, with the SELF amendment above
applied in place of D17's original receiver spelling, and the three
held questions were taken as their written recommendations: the zero
is the first declared member with every payload field at its own zero
(R1), there is no discriminant reuse (R2), and this run promised
`std.json` nothing about error shapes (R3).  Two places the code
departed from the memo, each recorded where it lives; each is here
with the reason, and each has a spec.

| | departure, and where it is argued |
|---|---|
| **A1** | **Runs are padded to one static length per union** — `1 + the widest member's field count`, D12's own number made the run length — where D8's letter said a run was the member index followed by the *active* member's fields, so that `Shape.empty` would have been one slot.  It could not be: generated code re-derives a value's box from its static type alone at sites where the run pointer is legitimately null — a call's result is a bare pointer, and `fillBoxShape` writes the length word once in the entry block — so the length had to be a fact about the type, exactly as a struct's is.  A member with fewer fields pads its tail with `none` slots, which hold nothing, copy as themselves, and release nothing, so the value walks never notice.  `types.VariantType.runLength` is the number and its comment the argument; `lower.zig`'s `boxLength` and `variantZero` arms are where the compiled path reads it. |
| **A2** | **A union is released with its scope, like any value.**  D9's letter still spoke of ownership verbs; ARC has none, so there is nothing to write and nothing to refuse.  A union value's reference payloads are released when the last reference to them goes, and a union of value-only members frees nothing at all — a union dies the way a struct does, when its scope ends.  That reclamation is proven by the two-engine leak census rather than by a verb: three members of three shapes go out of scope in `specs/union_spec.zig` and the census is zero. |

Two smaller calls the memo did not need to make: `variant_tag`
answers a **`long`** — slot 0 boxes exactly as a `long` does, which
is what the interpreter parks in the same slot and what `match`'s
compare-and-branch tree tests — and a union declaration takes a
visibility marker while its members, like an enum's, do not.

Everything else landed as drawn.  The three instructions are
`variant_make` / `variant_tag` / `variant_field` with the verifier
rules of "Where it lands", and the printer prints them.
`format_version` moved **37 → 38** — the memo's "29 → 30" was
overtaken by the runs that landed between its writing and this one.  `libluce_rt`
learned **nothing**: no export, no semantic, no table — the commit
touched no `runtime/` file — and `luce_rt_struct_make` builds the run,
`ownValue` copies it, `dropStorage` frees it, exactly as D8 priced.
A rendered-IR test (`08_llvm/test.zig`) pins one runtime call per
construction and none per read, which is the inline-load promise made
executable.  `abi.version` did not move.

**Twenty-two two-engine spec rows** in `specs/union_spec.zig` cover the
memo's battery — construction and dispatch for every member shape,
defaults on payload fields, value and reference payload bindings,
a union whose reference payload is shared and released, a caught error
unwinding past two of them with the census at zero, a trap with union
values in flight, the zeros of a late `var`, an `array(Shape, n)` and a
`list(Json)` element, a recursive `Json` tree built, walked, copied and
released, `Shape?` narrowed and defaulted, `string(u)` for all six `Json`
members, and A4's fallthrough — beside refusal rows in
`03_parse/test.zig` and `compile/test.zig` for every numbered refusal:
D1's positional payload, D2's all-bare union, D3's member-as-type,
D4's bare payload member and parenthesized bare member, D5's partial
field list and unknown member, D11's shadowing arm binding, D12's
self-containing union, D15's union map key, and D16's `==`, refused by
a sentence naming `match`.  The worked `Json` example compiles and
runs through the real toolchain on both engines.

**The six rows added on 2026-08-12 are the temporary scrutinee**, and
they are here because the sentence above — *"a temporary one lives to
the end of the statement, and the `match` *is* the statement"* — was
promised and not delivered.  `match make():` released the call's
result before the arms ran and then read it back: the compiled path
answered from freed memory and the oracle segfaulted on the dangling
run, and nothing caught it because until that day no spec had ever
matched anything but a name.  The cause was where the promise lives —
the statement-temporary ledger — and the fix is that the scrutinee's
park stays open across the arms and flushes in the merge, once, from
one slot.  The rows now ask: a call's result, a temporary holding a
reference whose census proves one release, a nested call, sixty-four
rounds of a loop where a leak would accumulate, an arm that leaves
early by `return`, `break` and `continue`, and an enum-valued call
taking the same road.  The spec suite carries the siblings
— the iterable of a `for`, a narrowing test, `else`, a receiver, an
index, an argument, and a fallible call's result — all of which were
already right, and none of which had been asked either.

## The customer, two days later (2026-08-12)

**`std.json` is now written on top of this**, and the memo's `union
Json` is the type it declares — `null / boolean(value: bool) /
number → real(value: double) / text(value: string) /
array(items: list(Json)) / object(fields: map(string, Json))`, with
one member added and nothing taken away.  The evidence section's claim
that *"a design that serves it honestly serves everything smaller"*
survived contact: the whole rework is a `.luc` file and its specs, and
**not one line of the compiler, the runtime or this document's
decisions moved to accommodate it.**

What held, checked rather than assumed:

- **D13's zero.**  `Json.null` is first and is the zero, so
  `list(Json)` and `map(string, Json)` are constructible and the
  parser's `new list(Json)` needs no ceremony.  BYTES B2's constraint
  was the decisive one exactly as argued.
- **D12's finiteness.**  The recursion goes through the two containers
  and nothing else; `sumShape` accepted the declaration on the first
  try and the tree frees itself at its last reference.
- **D9/D10's memory, with no new rule.**  Construction just shares the
  map and the list into the outermost value — they *are* the builder;
  an arm's reference payload binding names the scrutinee's own object,
  so mutating a parsed tree in place is `match` plus an ordinary
  container write; a value a walk hands back is a copy, which is why
  `member` and `element` answer copies and say so.  The two-engine leak
  census over a tree built, walked, copied, mutated, shared and
  released is zero, which was the claim the specs existed to keep
  honest.
- **D7's "match is the only door"** turned out to be the *API*, not a
  restriction on it: `std.json` needs no navigation type at all,
  because matching an object hands the caller the `map` itself and
  reading through it shares that reference.  The old
  `Document`/`Node`/`Kind` triple — a flat tape of indices, written
  that way because a nested tree of reference containers could not
  answer `get -> Node?` — is gone whole.
- **D16's `string(u)`** is what became of `Kind`: the member's name,
  which is every use `kind()` had that `match` did not already serve.

Two things the memo could not have priced, both recorded where they
live:

- **A member was added: `integer(value: long)` beside
  `real(value: double)`.**  JSON has one number type and Luce has two,
  and a language with no implicit narrowing cannot hand a `long` out
  of a `double` without inventing or discarding information.  The
  split makes `std.json`'s ratified "`as_long` reads the notation"
  rule a *type-level* fact the compiler holds instead of a re-reading
  of the token's text — and it is the split Zig's `std.json`,
  serde_json, Jackson and System.Text.Json all make.  Nothing in this
  memo argues against it; the memo simply drew the type from the RFC's
  data model rather than from Luce's.
- **A union costs frames, and a recursive one costs them per level.**
  `match` is cheap, but the *walk* of a recursive union is a call per
  level at both ends — the module's reader and writer, and every
  caller that reads what they answer — against loom's 128-call policy.
  That is what moved `std.json`'s nesting bound from 128 to 64 and
  what merged its two container readers into one function, so a level
  costs one frame rather than two.  It is not a defect of the design:
  it is what a tree is, and the flat tape it replaced bought its
  iterative walk by giving up being a value.  But it is the one number
  a program feels, and it belongs beside D8's allocation cost as
  something the shape charges.

`std.json`'s own header, `docs/STD.md`'s section and
`/library/json/` carry the rest.

## D16's `==`, as it had to be corrected (2026-08-12)

D16 refused `==` on a union with a sentence naming `match`, and the
refusal asked the operand's own tag.  A struct's `==` is field-by-field
`==` (`runtime/operators.zig`), so **a struct holding a union asked the
refused question through a wrapper and got an answer**:

```text
struct Point:
    x: long
    y: long

union Shape:
    at(p: Point)
    count(n: long)

struct Cell:
    what: Shape

Cell(what = Shape.at(p = Point(x = 1, y = 2))) == Cell(what = Shape.count(n = 3))
```

A union value is a struct-shaped run whose slot 0 is the member index
and whose payload slots hold **a different shape on each arm**.  The
comparison above walked a `Point` run against a `long`: two runs of
unequal length, which is a panic in a checked build and a read off the
end of a slice in an unchecked one.  Where both arms happened to be the
same width there was no crash and something worse — a quiet "different"
computed partly from an *inactive* payload slot.

**A struct carrying a union is not comparable either.**  That is the
correction, and it is the only one consistent with D16 rather than a
patch on its symptom:

- A struct's `==` is *defined* as field-by-field `==`.  A field-wise
  `==` that reaches a union is asking exactly the operation D16
  refuses; letting a wrapper through is a hole in D16, not a feature
  of structs.
- Making it work is a decision D16 deliberately did not make.  "Tag
  first, then only the live payload fields" is implementable, but it
  answers questions this memo left open — whether an inactive payload
  participates, what a payload field that is itself a union or a
  function value does — and it would have to be argued for
  `Shape == Shape` first.  Allowing the wrapped comparison while
  refusing the direct one is the one position no reader can hold.
- The crash had to go regardless, and refusing costs a program
  nothing it cannot write: `match` on each side and `==` on what the
  arms carry is the sentence the diagnostic already says out loud.

The same rule reaches `xs.find(v)` and `xs.contains(v)`, which are
`==` under another spelling: a `list(Shape)` and a `list(Box)` are both
refused, naming the move that works — keep what identifies the member
beside it, a name or an enum, and search that.

**Where it is decided.**  One walk in `04_semantics/shapes.zig`
(`incomparablePart`) answers for `==`, `find` and `contains`, and it
answers for BINDING.md D6's function values in the same pass, because
that refusal had the identical defect at the identical sites.  Its
frontier is `==`'s own: it descends struct field runs, union runs and
optional payloads, and it **stops at an object handle**, because object
equality is identity and never reads the contents — so
`struct Row: cells: list(Shape)` still compares two rows by the handles
they hold, and refusing *that* would be a false refusal.  This is why
the walk is not `shapes.carries`, which the worker boundary uses and
which goes through a container on purpose.

`06_mir/verify.zig` refuses an equality whose operand type reaches a
union or a function value, so the runtime comparator's remaining
`unreachable` is unreachable rather than merely unreached, and its
struct arm now answers "different" for runs of unequal length instead
of walking off the end of one.  The refusals are proved by wording in
`specs/errors_spec.zig`; what a program writes instead is proved on
both engines at the end of `specs/union_spec.zig`.
