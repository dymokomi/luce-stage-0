# std.zip

`std.zip` reads and writes ZIP32 archives and raw DEFLATE streams. The
archive operations work on `list(byte)` values; only the explicit `read` and
`write` helpers touch the filesystem. The module is ordinary Luce and uses
no host service for in-memory work.

```text
import std.zip
```

The implementation accepts stored entries and method-8 (DEFLATE) entries.
It does not implement Zip64, encryption, multi-disk archives, or other
compression methods. Damaged or unsupported input is an error, so callers
use `try` or `catch`.

## Bytes, text, and checksums

| Signature | Result |
|---|---|
| `zip.bytes(content: string) -> list(byte)` | UTF-8 bytes of a string |
| `zip.text(data: list(byte)) -> string?` | text represented by bytes, or `none` for invalid UTF-8 |
| `zip.crc32(data: list(byte)) -> long` | reflected CRC-32 used by ZIP entries |

```luce run
import std.zip

func main():
    let data = zip.bytes("123456789")
    print(string(zip.crc32(data)))
    print(zip.text(data) else "(not text)")
```

```output
3421780262
123456789
```

## Reading archives

`zip.entries(archive: list(byte)) -> list(Entry)!` reads the central
directory without extracting contents. Each `Entry` provides:

| Method | Result |
|---|---|
| `entry.name() -> string` | name stored in the archive |
| `entry.size() -> long` | uncompressed byte count |
| `entry.packed() -> long` | compressed byte count |
| `entry.crc() -> long` | recorded CRC-32 |
| `entry.deflated() -> bool` | whether the entry uses DEFLATE rather than stored bytes |

`zip.extract(archive, entry) -> list(byte)!` reads one local entry, inflates
it when necessary, and verifies both its uncompressed size and CRC. Entry
names and offsets are read from the archive; a self-extracting prefix and
data-descriptor entries are supported. An encrypted entry, non-text name,
unsupported method, truncated header, or checksum mismatch is refused.

## Writing archives

`zip.writer() -> Writer` creates an empty archive builder. The returned
`Writer` is owned by the receiving binding.

| Method | Behavior |
|---|---|
| `writer.add(name: string, data: list(byte), compress: bool = false) -> !` | adds one entry; when `compress` is true, keeps DEFLATE only if it is smaller |
| `writer.finish() -> list(byte)` | returns the complete archive, including its central directory |

`finish` returns a fresh byte list and leaves the writer usable. Archives are
limited to 65535 entries and 4 GiB per entry because Zip64 is not supported.

```luce run
import std.zip

func main() -> !:
    var writer = zip.writer()
    try writer.add("hello.txt", zip.bytes("hello\n"), compress = true)
    let archive = writer.finish()
    let found = try zip.entries(archive)
    for entry in found:
        print(f"{entry.name()} {entry.size()} {entry.deflated()}")
    let contents = try zip.extract(archive, found[0])
    print(string(len(contents)))
```

```output
hello.txt 6 false
6
```

Short text is often larger when compressed, so `writer.add` keeps the stored
form in that case. Entry order is the order in which `add` was called.

## Raw DEFLATE

| Signature | Result |
|---|---|
| `zip.inflate(data: list(byte)) -> list(byte)!` | expands stored, fixed-Huffman, or dynamic-Huffman raw DEFLATE blocks |
| `zip.deflate(data: list(byte)) -> list(byte)` | produces a raw fixed-Huffman DEFLATE stream; it cannot fail |

These functions do not accept or produce a zlib or gzip wrapper. A ZIP
method-8 entry contains exactly this raw stream.

All six are immutable DEFLATE lookup tables. They are built once for a
runtime and shared by calls; callers never need to initialize or release
them.

```luce run
import std.zip

func main() -> !:
    let plain = zip.bytes("the quick brown fox")
    let packed = zip.deflate(plain)
    let restored = try zip.inflate(packed)
    print(string(len(packed) < len(plain)))
    print(string(len(restored)))
```

```output
false
19
```

## Filesystem helpers

These are the only host-facing functions in the module:

| Signature | Result |
|---|---|
| `zip.read(path: string) -> list(byte)!` | reads an archive's bytes with `std.files.read_bytes` |
| `zip.write(path: string, archive: list(byte)) -> !` | writes archive bytes with `std.files.write_bytes` |

Use them with a `Writer` when an archive belongs on disk:

```text
var writer = zip.writer()
try writer.add("data.txt", zip.bytes("content"))
try zip.write("data.zip", writer.finish())
```

An entry name is supplied by the archive author. Before extracting into a
directory, validate names and reject `..` or absolute paths; otherwise a
zip-slip path can escape the intended destination. `std.zip` exposes the
archive format, not a policy for where extracted names may go.
