# SELF implementation audit — live findings

Started at `7a221e2` while implementing the ratified
[`SELF.md`](../SELF.md).  This is a working audit ledger, not a language
specification: it records surprising existing behavior, implementation
hazards, and possible improvements as they are found.  At the end of the
SELF run every row will be marked fixed, deliberately retained, or moved
to the permanent gap list.

| # | Finding | Disposition |
|---|---|---|
| S1 | D4's true in-place receiver mutation cannot use the old value-only MIR call while also retiring its hidden receiver result. | **Fixed in SELF:** a distinct `call_inout` aliases the caller's local and carries its ownership identity.  This changes the module format, not the host ABI. |
| S2 | The old `var self` copy-out made a fallible writer transactional by accident: writes disappeared when the method raised.  A real in-place receiver necessarily exposes writes performed before the error. | **Deliberately changed and pinned:** pre-error writes remain visible in both engines, the ownership tests, and current docs. |
| S3 | A specification test titled “receiver may be a field or element” only called a method on a bare local; it proved neither a field nor an element receiver.  The old checker in fact accepted only bare names for writing methods. | **Retained narrowly for this run:** writers require a bare mutable binding; readers still accept expressions and temporaries.  Honest positive/refusal coverage now pins both sides; nested mutable places moved to `docs/MISSING.md`. |
| S4 | The old implementation refused every object-carrying `var self`.  Removing that refusal without carrying the caller's ownership identity would bind replacements under the wrong frame and risk leaks or double ownership. | **Fixed in SELF:** the inout channel carries the original owner identity; `give self`, `free(self)`, and moving object-carrying `self` out remain refused. |
| S5 | In-place replacement creates a new argument-lifetime hazard: `s.change(s)` and `s.change(s.text)` can otherwise leave the ordinary argument borrowing storage the receiver frees.  Likewise, in `f(s, s.change())`, the first operand's local read is no longer intrinsically safe. | **Fixed in stage 4:** storage-owning arguments to writers are copied and parked through the call; owning-local reads participate in the existing later-operand mutation hazard rule. |
| S6 | Receiver write behavior cannot be inferred by a local syntax scan.  Forward calls and wrappers such as `self.real()` can mutate only because another method they call writes `self`; object-content calls such as `self.items.append(...)` must not count as value-self writes. | **Fixed in SELF:** declaration analysis computes a fixed point over same-owner method calls and distinguishes value replacement from borrowed object-content mutation. |
| S7 | Two production methods, `Play.take` and `Play.put_down`, were marked `var self` even though they only read receiver fields and mutate a separately borrowed object. | **Improved by inference:** both become ordinary read methods after migration. |
| S8 | `examples/editor/editor.luc` described a thirty-word keyword table and omitted the already-reserved `spawn`; adding `static` would otherwise make that drift two words wide. | **Fixed during corpus migration:** include both `spawn` and `static`, and pin the real count of 32.  Deriving this sample table from the compiler is recorded in `docs/MISSING.md`. |
| S9 | A writing method's receiver expression can be spilled while later arguments introduce control flow.  Aliasing that spill would mutate a temporary instead of the caller's binding. | **Fixed by construction:** `call_inout` stores a `LocalId`, and stage 4 re-resolves and rechecks the bare receiver after every argument is lowered. |
| S10 | Dead-store elimination used to be free to remove a final `local_set self` because old receiver writeback observed a returned value.  With a true alias, that store is externally visible even if the callee never reads it again. | **Fixed in stage 7:** writes to inout local zero are effects and survive DCE, with a verifier-valid inout regression. |
| S11 | Enum member visibility markers were parsed but discarded even though `FuncDecl` already carries visibility.  Adding `private static func` made the drift observable. | **Fixed in the parser:** enum functions now retain direct visibility just as struct functions do, with a cross-module private-static regression. |
| S12 | An inout receiver's storage flag is representation-critical: LLVM aliases either a full owning `Value` slot or a scalar slot through an opaque pointer.  A malformed module that disagrees with the callee about this flag could load the wrong representation. | **Fixed in the MIR verifier:** caller receiver and callee local zero must agree on `owns_storage`. |
| S13 | `call_inout` is both a receiver read and write, not merely an ordinary call.  Treating it otherwise lets store forwarding or loop hoisting cross an externally visible receiver mutation. | **Fixed in stage 7/8 analyses:** it invalidates forwarding, marks the receiver assigned, and participates in register read/write accounting. |
| S14 | The new call shape was initially absent from stage 4's closed list of fresh-storage producers.  A writing method returning a heap-backed string or struct would therefore leak its original answer, especially when the result was ignored. | **Fixed before integration:** `call_inout` has the same fresh-result ownership rule as direct and indirect calls; bound and discarded-result leak regressions prove both exits. |
| S15 | Two parser comments carried stale counts/claims: the keyword table was described as 22 words, and a migration assertion said no `.luc` source contains `self` even though method bodies necessarily do. | **Fixed in parser closeout:** pin 32 reserved words and distinguish retired receiver parameters from valid implicit-self body uses. |
| S16 | Optional narrowing produces a readable payload value, not a mutable payload place.  Without an explicit check, `maybe.advance()` could resolve as a writing `T` method while `call_inout` aliases the underlying `T?` slot, reaching the MIR verifier with incompatible types. | **Refused in stage 4:** a writing method requires the binding's actual type to equal its receiver type; bind the narrowed payload to a `var T` first. |
| S17 | Optional fallback carries an unwrapped string/struct through a hidden *borrowing* local.  If a later operand writes the source receiver, checking only whether that hidden local owns storage misses the dangling-view hazard (`use(b.text else fallback, b.clear())`). | **Fixed conservatively in stage 4:** every storage-typed `local_get`, including hidden fallback/spill locals, is copied when a later operand may mutate. |
| S18 | Receiver-effect inference initially inspected an assignment's final destination and right side but not expressions evaluated *inside the destination*.  `items[self.bump()] = 0` therefore looked read-only even though computing its index writes `self`. | **Fixed in declaration analysis:** index bases/subscripts and general chain places are walked for transitive receiver-writing calls, separately from classifying the final object-content store. |
| S19 | The existing “method is not a value” diagnostic suggested adapting every method with `(x) -> x.m()`.  That repair is invalid for an inferred writer because lambda parameters are immutable and function types have no inout receiver channel. | **Fixed diagnostically:** read methods retain the lambda guidance; writing methods point to a top-level/static receive-and-return operation instead. |
| S20 | Even for a read method, the old lambda recipe omitted every explicit method argument: `(x) -> x.plus()` cannot adapt `plus(other)`. | **Fixed diagnostically:** the concrete zero-argument recipe is used only when true; parameterized methods receive generic first-receiver/remaining-arguments guidance. |
| S21 | Several stage-4 comments still described the retired dual spelling as an identity (`p.length()` “is” `Point.length(p)`), even after the implementation correctly reserved the qualified spelling for `static`. | **Fixed in code documentation:** method lookup now describes direct read vs inout write lowering and the one valid receiver spelling. |
| S22 | Ordinary `var` parameters were already illegal, but failed as a generic “expected parameter name,” which hid SELF D5's actual rule. | **Improved in the parser:** `var value: T` now says parameters are values and directs the reader to a local `var` or an updated return value. |
| S23 | The dedicated `free(self)` ownership diagnostic was unreachable for struct receivers because `free`'s heap-only type gate ran first. | **Fixed diagnostically:** inout `self` is recognized before the ordinary container type check, while the operation remains refused. |
| S24 | Grouping inout `self` with ordinary borrowed parameters changed an established diagnostic and suggested parameter-signature repairs that do not apply to an implicit receiver. | **Fixed diagnostically:** borrowed parameters retain their existing message; inout `self` gets a separate caller-place/move refusal. |
| S25 | The first `give self` diagnostic advised giving one of self's fields, but `give` deliberately accepts only a bare owned name, so that repair could not be written. | **Fixed diagnostically:** it now suggests a borrowing parameter or `copy self`, both legal at this boundary. |
| S26 | Stage 7's ownership-pass commentary still claimed calls never write locals, and its new inout regression constructed a `call_inout` whose target was not an inout function. | **Fixed in the pass/tests:** the invariant names `call_inout` as the sole call-side local writer, and the regression now uses a verifier-valid inout callee shape. |
| S27 | Adventure/editor specification comments still described the retired `var self` copy-out model; one even claimed a caught error rolled receiver writes back. | **Fixed in test documentation:** the comments now describe implied self and the deliberately visible pre-error mutation boundary. |
| S28 | Standalone `give self` and `free(self)` were rejected generically because receiver-effect inference treated a bare `self` operand as a read; their dedicated inout-receiver diagnostics were reached only when an unrelated earlier write happened to classify the method as a writer. | **Fixed diagnostically:** recognize those inherently destructive spellings during receiver inference and make each regression prove the standalone operation.  Acceptance is unchanged. |
| S29 | The type reference still called every struct member a receiverless namespace function even after the executable site and the dedicated SELF coverage test passed; that check pinned the statement and expression pages but not the other reference page making the same claim. | **Fixed in site closeout:** correct `ref/types.md` and extend the focused coverage guard across that page too. |

## Follow-ups transferred to the permanent gap list

- Writing methods on nested mutable places such as
  `holder.counter.advance()` and `items[i].advance()` need a real place
  descriptor, caller-owner identity, and single-evaluation rules.  The
  current surface deliberately promises only a bare `var` binding.
- `examples/editor/editor.luc` still mirrors the compiler's keyword and builtin
  vocabulary manually.  Generating or checking those tables would prevent
  another drift like the missing `spawn` found during this run.

Both improvements are now recorded in [`docs/MISSING.md`](../MISSING.md),
so neither depends on this implementation ledger remaining open.

## Verification

Closed on 2026-08-08 with a stable worktree and an isolated Zig cache:

- repository suite: **65/65 build steps, 1632/1632 tests**;
- ReleaseSafe product build: **33/33 steps**, including every compiled
  program smoke target;
- grammar generation/pin: **10/10**;
- living-document checks: **7/7**;
- site generator: **32/32**, followed by **56 pages and 276 executable
  samples**, with every output matching and every link resolving; and
- whole changed Zig surface passed `zig fmt --check`; the complete patch
  passed `git diff --check`.
