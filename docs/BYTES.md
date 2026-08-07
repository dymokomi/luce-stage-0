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
