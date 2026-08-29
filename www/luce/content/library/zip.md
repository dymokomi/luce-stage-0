# std.zip

`std.zip` reads and writes ZIP32 archives and raw DEFLATE streams. The
archive operations work on `list[u8]` values; only the explicit `read` and
`write` helpers touch the filesystem. The module is ordinary Luce and uses
no host service for in-memory work.

```text
import std.zip
```

The implementation accepts stored entries and method-8 (DEFLATE) entries.
It does not implement Zip64, encryption, multi-disk archives, or other
compression methods. Damaged or unsupported input is a typed error — the
`ZipError` union below — so callers use `try` or `catch`.

## Errors

Every fallible function in the module fails with one union:

```text
union ZipError:
    damaged(reason: str)
    unsupported(reason: str)
    io(reason: str)
```

`damaged` is bytes that do not hold what they claim — truncation, a broken
directory, a failed checksum, a malformed DEFLATE stream. `unsupported` is a
conforming archive asking for a capability the module does not have: another
compression method, encryption, a non-UTF-8 entry name, or a size that needs
Zip64. `io` wraps the host's sentence when `zip.read` or `zip.write` touches
the disk. `match` reads the members apart; `zip.describe` renders the
`zip: REASON` sentence for a caller that only prints.

| Signature | Result |
|---|---|
| `zip.describe(failed: ZipError) -> str` | the refusal as one sentence, prefixed `zip: ` |

```luce run
import std.zip

func main():
    var scraps: list[u8] = [80, 75, 3]
    discard(zip.Archive(scraps)) catch reason:
        match reason:
            damaged(why):
                print("damaged: " + why)
            unsupported(why):
                print("unsupported: " + why)
            io(why):
                print("io: " + why)
        print(zip.describe(reason))
```

```output
damaged: not an archive (only 3 bytes)
zip: not an archive (only 3 bytes)
```

## Bytes, text, and checksums

| Signature | Result |
|---|---|
| `zip.to_bytes(content: str) -> list[u8]` | UTF-8 bytes of text |
| `zip.text(data: list[u8]) -> str?` | text represented by bytes, or `none` for invalid UTF-8 |
| `zip.crc32(data: list[u8]) -> i64` | reflected CRC-32 used by ZIP entries |

```luce run
import std.zip

func main():
    let data = zip.to_bytes("123456789")
    print(str(zip.crc32(data)))
    print(zip.text(data) else "(not text)")
```

```output
3421780262
123456789
```

## Reading archives

`zip.Archive` is a class made with a fallible init:
`let opened = try zip.Archive(archive: list[u8])` parses the central
directory once, so bytes that are not an archive — truncated, damaged, or
encrypted directory entries — fail at the init rather than on first use.
Contents are not extracted at open.

| Method | Result |
|---|---|
| `opened.entries() -> list[Entry]` | every entry the directory lists; cannot fail, the init already validated the directory |
| `opened.extract(entry) -> list[u8] ! ZipError` | one entry's contents, inflated when necessary and verified |

Each `Entry` provides:

| Method | Result |
|---|---|
| `entry.name() -> str` | name stored in the archive |
| `entry.size() -> i64` | uncompressed byte count |
| `entry.packed() -> i64` | compressed byte count |
| `entry.crc() -> i64` | recorded CRC-32 |
| `entry.deflated() -> bool` | whether the entry uses DEFLATE rather than stored bytes |

`extract` reads one local entry, inflates it when necessary, and verifies
both its uncompressed size and CRC. Entry names and offsets are read from
the archive; a self-extracting prefix and data-descriptor entries are
supported. An encrypted entry or non-text name is refused when the archive
is opened; an unsupported method, truncated local header, or checksum
mismatch is refused by `extract` on the entry it belongs to.

## Writing archives

`zip.Writer` is a class made with `zip.Writer()`: an empty archive
builder. A writer is an accumulator with identity — two bindings to one
writer see one archive under construction.

| Method | Behavior |
|---|---|
| `writer.add(name: str, data: list[u8], compress: bool = false) -> ! ZipError` | adds one entry; when `compress` is true, keeps DEFLATE only if it is smaller |
| `writer.finish() -> list[u8]` | returns the complete archive, including its central directory |

`finish` returns a fresh byte list and leaves the writer usable. Archives are
limited to 65535 entries and 4 GiB per entry because Zip64 is not supported.

```luce run
import std.zip

func main() -> ! zip.ZipError:
    var writer = zip.Writer()
    try writer.add("hello.txt", zip.to_bytes("hello\n"), compress = true)
    let archive = try zip.Archive(writer.finish())
    let found = archive.entries()
    for entry in found:
        print(f"{entry.name()} {entry.size()} {entry.deflated()}")
    let contents = try archive.extract(found[0])
    print(str(len(contents)))
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
| `zip.inflate(data: list[u8]) -> list[u8] ! ZipError` | expands stored, fixed-Huffman, or dynamic-Huffman raw DEFLATE blocks |
| `zip.deflate(data: list[u8]) -> list[u8]` | produces a raw fixed-Huffman DEFLATE stream; it cannot fail |

These functions do not accept or produce a zlib or gzip wrapper. A ZIP
method-8 entry contains exactly this raw stream.

All six are immutable DEFLATE lookup tables. They are built once for a
runtime and shared by calls; callers never need to initialize or release
them.

```luce run
import std.zip

func main() -> ! zip.ZipError:
    let plain = zip.to_bytes("the quick brown fox")
    let packed = zip.deflate(plain)
    let restored = try zip.inflate(packed)
    print(str(len(packed) < len(plain)))
    print(str(len(restored)))
```

```output
false
19
```

## Filesystem helpers

These are the only host-facing functions in the module:

| Signature | Result |
|---|---|
| `zip.read(path: str) -> list[u8] ! ZipError` | reads an archive's bytes with `std.files.read_bytes`; a host refusal arrives as `ZipError.io` |
| `zip.write(path: str, archive: list[u8]) -> ! ZipError` | writes archive bytes with `std.files.write_bytes`; a host refusal arrives as `ZipError.io` |

Use them with a `Writer` when an archive belongs on disk:

```text
var writer = zip.Writer()
try writer.add("data.txt", zip.to_bytes("content"))
try zip.write("data.zip", writer.finish())
```

An entry name is supplied by the archive author. Before extracting into a
directory, validate names and reject `..` or absolute paths; otherwise a
zip-slip path can escape the intended destination. `std.zip` exposes the
archive format, not a policy for where extracted names may go.
