# Self, implied — and a call site that cannot lie

**Ratified by the owner, 2026-08-07**, revising `docs/METHODS.md`'s
receiver design before the language locks: *"I think it makes
language less clear.  I also don't think we should do var self
either.  Self should be implied.  And then I suggest that we
introduce static keyword to struct member functions which would not
have access to self.  Being very clear that passing a value into a
function will not mutate the value is really important."*

The standing offer — a counter-example too awkward to solve with a
return value or a member function — was checked and **none survived**:
state threading is `pos, bits = read_bits(data, pos, 5)` once the
polish run lands multi-return into existing bindings; "reset this
struct" is a member function or a fresh construction; `swap` is three
lines once a decade; buffers are objects, whose borrowed contents
already mutate through their own methods on the other side of the
value/object line, unchanged.

## The rule the call site keeps

**`f(x)` never mutates a value.  `x.advance(8)` may — and reads like
it.**  Mutation's whole grammar becomes *a method on a receiver you
hold as `var`*, which is how containers already read (`xs.sort()`),
so structs and containers stop having different mutation stories.

## Decisions

| | decision |
|---|---|
| **D1** | **`self` is implied.**  A struct's member function declares no `self` parameter; its body may name `self` (and `self.field`) directly.  The signature lists only the arguments a caller passes. |
| **D2** | **`static` marks the member functions with no `self`** — the factories and namespace functions.  `static func start() -> Cursor` is called `Cursor.start()`, exactly the namespace-call shape already built; what changes is only how the two kinds are told apart (a keyword instead of a first parameter). |
| **D3** | **Writing `self` requires the receiver to be a `var` place**, checked at the call site — `frozen.advance(8)` on a `let` binding is refused by the sentence `let` refusals already use.  Reading `self` needs nothing.  There is no per-method mutation marker: the receiver's own mutability is the whole permission, as it is for `xs.append`. |
| **D4** | **`var self` is retired**, and with it the copy-in/copy-out write-back and the "receiver is result zero" convention.  A member function that writes `self` simply writes the receiver in place — one mutation story, no hidden travel in returns. |
| **D5** | **`var` parameters do not enter the language.**  A value passed to a function is never mutated by it, with no exception to learn.  (The near-miss was value-only copy-in/copy-out; refused for the clarity cost the ratification names.) |
| **D6** | The value/object line is untouched: an object argument still borrows, and borrowed contents still mutate through the object's own methods — that is what a reference is.  What this memo removes is any way for a *value* to change under a caller's feet. |
| **D7** | **Migration is mechanical and total**: every method in `std/`, `examples/` and every doc/site sample drops its `self` parameter; namespace functions gain `static`; `var self` methods (the rng, zip's writer) become plain writing methods.  The suite, the site build and the doc guards verify every one.  The old spellings are refused with sentences that teach the new (`self is implied; remove the parameter`, `a namespace function says static`). |

## Where it lands

Parser: `static` before `func` inside structs (dissolved like
visibility markers, or carried — the build decides and records);
`self` leaves the parameter grammar.  Stage 4: method-vs-namespace
resolution keys on `static`; receiver mutability checked where
`self` is written.  MIR unchanged in shape (a method still lowers
with the receiver as the hidden first operand — the *language* stops
spelling it, the IR never did differently).  Both engines by
construction.  Sequenced **after** threads → lambdas → polish, on a
quiet tree, as the final surface change before the lock.

## As built — 2026-08-08

The surface landed exactly as D1–D7: every plain struct or enum member
has implied `self`, and `static func` is the member with none.  One
detail was deliberately narrowed at implementation time: a writing
method accepts a **bare mutable binding**, not every nested place.
Reading methods still accept lets and temporaries.  An object-carrying
receiver may be replaced only through the binding that owns its
objects; mutating an object's contents through a borrowed field remains
a reading method under D6.

The write effect is inferred to a fixed point.  A direct store to
`self`, a store to one of its value fields, or a call to another writer
on `self` makes a method a writer, even through forward declarations
and several wrappers.  An object-content call such as
`self.items.append(value)` does not.  Writers may declare zero, one, or
several ordinary results; the receiver is not one of them.

The call surface stays honest in both directions.  A method is called
only as `value.method(...)`: it cannot be called through its type, made
into a function value, or spawned.  A static member is called through
its type and may be both a value and a worker target.

The prediction that MIR would not change was the one part that did not
survive implementation.  A writing call needs the caller's slot and
owner identity, not merely its current value, so MIR gained
`call_inout` and an `inout` local zero.  The interpreter aliases that
slot; LLVM passes an internal pointer/owner descriptor and forwards it
through nested writers.  Cleanup remains the caller's, and replacing an
object-carrying receiver does not invent a second owner.  This moved the
serialized module to **format 32** and added no host service at that
point.  (The host ABI has since moved on its own schedule — later
slots such as `shell_run` and `term_event_data` carried it past this
memo; `08_llvm/abi.zig`'s `version` is the one authoritative number.)

That representation also fixes the failure rule: mutation is in place,
so every write completed before an error remains visible while the
error unwinds.  There is no returning-edge copy-out to roll it back.
