# Bits are values too — `& | ^ << >> ~`, hex, binary, and the underscore

Run three of the ratified roadmap (`docs/MISSING.md` item 11: *"No
bitwise operators, no hex literals, no digit separators"*), sequenced
after visibility exactly as the visibility memo's `Order` said it
would be — both runs touch stage 2, and racing them would have been
the one way to lose both.

The warrant sharpened the day before this memo landed: the owner
asked for `std.zip`, and a ZIP file is CRC-32 tables, Huffman bit
readers, and little-endian fields — code that without these operators
is division-and-modulo soup wearing well-chosen names.  The owner's
sequencing ruling is the memo's first line: *"probably we need to do
bitwise ops before zip."*

---

## Ratified (owner, 2026-08-06)

Three questions were put to the owner; all three answered:

| | ruling |
|---|---|
| **R1** | **Go's fixed precedence.**  `&`, `<<`, `>>` bind at the multiply level; `\|`, `^` at the add level.  C's mistake — `x & 1 == 0` parsing as `x & (1 == 0)` — is fixed the way Go fixed it, so `flags & mask != 0` means what it reads as. |
| **R2** | **Shifts are bit transport, and the count is checked.**  `x << n` discards high bits without trapping — a shift moves bits, it does not multiply — but a count out of range (`n < 0` or `n >= width`) **traps** `shift_out_of_range`.  C leaves that undefined and Go silently masks; Luce says it out loud, which is the house posture on every boundary. |
| **R3** | **The full literal set**: `0xFF`, `0b1010`, and `_` digit separators (`1_000_000`).  No octal — `0o17` stays refused by name, and C's bare-`0` octal is not honored even as a refusal shape (a leading zero stays `luce.lex.number`). |

## Decisions (consensus, recorded once)

| | decision |
|---|---|
| **D1** | Six operators: binary `&`, `\|`, `^`, `<<`, `>>` and unary `~`.  Spelled as every C-family language spells them; no keyword forms. |
| **D2** | **Integers only**: `int` and `long` operate; `byte`, `short` widen to `int` first, exactly as arithmetic widens them (docs/TYPES.md D5) — no expression ever has an 8- or 16-bit type, so there is no 8-bit `&` to define.  Floats are refused with a sentence naming the fact (`double` has no bits a program may see). |
| **D3** | **Two's complement, signed.**  `&`, `\|`, `^` operate on the representation; `~x` is `-x - 1`; `>>` is an **arithmetic** shift (sign-extending) because the operands are signed — a logical shift on a signed value would manufacture a positive number out of a negative one silently.  Code that wants logical-shift behavior masks first, which under R2 it can. |
| **D4** | The result type is the unified operand type (`int` op `int` is `int`, anything with a `long` is `long`) — the arithmetic unification rule, reused whole.  A shift's *count* may be any integer type and does not widen the shifted operand. |
| **D5** | **Compound forms**: `&=`, `\|=`, `^=`, `<<=`, `>>=` — the assignment sugar every other operator has.  Same places, same rules. |
| **D6** | **Constants fold**, with identical semantics: a `let` of `0xFF & mask` folds in stage 4's folder, count-trap included (a constant shift with a bad count is a compile error naming the trap it would have been). |
| **D7** | Separator rules: `_` between digits only — `1_000`, `0xFF_FF`, `0b1010_1010` — never leading, trailing, doubled, or beside the base prefix or the point.  A misplaced one is `luce.lex.number` naming the rule. |
| **D8** | Hex and binary literals are **integers** (`int` until they land somewhere, like every integer literal); there are no hex floats.  Case-insensitive digits, lowercase canonical prefix (`0x`, `0b`); `0X`/`0B` are accepted — refusing a case would be the one place the language cared. |
| **D9** | One new trap code, `shift_out_of_range`, in the shared vocabulary — both engines, one sentence: `shift count out of range` with the count and the width.  `format_version` bumps for it. |
| **D10** | Comparison stays non-associative and the refusal extends: `a & b == c` parses as `(a & b) == c` under R1 and is fine; what stays refused is mixing *comparisons* (`a < b < c`), untouched by this memo. |

## Where it lands

Stage 2: five operator tokens (plus compound forms), `~`, hex/binary
scanning, separators.  Stage 3: precedence rows at the two levels R1
names; unary `~` beside `-`.  Stage 4: integer typing, widening,
folding.  MIR: `BinaryOp` gains five, `UnaryOp` gains one, the
verifier and printer learn them, `format_version` moves.  Engines:
LLVM lowers to `and`/`or`/`xor`/`shl`/`ashr` with the count check in
front; the interpreter calls the same `libluce_rt` arithmetic
helpers everything else calls.  The specs run every operator on both
engines, count-traps included, and the site's lexical page stops
saying "no hexadecimal" — a claim the build has been verifying, so
the fences move in the same commit.

---

*Built the day it was ratified, in one vertical: every guard named its site, the compound-assign path's `unreachable` died to the spec that found it, and 1,300+ tests including the two-engine bit-set rows and the count-trap rows are green.  The zip run this memo unblocks is next.*
