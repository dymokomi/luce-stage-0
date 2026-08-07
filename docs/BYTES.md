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

## Part two — the host channel: bytes underneath, text as a reading

Today the host's file services *are text*: `file_read` validates UTF-8
inside the host and `file_write` receives a string.  The honest
architecture inverts that: **a file is bytes, and text is a
validation the language performs on them.**

- `LuceHost` gains appended byte-channel slots — `read_bytes`,
  `write_bytes`, `append_bytes` — carrying raw contents with no
  opinion about encoding.  Fail-closed like every service,
  `yes`/`no`/`exhausted` like every fallible one; `abi.version` bumps.
- **UTF-8 validation moves out of the hosts and into `libluce_rt`**,
  the one implementation of every semantic: `file_read` (the text
  builtin, unchanged in surface and meaning) becomes the byte read
  followed by the runtime's own validation, so the interpreter, the
  compiled artifact, and every future host agree byte-for-byte on
  what "not text" means — today that sentence lives in `host.zig`
  where only loom can say it.
- The existing text slots are retired from use in the same movement
  (the vtable stays append-only and nothing reorders; a version-bumped
  artifact never indexes them, and the version is already how a stale
  artifact is refused by name).
- New builtins behind the same `allow_host` gate: `file_read_bytes`
  answering `list(byte)!`, `file_write_bytes`/`file_append_bytes`
  taking one.  Fallibility follows `docs/FAILURE.md` exactly as the
  text builtins do.

## Part three — the std surface

The owner's "std.io" is today spelled `std.files`, and it grows the
binary half plus the bridges:

- `files.read_bytes(path) -> list(byte)!`, `files.write_bytes`,
  `files.append_bytes` — thin and honest over the builtins, like the
  text functions beside them.
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
