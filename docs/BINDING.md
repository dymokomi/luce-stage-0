# Bound methods — the method travels with its struct

> **Status (2026-08-11, second run): built, with D4 amended and D7/D8
> outstanding — see *As built* below.**
> D1, D2, D3, D4 (amended: the borrowing bind, the owning bind
> refused), D5, D6, D9, D11 and D12 are built; D7 and D8 are not.
>
> **D4's amendment is the owner's, made deliberately on 2026-08-11**:
> a bound value may copy a value-only receiver or **borrow** a carrying
> one, and may **never own** the receiver's objects, so `give
> counter.bump` and `copy counter.bump` are refused.  The decision
> table below is the original ratification; the argument that changed
> D4, and the two consequences that fell out of it, are in *As built*.
>
> **Ratified 2026-08-10.**  The owner ratified
> the design in conversation on 2026-08-10, including the two defaults
> held out for the decision: a carrying receiver **borrows** at a bare
> bind and takes `give`/`copy` to move in, and the spelling is plain
> `receiver.method` with no marker.  Implementation is scheduled after
> `luce test`, before the `termui` package — its demanded customer.

Luce's answer to closures has been one sentence since docs/FUNCTIONS.md:
*state that travels with behavior is a struct with a method.*  This memo
makes the sentence literal: a **bound method** — `receiver.method`
written where a `func(T, ...) -> R` value is expected — is a function
value whose environment is the receiver.  Nothing anonymous enters the
language: the environment is a struct the program declared, with a
name, a layout, visible fields, and the ownership class its fields
already give it.

The alternatives were each refused by ground already ratified, which is
what makes this the unique point in the design space:

- **Capture by reference** needs the lifetime analysis S29 refused;
- **anonymous capture by copy** needs the structural types
  docs/RETURNS.md refused when tuples asked;
- **GC/ARC environments** are refused permanently (docs/MEMORY.md);
- **`ctx` parameters on every callback** need the generics the owner
  has now refused twice.

Bound methods cost nothing the language has not already paid for: the
environment is a struct, the ownership is the S-rules, the call shape
is `call_inout`'s, and the safety net is the one dynamic
`use_after_free` check Luce chose over a borrow checker.

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
| **D1** | **`receiver.method` is a function value** where a matching `func` type lands, with the receiver's parameter dropped from the written signature: `Nearest.before(self, a: Point, b: Point) -> bool` binds as a `func(Point, Point) -> bool`.  Reading methods only in this run (D9). |
| **D2** | **No marker.**  The spelling is the member-access spelling; what makes it a bind is the landing place, exactly as a bare function name becomes a value by landing (FUNCTIONS D2).  Ratified as presented. |
| **D3** | **A value-only receiver is copied at the bind.**  The bound value is then a plain value: copies freely, takes no verbs, crosses a worker boundary when given, releases nothing.  This is the everyday case and it carries zero ceremony. |
| **D4** | **A carrying receiver borrows at a bare bind** — the bound value aliases the receiver's graph, reads through it freely (S8), and an alias that outlives its owner meets `use_after_free` at the call, dynamically, like every source alias.  `give counter.bump` **moves** the receiver into the value, which then owns its state, carries objects, takes `give`/`copy` at stores and is released by scope; `copy counter.bump` copies it in.  The verb table is S21/S24's, unchanged.  Ratified as presented — **and amended 2026-08-11: the owning bind is refused, the borrow is the whole of it.  See *As built, second run*.** |
| **D5** | **Ownership arrives with no new rule** (the union precedent): a bound value's class is its receiver-state's class.  Value-state bound values are values; owning bound values are carrying values with the verbs and death point a carrying struct has; borrowing bound values are aliases.  `spawn` admits a value-state or given owning bind and refuses a borrowing one, which is the existing boundary sentence.  **Amended with D4: there is no owning bind, so no function value crosses.** |
| **D6** | **Equality stays identity**: same function and same receiver identity (same object for owning/borrowing binds; value-state binds compare by function alone is *refused* — `==` on a value-state bound value is refused like ordering, because two copies of equal state are observably distinct workers of equal behavior and no answer is honest).  `string(f)` answers the method's qualified name.  **Amended with D4: no function value has equality, because no type can say which of them carries a receiver.** |
| **D7** | **The storable form of every function value is `func(...)?`** — this run folds in the deferred "yet"s: function-typed struct fields, container elements and map values land as optionals, absence is the zero (S40 answered by the mechanism `T?` already is), and calling through one requires narrowing or `else`.  A bare `func` type remains legal on parameters and `let`s, where a value is always present. |
| **D8** | **Fallibility joins the value type**: `func(T) -> R!` and `func() -> !` are distinct value types (they always were distinct function shapes), callable through a value with the same mandatory `try`/`catch` any fallible call carries. |
| **D9** | **Writing methods do not bind in this run.**  A writer requires one bare owning `var` receiver aliased in place (SELF); a bound writer is an inout closure whose store-back discipline deserves its own design.  Refused with a sentence naming the reader form, reopens as a superset. |
| **D10** | **Capture-free lambdas stay; anonymous captures stay refused, permanently.**  A lambda that needs state names a struct.  This is the line that keeps every environment in the language inspectable, sized, and owned in the open. |
| **D11** | **Union member constructors become function values** the same way — `Msg.query_changed` lands as `func(string) -> Msg` — closing the callback-construction gap `termui`'s message loop wants.  A bare payload-less member stays a value, not a function. |
| **D12** | **Representation**: a function value grows from a bare index to `{function index, receiver}`, receiver empty for unbound functions and lambdas.  The runtime copies and frees receiver state through the struct-layout walks it already owns; calls prepend the receiver through the path `call_inout` proved.  `libluce_rt` learns a shape, not a semantic. |

## Where it lands

Stage 4 resolves the bind at the landing place (the head-names-a-value
path FUNCTIONS built), types it by the method's signature minus
`self`, and applies D3/D4's verb rule with the diagnostics S21/S24
already speak.  MIR's `const_function` grows the receiver operand;
`call_indirect` passes it; the verifier ties the receiver's type to
the function's declared receiver.  Both engines grow arms, not
machinery.  `format_version` moves; `abi.version` does not.  The spec
battery runs both engines on: binds of all three ownership classes,
the alias observed through the scrutinee and refused at spawn, the
owning bind released by scope with the census at zero, a bound
comparator through `sort_by`, storable `func()?` fields round-tripping
through structs and lists, fallible values through `try` and `catch`,
and every refusal (writer bind, `==` on value-state binds, absence
unwrapped).

## Sequencing

After `luce test` (whose runner this does not touch), before `termui`
(whose design assumes D11 and D7).  The run is union-sized; the memo
that schedules it is PACKAGES.md's flagship plan.

## As built — 2026-08-11

**D12 first, and it is the whole of the change.**  A function value
grew from a bare index to `{function, receiver}` and both engines carry
the pair as a **two-slot field run**: slot 0 the function's index in the
program table, slot 1 the receiver or `none`.  That shape is a struct
value's shape, so `libluce_rt` learned exactly what D12 promised — a
run of two values and how long it is — and not one semantic: the copy
that `ownValue` makes, the release that `dropStorage` makes and the
object walk that `bind` makes were already written for struct field
runs and were already dynamic, because a `Value` describes itself.  The
run length and the two slot numbers are stated once, in `06_mir/defs.zig`
beside `boxTag`, for that function's own reason: both engines build one
and both read one.

The run is built the same way whether the value carries a receiver or
not.  That costs a plain function value one allocation it did not use to
make, and it buys the thing worth having: **no reader of a function
value branches on boundness to find its way around one**, so a place
that holds a `func(...)` cannot tell — and must not be able to tell —
which of the three it holds.

`const_function` therefore grew a receiver operand, stopped being pure
(it allocates, exactly as `struct_make` does), and its result now owns
storage.  `format_version` moved 40 → **41**.  `abi.version` did not
move and the argument is short: nothing crosses the host boundary that
did not before.  A receiver travels inside a Luce value, a bound call is
a call, and the host table gained no slot.

**The bind lands where FUNCTIONS D2 said it would.**  Stage 4 resolves
`receiver.method` in the same `.field` arm that already resolved
`Struct.helper`, one step later: when the head does not name a
declaration, the target is lowered as a value and its type is asked for
a method of that name.  A miss answers *not a bind* and the field path
below says what it always said about `p.x`, which is why binding cost
the field diagnostics nothing.  The type is the declaration's shape with
parameter zero dropped — `matchesSignature` gained the index of the
first parameter the written type covers, and that number is 0 for a
plain function value and 1 for a bind.

**The receiver is copied in at the bind (D3)** through the same
`ownedForStore` a struct field's value goes through: a fresh temporary
moves, a borrowed read is duplicated.  So writing the original receiver
afterwards does not reach the value, which is the sentence D3 is for,
and a receiver holding text is released once by the value that holds it.

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

- **D7's storable `func(...)?`.**  Not started, and it has a spelling
  question in front of it that the build could not settle on its own:
  `func(long) -> string?` already parses as *a function answering a
  `string?`*, because the result type is parsed by the ordinary
  `typeName()` and consumes its own `?` first.  So there is no way to
  write "an optional function that answers a string" today, and D7
  needs one.  The three candidates: parenthesized types
  (`(func(long) -> string)?`, which is Swift's answer and the one this
  memo recommends — a small grammar addition, unambiguous, and readers
  already know it); moving the `?` to bind to the function and giving
  up `-> R?` inside a function type (a real loss, since
  `func(string) -> long?` is `parse_int` as a value); or a marker on
  the keyword (`func?(long) -> string`, unambiguous and cheap but
  inconsistent with every other postfix `?`).  Everything below the
  spelling is ready: `Payload` needs a `.function` arm and four
  exhaustive switches follow it, `resolve.zig`'s `refuseFunctionPart`
  has five call sites and `refuseOptionalPart` needs a carve-out for
  an optional function element, and `zeroOf` already answers `none`
  for an optional in all three engines.
- **D8's fallible function types.**  Not started; a fallible method is
  refused at the bind (`luce.sema.fallible`) exactly as a fallible
  function already was at a plain function value.

## As built, second run — 2026-08-11

**D4 is amended: a bound value borrows its receiver and never owns
it.**  A value-only receiver is copied in, as D3 already shipped; a
carrying receiver is **borrowed**, which is D4's own ratified default;
and the two spellings that would make a function value the *owner* of
an object graph — `give receiver.method` and `copy receiver.method` —
are refused.  One sentence carries the whole feature:

> A function value owns the two-slot run that holds it, and never owns
> the objects inside it.

That is what `ownsStorage(.function) => true` and
`carriesObjects(.function) => false` already said, and the amendment
is what makes the pair **true by construction** rather than true by
accident: no bind can create a function value that is the sole owner
of a graph, so the type-level answer is not conservative, it is exact.

### Why the owning bind lost

The first run stopped because `carriesObjects` asks a *type*, at some
thirty-five sites, and a function type cannot say which of its values
carries a receiver.  Four answers were weighed and three rejected.

**The conservative type-level answer (every function value carries
objects, the way `docs/UNION.md` D9 priced unions) was measured
against the corpus and is worse than ceremony.**  It was built and run:
`return kept` where `kept` aliases a `func` parameter becomes
`luce.sema.own` under S17 — *a function value can no longer be passed
through a function*, which is most of what function values are for —
and `spawn work(f, n)` starts demanding `give f` with a `give`
parameter to match.  But the deeper cost is that it silently
reclassifies ordinary **value** structs: a
`StatusBar { text: string, on_click: func() -> Msg }` owns nothing,
and today `let b = a` **copies** it.  Under the conservative answer
`StatusBar` becomes a carrying struct and `let b = a` **aliases**
instead — the same code, the same types on the page, different
semantics, with the only outward signal a `give` appearing at some
unrelated store later.  Refusing owning binds keeps every
handler-holding struct on the value side of that line.

**Distinguishing carrying from non-carrying function types** destroys
the interchangeability the first run shipped and that is the feature's
whole value: one place fillable by a plain function, a lambda or a
bind, with no reader knowing which.  It also infects every signature
that takes a callback with a question its author cannot answer.

**Per-value tracking in the checker** — the shape `nodes.provenance`
already has, a fact riding the value rather than the type — is the
named reopening path, and it can be added later without invalidating
anything written here.  It was not taken now because it dies exactly
where D7 lives: a value's class is unknowable at a struct field, a
container element, a parameter and a return, and the conservative
answer at those places is the same tax measured above, paid at the one
place D7 exists to open.  D7 and an owning bind cannot both be
comfortable.

### The two refusals that keep the invariant true

Both ask the **receiver's** type or provenance, where the answer is
exact, and both are spoken in `boundMethod` — one decision, one place.

- **A receiver carrying a `file` or `task` does not bind.**  The alias
  story S8 tells about a list has no counterpart for a resource: a
  resource cannot be duplicated, and it cannot be re-owned into
  another runtime.  `luce.sema.own`, naming the two answers a reader
  has — keep the binding and call the method on it, or bind a method
  of a value-only receiver.
- **A *fresh* carrying receiver does not bind.**  Its objects are the
  statement's own temporary and die at the end of it (S3), so every
  call through the value would trap `use_after_free`.  Refused where
  it is written rather than met at the first call.

`give` and `copy` at a bind are refused by the rules that were already
there: `give` moves a bare owning name and a bind is not one, and
`copy` applies to carrying values, which a function value is not (S32).

### What the borrowing bind costs, and what it does not

Nothing in `docs/OWNERSHIP.md` changed, and this time that is a
consequence rather than a claim.  A bound value's run is fresh storage
(`own_storage` duplicates it, exactly as a struct field's value is
duplicated) and the object handles inside it are **aliased**, which is
S26 word for word: *struct copies alias the same objects*.  So
appending to the receiver's list is visible through the bound value,
writing the receiver's own scalar fields is not, and the value's death
is `drop_storage` alone — which frees the run and leaves every object
to its real owner.  An alias that outlives its owner meets
`use_after_free` at the call, deterministically and with the frame
that made it named, which is S9 and the cost Luce chose over a borrow
checker.

**A function value does not cross a worker boundary, and that is a
narrowing of what shipped.**  `spawn` refused a *borrow* for every
other carrying type by demanding `give`; a function value can never
own, so it can never satisfy that demand, and a function type cannot
say whether the value in front of it carries a receiver at all.  So
the boundary refuses the type, beside the `carriesResource` refusals
it already made, in both directions — as a spawned function's
parameter and as its result.  Measured before it was decided: a bound
value with a carrying receiver crossing today deep-copies the graph
into the worker's runtime and **leaks it**, because nothing there owns
the copy.  Two `functions_spec` facts and one `binding_spec` fact were
retired for this; the `give`-through-a-value fact they were really
about is proved without a worker instead.

### D6, as it fell out

**A function value has no equality.**  `docs/FUNCTIONS.md` D3 said two
function values compare as the same function or a different one, which
was the whole answer when a function value was an index.  It is now
the function *and* the receiver it may carry, and its type cannot say
which — so comparing by function alone calls two binds of one method
equal whatever they carry, which is exactly the dishonest answer D6
names, and there is no honest one to put in its place while the class
is not in the type.  `==` and `!=` on a function value are refused
with the sentence that says so, beside the ordering refusal that was
already there, and `string(f)` is how a program asks what a value
names.  D6's naming half is unchanged and shipped in the first run.

### D11, as built

**A union member constructor is a function value.**
`Msg.query_changed` where a `func(string) -> Msg` lands is the
constructor for that member: the payload fields are the parameters in
declaration order, the union is the result, and a field that carries
objects takes `give`, because that is the verb its construction takes
(S24) and a call through a value checks argument verbs exactly as a
direct call does.  **A payload-less member stays a value, not a
function** — `Msg.quit` is answered as the value it is and the landing
place says what it wanted, which is one decision said once rather than
a second refusal.

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
Nothing new is serialized: a synthesized constructor is an ordinary
function in the function table, a borrowing bind is the
`const_function` that already carried a receiver operand, and the two
new refusals are diagnostics.

### The diff's own three-state

`boundMethod` used to answer an optional, and a refused bind therefore
fell through to the field path and was re-read as the field it is not
— one mistake, two messages.  It now answers `expressions.MemberAccess`,
the three-state the enum and union member paths already used for
exactly this reason, which is now shared rather than duplicated.  The
writer and fallible refusals inherited the fix.

