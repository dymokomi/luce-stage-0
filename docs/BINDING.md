# Bound methods — the method travels with its receiver

> **Status (2026-08-11, third run): built, with D8 outstanding — see
> *As built* below.**
> D1, D2, D3, D5, D6, D7, D9, D11 and D12 are built; D8 is not.
>
> **D7 landed with one refinement**, argued in *As built, third run*:
> a map value is written bare because `get` already answers `V?`.
>
> **D4 is subsumed by the memory model (docs/MEMORY.md).**  A bound
> method holds a **reference** to its receiver; ARC keeps that receiver
> alive for as long as the value lives.  There are no ownership verbs
> at a bind — a value-type receiver is copied into the value, a
> reference-type receiver is shared with it, and both are the ordinary
> semantics of the receiver's own kind.
>
> **Ratified 2026-08-10.**  The owner ratified the design in
> conversation on 2026-08-10, including that the spelling is plain
> `receiver.method` with no marker.  Implementation is scheduled after
> `luce test`, before the `termui` package — its demanded customer.

Luce's answer to closures has been one sentence since docs/FUNCTIONS.md:
*state that travels with behavior is a struct with a method.*  This memo
makes the sentence literal: a **bound method** — `receiver.method`
written where a `func(T, ...) -> R` value is expected — is a function
value whose environment is the receiver.  Nothing anonymous enters the
language: the environment is a struct or `class` the program declared,
with a name, a layout, and visible fields.

Bound methods cost nothing the language has not already paid for: the
environment is a declared type, the receiver is a value copied or a
reference shared exactly as it is anywhere else, and the call shape is
`call_inout`'s.

## The evidence

`std.lists.sort_by` takes `func(T, T) -> bool` and cannot be handed
context: sorting by distance-to-cursor today means precomputing keys
into elements.  The `termui` package (PACKAGES.md's flagship) wants
event handlers and view helpers that carry app state.  `cli` wants
subcommand handlers that carry parsed options.  In every case the
struct-with-a-method exists and the API cannot receive it — the
prescribed form does not compose with the `func`-taking surface, and
that non-composition is the whole gap.

## Decisions

| | decision |
|---|---|
| **D1** | **`receiver.method` is a function value** where a matching `func` type lands, with the receiver's parameter dropped from the written signature: `Nearest.before(a: Point, b: Point) -> bool` binds as a `func(Point, Point) -> bool`.  Reading methods only in this run (D9). |
| **D2** | **No marker.**  The spelling is the member-access spelling; what makes it a bind is the landing place, exactly as a bare function name becomes a value by landing (FUNCTIONS D2).  Ratified as presented. |
| **D3** | **The receiver travels by its own kind.**  A **value** receiver (a `struct`, an `enum`, a scalar) is copied into the bound value, so the value carries its own state.  A **reference** receiver (a `class` or container) is shared with the bound value, and ARC keeps it alive for as long as the value lives.  The bound value copies freely and takes no verbs. |
| **D4** | **No new ownership rule** — there is none in the language (docs/MEMORY.md).  A bound value's memory behavior is its receiver's: a value receiver is inline and copies; a reference receiver is shared and reference-counted.  A bound method that holds a reference is as ordinary as any other value holding one. |
| **D5** | **`spawn` refuses a function value** (as a spawned function's parameter and as its result), because a function value may hold a reference and reference types do not cross a worker boundary (docs/MEMORY.md D6, THREADS.md).  A call *through* a value type-checks its arguments exactly as a direct call does. |
| **D6** | **A function value has no equality or ordering.**  A function value is the function it names *and* the receiver it may carry, and its type cannot say which — so comparing by function alone would call two binds of one method equal whatever they carry, which is not an honest answer.  `==` and `!=` are refused, and the refusal is *transitive*, reaching every comparison that descends into a function value — `==` on a struct that holds one, and `find`/`contains` over a container of those, included.  `string(f)` is how a program asks what a value names. |
| **D7** | **A function value is storable** — this run folds in the deferred "yet"s: a struct field, a list element, an array cell and a union payload field hold one as `(func(...) -> R)?`, absence is the zero, and calling through one requires narrowing or `else`.  A bare `func` type remains legal on parameters, `let`s and a map value, where the value is present (or `get` already answers `V?`). |
| **D8** | **Fallibility joins the value type**: `func(T) -> R!` and `func() -> !` are distinct value types, callable through a value with the same mandatory `try`/`catch` any fallible call carries.  **Not built** — the remaining item; see the end. |
| **D9** | **Writing methods do not bind in this run.**  A writer requires one bare mutable receiver aliased in place (SELF); a bound writer is an inout closure whose store-back discipline deserves its own design.  Refused with a sentence naming the reader form, reopens as a superset. |
| **D10** | **Capture-free lambdas stay; anonymous captures stay refused.**  A lambda that needs state names a struct.  This is the line that keeps every environment in the language inspectable, sized, and named in the open. |
| **D11** | **Union member constructors become function values** the same way — `Msg.query_changed` lands as `func(string) -> Msg` — closing the callback-construction gap `termui`'s message loop wants.  A bare payload-less member stays a value, not a function. |
| **D12** | **Representation**: a function value grows from a bare index to `{function index, receiver}`, receiver empty for unbound functions and lambdas.  Calls prepend the receiver through the path `call_inout` proved.  `libluce_rt` learns a shape, not a semantic. |

## Where it lands

Stage 4 resolves the bind at the landing place (the head-names-a-value
path FUNCTIONS built), and types it by the method's signature minus the
receiver.  MIR's `const_function` grows the receiver operand;
`call_indirect` passes it; the verifier ties the receiver's type to
the function's declared receiver.  Both engines grow arms, not
machinery.  `format_version` moves; `abi.version` does not.  The spec
battery runs both engines on: binds of a value receiver and a reference
receiver, a bound comparator through `sort_by`, storable `func()?`
fields round-tripping through structs and lists, and every refusal
(writer bind, `==` on a function value, absence unwrapped).

## Sequencing

After `luce test` (whose runner this does not touch), before `termui`
(whose design assumes D11 and D7).  The run is union-sized; the memo
that schedules it is PACKAGES.md's flagship plan.

## As built — 2026-08-11

**D12 first, and it is the whole of the change.**  A function value
grew from a bare index to `{function, receiver}` and both engines carry
the pair as a **two-slot run**: slot 0 the function's index in the
program table, slot 1 the receiver or `none`.  The run length and the
two slot numbers are stated once, in `06_mir/defs.zig` beside `boxTag`,
for that function's own reason: both engines build one and both read
one.

The run is built the same way whether the value carries a receiver or
not.  That costs a plain function value one allocation it did not use to
make, and it buys the thing worth having: **no reader of a function
value branches on boundness to find its way around one**, so a place
that holds a `func(...)` cannot tell — and must not be able to tell —
which of the three it holds (a plain function, a lambda, or a bind).

`const_function` therefore grew a receiver operand and its result now
allocates, exactly as `struct_make` does.  `format_version` moved 40 →
**41**.  `abi.version` did not move: nothing crosses the host boundary
that did not before.  A receiver travels inside a Luce value, a bound
call is a call, and the host table gained no slot.

**The bind lands where FUNCTIONS D2 said it would.**  Stage 4 resolves
`receiver.method` in the same `.field` arm that already resolved
`Struct.helper`, one step later: when the head does not name a
declaration, the target is lowered as a value and its type is asked for
a method of that name.  A miss answers *not a bind* and the field path
below says what it always said about `p.x`, which is why binding cost
the field diagnostics nothing.  The type is the declaration's shape with
the receiver dropped — `matchesSignature` gained the index of the first
parameter the written type covers, and that number is 0 for a plain
function value and 1 for a bind.

**The receiver travels by its own kind (D3)** through the same store
path a struct field's value goes through: a value receiver is copied in,
a reference receiver is shared.  So writing a *value* receiver
afterwards does not reach the value, while a *reference* receiver stays
the one object both names — which is the ordinary meaning of each kind.

**The backend dispatches through adapters, and that is new.**  A call
site cannot know whether the value in its hand carries a receiver — one
`func(Point, Point) -> bool` place accepts a plain function, a lambda
and a bind — but a C signature is chosen at compile time.  So the
function table stopped holding functions and started holding one
adapter per function some `const_function` names: `luce.bound.N` takes a
receiver slot after the depth, unboxes it into the callee's parameter
zero when the value is a bind, and ignores it when it is not.  Every
indirect call passes the receiver slot of the run it is calling through.
The price is one extra call frame per call *through a function value*;
the alternative was two calling conventions at a site that cannot tell
them apart.  The interpreter needs none of this: it has the program in
front of it and prepends the receiver to the argument run.

### What did not ship, and why

- **D8's fallible function types.**  Not started; a fallible method is
  refused at the bind (`luce.sema.fallible`) exactly as a fallible
  function already was at a plain function value.  The remaining work is
  listed at the end.

## As built, second run — 2026-08-11

**A function value has no equality (D6).**  `docs/FUNCTIONS.md` D3 said
two function values compare as the same function or a different one,
which was the whole answer when a function value was an index.  It is
now the function *and* the receiver it may carry, and its type cannot
say which — so comparing by function alone calls two binds of one method
equal whatever they carry, which is exactly the dishonest answer D6
names, and there is no honest one to put in its place while the receiver
is not in the type.  `==` and `!=` on a function value are refused with
the sentence that says so, beside the ordering refusal that was already
there, and `string(f)` is how a program asks what a value names.

**The rule reaches every place the comparison is asked for**
(2026-08-12).  `xs.find(f)` and `xs.contains(f)` on a list or an array
of function values are equality under another spelling, and they were
accepted while `f == g` was refused — the search reached the runtime's
comparator, which has no sentence to say.  Both are now refused where
the comparison is written, naming D6 and the workaround: keep what you
meant to look for beside the values — a name, an enum — and search that.
Nothing else on a container changed, because nothing else compares
elements: `append`, `insert`, `fill`, `sort_by` and a store all *place*
a value, and a function value places like any other (D7).

**And it reaches every value the comparison *descends into*
(2026-08-12, corrected).**  A struct's `==` is field-by-field `==`, so
the D7 shape this memo exists to bless walked straight past a refusal
written as "the operand's own type is a function":

```text
struct Button:
    label: string
    on_click: (func(long) -> long)?

Button("ok", twice) == Button("ok", twice)   # once compiled, then refused
```

`xs.find(b)` and `xs.contains(b)` on a `list(Button)` did the same, one
wrapper further out.

**The refusal is therefore transitive, and the walk that decides it is
shared with `==` itself** (`04_semantics/shapes.zig`'s
`incomparablePart`, spoken by `refusals.failIncomparable` and
`refusals.failUnsearchable`).  Two things about its frontier are
deliberate:

- It descends a struct's field run, a union's run and an optional's
  payload — everything `runtime/operators.zig` descends.
- It **stops at a reference**, because `==` does: reference equality is
  identity and never reads the contents.  So
  `struct Panel: buttons: list(Button)` still compares two panels by the
  references they hold, which is an honest `==` and must not be refused.

`06_mir/verify.zig` refuses the same shape in a decoded module, which is
what makes the runtime comparator's `.function` arm unreachable rather
than merely unreached.  The sentence a reader gets names the struct, the
part of it that answered, and `string(f)`.

### D11, as built

**A union member constructor is a function value.**
`Msg.query_changed` where a `func(string) -> Msg` lands is the
constructor for that member: the payload fields are the parameters in
declaration order, and the union is the result.  **A payload-less member
stays a value, not a function** — `Msg.quit` is answered as the value it
is and the landing place says what it wanted, which is one decision said
once rather than a second refusal.

Nothing downstream of stage 4 learned that a constructor exists.  The
analyzer synthesizes the top-level function the reader would otherwise
have written — `func Msg.query_changed(query: string) -> Msg: return
Msg.query_changed(query = query)` — registers it the way a lambda's
declaration is registered, and emits the `const_function` a named
function emits.  The body reuses the *written* head, so an imported
union resolves from the reference site's own module exactly as it did
where the reader wrote it.  That is the lambda's own route
(FUNCTIONS D2), one node kind over, and it is why D11 added no MIR
instruction, no verifier arm, no runtime callback and no host slot.

`format_version` did **not** move, and neither did `abi.version`.

## As built, third run — 2026-08-11

**D7 is built, and the spelling is parenthesized types.**  A function
value is storable: a struct field, a list element, an array cell and a
union payload field hold one as `(func(...) -> R)?`, absence is the
zero, and reaching the value takes the narrowing or the `else` any other
optional takes.  D8 is **not** built and is the whole of what remains;
the precise list is at the end.

### The grammar rule: a parenthesized type is that type

`func(long) -> string?` already parses, and means *a function answering
an optional string* — the result type is parsed by the ordinary type
production and consumes its own `?` first.  It must keep meaning that,
because that is how `parse_int` is written as a value.  So the only way
to say "a function that may be absent" is to close the function type
before the `?` reaches it.

The rule shipped is the **uniform** one: `(T)` is `T`, accepted wherever
a type may stand.  Parentheses are grouping and are never required —
`long?` is unchanged and idiomatic, `(long)?` parses to the same type
and says nothing extra, and `(func(long) -> string)?` is the one thing
that becomes newly writable.  Nothing that compiled before compiles
differently.  **In return position the arity is what separates the two
productions** — one type in parentheses is a parenthesized type, two or
more is a return shape.

`writeTypeName` parenthesizes a function payload and nothing else, so a
diagnostic's spelling is one the parser reads back as the same type.

### Where a function value may stand, and why the map is different

| slot | written | why |
|---|---|---|
| struct field | `(func(...) -> R)?` | `var row: Row` creates it zeroed |
| array cell | `(func(...) -> R)?` | `new array(T, n)` creates it filled |
| list element | `(func(...) -> R)?` | uniform with the two above |
| union payload field | `(func(...) -> R)?` | a union's zero is its first member, fields at their own zeros |
| **map value** | `func(...) -> R` | see below |
| parameter, `let`, return | `func(...) -> R` | a value is always present |

The rule is one sentence: **a slot that exists before anything fills it
needs a zero, a function value has no zero, and absence is the zero
`T?` already means.**  A bare `func` type in one of those four is
refused by name, and the sentence spells the optional.

**A map value is the one slot no container ever creates.**  It exists
because `put` created it, and `m.get(k)` already answers `V?` — so the
absence D7 asks for is the missing key, the type is written bare, and
`map(K, (func(...) -> R)?)` is refused because it would make `get`
answer a `V??`, which has no representation.  The reader still writes
exactly one `?` and gets it from `get`.

**`m.values()` is refused on that one map, and the rule is its own
reason** (2026-08-12).  A bare `func` type is legal as a map value and
illegal as a list element, so `values()` — which answers `list(V)` —
would manufacture a type no program can write.  The refusal is at
`values()` and it names the loop that works: walk `m.keys()` and read
`m.get(k)`.  `m.keys()` is untouched — a key is a `long`, a `string` or
an enum, and every one of those is an element type.

### The receiver is a reference the value holds

A bound method's receiver rides in the value.  When it is a **value**
type it is copied in, so the value carries its own independent state.
When it is a **reference** type — a `class` or a container — the value
holds the reference, ARC retains it for the value's lifetime, and the
receiver stays alive as long as any bound value naming it does.  That is
the ordinary meaning of each kind (docs/MEMORY.md); a stored bound
method is safe for the same reason any stored reference is.

`luce_rt_function_make` is the run's own constructor beside
`luce_rt_struct_make`; both engines build one.  A function value copies
the two-slot run and shares whatever reference sits in slot 1, which is
a copy of a reference — the same thing `let b = a` does for any
reference-holding value.

### The seams that had to learn the optional

- **Landing.**  `wantPlace` looks through one optional layer for the
  signature a bare function name, a lambda and a bind land on, exactly
  as `literalLandingType` does for a number; `fit` then wraps.  So
  `Row(action = three.times)` and `steps.append(twice)` land and wrap
  with no new rule.
- **Landing at depth** (corrected 2026-08-12).  A **nested** store did
  not name a landing place: `assign.lowerAssignChain` lowered its
  operands under `Landing.nothing`, so `pane.render = plain` landed and
  `self.pane.render = plain` was refused for want of a function type.
  It was never a fact about function values: a bare `none` and a number
  reaching a `byte` were refused at the same depths, for the same
  missing landing.  The fix is `Landing.chain`, the nested sibling of
  `stored_element`: the written path *is* the landing, because a field
  names its type and a container names its element, so the leaf is known
  before an operand is lowered however deep it sits.
- **Calling.**  A narrowed `(func(...))?` local is callable, and the
  resolved callee records that it was narrowed, so lower reads the slot
  and unwraps it — the same `optional_unwrap` a narrowed name already
  lowers to.

### Versions

`format_version` did **not** move and `abi.version` did not either.  A
type travels as its outer `Type` tag and an optional writes its payload
as a whole `Type`, so no tag renumbered and the fingerprint did not
move.  What changed on the wire is only which modules *decode*:
`optional(function)` used to be rejected as damaged and now loads.  A
stale toolchain therefore refuses a new module rather than misreading
one, which is what a version exists to guarantee.

### What remains: D8

Fallible function types are not built.  `func(T) -> R!` and `func() ->
!` are still refused where they are written, in two places with one
sentence, and a fallible method is refused at the bind.  The work, in
the order it has to happen:

1. `03_parse/grammar.zig`'s `functionTypeName` — stop refusing the `!`
   in both positions; record it (`ast.TypeName` already carries a
   `fallible` bit, today reserved for `task(T!)`).
2. `support/types.zig` — `Signature.fallible`, and `eql` must compare it
   or two differently-fallible types intern to one row.  Render it in
   `writeTypeName`, beside the `task` arm that already does.
3. `04_semantics/resolve.zig`'s `resolveSignature` — carry it into the
   interned row.
4. `04_semantics/builder.zig` — delete the two refusals (the function
   value's and the bind's), add the comparison to `matchesSignature`
   and the stamp to `writtenSignature`.
5. `04_semantics/calls.zig`'s `lowerValueCall` — consult
   `signature.fallible`, emit `luce.sema.fallible` when the site is not
   a `try`/`catch`, pass `true` to `recordCallNode`, and call
   `openFallible`.  Stages 5 and 6 and the interpreter need **no**
   change: `replayIndirectCall` already ends in `finishFallible`.
6. `06_mir/verify.zig` — `expectSignature` compares `callee.fallible`
   against the signature's instead of refusing a fallible callee, and
   `raisesError` grows its `.call_indirect` arm.
7. `08_llvm/lower.zig`'s `emitIndirectCall` — `propagateTrapOnly` and
   record the outcome when the signature is fallible.  The `luce.bound.N`
   adapters already forward the outcome word untouched.
8. `06_mir/module.zig` — one `u8` per signature row, and `format_version`
   **must** bump.  `abi.version` still does not move.

## As built, fourth run — the call suffix, 2026-08-12

**D7 was storable but not callable in place.**  A function value could
live in a field, an element, an array cell, a union payload field and a
map value, and every call through one had to launder its callee through
a local, because the grammar accepted a call only on a bare name or on
`receiver.method`.  `chooser()(5)` and `m["a"](1)` were parse errors.  A
call is now one more **postfix suffix**, beside the index and the field
access, and `EXPR(args)` parses wherever `EXPR[i]` does
(docs/FUNCTIONS.md, *As built — the call suffix*).

Three consequences for this memo:

- **A bare map value is now callable where it is read.**  The one slot
  D7 writes bare is the one the suffix serves without ceremony:
  `actions["double"](21)` and, for a stored bind, `scales["two"](10)` —
  the receiver rides in the value, so calling it in place calls it on
  the state it carries.
- **The four optional slots are not**, and that is D7's own rule rather
  than a gap: narrowing is locals-and-parameters-only, so
  `rows.render(3)` is refused.  What changed is the sentence, which used
  to be "Rows has no method render" — a lie by omission, since the
  struct has exactly that field — and now names the field, says it may
  hold none, and writes out the three lines that work.
- **D8's step 5 renames.**  `lowerIndirectCall` is `lowerValueCall`, and
  it is reached by both the named form and the suffix, so making a
  function type fallible remains one edit there.

`Indirect` carries the callee **node** now rather than a `LocalId` and a
`narrowed` flag: the storable form reads through the ordinary
`narrowed_get` a narrowed name always produced, which is one fewer thing
for the tree to record.  `format_version` did not move, and neither did
`abi.version`.
