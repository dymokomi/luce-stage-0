# Strings

`string` is immutable UTF-8 text and a value. Assignment copies the value;
there is no string handle to close or free. The language provides the basic
operations, and `std.strings` provides the larger text API.

## Core operations

`len` reports bytes. Indexing and slicing use byte offsets but require valid
UTF-8 boundaries.

```luce run
func main():
    let greeting = "hello, loom"
    print(f"{len(greeting)} bytes")
    print(greeting[0:5])
    print(string(greeting.byte_at(0)))
    print(string(greeting.find_byte(44, 0)))
    print(string("apple" < "banana"))
```

```output
11 bytes
hello
104
5
true
```

String literals are single-line and support `\n`, `\t`, `\\`, and `\"`.
Other escape forms are rejected. Use `chr` for a code point. A slice that
would split a UTF-8 sequence traps:

```luce trap
func main():
    let text = "λx"
    print(f"{len(text)} bytes")
    print(text[0:1])
```

```output
3 bytes
loom: trap: string slice splits a UTF-8 sequence [string_boundary]
    at main (main.luc:4:5)
```

## Interpolation

An `f"..."` string contains expressions in `{...}`. Each expression is
converted to text. Braces can be written as `{{` and `}}`.

```luce run
struct User:
    name: string
    age: long

func main():
    let user = User(name = "ada", age = 36)
    let x = 7
    let y = 3
    print(f"x = {x}, y = {y}")
    print(f"sum = {x + y}")
    print(f"name is {user.name}, next year {user.age + 1}")
    print(f"{{literal braces}}")
```

```output
x = 7, y = 3
sum = 10
name is ada, next year 37
{literal braces}
```

## Format specs {#format-specs}

The supported format specifier is `:.Nf`, which formats a `double` to `N`
decimal places:

```luce run
import std.strings

func main():
    let mean = 23.998425
    print(f"mean = {mean:.2f}")
    let total = 74
    let count = 20
    print(f"{count} rolls, mean {total / count:.2f}")
    print(f"{2.5:.0f} and {-2.5:.0f}")
```

```output
mean = 24.00
20 rolls, mean 3.70
3 and -3
```

The format spec uses `std.strings`; add the import when one is present:

```luce fail
func main():
    let mean = 23.998425
    print(f"mean = {mean:.2f}")
```

```output
luce: compile failed
main.luc:3:21: a format spec like {x:.2f} formats through std.strings; add import std.strings [luce.sema.import]
        print(f"mean = {mean:.2f}")
                        ^~~~
```

An invalid format string is diagnosed at compile time:

```luce fail
import std.strings

func main():
    let x = 1.5
    print(f"{x:.2}")
```

```output
luce: compile failed
main.luc:5:15: unknown format spec ':.2'; the one form is ':.Nf' — N decimal places of a double [luce.parse.fstring]
        print(f"{x:.2}")
                  ^~~
```

## `std.strings`

Import the module for search, splitting, joining, trimming, case conversion,
replacement, padding, repetition, and float formatting. Method syntax is
available for the imported operations.

```luce run
import std.strings

func main():
    let line = "  the quick brown fox  "
    let trimmed = line.trim()
    print(f"[{trimmed}]")
    print(f"upper: {trimmed.upper()}")
    print(f"contains 'quick': {trimmed.contains("quick")}")
    print(f"find 'brown': {trimmed.find("brown") else -1}")
    print(f"replace: {trimmed.replace("quick", "slow")}")

    let words = trimmed.split(" ")
    print(f"{len(words)} words, joined with dashes: {words.join("-")}")

    print(f"[{"x".repeat(3)}] [{"7".pad_left(4)}]")
    print(strings.format_float(2.5, 2))
```

```output
[the quick brown fox]
upper: THE QUICK BROWN FOX
contains 'quick': true
find 'brown': 10
replace: the slow brown fox
4 words, joined with dashes: the-quick-brown-fox
[xxx] [   7]
2.50
```

Offsets remain byte offsets, while the library avoids returning a slice that
would split a UTF-8 character. `split("")` splits runs of whitespace and
drops empty pieces; a non-empty separator keeps its ordinary separator
semantics.

## Conversions

```luce run
func main():
    print(string(42))
    print(string(2.5))
    print(string(true))
    print(chr(955))
    print(string(ord("λ")))
```

```output
42
2.5
true
λ
955
```

`parse_int` and `parse_float` return optionals because the text may not
contain a number. See [Absence](../absence/).

Next: [Memory](../ownership/).
