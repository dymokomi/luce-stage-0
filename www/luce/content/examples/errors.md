# Errors

An error is a failure a correct program can meet anyway, because the
world decided. A `-> T!` says a call may raise one; `try` passes it up
and `catch` handles it here.

```luce run
func parse_port(text: string) -> long!:
    let n = parse_int(text) else error(f"not a number: {text}")
    if n < 1 or n > 65535:
        error(f"port out of range: {n}")
    return n

func main() -> !:
    print(string(try parse_port("8080")))
    print(string(parse_port("nope") catch -1))
    print(string(parse_port("99999") catch -1))
```

```output
8080
-1
-1
```

## try propagates

`try` releases what this frame owns and leaves — exactly what `return`
does, with one terminator changed. It needs a caller that said `!`.

```luce run
func inner(n: long) -> long!:
    if n == 0:
        error("inner refuses zero")
    return 100 // n

func middle(n: long) -> long!:
    return try inner(n) + 1

func outer(n: long) -> long!:
    return try middle(n) * 2

func main() -> !:
    print(string(try outer(5)))
    print(string(outer(0) catch -1))
```

```output
42
-1
```

Forgetting to say which you meant is a compile error. There is no
spelling that ignores the outcome.

```luce fail
func risky() -> long!:
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

## catch has two forms

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

## An uncaught error

Out of `main() -> !` it ends the run, and loom prints the words and
the one place it was raised. One line, not a stack: a trap is a bug
and the stack is its diagnosis, but an error is news and where it came
from is the news.

```luce raise
func check(value: long) -> long!:
    if value > 100:
        error(f"{value} is too large")
    return value

func main() -> !:
    print(string(try check(50)))
    print(string(try check(500)))
```

```output
50
loom: error: 500 is too large [user_error]
    raised in check (main.luc:3:9)
```

## The worked example

`programs/calc.luc` in the repository is a recursive-descent
calculator — a `double` one, because `/` is real division and a pocket
calculator that answers `3` to `7 / 2` is broken. Every way it can be
defeated is a way the *user* defeated it, so the parser says
`-> Step!` and raises with `error(...)`; `try` carries the failure up
through four frames of recursion without a single `if` written for
it.

```luce run include=programs/calc.luc args="2 + 3 * (10 - 4)"
```

```output
2 + 3 * (10 - 4) = 20
```

Give it something it cannot parse and the same program says so, at the
position it gave up:

```luce raise include=programs/calc.luc args="2 + )"
```

```output
loom: error: expected a number at position 4 [user_error]
    raised in Scan.number (calc.luc:55:13)
```
