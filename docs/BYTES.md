# Bytes — the binary half of the host boundary

A Luce `string` is validated UTF-8 by construction: nothing can build a
`string` that is not, so a `string` cannot carry a half-read JPEG or a
raw archive without making every string guarantee a lie. Binary data
therefore travels a path of its own — a packed byte buffer, a file
reached through an open handle, and text recovered from bytes by an
explicit validation. This document is the reference for that path.

The byte representation, file operations, and last-release cleanup run on both
engines. The host and ZIP specifications exercise round trips through real
resource handles and require a zero-object census.

## The byte buffer

Bytes live in the container vocabulary every program already knows.
There is no separate `bytes` type and no byte-literal grammar.

- **`list(byte)`** is the growable byte buffer: reference-counted,
  indexable, sliceable, iterable, and grown with `append`. Its storage
  is packed — one byte per element — so a `list(byte)` costs its bytes
  and not a boxed cell each.
- **`array(byte, n)`** is the fixed-length, packed buffer. It cannot
  grow, so it is what a read fills: you hand it to a file's `read` and
  the file says how many bytes landed.

Packing is general to scalar lists, not special to bytes: `list(T)` uses
the same `ElementKind` storage an `array(T, _)` uses, so `list(long)`
costs eight bytes per element and every scalar list is smaller for it.
Strings, structs, and reference objects keep a tagged slot inside a
`list`, exactly as they do inside an `array`; `map` is unchanged, since
its cost is the entry rather than the element. A `Value` remains the
boundary type at `at`/`put`, so indexing reads and writes look the same
whatever the element width.

A `list(byte)` grows and iterates like any list:

```luce
func main():
    var buffer = new list(byte)
    buffer.append(72)
    buffer.append(105)
    print(f"{len(buffer)} bytes")
    for b in buffer:
        print(string(b))
```

Because it is a reference type (`docs/MEMORY.md`), a buffer is shared, not
copied, when assigned or passed. ARC reclaims it at the last strong release:

```luce
func main():
    var a = new list(byte)
    a.append(1)
    let b = a
    b.append(2)
    print(f"{len(a)}")     # 2 — a and b name one buffer
```

A `byte` widens to `int` in an arithmetic or bitwise operator, so code
that assembles a wider integer from bytes must lift each byte to the
target width before shifting — otherwise the top byte's high bit would
land in a sign position:

```luce
func read_u32(data: list(byte), at: long) -> long:
    let b0 = long(data[at])
    let b1 = long(data[at + 1])
    let b2 = long(data[at + 2])
    let b3 = long(data[at + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

func main():
    print("ok")
```

## The file resource

A `file` is a reference-counted resource, not a container: it has no
element type, no `new`, and the only door in is `files.open` (and its
`create`/`append_to` siblings, `docs/FILESYSTEM.md`). It sits in the
runtime's `types.HeapType` as `.file`, beside the container kinds rather
than among them, because a socket is meant to arrive later wearing the
same shape.

A file carries **raw bytes with no opinion about encoding**. It answers
three methods, and there is deliberately no `close`:

| method | shape | meaning |
|---|---|---|
| `read(buffer)` | `read(array(byte, n)) -> long!` | fills the buffer you own, answers how many bytes landed; `0` means the file is finished |
| `write(buffer, count)` | `write(array(byte, n), long) -> long!` | writes `count` bytes from the buffer, answers how many landed, which may be fewer than asked |
| `flush()` | `flush() -> !` | pushes buffered writes to the host |

The primitive is C-shaped on purpose: a read fills a caller-owned buffer
and reports a count, and a short write is ordinary rather than a
failure, which is why `write` answers a count. All three are fallible —
the world decides whether a read or write lands — so a call site writes
`try` to pass the failure on or `catch` to handle it, and a site that
says neither is a `luce.sema.fallible` error. (`read`, `write`, and
`flush` are the first fallible *methods*; every earlier fallible thing
was a free builtin.)

Reading a file to its end is a loop over `read`:

```luce
import std.files

func stream(path: string) -> long!:
    var f = try files.open(path)
    var buffer = new array(byte, 4096)
    var total: long = 0
    var filled = try f.read(buffer)
    while filled > 0:
        total += filled
        filled = try f.read(buffer)
    return total

func main():
    print("ok")
```

Writing goes through `write` and `flush`:

```luce
import std.files

func save(path: string) -> !:
    var f = try files.create(path)
    var buffer = new array(byte, 3)
    buffer[0] = 72
    buffer[1] = 105
    buffer[2] = 10
    let sent = try f.write(buffer, 3)
    try f.flush()

func main():
    print("ok")
```

### No close; ARC owns the lifetime

There is no `close()` method and no `with` statement. ARC closes the file at
its last release through the same path that destroys a container. An explicit
close would add a second lifetime model and make aliases unsafe:

```text
f.close()
# luce.sema.method: file has no method close: the file closes when its
#   last reference is released, which is why there is no 'with' either
```

Naming `file` in a `new` is likewise refused, because a file with no
file behind it is the one state the type must never hold; the only door
is `files.open`:

```text
var f = new file
# luce.sema.new: a file is opened, not made; write files.open(path)
```

## Text as a validation

Because a `string` is validated UTF-8, turning bytes into a `string` is
a *validation*, and it may fail. That validation lives in `libluce_rt` —
the one implementation of every semantic — so the compiled path, the
interpreter, and every future host agree byte-for-byte on what "not
text" means.

- `strings.to_bytes(s) -> list(byte)` — a string always has bytes, so
  this never fails.
- `strings.from_bytes(xs) -> string?` — the parse direction. "Not UTF-8"
  is the same reason every time, so absence carries all the information:
  `none` means the bytes are not text. It is a one-line surface over the
  primitive `parse_string(xs) -> string?`, named for what it produces
  exactly as `parse_int` and `parse_float` are.

```luce
import std.strings

func roundtrip(s: string) -> string:
    let raw = strings.to_bytes(s)
    let back = strings.from_bytes(raw)
    if back == none:
        return "not text"
    return back

func main():
    print(roundtrip("hi"))
```

`strings.to_bytes` is an ordinary Luce loop over `byte_at`; `from_bytes`
is a validator, and a packed `list(byte)` *is* its bytes, so the
validator reads the buffer in place.

The whole-file text conveniences build on the same seam: `files.read`
(the whole-file text read) is open-read-close over the byte channel
followed by the runtime's own UTF-8 validation, so a file that is not
text is refused in one place for one reason.

## Whole-file byte conveniences

`std.files` layers whole-file byte operations over the handle primitive,
the way Go's `os.ReadFile` is a loop over `Read`:

| function | shape | meaning |
|---|---|---|
| `files.read_bytes(path)` | `-> list(byte)!` | the whole file as bytes; asks nothing about whether they are text |
| `files.write_bytes(path, bytes)` | `-> !` | replaces the file's contents with the bytes |
| `files.append_bytes(path, bytes)` | `-> !` | adds the bytes to the end, creating the file if absent |

```luce
import std.files
import std.strings

func save(path: string, text: string) -> !:
    try files.write_bytes(path, strings.to_bytes(text))

func main():
    print("ok")
```

## The host byte channel

Under the language, a file is five appended `LuceHost` slots —
`handle_open`, `handle_read`, `handle_write`, `handle_flush`,
`handle_close` — carrying raw bytes with no encoding opinion. They are
named for the handle rather than the file because the same five are
meant to serve a socket. Like every host service they are fail-closed;
like every fallible one they answer `yes`/`no`/`exhausted`.

Two facts about the seam matter to a reader of the runtime:

- **The channel is installed into `libluce_rt`, not read at each call.**
  A file's close happens inside the reference-counting release path,
  where no generated code is standing to hand a host table in, so the
  runtime is handed the five function pointers once (`luce_rt_files_install`)
  and calls them itself. Both engines install the *same* five pointers,
  which is why the interpreter and a compiled artifact agree on what an
  open answers, what a short read means, and when a close happens.
- **The mode is a number on the slot and a name in the library.** The
  open slot takes `0` read, `1` write, `2` append; `std.files` is where
  those numbers get the names `open`, `create`, and `append_to`. A
  builtin speaks what the host slot speaks, and the library is where it
  gets a name.

A handle remembers the path it was opened at, so the runtime — the side
that knows the path — raises `io_failed` itself and names the file in
the message; what reaches generated code is one flag to branch on.

## std.zip over real archives

`std.zip` is the proving customer for the byte path. `zip.read(path)`
and `zip.write(path, archive)` read and write real archives on disk;
its buffers are `list(byte)`; and its byte/text bridges are
`strings.to_bytes` and `strings.from_bytes`, so a module that once
carried a hand-written UTF-8 decoder now defers to the one validator.

```luce
import std.zip

func list_names(path: string) -> !:
    let archive = try zip.read(path)
    let items = try zip.entries(archive)
    for entry in items:
        print(entry.name())

func main():
    print("ok")
```

The end-to-end proof is Info-ZIP's own bytes carried through a real
file: archives written by Info-ZIP and Python are read, extracted,
re-zipped, and re-extracted to the same bytes on both engines, and
`examples/zipper/zipper.luc` drives the installed toolchain the way a
person does. A cross-check against the system `zip`/`unzip` runs when the
machine has them and says so when it does not, but the unconditional
proof is the embedded bytes, so no build-time dependency on an external
tool is added.

## Traps and limits

- **`io_failed`** is raised by the runtime, at the site that asked, with
  the path named — a read from a file the world will not give, a write
  the host refused.
- **`allocation_failed`** is the trap when a buffer outgrows the
  machine's memory. There is no flat element cap; `heap.maxElements(kind)`
  keeps only the ceilings a vectorized reduction proof is load-bearing
  on (`docs/VECTOR.md`), computed in `i128` so a wrapped bound cannot
  report that everything fits. Past those, RAM decides and says so at
  the site that asked, located and traced like every other trap. (On
  Linux, overcommit means a write can still fault after the allocation
  succeeded — the one case this trap does not catch, noted where the
  trap code is defined.)

The serialized-module `format_version` and the host `abi.version` both
moved when the byte channel landed; a stale or foreign artifact is
refused by name rather than run, and modules recompile from source.
