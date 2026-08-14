# Traps and errors

Luce has three outcomes for an operation that cannot produce its normal
value:

| Outcome | Meaning | Syntax |
|---|---|---|
| Trap | A deterministic program or runtime fault. The run stops. | `trap(...)`, failed bounds/checks, unavailable host services |
| Error | An operation failed because the outside world or the program reported a reason. It can be propagated or handled. | `-> T!`, `try`, `catch`, `error(...)` |
| Absence | No value is available and there is no failure reason. | `T?`, `none`, `else` |

This distinction is part of the type checker. A fallible call must be
handled; an optional value must be narrowed or given a fallback.

## Traps

Traps carry a stable code. Debug builds also report the source location
and call trace; `--release` keeps the code, message, and function names
but omits source lines. A trap ends the run and does not enter a `catch`
handler.

### The codes

| Code | Message | Raised when |
|---|---|---|
| `integer_overflow` | integer overflow | Checked `int` or `long` arithmetic leaves its width. |
| `divide_by_zero` | division by zero | Integer `//` or `%` has a zero divisor. Real `/` is IEEE and does not trap. |
| `conversion_range` | conversion out of range | An explicit conversion cannot represent its input. |
| `assertion_failed` | assertion failed | `assert(false)` runs. |
| `explicit_trap` | explicit trap | `trap(message)` runs. |
| `missing_return` | function ended without returning a value | A defensive MIR check reaches a function that ended without a value. Correct source is rejected earlier. |
| `call_depth_exceeded` | call depth exceeded | The call-depth budget is exhausted. |
| `string_bounds` | string index out of bounds | A string index or slice endpoint is outside the string. |
| `string_boundary` | string slice splits a UTF-8 sequence | A string slice splits a UTF-8 code point. |
| `host_unavailable` | host service unavailable | A requested host service is not implemented. |
| `index_bounds` | index out of bounds | A list or array index is outside the collection. |
| `key_missing` | key not found in map | Map indexing (`m[k]`) names an absent key. `m.get(k)` returns `none` instead. |
| `empty_collection` | pop from an empty list | `pop()` runs on an empty list. |
| `use_after_free` | object used after free | An alias or resource handle is used after its owner released it. |
| `null_object` | null object reference | An unfilled container or resource slot is used. |
| `bad_codepoint` | invalid character code | `chr` receives an invalid Unicode scalar, or `append_ascii` receives a value outside 0..127. |
| `not_owned` | object is owned by a container | A forged/damaged module attempts an ownership operation without an owner. The compiler cannot emit this path. |
| `shift_out_of_range` | shift count out of range | A shift count is negative or at least the operand width. |
| `allocation_failed` | not enough memory for this container | The allocator cannot create container or resource storage. |
| `immutable_object` | constant container is immutable | A write reaches a file-scope constant container through hidden provenance. |
| `ownership_cycle` | attempted store would create an ownership cycle | A retaining store would put an owner inside itself or one of its descendants. |

`use_after_free`, `null_object`, `not_owned`, and `allocation_failed`
use the runtime's broad *object* wording; the handles may also be a
`file` or `task`. `not_owned` is retained as a loader/IR defense and is
not reachable from a correctly compiled source program.

```luce trap
func main():
    var xs = [1, 2, 3]
    print("before")
    print(string(xs[7]))
```

```output
before
loom: trap: index out of bounds [index_bounds]
    at main (main.luc:4:5)
```

## Errors

Errors have one of two stable codes:

| Code | Source |
|---|---|
| `io_failed` | A host file operation failed. |
| `user_error` | `error(message)` was called. |

There are no typed error sets or error payloads beyond the message.
The host deliberately does not split `io_failed` into invented
`not_found` and `permission_denied` cases.

### Declaring, raising, propagating, handling

`-> T!` marks a function that returns `T` or raises an error. `-> !`
marks a function that returns no value or raises. `T!` is not a type.

`error(message)` raises `user_error` and never returns. `try CALL`
propagates the error to the caller, which must itself be fallible; the
current frame's owned values are released as it unwinds ([S4](../ownership/#s4)).

`catch` has these forms:

```
EXPR catch FALLBACK
CALL catch:
    ...
CALL catch NAME:
    ...
left, right = try read_pair()
left, right = read_pair() catch reason:
    print(reason)
```

The block form guards exactly one call. It can follow a call statement,
a single-place assignment, or an existing-name multi-return assignment.
On a successful multi-return assignment all replacement stores happen;
on failure none do. Side effects from evaluating the call are not rolled
back. `catch VALUE` supplies one value and cannot supply a return shape.

`NAME` is an immutable `string` scoped to the handler. It contains the
error message, not its code or source location. The expression form
does not bind a name. A fallible call with neither `try` nor `catch` is
`luce.sema.fallible`.

### The report

An uncaught error from `main() -> !` ends the run. The host reports the
message, code, and the one raise location (not a stack of error frames).

```luce raise
func check(n: long) -> long!:
    if n < 0:
        error(f"negative: {n}")
    return n

func main() -> !:
    print(string(try check(1)))
    print(string(try check(-5)))
```

```output
1
loom: error: negative: -5 [user_error]
    raised in check (main.luc:3:9)
```

There is no `errdefer`. Scope ownership already releases values on
`return` and `try`; an error path needs no second cleanup mechanism.

## Absence

`T?` means that a value may be absent. `none` is the only absent value.
It carries no error code or message. `parse_int` and `parse_float` use
this form, as do the standard-library functions whose only unsuccessful
case is an empty input (for example, `math.mean`).

`a else b` yields the payload of `a` when present and evaluates `b`
otherwise. Unlike a fallible call, an optional expression does not need
`try` or `catch`; it needs a narrowing test or `else`.
