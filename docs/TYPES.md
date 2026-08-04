# Seven numbers, and the two that are still spelled `Int` and `Float`

> **The rule.** There are seven numeric types on two ladders —
> `Byte` `Short` `Int` `Long` and `Half` `Float` `Double` — sized the
> way Java sizes them, which means **`Int` becomes 32 bits and `Float`
> becomes 32 bits.** A numeric literal has no type until it meets one;
> unconstrained, it is a `Long` or a `Double`. `Byte`, `Short` and
> `Half` are storage: arithmetic on them happens at `Int` and `Float`,
> so there are four arithmetic types and not seven. Widening is
> implicit along each ladder and across the two only into `Double`;
> **narrowing is never implicit** and is spelled with the name of the
> type it produces. Nothing in this tree changes meaning, because
> every existing `Int` becomes a `Long` and every existing `Float`
> becomes a `Double` before either name is resized.

`docs/MEMORY.md` records why scope ownership won; `docs/FAILURE.md`
why there are three failure mechanisms and not one; `docs/NUMERICS.md`
why `Int` promotes to `Float`, and it is this memo's direct parent —
every rule it ratified is inherited here, restated over seven types
instead of two, and **not one of its answers is overturned.** It is
also the model for the shape of this document, including the trick in
*Order* that makes the dangerous step boring.

It is not on `docs/MISSING.md`'s list. `docs/MISSING.md`'s *"The order
to work down"* has eleven numbered items and a numeric ladder is none
of them — `docs/RETURNS.md` closed item 10 and corrected two memos
that had each invented a Tier for that list. This one arrives from
outside the inventory, which is worth saying plainly rather than
retrofitting a citation: the gap list did not predict it, because the
gap list was written about a language whose two numeric types were
believed finished.

---

## What the owner decided

**2026-08-04:**

> *"we need to introduce full type list: for floating point: Half,
> Float, Double. for integer: Byte, Short, Int, Long."*

and, when asked whether that resizes the two names the language
already has:

> *"yes - we're changing the size of Int and Float obviously."*

So it is settled, and this memo does not relitigate it. `Byte` is 8
bits, `Short` 16, `Int` **32**, `Long` 64; `Half` is binary16, `Float`
**binary32**, `Double` binary64. That is Java's tower, C#'s, C's, and
the one every GPU API is written in.

It is the largest breaking change in the language's history, and the
rest of this memo is mostly about the fact that **it does not have to
break anything**, for a reason that is worth stating before anything
else.

---

## The one thing the decision does not mean

A survey of the corpus against 32-bit arithmetic finds three things
that cannot survive it, and they are genuinely fatal:

- **`src/luce/std/math.luc:247`** — `rng[0] = rng[0] * 48271 %
  2147483647`, the Lehmer/MINSTD generator the whole of std's
  randomness rests on. The intermediate product reaches
  **103,661,183,076,066** — 48,271× past `i32`. Luce's arithmetic is
  checked, so this traps on the first call. It is not a migration; at
  32 bits it is a different generator.
- **`bench/arrays.luc:25`** prints **25,625,000,000**, twelve times
  outside `i32`, and `bench/arrays.luc:7-9` carries an exactness
  argument — *"every product is an exact multiple of 1/8, so the sum
  is exact"* — that holds to 2^53/8 ≈ 1.1e15 in binary64 and to
  2^24/8 ≈ 2.1e6 in binary32. The proof fails by four orders of
  magnitude before the number does.
- **`clock_ms`** is a monotonic millisecond reading
  (`src/apps/host.zig:432`). At `i32` it saturates after **24.85 days
  of uptime**. `programs/life.luc:95,103` reads it.

And a fourth that is quieter and worse: `src/luce/std/math.luc:17-22`
holds five constants carrying **20–21 significant digits**, deliberately
over-specified so each rounds to the nearest binary64, and
`math.luc:5-11` promises *"exp/ln hold ~1e-14 relative"*. Binary32's
epsilon is 1.19e-7. Eight tolerance assertions in
`src/luce/specs/std_spec.zig` become unsatisfiable, and the accuracy
table on `site/content/std/math.md:40-46` becomes fiction.

**Every one of those is a blocker only if the corpus is forced down to
32 bits. It is not. It is renamed.**

The types that mean i64 and binary64 do not disappear from the
language — they acquire the names `Long` and `Double`. So the
mechanically correct migration of every program written before today
is:

```
Int   →  Long
Float →  Double
```

which is a **textual rename that preserves every semantic exactly**.
The MINSTD generator keeps its 64-bit intermediate. `bench/arrays`
keeps its 25.6 billion and its exactness proof. `clock_ms` keeps its
range. `math.luc` keeps its twenty-one digits and its 1e-14 contract,
and `std_spec` is not touched. The C twins are not touched. The 194
fenced samples on the site keep their byte-compared output, including
the seven that print a computed Float. `docs/NUMERICS.md` is not
invalidated: apply the same two substitutions to it and every sentence
in it is still true, §6's 2^53 included.

This is the whole safety argument of the memo, and *Order* below is
built to cash it: the rename happens while `Int` and `Float` still
mean i64 and binary64, so it cannot change a program even in
principle; the resize happens afterwards, when the two names are used
by nothing.

The cost that this migration really carries is therefore not
correctness. It is that a corpus written in `Long` and `Double` leaves
the two shortest, friendliest names unused until somebody deliberately
opts down — and that is a legibility cost, paid in daylight, not a
behaviour cost paid on a large input in six months.

---

## Decisions to confirm

Six. D2 is the one that decides whether the migration is a rename or
an audit; the rest follow from the shape of the ladder.

> ### D2 — an unconstrained literal defaults to `Long` and `Double`, not to `Int` and `Double`.
>
> Java's answer is `int` and `double`; Go's is `int` and `float64`,
> and **Go's `int` is 64 bits wide on every platform Luce targets**,
> so the two most-cited precedents already disagree about the integer
> default by a factor of two billion while agreeing exactly about the
> float one. Nobody defaults a float literal to 32 bits — not Go, not
> Java, not C, not Python, not Swift.
>
> **Recommended: `Long` and `Double`.** Three reasons, in order of
> weight.
>
> **One — it decides whether the migration is a grep or an audit.**
> With `Long`/`Double` defaults, every *unannotated* numeric in the
> tree keeps its current meaning, and the migration is confined to
> the 127 `Int` and 92 `Float` occurrences that are written down. With
> `Int`/`Double` defaults, every integer expression in the tree has to
> be re-derived against a 2.1-billion ceiling — including
> `math.luc:247`, whose overflow would then trap **inside the standard
> library** — and the failures appear at run time, on large inputs, in
> shipped programs. Checked arithmetic makes them loud; it does not
> make them visible before they happen.
>
> **Two — a default must not lose information.** The two widest are
> the two that never surprise. A narrow type is a decision about
> memory and bandwidth, and a decision belongs where it is written
> down.
>
> **Three — it is decided once.** Changing a literal default later
> re-breaks every program written against it, so there is no version
> of this that can be deferred and revisited.

> **OVERRULED — ratified 2026-08-04.** The owner, verbatim: *"The
> default value for Int - is 32bit and for Float is 32bit. when you do
> var i = 7 or var j = 2.5."*  So `var i = 7` is `Int` (i32) and
> `var j = 2.5` is `Float` (binary32): **the short names are the
> defaults**, symmetrically — a rule Java itself does not have (its
> `2.5` is double while its `7` is int).  The recommendation above is
> kept as the record of the road not taken, and its costs are now
> owned deliberately rather than avoided:
>
> - **The migration becomes the audit, not the grep.**  Every
>   unannotated integer in the tree must be re-derived against the
>   2.1-billion ceiling and every unannotated float against binary32
>   precision.  The plan's rename step gains a sibling: annotate what
>   must stay wide (`let pi: Double = …` — std's constants back a
>   documented 1e-14 contract and are wrong at 32 bits;
>   `math.luc:247`'s generator intermediates; accumulators that grow).
> - **Checked arithmetic is the net.**  An unannotated accumulator
>   that outgrows i32 traps with a location — loud, not silent, which
>   is what makes this ruling survivable where it would be reckless in
>   C.
> - Literals still fit annotated contexts exactly (D3 stands):
>   `let n: Long = 7` and `let x: Double = 2.5` land at full width
>   with no double-rounding.
>
> **What it costs, stated plainly:** the two shortest names are not
> the defaults. That is Swift's known wart — `Double` is Swift's
> default and `Float` is the shorter name nobody should reach for —
> and Luce would be adopting it deliberately. The mitigation is that
> `Int` and `Float` will mean in Luce exactly what they mean in C,
> Java, C#, Rust's `i32`/`f32`, GLSL, CUDA and Metal, so no reader is
> ever surprised by *what the name is*; the only thing to learn is one
> sentence about what an unannotated literal is, and most code does
> not annotate at all.
>
> **Confirm:** `let n = 1` is a `Long`; `let x = 1.5` is a `Double`.

> ### D3 — literals stop having a type of their own.
>
> Today a literal is typed the moment it is read: `1` is an `Int` and
> `1.5` is a `Float`, materialised in stage 4 by
> `helpers.parseIntLiteral` (i64) and `helpers.parseFloatLiteral`
> (f64), `04_semantics/helpers.zig:159-179`. Seven types make that
> untenable: `let x: Float = 1.5` would be a type error, which is
> **exactly Java's most-complained-about literal wart** — Java really
> does refuse `float f = 1.5;` and demand `1.5f`.
>
> **Recommended: Go's untyped constants.** A numeric literal, and any
> constant expression over literals — which in Luce includes every
> file-scope `let`, already folded at `04_semantics/declarations.zig`
> — carries no type until it meets one. It then takes the type of its
> context if it fits, and reports `luce.sema.literal` naming the type
> and its range if it does not. With no context at all, it takes D2's
> default.
>
> This is not a large mechanism, and the tree has already paid most of
> its cost twice over. A token has **no payload** — `02_lex/token.zig`
> keeps only the span, and *"every literal's text is read back out of
> the source by whoever needs its value"* — so a literal reaches
> stage 4 as text and can be parsed **directly at the width it lands
> on**. `std.fmt.parseFloat(f32, text)` is the same one line as
> `parseFloat(f64, text)`. That matters more than it sounds: parsing
> decimal to binary64 and then rounding to binary32 is a double
> rounding, and the design that keeps literals as text never performs
> it. §1 has the detail.
>
> **Confirm:** untyped constants; no literal suffixes (§1).

> ### D4 — `Byte` is unsigned, and it is the only unsigned type there will be.
>
> **Ratified 2026-08-04.**  The owner, verbatim: *"Byte is unsigned -
> correct."*  And, in a follow-up that sharpens the ruling into a
> principle: *"Bytes are bytes, a fixed-size sequence of bits...
> Should an array of bits be signed or unsigned?  Neither, the
> question is nonsensical: an array cannot be signed or unsigned in
> the first place.  There's a long-standing tradition in programming
> languages to conflate integers and arrays of bits... I argue that
> this blending of the two roles is a mistake: a violation of the
> Single Responsibility Principle."*
>
> So the ruling, precisely: **`Byte` is a bits type, not a small
> integer.**  D5 already gave it no arithmetic; this says why.  The
> word "unsigned" describes only the widening boundary — reading the
> bits as a magnitude (`zext`, what `byte_at` has always done) is the
> one numeric reading that does not invent a sign bit — and nothing
> else about `Byte` is numeric at all.  Forward consequence, binding
> on the bitwise/hex roadmap item: **when bitwise operations arrive,
> they are defined on `Byte`, not on the integer family.**  Integers
> do arithmetic; bytes do bits.  Every mainstream precedent conflates
> the two; Luce separates them on purpose.
>
> Java's `byte` is signed −128..127 and is, by a distance, the most
> regretted decision in its numeric tower; `Byte.toUnsignedInt` was
> added in Java 8 to apologise for it. The owner's list is Java's
> list, so this is the one place the memo proposes to break with it,
> and the evidence is entirely local rather than a matter of taste:
>
> - **The compiled path already made the choice.** `byte_at` lowers to
>   a `zext` (`08_llvm/lower.zig:2820`), and `runtime/text.zig:70-75`
>   returns `Value.ofInt(text[index])` from a `[]const u8`. Both
>   engines produce 0..255 today.
> - **Three specs assert it.** `specs/behavior_spec.zig:901-902`
>   (`s.byte_at(1) == 240`), `:1674-1678` (`206`, `187`), `:3030`
>   (`240`). Under a signed `Byte` those become `−16`, `−50`, `−69`,
>   which nobody would write and nobody could check.
> - **Every UTF-8 test in the corpus is an ordered comparison against
>   128, 192 or 194** — `programs/editor.luc:53-54,151,157`,
>   `programs/wordcount.luc:14`. Signed bytes invert the ordering at
>   precisely the point that matters: `byte >= 128 and byte < 192`
>   becomes `byte < 0 and byte < -64`.
> - **Luce has no bitwise operators and no hex literals**, refused by
>   name at `03_parse/expressions.zig:233,237` and
>   `02_lex/lexer.zig:1348,1479`, and `docs/MISSING.md` item 11 keeps
>   them refused. The usual escape hatch from a signed byte is
>   `b & 0xFF`, and it does not exist and cannot be added without
>   reopening that item. **A signed `Byte` here would be a trap with
>   no lid.**
> - **`find_byte` already names the full byte range unsigned** —
>   `runtime/text.zig:82` bounds its argument `0..0xFF`, and
>   `byte_at → find_byte` (`std/strings.luc:27→31`) is the one
>   producer/consumer pair in the standard library.
>
> Java itself kept exactly one unsigned type — `char`, unsigned 16-bit
> — for exactly this reason, so "one unsigned type, where the domain
> is unanimous" is a line Java drew too and merely drew in the wrong
> place. **No other unsigned type, ever**, and the refusals are in the
> last section.
>
> **Confirm:** `Byte` is 0..255; `Short`, `Int` and `Long` are signed;
> there is no unsigned family.

> ### D5 — `Byte`, `Short` and `Half` are storage, and there are four arithmetic types.
>
> Java promotes `byte`, `short` and `char` to `int` before any
> arithmetic, and so does C. **Extend that one rung to the float
> ladder** and the design collapses from a seven-by-seven promotion
> lattice to four rules:
>
> - `Byte`, `Short` widen to `Int` for arithmetic and comparison.
> - `Half` widens to `Float`.
> - `Int` widens to `Long`; `Float` widens to `Double`. (Exact.)
> - An integer meeting a float — either way round — becomes `Double`.
>
> The payoff is not tidiness, it is three obligations that never
> arrive:
>
> 1. **No checked arithmetic at 8 or 16 bits.** `emitChecked`
>    (`08_llvm/lower.zig:3699-3717`) needs one new width, not five.
>    There is no question of what `Byte` 255 + 1 does, because no such
>    expression has type `Byte`.
> 2. **No binary16 arithmetic in the backend, on any target.** Only
>    `fptrunc`/`fpext`, which every target Luce reaches has (§7). This
>    removes the single largest portability hazard in the whole
>    proposal.
> 3. **No 7×7 conversion matrix.** §3 has ten constructors and one
>    rule.
>
> And it is honest about what the narrow types are *for*: the prize is
> `Array(Byte, n)` at one byte an element, not scalar `Byte`
> arithmetic. §10.
>
> A narrow type may still be declared — a parameter, a local, a struct
> field, an array element. It simply widens the moment an operator
> touches it, and narrowing back is spelled (§3).
>
> **Confirm:** four arithmetic types; three storage types.

> ### D6 — std's numeric tranche picks one element type, and it picks `Double`.
>
> `std/math.luc`'s vector functions take `Array(Float, _)`; after the
> rename they take `Array(Double, _)`. **A user who writes
> `Array(Float, _)` — the 32-bit array, the ML one, the whole point of
> the change — cannot call them**, because a container is not its
> element (`docs/NUMERICS.md`'s step-1 correction 3) and Luce has no
> generics.
>
> There is no clever answer available. The three real ones:
> keep one tranche at `Double`; move the tranche to `Float` and lose
> every accuracy claim and every recorded benchmark number; or write
> the tranche twice.
>
> **Recommended: one tranche, at `Double`, now.** It preserves
> `std_spec` unchanged, the accuracy contract, and the cross-checked
> benchmark outputs. A second `Array(Float, _)` tranche is written
> when the 32-bit path has a user asking for it — as new functions,
> not as a replacement.
>
> **This is the largest debt the decision creates and it should be
> recorded as one**, because it is also the strongest argument this
> tree will ever assemble for element-generic functions
> (`docs/MISSING.md` item 11's neighbourhood). Seven numeric types
> and no generics means every numeric library function is written once
> per element type or refuses six of them.
>
> **Confirm:** `Double` tranche now; the duplication is named, not
> discovered.

> ### D7 — the benchmarks migrate to `Double`, and the C twins are not touched.
>
> `bench/run.sh:70-78` string-compares the two programs' stdout and
> **refuses to time anything whose outputs disagree**, so the twins
> and the Luce sources move together or not at all. All six C twins
> are written in `long` and `double`; there is not one `int`,
> `float`, `int32_t` or `int64_t` among them.
>
> Converting them to `int`/`float` would change two published answers
> outright — `bench/stats`' sum goes 7,750,000 → 7,864,699 (1.48%
> error) and `bench/arrays`' dot product 25,625,000,000 →
> 25,625,464,832, which does not fit `Int` in any case — and it would
> reset the 0.77–1.06× history in `docs/CODEGEN.md`, which is the
> record of how the one code generator was made fast.
>
> **Recommended: the `.luc` sources become `Double`/`Long`, the C
> twins stay `double`/`long`, every number stays where it is.** The
> 32-bit path gets *new* rows — a `matmul32`/`arrays32` pair against
> `float`/`int` twins — added rather than substituted, so the
> comparison that exists is preserved and the comparison that is
> missing is acquired.
>
> **Confirm:** add rows, do not convert rows.

---

## The ladder, stated once

| name | bits | kind | range | role |
|---|---:|---|---|---|
| `Byte` | 8 | unsigned integer | 0 … 255 | storage |
| `Short` | 16 | signed integer | −32 768 … 32 767 | storage |
| `Int` | 32 | signed integer | ±2.147e9 | arithmetic |
| `Long` | 64 | signed integer | ±9.223e18 | arithmetic, **default** |
| `Half` | 16 | binary16 | ±65 504, ~3 digits | storage |
| `Float` | 32 | binary32 | ±3.4e38, ~7 digits | arithmetic |
| `Double` | 64 | binary64 | ±1.8e308, ~16 digits | arithmetic, **default** |

Seven names, exactly the seven the owner listed, at exactly the widths
he listed them at. Two of them are the language's defaults and are not
the two with the shortest names, which is D2's cost and D2's argument.

Five rules, and everything below is why:

1. **A literal has no type until it meets one**; unconstrained, it is
   a `Long` or a `Double`.
2. **`Byte`, `Short` and `Half` are storage**: an operator widens them
   to `Int` and `Float` before it does anything.
3. **Widening is implicit along a ladder, and across the ladders only
   into `Double`.**
4. **Narrowing is never implicit** and is spelled with the name of the
   type it produces: `Byte(x)`, `Short(x)`, `Int(x)`, `Half(x)`,
   `Float(x)`.
5. **Everything the language hands you unbidden is a `Long` or a
   `Double`** — `len`, `range`, `parse_int`, `clock_ms`, `ord`,
   `arg_count`. You ask for a narrow type; you are never given one.
   (`byte_at` is the single deliberate exception, §9.)

## 1. Literals: untyped constants, and no suffixes

Go's model, adopted for the reason Go adopted it: a language with more
than one integer width and no untyped constants makes its users write
casts around numbers they wrote correctly.

```luce
let x: Float = 1.5              # 1.5 is a binary32
let y: Half = 0.25              # a binary16
var count: Short = 1000         # fits; a Short
let n = 1                       # no context: a Long
let z = 1.5                     # no context: a Double
pixels[i] = 200                 # element is Byte; 200 fits
pixels[i] = 300                 # luce.sema.literal, at compile time
let h: Half = 1e5               # 100000 > 65504 — refused, at compile time
```

Three properties, and the third is the one that matters:

**Constants stay untyped through arithmetic.** `2 * 3`, `-4`, and every
file-scope `let` — which `04_semantics/declarations.zig` already folds
— remain untyped, so `let width = 4` composes into a `Byte` context and
a `Long` context alike.

**They are carried at i64 and f64, not at arbitrary precision.** Go
carries at least 256 bits of mantissa; Luce will not, and the reason is
that Luce cannot express a constant expression that needs it. There are
no shifts and no bitwise operators, so nothing in a constant expression
can exceed i64 or f64 and then land somewhere narrower. Folding
overflow stays `luce.sema.const`, *"constant arithmetic overflows"*,
exactly where it is now. This is a deliberate simplification, recorded
so nobody re-derives it as a bug.

**A literal is parsed at the width it lands on, from its text.**
This is the piece of luck the existing design earned.
`02_lex/token.zig` gives a token no payload — *"every literal's text is
read back out of the source by whoever needs its value (the parser for
strings, stage 4 for numbers)"* — so `helpers.parseFloatLiteral` grows
a width parameter and calls `std.fmt.parseFloat(f32, text)` directly.
Nothing ever converts decimal → binary64 → binary32, so the
double-rounding hazard that would otherwise sit under every `Float`
literal in the language **never exists**. `helpers.parseIntLiteral`
gains the same parameter, which is also where the sign-folding it
already does (so that `-9223372036854775808` is writable) becomes
per-type.

**No suffixes.** `1L`, `1.0f`, `1u` stay what they are today: a
`luce.lex.number`, *"malformed numeric literal: a number cannot be
followed by letters"* (`02_lex/lexer.zig:762-772`). Untyped constants
plus an annotation cover every case a suffix would — a binding takes
`let x: Float = 1.5`, an argument takes the parameter's type, a list
literal takes the annotation pushed into it by the `wanted_element`
hop `docs/NUMERICS.md` step 1 already built, and an expression position
takes `Float(1.5)`. Adding suffixes would mean editing `number()`
before its `isWordStart` guard and teaching `numberProblem` which tails
are legal, and it would put a second spelling beside an annotation that
already reads better. The slot is recorded here in case the decision is
ever revisited; it is not being spent.

**Stage 2 does not move.** No new literal forms, no hex, no
separators, no suffixes: all five `luce.lex.number` messages
(`lexer.zig:750,767,781,824,843`) survive verbatim, including *"a
number has one decimal point"*. The lexer is marked *Locked* in
`docs/PIPELINE.md` and stays locked, which is a real result for a
change of this size.

## 2. The promotion lattice

Four arithmetic types, and therefore four rules rather than a
seven-by-seven table.

| from | to | when | exact? |
|---|---|---|---|
| `Byte`, `Short` | `Int` | any operator, any comparison | yes |
| `Half` | `Float` | any operator, any comparison | yes |
| `Byte`, `Short`, `Int` | `Long` | the other operand is a `Long` | yes |
| `Half`, `Float` | `Double` | the other operand is a `Double` | yes |
| any integer | `Double` | the other operand is any float | **exact below 2^53** |

The last row is the whole of the cross-family rule and it is one
sentence: **across the ladders, the answer is `Double`.**

That is not Java's rule. Java widens `long → float`, losing everything
above 2^24 from a 64-bit source, and `int → float`, losing everything
above 16.7 million — a boundary ordinary programs cross. Luce sends
both to `Double` instead, where `Byte`, `Short` and `Int` are
represented **exactly** and only `Long` is lossy, above 2^53. That is
precisely the position `docs/NUMERICS.md` §6 ratified and accepted with
its eyes open, unchanged and no worse. **Adopting the owner's sizes
does not widen the language's one lossy implicit conversion; it leaves
it where it was.**

Narrowing is implicit in no direction and no context: not `Long` into
`Int`, not `Double` into `Float`, not `Int` into `Byte`, not at a
store, not at an argument, not at a return. `docs/NUMERICS.md`'s answer
to float contagion — *"nothing needs to warn, because Luce has no
implicit narrowing"* — is what makes seven types safe rather than
seven times as dangerous, and it is the rule this memo leans on
hardest.

**`/` still answers a float.** It widens integer operands to `Double`
and then the ordinary rule applies: `Int / Int` is a `Double` (which is
what it is today, under the rename), `Float / Float` is a `Float`,
`Float / Int` is a `Double`. The last is the one to read twice — a
32-bit float divided by an integer answers 64 bits — and it is right:
the programmer mixed a ladder, and the safe common type is the wide
one. Writing `x / Float(n)` says otherwise in six characters.

**`//` and `%` answer the promoted integer type**, `Int` or `Long`, and
floor together exactly as `docs/NUMERICS.md` §3 ratified. `Byte // Byte`
is an `Int`, because `Byte` is storage.

**Where promotion is inserted** is unchanged in shape: `fit`
(`04_semantics/builder.zig:1288-1313`) grows from two arms to a lattice
lookup, and the five sites `docs/NUMERICS.md` step 1 found that do
*not* call `fit` — binary operands, compound assignment through a
nested place, `xs[i] = v`, `methodTakes`, and `min`/`max`/`clamp` —
each still need their own line. That correction is inherited whole;
this memo does not get to rediscover it.

## 3. Conversions: ten constructors, one rule

`Byte(x)`, `Short(x)`, `Int(x)`, `Long(x)`, `Half(x)`, `Float(x)`,
`Double(x)`, plus `String(x)` and the two parses. Each is named for the
type it produces, which is the family `docs/NUMERICS.md` §7 established
and this simply completes.

- **Float to integer rounds half away from zero** and traps
  `conversion_range` outside the target's range — the rule ratified in
  `docs/NUMERICS.md` §7 and shipped in its step 4, now with a
  per-target bound instead of i64's. The range check stays *after* the
  rounding, which is that step's correction and is still the reason
  one check does the work of two.
- **Integer to narrower integer traps `conversion_range`** outside the
  target. `Byte(300)` traps; `Byte(200)` does not.
- **Float to narrower float rounds to nearest, ties to even**, and does
  not trap: `Float(1e300)` is `inf`, because that is what IEEE says and
  `/` is already IEEE without traps (`docs/NUMERICS.md` §4). `Half` and
  `Float` acquire infinities far more easily than `Double` does, and
  the language should not acquire a second story about infinity to
  cushion it.
- **Widening constructors never trap** and are redundant with
  promotion, but stay, for the reason `Float(x)` stayed: they are how
  you widen without an operator to hang it on.
- **`String(x)` accepts all seven**, and prints each with the
  shortest representation that round-trips *at its own width* — so
  `String(Float(1.0) / Float(3.0))` is `"0.33333334"`, nine digits, not
  binary64's seventeen. `runtime/text.zig:117-126` already uses Zig's
  `{d}`, which is Ryū-derived and width-generic; this is a type
  parameter, not new code.

**One structural consequence, and it is a simplification.** Three sites
hard-code the constructor names by string comparison —
`04_semantics/builder.zig:3833-3853`, `:1022-1024`, and
`04_semantics/declarations.zig:1071-1081`. Ten constructors means all
three become one table, which they should have been at three.

**`ConvertKind` is deleted.** `06_mir/defs.zig:20` is
`enum { int_to_float, float_to_int }` — two members, and the single
tightest squeeze in the tree, because seven types is up to forty-two
pairs. It does not need to grow: a `convert` instruction already knows
its source (the operand's type) and its destination (its own result
type), so the kind is redundant information the verifier can and should
derive. `convert: Register`, and `06_mir/verify.zig` decides whether
the pair is a legal conversion. The instruction set gets *smaller*.

## 4. Overflow, and what traps at which width

Checked arithmetic exists at two widths, `Int` and `Long`, because D5
says nothing else does arithmetic.

`emitChecked` (`08_llvm/lower.zig:3699-3717`) currently passes `.i64`
as a literal overload argument to `sadd`/`ssub`/`smul.with.overflow`;
it takes the width as a parameter instead, and its three callers in
`emitIntArithmetic` plus negate's caller at `:3847-3853` pass it.
`checkDivisor` (`:3721-3732`) likewise hard-codes `.i64` and
`std.math.minInt(i64)`, and gains the same parameter — the
`minInt // -1` overflow is real at both widths.
`runtime/operators.zig:27-131` is the mirror and is the same shape.

**`Int` overflow at ±2^31 is a new trap that ordinary code can reach**,
and it should be said out loud rather than left to be discovered: an
`i32` counter multiplied by itself overflows at 46,341. This is exactly
why D2 defaults literals to `Long` — unannotated arithmetic never meets
this boundary, and code that writes `: Int` has asked for it.
`integer_overflow` gains no new spelling and no new trap code; the
message *"integer overflow"* (`support/vocabulary.zig:130,152`) is
already width-agnostic.

**Narrow types have no overflow semantics at all**, because they have
no arithmetic. A `Byte` at 255 does not wrap and does not trap; there
is no `Byte + Byte`. What can fail is a *store*: `pixels[i] = Byte(v)`
traps `conversion_range` if `v` is outside 0..255, and that is a
conversion trap, not an arithmetic one. One mechanism, already
ratified, doing the job of two.

## 5. Exactness across the ladders, per pair

`docs/NUMERICS.md` §5 established that a mixed comparison compares the
numbers rather than a conversion of them, and paid for it with one
intrinsic, `compare_int_float(op, i, f) -> Bool`, implemented once in
`libluce_rt` (`runtime/exports.zig:950-956`).

After D5's promotions, the only mixed comparisons that can reach a
lowering are `{Int, Long} × {Float, Double}` — four pairs:

| integer | float | naive widening exact below | needs the intrinsic? |
|---|---|---|---|
| `Int` (i32) | `Double` | **always** | **no** |
| `Int` (i32) | `Float` | 2^24 | yes |
| `Long` (i64) | `Double` | 2^53 | yes |
| `Long` (i64) | `Float` | 2^24 | yes |

**And the existing intrinsic covers all four, unchanged.** Widening an
`Int` to `i64` and a `Float` to `f64` are both lossless by
construction, so a mixed comparison widens both operands into the pair
the intrinsic already speaks and calls it. **No new intrinsic, no new
export, no new runtime code** — the freshly-landed §5 work generalises
to seven types for free, for the same reason the cross-family
promotion rule targets `Double`. `BinaryOp.mirrored`, step 1's
correction 5, keeps deciding which side the integer sits on.

The first row is a small gift: `Int` against `Double` is *exactly*
representable, so the lowering may emit `sitofp i32 to double` and an
ordinary `fcmp` and skip the call. That is an optimisation the two-type
language could not have, because it had no integer narrower than the
mantissa.

**The 2^53 statements in the tree do not become wrong; they become
one row of two.** The ~20 places that name 2^53 — `docs/NUMERICS.md`
§2/§5/§6, `docs/LANGUAGE.md:676`, `runtime/operators.zig:274-275`,
`specs/behavior_spec.zig:564-573,632-634`,
`site/content/ref/types.md:41`, `site/content/tour/values.md:63,71` —
are statements about `Long` and `Double` and stay true verbatim once
renamed. What is *added* is the 2^24 row for `Int` and `Float`, and it
deserves its own spec program beside the existing one, because 16.7
million is a number programs actually reach.

## 6. Representation: where each width lives

### The boxed `Value` does not change size

`runtime/value.zig:117-137` is a 24-byte `extern struct` — one tag
byte, `inline_length`, a six-byte `inline_head`, `bits: u64`,
`length: u64` — sized by the 22-byte small-string optimisation and
asserted by the layout test at `:328-341`. A 32-bit `Int` lives in
`bits` exactly as a 64-bit one does. **`sizeOf(Value)` stays 24 and the
ABI's entry-block `alloca` stays 24.** There is no scalar saving here
and the memo should not pretend there is one.

There is, however, ample room. `Tag` is `enum(u8)` with **7 of 256
values used** (`value.zig:50-64`), and every scalar leaves
`inline_length` and `inline_head` and `length` untouched — **15 spare
bytes in every scalar `Value`**.

**How the tags renumber, and why nothing moves.** `Tag.int = 2` means
i64 today and `Tag.float = 3` means binary64. Those two numbers keep
their meanings and change only their spellings — to `long` and
`double` — and the five new widths are **appended** at 7, 8, 9, 10, 11:
`int`(i32), `float`(f32), `byte`, `short`, `half`. No existing tag
number ever means something new, which is the append-only rule the
whole ABI is built on, honoured exactly.

### `Array` already has the machinery, and it is the prize

`runtime/heap.zig:181-192` states the design: *"The elements are stored
as themselves, not as `Value`s. An `Array(Float)` is `f64`s, an
`Array(Int)` is `i64`s, an `Array(Bool)` is bytes."* The stride table is
`ElementKind` at `heap.zig:260-305` — four arms, `value`/`float`/`int`/
`boolean`, with `Cell()` and `width()` — and allocation is a single
multiply at `heap.zig:855-859`, always at `Value` alignment, so any
narrower cell is trivially satisfied. **A one-byte element already
works today**: `Array(Bool, n)` is `u8` cells.

So the 8× memory win needs `ElementKind` to grow from four arms to
nine, and the parallel switches to grow with it: `Array.at`/`put`/`fill`
(`heap.zig:218-248`), `cellBefore` (`runtime/containers.zig:289-303`),
and on the compiled side `cellType` (`08_llvm/lower.zig:2376-2384`),
`cellAlignment` (`:2387-2398`), `loadCell` (`:2641-2663`) and
`storeCell` (`:2665-2694`). The stride is implicit in the LLVM `gep`'s
element type, so there is no byte arithmetic to get wrong.

**The one sharp edge, and how the tag renumbering removes it.**
`ElementKind.of(zero: Value)` derives the cell width from the *zero
element's tag* (`heap.zig:296-304`), because `luce_rt_new_array`
(`runtime/exports.zig:485-495`) is handed only dimensions and a zero —
the runtime deliberately does not know the program's type table. A
`Byte` whose zero boxed as `Tag.long` would silently allocate 8-byte
cells. Giving each width its own tag, as above, makes `of` keep working
verbatim — and that is why the widths belong in the tag rather than in
a widened `new_array` signature, which would have bumped `abi.version`
for no other reason.

`types.HeapType` (`support/types.zig:116-136`) carries the element
*type* and never a size, so `Array(Byte, n)` is
`.{ .array = .{ .element = .byte, .rank = 1 } }` and **the heap-type
table needs no change at all**.

### `List` and `Map` stay boxed, and this is said rather than hidden

`heap.zig:171-177`: a `List(T)` is a `std.ArrayList(Value)` and a
`Map(K,V)` an `ArrayList(MapEntry)` — 24 and 48 bytes per element,
with no per-element-type specialisation anywhere. **`List(Byte)` is 24
bytes an element after this memo, exactly as it is before it.** A
packed `List` is a genuinely new mechanism — growable, boxed API,
element-kind dispatch on every `append` and `pop` — and it is not in
this design.

That is the right place to stop, because `Array` is the numpy-shaped
type, `std/math.luc`'s vector tranche already takes `Array(Float, _)`,
and `08_llvm/loops.zig:224-235`'s `writesPlainElement` — the
vectorisation gate — already admits exactly the unboxed kinds. Narrow
elements belong in that gate, and once they are in it, **the same NEON
register holds four `Float`s where it held two `Double`s, and eight
`Half`s.** That is the concrete performance argument for the resize,
and it lands in `Array` or nowhere.

### The struct field run

`04_semantics/helpers.zig:31`'s `max_struct_values = 4096` counts
*values*, and `valueCount` (`declarations.zig:450-456`) gives every
non-struct exactly 1 — so a narrow field falls into the `else` arm and
the cap is untouched. Whether a struct's field run packs narrow fields
is a separate question from this memo; the honest default is that it
does, by the same `cellType` reasoning, and `08_llvm/lower.zig:679-712`'s
`zeroField` is where it would show.

## 7. `Half`, and what each target can actually do

D5 means binary16 arithmetic is never emitted. What is emitted is
`fpext half to float` and `fptrunc float to half`, and once
(`Half(x)` from a `Double`) `fptrunc double to half`.

| target | half↔float conversion | half arithmetic |
|---|---|---|
| AArch64 (ARMv8.0-A and later) | `FCVT`, mandatory in the base architecture | ARMv8.2 `FEAT_FP16` only |
| Apple Silicon (M-series) | `FCVT` | native (`FEAT_FP16`) |
| x86-64 with F16C (Ivy Bridge, 2012+) | `vcvtph2ps` / `vcvtps2ph` | AVX512-FP16 only |
| x86-64 baseline | `__extendhfsf2` / `__truncdfhf2`, compiler-rt | — |

So **conversion is one instruction on every machine Luce is built on
today**, and the softfloat fallback matters only for a baseline x86-64
build. `libluce_rt` is Zig and Zig ships its own `compiler_rt`, so those
routines should already be in the one static library every artifact
links — that is the *expectation*, and it is a thing step 4 must
verify on a baseline-x86-64 build rather than assume, because an
undefined `__truncdfhf2` at link time is exactly the class of failure
`docs/CODEGEN.md` built the artifact tag to avoid.

`std.zig.llvm.Builder`'s `Type` already has `.half`, `.bfloat` and
`.float` beside the integer widths, so **no backend type plumbing is
missing.**

**`fptrunc double to half` is a single correctly-rounded operation** in
LLVM IR, and AArch64 has `fcvt h, d` directly, so there is no
double-rounding through binary32. That is the same class of claim
`docs/NUMERICS.md` §2 measured rather than asserted, and it should get
the same treatment: a spec that sweeps the boundary cases and pins the
answer on both engines.

## 8. The wire, the ABI, and what does not move

| surface | now | after | why |
|---|---|---|---|
| `06_mir` `format_version` | 19 | **20** | new `types.Type` arms |
| the module fingerprint hash | pinned | moves | `Instruction` field names change with `ConvertKind`'s removal |
| `abi.version` | 9 | **9** | nothing in `LuceHost` changes |
| `artifact.format` | 2 | 2 | layout unchanged |
| `artifact.generator` | — | moves at every step | any edit under `08_llvm/` or `runtime/` |
| `sizeOf(Value)` | 24 | 24 | scalars share `bits` |
| `Value.Tag` | 7 used | 12 used | appended, 7…11 |
| `max_struct_values` | 4096 | 4096 | `valueCount` counts values |

Two of those need a sentence each.

**The format bump is manual and must not be forgotten.** The
fingerprint test at `06_mir/module.zig:903-921` hashes the field names
of `Instruction`, `Intrinsic`, `TrapCode` and `ErrorCode` — **it does
not hash the `Type` tag list**, and the file says so at `:915-918`
using the `key_read` precedent. Adding scalar arms to `types.Type`
moves no hash. The wire encodes a type as a bare `u8` tag
(`module.zig:106-113` and `:342-357`), so an inserted arm silently
re-tags every existing module: **append only, and bump 19 → 20 by
hand.** The decoder's switch has no `else` arm, which is the one thing
that will not let a new type through unnoticed.

**The host ABI does not move, and this is not luck.** All 33 numeric
positions in `08_llvm/abi.zig` are already `i64` — every string length,
`clock_ms`, `sleep_ms`, `arg_count`, `arg`, `term_rows`/`cols`/`move`/
`style`, `call_depth`, `leaked` — and D2's `Long` default means the
Luce-visible results of those services are `Long`s that need no
conversion at the boundary at all. Had the default been `Int`, every
one of them would have acquired a narrowing at the call: a new class of
overflow site created purely by a naming decision. That is the third
argument for D2 and it is the one that would only have shown up in the
implementation.

`abi.version` therefore stays 9, exactly as `docs/NUMERICS.md` §10
predicted for itself and was right about seven steps running.

## 9. What the language hands you, and the one exception

Rule 5 of the ladder — *everything unbidden is a `Long` or a `Double`*
— resolves the whole surface at once and needs no per-function
argument:

| builtin | answers | why it must |
|---|---|---|
| `len(x)` | `Long` | Java's `int`-length arrays are its second-most-cited numeric regret; and Luce's strings already travel as `{ptr, i64}` |
| `range(a, b)` bounds | `Long` | a loop bound is a length |
| `parse_int(s)` | `Long?` | at `Int` every input in (2^31, 2^63] would flip from a value to `none` — **silently**, because `parse_int` answers `T?` and does not trap |
| `parse_float(s)` | `Double?` | at `Float` the overflow-to-`none` threshold drops from 1.8e308 to 3.4e38 (`runtime/text.zig:154` rejects non-finite) |
| `clock_ms()` | `Long` | 24.85 days |
| `ord(s)` | `Long` | a codepoint would fit an `Int`, but the rule is worth more than the four bytes |
| `arg_count`, `term_rows`, `term_cols`, `dim(axis)` | `Long` | already `i64` across the ABI |
| `abs`, `min`, `max`, `clamp` | their operands' unified type | they unify like a binary operator (`docs/NUMERICS.md` step 1, correction 2) |
| `sqrt`, `floor`, `ceil`, `trunc` | their operand's float type | `llvm.sqrt.f32` exists; `sqrt` of a `Float` answering a `Double` would be a narrowing waiting to happen |

**The exception: `byte_at` answers a `Byte`.** It is the only function
in the language whose result is definitionally a byte, both engines
already produce 0..255 (D4), and it is the natural producer for the
one place an `Array(Byte, _)` gets filled from.

It costs nothing at the call sites, and this was checked rather than
assumed. All 30 `byte_at` calls in the `.luc` corpus are comparisons
against a decimal literal or a range — and under untyped constants the
literal takes `Byte` and the comparison holds. The two that are not:
`std/strings.luc:104`'s `byte + shift` promotes to `Int` by D5 and
still feeds `append_ascii`; `std/strings.luc:27→31` hands a byte to
`find_byte`, whose domain is already `0..0xFF`. Parameters annotated
`Int` (`editor.luc:53`, `wordcount.luc:7-14`) receive a widened `Byte`.
`String(s.byte_at(0))` still prints `104`. **Not one line of the corpus
changes.**

Two things `Byte` does *not* absorb, and both should be planned around
rather than discovered:

- **`append_ascii` is 0..0x7F, not 0..0xFF** (`runtime/containers.zig:152-159`),
  because a `Builder` must yield valid UTF-8. A `Byte` argument would
  still need its run-time check. The docs already misdescribe it as
  taking *"a byte"* (`docs/STD.md:116`, `site/content/guide/strings.md:94`);
  a real `Byte` type makes that gap more visible, not less.
- **`chr` and `ord` stay codepoint functions** over 0..0x10FFFF, so
  `chr(255)` is two bytes and not one. `programs/bf.luc:44`'s
  `chr(tape[pointer])` for a cell ≥ 128 is a latent bug that a
  `Byte`-typed tape would surface rather than fix.

## 10. What this is for

`Half` and `Array(Byte, n)` are not general-purpose conveniences and
should not be justified as if they were. They are the on-ramp to the
kind of computation `docs/STD.md:69` already calls *"the numpy-shaped
tranche"*: dense arrays of narrow numbers, moved in bulk, where the
element width *is* the performance.

The two facts that shape which corners of this memo matter:

- The LLVM this tree builds against — 22.1.8 on the reference machine
  — has **NVPTX, AMDGPU and SPIRV** among its built targets, beside
  AArch64 and X86. The back end that would emit for a GPU is already
  linked into `luce`. That is a direction, not a plan, and nothing in
  this memo commits to it; it is worth recording only because it means
  the expensive part of that road is not the part this decision is
  paying for.
- Every one of those targets is designed around f16, f32 and i8. A
  language whose only float is binary64 is not on that road at all.

So: **`Array`-of-narrow performance is the corner that matters** — the
`ElementKind` widths, `cellType`/`loadCell`/`storeCell`, and
`08_llvm/loops.zig`'s vectorisation gate. **Scalar `Byte` arithmetic is
the corner that does not**, which is exactly why D5 can afford to
delete it.

## 11. The migration, sized honestly

**1,866 lines across the whole tree mention `Int` or `Float`.** That is
the headline number and it is the wrong one to plan against, because
under *Order* they are not judgment calls — they are two substitutions
applied while both names still mean what they mean today.

| where | `Int`/`Float` lines | what happens |
|---|---:|---|
| `.luc` corpus — 19 files (10 `programs/`, 6 `bench/`, 3 `std/`) | 94 / 63 | rename; **no program changes meaning** |
| `site/content/**` — 42 files | 269 | rename; the 194 fenced samples re-verify byte-for-byte |
| `docs/**` | 363 (132 in `NUMERICS.md`) | rename; every claim stays true |
| `src/**/*.zig` — Luce inside specs | 775 `func main` programs | rename; the oracle re-runs both engines |
| `bench/*.c` twins | 0 | **not touched** (D7) |

**The `.luc` corpus, file by file.** Every file below keeps its exact
current behaviour by moving to `Long`/`Double`; the "could be 32-bit"
column is the *later* opt-down, a separate reviewable commit each, and
nothing in *Order* depends on any of it happening.

| file | needs 64-bit | could be 32-bit later |
|---|---|---|
| `std/math.luc` | **yes** — MINSTD at `:247` (intermediate 1.03e14); `ipow` specs assert 2^62 and 1e18; the five constants at `:17-22` carry 20–21 digits and the module promises 1e-14 | no; this is the file that most needs `Double` |
| `std/strings.luc` | **yes** — `format_float`'s `magnitude > 1.0e15` guard at `:192` and `Int(trunc(magnitude))` at `:202`; it is also the desugaring target of f-string `{x:.2f}` | no |
| `std/files.luc` | no `Int` or `Float` at all | — |
| `bench/arrays.luc` | **yes** — prints 25,625,000,000; the 1/8-exactness argument at `:7-9` needs binary64 | a `float` twin as a **new** row |
| `bench/stats.luc` | sums to 7,750,000 (fits) but the f64 sum is *exact* and an f32 sum is 7,864,699 | a **new** row |
| `bench/matmul.luc` | checksum 225,000,000 fits | the best candidate for a new 32-bit row |
| `bench/loops.luc` | total 462,794,501 fits | yes |
| `bench/math.luc`, `bench/strings.luc` | no range dependency | yes |
| `programs/dice.luc` | via `math.random` | — |
| `programs/life.luc` | `clock_ms` at `:95,103` | grid indices could be `Int` |
| `programs/bf.luc` | no — tape is `% 256` | **`Array(Byte, cells)`** is what `:29` wants |
| `programs/editor.luc` (61 `Int`) | no | rows/columns/offsets are `Int`; theme fields are 0..255 **with `-1` as a sentinel** (`:13-43,229`), so they are *not* `Byte`s |
| `programs/wordcount.luc`, `sort.luc`, `calc.luc`, `stats.luc` | no | yes |

**The site.** 194 fenced Luce blocks, all compiled and run by the
freshly built toolchain, with `site/src/verify.zig:229-249` requiring an
`output` block on every runnable fence and `:311` comparing it with
`std.mem.eql`. 114 `run`, 32 `fail`, 23 `trap`, plus the `include`,
`args`, `raise` and `module` variants. **Under the rename every one of
them keeps its recorded output**, including the seven that print a
computed Float (`ref/builtins.md:49`'s `1.4142135623730951`,
`std/strings.md:168` and `examples/text.md:156`'s
`0.3333333333333333`, `examples/programs.md:34,36`,
`tour/functions.md:92`, `std/strings.md:146`) and the three whose
*source* is outside `i32` (`tour/values.md:87`'s deliberate overflow
trap at 2^63−1, `:71`'s `9007199254740993 == 9007199254740992.0`,
`examples/traps.md:39`'s 2^62).

What the site does need is **new** prose: `ref/types.md`,
`tour/values.md`, `ref/lexical.md` and `ref/failure.md` currently
promise two numeric types and 64 bits, and after the resize they
describe a ladder, a default, and a literal that has no type until it
lands. That is writing, not editing, and it is the honest bulk of the
site work — six load-bearing lines to correct and one new reference
page to write.

**`docs/NUMERICS.md` is migrated, not superseded.** Apply the same two
substitutions and all 132 of its `Int`/`Float` lines stay true: §2's
`sitofp`+`fdiv` divergence table still begins at 2^53 for `Long`, §3's
negative-operand table is width-independent, §5's exactness argument
still holds and §6's silence above 2^53 still describes `Long` into
`Double`. What it gains is a pointer to this memo for the six rows the
ladder adds. A ratified record that survives a change this size by
find-and-replace is evidence the change was made the right way round.

**What is genuinely not mechanisable.** `src/**/*.zig` holds 485 `i64`
and 73 `f64` mentions, and most are not the language's `Int` at all —
they are the `{ptr, i64}` String representation and host-ABI lengths
that must stay 64-bit regardless. `08_llvm/lower.zig` alone has 143
`i64` mentions and **exactly two** of them are the language-type seam
(`:318-319`, `.int => .i64, .float => .double`). This is triage, one
file at a time, and it is where the implementation's real hours go.

The good news beside it: the six conversion builtins — `parse_int`,
`parse_float`, `String(x)`, `chr`, `ord`, `byte_at` — all live in
**one file**, `runtime/text.zig`, because `libluce_rt` is the one
implementation both engines call. Six edits, one place, both arms.

And the compiler will find the rest. The house style forbids `else`
arms on type switches (`08_llvm/lower.zig:4622-4624` says so), so
adding arms to `types.Type` and `types.Type.Payload` makes the Zig
compiler enumerate every one of roughly 55–65 switch sites — about 35
of them in `lower.zig` — rather than letting any of them fail
silently. `06_mir/module.zig`'s decoder switch is closed the same way.
Six enum or union definitions change (`types.Type`,
`types.Type.Payload`, `runtime.Tag`, `heap.ElementKind`,
`context.ConstantValue`, `lower.Numeric`) and the compiler walks the
tree from there.

**Diagnostics.** Two message constants name the current widths outright
and must become per-type — `04_semantics/context.zig:44-45`,
*"integer literal out of range; Int holds -9223372036854775808 to
9223372036854775807"*, and `:46-47`, *"float literal is not a finite
number; Float holds up to about 1.8e308"*. Both should name the
**wider type that would hold it**, which is the single most valuable
new message this memo creates: *"3000000000 does not fit an Int
(−2147483648 to 2147483647); write it as a Long"*.

`context.zig:61`'s tail — *"and there is no conversion between them"* —
is already flagged in the tree as depending on `Int → Float` being the
only widening. With a ladder it is false for `Byte` against `Int`, and
correcting it is an improvement rather than a repair: the message can
say *"a Byte widens to an Int; write `Byte(x)` to go the other way."*
Beyond those, about a dozen messages say `Int` where they mean *an
integer* — `"array indices are Int"`, `"lists index with one Int"`,
`"range bounds must be Int"`, `"slice bounds are Int"`,
`"min/max take two Ints or two Floats"`, `"clamp takes three Ints or
three Floats"`, `"Int() converts Float"` — and each becomes a sentence
about a family rather than a type.

## Order

Seven steps. Each leaves the tree green and shippable, and the sequence
exists so that **the resize changes the behaviour of no program in the
tree** — the same trick `docs/NUMERICS.md` used to make true division
boring, applied to a much larger change.

**This work is sequenced after `docs/METHODS.md` and
`docs/RETURNS.md`**, both of which are designed and unbuilt. Both edit
`04_semantics/builder.zig` and `08_llvm/lower.zig` heavily — `self`
changes call-site lowering, `-> (T, T)` changes the return path — and a
tree-wide type rename landing between them would collide in every file
either touches. `RETURNS.md`'s destructuring `let low, high = f()`
needs `fit` applied per position, and that is better built against a
settled `fit` than a moving one.

1. **Untyped constants.** D3, alone and additive: literals carry text
   and materialise at the width they land on, constant expressions fold
   at i64/f64, and the defaults are `Int` and `Float` as they are
   today. **No program changes meaning** — every literal still lands on
   the type it lands on now. This is the enabling step, and it must be
   first, because after step 3 `let x: Float = 1.5` compiles only under
   it.
2. **`Long` and `Double` arrive**, as second names for the types
   `Int` and `Float` currently denote. Two spellings for one type each,
   which is precisely what `docs/NUMERICS.md` step 5 spent a commit
   *removing* when it retired `str` — so this is a debt taken on
   deliberately with its repayment scheduled for step 3, and the memo
   owns that rather than pretending otherwise. Additive; nothing
   changes.
3. **The rename.** Every `Int` → `Long` and every `Float` → `Double`,
   tree-wide and mechanically: 19 `.luc` files, 194 site samples, the
   specs, `docs/`, `CLAUDE.md`. Provably meaning-preserving, because
   the names are aliases at this point. Benchmarks byte-identical, C
   twins untouched, `std_spec` unchanged, the site's byte-compare green.
   **This step must end with a test asserting that `Int` and `Float`
   appear in zero `.luc` files, zero fenced site samples and zero
   spec programs** — a grep that fails the build. That test is what
   makes step 4 safe, and it is the only mechanism that can be, because
   a missed `Array(Float, ...)` is the one migration failure that
   **type-checks**: it would silently become a 32-bit array and change
   results with no diagnostic anywhere.
4. **The resize.** `Int` becomes i32, `Float` becomes binary32.
   Because step 3 emptied both names, **this changes the behaviour of
   no program in the tree.** `types.Type` and `Payload` gain arms,
   `ConvertKind` is deleted, `emitChecked` and `checkDivisor` take a
   width, `Value.Tag` renumbers by appending, the promotion lattice
   and the four-pair exactness rule land, and the diagnostics become
   per-type. `format_version` → 20. The largest commit in the plan and
   the least dangerous one, on purpose.
5. **`Byte`, `Short`, `Half`.** `ElementKind` grows to nine arms;
   `cellType`/`cellAlignment`/`loadCell`/`storeCell`/`cellBefore` grow
   with it; `byte_at` answers `Byte` and `find_byte` takes one;
   `Array(Byte, n)` is one byte an element and enters
   `08_llvm/loops.zig`'s vectorisation gate. Verify the binary16
   softfloat routines on a baseline x86-64 build (§7) before calling
   this done.
6. **Opt down, deliberately.** One reviewable commit per program:
   `programs/bf.luc`'s tape becomes `Array(Byte, cells)`,
   `editor.luc`'s offsets become `Int`, and `bench/` gains **new**
   32-bit rows against new `float`/`int` C twins rather than converting
   the ones that exist (D7). Nothing here is required for the language
   to be finished; all of it is required for the language to be worth
   the change.
7. **The documents.** `docs/LANGUAGE.md`'s values and arithmetic
   sections, `docs/STD.md`, `docs/PIPELINE.md`, `CLAUDE.md`'s *"one
   implicit conversion and one only"* sentence, a new site reference
   page for the ladder, `docs/NUMERICS.md`'s pointer here, and this
   memo's *As built*.

Steps 1 and 2 are independent. 3 must follow 2, 4 must follow 3, and 6
must follow 5. **Step 3 is the one that cannot be done by halves**: a
partial rename is the only state in this plan from which step 4 does
damage.

## Refused, with reasons

**An unsigned family.** `Byte` and nothing else. C's signed/unsigned
comparison rule is a decades-old bug generator, Java refused unsigned
outright, and Zig and Rust both carry the complexity honestly and still
pay for it. Seven types is a lot; fourteen is a different language. The
one place unsignedness is unanimous across every domain — a byte is
0..255 in files, sockets, images and UTF-8 alike — gets a type, and
nowhere else does.

**Java's signed `byte`.** D4. Five pieces of local evidence, no
opinions.

**Java's `long → float` and `int → float` implicit widenings.** They
lose everything above 2^24 from sources that reach it routinely.
Luce's cross-family rule targets `Double` instead, so the only lossy
implicit conversion in the language remains the one
`docs/NUMERICS.md` §6 already ratified.

**Implicit narrowing, in any direction.** Not `Long` into `Int`, not
`Double` into `Float`, not at a store or an argument or a return. It
is the rule that makes seven types safe rather than seven times as
dangerous.

**Literal suffixes** (`1L`, `1.0f`). Untyped constants and an
annotation cover every case, and the lexer's existing refusal is a
better message than a second spelling would be. §1 records where the
slot is.

**Arbitrary-precision constants** (Go's ≥256-bit mantissa). Luce has
no shifts and no bitwise operators, so no constant expression can
exceed i64 or f64 and then land somewhere narrower. i64/f64 folding
with a range check on landing is the whole of what the language can
observe.

**`Int` and `Double` defaults** (Java's, and the one that makes the
short names the default ones). It converts the migration from a grep
over 219 written annotations into a value-range audit of every integer
expression in the tree, whose failures appear at run time on large
inputs — starting with `math.luc:247` trapping inside the standard
library. D2.

**A packed `List(T)`.** `List` is `ArrayList(Value)` and stays so.
Packing it is a real new mechanism, `Array` is the numpy-shaped type
the narrow widths are for, and doing both at once would hide which one
paid.

**`bfloat16`.** The obvious next rung — MLX and every current
accelerator have it, LLVM's `Builder.Type` already carries `.bfloat`,
and it is the one format `Half` does *not* substitute for, because it
trades mantissa for `Float`'s exponent range. Deliberately not now: it
is additive under this design (one `ElementKind` arm, one `Type` arm,
one constructor) and it should arrive when something in the tree wants
it rather than because the enum looked incomplete.

**A platform-width `Size` type.** Every length in Luce is a `Long` and
every artifact is 64-bit; a second spelling for the same width would
buy portability the language does not currently need and cost a
concept every reader has to hold.

**Hex literals, digit separators and bitwise operators.**
`docs/MISSING.md` item 11 keeps them refused and this memo does not
reopen it. Worth recording only that `Byte` and `% 256` between them
*lower* the pressure rather than raising it — `docs/NUMERICS.md` §3
already made `x & 255` expressible as `x % 256`, and an
`Array(Byte, n)` is the other half of what people wanted masks for.

**A `Number` supertype, or numeric generics.** There is no subtyping in
Luce beyond `T <: T?`. D6 names the cost of refusing it — one library
tranche per element type — and that cost is real and should be revisited
when it bites, as a language decision of its own and not as a rider on
this one.
