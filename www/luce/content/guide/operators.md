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

Continue with [Strings and Text](/guide/strings/).
