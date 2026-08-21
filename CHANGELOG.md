# Changelog

Luce is pre-1.0. The source language, module format, host ABI, package
manifests, and command-line surface may change between 0.x releases; each
release is a complete toolchain rather than a compatibility promise.

## Unreleased

- The standard library speaks typed errors (docs/ERRORS.md R2, the
  std sweep): the three pure-protocol modules declare what they fail
  with — `json.parse` and the whole parse path fail with `Malformed`,
  one member carrying the reason and the scalar position; `zip`'s
  archive path fails with `ZipError` (`Damaged` for bytes that lie,
  `Unsupported` for a capability the module lacks, `Io` for the
  disk); `http`'s request path fails with `HttpError`
  (`Unsupported`/`BadUrl`/`Protocol`/`Io`), and `Response.json`
  passes `json.Malformed` through whole.  Each module ships
  `describe`, rendering the member back into the one-line sentence a
  caller that only prints wants.  Where a typed module meets a
  bare-`!` host call — `zip.read` over `files`, the exchange over
  `network` — the `str` is caught and re-raised as the union's `Io`
  member: the visible conversion, demonstrated in std itself.
  `files`, `network`, `os`, and `term` stay on the bare `!`
  deliberately, because a host refusal is the world's own sentence.
  The specs now pin members and payloads with `match` rather than
  rendered strings, which is a stronger claim than the one it
  replaces.

- Errors are typed, and they are unions (docs/ERRORS.md R2): a
  fallible function may declare what it fails *with* — `-> i64 !
  ParseError`, where `ParseError` is an ordinary union — and
  `error(ParseError.unexpected(found = t, line = 3))` raises the
  value, `catch reason:` binds it, and `match` reads it apart with
  payload captures.  `try` passes the same error type up unchanged;
  a different one is caught and re-raised where the conversion is
  visible, never merged silently.  The bare `!` stays exactly the
  `str` message form it always was, so every existing program and
  signature keeps its meaning; the channel deep-copies the raised
  value so the unwind releases the frame's own, and `catch`'s
  binding adopts an owned copy.  Function types carry the same
  spelling: `func(str) -> Ast ! ParseError`.  MIR 70 -> 71
  (functions and signatures say what they fail with, `error_value`
  joins); the host ABI is untouched.

- Function types carry fallibility (docs/ERRORS.md R3): `func(i64)
  -> i64!` and `func(i64) -> !` are types, so failing functions are
  stored, passed, and called through values — a pass pipeline is a
  list at last.  The obligation travels with the type: a call
  through a fallible value owes `try` or `catch` exactly as a
  direct call does, a trap still unwinds immediately, and the door
  is one-way — a non-fallible function converts into a fallible
  slot (it trivially keeps the promise), while a fallible function
  refuses a non-fallible slot with the fix in the sentence.  Bound
  methods follow the same rule.  Along the way the probe exposed
  and fixed an old gap: a bare function name now lands in an
  optional container element implicitly, so the prescribed
  `[(func(i64) -> !)?]` spelling really works.  MIR 69 -> 70 (the
  signature table gains the fallible byte); the host ABI is
  untouched.

- A match arm names its captures itself: `word(bound)` binds the
  member's field by **position** under the arm's own name (Swift's
  shape, docs/UNION.md D21) — so two nested matches on one member no
  longer collide over the field's name.  An arm still binds every
  field in order or none, a name may not repeat inside one arm, and
  no existing arm changes meaning: the audit found every field-named
  capture in the tree already in declaration order.

- Deadlines arrive at the channel (docs/CANCEL.md, the ratified
  channel half): `c.receive_by(expires_ms)` waits for what is left
  of one absolute moment on the monotonic clock and answers absence
  once it has passed — so one budget spans a whole exchange.  The
  language primitive is a scalar (ruling A: the `handle` precedent —
  no std type crosses into a language signature); `os.Deadline` is
  the pure-Luce wrapper: `os.deadline(ms)` builds the moment,
  `stop.expires` feeds each call, `remaining_ms()` and `passed()`
  read what is left.  Both engines read the host's own clock at the
  call, so a deadline means the same thing everywhere; without a
  host the call traps `host_unavailable`, the FFI's precedent.
  `receive_timeout(ms)` stays as the one-step sugar.  MIR 68 -> 69;
  the host ABI is untouched.

- Recursive unions arrive: `indirect union Expr:` lets a member hold
  the union itself — `add(left: Expr, right: Expr)`, no optional, no
  wrapper class — by moving the payload behind one hidden ARC box
  (docs/UNION.md D20, Swift's `indirect enum` under the constitution).
  The tag stays inline so match dispatch and the tag test read no
  box; a payload-less member allocates nothing; copies retain the box,
  which payload immutability makes observably identical to a deep
  copy; workers and channels deep-copy the graph with aliases
  preserved.  The first member is still the union's zero, so it may
  not hold the union itself — refused with the fix in the sentence —
  and a value union that contains itself keeps its refusal and its
  `T?` remedy.  The word is contextual like `blocking`.  MIR 67 -> 68;
  the host ABI is untouched.

- A plan's step learns to link: `app.link("gen.o")` on a
  `std.build` program or library step carries an object, an
  archive, or a `-lNAME` request into that step's native link,
  exactly as `luce build --link` spells it — so a command step can
  compile C and the program step can call it through an extern.  A
  command step runs and an object step stops before linking, so
  `link` refuses both in the script, and the executor refuses an
  object step whose hand-forged plan carries links anyway.  Link
  inputs are the project's names like source and output; `-l`
  requests and absolute paths pass through as spoken.

- `std.c` opens the scoped buffer door: `c.with_bytes(buffer, body)`
  hands `body` the address of a `list[u8]`'s bytes as a `foreign`
  token for exactly one call (`with_bytes_foreign` for a callee that
  answers a token), and `c.zstring(text)` builds the NUL-terminated
  bytes C expects for text.  Underneath is one new std-only
  intrinsic, `Builtin.buffer_address`, carried by a `buffer_address`
  MIR instruction the verifier types as `list[u8] -> foreign` and
  both engines answer through the same runtime — an empty list hands
  over the null token.  A token that escapes the scope is dangling
  by contract; the guarantees still end at the boundary.
  MIR 66 -> 67; the host ABI is untouched.

- The FFI arrives (docs/FFI.md): `extern func name(a: i64) -> i64`
  declares a foreign function's C shape — no body, no defaults, no
  fallibility, at most eight parameters, every type a 32- or 64-bit
  integer or the new opaque `foreign` token (results add `f64`) — and
  a call is a direct machine call on the compiled path and a dispatch
  through the runtime's thunk shim on the oracle, under the effect
  lock unless the declaration says `blocking`.  `luce build`'s
  repeatable `--link INPUT` carries objects, archives, and `-lNAME`
  requests into the native link, so a `cc`-compiled C file is embedded
  and called through its extern — and an extern-declared
  `LLVMContextCreate()` against the vendored libLLVM works, which is
  the self-hosted back end's first breath.  Guarantees end at the
  boundary and the docs say so.  MIR 65 -> 66; the host ABI is
  untouched.


- Unions gain the one comparison there is — the tag test: `u ==
  Shape.dot` and `!=` against a payload-less member literal ask
  which member this is, and equal tags mean equal values because the
  literal side has no payload to differ (the #24 ruling — Zig's
  `u == .dot`).  Everything else stays match's: two held values, a
  payload-carrying literal, and a union inside a struct keep their
  refusals.  Also pinned: an unbroken `while true` diverges (no
  trailing return owed), and one with a `break` still owes its
  return — already true at head, now specified.


- Lists learn `extend`: `xs.extend(ys)` appends every element of
  another list of the same type, in order (the #24 ruling under the
  Zig tiebreaker — appendSlice).  The source is read, never consumed;
  an element with private storage lands as the target's own copy; and
  a list extended with itself gains exactly one round of itself,
  because the count is read before the first append.  MIR format
  64 -> 65.


- Character literals are contextual over integer widths, on the same
  terms as numeric literals: written into an integer place, `'a'`
  lands as that integer when its Unicode scalar fits — `c == '"'`
  over a `u8`, a `'0' .. '9'` match arm, a newline-escape constant —
  and one that does not fit is a compile error.  With no integer
  context a character literal is a `char`, unchanged.  Only literals
  are contextual; a runtime `char` still reaches a number only through
  `u32(character)`.  (The self-host lexer probe's magic-number
  friction, ruled under the Zig tiebreaker through Luce's own
  contextual-literal rule.)


- The build system completes its first shape: a `build.luc` beside
  `luce.yaml` is the project's build script — an ordinary compiled
  Luce program that declares a plan with the new pure-Luce `std.build`
  (`Plan`, steps for Luce artifacts and host commands, `needs` edges,
  `emit()` printing one versioned JSON document) — and a bare
  `luce build` compiles the script through the ordinary cache, runs
  it in the project root, and executes the chosen step's closure in
  dependency order.  The compiler pipeline never learns what a build
  is: no ABI slot, no intrinsic, no MIR movement.

- `luce install` fills the package store from the manifest alone: a
  `packages:` row may carry `url:` beside its exact version, a fetched
  row must carry `sha256:` — the same tree hash the resolver already
  verifies, computed over the unpacked archive — and the verified tree
  lands in `.luce/packages/` in one rename, so a killed install never
  leaves half a package where imports resolve.  Idempotent: an
  installed row is re-verified and skipped.  `https` required except
  on the loopback host.

- A bare `luce build` builds the project: the `luce.yaml` governing
  the working directory gains an optional top-level `main:` key naming
  the project's entry source, and `luce build` with no file expands to
  exactly the file form, options unchanged.  Without a manifest, or
  without the key, the bare form refuses and says which of the two to
  add — no convention scan.

- The filesystem completes: `files.size` and `files.modified` are the
  two stat facts a build tool stands on; `files.copy` streams one
  file's bytes in constant space and `files.move` renames with a
  copy-then-delete fallback — both pure Luce over the byte channel,
  no new host promise; `files.remove_directory` takes one empty
  directory and `files.remove_all` takes a whole tree, removing a
  symbolic link as a link and treating absence as success, the
  `make_directory` idempotence rule mirrored.  Four host slots
  (`path_size`, `path_modified`, `dir_remove`, `tree_remove`) join
  the table — ABI 29 → 30, MIR format 63 → 64 — and the differential
  harness's world grows from one file to a small set with several
  open handles, so a streaming copy is proven short-write by
  short-write on both engines.

- Channels: `channel[T]` is a bounded conduit between workers and the
  one reference a boundary admits. `send` parks a deep copy and
  `receive` rebuilds it in the receiver — no identity ever crosses,
  and mutating a value after sending it is always safe. Blocking,
  try, and timed forms; close is idempotent, drains before it
  refuses, and answers a recoverable error, never a trap; FIFO and
  per-sender program order are promised, waker order deliberately
  not. Element sendability is checked where the channel is written.
  Both engines agree on all of it, the leak census stays exact
  across workers, and ThreadSanitizer holds the whole suite
  race-free. MIR format 62 → 63.

- A key knows what was held with it: `std.term`'s `Event.key` answers
  a `KeyPress` — the key plus `shift`/`alt`/`control` booleans — and
  the host decodes the xterm CSI modifier parameter, alt's
  ESC-prefixed word keys, and bracketed paste (a paste is ONE text
  event and one undo step). A ctrl+letter stays its distinct
  `Key.ctrl_a`..`ctrl_z` member. Modifiers ride the same event slot a
  mouse report uses, so no ABI change.
- `term.copy(text)` hands text to the system clipboard through the
  terminal (OSC 52), so a copy works over SSH and inside a
  multiplexer. One new host slot at the end of the ABI table
  (version 25 → 26); the `term_copy` intrinsic joins MIR
  (format 58 → 59).
- The editor edits like an editor: shift+movement extends a selection
  (anchor in the Document; every edit selection-aware by
  construction), alt/ctrl+arrows jump words, alt+backspace erases
  one, Ctrl-A selects all, and Ctrl-C/X/V copy, cut, and paste — the
  whole-line gesture when nothing is selected, every copy also on the
  system clipboard. Selected text draws on its own background,
  a mouse drag or shift+click extends the selection, and escape,
  search jumps, and undo drop it. A ninth scripted session drives
  selection, clipboard, and drag through both engines.
- termui's surface is grouped into public submodules, so an import
  line says what it brings: `from termui import Application, View`
  carries the contract and vocabulary, and `termui.layout` (the
  stacks), `termui.constraints` (`Constraint` and the shipped sizes),
  and `termui.widgets` (the leaf and wrapper components) carry the
  rest. The facade no longer aliases what the groups own, and
  `visible_top` is spelled where it lives: `Rows.visible_top`.
  Internally `components.luc` split into `widgets.luc` and
  `layout.luc`, and the solver moved to `constraints.luc`; `model`,
  `input`, `canvas`, `view`, and `runtime` stay implementation
  boundaries behind the facade.
- The editor's sources say what they are: the panes and their
  chrome live in `ui/` (`workbench`, `source`, `filelist`, `console`,
  `statusbar`, `keymap`, `theme`) as project submodules imported as
  `from ui.filelist import FileList`; `browser.luc` is renamed
  `listing.luc` (it lists a directory - the file list is the UI);
  `Focus`, `Intent`, and the search scan fold into `model.luc` (the
  model speaks intents, the keymap only maps keys to them); the build
  shell folds into `session.luc` beside the other host seams; and
  `focus.luc`, `search.luc`, and `shell.luc` are gone. The
  highlighter's helper predicates are `private`; its surface is
  `tokens`, `Token`, and `TokenKind`. Eight scripted sessions replay
  cell-identical across the reorganization.
- `Constraint` is an interface - `minimum()`, `maximum()`, `weight()`,
  `preference(axis)` - and the sizes are classes conforming to it:
  `Fixed(cells)`, `Grow(weight, minimum)`, `Ratio(low, high, percent)`,
  `Preferred(low, ideal, high)`. A layout reads
  `layout.add(FileList(model), Fixed(0))`, and a program's own
  constraint kind lays out exactly like a shipped one. The solver's
  arithmetic is unchanged; the editor's sessions replay cell-identical.
- The `new` keyword leaves the language: everything constructs by
  call. Classes construct as `Counter()`; containers as `list[i64]()`,
  `map[str, i64]()`, `array[i64](5, 5)`, and `builder()`; a container
  alias constructs under its own name (`Cells()`, `models.Users()`),
  and literals `[]`/`{}` are unchanged. The compiler always knows what
  a name is, capitalization carries the reader, and `spawn` remains
  the one word that makes a resource. The whole tree - standard
  library, termui, the editor, examples, benchmarks, specifications,
  and documentation - migrates in this change, and the vocabulary
  tripwires (the reference's keyword table, both highlighters, and
  the TextMate grammar) move with the compiler's own word list.
- A size is a `Constraint`, because that is what it is: `Length` the
  four-member union is gone, and in its place one value struct carries
  `minimum`, an optional `maximum`, a `weight` for surplus, and an
  optional preference (`ideal` cells or a `share` of the axis). The
  `fixed`/`grow`/`ratio`/`preferred` constructors and the solver's
  behavior are unchanged - the editor's sessions replay
  cell-identical. `from` and the member-renaming `as` now highlight on
  import lines (they stay contextual words in the language), and the
  editor pane's minimum width is `Editor.minimum_columns()` - the
  pane's own knowledge - instead of an imported constant.
- The editor's domain is classes: `Document` owns a file's text,
  cursor, scroll, dirty flag, message, and its own `History` (undo and
  redo as methods on one owned stack), so the model holds a list of
  documents and an active index - the remember/restore park-dance and
  its six cached fields are gone, and switching files is switching a
  reference. `Selection` is a class, which ends the copy-out/copy-back
  window dance. The pure line and boundary arithmetic stays free: it
  answers questions about any text, the output transcript included.
- termui 0.5.0: the tree is retained. `Application` is a class -
  `Application()`, `set_layout(root)`, `start()` - and the
  `body()` interface with its rebuild-each-frame protocol is gone.
  Components are constructed once (typically with the model they
  observe), keep their own pane state for the life of the run, and the
  loop redraws the retained tree after every event; stacks reshape
  with `resize(index, size)`, and a hidden pane is a zero-cell slot.
  A component reacts to model changes by subscribing with a
  `[weak self]` closure - the model holds `list[(func())?]` watchers
  and never owns its components, which is the cycle discipline ARC
  demands. The editor decomposes accordingly: a shared `Model` plus
  retained `FileList`, `Editor`, `Console`, and `StatusBar`
  components and a `Workbench` that reshapes the layout through its
  subscription - and its differential sessions replay cell-identical.
- `match` takes value scrutinees: an integer, `char`, `str`, or `bool`
  dispatches by literal arms - exact values, several per arm behind
  commas (`1, 2:`), and inclusive `low .. high` ranges for the ordered
  scalars (`0..9:`, `'a'..'z':`). The first arm that admits the value
  wins, so overlapping ranges are a style question - but the same
  exact literal twice is a dead arm and is refused. `else` is required
  unless the arms provably cover everything, which only `bool`'s
  `true` and `false` can. A float scrutinee is refused: floats never
  match a literal exactly, and `if` with a tolerance says what is
  meant. `..` is a new token, and a folded constant counts as a
  literal the compiler can read.
- termui 0.4.0: `View` becomes a public interface -
  `draw(surface, area) -> Cursor?` and `dispatch(event, area) ->
  Response` - and the shipped components become classes conforming to
  it, so a program's own component participates in layout, drawing,
  and routing exactly like a shipped one. Stacks compose with
  `VStack(spacing = 0)` and `add(child, size = none)` (absence
  means grow); behavior and cursor placement wrap as
  `EventHost(content, respond)` and `new CursorHost(content,
  locate)` in place of the `.sized/.on_event/.cursor` modifier chain;
  `route(child, event, area)` is the one door a container dispatches
  through, owning the lifecycle and pointer-containment pre-checks.
  Border merging lives in `Surface.stroke`, so any component's
  borders meet any other's with the right junction. The public `Item`
  struct, the view union, and the constructor functions are gone; the
  rebuild-each-frame protocol and `snapshot` testing are unchanged,
  and the editor replays its differential sessions cell-identical.
- The terminal moves into its own module: `std.term` is now the real
  terminal - frame drawing (`rows`/`cols`, `clear`/`move`/`style`/
  `write`/`flush`), typed input, and the border glyphs with
  `junction` - and `std.os` keeps console, time, environment, process
  and machine services. Input is one stream of values:
  `term.read() -> Event?` answers a `key(Key)`, `text(str)`,
  `mouse(Mouse)`, or `resize` event copied whole before it returns,
  and `none` at end of input. The `os.term`/`os.term.io`/`os.term.ui`
  facade structs, their token fields, and the hidden most-recent-event
  accessors (`io.text/row/column/button/modifiers/value`) are gone;
  `os.shell.run` is now plain `os.run`. termui's `Key`, `Pointer`,
  and `Mouse` become aliases of `std.term`'s, so termui events and
  plain terminal events are the same values.
- `std.zip`'s read path gets `zip.Archive`: opening -
  `let opened = try zip.Archive(data)` - parses the central
  directory once, so a damaged archive fails where it is opened,
  `opened.entries()` cannot fail anymore, and `opened.extract(entry)`
  still can, because a bad local header or checksum belongs to the
  entry it is found on. `Writer` is a class made with
  `zip.Writer()` - an accumulator with identity - and the free
  `zip.entries`, `zip.extract`, and `zip.writer` are gone.
- Construction idiom sweep: `math.Rng` is a class made with
  `math.Rng(seed)` (a generator is stateful identity; the struct
  copy was a footgun) and the free `math.rng` is gone; `ui.Window`
  opens through its own fallible init - `try new ui.Window(title, w,
  h)` - and the free `ui.open` is gone; `gpu.Surface` is a class whose
  only door is the std-internal `from_handle` seam `ui` uses.
- `http.Client` and `Response` methods: a client carries a base URL and
  default headers (`var api = http.Client("http://host")`,
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
  `File` init — `try files.File(path)`,
  `try files.File(path, files.Mode.append)` — and
  `network.connect`/`listen` became
  `network.Connection.dial(host, port)` (a static function over a
  private init, because both of a connection's doors ask the world)
  and `try network.Listener(0)`.
  `std.http` dials through `Connection.dial`; its public surface is
  unchanged.
- Selective imports: `from geo import Point, length as span` binds the
  named public members bare — any declaration kind — so a file writes
  `Point`, not `geo.Point`. The module namespace stays unbound unless a
  plain `import geo` also appears; members are checked where the import
  is written, and there is no wildcard form. `from`, like `as`, is
  contextual rather than reserved.
- Class construction now requires `new`: `var app = Application()`,
  `try File(path)`, and bare `VStack()` when no arguments are
  needed. `new` is the one keyword that makes a reference identity —
  it already builds containers (`list[str]()`, `map[K, V]()`,
  `array[i64](5)`, `builder()`) and now builds classes the same
  way. Structs, enums, and unions keep plain call syntax
  (`Point(x = 1)`). A bare `ClassName(...)` call is a compile error:
  a class makes a new identity — write `ClassName(...)`.
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
  and opened with `try Listener(port)`; port 0 asks for any free
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
