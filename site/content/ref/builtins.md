# Builtins

Two kinds. **Free functions** are the generic, cross-type set — the
split Python makes. **Methods** belong to one type and are called on
it; the method spelling is sugar for a plain function with the
receiver first, resolved by the receiver's type, not dispatched.

## Free functions

| Signature | Notes |
|---|---|
| `len(x) -> Int` | `String` bytes; list, map, builder or rank-1 array length; an `Array`'s dimension 0 |
| `str(x) -> String` | `Int`, `Float`, `Bool`, `String`, `Builder`. Anything else is a type error |
| `print(text: String)` | host-gated |
| `range(low: Int, high: Int)` | `for` only; excludes `high` |
| `assert(condition: Bool)` | traps `assertion_failed` |
| `trap(message: String)` | never returns; traps `explicit_trap` |
| `error(message: String)` | never returns; raises `user_error` |
| `free(x)` | early release of an owned object; poisons the name |
| `abs(x)` | `Int` or `Float` |
| `min(a, b)`, `max(a, b)` | `Int` or `Float`, both the same |
| `clamp(x, low, high)` | |
| `sqrt(x: Float) -> Float` | |
| `floor(x: Float) -> Float`, `ceil(x: Float) -> Float` | |
| `chr(code: Int) -> String` | traps `bad_codepoint` on an invalid codepoint |
| `ord(text: String) -> Int` | first codepoint; traps on empty |
| `parse_int(text: String) -> Int?` | `none` when the text is not an integer |
| `parse_float(text: String) -> Float?` | `none` when the text is not a number |
| `Int(x)`, `Float(x)` | the only numeric conversions; `Int` traps outside range |

```luce run
func main():
    print(str(abs(-7)))
    print(str(min(3, 9)) + " " + str(max(3, 9)))
    print(str(clamp(42, 0, 10)))
    print(str(sqrt(2.0)))
    print(str(floor(-2.5)) + " " + str(ceil(-2.5)))
    print(chr(9731))
    print(str(ord("A")))
    print(str(parse_int("17") else -1))
    print(str(parse_float("nope") else -1.0))
```

```output
7
3 9
10
1.4142135623730951
-3 -2
☃
65
17
-1
```

## Host builtins

Every one of these is gated. In a program compiled without host
access, naming one is `luce.sema.host`. At run time a service the host
does not implement traps `host_unavailable` rather than doing nothing.

| Signature | Notes |
|---|---|
| `print(text: String)` | |
| `file_read(path: String) -> String!` | fallible |
| `file_write(path: String, text: String) -> !` | fallible |
| `file_exists(path: String) -> Bool` | a question about the past, not a guard |
| `arg(index: Int) -> String` | traps `argument_bounds` outside the range |
| `arg_count() -> Int` | |
| `term_rows() -> Int`, `term_cols() -> Int` | |
| `term_clear()`, `term_move(row, column)` | |
| `term_style(foreground, background, bold)` | |
| `term_write(text: String)` | sanitized; a program cannot emit a control sequence |
| `term_flush()` | |
| `key_read() -> String` | presents the pending frame, then blocks; returns a stable name |
| `key_text() -> String` | the payload when the last `key_read` returned `"text"` |

`std.files` is the layer you should normally use over the three file
builtins.

**Paths are not confined.** A program may name any path the process
itself can — relative paths resolve against the working directory it
was started in, and `../` and absolute paths mean what they mean
everywhere else. That is deliberate: loom runs programs the way a
shell runs processes, the gate above decides whether a program may
reach the world at all, and the operating system decides which files.
A path prefix enforced in the host would be a third mechanism that
looks like security and is not. `file_read` does have a size ceiling —
64 MiB, a host policy so one call cannot ask for the machine's memory —
and a larger file answers the same failure as an unreadable one.

## List(T)

| Method | Notes |
|---|---|
| `append(value)` | |
| `insert(index, value)` | |
| `remove(index)` | frees an owned element |
| `pop() -> T` | ownership moves out; traps `empty_collection` when empty |
| `sort()` | in place, **stable**, O(n log n); `Int`, `Float` or `String` elements |
| `reverse()` | in place |
| `find(value) -> Int` | `-1` when absent |
| `contains(value) -> Bool` | |
| `clear()` | frees all owned elements |

Plus `len`, `xs[i]`, `xs[i] = v`, and `xs[a:b]` — which allocates a
new list the receiver owns, deeply when the elements are objects.

## Map(K, V)

| Method | Notes |
|---|---|
| `has(key) -> Bool` | |
| `get(key, default) -> V` | never traps |
| `remove(key)` | a no-op when absent |
| `keys() -> List(K)` | a fresh list the receiver owns |
| `values() -> List(V)` | a fresh list the receiver owns |
| `clear()` | |

Plus `len`, `m[k]` — which traps `key_missing` when the key is
absent — and `m[k] = v`, which inserts or updates.

## Array(T, ...)

| Method | Notes |
|---|---|
| `dim(axis) -> Int` | the size of one axis |
| `fill(value)` | rank-1, **value elements only** |
| `sort()`, `reverse()`, `find(v)`, `contains(v)` | rank-1 only |

Plus `len` (dimension 0), `a[i]`, `grid[r, c]` up to four indices, and
index assignment.

## Builder

| Method | Notes |
|---|---|
| `append(text: String)` | |
| `append_ascii(code: Int)` | one ASCII byte; traps `bad_codepoint` outside 0..127 |
| `clear()` | |

Plus `len` and `str(builder)`.

## String

The language keeps only these:

| Operation | Notes |
|---|---|
| `"..."`, `f"..."` | literals |
| `+` | concatenation |
| `== != < <= > >=` | comparison and ordering |
| `s[a:b]` | slice; checks UTF-8 boundaries |
| `len(s)` | in bytes |
| `s.byte_at(index) -> Int` | raw byte |
| `s.find_byte(byte, start) -> Int` | offset of the first `byte` at or after `start`, or `-1`; traps if `byte` is outside 0..255 or `start` is outside the string |

Every other String method routes to [`std.strings`](/std/strings/) and
needs `import std.strings` in scope.

```luce run
func main():
    let s = "hello, loom"
    print(f"{len(s)} bytes")
    print(s[7:11])
    print(str(s.byte_at(0)))
    print(str(s.find_byte(44, 0)))
    print(str(s.find_byte(122, 0)))
```

```output
11 bytes
loom
104
5
-1
```
