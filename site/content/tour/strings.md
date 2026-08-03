# Strings

A `String` is immutable UTF-8 text, and it is a **value**: it copies
on assignment, it goes into a list without ceremony, and nobody frees
it.

The *language* keeps only the primitives. Everything built on top of
them lives in the standard library's `strings` module, written in
ordinary Luce.

## The primitives

Literals, `+`, comparison, boundary-checked slices, `len` in bytes,
and two raw-byte operations.

```luce run
func main():
    let greeting = "hello, loom"
    print(f"{len(greeting)} bytes")
    print(greeting[0:5])                # a slice; still a value
    print(str(greeting.byte_at(0)))     # 'h'
    print(str(greeting.find_byte(44, 0)))  # first comma
    print(str("apple" < "banana"))
```

```output
11 bytes
hello
104
5
true
```

A literal is written `"..."` and stays on one line. The escapes are
`\n`, `\t`, `\\` and `\"` — and there are no others. `\r`, `\0`, hex
and unicode escapes are all rejected by name; a codepoint goes in with
`chr(...)`.

Slicing checks UTF-8 boundaries, so you cannot cut a character in
half. Trying is a trap, not silent corruption.

```luce trap
func main():
    let text = "λx"          # the lambda is two bytes
    print(f"{len(text)} bytes")
    print(text[0:1])
```

```output
3 bytes
loom: trap: string slice splits a UTF-8 sequence [string_boundary]
    at main (main.luc:4:5)
```

`find_byte(byte, start)` is a primitive for the same reason `byte_at`
is: the library builds substring search on it, and the runtime is free
to vectorize it.

## Interpolation

An `f"..."` string splices expressions written in `{...}`, each one
converted with `str(...)`.

```luce run
struct User:
    name: String
    age: Int

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

A hole is one expression, and `"..."` strings nested inside a hole are
fine. `f"..."` desugars to plain `+` concatenation of `str(...)`
pieces, so the result is a `String` like any other. A `List` in a hole
is a type error — `str` takes `Int`, `Float`, `Bool`, `String` and
`Builder`.

## The strings module

`import std.strings` brings in everything else. The familiar method
spelling is sugar for it: with the import in scope, `s.find(x)` *is*
`strings.find(s, x)`. Without the import, using a String method is a
compile error that says so.

```luce run
import std.strings

func main():
    let line = "  the quick brown fox  "
    let trimmed = line.trim()
    print(f"[{trimmed}]")
    print(f"upper: {trimmed.upper()}")
    print(f"contains 'quick': {trimmed.contains("quick")}")
    print(f"find 'brown': {trimmed.find("brown")}")
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

All offsets are byte offsets, like the primitives, and the module
never splits a UTF-8 character: it slices at ASCII positions or at
match positions of valid UTF-8 needles.

`split` with an empty separator splits on runs of whitespace and drops
the empty pieces, which is Python's `split()`; with a real separator
it keeps them.

## Conversions

```luce run
func main():
    print(str(42))
    print(str(2.5))
    print(str(true))
    print(chr(955))              # a codepoint becomes a String
    print(str(ord("λ")))         # and back
```

```output
42
2.5
true
λ
955
```

`parse_int` and `parse_float` are different: they may find no number
at all, so they answer an *optional*. That is the
[next chapter but one](../absence/).

## Why strings work this way

Strings being values rather than objects is the reason a Luce program
can loop forever building text without growing: a `String`'s bytes
have exactly one owner, and any store into something that outlives the
current statement copies them. Strings of 22 bytes or fewer live
inside the value that carries them and allocate nothing at all.
[Strings and copies](/guide/strings/) is the long version, including
the one benchmark this costs.
