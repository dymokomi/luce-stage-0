# Failure

A function whose result type ends in `!` may return a value or fail. For
example, `string!` means a string-or-error result and `-> !` means no value
or an error. `?` is different: it represents ordinary absence.

## Choosing the failure kind

Luce separates two questions:

- A **trap** is a program bug: a deterministic precondition was violated.
- An **error** is an event a correct program may encounter, such as a file
  service refusing an operation.

Absence without a reason to carry is `T?`. The [failure reference](/guide/reference/failure/)
lists the stable trap and error codes.

## `try` and `catch`

The caller must handle every fallible call. `try` passes its error to a
fallible caller. `catch` handles it at the call site.

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

```luce run
import std.files

func save(path: string, text: string) -> !:
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

    files.write("/nowhere/at/all", "x") catch reason:
        print(reason)
```

```output
wrote notes.txt
read back: hello, disk
missing: (nothing)
could not write to /nowhere/at/all
cannot write /nowhere/at/all
```

The expression form supplies a fallback value. The block form handles one
call, and `catch reason:` binds the error message for that handler.

## Raising an error

`error(text)` stops the current function with a `user_error`. It can be used
where a value would otherwise be required:

```luce run
func check(n: long) -> long!:
    if n < 0:
        error(f"negative: {n}")
    return n

func main() -> !:
    print(string(try check(5)))
    let fallback = check(-1) catch 0
    print(f"fallback {fallback}")
```

```output
5
fallback 0
```

Fallibility belongs to a function signature, not to a value type. There is
no `T!` variable type and a fallible result cannot be put in a list:

```luce fail
func main():
    var results: list(long!) = []
    print(string(len(results)))
```

```output
luce: compile failed
main.luc:2:27: expected ')' to close '(', found '!' [luce.parse.expected]
        var results: list(long!) = []
                              ^
```

## Uncaught failures

An uncaught error from `main() -> !` reports its message and origin:

```luce raise
func main() -> !:
    error("the disk is on fire")
```

```output
loom: error: the disk is on fire [user_error]
    raised in main (main.luc:2:5)
```

A trap reports a call trace because it identifies a programming bug:

```luce trap
func inner(values: list(long)) -> long:
    return values[9]

func outer(values: list(long)) -> long:
    return inner(values)

func main():
    var values: list(long) = [1, 2, 3]
    print(string(outer(values)))
```

```output
loom: trap: index out of bounds [index_bounds]
    at inner (main.luc:2:5)
    at outer (main.luc:5:5)
    at main (main.luc:9:5)
```

The runtime currently exposes two error codes: `io_failed` for host I/O and
`user_error` for `error(...)`. Ownership releases resources while a function
returns or propagates an error; there is no `errdefer` construct.

Next: [Modules](/guide/language/modules/).
