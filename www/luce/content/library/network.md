# std.network

`std.network` is the TCP transport: dial a host, open a listening door,
and move bytes. It is deliberately small — two classes, and nothing
else — and every operation that touches the world is fallible: a refused dial,
a taken port, or a reset peer arrives as an ordinary error carrying the
world's reason.

```text
import std.network
```

An open connection is a `Connection` and an open door is a `Listener` —
two distinct classes, so passing a door where a stream belongs is a
compile error. Each owns its descriptor privately; no raw handle enters
a program. There is no `close()`: the descriptor closes when the last
strong reference is released, exactly as a [`files.File`](/library/files/)
does, and using one after that traps like any use after free.

## Dial

```text
network.Connection.dial(host: str, port: i64) -> network.Connection!
```

`Connection.dial` resolves the name — `"localhost"`, a DNS name, or a
literal address — and dials it. The host owns how an address is found
and which family answers; no address vocabulary crosses into the
program. A world that refuses every road answers the error with the
reason it gave. A connection has two doors — dialing out, and being
accepted — and both ask the world, which is why `dial` is a static
function and `Connection` has no public `init`: there is no "make me a
connection from parts".

## Listen and accept

```text
try new network.Listener(port: i64) -> Listener!
listener.accept() -> network.Connection!
listener.port() -> i64!
```

A `Listener` is constructed the way any class is — with `new` — and its
`init` is fallible because opening the door asks the world.
`try new network.Listener(0)` opens a door on every interface: port `0`
asks for any free port, and `port()` answers which one landed — which
is how a program listens without claiming a number in advance. `accept`
waits for one peer and answers the connection; a server loops on it for
as long as it means to serve. A port another program holds is the world
saying no.

## Move bytes

```text
conn.read(buffer: array[u8, _]) -> i64!
conn.write(buffer: array[u8, _], count: i64) -> i64!
conn.flush() -> !
```

A `Connection` carries the same C-shaped byte channel a `File` does,
and conforms to [`io.Reader` and `io.Writer`](/library/io/), so
`io.drain` and `io.send` loop over one the way they loop over any
stream.
`read` fills a caller-owned buffer and answers how many bytes landed;
**zero is the end of the stream** — the peer released its last
reference, and the sentence is the same one a file ends with. `write`
hands over the first `count` bytes and answers how many landed, which
may be fewer; loop on both. Blocking is honest: `read` waits for bytes
and `accept` waits for a peer, and each holds only its own caller —
other workers keep printing and reading files while one waits.

## A whole conversation

```luce run
import std.network

func main() -> !:
    let door = try new network.Listener(0)
    let client = try network.Connection.dial("127.0.0.1", try door.port())
    let served = try door.accept()

    var word = new array[u8](2)
    word[0] = 104
    word[1] = 105
    var sent: i64 = 0
    while sent < 2:
        let landed = try client.write(word, 2)
        if landed <= 0:
            error("the write made no progress")
        sent += landed
    try client.flush()

    var heard = new array[u8](2)
    var got: i64 = 0
    while got < 2:
        let landed = try served.read(heard)
        if landed == 0:
            error("the peer finished early")
        got += landed
    print(str(heard[0]) + " " + str(heard[1]))
```

```output
104 105
```

Dialing before accepting works the way it does everywhere: the kernel
completes the handshake into the listener's backlog, and `accept` then
hands it over.

## Errors and absence

Everything here follows the [failure model](/guide/errors/) with no
additions. `io_failed` carries `cannot connect to HOST`,
`cannot listen on :PORT`, or `cannot accept on :PORT` plus whatever the
world said; there are no split error codes to match on, only the
message. A host with no transport channel at all — a build without
network access — traps `host_unavailable` at the first reached
operation, having touched nothing.

## Deliberately absent

- **`close()` and `with`.** One lifetime story: the last release
  closes. A second, manual one would make aliases unsafe.
- **Timeouts and socket options.** No knobs before a measured need.
- **TLS.** Planned as a later addition over platform TLS; today the
  transport is cleartext, which is what a local tool or an internal
  service needs first.
- **UDP.** Waits for a real customer.
