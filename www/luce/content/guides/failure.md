# Traps are bugs, errors are news

Luce has three ways to say that an operation did not produce a value:

| Shape | Use it when | What the caller writes |
|---|---|---|
| `T?` | the only result is absence | `value else fallback` |
| `T!` or `!` | the outside world may refuse a valid request | `try` or `catch` |
| trap | the program violated a checked precondition | fix the call or let the diagnostic stop it |

The useful test is: **could the caller have prevented this with a check
that is not racy?** If yes, the operation traps. If the answer depends on a
file, terminal, clock, or another process, it is an error. If there is no
reason to carry and the result is simply missing, return an optional.

Examples:

- `xs[i]` with an invalid index and `m[key]` for a missing key are traps.
- A file read can fail after any prior check, so `files.read` returns
  `string!`.
- `parse_int("abc")` returns `long?`: the text is not a number, and the
  absence already says what the caller needs to know.
- `math.mean` returns `double?` for an empty array.

The complete trap and error vocabulary is in the [failure reference](/reference/failure/).

## Propagate a failure with `try`

The caller of a fallible function must handle its result. `try` returns from
the current function when the call fails and passes the error to that
function's caller. A function that can let an error escape declares `!`:

```luce run
func read_number(text: string) -> long!:
    let number = parse_int(text) else error("not a number")
    return number

func main() -> !:
    print(string(try read_number("42")))
```

```output
42
```

`try` also releases objects owned by the current scope before it leaves.
The returned value, when there is one, is moved to the caller; an error
returns no value.

## Handle one call with `catch`

The expression form supplies a fallback value:

```luce run
func read_number(text: string) -> long!:
    let number = parse_int(text) else error("not a number")
    return number

func main():
    let good = read_number("42") catch 0
    let bad = read_number("hello") catch 0
    print(f"{good} {bad}")
```

```output
42 0
```

The block form handles a statement. It may bind the error message with a
name, and the handler covers exactly the call before `catch`:

```luce run
func read_number(text: string) -> long!:
    let number = parse_int(text) else error("not a number: " + text)
    return number

func main():
    read_number("hello") catch reason:
        print(reason)
```

```output
not a number: hello
```

The bound `reason` is an immutable `string` scoped to the handler. Luce has
no typed error payload: branch on the data you have before making a fallible
call, or handle the message at the boundary where it is useful.

## `T!` is a function property

`T!` is not a type that can be stored in a variable, list, map, or struct.
The `!` belongs on a function's return declaration. A successful
`return value` returns `value` directly; a failed call carries an error
through `try` or `catch`.

There are two error codes today: `io_failed` for host file operations and
`user_error` for `error(...)`. The message is the useful payload. An
uncaught error reports that message and the place where it was raised; a
trap reports its stable code, source location, and call trace because a trap
is a programming bug.

## Keep the distinction visible

Do not turn a fallible file operation into a racy pre-check:

```luce run
import std.files

func main() -> !:
    let text = files.read("notes.txt") catch "(missing or unreadable)"
    print(text)
```

```output
(missing or unreadable)
```

The `catch` is the recovery point. If the file disappears between an
`exists` check and `read`, the read still reports its own result. See
[`std.files`](/library/files/) for the file API and [Failure in the reference](/reference/failure/)
for every trap code.
