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

Each one's shape is a decision about what kind of fact it reports.
A service the world can say no to answers `!`; a service that can only
report "there is nothing there" answers `T?`; a service that cannot
fail answers a plain value. See [traps and errors](../failure/).

### Console

| Signature | Notes |
|---|---|
| `print(text: String)` | a line to standard output, unsanitized — it is the program's own channel and may be a pipe |
| `print_error(text: String)` | a line to standard error, **always sanitized**: that channel is shared with the runner, so a program may not scribble on a frame it does not own |
| `read_line(prompt: String) -> String?` | writes the prompt, reads one line without its newline; `none` at end of input. Hands the terminal back its line discipline first, so a line read and a raw key loop never fight over standard input |

End of input is absence, not failure — nothing went wrong, there is
just nothing more — so `read_line` answers `T?` and
`read_line("> ") else ""` is the whole handling.

### Arguments and environment

| Signature | Notes |
|---|---|
| `arg(index: Int) -> String` | traps `argument_bounds` outside the range |
| `arg_count() -> Int` | |
| `env(name: String) -> String?` | one environment variable; `none` when it is unset. There is no setter and no way to read the whole environment |

### The clock

| Signature | Notes |
|---|---|
| `clock_ms() -> Int` | a **monotonic** reading in milliseconds; only differences mean anything, and it is not a wall clock or a calendar |
| `sleep_ms(milliseconds: Int)` | waits at least that long; presents the pending frame first, as `key_read` does |

Neither can fail, and that is deliberate for `sleep_ms`: a duration
that has **already elapsed** — zero, or the negative left by
`deadline - clock_ms()` when a frame overran — is not a bug and not a
failure. There is no time left to wait, so it returns at once. An
animation loop can subtract without guarding.

```luce run
func main():
    let started = clock_ms()
    sleep_ms(0)
    sleep_ms(-40)
    print(f"an overrun frame waits {clock_ms() - started} ms")
```

```output
an overrun frame waits 0 ms
```

### Files

| Signature | Notes |
|---|---|
| `file_read(path: String) -> String!` | the whole file; 64 MiB ceiling |
| `file_write(path: String, text: String) -> !` | truncates or creates |
| `file_append(path: String, text: String) -> !` | adds to the end, creating the file if it is not there |
| `file_delete(path: String) -> !` | an absent path is `io_failed`, not a quiet success |
| `file_rename(from: String, to: String) -> !` | moves a file, **replacing** an existing target — which is what makes write-then-rename the way to replace a file without ever leaving half of one on disk |
| `file_exists(path: String) -> Bool` | a question about the past, not a guard |
| `dir_list(path: String) -> List(String)!` | the names in a directory — plain names, not paths, without `.` and `..`, in whatever order the file system gave them. A fresh list the caller owns |

Every one that changes a file is fallible, because the world decides
whether it lands. `file_exists` is the exception and answers a plain
`Bool` — but it is a question about the past, never a guard for the
call after it.

### The terminal

| Signature | Notes |
|---|---|
| `term_rows() -> Int`, `term_cols() -> Int` | |
| `term_clear()`, `term_move(row, column)` | |
| `term_style(foreground, background, bold)` | 256-color SGR; `-1` is the default |
| `term_write(text: String)` | sanitized; a program cannot emit a control sequence |
| `term_flush()` | |
| `key_read() -> String` | presents the pending frame, then blocks; returns a stable name |
| `key_text() -> String` | the payload when the last `key_read` returned `"text"` |

`std.files` is the layer you should normally use over the file
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
| `fill(value)` | every element at any rank; **value elements only** |
| `sort()`, `reverse()`, `find(v)`, `contains(v)` | rank-1 only |

Plus `len` (dimension 0), `a[i]`, `grid[r, c]` up to four indices, and
index assignment.

`dim` and `fill` are the two that work at every rank; the rest need a
single axis to mean anything.

```luce run
func main():
    var grid = new Array(Int, 2, 3)
    grid.fill(7)
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[1, 2]}")
```

```output
2 by 3, corner 7
```

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
