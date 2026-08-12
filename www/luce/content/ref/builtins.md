# Builtins

Two kinds. **Free functions** are the generic, cross-type set — the
split Python makes. **Methods** belong to one type and are called on
it; the method spelling is sugar for a plain function with the
receiver first, resolved by the receiver's type, not dispatched.

## Free functions

| Signature | Notes |
|---|---|
| `len(value) -> long` | `string` bytes; list, map, builder or rank-1 array length; an `array`'s dimension 0 |
| `print(text: string)` | host-gated |
| `range(low: long, high: long)` | `for` only; excludes `high` |
| `assert(condition: bool)` | traps `assertion_failed` |
| `trap(message: string)` | never returns; traps `explicit_trap` |
| `error(message: string)` | never returns; raises `user_error` |
| `free(object)` | early release of a direct owned container or resource handle; the parameter's established broad name includes both; poisons the name |
| `abs(value)` | any number; answers its operand's type |
| `min(a, b)`, `max(a, b)` | any two numbers of the same type |
| `clamp(value, low, high)` | any three numbers of the same type |
| `sqrt(value)` | a `float` or a `double`, and **the same width back** |
| `floor(value)`, `ceil(value)` | ″ |
| `trunc(value)` | ″; toward zero, and `math.round` is the fourth |
| `chr(code: long) -> string` | traps `bad_codepoint` on an invalid codepoint |
| `ord(text: string) -> long` | first codepoint; traps on empty |
| `parse_int(text: string) -> long?` | `none` when the text is not an integer |
| `parse_float(text: string) -> double?` | `none` when the text is not a number |
| `byte(x)`, `short(x)`, `int(x)`, `long(x)`, `half(x)`, `float(x)`, `double(x)`, `string(x)` | the conversion constructors, each named for what it produces. Float to integer rounds half away from zero and traps outside the target's range; integer to a narrower integer traps outside it; float to a narrower float rounds to nearest and reaches `inf` rather than trapping; `string(x)` accepts numbers, `bool`, strings, enums, unions (answering the member's name, never the payload) and function values, and refuses container objects, resources and structs |

The four numeric builtins that answer their operand's own type land
their arguments where the whole call lands, so `let x: double =
sqrt(2.0)` reads `2.0` at binary64 rather than widening binary32's
answer into it. Unannotated, a float literal is a `float`, which is
what the fourth line below prints.

```luce run
func main():
    print(string(abs(-7)))
    print(string(min(3, 9)) + " " + string(max(3, 9)))
    print(string(clamp(42, 0, 10)))
    print(string(sqrt(2.0)))
    let two: double = 2.0
    print(string(sqrt(two)))
    print(string(floor(-2.5)) + " " + string(ceil(-2.5)) + " " + string(trunc(-2.5)))
    print(string(long(2.5)) + " " + string(long(-2.5)) + " " + string(long(2.4)))
    print(chr(9731))
    print(string(ord("A")))
    print(string(parse_int("17") else -1))
    print(string(parse_float("nope") else -1.0))
```

```output
7
3 9
10
1.4142135
1.4142135623730951
-3 -2 -2
3 -3 2
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
| `print(text: string)` | a line to standard output, unsanitized — it is the program's own channel and may be a pipe |
| `print_error(text: string)` | a line to standard error, **always sanitized**: that channel is shared with the runner, so a program may not scribble on a frame it does not own |
| `read_line(prompt: string) -> string?` | writes the prompt, reads one line without its newline; `none` at end of input. Hands the terminal back its line discipline first, so a line read and a raw key loop never fight over standard input |

End of input is absence, not failure — nothing went wrong, there is
just nothing more — so `read_line` answers `T?` and
`read_line("> ") else ""` is the whole handling.

### The environment

| Signature | Notes |
|---|---|
| `env(name: string) -> string?` | one environment variable; `none` when it is unset. There is no setter and no way to read the whole environment |

**The command line is not a builtin.** It is `main`'s parameter — write
`func main(args: list(string)):` and read `args` like any other list
([S44](../ownership/#s44)).

### The shell

| Signature | Notes |
|---|---|
| `shell_run(command: string) -> string!` | runs one command through the host shell, captures standard output and standard error, and appends the exit status. The returned text is a transcript, not a separate status value; quote paths and other arguments for the shell. |

Use [`std.os.shell.run`](/std/os/) rather than naming this host builtin
directly. It is intended for host tools such as an editor's build action,
not as a portable process API: a host that cannot launch the shell refuses
the call and a failed launch is an `io_failed` error.

### The clock

| Signature | Notes |
|---|---|
| `clock_ms() -> long` | a **monotonic** reading in milliseconds; only differences mean anything, and it is not a wall clock or a calendar |
| `epoch_ms() -> long` | milliseconds since the Unix epoch — **what time it is**, which the monotonic clock cannot say |
| `sleep_ms(milliseconds: long)` | waits at least that long; presents the pending frame first, as `key_read` does |

**Two clocks, and the names say which is which.** `clock_ms` counts
from an origin nobody specifies, so subtracting two readings is the
only thing it is for; `epoch_ms` counts from 1970-01-01T00:00:00Z, so
its *reading* is the answer and it is what a timestamp is made of. Use
`clock_ms` to measure how long something took — an operator can set the
wall clock backwards, and a span measured with `epoch_ms` would go
negative — and `epoch_ms` to say when something happened.

`epoch_ms` is not a calendar: turning it into a date is a library
nobody has written yet, and this is the number that library will be
built on.

Neither clock can fail, but a host that has no calendar at all refuses
`epoch_ms` with `host_unavailable` rather than inventing a number — the
same refusal the machine facts give, and for the same reason. That a
duration has **already elapsed** — zero, or the negative left by
`deadline - clock_ms()` when a frame overran — is not a bug and not a
failure for `sleep_ms`. There is no time left to wait, so it returns at
once. An animation loop can subtract without guarding.

### The exit

| Signature | Notes |
|---|---|
| `exit(status: long)` | the program's chosen end — the fourth way a run stops, beside finishing, trapping, and an uncaught error. It never returns: the run unwinds, nothing after the call executes, and the host carries the status — on POSIX, the low eight bits of the process's exit code |

Not a trap (nothing is wrong) and not an error (nothing failed):
`exit(0)` from the middle of `main` is an ordinary way for a program
that has said everything it came to say to stop saying it. Host-gated
like every effect — a host that cannot carry a status refuses the call
(`host_unavailable`) rather than losing the number.

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
    print("after 2020: " + string(stamped > 1577836800000))
    # `clock_ms` measures a span, and only differences mean anything.
    let started = clock_ms()
    sleep_ms(0)
    print("elapsed is never negative: " + string(clock_ms() >= started))
```

```output
after 2020: true
elapsed is never negative: true
```

### The machine

| Signature | Notes |
|---|---|
| `os_total_memory() -> long` | bytes of physical memory the machine has; fixed for the life of the run |
| `os_available_memory() -> long` | bytes it could still hand out. This one **moves**: ask twice and expect two answers |
| `os_cpu_count() -> long` | how many processors the host would schedule work onto — logical ones, so simultaneous multithreading counts threads |

Read them through [`std.os`](/std/os/), which is where they are
documented and where the word "available" is pinned down per platform.
None of them can fail in the `!` sense and none answers `none`: a fact
the host knows is a number, and a fact it does not know is a **refusal**
— `host_unavailable`, the same trap a withheld service gives. A host is
never made to invent a number for a machine it could not measure.

### Files

| Signature | Notes |
|---|---|
| `file_read(path: string) -> string!` | the whole file; 64 MiB ceiling |
| `file_write(path: string, content: string) -> !` | truncates or creates |
| `file_append(path: string, content: string) -> !` | adds to the end, creating the file if it is not there |
| `file_delete(path: string) -> !` | an absent path is `io_failed`, not a quiet success |
| `file_rename(from: string, to: string) -> !` | moves a file, **replacing** an existing target — which is what makes write-then-rename the way to replace a file without ever leaving half of one on disk |
| `file_exists(path: string) -> bool` | a question about the past, not a guard |
| `dir_list(path: string) -> list(string)!` | the names in a directory — plain names, not paths, without `.` and `..`, in whatever order the file system gave them. A fresh list the caller owns |
| `dir_create(path: string) -> !` | makes a directory **and every directory leading to it**. A directory already there is success; a *file* holding the name is `io_failed` |
| `file_open(path: string, mode: long) -> file!` | a handle your scope owns. `mode` is 0 read, 1 write, 2 append — and you write [`files.open`](/std/files/), [`files.create`](/std/files/) or [`files.append_to`](/std/files/) rather than a number |

Every one that changes a file is fallible, because the world decides
whether it lands. `file_exists` is the exception and answers a plain
`bool` — but it is a question about the past, never a guard for the
call after it.

**`dir_create` means "there is a directory here when I return."** It
makes the parents, so laying out `store/packages/geo-1.2.0` is one
call rather than a splitting loop in every program; and a directory
that was already there is success, so an install path never has to
write `if not files.exists(p)` in front of it — which would be exactly
the check-then-act race `file_exists` is not allowed to be. Write it as
[`files.make_directory`](/std/files/).

`file_read` and `file_write` are **defined over the handle**: each is
an open, a loop of reads or writes, a close, and — for the reading
direction — the runtime's own UTF-8 check. They are conveniences with a
ceiling, not a second channel.

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
| `parse_string(bytes: list(byte)) -> string?` | those bytes as text, or absent when they are not valid UTF-8 |

The third member of the parse family, and it answers absence for the
reason `parse_int` does: "not UTF-8" is the same reason every time, so
there is nothing a carried message would add. Write it as
[`strings.from_bytes`](/std/strings/), which is where the other
direction — `strings.to_bytes`, total, because a string always has
bytes — lives beside it.

### The terminal

| Signature | Notes |
|---|---|
| `term_rows() -> long`, `term_cols() -> long` | |
| `term_clear()`, `term_move(row, column)` | |
| `term_style(fg, bg = -1, bold = false)` | 256-color SGR; `-1`, the default, is the terminal's own color |
| `term_write(text: string)` | sanitized; a program cannot emit a control sequence |
| `term_flush()` | |
| `key_read() -> string?` | presents the pending frame, then blocks; a stable name, or `none` at end of input |
| `key_text() -> string` | the payload when the last `key_read` returned `"text"` |
| `term_event_data(field: long) -> long` | numeric data for the most recent terminal event: row, column, button, modifiers or wheel value; used by `std.os.term.io` |

`key_read` answers `string?` because a keyboard can run dry — the pipe
driving the program ends, the terminal closes — and then there is
nothing there and no reason worth carrying, exactly as for `read_line`
off the same input. `none` is not one more name in the set: a name
would be a value a loop can fall past, and a loop that falls past it
asks for the next key forever. End of input empties `key_text` too, so
the payload of a key that never came is `""`.

```
let name = key_read()
if name == none:
    break
```

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

## list(T)

| Method | Notes |
|---|---|
| `append(value)` | |
| `insert(index, value)` | |
| `remove(index)` | frees an owned element |
| `pop() -> T` | ownership moves out; traps `empty_collection` when empty |
| `sort()` | in place, **stable**, O(n log n); `long`, `double` or `string` elements |
| `sort_by(before: func(T, T) -> bool)` | in place, **stable**, O(n log n); every element type; requires `import std.lists` |
| `reverse()` | in place |
| `find(value) -> long?` | absence when not found; `xs.find(v) else -1` is the sentinel form |
| `contains(value) -> bool` | |
| `clear()` | frees all owned elements |

Plus `len`, `xs[i]`, `xs[i] = v`, and `xs[a:b]` — which allocates a
new list the receiver owns, deeply when the elements are resource-free
container objects or carrying structs. When the element type carries
`file` or `task`, both effective bounds must be equal compile-time `long`
constants, proving an empty slice with no element copies; every other
such slice is refused.
`sort_by` borrows a named function or capture-free lambda; when the
elements are containers, resources, or carrying structs the merge moves
them rather than copying.

## map(K, V)

| Method | Notes |
|---|---|
| `has(key) -> bool` | |
| `get(key) -> V?` | absence when missing — never traps; `m.get(k) else d` is the fallback form |
| `remove(key)` | a no-op when absent |
| `keys() -> list(K)` | a fresh list the receiver owns |
| `values() -> list(V)` | a fresh list the receiver owns; refused when `V` carries `file` or `task` |
| `clear()` | |

Plus `len`, `m[k]` — which traps `key_missing` when the key is
absent — `m[k] = v`, which inserts or updates, and `m[k] OP= v`, which
defines a missing key at `V`'s zero value and then applies.

`values()` copies each value into its new list. Container and carrying
struct values are deep-copied, so their complete type graph must be
resource-free.

## array(T, ...)

| Method | Notes |
|---|---|
| `dim(axis) -> long` | the size of one axis |
| `fill(value)` | every element at any rank; **non-handle value elements only** |
| `sort()`, `reverse()`, `find(v)`, `contains(v)` | rank-1 only |

Plus `len` (dimension 0), `a[i]`, `grid[r, c]` up to four indices, and
index assignment.

`dim` and `fill` are the two that work at every rank; the rest need a
single axis to mean anything.

```luce run
func main():
    var grid = new array(long, 2, 3)
    grid.fill(7)
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[1, 2]}")
```

```output
2 by 3, corner 7
```

## builder

| Method | Notes |
|---|---|
| `append(text: string)` | |
| `append_ascii(code: long)` | one ASCII byte; traps `bad_codepoint` outside 0..127 |
| `build() -> string` | the bytes so far, as a string; the builder stays usable |
| `clear()` | |

Plus `len`. A `builder` is a heap object, so its text comes out through
`build()` rather than through `string(...)`, which accepts only the
explicit value families listed in the conversions table.

## file

| Method | Notes |
|---|---|
| `read(into: array(byte, _)) -> long!` | fill the buffer and answer how many bytes landed; **zero is the end of the file**, not a refusal |
| `write(from: array(byte, _), count: long) -> long!` | write the first `count` bytes and answer how many landed, which may be fewer than you offered |
| `flush() -> !` | everything written so far is on the device |

All three are fallible: the world decides. There is deliberately no
`close` — a [`file`](/ref/types/#file) is scope-owned, so the end of
the owning scope closes it and `free(f)` closes it early.

The buffer is the caller's, which is the C shape and is what makes the
same three methods serve a socket later. [`std.files`](/std/files/) is
where the loops over them live.

## task

| Method | Notes |
|---|---|
| `wait()` | consume the task and answer its worker's return shape; a fallible worker makes this a fallible call |

`wait` is a join and may be used once. A resource-free worker answer
moves into the joining runtime; a function answering `file`, `task`, or
a graph carrying either is refused at `spawn` instead. An error crosses
as an error, and a trap surfaces with the worker's frames before the
joiner's. A task not explicitly waited on is still joined when its
owning scope ends, but its answer is discarded. See the [`task`
type](/ref/types/#task).

## string

The language keeps only these:

| Operation | Notes |
|---|---|
| `"..."`, `f"..."` | literals |
| `+` | concatenation |
| `== != < <= > >=` | comparison and ordering |
| `s[a:b]` | slice; checks UTF-8 boundaries |
| `len(s)` | in bytes |
| `s.byte_at(index) -> byte` | raw byte. The one builtin that answers a `byte`, because its result is definitionally one; it reaches a `long` parameter or a comparison with nothing written down |
| `s.find_byte(byte, start) -> long` | offset of the first `byte` at or after `start`, or `-1`; the byte looked for is a `byte`, so "outside 0..255" is refused where it is written rather than trapping where it is read. Traps if `start` is outside the string |

Every other string method routes to [`std.strings`](/std/strings/) and
needs `import std.strings` in scope.

```luce run
func main():
    let s = "hello, loom"
    print(f"{len(s)} bytes")
    print(s[7:11])
    print(string(s.byte_at(0)))
    print(string(s.find_byte(44, 0)))
    print(string(s.find_byte(122, 0)))
```

```output
11 bytes
loom
104
5
-1
```
