# Bitwise operators and integer literals

Luce has six bit operators—binary `&`, `|`, `^`, `<<`, `>>` and unary
`~`—plus their compound-assignment forms. They work on every concrete integer
type and never change its width or signedness.

## Operators and types

| Operator | Meaning |
|---|---|
| `a & b` | bitwise and |
| `a \| b` | bitwise or |
| `a ^ b` | bitwise xor |
| `~a` | bitwise complement |
| `a << n` | checked left shift |
| `a >> n` | signed arithmetic or unsigned logical right shift |

`&`, `|`, `^`, and `~` preserve the operand's exact integer type. The two
operands of a binary operation have the same concrete type; a literal takes
that type from the other operand, while two already typed values need an
explicit conversion.

```luce
func main():
    let flags: u8 = 0b1010
    let mask: u8 = 0b0110
    assert(flags & mask == 2)
    assert(flags | mask == 14)
    assert(flags ^ mask == 12)
    assert(~flags == 245)

    let signed: i8 = -8
    assert(signed >> 1 == -4)
    assert(u8(240) >> 4 == 15)
```

Floats have no bitwise operators. A mixed concrete-width expression is also
refused; Luce never inserts a numeric promotion for bit work.

## Shift checks

A shift preserves the left operand's type. Its count has the same concrete
integer type after contextual literal fitting or explicit conversion.

Two checks are distinct:

- a negative count, or a count at least the operand width, traps
  `shift_out_of_range`;
- a left shift whose result does not fit the operand type traps
  `integer_overflow`.

```luce
func main():
    let byte: u8 = 1
    assert(byte << 7 == 128)
    let wide: i64 = 1
    assert(wide << 62 == 4611686018427387904)
```

Thus `u8(128) << 1` traps overflow, `u8(1) << 8` traps a bad count, and
`i64(1) << 63` traps overflow. A signed right shift sign-extends; an unsigned
right shift zero-fills.

In a constant expression the same failures are compile-time refusals rather
than runtime traps:

```text
let bad_count: i64 = 1 << 99
let overflow: u8 = 128 << 1
```

## Precedence

Precedence follows Go rather than C: `&`, `<<`, and `>>` bind with
multiplication; `|` and `^` bind with addition. Consequently
`flags & mask != 0` means `(flags & mask) != 0`, as it reads.

```luce
func main():
    let flags = 0b1100
    let mask = 0b0100
    if flags & mask != 0:
        print("set")
```

Comparisons remain non-associative, so `a < b < c` is refused. The bitwise
precedence only makes expressions such as `a & b == c` group as
`(a & b) == c`.

## Compound assignment

`&=`, `|=`, `^=`, `<<=`, and `>>=` compute at the destination's concrete
width and use the same shift-count and overflow checks:

```luce
func main():
    var bits: u8 = 0b1111
    bits &= 0b1010
    bits |= 0b0101
    bits ^= 0b0110
    bits <<= 2
    bits >>= 4
    assert(bits == 2)
```

## Integer literal spellings

- Decimal, hexadecimal `0xFF`, and binary `0b1010` literals are integers.
  Digits in hexadecimal literals are case-insensitive; the canonical prefixes
  are lowercase, while `0X` and `0B` are accepted.
- A literal takes its integer type from context and must fit. With no context
  it is `i64`.
- `_` may separate digits—`1_000`, `0xFF_FF`, `0b1010_1010`—but cannot be
  leading, trailing, doubled, or adjacent to the base prefix.
- There are no hexadecimal floats or octal literals. `0o17` is refused, and a
  malformed leading-zero number does not silently become C-style octal.

Constant folding and runtime evaluation use the same concrete-width rules on
both execution engines. The runtime helpers and LLVM lowering both preserve
signedness, distinguish arithmetic from logical right shift, and report the
same `integer_overflow` or `shift_out_of_range` trap.
