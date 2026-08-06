# Architecture audit — the accumulated whole, after the storm

> **Executed, the XS/S set.**  Findings 1, 2, 4, 5, 7, 9, 10 and 11 are
> done and marked below with their commits, in the order the closing
> section asked for — 5 first, because collapsing the side arrays was
> mechanical then and would not have been once the vector layers landed
> on the same pattern.  Findings 3, 6 and 8 are M-sized and stay
> scheduled.  `zig build test` 1204 → **1207**, the delta being three
> new drift guards; `bench/compare.sh` against the base is noise on
> every row across two interleaved passes.
>
> One thing to know before merging: findings 4, 9 and 11 are each
> rooted in `04_semantics/builder.zig`, which was under a concurrent
> agent's territory hold for the `catch` binding.  The audit's own
> evidence names that file for all three, so there was no version of
> the prescribed set that avoided it.  The edits there are six small
> regions and all six are deletions of a list or one-token
> substitutions; none adds a line inside the `try`/`catch` machinery.

Audited at `fdba034`.  `zig build test`: 58/58 steps, **1187/1187 tests
passed**.  73,741 lines of Zig across 100 files.

This audit has one subject the previous one did not: **accumulation**.
`docs/audit/STRUCTURE.md` was taken at `0a22b81`, 111 commits and two
days ago.  Since then the tree absorbed true division and promotion,
`self`/`var self` methods, multiple returns, the seven-type ladder with
a full resize, storage-only narrow types, copy-on-store strings with
three storage intrinsics, the landing machinery, the `boxes`/`outcomes`
side tables, four guard tools and a sweep harness.  Each landed clean
per feature.  Nobody had read what they add up to.  That sum is what
follows.

Nothing here is audited against a memo.  The decision records say what
was intended; this reads the code.

## The test, restated

`docs/audit/STRUCTURE.md` settled the reconciliation between the
owner's instinct (split large files) and the guide's rule (split only
at a one-to-three-function interface):

> **A large file is fine if it is one subject, well-sectioned.  A large
> file hiding several subjects is the finding, at any size.**

That test acquitted `builder.zig` and `lower.zig` at ~4,670 lines
each.  This audit re-tries both at what they have become, and adds a
second test the storm makes necessary:

> **A judgment stated twice is a finding, however well-commented.**
> Proximity is not enforcement, and a comment saying "these must
> agree" is a record that nothing checks they do.

The tree passes the first test.  It is the second one that produces
almost every finding below.

---

## Summary of verdicts

| # | Finding | Verdict | Effort |
|---|---|---|---|
| 1 | The site's highlighter is a fourth copy of the word tables, and has already drifted | **Done** (`13e0974`) | XS |
| 2 | The runtime ABI is described twice and nothing compares the descriptions | **Done** (`d22f936`) | S |
| 3 | The method tables are the builtin-table consolidation, left half-finished | Restructure | M |
| 4 | `isFallibleIntrinsic` vs `verify.zig`: a carried-over finding the storm did not clear | **Done** (`fdb06ee`) | XS |
| 5 | Three register-indexed arrays are one record, written at the same seven sites | **Done** (`85a3364`) | S |
| 6 | The literal-landing rule is a twin, and the twins already guard differently | Restructure | S |
| 7 | The two "living document" lists disagree by one entry | **Done** (`9f6e125`) | XS |
| 8 | Four guards, four copies of the walking and extracting machinery | Restructure | M |
| 9 | The width-polymorphic set is a fourth list beside a table with a spare column | **Done** (`fdb06ee`) | XS |
| 10 | Comment-vs-code drift in two hot files and one README | **Done** (`13e0974`, `d22f936`, `9f6e125`) | XS |
| 11 | Three `pub` declarations with no external caller | **Done** (`680a267`) | XS |
| A | `builder.zig` is one subject | **Fine as is** | — |
| B | `lower.zig` is one subject | **Fine as is** | — |
| C | The import graph has no cycles | **Fine as is** | — |
| D | The runtime seam's *semantics* are single-sourced | **Fine as is** | — |
| E | The numeric lattice proper is stated once | **Fine as is** | — |

---

## 1. The site's highlighter is a fourth copy of the word tables, and it has already drifted

**Evidence.**  `build.zig:149` records the lesson in the tree's own
words: the committed editor grammar *"spent a release cycle
highlighting builtins the language had deleted, because it was a copy
and nothing checked it."*  That lesson was applied twice — `tools/
grammar.zig` imports `luce` and generates from the real tables,
`tools/doccheck.zig` imports `luce` — and `builder.zig:73` now says of
the builtin table: *"Published … because it is what the language
spells."*

`site/src/highlight.zig` is the copy that was not fixed, and it is
failing today:

* `type_names` (`site/src/highlight.zig:44-51`) lists `bool, long,
  double, string, list, map, array, builder`.  `support/types.zig:388-
  402` has thirteen: the eight above **plus `byte`, `short`, `int`,
  `half`, `float`**.  Five of the language's own type names render as
  plain identifiers.  `site/content/ref/types.md`, `tour/values.md`
  and `examples/traps.md` all write them inside `luce` fences — the
  reference page that documents the seven-type ladder does not
  highlight five of its rungs.
* `builtins` (`:57-67`) lists **`str`**, which is not in
  `builder.zig:78`'s table *or* in `retired_builtins`; the language has
  no such name (`string(x)` replaced it), so a program writing it is
  an unknown-name error the site colours as language.
* The same list carries **`arg`** and **`arg_count`**, both retired
  (`builder.zig:133-134`), and **omits `trunc`**, which shipped with
  `long(x)`'s rounding (`builder.zig:86`).

The guard at `:289` cannot catch any of this, because it is a *fifth*
copy: `reserved` (`:316-330`) is a hand-copied snapshot of
`04_semantics/context.zig:178`'s `reserved_names`, stale in exactly the
same places — it has `str`, `arg`, `arg_count` and lacks `trunc`.  A
test that duplicates the thing it checks proves only that the copy
equals the copy.

**Verdict: restructure.**  The header's excuse — the generator links no
part of the tree it documents — does not hold, because
`site/src/coverage.zig` in the same directory already solved it.  It
reads the compiler's tables *out of the source files at test time*:
`builtins(repository)` (`coverage.zig:173`) scrapes `builder.zig`'s
table, `methods(repository)` (`:203`) the four method tables,
`typeNames(repository)` (`:545`) `types.zig`'s `builtin_table`.  Its
own header (`:27-34`) names `highlight.zig`'s copies as the contrast
and says *"they read it, and there is nothing to keep in step."*

The fix is one test in `highlight.zig` calling those three existing
functions and asserting `inTable` for every name they return, and the
deletion of the `reserved`/`also` snapshots.  No new machinery.

**Precedent.**  Rust's tidy is the model for a checker that reads the
tree rather than a copy of it (`src/tools/tidy/src/walk.rs`, four
functions, thirty-three check modules over it).  The failure mode has
a name in this repo already — it is the one `build.zig:149` describes.

**Effort: XS.**  This is the highest-ranked finding because it is
already wrong, already public, and already has its fix sitting 200
lines away.

> **Done** (`13e0974`), and the audit undercounted the drift.  Beyond
> the five type names, the three deleted builtins and the missing
> `trunc`, `methods` was also missing `build` (`builder_methods` gained
> it) and the `lexed` snapshot in the deleted guard was missing `self`.
> Six stale places, not four.
>
> The guard is a two-way check and it lives in `coverage.zig` rather
> than in `highlight.zig` as prescribed, for one reason: `coverage.zig`
> is a test-only leaf and `highlight.zig` is production code the
> generator renders through.  Putting the test in `highlight.zig` would
> have meant publishing `Repository`, `open` and five scrapers out of a
> test-only file and giving production code an import edge into it.  The
> substance is the audit's — the compiler's sources are read at test
> time, no snapshot survives — and what moves instead is five word
> tables and `inTable`, `pub` for the guard and documented as such.
>
> `coverage.zig` gained three scrapers to make the check total: the
> lexer's keyword table, `reserved_names`, and `retiredSpelling`.  It
> checks **both** directions, which the audit's prescription (assert
> `inTable` for every name the scrapers return) does not: a
> forward-only check never sees `str`.  Demonstrated by putting `str`
> back and taking `assert` out — `'assert' has 0 classes, want 1` and
> `'str' is not a name the language spells`.

---

## 2. The runtime ABI is described twice and nothing compares the descriptions

**Evidence.**  `libluce_rt` has 69 `export fn`s
(`runtime/exports.zig`).  `08_llvm/runtime_effects.zig:105` declares a
`Service` enum with 69 tags, and `describe(service)` (`:344`) gives
each one a parameter list — `.run`, `.value_in`, `.value_out`,
`.bytes_kept`, … — from which `lower.zig` builds the LLVM
`declare`.  These are two hand-maintained lists of the same 69
functions.

Names cannot drift silently: `Service.symbol` is `@tagName`
(`runtime_effects.zig:197`), so a missing export is a link error.
**Shapes can.**  Nothing compares `describe(service).parameters` to the
real Zig signature.  A `describe` arm with the wrong arity emits a
`declare` with the wrong arity, links cleanly — C object files carry no
signature — and corrupts the stack at run time.  The three tests in the
file (`:755`, `:771`, `:776`) check `describe` against *itself*:
that every arm names a plausible list, that `value_size` is 24, that
only the host-calling exports withhold `nounwind`.  None reaches
`exports.zig`.

**Verdict: restructure**, to a proof rather than a registry.  The
exports are `export fn` and not `pub`, so nothing can name them; make
them `pub export fn` and one comptime test closes it:

```zig
for (std.enums.values(Service)) |service| {
    const signature = @typeInfo(@TypeOf(@field(exports, @tagName(service)))).@"fn";
    // parameter count, and each Parameter shape against its Zig type
}
```

One function, total over the enum, no `else`.  That is a single
registry in the only sense that matters — two statements that cannot
disagree — without merging two files that legitimately live in
different modules.

**Precedent.**  This is the discipline `builder.zig:6792` already
applies to builtins (*"Read from the two tables rather than from a copy
of either"*), and the same shape as Zig's `runtime_effects`-adjacent
layout assertions.  rustc's equivalent seam — `rustc_codegen_ssa`'s
symbol declarations against the real runtime — is checked by the linker
because Rust's ABI carries types; C's does not, which is precisely why
this one needs the test.

**Effort: S.**

> **Done** (`d22f936`), by the comptime the audit sketches, with two
> additions.  It is seventy entry points now, not sixty-nine.  The
> shape check goes past arity to the pointee: `.value_in` must be a
> `*const Value` and not merely a pointer, `.run` must be the runtime,
> `returns_noalias` must sit on something that can carry it.  And a
> second test closes the direction the first cannot see — an export
> with no `Service` tag is a symbol generated code has no way to call.
>
> Demonstrated both ways: `luce_rt_leaked: described with 2
> parameter(s), declared with 1`, and `luce_rt_close: parameter 0 is
> described .value_in and declared *runtime.heap.Runtime`.
>
> One thing the audit could not have known: publishing the exports is
> not enough to name them.  `runtime.zig`'s `comptime { _ = @import(…) }`
> is load-bearing — replacing it with a `pub const` alone made
> `libluce_rt.a` link empty, because a namespace's `pub` declarations
> are analyzed when something reaches them and the linker is not
> something Zig can see reaching one.  Both are there now, with the
> reason written down.

---

## 3. The method tables are the builtin-table consolidation, left half-finished

**Evidence.**  The storm's best structural work is `builder.zig:55-77`:
`Builtin { name, kind, arity, host, pure }`, one row per free builtin,
read by `lowerIntrinsic` for dispatch and by `isPureBuiltin` for the
ownership analysis.  Its doc comment records what it replaced —
*"two lists of the same thirty-nine names, 3,375 lines apart in this
file, with nothing checking they agreed."*  That is finding 8 of the
previous audit, correctly closed.

The **methods** did not get the same treatment.  Their name set is
written three times:

1. `list_methods` / `array_methods` / `map_methods` / `builder_methods`
   (`builder.zig:5917-5923`) — flat name lists, published for
   suggestions and the editor grammar.
2. `methodParameters` / `sequenceParameters` (`:5679`, `:5716`) — the
   landing and arity table, a chain of `std.mem.eql`.
3. `sequenceMethod` / `objectMethod` (`:6038`, `:5932`) — the dispatch
   to intrinsic kinds, another chain of `std.mem.eql` over the same
   names.

The comment at `:5909` is honest about the arrangement — *"Kept beside
the dispatch so the two cannot drift apart unnoticed"* — and that is
proximity, not enforcement.  Two of the three are 400 lines apart; the
third is 250 lines from that.

`methodParameters` itself is excellent and should be kept: its doc
(`:5661-5673`) explains that it is consulted before an argument is
lowered *and* after, so a literal lands at the right width, and that
*"two answers from one table cannot disagree; two tables would."*  The
finding is that the observation was applied to two of the three
readers and not the third.

**Verdict: restructure**, along the line the file already drew.  One
row type — `Method { name, kind, receiver_kinds, parameters, result }`
where `parameters` and `result` are functions of the receiver's element
/ key / value type — and all three readers derive from it.  This is the
`Builtin` refactor a second time, on the harder half.

**Precedent.**  In-repo, and it is the strongest kind: the same file,
5,000 lines up, with the cost of not doing it written in its doc
comment.

**Effort: M.**  The parameter types depend on the receiver, so the rows
carry small functions rather than constants — which is what
`sequenceParameters` already is.

---

## 4. `isFallibleIntrinsic` vs `verify.zig`: a carried-over finding the storm did not clear

**Evidence.**  `builder.zig:6769` lists the six fallible intrinsics;
`06_mir/verify.zig:474-479` lists the same six.  The comment above the
first says so and names the consequence: *"`06_mir/verify.zig` keeps
the same list — a program where the two disagree is one that could
branch on a word nobody wrote."*  Both switches carry an `else`, so
adding a seventh fallible intrinsic to one and not the other is silent
in both directions.

`docs/audit/STRUCTURE.md:475` raised this as part of finding 8 in
August.  It is unchanged.

**Verdict: restructure**, and it is nearly free.  The predicate belongs
on the enum, in `06_mir/defs.zig`, as an exhaustive `pub fn
isFallible(self: Intrinsic) bool` with no `else` arm — so a new
intrinsic is a compile error until someone classifies it.  Both callers
then ask the type.

The same move retires the other `else`-guarded per-intrinsic predicates
in `builder.zig`: `producesFreshStorage`'s inner switch (`:927`) and
`storedElement` (`:5625`).  `07_optimize/effects.zig:143`'s
`intrinsicEffect` already does it correctly — exhaustive, no `else` —
and is the model.

**Precedent.**  Zig's own rule, which this backend adopted for
instruction lowering and stated in `lower.zig:11-15`: *"the switches
… name every tag, so adding an IR instruction is a compile error here
rather than a silent fallthrough — the deleted backends had 23 `else`
arms and that is how a register corruption bug survived."*  The rule is
right; it has not reached the predicates.

**Effort: XS.**

> **Done** (`fdb06ee`), all three, as exhaustive methods on `Intrinsic`
> in `06_mir/defs.zig`: `isFallible`, `makesFreshStorage` and
> `storedArgument`.  Both of `isFallible`'s callers ask the type now.
> `storedElement` keeps the receiver-shape narrowing that is genuinely
> its own and takes the positions from the enum.
>
> Demonstrated: a new `Intrinsic` tag fails to compile at all three,
> named — `unhandled enumeration value: 'file_touch'` at `defs.zig`
> lines 211, 306 and 408.
>
> **Territory:** the three call sites are in
> `04_semantics/builder.zig`, which was held for the `catch` binding.
> There is no form of this finding that avoids that file — the audit's
> evidence is three line numbers in it — so it was done rather than
> deferred; see the note at the top of this document.

---

## 5. Three register-indexed arrays are one record, written at the same seven sites

**Evidence.**  `08_llvm/lower.zig:1417-1443` — `values`, `boxes`,
`outcomes`, each `[]Builder.Value` of length `instructions.len`, each
allocated and `@memset` separately at `:1501-1506`, each freed at
`:1471-1473`.

The measurement that decides this: `values[r]` is written at 50 sites;
`boxes[r]` at 7; `outcomes[r]` at 7.  And at every one of those seven,
**they are written together with the value**:

```
3131  self.values[register]   = try self.unboxed(.string, box, "read.value");
3132  self.boxes[register]    = box;
3133  self.outcomes[register] = try self.wip.load(.normal, .i32, outcome_slot, flag, "read.outcome");
```

The same triple at `:3262-3264`; box-with-value at `:2265/2273`,
`:3455/3460`, `:3488/3490`, `:4369/4371`, `:4577/4578`.  These are not
independent facts that happen to share a key.  They are three columns
of one record — *what this register produced: its SSA value, the memory
it was read out of, and the outcome flag standing beside it* — and the
record is written whole.

**Verdict: restructure**, to one array of a struct.  Not to a sum type:
I expected one and the code refuted it.  `boxes[r]` does not *replace*
`values[r]`; `boxAt` (`:1853`) falls back to re-boxing the value when
the box is absent, so both are live together.  The states coexist, and
the right shape for coexisting per-entity facts is one struct.

**Precedent** (all verified in source today).  Go's register allocator
is the exact match — `ssa/regalloc.go:288`'s `valState` groups seven
per-value facts (`regs`, `uses`, `spill`, `restoreMin`, `restoreMax`,
`needReg`, `rematerializeable`) into **one** `values []valState`
(`:327`), not seven arrays.  Cranelift's `SSABlockData`
(`cranelift/frontend/src/ssa.rs`) does the same for three per-block
facts in one `SecondaryMap`, and `cranelift-entity`'s own
documentation is the rationale for when a side map is legitimate at
all.  Zig's `FuncGen` keeps one `func_inst_table`
(`src/codegen/llvm.zig:4693`) and, where a feature needs several facts,
groups them — `SwitchDispatchInfo` holds three fields in one map rather
than three maps.  Go's `ssagen/ssa.go:1028` carries the counter-example
and flags itself: a `TODO` on four parallel variable maps asking
whether they should be one.

The two deeper moves the same sources suggest, both worth recording
even though neither is urgent:

* **`boxes` need not exist at all.**  Zig and Cranelift have no
  equivalent because "this needs memory" is decided upstream — an
  `alloc` instruction, a `StackSlot` entity — and the backend never
  re-decides.  rustc keeps the decision in codegen but confines it to a
  pre-pass returning a bitset consumed once at init
  (`rustc_codegen_ssa/src/mir/analyze.rs:17`).  Luce's `boxes` is
  provenance the lowering recomputes; the IR could carry it.
* **`outcomes` is a second result modelled as side state.**  Nobody
  else does this.  rustc's `BinOp::AddWithOverflow` yields `(T, bool)`
  as an `OperandValue::Pair`; Zig returns the `@llvm.*.with.overflow`
  aggregate as one value; Go uses a tuple-typed value with
  `OpSelect0`/`OpSelect1`; Cranelift uses `ValueData::Inst{num}` and
  `inst_results()`.  Every one of them made the second result a
  *value*.

**The concrete test the vector work supplies.**  `docs/VECTOR.md` needs
per-register witness accumulators and chunk state, and Layer 1 and
Layer 2 differ by exactly "the witness and the second arm" (`:325`).
Under the current pattern that is two or three more `[]Builder.Value`,
each with its own `alloc`, `@memset`, `free` and read sites — the cost
of a feature is *a new array*.  Under one struct it is a new field, and
Layer 2 over Layer 1 is a field that Layer 1 leaves `.none`.  That is
the difference between a pattern that extends and one that accretes.

**Effort: S.**  Mechanical: one `Produced` struct, one array, one
`@memset` of `.{}`, and `self.values[r]` becomes `self.produced[r].value`.
Worth doing *before* the vector layers, not after.

> **Done** (`85a3364`), exactly as written: `Produced { value, box,
> outcome }`, one `produced: []Produced`, one `alloc`, one `@memset` of
> `.{}`, one `free`.  129 read and write sites moved mechanically; the
> three field doc comments moved with the fields, so the reasoning
> about why `box` exists now sits on `box`.
>
> No behaviour change and no cost: `bench/compare.sh` against the base,
> two interleaved passes, moves every row by under 4% in *both*
> directions between passes — `strings` is +3.5% then +0.7%, `arrays32`
> is −1.2% then +2.9% — which is the shape of noise and not of a
> regression.  Nothing about the generated code can differ; this is a
> compile-time data structure.
>
> The two deeper moves the finding records — retiring `boxes`, and
> making `outcomes` a second *value* — are untouched and still stand as
> written.

---

## 6. The literal-landing rule is a twin, and the twins already guard differently

**Evidence.**  `declarations.zig:1023` is candid: *"the constant
folder's twin of the builder's `lowerIntLiteral`, and it has to be a
twin, because a file-scope `let` is folded here and a local one is
lowered there and the two must agree on what `1` is."*

They do not agree on their precondition.

```
declarations.zig:1038   const lands: Type = if (wanted) |place|
                            (if (place.isNumeric()) place else .int) else .int;

builder.zig:3608        const lands: Type = wanted orelse .int;
```

The folder guards `isNumeric` and explains why (`:1034-1037`: `let
flag: bool = 3` must reach the mismatch message rather than be folded
into a bool-typed 3).  The builder does not guard at all.  It is
correct today only because every `self.wanted` assignment happens to
come from `landingType`, which returns null for non-numerics — seven
sites, `:1670`, `:1876`, `:2088`, `:3154`, `:4432`, `:4446`, plus the
pass-through at `:4846`.  That is an unenforced invariant on a mutable
field, and the eighth assignment breaks it silently: a `const_long`
emitted at a boolean type.

The float-literal arms (`builder.zig:3641`, `declarations.zig:1116`)
are byte-identical, and `widenNumeric` / `widenConstant`,
`unifyNumeric` / `Type.unified`-plus-`widenConstant` are the same
judgment applied to registers and to values.

**Verdict: restructure**, narrowly.  The *lattice* is fine (finding E);
what is doubled is the landing rule sitting on top of it.  Lift the two
literal-landing decisions into pure functions beside `Type` —
`fn intLiteralLands(wanted: ?Type) Type` and
`fn floatLiteralLands(wanted: ?Type) Type` — and have both twins call
them.  A one-to-two-function interface, no state, testable directly.
The emit halves stay where they are, which is where they belong: one
makes registers, the other makes values.

**Precedent.**  Zig is the maximal position — comptime and runtime go
through one `Sema`, so there is no twin to keep honest — and Luce
cannot follow it, because folding a file-scope `let` produces a value
and lowering a local produces IR.  rustc lives with the same split
(const-eval separate from codegen) and keeps them honest by sharing the
*type* layer, which is precisely what this finding asks for: share the
decision, not the emission.

**Effort: S.**

---

## 7. The two "living document" lists disagree by one entry

**Evidence.**  `tools/doccheck.zig:80-105` declares `documents`, whose
first `living_count = 10` entries are the living documents.
`tools/spelling.zig:86-98` declares `living` with **eleven**, and the
comment at `:84` says the two *"are meant to be read together."*

The odd one is `docs/README.md`: spell-guarded by `spelling.zig`,
absent from `doccheck.zig`'s list entirely.  Its prose may not name a
retired type; its Luce samples are never compiled.  It has none today,
so nothing is broken — but the gap is the wrong way round, and it is
the kind that is only discovered by adding a sample.

**Verdict: sectioning.**  `doccheck.documents` and `living_count` are
already `pub`.  Either give `spelling_guard` that import in `build.zig`
(it currently imports nothing) or lift the list into a five-line
`tools/documents.zig` both read.  One declaration, one truth.

**Effort: XS.**

> **Done** (`9f6e125`), by the second option.  The first would have
> dragged the whole `luce` module into `spelling.zig` for a list of
> filenames; `tools/documents.zig` imports nothing and is read by both.
> `docs/README.md` joins the living set, which is what half the guard
> already treated it as, and `doccheck`'s deliberate anti-vacuity count
> moves 20 → 21.

---

## 8. Four guards, four copies of the walking and extracting machinery

**Evidence.**  Five tools grew in a week; four of them read the
repository, and each brought its own reader.

* **Directory walking**: `spelling.zig:146` opens and iterates
  directories itself; `site/src/coverage.zig:54-88` has a `Repository`
  type that finds the root by landmark and reads by path.  Two
  mechanisms, two root-finding conventions.
* **Fenced-block extraction**: `doccheck.zig:144` (`fences`),
  `spelling.zig:197-205` (inside `scan`), `site/src/verify.zig`, and
  `site/src/markdown.zig:131` (`blocks`, for rendering).  **Four
  parsers of the same notation.**
* **Two fence vocabularies for one syntax.**  `doccheck` accepts
  `luce` / `fragment` / `refused` / `historical`; `verify.zig` accepts
  `luce run` / `trap` / `raise` / `fail` / `module file=`.  Disjoint,
  each enforced over its own tree — coherent by partition, but an
  author must know which tree they are in, and neither tool's error
  message says the other exists.

`grammar.zig` walks nothing (it imports `luce` and emits JSON) and
`sweep.sh` is a mutation harness, not a reader — so the duplication is
four-way, not five.

**First, the credit, because it is the part that matters most.**  The
one thing all four surveyed projects share is not tool count — it is a
**single entry point**: `./x test`, `go test`, `zig build test`, `lit`.
No contributor has to remember to run five commands.  Luce already has
this: every guard is a step of `zig build test`, wired in `build.zig`,
and `sweep.sh` is the only thing outside it.  The most important
property is present, and the finding below is about packaging beneath
it, not about the seam.

**Verdict: restructure**, but not urgently and not into a framework.
The shared need is small and nameable: *walk a tree by suffix*, and
*extract Luce source from three containers* (a `.luc` file whole, a
Markdown fence, a Zig multiline literal).  That is a two-function
library — `tools/corpus.zig` — that `spelling`, `doccheck` and the
site's checks all consume.  The fence *taxonomies* should stay separate;
what should not be separate is the code that finds a fence.

**Precedent.**  Rust's tidy is the model and it is exactly this shape:
one binary, thirty-four check modules
(`src/tools/tidy/src/lib.rs:104-137`), and a shared walker of **106
lines total** (`walk.rs`: `walk`, `walk_many`, `filter_dirs`,
`filter_not_rust`).  Go's `x/tools/go/analysis` is the same principle
with a driver instead of a walker, and its `inspect.Analyzer` — the
shared traversal every other analyzer depends on — is two lines of
logic.  Nobody built a framework; they built the hundred lines that
would otherwise be copy-pasted.

Three sharper points the sources give, each of which changes the shape
of the fix:

* **The tipping point is quantified, and Luce is past it.**
  `go/ast/inspector`'s own doc comment is the only hard number any of
  these projects states: *"it may take around 5 traversals for this
  benefit to amortize the inspector's construction cost."*  Five
  guards.
* **The seam is the input corpus, not the check count.**  Rust splits
  sharply: everything reading repo *source text* goes through `walk()`
  inside tidy; everything reading *built artifacts* (`linkchecker` over
  HTML, `jsondoclint` over rustdoc JSON) is its own binary sequenced
  after a build step.  By that line, doccheck, spelling, grammar and
  coverage are all tidy-shaped — they all read repo text.  Only
  `sweep.sh` is a different animal, and it belongs in `build.zig` as a
  step rather than as a script.
* **Do not write what already exists.**  Tidy does not implement
  spellchecking.  `extra_checks/mod.rs` shells out to `typos-cli`
  pinned at `1.38.1`, plus `ruff`, `shellcheck` and `eslint`, each
  gated on presence and each honouring one shared `--bless`.  A
  hand-written spelling checker is the one of Luce's five that no
  surveyed project writes itself — though `spelling.zig` is not a
  general spellchecker but a rename guard over a closed list of
  thirteen names, which is a narrower and more defensible thing.

The best statement of the defect is not "five tools" but this: Go's
`singlechecker` and `multichecker` exist so that **the cost of writing
a check is one value, and how it ships is decided later, by someone
else, reversibly.**  Luce's guards each hardcoded that decision at
authoring time.

**Effort: M**, and it is the one finding here that can wait — every
guard works today, and consolidating four readers is worth doing when a
fifth is proposed, not before.

---

## 9. The width-polymorphic set is a fourth list beside a table with a spare column

**Evidence.**  `builder.zig:6399`:

```zig
const polymorphic = switch (matched.kind) {
    .abs, .min, .max, .clamp, .sqrt, .floor, .ceil, .trunc => true,
    else => false,
};
```

`Builtin` (`:55`) already carries a `pure: bool` column added for
exactly this reason, and its doc says `isPureBuiltin` reads it.  The
polymorphic set is the same kind of per-builtin fact, written as an
`else`-guarded switch 6,300 lines from the table it belongs to.

**Verdict: sectioning.**  Add `polymorphic: bool = false` to `Builtin`,
set it on eight rows, delete the switch.  The table's own doc comment
already promises this is where such facts live.

**Effort: XS.**

> **Done** (`fdb06ee`), exactly so.  **Territory:** in
> `04_semantics/builder.zig`; see the note at the top.

---

## 10. Comment-vs-code drift in two hot files and one README

**Evidence.**

* `08_llvm/runtime_effects.zig:3` — *"Generated code calls fifty-eight
  runtime entry points"*.  There are 69, in the enum 100 lines below.
* `tools/README.md:7-8` — *"Everything else here tested the
  hand-written code generators and went away with them"*, listing only
  `vscode-luce/`.  The directory now holds `doccheck.zig`,
  `spelling.zig`, `grammar.zig`, `sweep.sh` and `testdata/`.  The
  README of the guard directory is the one document in the tree no
  guard reads.
* `site/src/highlight.zig:55` — *"The compiler's list is the table in
  `04_semantics/builder.zig`'s `lowerIntrinsic`"*.  The table moved out
  of `lowerIntrinsic` to file scope (`:78`) when it was consolidated.

Three in a sample of the files I read whole, all of the same kind: a
count or a location that was true when written.  The prose in these
files is otherwise unusually load-bearing and unusually accurate — the
reason to fix these is that a reader who finds one wrong number stops
trusting the rest, and in this tree the rest is worth trusting.

**Verdict: sectioning.**  **Effort: XS.**

> **Done**, all three, each in the commit that fixed what it described:
> the runtime-effects header (`d22f936`) no longer states a count at all
> — it names the set and points at the test that proves it, which is a
> number that cannot go stale; `tools/README.md` (`9f6e125`) names the
> four guards that grew there and the thing worth knowing about them,
> that each is a step of `zig build test`; and `highlight.zig`'s
> pointer at `lowerIntrinsic` (`13e0974`) now names the file-scope
> table.

---

## 11. Three `pub` declarations with no external caller

Rerunning the previous audit's method over the load-bearing files
returns three, which is a good result for 111 commits:

* `builder.zig:845` `declareLocal` — only `declareLocalAs` calls it.
* `06_mir/build.zig` `resultType` — four callers, all in the file.
* `04_semantics/helpers.zig` `editDistance` — one caller plus its own
  tests, all in the file.

**Verdict: sectioning.**  Drop the `pub`.  **Effort: XS.**

> **Done** (`680a267`).  One correction: `declareLocal` has five
> callers, not one — but all five are in `builder.zig`, so the verdict
> stands unchanged.  **Territory:** one of the three is in
> `04_semantics/builder.zig`; see the note at the top.

---

# Acquittals

## A. `builder.zig` is one subject

6,824 lines, up from 4,677 — **+46% in 111 commits**, the largest
single accumulation in the tree.  It now holds checking, IR emission,
ownership, narrowing, landing, methods, returns and storage.  The
question is whether that is eight subjects.

It is not.  It is one subject — *the checked walk of one function
body* — with one state object, `FunctionBuilder`, and every section
reads it.  The interlock that justified the acquittal is unchanged and
is stated at the top of the file: checking and emitting are one visit
because *"resolving `xs.append(v)` needs the receiver's type and typing
it needs the name resolved first."*  The storm strengthened that
argument rather than weakening it.  `lowerOperandsInto` (`:1811`) now
runs three analyses in one left-to-right pass — landing, block-split
spilling, and the copy-on-store mutation hazard — and its doc (`:1730`)
explains that splitting the batch *"would have given up the
cross-operand analysis that copies a borrowed string before a later
operand can free it."*  That is a real interlock, not an excuse.

The sectioning licence is earned: **19 named sections**, up from the
eight the previous audit's finding 6 installed.  I looked for the
subject that could leave and did not find one.  The best candidate is
narrowing (`:314-430`, six functions over one set) — and it fails the
guide's own test, because `applyFacts` needs `findLocal`, which would
have to become `pub` for a sibling.  The guide says that split is the
wrong split, and it is right.

**Measured against precedent**: Zig's `src/Sema.zig` is **37,745
lines** doing the same job under the same one-pass architecture — its
header says it "*Transforms untyped ZIR instructions into
semantically-analyzed AIR instructions. Does type checking, comptime
control flow, and safety-check generation*" — and `builder.zig` is 18%
of it.  Go ships an 8,165-line `ssagen/ssa.go` with no package doc
comment at all; Swift ships a 17,064-line `CSSimplify.cpp` that nobody
publicly considers a problem.  6,824 lines is not a large compiler
file, and neither Zig, Go nor Swift has any rule about file length.

**Two pieces of counter-evidence worth recording**, because they bear
on whether a future split would help:

* **Splitting is not size control.**  Zig's four extractions from
  `Sema.zig` (`bitcast.zig`, `comptime_ptr_access.zig`, `arith.zig`,
  `LowerZon.zig`) each bought roughly one release of growth and the
  file returned to trend — 36,927 at 0.11.0, 38,610 at 0.12.0, 37,644
  at 0.15.1, 37,745 today.  None of the four commits gives length as a
  reason.  The criterion they *do* give (PR #19630) is the guide's:
  helpers "*not generally useful elsewhere*… with simple re-exports
  for their **small public APIs**" — 1,847 lines behind six symbols.
* **Splitting without a seam fails, and it failed for exactly the
  reason `docs/CODING_GUIDE.md` names.**  Go tried to move the SSA
  builder out of `ssa.go` (CL 795076, 2026-06) for build-parallelism
  reasons.  It needed an import-cycle bridge and exports created purely
  for the seam — `isStructNotSIMD` → `IsStructNotSIMD` — and was
  abandoned three weeks later.  That is the guide's rule confirmed by
  a real attempt: *if the split forces a declaration `pub` purely for
  a sibling, the split is wrong.*

**The strongest argument against this acquittal**, which I record
rather than dismiss: rustc and Swift both put two of `builder.zig`'s
responsibilities on the far side of an IR boundary, deliberately.
rustc invented THIR so that "*method calls and overloaded operators are
converted into plain function calls*" happens **after** checking — so
Luce's landing and method-call lowering are, in rustc's architecture,
definitionally past the boundary.  Swift moved definite initialization
off the type checker entirely onto mandatory dataflow passes over raw
SIL, because flow-sensitive initialization checking is the class of
thing an AST walk does badly.  Luce's ownership checking and its
optional-narrowing flow analysis are that class of thing.

I do not think it flips the verdict, for three reasons, and the third
is the one that decides it.  Luce's ownership is scope-based and
largely syntactic — *the binding that received a fresh object owns it*
— not borrowck's fixpoint over a control-flow graph; the IR-level half
that does need the CFG already exists as its own pass
(`07_optimize/ownership.zig`); and the interlock runs the other way
from rustc's.  `lowerOperandsInto` must interleave landing with the
copy-on-store mutation hazard **within one left-to-right operand
walk**, because a literal's width depends on a receiver lowered in the
same batch, and a borrowed string must be copied before a later operand
in that same batch can free it.  rustc can separate the two because its
literals do not take their width from a receiver.  Luce's do (D3), and
that is a language decision, not an implementation accident.

The honest form of the verdict is therefore: **the architecture is
right for this language, and it is the one thing in the tree whose
cost would be highest to change later.**  If a future language change
ever removes the receiver-to-literal dependency, this acquittal should
be re-tried, and the two responsibilities named above are where the
knife would go.

**Fine as is** — with finding 3 against its method tables and finding 6
against its literal twin, neither of which is a size problem.

## B. `lower.zig` is one subject

5,101 lines, up from 4,672 — **+9%**, which is the more interesting
number: it absorbed boxes, outcomes, loops and the artifact description
and grew by a twelfth, because `loops.zig` (639) and
`runtime_effects.zig` (783) were split out as it went.  That is the
guide's rule being applied correctly in flight.

Two structs, cleanly divided: `Module` (`:241`) is per-program state —
types, text interning, struct zeros, service declarations — and `Body`
(`:1381`) is one function.  **25 named sections.**  The two large
switches are dispatch tables, not functions doing many things:
`emitIntrinsic` is 573 lines of 77 arms averaging six lines each, in a
uniform `callAnswering` / `callChecked` shape; `lowerIntrinsic` in
builder is 447 lines of the same kind.  Zig's `src/codegen/llvm.zig`
is 13,384 lines with a switch of comparable arity, and Go's
`ssagen/ssa.go` is 8,165.

Swift supplies the sharpest calibration of the house test, because it
holds both poles at once.  `lib/Sema/CSSimplify.cpp` is **17,064
lines** and goes unremarked — one subject.  A **7,000-line** SIL parser
was condemned on the forums, and on responsibilities rather than size:
*"It attempts to do three things: read SIL text, check and verify the
input, and transform the input into SIL instructions… The current
implementation tries to do everything in one place."*  Three
responsibilities at 7,000 lines is a finding; one responsibility at
17,064 is not.  That is the test this audit applies, arrived at
independently by another compiler's maintainers.

**Fine as is** — with finding 5 against its side tables, which is a
data-shape finding and not a file-boundary one.

## C. The import graph has no cycles

Every relative `@import` in `src/luce` was extracted and read.  Every
edge runs downhill — a later stage to an earlier one, or to `support/`
or `runtime/`.  There are exactly three back-edges, and all three sit
**below a `Tests` section header**: `06_mir/module.zig:522-523` reaches
`compile.zig` and `interpreter.zig`, and `08_llvm/loops.zig:475`
reaches `compile.zig`, each to compile a program for its own tests.
That is idiomatic Zig and not a cycle in the shipping graph.

One edge deserves praise rather than suspicion:
`04_semantics/declarations.zig` imports `runtime/operators.zig` so the
constant folder computes `%` with the runtime's own floor modulus
(`:1087`) rather than Zig's `@mod`, which disagrees for a negative
divisor.  That is the single-implementation rule reaching into the
front end, correctly.

`support/diagnostics.zig` importing `01_source.zig` is a support module
reaching a stage; it is where `Span` lives, and moving it would be
churn for its own sake.

## D. The runtime seam's semantics are single-sourced

The claim that matters most survives inspection.  Both engines bottom
out in the *same* Zig function:

```
interpreter/machine.zig:793   .list_find => return .ofLong(try containers.find(...))
runtime/exports.zig:788       const at = containers.find(runtime, target.*, wanted.*) catch ...
```

`exports.zig` is a thin C shim — error to `i32`, result through an
out-pointer — over the same `containers.*` / `text.*` / `heap.*` the
interpreter calls directly.  Nothing is implemented twice.  The
intrinsic *dispatch* is written twice (a switch in `machine.zig`, a
switch in `lower.zig`), which is the unavoidable cost of two engines,
and it is exactly what the differential oracle in `specs/` exists to
prove equal — prints, trap code, trap message, call trace, leak census
and the world left behind, on every program in the suite.  That is a
named discipline with Miri as its precedent, and it is working.

The seam's *description* is the finding (2), not its implementation.

## E. The numeric lattice proper is stated once

I grep-mapped every site that asks "what type does this land at" — 70
call sites across three files, excluding tests and specs — and they
route to one answer.

`Type.widensTo` (`support/types.zig:209`) is the whole of implicit
conversion, in one switch, with the reasoning in its doc comment
(including what is deliberately *absent*: Java's `int → float`).
`Type.unified` (`:232`) is built on `arithmeticType` (`:181`) and
nothing else.  Crucially, `widenNumeric` (`builder.zig:1542`) —
the one function that emits a widening — **asserts** rather than
re-decides:

```zig
std.debug.assert(value.value_type.widensTo(to));
```

and says why: *"The caller has already asked `widensTo`; this asserts
it rather than re-deciding it, so there is one statement of the
lattice."*  Every promotion path funnels through it: `fit`, `promoted`,
`unifyNumeric`, `widensInto`.  `fit` (`:1513`) is documented as *"the
one place promotion happens"* and the claim holds.

The landing machinery is likewise a real design and not an accretion.
`Landing` (`:1788`) is a five-arm sum type — `nothing`, `places`,
`method`, `stored_element`, `subscripts` — answered per operand by
`landsOn` (`:1738`) because a method's parameter types are not known
until operand zero is lowered.  `methodParameters` is "the one table"
consulted twice for exactly the double-rounding reason its doc gives.

What is *not* stated once is the layer above the lattice: the literal
landing rule (finding 6) and the polymorphic set (finding 9).  The
lattice itself is clean.

---

# The answer

**This is release-shaped.**  The two things that would have made it not
so — a file that had quietly become several, and a pipeline that had
grown back-edges — are both absent: `builder.zig` and `lower.zig` are
each still one subject with one state object, better sectioned at 6,824
and 5,101 lines than they were at 4,670, and the import graph's only
back-edges are three test imports sitting under their own section
headers.  The semantics are single-sourced where it counts, the numeric
lattice is stated once and asserted rather than re-decided at its one
emission site, and the landing machinery is a designed sum type rather
than a pile of special cases.  111 commits in two days did not produce
spaghetti; they produced a bigger version of the same shape, which is
the outcome the guiding principle was aiming at.

What the speed did leave is a specific, bounded debt with a single
signature: **eleven places where a judgment is stated twice and a
comment, rather than a compiler, is what keeps the two in step.**  Four
of them are already wrong — the site highlighter has lost five type
names and gained three deleted builtins (1), the two living-document
lists disagree by one entry (7), and two headers name counts and
locations that have moved (10).  The rest are correct today and
unenforced tomorrow: the runtime ABI's shapes (2), the method tables
(3), the fallible-intrinsic list the previous audit already raised (4),
and the literal-landing twins whose guards already differ (6).  None of
these is architectural.  All of them are the same fix — derive, or
prove agreement in a test that reads both sources — and the tree
already knows how, because it did exactly that for the free-builtin
table and for the editor grammar and wrote down what the copy had cost.

> **Done, and in that order.**  Findings 1, 2, 4, 5, 7, 9, 10 and 11
> are closed; 3, 6 and 8 stand as scheduled below.  What the day
> actually cost was closer to half of one, and the two findings that
> took most of it were the two the audit ranked hardest — the runtime
> ABI's shapes, and the highlighter's guard, which needed three new
> scrapers before it could be written against the real sources.

**Before the roadmap resumes**, do findings 1, 2, 4, 7, 9, 10 and 11:
they are XS or S, they total perhaps a day, and every one of them
converts a comment into a compile error or a test.  Do finding 5 as
well, and do it *first* among the code changes — collapsing `values`,
`boxes` and `outcomes` into one array of a record is mechanical today
and stops being mechanical the moment the vector layers add witness and
chunk state to the same pattern, because that is the change that turns
"three columns of a record" into "five parallel arrays nobody chose."
Findings 3, 6 and 8 are M-sized and can be scheduled: the method-table
consolidation should happen before the next batch of methods lands, the
literal twins before the next numeric change, and the four fence
parsers when someone proposes a fifth.
