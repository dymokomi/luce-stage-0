# Error Handling

An operation that does not produce its normal value has one of three
shapes. Choose the shape from what the caller needs to know.

| Shape | Meaning | Caller response |
|---|---|---|
| `T?` | The value is absent | Narrow it or use `else` |
| `T!` or `!` | A valid request can fail | Propagate with `try` or handle with `catch` |
| trap | The program broke a checked rule | Fix the program |

The useful test is whether the caller could have prevented the result with
a non-racy check. A bad index is a trap. A file read is fallible because the
file can change after any check. Parsing returns an optional when absence
already carries all the information the caller needs.

An error is therefore a failure a correct program can encounter anyway. A
`-> T!` says a call may raise one; `try` passes it up and `catch`
handles it here.

```luce run
func parse_port(text: str) -> i64!:
    let n = parse_int(text) else error(f"not a number: {text}")
    if n < 1 or n > 65535:
        error(f"port out of range: {n}")
    return n

func main() -> !:
    print(str(try parse_port("8080")))
    print(str(parse_port("nope") catch -1))
    print(str(parse_port("99999") catch -1))
```

```output
8080
-1
-1
```

## Propagating with `try`

`try` releases what this frame owns and leaves — exactly what `return`
does, with one terminator changed. It needs a caller that said `!`.

```luce run
func inner(n: i64) -> i64!:
    if n == 0:
        error("inner refuses zero")
    return 100 // n

func middle(n: i64) -> i64!:
    return try inner(n) + 1

func outer(n: i64) -> i64!:
    return try middle(n) * 2

func main() -> !:
    print(str(try outer(5)))
    print(str(outer(0) catch -1))
```

```output
42
-1
```

Forgetting to say which you meant is a compile error. There is no
spelling that ignores the outcome.

```luce fail
func risky() -> i64!:
    error("no")

func main():
    risky()
```

```output
luce: compile failed
main.luc:5:5: risky can fail: write 'try risky(…)' to pass the error on, or 'risky(…) catch …' to handle it [luce.sema.fallible]
        risky()
        ^~~~~~~
```

## Handling with `catch`

`catch EXPR` supplies a value. `catch:` opens a handler block, and it
guards exactly one call — there is never a question about which
statement failed.

```luce run
import std.files

func main() -> !:
    let text = files.read("absent.txt") catch "(default contents)"
    print(text)

    files.write("/nowhere/x", "data") catch:
        print("the write did not land")

    var greeting = "unset"
    greeting = files.read("absent.txt") catch:
        greeting = "(new file)"
    print(greeting)
```

```output
(default contents)
the write did not land
(new file)
```

The block form can bind the error message. The binding is an immutable
`str` scoped to the handler:

```luce run
func parse_count(text: str) -> i64!:
    let value = parse_int(text) else error("not a count: " + text)
    return value

func main():
    parse_count("many") catch reason:
        print(reason)
```

```output
not a count: many
```

Luce does not have typed error payloads. Branch on known data before the
call, or handle the message at the boundary where it is useful.

## Uncaught errors

Out of `main() -> !` it ends the run, and loom prints the words and
the one place it was raised. One line, not a stack: a trap is a bug
and the stack is its diagnosis, but an error is news and where it came
from is the news.

```luce raise
func check(value: i64) -> i64!:
    if value > 100:
        error(f"{value} is too large")
    return value

func main() -> !:
    print(str(try check(50)))
    print(str(try check(500)))
```

```output
50
loom: error: 500 is too large [user_error]
    raised in check (main.luc:3:9)
```

## Traps

A trap is deterministic, has a stable code, and stops the program. Debug
builds show the source location and call trace from the machine code you
ship.

```luce trap
func read_third(values: list[i64]) -> i64:
    return values[2]

func main():
    let values: list[i64] = [10]
    print(str(read_third(values)))
```

```output
loom: trap: index out of bounds [index_bounds]
    at read_third (main.luc:2:5)
    at main (main.luc:6:5)
```

Checked integer overflow, division by zero, missing map keys, invalid
indexes, UTF-8 boundary violations, failed assertions, and explicit
`trap(message)` calls all trap. Do not catch them as normal control flow.
[Errors and Traps](/guide/reference/failure/) lists every stable code and
the condition that produces it.

## A complete example

`examples/calc/calc.luc` in the repository is a recursive-descent
calculator — an `f64` one, because integer `/` is true division and a pocket
calculator that answers `3` to `7 / 2` is broken. Every way it can be
defeated is a way the *user* defeated it, so the parser says
`-> Step!` and raises with `error(...)`; `try` carries the failure up
through four frames of recursion without a single `if` written for
it.

```luce run include=examples/calc/calc.luc args="2 + 3 * (10 - 4)"
```

```output
2 + 3 * (10 - 4) = 20
```

Give it something it cannot parse and the same program says so, at the
position it gave up:

```luce raise include=examples/calc/calc.luc args="2 + )"
```

```output
loom: error: expected a number at position 4 [user_error]
    raised in Scan.number (calc.luc:55:13)
```
