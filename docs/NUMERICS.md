# Numbers that mix

> **The rule.** `Int` converts to `Float` implicitly, in one direction,
> wherever a `Float` is required — and nowhere does a `Float` become an
> `Int` without being asked. `/` is real division and always answers
> `Float`; `//` and `%` are the integer pair and they floor together.
> Comparison across the line is **exact**, because an answer that is
> merely close is a wrong answer. Everything that narrows is spelled
> with the name of the type it produces: `Int(x)`, `Float(x)`,
> `String(x)`.

`docs/MEMORY.md` records why scope ownership won; `docs/FAILURE.md` why
there are three failure mechanisms and not one. This is the memo for
the rule those two never had to touch, and it is the first one that
**overturns a ratified decision** rather than filling a hole.

This is `docs/MISSING.md`'s **"The order to work down"** item 10, in
part — *"decide … integer division spelling — one memo each"* — and it
swallows item 9 whole.  (It said "Tier 5 item 10"; that list is in no
Tier, and `docs/METHODS.md` said "Tier 4" for the same line.  Both are
corrected.)

## What the owner decided

> *"I always want (int + float) to be float. int / int = float. int \*
> float = float. we should also allow things like Int(float value) to
> become int by rounding and so on for all values. String(Int value)
> should also work. String(float value).format("%f.2") might be a good
> idea as well."*

That overturns **no implicit conversions**, which is enforced at
`04_semantics/builder.zig:3401`, spelled in a diagnostic at
`04_semantics/context.zig:72`, and asserted as a property of the
language in sixteen places on the site and four in `docs/`. The owner
may overturn his own language's rules; the memo's job is to make sure
he is overturning the one he means to, and not four others by
accident.

Below, **every consequence that a reasonable person might not have
intended is a numbered decision point**, stated before the design that
assumes it.

---

## Decisions to confirm

Six. The first two are the ones that cost real work; the rest are
cheap once these are settled.

> ### D1 — True division alone buys nothing. Promotion is what pays.
>
> The corpus was surveyed exhaustively. **Every single `Int / Int` in
> shipping code wants floor or truncating semantics — seven in `.luc`,
> four in site samples, twenty-five more in test programs. Not one
> wants a real quotient.** Median midpoints (`mathx.luc:18,20`), grid
> centres (`life.luc:20,30`), exponent halving (`math.luc:111`), an Int
> calculator (`calc.luc:65`).
>
> That is not evidence the feature is unwanted — it is survivorship.
> The four places that *do* want a real quotient already write
> `sum(xs) / Float(len(xs))` (`math.luc:157`, `math.luc:197`,
> `mathx.luc:7`, `dice.luc:36`), because the no-mixing rule left them
> no choice.
>
> The consequence: **`Int / Int → Float` shipped by itself makes every
> existing division wrong and makes no existing average shorter.**
> `total / Float(len(values))` only becomes `total / len(values)` once
> mixed arithmetic promotes. The two halves of the owner's sentence are
> not two features; they are one feature, and shipping the division
> half first would be all of the cost and none of the benefit.
>
> **Confirm:** promotion and true division ship as one ruleset, in the
> order in *Order* below.

> ### D2 — `%` changes sign behaviour on negative operands, or `//` and `/` disagree about the same numbers.
>
> Today `%` is C's: the remainder takes the sign of the **dividend**
> (`runtime/operators.zig:58`, `@rem`). If `//` floors — Python's
> answer — and `%` keeps taking the dividend's sign, then
> `b * (a // b) + (a % b) != a` for negative operands, and the division
> identity that has held in every language since FORTRAN breaks inside
> Luce.
>
> So `//` and `%` must pair, and there are exactly two coherent
> pairings. **Recommended: floor.** The table and the argument are in
> §3; the short version is that once `/` means real division, `//`
> ought to mean *the floor of `/`*, and under the C pairing it does not.
>
> **This changes existing programs.** Three corpus sites are literally
> hand-written workarounds for C's sign rule and get shorter; no
> corpus site gets longer or wrong. But `%` is a rule people carry in
> their heads from other languages, and Luce would be joining the
> minority (Python) against the majority (C, Go, Rust, Java, JS).
>
> **Confirm:** floor pairing, with `%` changing meaning on negatives.

> ### D3 — `1 / 0` stops trapping.
>
> `Int / Int` answering `Float` means division by zero answers `inf`,
> not `divide_by_zero`. The trap does not survive in `/` unless `/`
> becomes the one Float operation in the language that is not IEEE.
>
> **Recommended:** let it go, and keep the trap where it belongs — on
> `//` and `%`, the operators that still produce an `Int`. The blast
> radius is smaller than it looks, because **every corpus site that
> relied on the trap is a site that migrates to `//` anyway**, and it
> keeps the trap there. What it costs is real but bounded: ten specs
> use `a / b` as *the* canonical trapping instruction
> (`behavior_spec.zig:2977,3000`, `08_llvm/test.zig:432,555,580`,
> `apps/luce/object.zig:353,402`, `optimize_spec.zig:182`), and
> `07_optimize/test.zig:579` exists *because* division is `stable` and
> not `pure`. Each swaps `/` for `//` and keeps proving what it proved.
>
> Also: `0 / 0` becomes a second way to write NaN, beside `0.0 / 0.0`.
>
> **Confirm:** `/` never traps; `//` and `%` keep `divide_by_zero`.

> ### D4 — `Int(x)` rounding removes the only spelling of truncation.
>
> `Int(x)` truncates today (`runtime/operators.zig:224`, `@trunc`).
> The owner wants it to round. Then `floor`, `ceil` and round all have
> spellings and **truncation-toward-zero has none** — for negative
> numbers `Int(floor(x))` is not it.
>
> **Recommended:** add `trunc(x: Float) -> Float` beside the existing
> `floor` and `ceil` builtins, in the same commit. One intrinsic,
> three lines, and it completes a set that would otherwise have a hole
> punched in it by this change.
>
> **Confirm:** `Int(x)` rounds half away from zero (§7), and `trunc`
> is added.

> ### D5 — If `String(x)` arrives, does `String(x)` leave?
>
> `Int(x)` and `Float(x)` are conversion constructors named for the
> type they produce. `String(x)` completes that family. But `String(x)`
> already does the job and is called 34 times across 14 `.luc` files,
> plus the site and the specs.
>
> **Recommended:** add `String(x)` and **retire `String(x)`**. The rename
> is mechanical, it is the only outcome in which the language gets
> *smaller* rather than larger, and it fixes a complaint already
> written into this codebase — `04_semantics/context.zig:61` records
> that a bad diagnostic *"sends the reader looking for a `String(...)`
> that does not exist."* After this change it does exist.
>
> The counter-argument is real: `str` is Python-shaped, and the free
> builtins are deliberately Python-shaped. Keeping both is the only
> option that changes no existing program, at the price of two
> spellings for one act, forever.
>
> **Confirm:** retire `str`, or keep both and accept the duplication.

> ### D6 — Formatting: the owner's literal spelling cannot be built.
>
> `String(float value).format("%f.2")` — by the time `String(...)` has
> run, the Float is gone and only its text remains; `.format` would be
> re-parsing a number it just printed. (And `"%f.2"` is itself
> backwards: printf spells it `"%.2f"` — which is the argument against
> the mini-language, made by its own proposal.)
>
> **Recommended:** f-string format specs, `f"{x:.2f}"`, lowering to the
> `strings.format_float` that already exists and is already tested.
> Formatting belongs where formatting happens. §8 has the full case
> and the two refusals.
>
> **Confirm:** f-string specs, one spec form only.

---

## The rule, stated once

1. **`Int` widens to `Float` wherever a `Float` is required.** Binary
   operands, `let` annotations, arguments, returns, container
   elements, struct fields, compound assignment. One direction. Never
   the reverse, never without being asked.
2. **`/` always answers `Float`** and follows IEEE 754 without traps.
3. **`//` and `%` are the integer pair**, answer `Int` for `Int`
   operands, floor together, and trap `divide_by_zero`.
4. **Comparison across the line is exact.**
5. **Narrowing is a constructor named for its target**: `Int(x)`
   rounds and traps out of range, `Float(x)` widens, `String(x)`
   prints.

Five sentences. Everything below is why, and what it costs.

## 1. Promotion: one direction, everywhere

Luce can afford implicit widening for a reason most languages cannot,
and it is worth naming because it is the whole safety argument:
**there is no overloading.** The catastrophe of implicit conversions
in C++ is not the conversion, it is the conversion *interacting with
overload resolution* to pick a function nobody meant. Luce has one
function per name, no subtyping beyond `T <: T?`, no generics past
monomorphic containers, and no truthiness. A widening here can change
what a value *is*; it can never change what code *runs*.

The insertion point already exists and is one function —
`04_semantics/builder.zig:1274`, `fit`, which today performs the sole
coercion in the compiler (`T` into `T?`):

```zig
fn fit(self: *FunctionBuilder, value: Typed, expected: Type) Error!?Typed {
    if (value.value_type.eql(expected)) return value;
    const payload = expected.held() orelse return null;
    …
```

Promotion is a second arm on that function, and every site that
already calls `fit` — annotation, argument, return, element, field —
gets promotion for free and consistently. That is the argument for
doing it **everywhere rather than only in binary operators**: an
operator-only rule leaves `let f: Float = 1` a compile error, which
reads as arbitrary the first time anyone meets it, and there is no
principled line between the two cases. Half a rule here is worse than
either whole.

Two boundaries the uniform rule does *not* cross:

- **Promotion needs an expected type.** `let xs = [1, 2, 3]` is still
  `List(Int)`; `let xs: List(Float) = [1, 2, 3]` is `List(Float)`.
  Inference where nothing is expected is untouched.
- **Promotion does not reach through `T?`.** `Int? + Float` keeps
  today's message, which already says the useful thing (*"test it
  first (`if n != none:`) or supply a fallback"*,
  `site/content/tour/absence.md:134`). `let x: Float? = 1` may compose
  the two steps — widen, then wrap — because refusing that is the
  arbitrary carve-out again.

**Cost at run time: usually zero.** An `Int` *literal* meeting a
`Float` folds at compile time — `x * 2` with `x: Float` becomes
`x * 2.0` in the constant folder and emits nothing. Only a promoted
*variable* costs a `sitofp`, which is one instruction and free on
every machine Luce targets. This is worth stating because it means
the Go-style "untyped constants only" design — the restrained
alternative — is a strict subset of what is proposed here and arrives
free with it.

## 2. `/` is true division

Python's PEP 238 is the exact precedent, down to the second operator.
Its rationale is ours: the classic `1/2 == 0` is *"the single most
common cause of surprise"* for people who do not already think in
machine words, and a language whose model is Python inherits both the
expectation and the fix.

`/` therefore promotes both operands to `Float` and answers `Float`,
for every combination of `Int` and `Float` operands. There is no
`Int` division left in the IR: `Binary { op = .divide, operand_type =
.float }` is the only shape stage 4 emits for `/`.

**Correct rounding, and the honest limit.** Python's `int.__truediv__`
computes the correctly-rounded double of the exact rational. Luce
will not: it will emit `sitofp` on both operands and one `fdiv`, which
double-rounds. Measured, on random operand pairs:

| operand width | naive `sitofp`+`fdiv` differs from correctly-rounded |
|---|---|
| 52-bit | 0.0% |
| 53-bit | 0.0% |
| 54-bit | 21.9% |
| 62-bit | 33.8% |

The divergence begins **exactly at 2^53** and never occurs below it,
which is the whole finding: for every operand pair a program is
plausibly going to divide, one `fdiv` *is* the correctly-rounded
answer. Buying the rest costs a `libluce_rt` call on the hottest
operator in the language to fix a case no program meets. Refused, and
recorded here so nobody has to re-derive it.

## 3. `//` and `%`: the negative-operand table

This is the design. Two coherent pairings, and they differ only on
negatives.

| `a` | `b` | `a // b` (floor) | `a % b` (floor-mod) | `a // b` (trunc) | `a % b` (rem, **today**) |
|---:|---:|---:|---:|---:|---:|
|  7 |  3 |  2 |  1 |  2 |  1 |
| −7 |  3 | **−3** | **2** | −2 | −1 |
|  7 | −3 | **−3** | **−2** | −2 |  1 |
| −7 | −3 |  2 | −1 |  2 | −1 |

Both satisfy `b * (a // b) + (a % b) == a`. What separates them:

- Under **floor**, `%` takes the sign of the **divisor**, so a
  positive divisor always yields a non-negative result.
- Under **trunc**, `%` takes the sign of the **dividend** — today's
  behaviour, and C's, Go's, Rust's, Java's and JavaScript's.

**Recommended: floor.** Four reasons, in order of weight.

**One — it is a consequence of the owner's own decision, not a
preference.** Once `/` is real division, `//` should be its floor; the
name of the thing is *floor division*. Under the trunc pairing
`a // b != floor(a / b)` for negative operands, so the two division
operators would tell different stories about the same two numbers.
That is the kind of seam that produces bug reports for a decade.

**Two — three corpus sites are already hand-written workarounds for
the C rule, and this deletes all three.** This is not a hypothetical:

```luce
# src/luce/std/math.luc:96 — sign-safe parity, today
if (Int(y) % 2 + 2) % 2 == 1:
# under floor-mod
if Int(y) % 2 == 1:

# src/luce/std/math.luc:230-233 — folding a seed into range, today
var folded = from % 2147483646
if folded < 0:
    folded += 2147483646
return [folded + 1]
# under floor-mod
return [from % 2147483646 + 1]

# programs/bf.luc:42 — a byte decrement, today
tape[pointer] = (tape[pointer] + 255) % 256
# under floor-mod, the spelling the author meant
tape[pointer] = (tape[pointer] - 1) % 256
```

`docs/MISSING.md` item 9 already named two of these by file and line
as evidence something was missing. It was right; this is the thing.

**Three — wrapping and torus indexing is what `%` is actually used
for here.** Of nineteen `%` sites in `.luc`, the ones that carry
weight are byte wrapping (`bf.luc:40,42`) and toroidal neighbour
lookup (`life.luc:42,43` — `(row + dr - 1 + height) % height`, where
the `+ height` is a fourth workaround for the same rule). Floor-mod is
the operation those sites want; C's remainder is the operation they
correct for.

**Four — it is not slower, and by a constant divisor it is faster.**
Floor-mod by a positive power of two is exactly a bitwise AND —
`x mod 256 == x & 255` for every `x`, positive or negative, verified
over the range — whereas C's `srem` needs a sign fixup. `bf.luc`'s
inner loop gets *cheaper*. For a general divisor, floor-mod is `srem`
plus a two-instruction correction, in the operator that is already the
most expensive one on the chip.

**What it costs.** `%` changes answers for negative operands, in a
language where it currently matches C. Every corpus site was checked:
none changes answer (all have non-negative operands, or are one of the
three workarounds above, which change for the better). The exposure is
to programs not yet written, by people carrying C's rule.

### Float `%` changes too

Today Float `%` is `@rem`/`frem` — C's `fmod`, sign of the dividend
(`runtime/operators.zig:72`, `08_llvm/lower.zig:3575-3579`). It must
become floor-mod with the integer operator, or promotion introduces a
discontinuity: `-7 % 3` would answer `2` and `-7 % 3.0` would answer
`-1.0`, with an invisible widening choosing between them. Python makes
the same choice for the same reason.

This imports one known wart, and it should be recorded rather than
discovered: floor-mod on floats can return the divisor.
`-1e-100 % 1.0` is `1.0` exactly, because the true answer is a hair
under 1.0 and rounds up; `fmod` has no such case. Python has lived
with it since 2.0. It is the price of the two operators agreeing, and
agreeing is worth more.

### Spelling

`//` and `//=`. The lexer has the token free — comments are `#`
(`02_lex/lexer.zig:446`) — but it is not *unclaimed*: `'/'` currently
dispatches to `foreignComment` (`02_lex/lexer.zig:578-611`), which
reports `luce.lex.comment`, *"a comment starts with '#'; there is no
'//' form"*, and swallows the line. So `let q = a // b` today is one
diagnostic, not two slashes.

Taking `//` therefore **spends** that message, and it is a good
message aimed at exactly the newcomer this change is otherwise
courting. It is still the right trade: the message serves people
writing a comment wrong once, and the operator serves people doing
integer arithmetic forever. `/* */` keeps its arm and its diagnostic.

The alternatives are worse. A builtin `div(a, b)` puts the language's
second-most-common arithmetic operator in prefix position and cannot
have a compound form. `Int(a / b)` is not integer division at all —
it is a real division rounded, which is a different function and, once
D4 lands, rounds rather than truncates. `\` is Visual Basic's and is
already the escape character.

## 4. Division by zero

Stated as D3 above; here is the shape it leaves.

| expression | today | proposed |
|---|---|---|
| `1 / 0` | trap `divide_by_zero` | `inf` |
| `1 / 0.0` | *refused* | `inf` |
| `1.0 / 0.0` | `inf` | `inf` |
| `0 / 0` | trap `divide_by_zero` | `NaN` |
| `1 // 0` | — | trap `divide_by_zero` |
| `1 % 0` | trap `divide_by_zero` | trap `divide_by_zero` |
| `minInt // -1` | trap `integer_overflow` | trap `integer_overflow` |
| `minInt / -1` | trap `integer_overflow` | `-9.223372036854776e18` |

The rule underneath is `docs/FAILURE.md`'s, applied without
flinching: the operators that produce an `Int` keep integer semantics,
including the trap, and the operator that produces a `Float` is IEEE
like every other Float operation. `/` becomes `pure` in
`07_optimize/effects.zig` where it is `stable` today, which is a real
optimizer improvement and simultaneously the thing that dissolves
`07_optimize/test.zig:579`'s premise.

Python's stricter answer — `1.0 / 0.0` raises too — was considered and
refused. It would make `/` the one Float operation in Luce that is not
IEEE, and `math.luc` documents `exp` as overflowing to infinity
already (`std/math.luc:30`): the language has a working relationship
with infinity and should not acquire a second story about it.

## 5. Across the line: `==` and `<`

`1 < 1.5` and `1 == 1.0` are both compile errors today —
`04_semantics/builder.zig:3401` refuses type inequality before it ever
looks at the operator, so ordering and equality are refused by the
same line as arithmetic. Promotion admits all of them.

**They must be exact.** The naive lowering — widen the `Int`, then
`fcmp` — is wrong, and wrong in the one place where wrong is not
merely imprecise:

```
9007199254740993 == 9007199254740992.0
```

is `false` mathematically, and `true` under naive widening, because
the left operand does not survive `sitofp`. Approximation in `+` is
expected and understood; an `==` that answers `true` for two different
numbers is a defect. And the two cannot be split: if `==` is exact
while `<` widens, then `a == b` and `not (a < b) and not (b < a)` give
different answers for the same pair, which is worse than either.

**Both precedents already went this way, independently.** Python's
`float_richcompare` performs an exact mathematical comparison rather
than a conversion — `2**53 + 1 == float(2**53)` is `False`, and
`10**30 < 1e30` is `True` even though `int(1e30)` is
`1000000000000000019884624838656`. TC39 reached the same place from
the other side: JavaScript's BigInt permits `1n < 1.5` — exactly — and
**refuses** `1n + 1.5` with a `TypeError` telling you to convert. It
is worth registering that the committee that had to solve this most
recently kept exact comparison and threw out mixed arithmetic, which
is the opposite split from the one being adopted here. Adopting mixed
arithmetic is the owner's call; adopting it *and* inexact comparison
would be taking the loss twice.

**The cost, honestly.** This is the one part of the design that is not
free and is not an existing mechanism reused. `Binary` carries a
single `operand_type` (`06_mir/defs.zig:187`) and cannot express a
mixed comparison, so exactness needs **one new intrinsic** —
`compare_int_float(op, i, f) -> Bool` — implemented once in
`libluce_rt` (a dozen lines: reject NaN, bound against ±2^63, split
the Float at its integral part, compare the integer parts, then the
fraction), exported, lowered as a call, and agreed on by the oracle.
A call rather than inline code, because mixed comparison is rare by
construction and `libluce_rt` is where semantics live; if it ever
shows on a profile it can be inlined then.

There is one inconsistency this leaves, and it is Python's too, so it
is liveable but should be written down: `a == b` is exact while
`a + 0.0 == b` is not, because the addition really did widen. The
language is exact where it compares and approximate where it computes,
which is the correct place for each.

## 6. 2^53

`Float(int)` is silent above 2^53 today (`runtime/operators.zig:210`,
a bare `@floatFromInt`, classified `.pure`), and stays silent. The
change is that it is now reachable *without being written* — every
promotion is a `Float(...)` the programmer did not spell.

Considered and refused: refusing `Int` literals above 2^53 in a Float
position. It refuses correct programs (`1e18` as a nanosecond count
divided by `1e9` is exact and useful), it cannot see variables at all
so it catches the harmless case and misses the real one, and it makes
the rule un-statable in one sentence.

Rust is the honest counter-precedent and deserves the credit: it
declines to implement `From<i64> for f64` *precisely* because the
conversion is lossy, while providing `From<i32> for f64` which is not.
That is a language drawing exactly the line this memo erases. It can
afford to: `as` is three characters and Rust's audience budgets for
them. Luce is Python-shaped and its owner has decided otherwise, which
is a legitimate decision about who the language is for — but the
mitigation is the type system, not a check, and that is §9.

## 7. Conversions: `Int`, `Float`, `String`

Three constructors, each named for the type it produces, each taking
one argument.

### `Int(x)` rounds half away from zero

Today it truncates (`runtime/operators.zig:214-225`). Proposed: round.
Which rounding matters, and there are three candidates:

- **half away from zero** — C's `round`/`lround`. `Int(2.5) == 3`,
  `Int(-2.5) == -3`.
- **half to even** — IEEE's default and Python's `round()`.
  `round(2.5) == 2`, `round(0.5) == 0` in Python, which surprises
  everyone once.
- **half up** — `floor(x + 0.5)`. Asymmetric about zero.

**Recommended: half away from zero**, for one reason that outranks the
numerical arguments: `math.round` already exists, is already
documented as *"Round half away from zero: round(2.5) == 3.0,
round(-2.5) == -3.0"* (`std/math.luc:24`), and is already what
`strings.format_float` uses. A language with two roundings that
disagree has a bug in it, and the one already ratified wins.

Note in passing that `std/math.luc:35` writes `Int(floor(x / ln2 +
0.5))` — a hand-rolled *half-up*, which is a third behaviour again.
After this change it becomes `Int(x / ln2)`, and is correct for the
first time on negative inputs.

**The traps stay.** NaN, ±inf and out-of-i64-range keep answering
`conversion_range`. This is `docs/FAILURE.md`'s rule with no argument
on either side, and the guard is duplicated in three places that must
move together — `runtime/operators.zig:216-222`,
`04_semantics/declarations.zig:1129-1136`, and
`08_llvm/lower.zig:3449-3489`, the last of which carries the comment
that decides it: *"a conversion that disagrees at the boundary is a
different language."*

**`math.round` stays**, because `Float -> Float` rounding is a
different act from narrowing — `round(x * 100.0) / 100.0` needs it.
`Int(round(x))` simply becomes redundant with `Int(x)`.

**`trunc(x: Float) -> Float` is added** (D4), beside `floor` and
`ceil`, so that the four roundings all have spellings after `Int`
takes one of them.

### `Float(x)` is unchanged

Widens, never traps, silent above 2^53 (§6). It becomes largely
redundant — every corpus use of it is at a promotion site — but stays,
because it is how you widen without an operator to hang it on, and
because deleting it would make `Int` and `String` an odd pair.

### `String(x)` joins them

`String(Int)`, `String(Float)`, `String(Bool)` — the same scalars
`str` covers, minus `Builder` and the `String`-to-`String` identity.
It resolves the same way `Int` and `Float` do: name-matched in
`lowerCall` before name resolution (`04_semantics/builder.zig:3687`),
lowering to the existing `str_value` intrinsic, so this is stage-4
work and **no new MIR, no new runtime, no new ABI**.

`Builder` is the reason `str` cannot be renamed by search-and-replace:
`String(builder)` takes a heap object, and a scalar constructor should
not. Under D5's recommendation `Builder` gets `b.build()` as the
method it should always have had and `String(...)` stays scalar-only.

## 8. Formatting

The owner hedged this one — *"might be a good idea"* — and it is the
sub-item where the recommendation diverges most from the literal
proposal.

**`String(x).format("%f.2")` cannot be built as written**, for a
reason that is not pedantry: `String(x)` has already produced text, so
`.format` would be handed `"3.14159"` and a spec, with the Float gone.
The only implementable reading is that `String(...)` returns something
that is not yet a String — a formatter object — and Luce has no such
thing and should not acquire one for this.

**The printf mini-language is refused.** It is a second language
inside string literals, with its own grammar, its own errors, and its
own undefined behaviour, and it exists to serve *varargs* — which Luce
does not have and does not want (no first-class functions, no variadic
calls). A `format` taking exactly one value has no use for `%`
placeholders at all. The proposal's own example is the argument:
`"%f.2"` is not a printf spec; `"%.2f"` is. If the spelling is
mis-remembered in the sentence that proposes it, the failure mode is
not hypothetical. `docs/MISSING.md:557` already records `"value %d" %
a` being answered as a type error, and answering it as a feature is
the larger version of the same mistake.

**Recommended: format specs inside f-strings**, and nowhere else.

```luce
print(f"mean = {mean:.2f}")        # "mean = 23.99"
print(f"{count} rolls, {rate:.3f}/s")
```

Because that is where formatting happens. Every numeric formatting
site in the corpus and on the site is inside an f-string or a `print`,
and the one that is not — `dice.luc:36`, `strings.format_float(...)`
assigned to a name and then interpolated — is the shape this replaces.

Scope, deliberately minimal: **`:.Nf` on a `Float`, and nothing
else.** No width, no fill, no alignment, no `%`, no `e`, no thousands
separator. It lowers to `strings.format_float(value, N)`, which
already exists, is already tested, and is already documented as
rounding half away from zero — so this adds **one grammar production
in the f-string scanner and no runtime whatsoever**.

One sub-decision worth flagging: the `f` in `:.2f` is redundant, since
the compiler knows the operand is a `Float`. It should be **required
anyway**, because `{x:.2}` means *two significant digits* in Python
and *two decimal places* here would be a silent divergence from the
language Luce is shaped after. One redundant character buys exactness
of the precedent.

Refused alongside: a `String.format` method (String keeps only
primitives; everything else routes to `std.strings`, and this would
be the exception that reopens that rule); and `%` as a formatting
operator (it is an arithmetic operator, and Python has spent fifteen
years deprecating that pun).

## 9. Diagnostics: what dies, what is born, what is not needed

**Dies.** The conversion advice loses its whole reason to exist for
`Int`/`Float`, which is what it was written for:

- `04_semantics/context.zig:72` — *"; conversions are explicit, so
  write Int(...) or Float(...) to make them one type"* — deleted.
- `04_semantics/context.zig:64`, `convertsBetween` — deleted; the
  only pair it knows about now converts implicitly.
- `04_semantics/builder.zig:1637` — the `let`-annotation twin,
  *"conversions are explicit, so write Float(...)"* — deleted.
- `04_semantics/builder.zig:4499,4511` — *"Int() converts Float, not
  X"* / *"Float() converts Int, not X"* — rewritten, since both
  constructors now accept both numeric types (`Int(Int)` stays
  identity) and `String()` joins them.

`context.zig:74` — *", and there is no conversion between them"* —
**survives and gets better**, because after this change it is true
without qualification: the pairs that reach it (`Int` and `String`,
`Int?` and `Int`) really have no conversion. The commit that split
those two arms, *"A conversion is offered only where one exists, and
operands say which"*, was right; this change simply moves one pair
from the first arm to no arm at all.

**Born.** Nothing, and that is the interesting part. Every mistake
promotion makes newly possible is caught by a message that already
exists, because the type system refuses the continuation:

```luce
let mid = (lo + hi) / 2      # Float now
grid[mid]                    # index is Float — refused, existing message
func f(n: Int)
f(a / b)                     # argument is Float — refused, existing message
var n: Int = 10
n /= 2                       # place is Int, value is Float — refused,
                             # builder.zig:1882, existing message
```

This is the answer to *"what warns about accidental float
contagion?"*: **nothing needs to, because Luce has no implicit
narrowing.** The C pitfall — `int i = total / count` quietly
truncating — cannot be written here, and Python's version — a `float`
propagating to a runtime `TypeError` three functions away — cannot
either. Contagion stops at the first place an `Int` is required, at
compile time, with a message already in the tree. Luce has no
warnings by design, and this design needs none.

The one mistake that stays silent is precision: `let big: Float = n`
above 2^53. That is §6, it is accepted, and the type system genuinely
cannot see it.

**`n /= 2` deserves its own line**, because it is the migration's
sharpest edge: it is a compile error after this change, at every site
where `n` is an `Int`. There is exactly one in `.luc`
(`std/math.luc:111`, `left /= 2` in `ipow`, which wants `//=`) and two
in parser tests. That it is an *error* rather than a silent truncation
is the whole safety story in one line.

## 10. What it costs: MIR, wire, engines, oracle

**Stage 4 does nearly all of it.** Promotion is `convert` instructions
— `ConvertKind.int_to_float`, which already exists
(`06_mir/defs.zig:20`) — inserted at `fit`. `String(x)` is the
existing `str_value` intrinsic reached by a new name. `/` is the
existing `divide` with `operand_type = .float`. **No new instruction
is needed for any of that.**

**Three things are genuinely new:**

1. `BinaryOp.floor_divide` (`support/vocabulary.zig:25-44`) — `//`.
2. `Intrinsic.compare_int_float` — exact mixed comparison (§5).
3. `Intrinsic.trunc` — the builtin D4 requires.

**One rename, for honesty.** `BinaryOp.remainder` should become
`.modulo`, because after §3 it computes a modulus and not a
remainder, and those differ exactly on the negatives this memo spent a
table on. The wire format bumps anyway, so the rename is free.

**Wire.** `06_mir/module.zig:37` is `format_version = 18` (CLAUDE.md
says 17 and is stale). Adding a `BinaryOp`, adding intrinsics, and
changing what `remainder` means each independently require a bump;
one bump to **19** covers all of them. No migration — modules
recompile from source.

**ABI.** `abi.version` does **not** move. Nothing here touches the
`LuceHost` vtable; every new semantic is a `libluce_rt` call or an
inline sequence, which is exactly the split `docs/CODEGEN.md` draws.
The `generator` identity moves on its own, as it does for any backend
change, and stale artifacts are refused by name as usual.

**Runtime (`libluce_rt`).** `operators.zig:46-59` swaps `@divTrunc`
for `@divFloor` under the new `floor_divide` op and `@rem` for `@mod`
in both the Int and Float arms; `operators.zig:214-225` gains the
rounding; one new exported comparison; one new `trunc`. All of it in
the one implementation both arms call, which is the point of the
library.

**LLVM.** `sdiv`→`sdiv` plus floor correction (or LLVM's own
canonicalisation), `srem`→ the floor-mod sequence, `frem`→ floor-mod,
`fptosi` gains a rounding step, one new call. `08_llvm/lower.zig`'s
`checkDivisor` moves from `/` to `//` and `%` unchanged in substance.
`emitFloatArithmetic`'s doc comment at `:3575-3579`, which currently
pins `%` to `fmod` by name, is rewritten.

**Oracle.** `specs/agree.zig` runs every program on both arms and
compares prints, trap code, message, call trace, leak census and the
world left behind. The negative-operand table of §3 and the exactness
table of §5 should each become a program in `specs/`, so the two
engines are held to the table and not to each other's accidents. This
is the cheapest high-value test in the plan and it should be written
before the lowering, not after.

## 11. The corpus, honestly sized

Ninety-two integer-operator sites, plus conversions. The distribution
is much kinder than the headline suggests, and one fact does most of
the work: **fifty-six of the ninety-two are `%`, and not one of them
changes answer** (all have non-negative operands, or are one of the
three workarounds §3 improves).

| where | Int `/` | Int `%` | what happens |
|---|---:|---:|---|
| `*.luc` (19 files) | 7 | 19 | all seven `/` → `//`; `%` untouched, three sites get shorter |
| `bench/*.c` twins | 0 | 7 | **nothing changes** — see below |
| Luce inside `*.zig` specs | 25 | 24 | `/` → `//`, except where the spec *is* the old rule |
| site fences + docs | 4 | 6 | four `/` → `//`; two samples need real thought |

**The C twins do not move, and this is the single largest piece of
good news in the plan.** `bench/*.c` contains **no integer `/` at
all** — only seven integer `%`, all with non-negative operands
(`(i * 7) % 100`, `(i * 13) % 16`, `(i * j) % 7`), where floor-mod and
C's remainder are the same number. The cross-check in `bench/run.sh`
compares printed output; that output is unchanged. **No benchmark pair
needs its algorithm revisited**, and the feared lockstep migration is
seven sites verified by inspection.

**Site samples.** 194 fenced Luce blocks, of which 111 are `run` with
byte-compared output and 31 are `fail` with byte-compared diagnostics.
Two `run` samples need more than a mechanical edit:

- `site/content/examples/traps.md:52` — `func ratio(a: Int, b: Int)
  -> Int: return a / b`, whose recorded output *is* a
  `divide_by_zero` trace. Under D3 there is no trap and the return
  type is wrong. It becomes `//` and keeps proving exactly what it
  proved.
- `site/content/tour/control.md:40-41` — Collatz,
  `remaining = remaining / 2` on an `Int`. Becomes `//`.

Plus `site/content/tour/values.md:145` (`let half = width / 2` prints
`40` → `//`, prints `40`), `site/content/examples/errors.md:35`
(`return 100 / n` in `-> Int!` → `//`). Every `fail` block that
asserts *"conversions are explicit"* is deleted or rewritten —
principally `site/content/tour/hello.md:116`, and the prose in
`tour/values.md:36-57`, `ref/types.md:3-6,32-41`, `tour/next.md:10`,
`status/index.md:33,84`.

`site/content/ref/expressions.md:103` currently rejects `//` by name.
It becomes the row that documents it.

**Specs.** The load-bearing ones are load-bearing *because they are
the old rule*, and they should be rewritten rather than repaired:

- `specs/behavior_spec.zig:66-73` — *"integers: division truncates
  toward zero, remainder follows the dividend"* — is the trunc
  contract, and becomes the floor contract with the §3 table verbatim.
- `:2083,2092,2581` — `divide_by_zero` traps — move to `//` and `%`.
- `:100,789,2922` — constant folds of `Int /` — move to `//`.
- `:163` — `n /= 5` — becomes `//=`.
- `07_optimize/test.zig:579` — *"dead keeps an unread instruction that
  can trap"* — its premise ("a division is `stable`") is true of `//`
  and false of `/` after this change; it moves to `//` and the comment
  gets one clarifying clause.
- Ten trap-trace specs use `a / b` as the canonical trap
  (`behavior_spec.zig:2977,3000`, `08_llvm/test.zig:163,432,555,580`,
  `apps/luce/object.zig:353,402`, `optimize_spec.zig:182`) — `//`
  serves identically.
- `specs/errors_spec.zig:883,899,917` assert the dying messages;
  deleted, and replaced by tests that the same programs now *compile*.

**One program needs a real decision, not a migration.**
`programs/calc.luc:65,67` is a user-facing calculator whose
`Step.value` is an `Int`, so `7/2` prints `3` today. Under the new
rules it can become a Float calculator — which is what a calculator
should be, and what every pocket calculator is — or keep `Int` and
use `//`. Recommended: make it Float, and let it be the worked
example, the way `dice.luc` and `editor.luc` became the worked
examples in `docs/FAILURE.md`.

**Total honest size:** the `/`→`//` edits are ~36 mechanical
one-character insertions; the `%` edits are three simplifications and
no corrections; the prose is ~20 authoritative statements across
`docs/` and the site; the specs are ~15 tests, of which four are
rewrites rather than edits. The oracle and the site build catch
everything missed, by construction.

## Order

Each step leaves the tree green and shippable. The sequence is chosen
so that the one dangerous change lands last and, by then, has no
users.

1. **Promotion, and exact comparison.** Extend `fit`; unify binary
   operands; add `compare_int_float`; delete the dying diagnostics;
   rewrite the site's "no implicit conversions" pages. **This step is
   strictly additive** — it only admits programs that were refused, so
   no existing program changes meaning and no corpus migration
   happens. Version 19. The whole benefit of D1 lands here:
   `total / Float(len(values))` becomes `total / len(values)` on the
   day this ships, with `/` still meaning integer division.
2. **`//`, `//=`, and floor `%`.** New `BinaryOp.floor_divide`,
   `remainder` → `modulo`, `@divFloor`/`@mod` in the runtime and the
   lowering, the lexer's `'/'` arm, and the §3 and §5 tables as
   programs in `specs/`. **Then migrate every integer `/` in the tree
   to `//` in the same commit** — all 36 — leaving `Int / Int` legal,
   truncating, and used by nothing.
3. **`/` becomes true division.** Because step 2 emptied it, this
   commit changes the behaviour of **no program in the tree**. It is
   stage-4 convert insertion, the `divide_by_zero` guard moving off
   `/`, `effects.zig` reclassifying `/` as `pure`, and the four site
   samples. The riskiest change in the memo, made boring on purpose.
4. **`Int(x)` rounds; `trunc` is added.** Three guard sites in
   lockstep (runtime, folder, LLVM), `std/math.luc:35` simplified.
5. **`String(x)`, and D5's answer on `str`.** Stage 4 only if `str`
   stays; a mechanical corpus rename if it goes, plus `Builder.build()`.
6. **f-string `:.2f`.** One production in the f-string scanner,
   lowering to `strings.format_float`. No runtime.
7. **`docs/LANGUAGE.md`, `docs/MISSING.md` items 9 and 10 closed,
   `docs/PIPELINE.md`, and this memo's corrections section.**

Steps 1 and 2 are independent and could be done in either order; 3
must follow 2, and 6 must follow nothing.

## Refused, with reasons

**Implicit `Float` → `Int`.** In no direction, ever. It is the half of
implicit conversion that loses information silently and it is what
makes §9's answer to float contagion work.

**Untyped-constant promotion only** (Go's, Swift's, Haskell's). It is
a strict subset of what is proposed, arrives free with it, and by
itself refuses `total / len(xs)` — the exact expression the owner is
trying to make writable.

**Refusing everything** (Go's real position: no implicit conversion
between any numeric types, `int/int = int`, and `float64(i)` spelled
at every site). This is the counterargument, it is the position Luce
held until today, and it is worth recording that Go's authors
considered it load-bearing enough to keep through fifteen years of
complaint. It loses here for one reason: Luce is Python-shaped, and a
Python-shaped language in which `total / len(xs)` is a type error is
lying about what it is.

**Rust's `as`.** Explicit, cheap, uniform — and it works because
Rust's audience budgets three characters for correctness. Rust's own
refusal to implement `From<i64> for f64` is the sharpest available
statement of what this memo gives up (§6). Recorded, not adopted.

**JavaScript's answer** — one numeric type, `/` always real, integers
exact only to 2^53. The cautionary tale, and the reason §5 insists on
exactness: TC39 had to bolt on BigInt, and then had to refuse mixed
arithmetic while permitting exact mixed comparison. Luce is taking the
opposite half. It should at least take the half TC39 kept.

**Correctly-rounded `Int / Int`** (Python's `long_true_divide`). A
`libluce_rt` call on the hottest operator to fix a case that begins at
exactly 2^53 and never occurs below it (§2).

**The trunc pairing for `//` and `%`.** It keeps `%` compatible with
C and changes no existing program, and it loses because
`a // b != floor(a / b)` under it — which makes `//` mean something
other than its name in the presence of the `/` this memo is
introducing (§3).

**`divmod`.** Python has it because its `//` and `%` are two calls on
a big-integer object and one instruction is cheaper than two; Luce's
are two machine instructions and LLVM's `sdiv`/`srem` pair already
CSEs into one `idiv`. It would be ceremony over a fixed problem.

**Bitwise operators, as a substitute for `//` on powers of two.**
`docs/MISSING.md` item 11 keeps them refused-by-name and this memo
does not reopen it. Worth noting only that floor-mod makes the most
common reason to want them — `x & 255` as byte wrapping — expressible
correctly as `x % 256` for the first time (§3).

**A `numeric` or `Number` supertype.** There is no subtyping in Luce
beyond `T <: T?` and this would be the second, which is how a small
type system stops being small.

---

## As built

The ratified plan, landed step by step.  Each entry says what shipped
and — where the memo met the code and lost — what the memo had wrong,
corrected here rather than left for the next reader to re-derive.

### Step 1 — promotion, and exact comparison — **landed**

`fit` (`04_semantics/builder.zig`) grew its second arm and every site
that already called it got promotion for free: annotation, argument,
return, struct field.  `Intrinsic.compare_int_float` arrived with
`operators.compareIntFloat` behind it, one implementation in
`libluce_rt` that the constant folder calls too.  `format_version` is
**19** and `abi.version` did not move, exactly as §10 predicted.  The
benchmarks are unchanged to the tenth of a percent: promotion costs
nothing in code that does not mix.

**Five things the memo did not have right.**

1. **`fit` is not the whole of it.**  Five places compare an operand's
   type against a wanted type *without* calling `fit`, because they
   lower before the wanted type is known: binary operands, compound
   assignment through a nested place, `xs[i] = v`, `methodTakes`
   (`xs.append(1)`), and `min`/`max`/`clamp`.  Each needed its own
   line.  The memo's "promotion is a second arm on that function" is
   true of half the sites and no more.

2. **`min`, `max` and `clamp` are promotion sites**, and the memo does
   not list them.  They are not `fit` sites — they have no expected
   type, they unify — but `clamp(x, 0, 10)` being a type error for a
   Float `x`, in a language where `x < 0` is not, is exactly the
   arbitrary carve-out §1 argues against.  They unify like a binary
   operator: one Float among them makes them all Floats.

3. **A list literal needs the expected type pushed *into* it.**
   §1's "`let xs: List(Float) = [1, 2, 3]` is `List(Float)`" cannot
   come from `fit`: the literal is inferred bottom-up and hands back a
   `List(Int)` that no widening turns into a `List(Float)` — a
   container is not its element.  It works by a one-hop
   `wanted_element` field on the builder, the same shape
   `allow_fallible` already uses.  While there: `[1, 2.5]` was a type
   error and `[2.5, 1]` would have been legal under the naive rule, so
   the literal unifies over *all* its elements — one Float anywhere
   makes them all Floats.

4. **Nothing folds a promoted literal at compile time.**  §1 says
   "`x * 2` with `x: Float` becomes `x * 2.0` in the constant folder";
   there is no such folder for function bodies — `07_optimize` is
   prune, ownership and dead, and none of them is constant folding.
   The `convert` instruction is emitted and LLVM folds `sitofp` of a
   constant before any machine code exists, so the *claim* (zero cost)
   holds and the *mechanism* named does not.

5. **The mirror belongs to the operator.**  §5 describes
   `compare_int_float(op, i, f)` without saying what happens when the
   Float is written first.  `BinaryOp.mirrored` answers it in one
   place: the Int is always the left operand and an operator written
   the other way round is turned around, rather than the runtime
   growing a second implementation of the same judgment.

**Deliberately not done here.**  Method arguments promote numerically
but still refuse `T` into `T?` — `fit` would have given both, and
admitting the second is a separate decision that has nothing to do
with numbers.

### Step 2 — `//`, `//=`, and floor `%` — **landed**

`BinaryOp.floor_divide` arrived, `remainder` became `modulo`, and the
two floor together in the runtime (`@divFloor`/`@mod`), in the
constant folder, and in the lowering.  §3's table is a program in
`specs/` on both engines, beside the identity `b * (a // b) + (a % b)
== a` swept over every sign, and the mask property (`x % 256` in
`[0, 256)` for every `x`) that made `bf.luc:42` the spelling its
author meant.  Every integer `/` in the tree is now `//`: **35 sites**
— nine in `.luc`, twenty in Zig specs, four on the site, two in
`src/apps` — against the memo's estimate of 36, which was one out.
The three `%` workarounds §3 named are gone, `math.luc:230-233` from
four lines to one.  The benchmarks do not move and the C twins were
not touched, as §11 predicted.

**Three things the memo did not have right.**

1. **Zig's float `@mod` is not floor-mod**, so the runtime could not
   simply swap `@rem` for `@mod` in both arms as §10 says.  Zig's
   *integer* `@mod` floors and pairs with `@divFloor` correctly, but
   its float `@mod` only forces a non-negative answer:
   `@mod(7.0, -3.0)` is `1.0` where flooring says `-2.0`.  Using it
   would have put the discontinuity promotion exists to remove back
   one type over.  `operators.floorMod` is written out instead, and
   because its answer is a `frem`, a zero case that takes the
   divisor's sign, and a correction on opposed signs — three chances
   to differ if written twice — the compiled path **calls** it rather
   than inlining it.  It is the only float operator that is a call.

2. **`//` works on Floats.**  Rule 3 says `//` and `%` "answer `Int`
   for `Int` operands" and the memo never says what `7 // 2.0` is.
   It has to be something: `//` promotes like every other arithmetic
   operator, and refusing the mixed form while `%` accepts it is the
   arbitrary carve-out §1 argues against.  So Float `//` is
   `floor(a / b)`, which keeps the §3 identity true of Floats as well
   and is IEEE like the rest of them — `1.0 // 0.0` is `inf`, not a
   trap.

3. **The lexer's message did not die, it moved.**  §3 accepts spending
   `luce.lex.comment` for the operator.  It did not have to be spent
   outright: **prefix position** is where the comment reading is
   unambiguous — an operator with nothing on its left cannot be
   arithmetic — and a `// comment` is written at the start of a line
   every time.  So a statement beginning `//` is `luce.parse.comment`,
   *"'//' is floor division and needs a number on its left; a comment
   starts with '#'"*, and `a // b` is division without a word about
   it.  `/* */` keeps its lexer arm unchanged.

### Step 3 — `/` is true division — **landed**

Exactly as §Order predicted, and for the reason it gave: step 2 had
emptied the operator, so this commit changed the behaviour of no
program in the tree.  Stage 4 widens two Int operands of `/`, the
verifier **refuses** `Binary { .divide, .int }` outright — which is
what let the runtime, the folder and the lowering stop carrying an
integer `/` at all rather than keeping a dead arm — `effects.zig` now
reaches `/` through its Float arm and calls it `pure`, and the
`divide_by_zero` guard lives on `//` and `%`.  `1 / 0` is `inf`,
`0 / 0` is NaN, and `minInt / -1` is `-9.223372036854776e18`.
`programs/calc.luc` is a Float calculator: `7/2` is `3.5`, `1/0` is
`inf`, and its scanner did not have to learn about decimal points to
get there, because promotion does it.

**Two things the memo did not have right.**

1. **The four site samples needed nothing.**  §11 calls
   `examples/traps.md:52` and `tour/control.md:40` samples that "need
   more than a mechanical edit" and asks for real new content.  They
   did not: step 2 moved both to `//`, and `//` still traps
   `divide_by_zero` and still answers the Int quotient, so each keeps
   proving exactly what it proved with the caret in the same column.
   Landing the operator before flipping `/` is what made the hard
   cases disappear, which is the strongest evidence for the order the
   memo chose.

2. **`n /= 2` needed its own diagnostic, not an inherited one.**  §9
   says the existing message at `builder.zig:1882` catches it — "place
   is Int, value is Float".  It does not: compound assignment fits its
   value to the *place* first, so the Int value fits an Int place and
   the mismatch only appears in the result, which nothing looks at.
   It is refused where the operator is chosen instead, and the message
   names the one-character fix: *"/ answers a Float and this place is
   Int; write '//=' for the integer quotient"*.

### Step 4 — `Int(x)` rounds; `trunc` arrives — **landed**

`Int(x)` rounds half away from zero and `trunc(x: Float) -> Float`
joins `floor` and `ceil`, so the four roundings are four spellings for
four different answers.  The three guard sites moved in lockstep as
§7 requires — `runtime/operators.zig`, `04_semantics/declarations.zig`
and `08_llvm/lower.zig` — and `std/math.luc:35`'s hand-rolled half-up
is now `Int(x / ln2)`, correct on negative inputs for the first time.

**Two things the memo did not have right.**

1. **`math.round` was not the rounding it was documented as, so
   "the one already ratified wins" had to be applied to the
   *documentation* rather than to the code.**  §7 argues that `Int(x)`
   must agree with `math.round` because `math.round` already exists
   and already says "half away from zero".  It said so and did not do
   so: it was `floor(x + 0.5)`, and `0.49999999999999994 + 0.5` rounds
   up to exactly `1.0` in binary64, so its floor is `1` where the
   answer is `0`.  Adopting the implementation would have adopted the
   bug into `Int(x)` and into every artifact.  Both now compute the
   documented rule: the runtime and the lowering through `@round` /
   `llvm.round`, which *is* roundToIntegralTiesToAway, and
   `math.round` by splitting at `trunc(x)` and comparing the fraction
   — exact, and the first real payoff of adding `trunc`.

2. **`Int(x)` had truncating callers, and §7 does not mention them.**
   `strings.format_float` split a number at its integral part with
   `Int(magnitude)` and hand-rolled the fraction's rounding with
   `floor(… + 0.5)`; three benchmarks took `Int` of a checksum.  All
   of them say `trunc` out loud now, and `format_float`'s `+ 0.5` is
   gone because `Int` does that step correctly.  None changed answer:
   the benchmark outputs are byte-identical and the C twins were not
   touched.

**The range check moved after the rounding**, which §7 does not
specify.  Rounding can only carry a value toward the boundary, and
NaN and the infinities survive `@round` unchanged, so one check on the
rounded value catches everything two checks would — and it is one
check in each of the three places rather than two, which is what keeps
them provably the same check.

### Step 5 — `String(x)` arrives; `str` retires — **landed**

`String(x)` joins `Int(x)` and `Float(x)` as a conversion constructor
named for what it produces, `Builder` gets the `build()` method D5
recommended, and `str` is gone from the builtin table, from the
reserved list, and from all 35 call sites.  The complaint at
`04_semantics/context.zig:61` is closed twice over: the `String(...)`
it sent readers after exists, and the message that sent them there had
already gone in step 1.

**Three things the memo did not have right.**

1. **`String(x)` is not "the existing `str_value` intrinsic reached by
   a new name" and nothing else.**  §7 says the change is "stage-4
   work and no new MIR, no new runtime, no new ABI", which is true of
   the *intrinsic* and understates the seam: `str` was resolved
   through the builtin table, where `Int` and `Float` are matched by
   name in `lowerCall` **before** that table is consulted.  Moving
   `String` to the second mechanism is what makes all three
   constructors one thing rather than two-plus-one — and it is why
   `String` is a reserved name and `str` is no longer one.

2. **f-strings desugar through it.**  §7 does not mention them, and
   they are the largest caller: every hole is a synthesized `str(...)`
   call, so the rename reached `03_parse/expressions.zig` and every
   f-string diagnostic became `luce.sema.convert` at the hole.  That
   reads better than what it replaced — a hole is a conversion the
   reader did not write, so the constructor's own message is the right
   one to give.

3. **`String(x)` of a constant folds, and `str(x)` never did.**  A
   consequence nobody asked for and worth keeping: the folder handles
   the three constructors, so `let banner = String(width) + "px"` is
   now a compile-time constant where it used to be "calls are not
   constant".  One site sample was built on exactly that refusal and
   needed a real call to make its point instead.

**The Float text is spelled once.**  Both the runtime and the folder
print a Float with Zig's `{d}` — the Ryū-derived shortest
representation that round-trips — so a folded `String(2.5)` is the
same bytes a run would produce, and the specs compare them.

### Step 6 — f-string `:.Nf` — **landed**

`f"{mean:.2f}"` lowers to `strings.format_float(mean, 2)`, exactly as
§8 recommends: one production in the f-string scanner, no runtime, and
the std function that already existed and already rounds half away
from zero.  `programs/dice.luc:36-37` — the shape §8 names as what
this replaces — is one line now, and reads
`f"total {total}, mean {total / count:.2f}"`, which is D1, D3 and D6
in the same expression.

**Two things the memo did not have right, both in its favour.**

1. **The scan was already written.**  §8 costs "one grammar production
   in the f-string scanner"; it cost slightly less, because
   `topLevelColon` already existed to *refuse* this exact syntax —
   *"no format specifiers in an f-string hole; use
   strings.format_float(x, 2)"* — and it is the same bracket-aware,
   string-skipping scan the split needs.  The refusal became the
   feature by deleting four lines and calling the helper for its
   answer instead of for its existence.

2. **A spec needs `import std.strings`,** which §8 does not mention.
   It follows from the lowering rather than being a new rule: a spec
   *is* `strings.format_float`, so it needs what `s.split(",")` needs
   and reports through the same `luce.sema.import` diagnostic.  Worth
   writing down because it is the one thing about specs that surprises.

### Step 7 — the docs, and what the numbers say — **landed**

`docs/LANGUAGE.md`'s arithmetic and conversion sections are rewritten,
`docs/MISSING.md` item 9 is closed by name (both workarounds it cited
by line are gone) along with its Tier-5b item 3, `docs/PIPELINE.md`
and `CLAUDE.md` no longer claim there are no implicit conversions, and
every site page that asserted it says what is true instead.  The site
builds every sample it shows, so the tour and the reference are
verified rather than merely edited.

**The measurements.**  `bench/compare.sh` against the base, twice:
every row within noise, the largest consistent movement 1% and in both
directions between runs.  The one row that looked real on the first
pass — matmul's compute column at +5.9% — was 0.5% on the second, and
matmul is the shortest benchmark there is.  Promotion costs nothing in
code that does not mix, which is what §1 predicted; the C twins were
never touched, which is what §11 predicted; and `bench/run.sh`'s
cross-check passed at every step.

**`abi.version` did not move**, at any step.  §10 said nothing here
touches the `LuceHost` vtable and nothing did: every new semantic is a
`libluce_rt` call (`luce_rt_compare_int_float`, `luce_rt_float_mod`)
or an inline sequence.  `format_version` moved once, to **19**, at the
first wire change, and the fingerprint moved with it three times as
the instruction set settled.
