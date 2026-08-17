# Bytes and binary buffers

`bytes` is immutable binary data. It is a value type with no UTF-8 invariant:

- `len(data)` counts bytes and answers `i64`;
- `data[index]` answers `u8`;
- `data[start:end]` answers `bytes`;
- `for value in data` iterates `u8` values;
- `+` concatenates; and
- equality and ordering are lexicographic over unsigned bytes.

```luce
func main():
    let source: list[u8] = [72, 105]
    let data = bytes(source)
    assert(len(data) == 2)
    assert(data[0] == 72)
```

There is no byte-literal grammar. Constructors make the boundary explicit:

- `bytes(text)` encodes a `str` as UTF-8;
- `bytes(values)` copies a `list[u8]`; and
- `bytes(values)` copies a one-dimensional `array[u8, _]`.

`parse_str(data) -> str?` validates bytes as UTF-8. Invalid text answers
`none`; Luce never manufactures an invalid `str`.

## Mutable buffers

`bytes` is immutable. Use `list[u8]` for a growable buffer and
`array[u8, _]` for a fixed-size buffer that a file read can fill. Both are ARC
reference objects, so assignment and arguments share one buffer.

```luce
func main():
    let buffer = new list[u8]
    buffer.append(72)
    buffer.append(105)
    let same = buffer
    same.append(10)
    assert(len(buffer) == 3)
```

Each numeric element is stored at its declared width. A `list[u8]` or
`array[u8, _]` uses one byte per element; it is not a list of boxed 24-byte
runtime values.

Integer operations preserve their concrete type. Convert each byte to the
desired wider result before combining it:

```luce
func read_u32(data: list[u8], at: i64) -> u32:
    let b0 = u32(data[at])
    let b1 = u32(data[at + 1])
    let b2 = u32(data[at + 2])
    let b3 = u32(data[at + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

func main():
    let data: list[u8] = [1, 0, 0, 0]
    assert(read_u32(data, 0) == 1)
```

## Files

`files.File` is an ordinary ARC class owning the host's descriptor — the
raw `handle` currency is spellable only inside embedded standard source,
so a program holds a `File`, never a number (the Swift shape: a
descriptor lives behind the session object that owns it). Its methods
operate on a caller-owned `array[u8, _]` and are fallible:

| Method | Meaning |
|---|---|
| `f.read(buffer) -> i64!` | fills up to `len(buffer)` bytes; `0` means end of file |
| `f.write(buffer, count) -> i64!` | writes up to `count` bytes and reports the actual count |
| `f.flush() -> !` | asks the host to flush pending writes |

There is no source `close()`. The runtime closes the descriptor when the
File's last strong reference is released. Adding a second manual lifetime
would make aliases unsafe.

```luce
import std.files

func size(path: str) -> i64!:
    let handle = try files.open(path)
    let buffer = new array[u8](4096)
    var total: i64 = 0
    var filled = try handle.read(buffer)
    while filled > 0:
        total += filled
        filled = try handle.read(buffer)
    return total

func main():
    print("ok")
```

The current whole-file standard-library APIs use mutable byte lists:

| Function | Meaning |
|---|---|
| `files.read_bytes(path: str) -> list[u8]!` | reads the complete file |
| `files.write_bytes(path: str, data: list[u8]) -> !` | replaces the file |
| `files.append_bytes(path: str, data: list[u8]) -> !` | appends, creating when needed |

`std.strings.to_bytes(text) -> list[u8]` and
`std.strings.from_bytes(data) -> str?` bridge those mutable library buffers.
The core `bytes` type is the immutable value form.

All text validation, binary copying, packed storage, file access, and ARC
cleanup use the shared runtime reached by both execution paths.
