# LuciaOS Coding Guide (v2)

Write code that a tired reader can understand a week later.
Prefer plain, old-school code over clever modern ceremony.

Everything is Zig 0.16.  `src/luce/module.zig` is the reference
style: one clear job, explicit ownership, tests beside the code.
North star for architecture: [V2.md](V2.md) (Luce the language, loom
the terminal); [LANGUAGE.md](LANGUAGE.md) is the language itself and
[OWNERSHIP.md](OWNERSHIP.md) its memory model.  The v1 guide this
revises is preserved at `v1/CODING_GUIDE.md`.

## Goals

- Simple
- Readable
- Fast
- Well organized
- Easy to return to after time away

If a change makes the architecture harder to see, do not merge it.

## Language

- Zig 0.16, pinned in `build.zig.zon`
- `zig fmt src/ build.zig` before every commit; nothing to argue about
- Errors are values: small explicit error sets, `try` at call sites,
  no panics for ordinary failure
- Allocation is explicit: functions that allocate take an `Allocator`
- Anything that may touch the host takes an explicit `std.Io`; the
  language module (`src/luce/`) never sees the host except through
  `backend.Host`
- Tagged unions over class hierarchies (`Value`, `Instruction`,
  `Result`); named payload structs so signatures say what they take —
  `anytype` is for format arguments, not for data
- Function-pointer tables only where substitution is real
  (`backend.Host`, `compile.Loader`)

## Ownership

Every heap-holding type has `deinit`, and the doc comment says who
owns what:

- The caller owns what a function returns unless the doc says borrowed
- Borrowed results say what invalidates them
- Arena-backed types say so ("arena-owned by the program")
- Tests run under `std.testing.allocator`, which fails on leaks —
  keep it that way

A type that must not move after setup (because something captured a
pointer into it) uses the documented in-place `setup` pattern
(`src/apps/loom/host.zig`'s `Host`).

## Naming

Zig conventions: TitleCase types, camelCase functions, snake_case
variables and fields.

- Drop the type noun when context already has it: `volume.read(...)`,
  `store.get(id)` — never `putPort`, `countPages`
- Collections use the small verb set: `count has get put remove at`
- Other functions are short verbs: `read write open close parse
  encode decode resolve lower emit fold`
- Reporting helpers are verbs too: `fail`, `failIntrinsic` — a
  function that reports an error is named for the reporting, not for
  what it inspects
- Names are plain English: `file_handle`, `page_index`,
  `byte_offset` — never `fd`, `buf`, `n`, `ptr`, `idx`

## Comments and docs

Files start with a `//!` doc comment saying what the file is for.
Sections inside a file use short dashed headers.  Public types and
methods get `///` comments that explain assumptions and ownership,
not narration of obvious code.  Compiler and interpreter code that
implements a ratified rule cites its number (`(S23)`) so the reader
can find the contract.

## Organization

```text
build.zig  build.zig.zon      zig build test runs everything; ./build.sh installs
src/luce/                     the language, one file per stage:
  lexer parser ast            source to tree
  analyzer                    checking + IR lowering + ownership + constants, one walk
  ir                          the typed IR, verifier, printer
  interpreter                 the deterministic engine (owner-tracked heap)
  module                      the .lc on-disk format (decode re-verifies)
  compile                     the pipeline driver and project/import loading
  backend types diagnostics   the execution boundary, types, and reporting
  ownership_spec              the executable form of docs/OWNERSHIP.md
src/apps/luce/                the compiler CLI (build, check, ir)
src/apps/loom/                the terminal: shell, runner, host, keys, palette
src/apps/files.zig            file access shared by both executables
programs/                     userland, written in Luce; editor.luc is embedded in loom
docs/                         V2.md LANGUAGE.md OWNERSHIP.md MEMORY.md AUDIT.md; v1/ is history
```

Rules:

- One file, one stage; one clear idea per file
- Public contracts stay small; implementation details stay private
- The apps consume only the `luce` module's public surface

Dependency rule:

```text
apps (luce CLI, loom terminal) → luce module (language)
tests → the file under test
```

The language module never touches the host; the host never touches
IR internals.

## Errors and diagnostics

- Small explicit error sets at package borders
- Compiler diagnostics carry stable codes (`luce.sema.own`,
  `luce.parse.top`, ...) and byte spans; tests assert the code, not
  the wording
- Runtime failures are traps with stable codes; the interpreter
  records a pending trap and the dispatch loop reports it once
- Do not hide durability: callers call `flush()`/`sync` when
  durability matters

## Tests

- Tests are `test` blocks beside the code they prove, named after
  what they prove: `test "truncated, oversold, and damaged modules
  are rejected"`
- Ratified specifications get an executable form:
  `ownership_spec.zig` mirrors OWNERSHIP.md's numbering, and every
  situation is proven three ways — the behavior works, misuse is a
  compile error with a stable code, the dynamic backstop traps
- Cover success, bounds failure, and round-trip/rejection where
  relevant; everything runs leak-checked under
  `std.testing.allocator`
- A new language file must be added to `src/luce/luce.zig`'s
  re-exports and test block or its tests will not run

## What not to add casually

- Comptime metaprogramming beyond what a reader can hold in their head
- Async or threads
- Codegen / build-time tricks beyond simple steps in `build.zig`
- Premature abstraction before a caller needs it
- Wrappers around Zig std that add nothing but indirection

## Checklist for new code

1. Can a reader say what the file is for in one sentence?
2. Are names short, with no redundant type nouns, no `anytype` data?
3. Is ownership explicit — deinit present, docs say who frees?
4. Do tests beside the code prove the new behavior, leak-checked?
5. If it implements a spec rule, does it cite the number and does the
   spec suite cover it?
6. Is the hot path still visible?
7. Did we avoid adding a layer that is not needed yet?
