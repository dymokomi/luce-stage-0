# LuciaOS Coding Guide (v2)

Write code that a tired reader can understand a week later.
Prefer plain, old-school code over clever modern ceremony.

Everything is Zig 0.16.  `src/luce/06_mir/module.zig` is the reference
style: one clear job, explicit ownership, tests beside the code.
North star for architecture: [V2.md](V2.md) (Luce the language, loom
the terminal); [LANGUAGE.md](LANGUAGE.md) is the language itself,
[OWNERSHIP.md](OWNERSHIP.md) its memory model, and
[docs/CODEGEN.md](docs/CODEGEN.md) why there is one code generator.  The v1
guide this revises is preserved at `v1/CODING_GUIDE.md`.

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
src/luce/                     the language, one numbered folder per stage:
  compile.zig                 the driver: the stage sequence, in order
  01_source 02_lex 03_parse   bytes to tokens to tree
  04_semantics                resolve + type-check + validate (and, still, the MIR lowering)
  05_hir                      a named seam; nothing in it yet
  06_mir                      the typed MIR, verifier, printer, and the .lc format
  07_optimize                 MIR passes; dead-code elimination is the only one
  08_llvm                     MIR to LLVM IR to an object; the host ABI
  runtime                     libluce_rt: the heap, ownership, containers, text
  interpreter                 the reference engine over that runtime
  backend.zig                 the execution boundary
  support/                    types and diagnostics, used by every stage
  specs/                      the executable form of the ratified documents
src/apps/luce/                the compiler CLI (build, check, ir)
src/apps/loom/                the terminal: shell, runner, host, keys, palette
src/apps/files.zig            file access shared by both executables
programs/                     userland, written in Luce; editor.luc is embedded in loom
docs/                         V2.md LANGUAGE.md OWNERSHIP.md docs/CODEGEN.md CODEGEN.md; v1/ is history
```

A stage that outgrows one file becomes a directory beside a
same-named barrel that re-exports its public API and pulls in its
tests: `03_parse.zig` + `03_parse/`, `06_mir.zig` + `06_mir/`, `runtime.zig` +
`runtime/`.  The barrel is the stage's public surface; the directory
is its inside.

Rules:

- One stage, one name; one clear idea per file
- Public contracts stay small; implementation details stay private
- The apps consume only the `luce` module's public surface

### When to split a file

**Split when a subproblem has a one-to-three-function interface and
can be understood without the parent's state.  Never split because a
file is long.**

Length is not the signal, and the projects we take our practice from
say so plainly: rustc's `late.rs` is 5,735 lines, and Zig's
`x86_64/CodeGen.zig` is 190,207 — both single cohesive files, both
maintained by teams.  A 4,000-line file with one job and a small
surface is easier to hold than the same code in nine files that all
reach into each other.

**A file boundary in Zig is a privacy boundary**, so split only where
you would also draw an API boundary.  The test: if a split forces a
declaration `pub` purely so a sibling — or a sibling's test — can
reach it, the split is in the wrong place.  Put it back and find the
seam where the exported surface is genuinely small.

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
- Runtime failures are traps with stable codes, raised through one
  channel: the runtime reports a trap where it happens, and the
  caller — interpreter dispatch loop or generated code — unwinds
- Do not hide durability: callers call `flush()`/`sync` when
  durability matters

## Tests

- Tests are `test` blocks beside the code they prove, named after
  what they prove: `test "truncated, oversold, and damaged modules
  are rejected"`
- Ratified specifications get an executable form:
  `specs/ownership_spec.zig` mirrors OWNERSHIP.md's numbering, and
  every situation is proven three ways — the behavior works, misuse
  is a compile error with a stable code, the dynamic backstop traps
- Nothing is made `pub` for a test.  A test lives with the code it
  proves, inside the same privacy boundary
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
