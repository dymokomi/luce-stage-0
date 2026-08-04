# Failure

A trailing `!` on a return type says the call may not succeed.
`String!` hands back a `String` **or** an error, and a bare `-> !`
hands back nothing or an error.

`!` means failure and only failure. It is never spent on absence,
which is [`?`'s job](../absence/).

## The rule that decides

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not
> the program. Everything else is a trap.
>
> **Traps are bugs. Errors are news.**

Operationally: could the caller have prevented it with a check that is
not racy? If yes, it is a trap, and the check is the program's job. If
the check is inherently racy or impossible, it is an error. And if the
answer is simply "there is nothing there", with no reason worth
carrying, it is neither — it is a `T?`.

That rule left all but one of Luce's trap codes exactly where they
were. What it moves is the host's file boundary: a read or a write the
world refuses is an error, because `file_exists` before `file_read` is
a race no program can close. There are
[18 trap codes](/ref/failure/#the-codes) and two error codes.

## try and catch

A call that can fail must say which it means. Ignoring the outcome is
not a spelling the grammar has.

```luce fail
import std.files

func main():
    files.write("notes.txt", "hello")
```

```output
luce: compile failed
main.luc:4:5: files.write can fail: write 'try files.write(…)' to pass the error on, or 'files.write(…) catch …' to handle it [luce.sema.fallible]
        files.write("notes.txt", "hello")
        ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

`try` passes the failure to your caller. It needs a caller that said
`!`, and it releases what this frame owns on the way out — the same
three lines `return` ends with, with one terminator changed.

`catch` handles it here, and deliberately discards the reason. It
has two forms, for the two shapes recovery takes.

```luce run
import std.files

func save(path: String, text: String) -> !:
    try files.write(path, text)
    print(f"wrote {path}")

func main() -> !:
    try save("notes.txt", "hello, disk")

    let read_back = files.read("notes.txt") catch "(nothing)"
    print(f"read back: {read_back}")

    let missing = files.read("no-such-file") catch "(nothing)"
    print(f"missing: {missing}")

    files.write("/nowhere/at/all", "x") catch:
        print("could not write to /nowhere/at/all")
```

```output
wrote notes.txt
read back: hello, disk
missing: (nothing)
could not write to /nowhere/at/all
```

The block form guards exactly **one** call, which is what separates it
from an exception block: there is never a question about which
statement failed. It attaches to a call written as a statement and to
a plain assignment, and to nothing else.

`catch` binds like `else`, between the comparisons and `+`, and
associates right. Both sides must agree on ownership: if the call
hands over a fresh object, the fallback must too.

## error raises, with your own words

```luce run
func check(n: Int) -> Int!:
    if n < 0:
        error(f"negative: {n}")
    return n

func main() -> !:
    print(String(try check(5)))
    let fallback = check(-1) catch 0
    print(f"fallback {fallback}")
```

```output
5
fallback 0
```

`error(...)` never comes back, so — like `trap(...)` — it may stand
where a value belongs: `parse_int(digits) else error("not a number")`.

## T! is not a type

Fallibility is an attribute of the *function*. There is no `T!` to
declare a variable of, put in a `List`, or write in a struct field —
and `return x` in a `-> T!` function just returns `x`, with nothing to
wrap it in.

```luce fail
func main():
    var results: List(Int!) = []
    print(String(len(results)))
```

```output
luce: compile failed
main.luc:2:26: expected ')' to close '(', found '!' [luce.parse.expected]
        var results: List(Int!) = []
                             ^
```

## What an uncaught error looks like

An error out of `main() -> !` ends the run. loom prints the words and
the **one** place the error was raised.

```luce raise
func main() -> !:
    error("the disk is on fire")
```

```output
loom: error: the disk is on fire [user_error]
    raised in main (main.luc:2:5)
```

One line, not a stack. A trap is a bug and the stack is its diagnosis;
an error is news, and where it came from is the news. Carrying a full
trace would also charge the *success* path for it.

Compare a trap, which does print the stack:

```luce trap
func inner(values: List(Int)) -> Int:
    return values[9]

func outer(values: List(Int)) -> Int:
    return inner(values)

func main():
    var values = [1, 2, 3]
    print(String(outer(values)))
```

```output
loom: trap: index out of bounds [index_bounds]
    at inner (main.luc:2:5)
    at outer (main.luc:5:5)
    at main (main.luc:9:5)
```

## There are exactly two error codes

`io_failed`, which the host's file services raise, and `user_error`,
which `error(...)` raises. Not `not_found` and `permission_denied` —
a host service answers yes, no, or out of memory, and cannot tell
those two apart, so inventing the codes would be inventing the
distinction.

## There is no errdefer

And there never will be. Luce's cleanup is scope ownership, which
already knows that `return` moves what it hands back and `try` moves
nothing. The one bit `errdefer` encodes is already a parameter of the
unwinder.

[Traps are bugs, errors are news](/guide/failure/) is the long
version, including why `Result<T, E>` is not the shape Luce took.
