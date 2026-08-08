# std.zip

ZIP archives and DEFLATE, in pure Luce. Read a real archive's central
directory, pull an entry's contents out of it, and write an archive of
your own. Nothing here is a builtin and nothing here touches the host:
every function takes bytes and answers bytes, and where the bytes came
from is the caller's business.

```
import std.zip
```

Written against the normative documents, and every structure in the
source names its clause. The container is PKWARE's **APPNOTE.TXT
6.3.10** — 4.3.7 the local header, 4.3.12 the central directory,
4.3.16 the end record, 4.4.4 the flags. The compression is **RFC
1951** — §3.2.2 canonical Huffman, §3.2.4 stored blocks, §3.2.5 the
length and distance tables, §3.2.6 the fixed codes, §3.2.7 the dynamic
ones. A ZIP member's method-8 data is a *raw* deflate stream: no zlib
header and no Adler-32 trailer.

## Bytes are a `list(byte)`

One byte to an element, and one byte of memory — a `list` stores its
elements at their real width. This page used to say the opposite, and
this module is where the cost was measured: a boxed slot is 24 bytes,
so a byte buffer was 24 times its payload and `list(long)` was the
honest least-bad choice. The buffers here are a quarter of what they
were, and nothing above them changed to make it so.

One thing the narrower element made explicit rather than changed: a
`byte` widens to `int` in an operator, so a 32-bit field's top byte
would shift into a sign bit. `read_u32` lifts its four bytes to `long`
before shifting; everything else fits.

## An archive on disk

| Signature | Notes |
|---|---|
| `zip.read(path: string) -> list(byte)!` | an archive's bytes, straight off the disk |
| `zip.write(path: string, archive: list(byte)) -> !` | write what `writer.finish()` answered |

These two are the only things in the module that touch the world, and
they are the reason it was written. Until a Luce program could read a
file that was not text, "takes bytes" meant "takes bytes somebody
computed", and no real archive could reach any of it. Everything
between still takes bytes and answers bytes: a container format has no
business deciding where its bytes live, which is why the two doors are
one line each.

## Bytes and text

| Signature | Notes |
|---|---|
| `zip.bytes(content: string) -> list(byte)` | the UTF-8 bytes a string is made of |
| `zip.text(data: list(byte)) -> string?` | the string those bytes spell, or absent when they spell none |

```luce run
import std.zip

func main() -> !:
    let raw = zip.bytes("héllo")
    print(string(len(raw)))
    print(zip.text(raw) else "(not text)")
```

```output
6
héllo
```

## The checksum

| Signature | Notes |
|---|---|
| `zip.crc32(data: list(byte)) -> long` | the reflected CRC-32 every entry carries (APPNOTE 4.4.7) |

The 256-entry CRC table is one private file-scope constant, materialized
once per runtime rather than rebuilt in every call. Five more private
constants hold DEFLATE's length bases, length extras, distance bases,
distance extras and code-length order. All six are immutable program
roots; every worker runtime materializes its own copies.

```luce run
import std.zip

func main():
    print(string(zip.crc32(zip.bytes("123456789"))))
```

```output
3421780262
```

That is `0xCBF43926`, the published check value.

## Reading

| Signature | Notes |
|---|---|
| `zip.entries(archive: list(byte)) -> list(Entry)!` | every entry the central directory lists, in the order it lists them |
| `zip.extract(archive: list(byte), entry: Entry) -> list(byte)!` | the entry's contents, checked against the size and the CRC the directory recorded |

An `Entry` describes one member and is made only by reading an
archive — its fields are the module's own, and these are how a program
asks:

| Method | Notes |
|---|---|
| `entry.name() -> string` | the name inside the archive, as it is stored |
| `entry.size() -> long` | how many bytes the contents are |
| `entry.packed() -> long` | how many bytes it takes up in the archive |
| `entry.crc() -> long` | the CRC-32 the archive records |
| `entry.deflated() -> bool` | true when it is deflated rather than stored whole |

Two things a conforming reader has to tolerate are tolerated. An entry
written by a program that could not seek has zeros where its local
header's CRC and sizes belong (APPNOTE 4.4.4 bit 3); this reads the
central directory, which 4.4.7 requires to hold the right values. And
an archive with a program in front of it — a self-extracting one — has
every offset shifted by however far its directory really begins from
where it says it does.

Anything else is refused by name rather than half-read: an encrypted
entry, a compression method the module does not have, a name that is
not text, contents that fail their checksum.

## Writing

| Signature | Notes |
|---|---|
| `zip.writer() -> Writer` | a new, empty archive, owned by the binding that received it |
| `writer.add(name: string, data: list(byte), compress: bool = false) -> !` | store one entry; `compress` deflates it and keeps whichever is smaller |
| `writer.finish() -> list(byte)` | the whole archive: everything added, then the central directory over it |

`finish` builds a fresh list every time, so the writer stays usable.

```luce run
import std.zip

func main() -> !:
    var writer = zip.writer()
    try writer.add("greeting.txt", zip.bytes("hello, world\n"))
    var raw: list(byte) = [0, 255, 128, 1]
    try writer.add("every.bin", raw)
    let archive = writer.finish()

    let found = try zip.entries(archive)
    for entry in found:
        print(entry.name() + " " + string(entry.size()))
    let first = try zip.extract(archive, found[0])
    print(zip.text(first) else "(not text)")
```

```output
greeting.txt 13
every.bin 4
hello, world

```

## DEFLATE on its own

| Signature | Notes |
|---|---|
| `zip.inflate(data: list(byte)) -> list(byte)!` | the bytes a raw DEFLATE stream stands for — stored, fixed and dynamic Huffman blocks alike |
| `zip.deflate(data: list(byte)) -> list(byte)` | a raw DEFLATE stream those bytes stand for; compression cannot fail, so it answers bytes rather than an error |

`inflate` reads everything RFC 1951 defines. `deflate` writes one final
block on the fixed tables of §3.2.6, with LZ77 matches found through a
hash of three bytes and a chain of the positions that hashed the same —
§3.3 lets a compressor use less than the format's full range and stay
compliant, which is what a fixed-code encoder with a bounded search is
doing.

```luce run
import std.zip

func main() -> !:
    var text = ""
    for step in range(0, 40):
        text += "the quick brown fox jumps over the lazy dog. "
    let plain = zip.bytes(text)
    let squeezed = zip.deflate(plain)
    print(string(len(plain)) + " -> " + string(len(squeezed)))
    let back = try zip.inflate(squeezed)
    print(string((zip.text(back) else "") == text))
```

```output
1800 -> 61
true
```

## Limits

The sizes are the ZIP32 ones: at most 65535 entries, each at most 4 GB,
and there is no Zip64. Encryption, multi-disk archives and compression
methods other than stored and deflated are refused rather than
half-read. Damaged input is an **error**, never a trap — the bytes are
the world's, not the program's — so a reader writes `try` or `catch`:

```luce run
import std.zip

func count(archive: list(byte)) -> !:
    let found = try zip.entries(archive)
    print(string(len(found)) + " entries")

func main():
    var scraps: list(byte) = [80, 75, 3]
    count(scraps) catch reason:
        print(reason)
```

```output
zip: not an archive (only 3 bytes)
```

## A program that uses it

`programs/zipper.luc` is this module at a command line — list, extract
and build archives on disk — and it is
[shown running, with its source](/examples/programs/#zipper-a-real-zip-archive-in-and-out).
Read it before writing an extractor of your own: an entry's name is
whatever the person who wrote the archive put there, and joining one
to a target directory without checking it is the bug called zip-slip.
