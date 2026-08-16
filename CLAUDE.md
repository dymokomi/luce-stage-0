# CLAUDE.md

This is the repository operating guide. Read it before changing the tree, then
follow the deeper references it names.

> **Memory model — read first.** Luce has value types and ARC reference types.
> Numbers, `bool`, `char`, `str`, `bytes`, structures, enumerations, unions,
> and value receivers copy. Classes, containers, closure environments, files,
> and tasks are references. Assignment retains and shares a reference; the
> last strong release destroys it and closes or joins resources. `weak` breaks
> cycles without dangling. Workers own separate runtimes and never share
> object identity. [docs/MEMORY.md](docs/MEMORY.md) is the source of truth.

## Guiding principle

**Always decide for long-term success. No short-term stopgaps.** A skipped
test, hard-coded exception, duplicated semantic, or knowingly temporary
architecture hides complexity instead of removing it. If the right fix is
large, scope and prove that fix. Do not make the wrong design permanent by
calling it an intermediate step.

[docs/SOFTWARE_DESIGN.md](docs/SOFTWARE_DESIGN.md) governs deep modules,
information hiding, naming, and complexity. [docs/CODING_GUIDE.md](docs/CODING_GUIDE.md)
governs Zig style and organization.

## Workflow

This is a single-developer project. Commit directly to `main` unless the
maintainer asks for another workflow. Use author `Dy Mokomi
<dy@dymokomi.com>`. Preserve unrelated working-tree changes.

Meaningful phase commits are preferred to one undifferentiated final commit.
Before committing, format the complete owned surface:

```sh
zig fmt src/ build.zig www/luce/src/ tools/
```

## Build and test

The repository uses Zig 0.16, pinned in `build.zig.zon`. Building the compiler
requires LLVM and `cc`; running an already compiled Luce artifact does not.
The complete gate also needs Node.js for the dependency-free editor-extension
tests.

```sh
./build.sh       # ReleaseSafe install under build/
zig build test   # owner-grouped release gate with progress and heartbeat
```

`zig build test` does not refresh `build/`; run `./build.sh` when an installed
product tree is part of the acceptance check. Use focused lanes during an
implementation loop and the complete gate once at the phase boundary.
[docs/TESTING.md](docs/TESTING.md) lists every lane and owner.

## Products

LuciaOS v2 is language-first:

- `luce` compiles and tests Luce. `luce build FILE.luc` creates a native
  executable named after the source by default. `--emit=library` creates the
  `.lc` library loom loads; `--emit=object` creates a relocatable object.
  `luce check`, `luce ir`, and `luce test` are focused workflows.
- `loom` is the terminal and `.lc` host. `loom run FILE.lc` loads machine code;
  `loom luce FILE.luc` compiles and caches a library artifact before running
  it. Loom contains no compiler, LLVM, or editor.
- The terminal editor is an ordinary bundled Luce program. The release also
  ships the local VS Code/Cursor syntax extension.

The runtime/host C ABI used by generated artifacts is real and public inside
the toolchain. A user-facing C FFI is not part of the language.

## Architecture

```text
apps (luce CLI, loom host) -> luce module
specs -> compiled path + interpreter oracle
both execution paths -> one runtime implementation
```

There is one shipping engine: LLVM-generated machine code linked with
`libluce_rt`. The interpreter ships in nothing; it is the differential oracle
used by the specification suite. There is no JIT, bytecode VM, handwritten
emitter, or runtime fallback.

The serialized MIR module format is **54**. The published host ABI is **23**.
The declarations in `src/luce/mir/module.zig` and
`src/luce/codegen/abi.zig` are authoritative; never copy the numbers into a
new compatibility check.

Luce is pre-1.0 and has no source-compatibility contract. Rename, remove, or
reshape a feature when that makes the language better; update the whole tree
in one change. Do not add deprecated aliases, compatibility branches, or
migration tests. MIR and host version checks exist only to reject stale binary
artifacts safely, never to translate or continue running them.

### Language pipeline

`src/luce/compile.zig` drives the stages in this order:

```text
source -> lex -> parse -> semantics -> HIR lowering -> MIR -> optimize -> codegen
                                                           \-> interpreter oracle
```

- `source/` validates bytes, line endings, size, positions, and module loading.
- `lex/` produces indentation-aware tokens.
- `parse/` builds the arena-owned AST with recursive descent and Pratt
  expression parsing.
- `semantics/` resolves names and types, checks control flow and effects,
  diagnoses misuse, and records typed HIR. It emits no MIR instructions.
  Its files are concern modules over `Analyzer` or `FunctionBuilder`;
  `closures.zig`, `interfaces.zig`, `initializers.zig`, `assign.zig`, and
  `calls.zig` own those subjects rather than scattering their rules through
  the walker.
- `hir/` is the checked-tree seam. `lower.zig` mechanically removes sugar and
  has only `OutOfMemory` failure; a user diagnostic at this stage is a design
  error because semantics should already have decided everything.
- `mir/` owns typed instructions, basic blocks, verification, deterministic
  printing, and serialization. Decoding always re-verifies hostile input.
- `optimize/` contains the deliberately small MIR passes: reachability prune,
  dead instruction removal, and register compaction. LLVM owns general
  optimization.
- `codegen/` lowers verified MIR to LLVM IR, emits an object through libLLVM,
  and links the requested native artifact.

A stage that needs several files has a same-named barrel (`parse.zig` plus
`parse/`). The barrel is the stage's public surface. Split a file only when a
subproblem has a genuine one-to-three-function interface; length alone is not
a seam. Never make a declaration `pub` merely so a sibling file or test can
reach it.

### Runtime and execution

`src/luce/runtime.zig` and `runtime/` implement every dynamic semantic once:
ARC, object identity, weak handles, containers, class destruction, text,
checked arithmetic, files, tasks, worker copies, traps, and closure storage.
The interpreter calls this runtime, and generated code calls its published C
exports. Do not implement a rule separately in the interpreter and codegen.

`src/luce/interpreter/` owns only the oracle's dispatch loop, frame stack,
traceback, and host adaptation. `src/luce/codegen/` owns only the native path.
Both must agree through `src/luce/specs/agree.zig` on output, raised errors,
trap code and message, call trace, host world, and live-object census.

Host effects are explicit. Generated code reaches them only through the
versioned table in `codegen/abi.zig`; the oracle reaches an explicit
`interpreter.Host`. Language code under `src/luce/` never opens files, reads a
terminal, starts a process, or consults the OS directly. Shared concrete host
implementation belongs in `src/apps/`.

### Compiler and host applications

- `src/apps/luce/` owns CLI parsing, the front/back compiler split, artifact
  creation, test discovery, and the Luce test runner.
- `src/apps/loom/` owns loom dispatch, its shell, artifact loading, platform UI
  adaptation, and product tests.
- `src/apps/*.zig` holds behavior both products share: host services, manifest
  and package loading, native linking/loading, diagnostics, streams, terminal
  sanitation, startup, and test harnesses.

The behavior of a program must not depend on whether `luce`, `loom`, or a
standalone executable started it.

## Current language boundaries

[docs/LANGUAGE.md](docs/LANGUAGE.md) is the broad specification. The focused
references are indexed in [docs/README.md](docs/README.md). Important current
facts that architecture work must preserve:

- Numeric names state representation: `u8`–`u64`, `i8`–`i64`, and
  `f16`/`f32`/`f64`. Every integer width has checked arithmetic. Concrete
  values never change width, signedness, or numeric family implicitly;
  literals are contextual and conversions are explicit.
- `char` is one Unicode scalar, `str` is immutable UTF-8 indexed by scalar,
  and `bytes` is immutable binary data. `alias Name = Type` is transparent and
  erased before HIR.
- A `struct` is a value. A `class` is a final ARC reference with identity,
  mutation through a stable `let`, `is`, weak back-edges, interface
  conformance, one definite `init` factory, and one ARC-driven `deinit`.
  Initialization publishes no identity until every field exists. There is no
  class inheritance.
- Interfaces are nominal and support multiple methods, multi-value results,
  directional fallibility, class and struct conformers, optionals, returns,
  and heterogeneous collections. The current hidden bound-witness layout
  permits mutable class dispatch but refuses a writing value-struct witness;
  the owned existential replacement remains planned.
- `(x) -> expression` is capture-free. `func(x):` is a block closure with an
  ARC environment. Immutable values snapshot, references capture strongly by
  default, mutable locals share one cell, `[weak name]` is zeroing and
  optional, and `[copy = expression]` evaluates once.
- ARC does not collect strong cycles. The compiler diagnoses the direct stored
  `self` closure cycle, but program graphs still need an intentional weak
  back-edge.
- Workers have private runtime/object tables. Permitted value/container graphs
  copy while preserving aliases inside the snapshot. Resources, classes,
  function values, and weak storage do not cross the boundary.
- Function types carry neither parameter names/defaults nor fallibility.
  Function values have no equality or ordering and cannot cross workers.
- Recoverable errors use `T!`, `try`, and `catch`. Traps remain terminal.
  Multiple returns are shapes received by destructuring; they are not tuples.

## Where a test goes

One rule decides placement:

> Any claim about a Luce program's observable behavior is a specification in
> `src/luce/specs/`. It runs on the compiled path and oracle, and the results
> are compared. Anything that inspects an otherwise invisible structure lives
> beside the code it proves.

A new language package must be re-exported and imported by the test roster in
`src/luce/luce.zig`. A new spec file must be imported by
`src/luce/specs.zig` and assigned exactly one owner in
`tools/test_suites.zig`. The suite audit rejects missing and overlapping
ownership.

Tests use `std.testing` directly and run with `std.testing.allocator`. Cover
success, relevant boundaries, rejection, round trips, and cleanup. Do not
weaken a leak census or skip a feature case to make a lane green. Platform
capability skips must say what capability is absent and remain separate from
product gaps.

## Change costs

Language changes cross explicit seams. Account for every relevant row:

| Change | Required surfaces |
|---|---|
| syntax or keyword | lexer/token data, parser/AST, grammar coverage, highlighting, positive and negative specs, Guide/reference |
| type or semantic rule | support types, semantic resolver/checker, HIR, MIR/verifier as needed, both-engine spec, diagnostics, docs |
| dynamic operation | runtime implementation and export, MIR instruction/intrinsic, interpreter dispatch, codegen lowering, ABI effects table when host-facing |
| MIR/type tag/trap code | bump `mir.module.format_version`, update encoding/decoding/fingerprint, hostile verifier tests |
| host table shape | bump `codegen.abi.version`; update every host, generated slot, and stale-artifact rejection test atomically; pre-1.0 may reorder or remove fields and adds no adapters |
| standard module | `.luc` source, embedded module roster, std/spec coverage, Library page and surface coverage |
| spec file | `specs.zig` import and exactly one `tools/test_suites.zig` owner |
| public release surface | Guide/Library/Status, checked samples, installer/archive smoke, version agreement |

Do not bump the host ABI for an internal runtime change. Do not leave the
module version unchanged when a decoder would read the old bytes with a new
meaning. Stale source recompiles; there is no serialized-module migration.

## Documentation

`docs/README.md` separates current references, plans, and frozen decision
records. Current `luce` fences compile. Planned syntax uses `text` until it is
implemented. A historical fence belongs only in a decision record.
`tools/documents.zig` and `tools/doccheck.zig` enforce the catalogue and
examples. The compiler treats names outside the current vocabulary as ordinary
unknown identifiers; there is no compatibility-name table.

User documentation lives in `www/luce/`. The generator compiles or refuses
every classified sample, compares claimed output, checks links and anchors,
and holds selected compiler surfaces to the Language Reference and Library.
Build the short documentation feedback path with `www/luce/build.sh`.
`www/luce/release.sh` separately builds and smoke-tests the macOS ARM64 and
glibc Linux ARM64/x86-64 archives; keeping that Docker/LLVM matrix out of an
ordinary prose edit is intentional. The default `www/luce/deploy.sh` runs both.
Deploy only after the repository, site, and release gates are clean.

`www/loom/`, `www/luciaos/`, and `www/stats/` are separate products. Shared
web assets and publishing mechanics live under `www/shared/` and
`www/deploy/`; do not copy them into a product directory.

## Coding conventions

The authoritative details are in [docs/CODING_GUIDE.md](docs/CODING_GUIDE.md).
The non-negotiable summary:

- Errors are values with small explicit error sets; no panic for ordinary
  failure.
- Allocation is explicit. A heap-owning Zig type has `deinit`, and public docs
  state ownership and borrow invalidation.
- Host access takes explicit `std.Io` or the published host interface.
- Prefer tagged unions and plain data over class-like Zig hierarchies and
  framework managers.
- Names are plain and responsibility-based. Use TitleCase types, camelCase
  functions, snake_case fields, and short verbs.
- Comments explain invariants, ownership, and reasons—not visible syntax.
- Keep the hot path readable. Optimize from measurement and preserve semantic
  order, cleanup, and traps.
- Do not add abstraction for imagined future needs. Deep modules with small
  surfaces are preferred to many shallow wrappers.
