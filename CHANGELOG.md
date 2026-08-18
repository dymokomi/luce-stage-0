# Changelog

Luce is pre-1.0. The source language, module format, host ABI, package
manifests, and command-line surface may change between 0.x releases; each
release is a complete toolchain rather than a compatibility promise.

## Unreleased

- `std.zip`'s read path gets `zip.Archive`: opening -
  `let opened = try new zip.Archive(data)` - parses the central
  directory once, so a damaged archive fails where it is opened,
  `opened.entries()` cannot fail anymore, and `opened.extract(entry)`
  still can, because a bad local header or checksum belongs to the
  entry it is found on. `Writer` is a class made with
  `new zip.Writer()` - an accumulator with identity - and the free
  `zip.entries`, `zip.extract`, and `zip.writer` are gone.
- Construction idiom sweep: `math.Rng` is a class made with
  `new math.Rng(seed)` (a generator is stateful identity; the struct
  copy was a footgun) and the free `math.rng` is gone; `ui.Window`
  opens through its own fallible init - `try new ui.Window(title, w,
  h)` - and the free `ui.open` is gone; `gpu.Surface` is a class whose
  only door is the std-internal `from_handle` seam `ui` uses.
- `http.Client` and `Response` methods: a client carries a base URL and
  default headers (`var api = new http.Client("http://host")`,
  `api.header(name, value)`, `api.get("/path")`), and a `Response`
  answers `ok()` (200-299), `text()` (UTF-8 or absent), and `json()`
  (a `json.Json` document, or the error it says). Still one request
  per connection - no keep-alive pool, honestly. http's internals now
  ride `io.send`/`io.drain`.
- `std.io` arrives: the pure byte-stream contract. `interface Reader`
  (`read(buffer) -> i64!`, zero is the end) and `interface Writer`
  (`write(buffer, count) -> i64!`, `flush() -> !`), plus the two loops
  every stream shares — `io.drain(source)` reads a `Reader` to its end
  and `io.send(sink, data)` writes everything and flushes, erroring
  rather than spinning on a sink that accepts nothing. `files.File`
  and `network.Connection` conform, and a program's own type conforms
  by declaring the same functions. With the contract in place,
  opening moved onto the classes themselves: `files.open`/`create`/
  `append_to` became the `files.Mode` enum and a fallible
  `File` init — `try new files.File(path)`,
  `try new files.File(path, files.Mode.append)` — and
  `network.connect`/`listen` became
  `network.Connection.dial(host, port)` (a static function over a
  private init, because both of a connection's doors ask the world)
  and `try new network.Listener(0)`.
  `std.http` dials through `Connection.dial`; its public surface is
  unchanged.
- Selective imports: `from geo import Point, length as span` binds the
  named public members bare — any declaration kind — so a file writes
  `Point`, not `geo.Point`. The module namespace stays unbound unless a
  plain `import geo` also appears; members are checked where the import
  is written, and there is no wildcard form. `from`, like `as`, is
  contextual rather than reserved.
- Class construction now requires `new`: `var app = new Application()`,
  `try new File(path)`, and bare `new VStack` when no arguments are
  needed. `new` is the one keyword that makes a reference identity —
  it already builds containers (`new list[str]`, `new map[K, V]`,
  `new array[i64](5)`, `new builder`) and now builds classes the same
  way. Structs, enums, and unions keep plain call syntax
  (`Point(x = 1)`). A bare `ClassName(...)` call is a compile error:
  a class makes a new identity — write `new ClassName(...)`.
- `std.http` arrives: the HTTP/1.1 client in pure Luce over the
  transport. `get` and `post` answer a `Response` whose status is
  data — a 404 is an answer, not an error — with lowercased headers
  and a de-chunked body. One request per connection, sent with
  `Connection: close`; `https` is refused with the reason until TLS
  lands. Workers now inherit the transport channel, so a spawned
  function can listen and serve — the Library page runs a whole
  server-and-client conversation in one program.
- `std.network` arrives: TCP transport as two library classes,
  `Connection` (read/write/flush — the byte channel files carry) and
  `Listener` (accept/port), dialed with `Connection.dial(host, port)`
  and opened with `try new Listener(port)`; port 0 asks for any free
  port. No `close()` — ARC's
  last release closes, and a dropped peer reads as end of stream.
  Refusals are `io_failed` with the world's reason; a host without the
  channel traps `host_unavailable`. The socket callbacks run outside
  the host effect serialization and are thread-safe by contract, so a
  blocked accept never stalls another worker. Host ABI is 25;
  serialized module format is 58. TLS is deferred to a later bump.
- The builtin `file` type left the language. `std.files` now declares the
  ordinary ARC class `File` (with `read`/`write`/`flush` methods), and the
  raw descriptor currency — renamed `handle` — is spellable only inside
  embedded standard source, the same gate as `Builtin.NAME`. Programs may
  declare their own `file` and `handle` types; `weak` storage works on
  `files.File` as on any class. This is the Swift shape — descriptors live
  behind library session classes — and the pattern `std.network` will
  arrive wearing. Serialized module format is 57.

## 0.18 — release candidate

This is the published release candidate described by `VERSION` and the
checked installer under
`www/luce/install/0.18/install.sh`.

- ARC is the one lifetime model for classes, containers, closures, interfaces,
  files, tasks, windows, and GPU surfaces. Weak references break supported
  cycles, and workers copy permitted graphs without sharing identity.
- The language has explicit-width numeric types, `char`, `str`, `bytes`,
  transparent `alias`, final classes with custom initialization, nominal
  interfaces, multiple returns, recoverable errors, and local package
  creation/versioning commands.
- TermUI 0.3 and the bundled editor are ordinary Luce programs. TermUI owns
  the terminal loop and the editor can compile and run the current file.
- `std.ui` and `std.gpu` expose the current low-level host surfaces. Native
  window and Metal support is available on the published macOS target; other
  hosts fail closed where the service is unavailable.
- Host implementation operations are compiler-private to embedded standard
  modules. Programs use the namespaced `std.files`, `std.os`, `std.ui`, and
  `std.gpu` APIs, while names such as `clock_ms`, `dir_create`, and `append`
  remain available for their own declarations.
- The installer supplies `luce`, `loom`, the editor, runtime libraries,
  TermUI, and the VS Code/Cursor syntax extension on macOS 15+ ARM64 and glibc
  Linux 2.28+ ARM64/x86-64. Archives carry source identity, toolchain and
  ABI metadata, licenses, and reproducible tar/gzip metadata.

The complete release gate, clean-room journeys, and deployment proof have
passed for the published candidate. It remains pre-1.0: the source language,
module format, host ABI, package manifests, and command-line surface may still
change between 0.x releases.
