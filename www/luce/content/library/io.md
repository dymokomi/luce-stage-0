# std.io

`std.io` is the byte-stream contract: two interfaces and the two loops
every stream shares. A `Reader` fills a buffer you own and says how
many bytes landed; a `Writer` takes a buffer and a count and says how
many landed. The shape is C's on purpose, for the reason Go kept it —
everything else is a loop over these two calls.

```text
import std.io
```

The module is pure: nothing here touches the host, so it imports in any
program. What a stream's read or write actually moves is the
conformer's business — [`files.File`](/library/files/) and
[`network.Connection`](/library/network/) conform, and a program's own
type conforms by declaring the same functions.

## The contract

```text
interface Reader:
    func read(buffer: array[u8, _]) -> i64!

interface Writer:
    func write(buffer: array[u8, _], count: i64) -> i64!
    func flush() -> !
```

`read` fills the buffer from where the last read stopped and answers
how many bytes landed. **Zero is the end of the stream, not an error**
— the same sentence a file ends with and a finished peer says. `write`
hands over the first `count` bytes and answers how many landed, which
may be fewer than asked; a short write is ordinary, and the count
coming back is what lets the next round continue where this one
stopped. `flush` asks the stream to let go of anything it is holding.
The error channel carries what it always carries: the world refusing.

## The two loops

```text
io.drain(source: io.Reader) -> list[u8]!
io.send(sink: io.Writer, data: list[u8]) -> !
```

`drain` reads the source to its end and answers everything it heard.
`send` writes all of `data`, looping over short writes, then flushes; a
sink that accepts nothing at all has stopped writing, and `send` says
so as an error instead of spinning. These are the loops every byte
channel needs, written once over the contract instead of once per
stream — `files.read_bytes` is `io.drain` behind a path.

## Your own stream

A type conforms by declaring the interface and the functions. Nothing
about the contract requires a file or a socket — an in-memory source is
a `Reader` all the same, and `drain` cannot tell the difference:

```luce run
import std.io
import std.strings

class Feed: io.Reader:
    private data: list[u8]
    private at: i64

    init(text: str):
        self.data = strings.to_bytes(text)
        self.at = 0

    func read(buffer: array[u8, _]) -> i64!:
        var filled: i64 = 0
        while filled < len(buffer) and self.at < len(self.data):
            buffer[filled] = self.data[self.at]
            filled += 1
            self.at += 1
        return filled

func main() -> !:
    let all = try io.drain(Feed("a stream is a loop"))
    print(str(len(all)))
    print(strings.from_bytes(all) else "(not text)")
```

```output
18
a stream is a loop
```

The same works on the other side: a class holding a `list[u8]` and
appending in `write` is a `Writer`, and `io.send(sink, data)` feeds it
the way it feeds a file.

## Deliberately absent

- **Seeking and positions.** A stream is what moves; a file that can
  seek is `files.File`'s business, when something real asks for it.
- **Buffered wrappers.** `drain` and `send` already move data in large
  chunks; a buffering layer earns its place with a measurement.
- **Text decoding.** Bytes are bytes. `strings.from_bytes` and
  `strings.to_bytes` are the boundary, and they live where text lives.
