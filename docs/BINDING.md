# Bound methods — the method travels with its struct

> **Status (2026-08-11): built in part — see *As built* below.**
> D1, D2, D3, D5's value-state half, D6's naming half, D9's refusal and
> D12 shipped; D4's carrying receiver, D6's refusal, D7, D8 and D11 did
> not, each for a reason recorded there.
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
| **D4** | **A carrying receiver borrows at a bare bind** — the bound value aliases the receiver's graph, reads through it freely (S8), and an alias that outlives its owner meets `use_after_free` at the call, dynamically, like every source alias.  `give counter.bump` **moves** the receiver into the value, which then owns its state, carries objects, takes `give`/`copy` at stores and is released by scope; `copy counter.bump` copies it in.  The verb table is S21/S24's, unchanged.  Ratified as presented. |
| **D5** | **Ownership arrives with no new rule** (the union precedent): a bound value's class is its receiver-state's class.  Value-state bound values are values; owning bound values are carrying values with the verbs and death point a carrying struct has; borrowing bound values are aliases.  `spawn` admits a value-state or given owning bind and refuses a borrowing one, which is the existing boundary sentence. |
| **D6** | **Equality stays identity**: same function and same receiver identity (same object for owning/borrowing binds; value-state binds compare by function alone is *refused* — `==` on a value-state bound value is refused like ordering, because two copies of equal state are observably distinct workers of equal behavior and no answer is honest).  `string(f)` answers the method's qualified name. |
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

- **D4's carrying receiver.**  Refused by name (`luce.sema.own`,
  naming D4).  The blocker is not the verbs — those are S21's and were
  ready — but that **`carriesObjects` asks a *type***, in some
  thirty-five places, and a function type cannot say which of its
  values carries.  `func(Point, Point) -> bool` is one type worn by a
  plain function, a lambda, a value-state bind and an owning bind, and
  D5's "a bound value's class is its receiver-state's class" therefore
  makes the class a property of the *value*.  Making it one is a real
  change to how stage 4 asks the ownership question, and it is the same
  change D6's refusal needs (below).  Doing it badly under time
  pressure would have put a wrong answer in the one place the language
  cannot afford one, so it was not done at all.
- **D6's refusal of `==` on a value-state bind.**  Equality compares
  the function named, as it always did; two binds of one method
  therefore compare equal whatever they carry, which is exactly the
  dishonest answer D6 names.  The refusal is static and needs to know,
  at the comparison, whether an operand may carry a receiver — the same
  per-value class D4 needs.  The two reopen together.  `string(f)`
  shipped: it answers the method's qualified name.
- **D7's storable `func(...)?`.**  Not started.  A function value is
  still not a struct field, a container element or an optional payload.
- **D8's fallible function types.**  Not started; a fallible method is
  refused at the bind (`luce.sema.fallible`) exactly as a fallible
  function already was at a plain function value.
- **D11's union member constructors.**  Not started.
- **D9 shipped as a refusal**, as designed: a writing method names the
  reader form and does not bind.
