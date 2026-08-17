# Network: the TCP transport

`std.network` is the transport layer: TCP connections and listeners as
ordinary library classes over the std-only `handle` currency
(docs/BYTES.md R5). This document owns the design decisions;
[the Library page](https://luce.luciaos.com/library/network/) is the
user-facing API reference.

## The shape

Two nominal classes and two doors:

```luce
import std.network

func main() -> !:
    let door = try network.listen(0)
    let client = try network.connect("localhost", try door.port())
    let served = try door.accept()
```

- `network.connect(host, port) -> Connection!` dials. Name resolution
  is the host's: a program says where it wants to go, and how an
  address is found — literal, DNS, which family answers first — never
  crosses the boundary.
- `network.listen(port) -> Listener!` opens a door on every interface.
  Port `0` asks for any free port; `listener.port()` answers which one
  landed.
- `listener.accept() -> Connection!` waits for one peer.
- A `Connection` carries the byte channel files carry — `read(buffer)`,
  `write(buffer, count)`, `flush()` — with the same contract: reads and
  writes may be short, zero read is the end of the stream, and the
  caller loops.

`Connection` and `Listener` are distinct classes, so handing a door
where a stream belongs is a compile error. Each privately owns its
descriptor; no raw handle enters a program. This is the Swift shape —
`NWConnection` and `NWListener` are separate session classes over a
hidden descriptor — chosen deliberately after reading how SwiftNIO and
Network.framework layer the same problem.

## Lifetime

There is no `close()`. A connection or listener closes at its last
strong release, exactly as a `File` does, and use after that traps
`use_after_free`. Dropping the last reference to one end of a
connection is the other end's end of stream: the peer drains what was
written and then reads zero.

## Errors

The transport follows docs/FAILURE.md with no additions. A refused
dial, a taken port, a reset peer are the world deciding: `io_failed`,
carrying `cannot connect to HOST`, `cannot listen on :PORT`,
`cannot accept on :PORT` plus whatever the world said. There are no
split errno codes — the message is the story. A missing transport
channel traps `host_unavailable` before touching anything. An HTTP
status code, in `std.http` above this module, is data, never an error —
`os.shell.run`'s "a non-zero exit is data" rule, transferred.

## Concurrency: the one deliberate exception

Host effects are serialized by one process-wide Effects guard
(docs/THREADS.md D9), held across every callback so a printed line is
atomic. The transport channel is the deliberate exception: `accept`
and a socket `read` block for a **peer** — seconds, or forever — and a
worker blocked inside the guard would freeze every other worker's
printing and file I/O for the duration.

So the socket channel's callbacks run outside the guard and are
required to be thread-safe. The host keeps its registry behind its own
short-held mutex and makes the blocking system call outside every
lock. This is sound on the language side because resources never cross
a worker boundary: the one socket a blocked read holds cannot be
closed concurrently, and the only true concurrency is different
sockets on different workers — exactly what the registry mutex exists
for. `runtime/sockets.zig` owns this contract; `codegen/abi.zig`
version 25 publishes it.

Connected sockets travel the ordinary `handle_read`/`handle_write`/
`handle_flush` slots — the handle is the interface, which is what
those slots' names always promised — and `runtime/files.zig` skips the
Effects guard exactly when the resource kind says socket.

## What a server will build on

`std.server` (planned) is multithreaded, and the constraint that
shapes it is already fixed: resources cannot cross a worker boundary,
so connections cannot be accepted in one worker and handled in
another. The transport was built for the pre-fork shape instead —
`accept` is callable concurrently on a shared host listener from
several workers — and how workers come to share a listener is a
decision `std.server` will make without changing this module's public
surface.

## Deliberately absent

- **`close()` and timeouts as configuration.** One lifetime story, and
  no knobs before a measured need; the language has no cancellation
  primitive for a timeout to compose with yet.
- **Peer addresses.** Nothing consumes one today. When server logging
  wants it, it is one appended channel slot away.
- **UDP, half-close, socket options.** Each waits for a real customer,
  not an imagined one.
- **TLS.** Deferred by decision, not oversight: it arrives later as
  appended channel slots over platform TLS, in an ABI bump of its own.
  The append-only table makes that clean.

## Verification

`specs/network_spec.zig` runs the surface on both engines over the
simulated world in `specs/hosts.zig`: the round trip through short
writes, the peer-close end-of-stream, refused dials and doors, and the
fail-closed missing channel. The world refuses where reality would
block — a single-threaded oracle cannot wait for a peer — so blocking
behavior is proven on the real host by `tests/std/network_test.luc`
and `tests/std/http_test.luc` (`zig build test-std-userland`): ordinary
`luce test` suites where a worker blocks in `accept` while its client
retries the knock, and a Luce HTTP server answers a Luce client over
the machine's own loopback.
