# Built-in Functions and Methods

Builtins are compiler-provided functions. A top-level builtin is called by
name. A method is selected from the receiver's static type; method
syntax does not perform dynamic dispatch. Host builtins require a host
enabled compilation and may report `host_unavailable` at run time.

## Free functions

| Signature | Notes |
|---|---|
| `len(value) -> i64` | Unicode scalars in `str`; bytes in `bytes`; elements in a list, map, builder, or rank-1 array; an `array`'s dimension 0 |
| `print(text: str)` | host-gated |
| `range(low: i64, high: i64)` | `for` only; excludes `high` |
| `assert(condition: bool)` | traps `assertion_failed` |
| `trap(message: str)` | never returns; traps `explicit_trap` |
| `error(message: str)` | never returns; raises `user_error` |
| `abs(value)` | any number; answers its operand's type |
| `min(a, b)`, `max(a, b)` | any two numbers of the same type |
| `clamp(value, low, high)` | any three numbers of the same type |
| `sqrt(value)` | `f16`, `f32`, or `f64`, and **the same width back** |
| `floor(value)`, `ceil(value)` | ″ |
| `trunc(value)` | ″; toward zero, and `math.round` is the fourth |
| `parse_int(text: str) -> i64?` | `none` when the text is not an integer |
| `parse_float(text: str) -> f64?` | `none` when the text is not a number |
| `parse_str(data: bytes) -> str?` | decoded text, or `none` when the bytes are not valid UTF-8 |
| `u8(x)`, `u16(x)`, `u32(x)`, `u64(x)`, `i8(x)`, `i16(x)`, `i32(x)`, `i64(x)`, `f16(x)`, `f32(x)`, `f64(x)` | explicit numeric conversions. Float to integer truncates toward zero; integer conversion checks range; float narrowing rounds to nearest, ties to even, and may reach infinity |
| `char(x)`, `str(x)`, `bytes(x)` | checked Unicode scalar conversion, textual rendering, and immutable binary copying |

The numeric builtins that answer their operand's own type land
their arguments where the whole call lands, so `let x: f64 =
sqrt(2.0)` reads `2.0` at binary64 rather than widening binary32's
answer into it. Unannotated, a float literal is an `f64`.

```luce run
func main():
    print(str(abs(-7)))
    print(str(min(3, 9)) + " " + str(max(3, 9)))
    print(str(clamp(42, 0, 10)))
    print(str(sqrt(2.0)))
    let two: f64 = 2.0
    print(str(sqrt(two)))
    print(str(floor(-2.5)) + " " + str(ceil(-2.5)) + " " + str(trunc(-2.5)))
    print(str(i64(2.5)) + " " + str(i64(-2.5)) + " " + str(i64(2.4)))
    print(str(char(9731)))
    print(str(u32('A')))
    print(str(parse_int("17") else -1))
    print(str(parse_float("nope") else -1.0))
```

```output
7
3 9
10
1.4142135623730951
1.4142135623730951
-3 -2 -2
2 -2 2
☃
65
17
-1
```

## Host builtins

All host builtins require host access at compile time. A host that does
not provide a requested service raises `host_unavailable`. Services
whose normal result can be absent use `T?`; operations that can fail use
`!`. See [traps and errors](../failure/).

### Console

| Signature | Notes |
|---|---|
| `print(text: str)` | a line to standard output, unsanitized — it is the program's own channel and may be a pipe |
| `print_error(text: str)` | a line to standard error, **always sanitized**: that channel is shared with the runner, so a program may not scribble on a frame it does not own |
| `read_line(prompt: str) -> str?` | writes the prompt, reads one line without its newline; `none` at end of input. Hands the terminal back its line discipline first, so a line read and a raw key loop never fight over standard input |

At end of input, `read_line` returns `none`; use `read_line("> ") else
""` to supply a fallback.

### Environment

| Signature | Notes |
|---|---|
| `env(name: str) -> str?` | one environment variable; `none` when it is unset. There is no setter and no way to read the whole environment |

The command line is `main`'s optional `list[str]` parameter, not a builtin
([entry forms](../statements/#entry)).

### Shell

| Signature | Notes |
|---|---|
| `shell_run(command: str) -> str!` | runs one command through the host shell, captures standard output and standard error, and appends the exit status. The returned text is a transcript, not a separate status value; quote paths and other arguments for the shell. |

Use [`std.os.shell.run`](/library/os/) for this operation. It is a host
shell interface, not a portable process API. A failed launch is an
`io_failed` error.

### Clocks and sleep

| Signature | Notes |
|---|---|
| `clock_ms() -> i64` | a **monotonic** reading in milliseconds; only differences mean anything, and it is not a wall clock or a calendar |
| `epoch_ms() -> i64` | milliseconds since the Unix epoch — **what time it is**, which the monotonic clock cannot say |
| `sleep_ms(milliseconds: i64)` | waits at least that long; presents the pending frame first, as `key_read` does |

Use `clock_ms` for elapsed-time measurements: subtract two readings.
It is monotonic and has no defined epoch. Use `epoch_ms` for a Unix
timestamp (milliseconds since 1970-01-01T00:00:00Z). It is not a date
formatter. If a host cannot provide a calendar, `epoch_ms` raises
`host_unavailable`. `sleep_ms` returns immediately for zero or negative
durations.

### Exit

| Signature | Notes |
|---|---|
| `exit(status: i64)` | the program's chosen end — the fourth way a run stops, beside finishing, trapping, and an uncaught error. It never returns: the run unwinds, nothing after the call executes, and the host carries the status — on POSIX, the low eight bits of the process's exit code |

`exit` is a normal termination, not a trap or error. It is host-gated;
an unsupported host raises `host_unavailable`.

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

A moment, and a span, told apart by which clock answers them:

```luce run
func main():
    # `epoch_ms` names a moment: this is the number a timestamp is
    # made of, and it means the same thing on every machine.
    let stamped = epoch_ms()
    print("after 2020: " + str(stamped > 1577836800000))
    # `clock_ms` measures a span, and only differences mean anything.
    let started = clock_ms()
    sleep_ms(0)
    print("elapsed is never negative: " + str(clock_ms() >= started))
```

```output
after 2020: true
elapsed is never negative: true
```

### Machine information

| Signature | Notes |
|---|---|
| `os_total_memory() -> i64` | bytes of physical memory the machine has; fixed for the life of the run |
| `os_available_memory() -> i64` | bytes it could still hand out. This one **moves**: ask twice and expect two answers |
| `os_cpu_count() -> i64` | how many processors the host would schedule work onto — logical ones, so simultaneous multithreading counts threads |

These are also exposed by [`std.os`](/library/os/). The values are numbers;
an unsupported host raises `host_unavailable` rather than returning a
made-up value.

### Windows and GPU surfaces

The low-level graphics channel keeps platform handles behind the runtime.
The installed macOS `loom` host provides it with Metal when available and a
CPU-backed window otherwise. Other hosts may leave it unavailable without
changing these signatures.

| Signature | Notes |
|---|---|
| `gpu_backend() -> i64` | backend code: 0 Metal, 1 Vulkan, 2 headless; an unknown code traps |
| `ui_window_open(title: str, width: i64, height: i64) -> file!` | opens an ARC-managed window handle |
| `ui_window_surface(window: file) -> file!` | creates an ARC-managed GPU surface for the window |
| `gpu_surface_size(surface: file, axis: i64) -> i64!` | axis 0 is width, 1 is height |
| `gpu_surface_clear(surface: file, red: i64, green: i64, blue: i64, alpha: i64) -> !` | clears the surface with an RGBA colour |
| `gpu_surface_fill_rect(surface: file, x: i64, y: i64, width: i64, height: i64, red: i64, green: i64, blue: i64, alpha: i64) -> !` | fills a rectangle |
| `gpu_surface_present(surface: file) -> !` | presents the completed surface |

Use [`std.gpu`](/library/gpu/) and [`std.ui`](/library/ui/) rather than these
raw names. They are deliberately small; widgets and layout belong in a
higher-level package.

### Files

| Signature | Notes |
|---|---|
| `file_read(path: str) -> str!` | the whole text file; 64 MiB ceiling |
| `file_write(path: str, content: str) -> !` | truncates or creates |
| `file_append(path: str, content: str) -> !` | adds to the end, creating the file if it is not there |
| `file_delete(path: str) -> !` | an absent path is `io_failed`, not a quiet success |
| `file_rename(from: str, to: str) -> !` | moves a file, **replacing** an existing target — which is what makes write-then-rename the way to replace a file without ever leaving half of one on disk |
| `path_kind(path: str) -> i64!` | what is at the path: 0 nothing, 1 a file, 2 a directory, 3 something else. Links are followed. `!` is the world **refusing to say** — a parent nobody may search — which is a different fact from "nothing is there". You write [`files.kind`](/library/files/), which gives the four codes their names |
| `dir_list(path: str) -> list[str]!` | the names in a directory — plain names, not paths, without `.` and `..`, in whatever order the file system gave them. Returns a fresh list |
| `dir_create(path: str) -> !` | makes a directory **and every directory leading to it**. A directory already there is success; a *file* holding the name is `io_failed` |
| `file_open(path: str, mode: i64) -> file!` | an ARC-managed handle. `mode` is 0 read, 1 write, 2 append — and you write [`files.open`](/library/files/), [`files.create`](/library/files/) or [`files.append_to`](/library/files/) rather than a number |

All file operations are fallible. `path_kind` returns 0 for absence, 1
for a file, 2 for a directory, and 3 for another entry kind; inability
to inspect the path is an error. `dir_create` creates missing parent
directories and succeeds when the target directory already exists.
`file_read` and `file_write` are convenience operations with a 64 MiB
read limit. Use [`std.files`](/library/files/) for higher-level wrappers.

```luce run
import std.files

func main() -> !:
    # One call for the whole path: `store` and `store/packages` are
    # made on the way.
    try files.make_directory("store/packages/geo-1.2.0")
    # And saying it again is success, not an error.
    try files.make_directory("store/packages")
    try files.write("store/packages/geo-1.2.0/luce.json", "{}\n")
    let names = try files.list("store/packages")
    for name in names:
        print(name)
```

```output
geo-1.2.0
```

### Bytes

| Signature | Notes |
|---|---|
| `parse_str(data: bytes) -> str?` | those bytes as text, or absent when they are not valid UTF-8 |

`parse_str` returns `none` for invalid UTF-8. `bytes(text)` is the total
reverse operation.

### Terminal

| Signature | Notes |
|---|---|
| `term_rows() -> i64`, `term_cols() -> i64` | |
| `term_clear()`, `term_move(row, column)` | |
| `term_style(fg, bg = -1, bold = false)` | 256-color SGR; `-1`, the default, is the terminal's own color |
| `term_write(text: str)` | sanitized; a program cannot emit a control sequence |
| `term_flush()` | |
| `key_read() -> str?` | presents the pending frame, then blocks; a stable name, or `none` at end of input |
| `key_text() -> str` | the payload when the last `key_read` returned `"text"` |
| `term_event_data(field: i64) -> i64` | numeric data for the most recent terminal event: row, column, button, modifiers or wheel value; used by `std.os.term.io` |

`key_read` returns `none` when its input reaches end-of-file. Until then
it returns the event name; `key_text` returns the text payload of the
most recent text event. End of input resets that payload to `""`.

```
let name = key_read()
if name == none:
    break
```

`std.files` is the normal higher-level interface for file operations.
Paths are passed to the operating system unchanged: relative paths use
the process working directory, and absolute paths are allowed. The
`file_read` 64 MiB limit still applies.

## list[T]

| Method | Notes |
|---|---|
| `append(value)` | |
| `insert(index, value)` | |
| `remove(index)` | removes the element and releases any reference it held |
| `pop() -> T` | removes and returns the final element; traps `empty_collection` when empty |
| `sort()` | in place, **stable**, O(n log n); ordered numeric, `char`, or `str` elements |
| `sort_by(before: func(T, T) -> bool)` | in place, **stable**, O(n log n); every element type; requires `import std.lists` |
| `reverse()` | in place |
| `find(value) -> i64?` | absence when not found; `xs.find(v) else -1` is the sentinel form |
| `contains(value) -> bool` | |
| `clear()` | removes every element and releases their references |

Plus `len`, `xs[i]`, `xs[i] = v`, and `xs[a:b]` — which allocates a
new outer list, copies value elements, and retains reference elements. The new
list and the source therefore share any referenced objects.
`sort_by` accepts a named function or capture-free lambda. Sorting rearranges
the existing elements without changing their ARC lifetimes.

## map[K, V]

| Method | Notes |
|---|---|
| `has(key) -> bool` | |
| `get(key) -> V?` | absence when missing — never traps; `m.get(k) else d` is the fallback form |
| `remove(key)` | a no-op when absent |
| `keys() -> list(K)` | a fresh list |
| `values() -> list(V)` | a fresh outer list; reference values remain shared |
| `clear()` | |

Plus `len`, `m[k]` — which traps `key_missing` when the key is
absent — `m[k] = v`, which inserts or updates, and `m[k] OP= v`, which
defines a missing key at `V`'s zero value and then applies.

`values()` copies each value into its new list. Container and carrying
struct values are deep-copied, so their complete type graph must be
resource-free.

## array[T, ...]

| Method | Notes |
|---|---|
| `dim(axis) -> i64` | the size of one axis |
| `fill(value)` | every element at any rank; **non-handle value elements only** |
| `sort()`, `reverse()`, `find(v)`, `contains(v)` | rank-1 only |

Plus `len` (dimension 0), `a[i]`, `grid[r, c]` up to four indices, and
index assignment.

`dim` and `fill` are the two that work at every rank; the rest need a
single axis to mean anything.

```luce run
func main():
    var grid = new array[i64](2, 3)
    grid.fill(7)
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[1, 2]}")
```

```output
2 by 3, corner 7
```

## builder

| Method | Notes |
|---|---|
| `append(text: str)` | |
| `append_ascii(code: i64)` | one ASCII byte; traps `bad_codepoint` outside 0..127 |
| `build() -> str` | the text so far; the builder stays usable |
| `clear()` | |

Plus `len`. A `builder` is a heap object, so its text comes out through
`build()` rather than through `str(...)`, which accepts only the
explicit value families listed in the conversions table.

## file

| Method | Notes |
|---|---|
| `read(into: array[u8, _]) -> i64!` | fill the buffer and answer how many bytes landed; **zero is the end of the file**, not a refusal |
| `write(from: array[u8, _], count: i64) -> i64!` | write the first `count` bytes and answer how many landed, which may be fewer than you offered |
| `flush() -> !` | everything written so far is on the device |

All three are fallible: the world decides. There is deliberately no `close`.
ARC closes a [`file`](/guide/reference/types/#file) at its last release.

The buffer is the caller's, which is the C shape and is what makes the
same three methods serve a socket later. [`std.files`](/library/files/) is
where the loops over them live.

## task

| Method | Notes |
|---|---|
| `wait()` | consume the task and answer its worker's return shape; a fallible worker makes this a fallible call |

`wait` is a join and may be used once. A graph carrying no resource or
function value is copied into the joining runtime; a function answering
`file`, `task`, a function value, or a graph carrying one is refused at
`spawn`. An error crosses
as an error, and a trap surfaces with the worker's frames before the
joiner's. ARC joins a task whose last reference is released without a wait and
discards its answer. See the [`task`
type](/guide/reference/types/#task).

## str

The language keeps only these:

| Operation | Notes |
|---|---|
| `"..."`, `f"..."` | literals |
| `+` | concatenation |
| `== != < <= > >=` | comparison and ordering |
| `s[index] -> char` | Unicode scalar at a scalar position |
| `s[a:b]` | scalar-position slice |
| `len(s)` | Unicode scalar count |
| `s.byte_at(index) -> u8` | raw UTF-8 byte at a byte position |
| `s.find_byte(byte, start) -> i64` | raw byte offset or `-1`; `byte` is `u8` and `start` is a byte position |

Every other `str` method routes to [`std.strings`](/library/strings/) and
needs `import std.strings` in scope.

```luce run
func main():
    let s = "hello, Luce"
    print(f"{len(s)} scalars")
    print(s[7:11])
    print(str(s.byte_at(0)))
    print(str(s.find_byte(44, 0)))
    print(str(s.find_byte(122, 0)))
```

```output
11 scalars
Luce
104
5
-1
```
