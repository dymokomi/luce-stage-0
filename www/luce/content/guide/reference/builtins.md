# Built-in Functions and Methods

Luce keeps its built-in surface small. These functions need no import because
they express language operations rather than a library domain. Files,
terminals, clocks, environment variables, windows, and GPU surfaces are
ordinary declarations in the [standard library](/library/); their runtime
implementation names are not visible to programs.

Built-in names are reserved. Method names are not: the receiver already
selects their namespace, so a program may declare its own `append`, `has`, or
`dim` function.

## Free functions

| Signature | Meaning |
|---|---|
| `len(value) -> i64` | Unicode scalars in `str`; bytes in `bytes`; elements in a list, map, builder, or rank-one array; dimension zero for any array |
| `print(text: str)` | writes one line to standard output; requires a host |
| `range(low: i64, high: i64)` | the half-open interval used by `for`; `high` is excluded |
| `assert(condition: bool)` | traps with `assertion_failed` when false |
| `trap(message: str)` | stops the run with `explicit_trap` |
| `error(message: str)` | raises the catchable `user_error` |
| `exit(status: i64)` | ends the hosted run normally with the chosen status |
| `abs(value)` | absolute value of any number; returns the same numeric type |
| `min(a, b) -> T` | the smaller of two numbers of the same type |
| `max(a, b) -> T` | the larger of two numbers of the same type |
| `clamp(value, low, high) -> T` | confines a number to inclusive bounds of the same type |
| `sqrt(value) -> T` | square root of `f16`, `f32`, or `f64`; returns the same width |
| `floor(value) -> T` | rounds a float toward negative infinity, at the same width |
| `ceil(value) -> T` | rounds a float toward positive infinity, at the same width |
| `trunc(value) -> T` | rounds a float toward zero, at the same width |
| `parse_i64(text: str) -> i64?` | `none` when the text is not an integer |
| `parse_f64(text: str) -> f64?` | `none` when the text is not a number |
| `parse_str(data: bytes) -> str?` | decoded text, or `none` for invalid UTF-8 |

The type names are also explicit constructors: `u8(x)`, `u16(x)`, `u32(x)`,
`u64(x)`, `i8(x)`, `i16(x)`, `i32(x)`, `i64(x)`, `f16(x)`, `f32(x)`,
`f64(x)`, `char(x)`, `str(x)`, and `bytes(x)`. Numeric narrowing checks range;
float narrowing rounds to nearest with ties to even. See [Types](../types/).

The polymorphic numeric functions use the surrounding type for literals:

```luce run
func main():
    let root: f32 = sqrt(4.0)
    print(str(abs(-7)))
    print(str(min(3, 9)) + " " + str(max(3, 9)))
    print(str(clamp(42, 0, 10)))
    print(str(root))
    print(str(parse_i64("17") else -1))
```

```output
7
3 9
10
2
17
```

`print` and `exit` are the only host-facing prelude functions. Everything
else supplied by a host is namespaced:

- [`std.files`](/library/files/) for paths, text, bytes, and open files
- [`std.os`](/library/os/) for input, standard error, clocks, environment,
  terminal access, shell commands, and machine facts
- [`std.ui`](/library/ui/) and [`std.gpu`](/library/gpu/) for windows and
  drawing surfaces

## list[T]

| Method | Meaning |
|---|---|
| `append(value)` | adds one element |
| `extend(other)` | appends every element of another list of the same type, in order; the source is unchanged, and a list extended with itself gains exactly one round of itself |
| `insert(index, value)` | inserts before `index` |
| `remove(index)` | removes the element and releases references it held |
| `pop() -> T` | removes and returns the last element; traps when empty |
| `clear()` | removes every element |
| `sort()` | stable in-place ordering for ordered element types |
| `sort_by(before)` | stable in-place ordering using a function or closure; requires `std.lists` |
| `reverse()` | reverses in place |
| `find(value) -> i64?` | index of the first match, or `none` |
| `contains(value) -> bool` | whether any element equals `value` |

Lists also support `len(xs)`, indexing, assignment, and slicing. A slice is a
new outer list; referenced elements remain shared under ARC.

## map[K, V]

| Method | Meaning |
|---|---|
| `has(key) -> bool` | whether the key exists |
| `get(key) -> V?` | the value or `none`; never traps for absence |
| `remove(key)` | removes the key; absence is a no-op |
| `keys() -> list[K]` | a fresh list of keys |
| `values() -> list[V]` | a fresh outer list of values |
| `clear()` | removes every entry |

`m[key]` traps with `key_missing` when absent. Assignment inserts or updates.

## array[T, ...]

| Method | Meaning |
|---|---|
| `dim(axis) -> i64` | size of one axis |
| `fill(value)` | fills every element at any rank; value elements only |
| `sort()` | stable in-place ordering; rank one only |
| `reverse()` | reverses a rank-one array |
| `find(value) -> i64?` | first matching index; rank one only |
| `contains(value) -> bool` | whether a rank-one array contains the value |

```luce run
func main():
    var grid = array[i64](2, 3)
    grid.fill(7)
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[1, 2]}")
```

```output
2 by 3, corner 7
```

## builder

| Method | Meaning |
|---|---|
| `append(text: str)` | appends text |
| `append_ascii(code: i64)` | appends one ASCII byte; traps outside 0...127 |
| `build() -> str` | returns the text so far; the builder remains usable |
| `clear()` | removes accumulated text |

A builder also supports `len(value)`. Use `build()` rather than `str(value)`
to obtain its text.

## task

| Method | Meaning |
|---|---|
| `wait()` | joins once and returns the worker's result; fallible when the worker is fallible |

Releasing the last reference to an unwaited task joins it and discards its
answer. See [Concurrency](/guide/concurrency/).

## channel

| Method | Meaning |
|---|---|
| `send(v)` | fallible; blocks while full; a closed channel is the `channel_closed` error |
| `try_send(v) -> bool` | fallible; false instead of waiting on a full queue |
| `receive() -> T` | fallible; blocks while empty; drains a closed channel first, then errors |
| `try_receive() -> T?` | fallible; `none` when nothing is parked right now |
| `receive_timeout(ms) -> T?` | fallible; `none` when the wait ran out |
| `receive_by(expires_ms) -> T?` | fallible; the deadline form — `expires_ms` is a moment on `os.clock_ms`'s clock, and the wait takes what is left of it; `none` once it has passed |
| `close()` | idempotent; any holder may close |
| `len() -> i64` | values parked right now — a snapshot |
| `cap() -> i64` | the bound construction chose |

`send` parks a deep copy and `receive` rebuilds it in the receiver, so
mutating a value after sending it is always safe. See
[Concurrency](/guide/concurrency/) and the
[types reference](/guide/reference/types/#channel).

## str

The language keeps only the operations needed to represent and inspect text:

| Operation | Meaning |
|---|---|
| `+` and comparisons | concatenation, equality, and scalar ordering |
| `value[index] -> char` | Unicode scalar at a scalar index |
| `value[start:end]` | scalar-indexed slice |
| `len(value)` | Unicode scalar count |
| `value.byte_at(index) -> u8` | raw UTF-8 byte at a byte index |
| `value.find_byte(value, start) -> i64` | raw byte offset or `-1` |

Every higher-level string operation lives in
[`std.strings`](/library/strings/) and requires `import std.strings`.

```luce run
func main():
    let text = "hello, Luce"
    print(f"{len(text)} scalars")
    print(text[7:11])
    print(str(text.byte_at(0)))
    print(str(text.find_byte(44, 0)))
```

```output
11 scalars
Luce
104
5
```
