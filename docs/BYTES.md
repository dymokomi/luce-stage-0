# Bytes — the binary half of the host boundary, done as language

**Owner directive, 2026-08-06**: *"we need to fix this and not patch —
fix so that it's done correctly … it has to be part of the language and
we need to update std.io it seems as well."*  "This" is the std.zip
run's headline finding, measured rather than assumed: **Luce cannot
read or write an arbitrary binary file in either direction.**
`src/apps/host.zig`'s `loadFile` rejects anything that is not valid
UTF-8 (deliberately — a half-read JPEG pretending to be a `string`
would make every string guarantee a lie), and the writing direction is
closed by construction, because a `string` *is* valid UTF-8 and nothing
can build one that is not: `chr(200)` is a codepoint encoder answering
two bytes, and `builder.append_ascii` traps past 127.  So `std.zip`
shipped as a complete byte-buffer library that no real archive can
reach.  This memo is the fix, in three parts that are each the
long-term shape rather than the least change.

## What the zip run measured

- `list(byte)` costs **24 bytes per element** — `docs/TYPES.md`
  ("`List` and `Map` stay boxed, and this is said rather than hidden")
  records the price and names the alternative: *"a packed `List` is a
  genuinely new mechanism — growable, boxed API."*  The zip module
  used `list(long)` as the honest least-bad buffer, at 24× the payload.
- `array(byte, n)` is already packed — the `ElementKind` machinery
  stores array elements at real width — but an array cannot grow, and
  a file being read does not announce its length in advance.
- The host gap is exactly **one service each way**: a read that does
  not validate, a write that takes bytes rather than text.  Everything
  else — ownership, slices, the checked arithmetic a CRC needs —
  already exists and was proven by the zip run itself.

## Part one — the buffer: unbox `list` element storage

**The proposal is not a new type.**  `list(byte)` is already the right
surface: growable, owned by scope, indexable, sliceable, iterable, and
spelled with the vocabulary every Luce program already knows.  What is
wrong with it is only the storage, so the fix is storage: **`list(T)`
adopts the `ElementKind` mechanism arrays already have**, storing
scalar elements at their real width — `list(byte)` at one byte per
element, `list(long)` at eight instead of twenty-four — with `Value`
remaining the boundary type at `at`/`put` exactly as it is for arrays
today.  Strings, structs and objects keep the tagged slot, as they do
in arrays, and `map` is untouched (its cost is the entry, not the
element, and nothing here needs it).

This is the fix a maintainer is glad of in a year: no second buffer
type to teach, no `bytes` literal grammar, no conversion surface
between "the byte container" and "the list of bytes" — and every
scalar list in every program gets three times smaller as a side
effect.  The compiled path loads and stores elements with one
instruction either way; the interpreter calls the same `libluce_rt`
accessors it calls now.

## Part two — the host channel: handles, buffers, and text as a reading

Today the host's file services *are text*, whole-file, and
path-addressed: `file_read` validates UTF-8 inside the host and
answers everything at once.  The honest architecture (R4, R5) inverts
all three: **a file is bytes reached through an open handle, a read
fills a caller-owned buffer and says how much landed, and text is a
validation the language performs on the bytes.**

- **The handle is a scope-owned resource** — a new object kind whose
  create is `open` and whose scope-end release is `close`, so a file
  cannot leak by the same construction that keeps every list from
  leaking, and use-after-close traps like use-after-free because it
  is the same mistake.  `give`, `return` and early `free` mean what
  they always mean.  The run's design decides the type's spelling and
  where it sits in `types.HeapType`; the ownership semantics are not
  open — they are OWNERSHIP.md's, unchanged.
- `LuceHost` gains appended handle-channel slots — open, read into a
  buffer answering the count, write from a buffer, flush, close —
  carrying raw bytes with no opinion about encoding.  Fail-closed
  like every service, `yes`/`no`/`exhausted` like every fallible one;
  `abi.version` bumps once for the whole movement.
- **UTF-8 validation moves out of the hosts and into `libluce_rt`**,
  the one implementation of every semantic: `file_read` (the
  whole-file text convenience, unchanged in surface and meaning)
  becomes open-read-close over the byte channel followed by the
  runtime's own validation, so the interpreter, the compiled
  artifact, and every future host agree byte-for-byte on what "not
  text" means — today that sentence lives in `host.zig` where only
  loom can say it.
- The existing whole-file text slots are retired from use in the same
  movement (the vtable stays append-only and nothing reorders; a
  version-bumped artifact never indexes them, and the version is
  already how a stale artifact is refused by name).
- The gate is unchanged in principle: the handle builtins sit behind
  `allow_host` like every effect, and fallibility follows
  `docs/FAILURE.md` — `open` and `read` answer `T!`, because the
  world decides.

## Part three — the std surface

The owner's "std.io" is today spelled `std.files`, and it grows the
binary half plus the bridges:

- `files.open(path)` and the handle's own surface — read into an
  `array(byte, n)` answering the count, write from one — plus the
  whole-file conveniences `files.read_bytes(path) -> list(byte)!`,
  `files.write_bytes`, `files.append_bytes`, each a loop over the
  primitive the way Go's `os.ReadFile` is a loop over `Read`.
- `strings.to_bytes(s) -> list(byte)` (a string always has bytes) and
  `strings.from_bytes(xs) -> string?` — the parse direction: "not
  UTF-8" is the same reason every time, so absence carries all the
  information, the `parse_int` precedent.
- `std.zip` then does what it was always for: `zip.read(path)`,
  `zip.write(path, ...)` over real archives on disk, and its
  `list(long)` buffers become `list(byte)` at a quarter the memory.
  The five collapsed "not text" reasons in `zip.text` become one
  honest `string?`.

## Ratified (owner, 2026-08-06)

All three questions answered with the memo's recommendation, the same
sitting as the directive itself:

| | ruling |
|---|---|
| **R1** | **Unbox `list` scalar storage.**  `list(byte)` is the byte buffer; no new type.  Part one is the design. |
| **R2** | **Bytes underneath, text as validation in `libluce_rt`.**  Host file slots carry raw bytes; the text builtins are defined over them; the old text slots retire behind the `abi.version` bump.  Part two is the design. |
| **R3** | **`strings.from_bytes` answers `string?`** — the parse case, the `parse_int` precedent. |
| **R4** | **The primitive is C-shaped: read into a caller-owned buffer, answering the count** (*"generally we want reading bytes into array and write just like real languages like C"* — owner, same sitting).  `array(byte, n)` is the buffer — already packed, already fixed — and whole-file read/write demote to `std.files` conveniences built over the primitive, the Go/Rust layering.  The same shape serves sockets in `std.network`, where whole-read does not exist. |
| **R5** | **File handles enter the language in this run, as scope-owned resources.**  `files.open(path)` answers a handle; reads advance it; the owning scope's end closes it — deterministic close is exactly what scope ownership is for, and `give`/`return`/`free` mean for a handle what they mean for every object.  Doing the channel path-shaped now and handle-shaped again for sockets would have been the patch-shaped choice; this run bumps the ABI once, and `std.network` reuses the resource pattern for sockets. |

## The questions, as they were argued

**Q1 — the buffer type.**  Unboxing `list` scalar storage
(recommended, part one above) keeps one container vocabulary and
fixes every scalar list; the alternative is a dedicated `bytes` heap
type (Python's `bytearray` shape) — a smaller diff now, a second
buffer type forever after.

**Q2 — the host channel.**  Bytes-underneath with text-as-validation
in `libluce_rt` (recommended, part two) makes hosts dumber and both
engines agree on "not text" by construction; the alternative appends
binary slots *beside* the text slots and leaves validation in each
host — less movement, two channels forever, and loom's opinion of
UTF-8 stays loom's.

**Q3 — `from_bytes`'s answer.**  `string?` (recommended — one failure
reason, the parse case) or `string!` (the files shape, a reason
carried, for symmetry with the module it lives beside).

## As built (2026-08-07)

Built in two verticals, both engines, one run.  R1 is storage and
moves nothing a program can see; R2, R4 and R5 are one movement and
spend one `abi.version` between them.  The rulings left several
questions open that the code had to answer; each is here with the
reason, and each has a spec in `specs/bytes_spec.zig`.

| | decision, and where it is proved |
|---|---|
| **B1** | **The shape a List and an Array share is `Object.Elements`, hoisted to a row field.**  Part one said `list` adopts the `ElementKind` mechanism; what it does not say is where the mechanism lives, and duplicating a nine-arm `at`/`put` switch would have been two places for one storage semantic.  So `kind`, `bytes` and `count` are one struct, and the row holds it beside `dims` — a *row* field for the reason an Array's storage already was one: generated code walks it at a measured `@offsetOf`, and Zig promises nothing about a tagged union's payload.  The only difference between the two containers is that a List's `bytes` runs ahead of its `count` and an Array's does not, because an Array never grows.  `Data.list` and `Data.array` are payload-free tags now. |
| **B2** | **`new list(T)` is handed the element zero, exactly as `new array` is.**  The runtime deliberately does not know the program's type table, and the zero's tag *is* the type — the sentence `ElementKind.of` already stood on.  Nothing new crosses the boundary; `luce_rt_new_list` takes one more `Value` and both engines pass it. |
| **B3** | **A list the *runtime* builds is a `.value` list, whatever its element type.**  `m.keys()`, `m.values()`, `dir_list` and `args` are built out of stored `Value`s and the runtime has no type to read a kind from.  A boxed cell holds anything and hands back exactly what was put in it, so this is always correct and only ever costs memory; `list_slice` and `copy` preserve the source's kind, and `new list(T)`, which does know the type, packs.  Said out loud in `containers.zig` rather than left to be discovered. |
| **B4** | **`capacity()` is not on the hot path.**  Element arithmetic in `ensureCapacity` divides by a width the compiler does not know, and one integer division per `append` measured as a real cost on the `strings` benchmark.  The growth arithmetic is in bytes; the division survives only where a reader asks for a capacity. |
| **B5** | **The handle's type is spelled `file`, and it sits in `types.HeapType` as `.file`.**  A heap type because scope ownership is what gives a resource a death point, and it is the resource half of `HeapType` rather than a fifth container: no element type, no `new`, and the only door in is `files.open`.  `file_methods` in stage 4 is `read`/`write`/`flush`, and there is deliberately no `close` — `free(f)` is one and the end of the owning scope is the other.  `std.network`'s sockets are meant to arrive beside it wearing the same pattern, which is the whole reason the shape carries no container vocabulary. |
| **B6** | **The channel is installed into `libluce_rt`, not read at each call.**  This is the decision the close forces, and it is the one that decided the whole architecture of part two: a scope's end arrives inside the ownership walk, where no generated code is standing to hand a host table in.  So `luce_rt_files_install` takes the five pointers once, `Runtime.files` holds them for the run, and the runtime calls them.  The consequence is better than the requirement: both engines install *literally the same five function pointers*, so the interpreter and a compiled artifact reach one implementation of what an open answers, what a short read means and when a close happens — and the four intrinsics lower to plain `luce_rt_*` calls rather than to host-slot code. |
| **B7** | **The five slots are `handle_open`, `handle_read`, `handle_write`, `handle_flush`, `handle_close`**, appended in that order at `abi.version` 12.  Named for the handle rather than for the file, because the same five serve a socket; `file_read` and its siblings kept their names and their positions and are simply not filled any more.  Mode is a number on the slot (0 read, 1 write, 2 append) and a named door in `std.files`: a builtin speaks what the host slot speaks, and the library is where it gets a name. |
| **B8** | **A handle remembers the path it was opened at.**  "The read failed" without saying which file is a message that helps nobody, and a handle two hundred lines from its `open` is exactly where a reader has stopped being able to supply the name themselves.  The bytes are the object's and go back with it.  `FileAct` gains `open` and `flush`, appended. |
| **B9** | **The runtime raises the `io_failed` itself.**  It is the side that knows the path, so the exports take the raise site (`function`, `instruction`) and record the error; what reaches generated code is one flag to branch on.  `emitFileRead` went from a host call, a branch and an intern to one call. |
| **B10** | **A method can be fallible.**  Nothing before the byte channel needed one — every fallible thing was a free builtin — so `lowerMethod` simply never opened an outcome.  `f.read(buffer)` needs `try` or `catch` for the same reason `file_read` does, and a site that says neither is `luce.sema.fallible` rather than a silently dropped outcome. |
| **B11** | **`parse_string(xs) -> string?` is the primitive R3 needs.**  `strings.to_bytes` is an ordinary Luce loop over `byte_at`, but `from_bytes` is a *validator*, and a second UTF-8 validator written in Luce would be a second implementation of a semantic.  So the parse family takes a third member, named for what it produces exactly as `parse_int` and `parse_float` are, and `strings.from_bytes` is its one-line surface.  A packed `list(byte)` *is* its bytes, so the validator reads the run in place — which is R1 paying for R3. |
| **B12** | **`copy f` and `new file` are refused by name, in stage 4.**  A second Luce handle on one open file would be two owners of one resource, which is the thing scope ownership exists to make impossible; a `file` with no file behind it is the one state the type must never hold.  Both have a wall behind them in the runtime and the verifier for IR that arrived some other way — a `.lcm` reaches the backend without passing the analyzer. |

**The folded ruling, and what survived of the cap.**  The flat
`max_array_elements = 1 << 24` is gone: it was a policy number
denominated in the wrong unit, and what limits an array is the machine.
`heap.maxElements(kind)` keeps only the ceilings docs/VECTOR.md's
reduction proof is load-bearing on, computed from the proof's own
obligation in `i128` — because `i64` is the width the arithmetic is
*about* and a wrapped bound reports that everything fits.  Past that,
RAM decides and says so: `allocation_failed`, a trap at the site that
asked, located and traced like every other.  The Linux overcommit
caveat is written where the trap code is defined, because it is the
one case this trap honestly does not catch.

**What did not move.**  The ownership rules are OWNERSHIP.md's,
unchanged, and the handle specs are written against the existing
clauses rather than new ones.  `map` is untouched.  `file_read`,
`file_write` and `file_append` have the surface and the meaning they
had.  No keyword arrived.

## Sequencing

After run four (enums + match) merges: both runs move
`format_version` and this one moves `abi.version`; racing two runs
through the same seams is the one way to lose both (the BITWISE.md
lesson, again).  Then: part one (runtime + codegen, no surface
change, benchmarked — `bench/` has the harness and `list` rows will
move), part two (ABI + runtime + hosts + both engines), part three
(std + zip's payoff), specs at every step — two-engine rows for byte
round-trips including bytes that are not text, and the artifact-refusal
row for the version bump.
