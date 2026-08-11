# Bound methods — the method travels with its struct

> **Status (2026-08-10): ratified, not built.**  The owner ratified
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
