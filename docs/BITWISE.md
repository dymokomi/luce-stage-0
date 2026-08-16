# Bitwise operators and integer literals

Luce has the six C-family bit operators — binary `&`, `|`, `^`, `<<`,
`>>` and unary `~` — their compound-assignment forms, and the integer
literals `0xFF`, `0b1010`, and `1_000` with digit separators. They spell
the bit-level work that CRC tables, Huffman coders, and little-endian
fields are made of.

## The operators

| operator | meaning |
|---|---|
| `a & b` | bitwise and |
| `a \| b` | bitwise or |
| `a ^ b` | bitwise xor |
| `~a` | bitwise not (`~a` is `-a - 1`) |
| `a << n` | left shift by `n` bits |
| `a >> n` | right shift by `n` bits (arithmetic) |

```luce
func main():
    let flags = 0b1010
    let mask = 0b0110
    print(str(flags & mask))   # 2
    print(str(flags | mask))   # 14
    print(str(flags ^ mask))   # 12
    print(str(~flags))         # -11
    print(str(flags << 2))     # 40
    print(str(flags >> 1))     # 5
```

**Integers only.** `int` and `long` operate directly; `byte` and `short`
widen to `int` first, exactly as they do under arithmetic
(`docs/TYPES.md`), so no expression ever has an 8- or 16-bit type. A
float has no bits a program may see, and a bitwise operator on one is
refused:

```text
let y = 1.5 & 1   # refused:
# & works on int and long; float has no bits a program may see
```

**Two's complement, signed.** `&`, `|`, and `^` operate on the two's
complement representation; `>>` is an **arithmetic** shift that
sign-extends, because the operands are signed — a logical shift on a
negative value would silently manufacture a positive number. Code that
wants logical-shift behavior masks first.

**Result type.** A binary bit operator's result is the unified operand
type — `int` with `int` is `int`, anything with a `long` is `long` — the
same unification arithmetic uses. A shift's **count** may be any integer
type and does not widen the shifted operand; the result type is the type
of the value being shifted.

Precedence follows Go rather than C: `&`, `<<`, and `>>` bind at the
multiplication level, and `|` and `^` at the addition level. This fixes
C's classic trap — `flags & mask != 0` means `(flags & mask) != 0`, as
it reads.

```luce
func main():
    let flags = 0b1100
    let mask = 0b0100
    if flags & mask != 0:
        print("set")
```

Comparison stays non-associative, and mixing comparisons (`a < b < c`)
remains refused; the change here is only that `a & b == c` groups as
`(a & b) == c`.

## Shifts are checked bit transport

A shift moves bits; it does not multiply, so high bits shifted out of an
`int` or `long` are discarded without trapping. The shift **count**,
however, is checked: a count that is negative or at least the operand's
bit width traps `shift_out_of_range` (`shift count out of range`, with
the count and the width), on both engines.

```luce
func main():
    let width = 40
    let n = width - 8
    print(str(1 << n))   # ok: 32 < 64 for a i64 shift
```

A `1 << 64` on a `long`, or a negative count, traps at run time. In a
constant context — a file-scope `const` or a folded default — a bad
shift count is caught at compile time instead:

```text
const bad: long = 1 << 99   # refused:
# constant shift count out of range
```

## Compound assignment

Each binary operator has a compound-assignment form — `&=`, `|=`, `^=`,
`<<=`, `>>=` — with the same typing and the same count check on the
shifts:

```luce
func main():
    var x = 0b1010
    x &= 0b0110
    x |= 0b0001
    x ^= 0b0011
    x <<= 2
    x >>= 1
    print(str(x))
```

## Constant folding

Bitwise expressions over constants fold in stage 4 with identical
semantics, the shift-count check included. A folded bitwise constant is
a value that inlines wherever it is used:

```luce
const read_mask: i64 = 0xFF
const write_flag = 1 << 4

func main():
    print(str(read_mask & write_flag))
```

## Literals

- **Hexadecimal** `0xFF` and **binary** `0b1010`. Hex and binary
  literals are integers — `int` until they land on a wider type, like
  any integer literal — and there are no hex floats. Digits are
  case-insensitive; the canonical prefix is lowercase (`0x`, `0b`), and
  `0X`/`0B` are also accepted.
- **Digit separators.** A `_` may sit between digits — `1_000`,
  `0xFF_FF`, `0b1010_1010` — but never leading, trailing, doubled, or
  beside the base prefix. A misplaced separator is `luce.lex.number`.
- **No octal.** There is no octal literal: `0o17` is refused by name,
  and a bare leading zero is a malformed number rather than a C-style
  octal.

```luce
func main():
    let a = 0xFF_FF
    let b = 0b1010_1010
    let c = 1_000_000
    print(str(a + b + c))
```

`shift_out_of_range` is the one trap code these operators add, shared by
both engines. Everything else reuses the arithmetic machinery: the LLVM
backend lowers to `and`/`or`/`xor`/`shl`/`ashr` with the count check in
front, and the interpreter calls the same runtime helpers.
