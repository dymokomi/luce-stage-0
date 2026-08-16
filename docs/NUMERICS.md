# Numeric semantics

Luce has eight fixed-width integers and three IEEE floating-point types:

```text
u8  u16  u32  u64
i8  i16  i32  i64
f16 f32 f64
```

The type name is the representation. Concrete numeric values never change
width, signedness, or numeric family implicitly. Literals take a type from
context; explicit constructors cross representation boundaries.

## Contextual literals

An integer literal is checked with arbitrary precision and lands directly in
the integer type required by its annotation, argument, result, field,
container element, enum backing, or concrete numeric operand. It must fit that
type. Without context it is `i64`.

```luce
func main():
    let small: u8 = 255
    let count = 42              # i64
    let values: list[u16] = [1, 2, 3]
    assert(small == 255)
    assert(count == 42)
    assert(values[2] == 3)
```

A floating literal follows the same rule for `f16`, `f32`, or `f64` and
otherwise becomes `f64`. Compile-time rounding uses round-to-nearest,
ties-to-even.

Context reaches a literal, not an already typed value. If `x` is `u32`, the
literal in `x + 1` becomes `u32`; two names in `x + y` must already have the
same concrete type.

## No implicit numeric conversion

Assignment, arguments, returns, operators, comparisons, and container stores
never convert one concrete numeric type into another. This is a type error:

```luce refused
func main():
    let narrow: i32 = 7
    let wide: i64 = narrow
    print(str(wide))
```

The intended boundary is explicit:

```luce
func main():
    let narrow: i32 = 7
    let wide: i64 = i64(narrow)
    print(str(wide))
```

## Checked integers

Every integer type computes at its own width.

- `+`, `-`, `*`, and unary `-` are checked. Overflow traps
  `integer_overflow`; it never wraps and is never undefined.
- Unary `-` accepts signed integers only. Negating the minimum signed value
  traps.
- `//` is floor division and `%` is its paired remainder. Both preserve the
  operand type, trap `divide_by_zero`, and satisfy
  `b * (a // b) + (a % b) == a`.
- Signed minimum divided by `-1` traps `integer_overflow`.
- `&`, `|`, `^`, and `~` work on every integer type and preserve it.
- `<<` and `>>` preserve the left type. A negative shift count or a count at
  least the left width traps `shift_out_of_range`; a left-shift result that
  does not fit traps `integer_overflow`. Signed right shift sign-extends and
  unsigned right shift zero-fills.

```luce
func main():
    var value: u8 = 255
    value += 1
```

The compound assignment computes as `u8`, so it traps
`integer_overflow`; there is no hidden wider intermediate.

Signed `//` floors toward negative infinity, and `%` takes the sign of the
divisor:

```luce
func main():
    assert(-7 // 3 == -3)
    assert(-7 % 3 == 2)
```

Unsigned division is ordinary quotient and remainder.

## Floats

`f16`, `f32`, and `f64` all compute at their own width. Arithmetic,
comparisons, `floor`, `ceil`, and `trunc` preserve that width. Floating-point
arithmetic follows IEEE 754, including infinities and NaNs, and does not trap.

Concrete float widths do not mix, and an integer does not mix with a float.
A literal can still take the concrete operand's type:

```luce
func main():
    let scale: f32 = 1.5
    let doubled = scale * 2       # 2 becomes f32
    let precise = f64(scale) * 2  # explicit f64
    print(str(doubled) + " " + str(precise))
```

## Division

`/` is true division:

- two operands of the same float type answer that float type;
- two operands of the same integer type answer `f64`;
- division by zero therefore follows IEEE 754 and answers infinity or NaN.

Integer `/` may lose precision because its result is explicitly floating.
Use `//` for an integer result. Convert both inputs before `/` when the result
must have a chosen float width.

```luce
func main():
    assert(7 / 2 == 3.5)
    let done: u32 = 1
    let total: u32 = 4
    let ratio: f32 = f32(done) / f32(total)
    assert(ratio == 0.25)
```

## Comparisons

Numeric values compare only at one concrete type. Literals may take that type;
typed values require a conversion. Integer ordering is exact. Floating-point ordering
follows IEEE rules, so every ordered comparison with NaN is false and NaN is
not equal to itself.

```luce
func main():
    let exact: i64 = 9007199254740993
    assert(exact != 9007199254740992)
    assert(f64(exact) == 9007199254740992.0)
```

The second comparison is true because the written `f64` conversion rounds an
integer that binary64 cannot represent exactly.

## Explicit conversions

Every numeric name is a conversion constructor. Conversion to the same type
is legal and redundant.

- Integer to integer checks the destination range and traps
  `conversion_range` when the value does not fit.
- Floating-point to integer truncates toward zero, then checks the destination range.
  NaN and infinities trap `conversion_range`.
- Integer to float rounds to nearest, ties-to-even, and does not trap.
- One floating-point width to another rounds to nearest, ties-to-even; narrowing may produce
  infinity rather than trapping.

```luce
func main():
    let x: f64 = 3.9
    assert(i32(x) == 3)
    assert(i64(floor(x)) == 3)
```

Enum conversion uses the enum's declared integer backing type. An omitted
backing defaults to `i32`. Converting out is explicit through that integer
type or `str`; `Enum(value)` is the optional checked way in.

## Text parsing

The parser name states the result width. `parse_i64(text)` answers `i64?` and
`parse_f64(text)` answers `f64?`; invalid or out-of-range text produces
`none`. Neither name guesses a width, and neither silently narrows to another
numeric type. Convert the parsed value explicitly when a different
representation is required.

```luce
func main():
    let count = parse_i64("42") else 0
    let ratio = parse_f64("0.25") else 0.0
    let small = u8(count)
    print(f"{small} {ratio}")
```

## Text formatting

`str(x)` renders a number with the shortest text that round-trips at its own
width. It also renders `bool`, `char`, `str`, enum and union members, and
function values.

A float in an f-string accepts `:.Nf`, meaning `N` decimal places rounded half
away from zero:

```luce
import std.strings

func main():
    let mean: f64 = 23.995
    print(f"{mean:.2f}")
```
