# Basic Operators

Operators combine, compare, or update values. Their operands are statically
typed: Luce does not turn numbers, strings, or objects into Boolean
conditions.

| Purpose | Operators |
|---|---|
| Arithmetic | `+` `-` `*` `/` `//` `%` |
| Comparison | `==` `!=` `<` `<=` `>` `>=` |
| Boolean logic | `and` `or` `not` |
| Bitwise integer work | `&` `|` `^` `~` `<<` `>>` |
| Assignment | `=` and the compound forms such as `+=` and `<<=` |

This chapter teaches the common forms. [Expressions](/guide/reference/expressions/)
defines the complete precedence table and every accepted spelling.

## Precedence and parentheses

Postfix operations such as a call, index, or field access bind first. Prefix
operators bind next, followed by multiplicative arithmetic, additive
arithmetic, `else` and `catch`, comparisons, `and`, and finally `or`.
Assignment is a statement rather than an expression, so it does not
participate in this table.

You rarely need to memorize the order. Use parentheses when two reasonable
readers could group an expression differently. In particular, Luce refuses
two forms whose familiar readings disagree across languages:

- `not a == b` must become either `(not a) == b` or `not (a == b)`;
- `a < b < c` must become `a < b and b < c`.

`else` and `catch` bind more tightly than comparison and associate to the
right. Thus `port else 0 > 0` means `(port else 0) > 0`, and `a else b else c`
tries each fallback from left to right.

## Unary operators

Prefix `-` negates a number, `not` negates a Boolean, and `~` complements
every bit of an integer. The result keeps the concrete operand type. Integer
negation is checked, so negating the smallest signed value traps rather than
wrapping. `try` is also a prefix expression, but it belongs to fallible calls
and is covered in [Error Handling](/guide/errors/#propagating-with-try).

## Arithmetic

`+`, `-`, and `*` preserve their operands' concrete numeric type. `/` is
true division: integer operands return `f64`, while floating-point operands
preserve their width. `//` is floor division, and `%` is its paired
remainder. Both operands must have the same concrete type; convert explicitly
when they do not.

```luce run
func main():
    print(str(1 / 2))
    print(str(7 // 2) + " " + str(7 % 2))
    print(str(-7 // 3) + " " + str(-7 % 3))
    print(str(-1 % 256))
```

```output
0.5
3 1
-3 2
255
```

Integer arithmetic is checked in every build mode. Overflow, division by
zero, and remainder by zero trap instead of silently producing a different
value.

```luce trap
func main():
    var n: i64 = 9223372036854775807
    print("about to add one")
    n += 1
    print(str(n))
```

```output
about to add one
loom: trap: integer overflow [integer_overflow]
    at main (main.luc:4:5)
```

Floating-point arithmetic follows IEEE rules. Adding two `str` values
concatenates them; use a [string builder](/guide/strings/#building-text)
when assembling many pieces.

Explicit numeric constructors make representation changes visible:

```luce run
func main():
    let count: u16 = 500
    let wider: u32 = u32(count)
    let ratio: f32 = f32(wider) / 8.0
    print(f"{wider} {ratio}")
```

```output
500 62.5
```

A conversion that cannot represent its input traps. Luce never chooses a
wider, signed, or floating result merely because another operand requires it.
This keeps the storage and precision decision at the line that makes it.

## Comparison

Equality and order comparisons work on the scalar types that define those
operations. Numeric operands must have the same concrete type, so a possible
change of width, signedness, or precision is visible in source.

```luce run
func main():
    let after: i64 = 9007199254740993
    let rounded: f64 = 9007199254740992.0
    print(str(f64(1) < 1.5))
    print(str(after == i64(rounded)))
```

```output
true
false
```

Comparisons do not chain. Write both comparisons so the shared operand and
the Boolean operation are visible:

```luce fail
func main():
    let a = 1
    let b = 2
    let c = 3
    print(str(a < b < c))
```

```output
luce: compile failed
main.luc:5:21: chained comparison: write 'a < b and b < c' [luce.parse.chain]
        print(str(a < b < c))
                        ^
```

Equality is not one operation over every value:

- numbers, `bool`, `char`, text, enums, and equality-capable value structures
  compare by value;
- lists, maps, arrays, builders, files, tasks, windows, and surfaces compare
  reference identity with `==` and `!=`;
- two values of the same class type compare identity with `is`;
- unions are inspected with `match`, and function values are not comparable.

These distinctions follow the underlying model: a structure is data, a list
or file is a reference, and a class declares nominal shared identity.

## Boolean logic

`and`, `or`, and `not` require `bool`. The first two short-circuit:
the right operand is evaluated only when it can affect the result.

```luce run
func valid_port(value: i64) -> bool:
    return value >= 1 and value <= 65535

func main():
    print(str(valid_port(8080)))
    print(str(not valid_port(70000)))
```

```output
true
true
```

Short-circuiting is useful for a guard whose second half is only valid after
the first succeeds. It is not an implicit optional unwrap: bind and narrow an
optional before using its payload, as described in [Optionals](/guide/optionals/).

## Bitwise integer operations

`&`, `|`, `^`, `~`, `<<`, and `>>` work on concrete integer types. The
operands of a binary operation have the same type, and the result keeps that
width. Right shift zero-fills an unsigned value and sign-extends a signed
value. Left shift is checked for overflow; every shift count must be between
zero and one less than the operand width.

```luce run
func main():
    let permissions: u8 = 0b10110100
    let readable: u8 = permissions & 0b00000100
    let high: u8 = permissions >> 4
    let signed: i8 = -8
    print(f"{readable} {high} {signed >> 1}")
```

```output
4 11 -4
```

Bitwise precedence follows Go rather than C: `&` and shifts group with
multiplication, while `|` and `^` group with addition. Write parentheses in
flag code when the grouping is part of the explanation, even when the table
already gives the same answer.

## Assignment

`=` replaces the value of a `var` binding or an assignable field,
element, or map entry. A compound assignment reads its target once, applies
the operator, and writes the result back.

```luce run
func main():
    var total = 4
    total *= 3

    var counts = new map[str, i64]
    counts["pear"] = 1
    counts["pear"] += 1
    print(f"{total} {counts["pear"]}")
```

```output
12 2
```

The target must be writable. Rebinding a `let`, changing a field through an
immutable structure binding, or applying a writing structure method to a
temporary is refused. A class object is different: `let` keeps the binding
fixed, but its methods may still mutate the shared object.

Compound forms exist for arithmetic and bitwise operators: `+=`, `-=`, `*=`,
`/=`, `//=`, `%=`, `&=`, `|=`, `^=`, `<<=`, and `>>=`. Luce has no `++` or
`--`; write `value += 1` or `value -= 1` so the update remains an ordinary
checked assignment.

Every checked failure keeps the same meaning in debug and release builds.
Overflow, a bad shift count, division by zero, or an invalid conversion is a
trap because continuing would require inventing a value. See [Errors and
Traps](/guide/reference/failure/) for the stable codes.

Continue with [Strings and Text](/guide/strings/).
