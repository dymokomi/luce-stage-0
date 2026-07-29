# LuciaOS Coding Guide

Write code that a tired reader can understand a week later.
Prefer plain, old-school code over clever modern ceremony.

The engine is written in Zig 0.16.  `loom/storage/volume.zig` is the
reference style. Match it.
North star for architecture: [LOOM.md](LOOM.md) (LuciaOS = OS; Loom = its
trusted local engine).

## Goals

- Simple
- Readable
- Fast
- Well organized
- Easy to return to after time away

If a change makes the architecture harder to see, do not merge it.

## Language

- Zig 0.16, pinned in `build.zig.zon`
- `zig fmt` is the formatter; there is nothing to argue about
- Errors are values: small explicit error sets, `try` at call sites,
  no panics for ordinary failure
- Allocation is explicit: functions that allocate take an `Allocator`
- Anything that may touch the host takes an explicit `std.Io`; the rest
  of the engine never sees the host
- Tagged unions over class hierarchies (`Volume`, `Value`, `Outcome`)
- Function-pointer tables only where substitution is real (`Evaluator`)
- Zig std is consumed through a thin surface (allocators, ArrayList,
  Io.File); anything volatile gets a Lucia-owned wrapper before it
  spreads

## Ownership

Every heap-holding type has `clone` and `deinit`, and the doc comment
says who owns what:

```zig
pub fn clone(self: Texel, allocator: Allocator) !Texel
pub fn deinit(self: *Texel, allocator: Allocator) void
```

- The caller owns what a function returns unless the doc says borrowed
- Borrowed results say what invalidates them ("valid until the next
  commit")
- Functions that take ownership say so ("takes ownership of the port")
- Tests run under `std.testing.allocator`, which fails on leaks —
  keep it that way

A type that must not move after setup (because something captured a
pointer into it) uses the in-place setup pattern, with a comment:

```zig
/// Fills self in place: the spool keeps pointers into self, so a
/// Shell must never move once set up.
pub fn setup(self: *Shell, allocator: Allocator, store: *Store) !void
```

## Naming

Zig conventions: TitleCase types, camelCase functions, snake_case
variables and fields.

### Drop the type noun when context already has it

The type or receiver already says what you are dealing with.  Do not
repeat it in the function name:

```zig
volume.read(page_index, &destination);
volume.write(page_index, &source);
volume.flush();
store.get(id);
texel.putOutput(allocator, port);
```

### Collections use a small verb set

For tables and lists of items:

```zig
count()
has(...)
get(...)
put(...)
remove(...)
at(...)
```

Prefer short names: `count()` not `countElements()`, `put(...)` not
`putElement(...)`.

### Other functions are short verbs

```zig
read(...)
write(...)
flush()
create(...)
open(...)
close()
parse(...)
encode(...)
decode(...)
```

Getters that answer a question may read as verbs: `isUnset()`,
`hasSelection()`, `has(...)`.

### Names are plain English

Prefer:

```zig
file_handle
byte_offset
image_bytes
bytes_read
page_index
```

Avoid shorthand and platform-looking names in our code:

```zig
fd
off
buf
n
ptr
```

Host calls stay behind `std.Io`; wrap their results immediately in
clear local names.

## Formatting

- `zig fmt loom/ apps/loom/ build.zig` before every commit; the test
  suite and CI assume formatted code
- Keep functions short and boring
- Keep related declarations adjacent when it helps scanning

## Comments and docs

Files start with a `//!` doc comment saying what the file is for in a
sentence or two.  Sections inside a file use short dashed headers:

```zig
// ---------------------------------------------------------------------------
// FileVolume
// ---------------------------------------------------------------------------
```

Public types and methods get `///` doc comments that explain
assumptions and ownership, not narration of obvious code.

Good:

```zig
/// write is not durable until flush succeeds.
```

Bad:

```zig
// increment index
```

## Organization

Current first-Lucia packages:

```text
build.zig  build.zig.zon        engine build; zig build test runs everything
loom/storage/                   page volumes and durability mechanics
loom/fabric/                    Texels, Ports, Fibers, values, encode, Store
loom/evaluation/                Spool, FiberIndex, State/Delay
loom/organization/              arrangements
loom/effects/                   effect intents and the trusted boundary
loom/authority/                 capabilities
loom/view/                      View evaluators and the shell runtime
loom/projection/                manifests and file projection
loom/abi.zig  abi/              the C border and its smoke test
apps/loom/                      the loom terminal
testdata/                       golden image fixtures
docs/                           architecture and coding documentation
```

Durable Texels, typed Ports, Fibers, and values belong in `fabric/`.
Page storage and durability mechanics belong in `storage/`.
Capabilities belong in `authority/`. Evaluation, State/Delay, effects,
and arrangements belong in their narrow packages. The terminal lives in
`apps/loom/`. Views and file projection live in `view/` and
`projection/`.

Production security, collaboration, Braid, permanent history,
replacement engines, and the agent remain deferred.

Rules:

- One package, one job
- One clear idea per file
- Public contracts stay small; implementation details stay private

Dependency rule:

```text
projection / view → evaluation → organization / fabric → storage
tests → the package under test
```

Keep storage independent of Fabric concepts. Keep deferred systems out
of this dependency chain.

## APIs

- Narrow interfaces
- Substitution points are explicit values: the `Volume` union, the
  `Evaluator` function table — never a hierarchy
- Resource owners are not copied; they are cloned deliberately or moved
  once
- Construction/setup methods read clearly: `create`, `open`, `init`,
  `setup`

A good call site looks like:

```zig
var file = try FileVolume.create(io, directory, "lucia.img", 1024);
defer file.close();
var store = try Store.create(allocator, file.volume());
defer store.deinit();
```

## Errors

- Small explicit error sets at package borders; do not leak deep
  internal sets upward
- Fail early on bad arguments (empty name, out-of-range page)
- Do not hide durability: callers call `flush()` when durability
  matters

## Performance

- Keep the hot path obvious: `@memcpy`, positional reads and writes,
  explicit `sync`
- No hidden allocations in `read` / `write`
- Page size is fixed (`page_size`); do not surprise callers with
  variable transfer sizes at this layer

## Tests

- Tests are `test` blocks beside the code they prove; the acceptance
  proof lives in `loom/first_lucia_test.zig`
- Name tests after what they prove:
  `test "file volume persists across close and reopen"`
- Prefer direct `std.testing` checks over frameworks
- Cover success, bounds failure, and reopen/persistence where relevant
- Everything runs leak-checked under `std.testing.allocator`

## What not to add casually

- Comptime metaprogramming beyond what a reader can hold in their head
- Async or threads (the scheduler belongs to Loom, never to Zig async)
- Codegen / build-time tricks beyond simple steps in `build.zig`
- Premature abstraction before a caller needs it
- Redundant type nouns in names (`putPort`, `countPages` on a page
  volume — prefer `put`, `count`)
- Wrappers around Zig std that add nothing but indirection

## Checklist for new code

1. Can a reader say what the file is for in one sentence?
2. Are names short, with no redundant type nouns?
3. Is ownership explicit — clone/deinit present, docs say who frees?
4. Do tests beside the code prove the new behavior, leak-checked?
5. Are docs short and useful?
6. Is the hot path still visible?
7. Did we avoid adding a layer that is not needed yet?
