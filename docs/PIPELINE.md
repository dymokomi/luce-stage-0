# The compiler pipeline

`src/luce/compile.zig` is the driver. It loads the root module graph, sends
each source file through the front end, joins the resolved program, lowers it
to verified MIR, optimizes it, and hands that program to code generation or
the test-only interpreter.

```text
source -> lex -> parse -> semantics -> HIR -> MIR -> optimize -> codegen
                                                   \-> interpreter oracle
```

The folder names state responsibilities rather than historical step numbers.
Each multi-file stage has a same-named barrel file; that barrel is the stage's
public surface.

## Stage map

| Stage | Input | Output | Responsibility |
|---|---|---|---|
| `source` | root bytes and a host loader | prepared UTF-8 files and module graph | encoding, line endings, positions, size, exact module loading |
| `lex` | one prepared file | layout-resolved tokens | indentation, literals, operators, keywords, bounded recovery |
| `parse` | tokens | arena-owned AST | declarations, statements, Pratt expressions, syntax recovery |
| `semantics` | ASTs and compile options | analyzed declarations plus typed HIR bodies | names, types, effects, flow, diagnostics, all source meaning |
| `hir` | checked typed tree | MIR-building operations | mechanical desugaring, ownership/store decisions already recorded |
| `mir` | lowered operations | verified typed program | instructions, blocks, locals, layouts, serialization, hostile-input verification |
| `optimize` | verified MIR | smaller verified MIR | reachability pruning, dead instructions, register compaction |
| `codegen` | optimized MIR | LLVM IR, object, native artifact | ABI lowering, optimization through LLVM, emission and linking |

## Source

`source/encoding.zig` validates UTF-8, normalizes supported line endings,
rejects binary and oversized input, and makes every later stage operate on one
trusted representation. `source/sources.zig` owns file identities and line
indexes. `source/load.zig` owns the language-facing module request; actual
filesystem access remains a host responsibility.

Standard imports and project/package imports enter the same `Sources`
registry. A module is loaded once. Module cycles are allowed because Luce has
no module initialization phase; finer semantic cycles such as recursive
constants and unbounded value layouts are rejected by their owning stage.

## Lexing and parsing

The lexer turns four-space indentation into `indent` and `dedent` tokens,
validates literal spellings and source controls, and bounds nesting and
diagnostic volume. It recovers to a usable token stream instead of failing
hard on the first malformed byte.

The parser owns syntax only. It uses recursive descent for declarations and
statements and Pratt parsing for expressions. It builds an arena-owned AST,
keeps recovery local to a line or block, and reports the reader's correction
rather than an internal parser state.

Current syntax includes transparent aliases, interfaces, final classes,
`init`, `deinit`, weak fields/locals, expression lambdas, block closures and
capture lists. The parser does not decide conformance, definite
initialization, ownership, capture kind, or class lifetime; those are semantic
questions.

## Semantics

`semantics/` is one subsystem because name resolution, type checking, flow,
and call selection are mutually dependent. It has two spines:

- `Analyzer` collects declarations, names, layouts, aliases, signatures,
  defaults, interfaces, constants, and the entry point.
- `FunctionBuilder` checks one body, manages scopes and narrowing, and records
  a typed tree containing every later lowering decision.

Concern files expose small operations over one of those types:

| File | Owns |
|---|---|
| `aliases.zig` / `resolve.zig` | transparent type names and written-type resolution |
| `layouts.zig` / `shapes.zig` | structures, classes, enums, unions, interfaces, recursive width/carry facts |
| `signatures.zig` / `receiver.zig` | function contracts, return shapes, implied receiver effects |
| `interfaces.zig` | nominal conformance and witness construction |
| `closures.zig` | capture planning, ARC environments, shared cells, cycle refusals |
| `initializers.zig` | class factory lowering, definite fields, and pre-identity `self` restrictions |
| `flow.zig` | optional narrowing and branch joins |
| `ledger.zig` | statement temporaries and their release points |
| `recorder.zig` | the only API that creates HIR nodes |
| `statements.zig` / `expressions.zig` | checked source walks |
| `assign.zig` | local, field, index, chain, compound, and parallel assignment places |
| `calls.zig` / `construct.zig` | callable selection, arguments, construction, conversions |
| `refusals.zig` | user-facing rejection paths shared by the walk |

Semantics implements the explicit numeric model: literals are contextual,
all eight integer widths compute with checked same-type arithmetic, all three
floating widths retain their representation, and concrete conversions are
explicit. Aliases are erased here; HIR and every later stage see only the
resolved target.

This is also the last word on source-level rules: `let`, visibility,
conformance, return paths, definite class construction, worker sendability,
strong/weak/snapshot capture, class resurrection, and the host gate are
checked here. The MIR verifier defends the instruction protocol; it does not
reconstruct source intent.

## HIR

`hir/nodes.zig` is the typed check/lower seam. It preserves structured source
meaning—loops, matches, compound and parallel assignment, fallible control,
resolved calls, capture environments—while recording types, store kinds,
temporary parks, and source spans.

`hir/lower.zig` is mechanical and diagnostic-free. Its only error is
`OutOfMemory`; if it discovers that a legal source shape cannot lower, the
semantic representation is incomplete. Whole-array operations stay whole so
later stages retain information that a synthesized scalar loop would destroy.

## MIR and serialization

`mir/build.zig` constructs functions, blocks, registers, locals, layouts,
constants, and retain/release operations. `mir/defs.zig` is the instruction
and program vocabulary. `mir/verify.zig` rejects malformed types, layouts,
instructions, ownership claims, worker boundaries, and control flow before
either execution path receives a program.

`mir/module.zig` encodes the verified front-end handoff. The current
`format_version` is **55**. The format includes explicit-width types, weak
storage, class reference layouts and deinitializers, closure-only layouts, and
boxed non-owning closure bridges. It is a cache seam, not a stable distribution
format: incompatible modules recompile from source.

A change to an instruction, intrinsic, type tag, trap/error code, encoded
layout/local field, or another wire meaning bumps the format and updates the
round-trip fingerprint and hostile decoder tests.

## Optimization

MIR optimization is intentionally small:

- `prune` removes declarations unreachable from the selected entry and follows
  every function value, witness, class deinitializer, and closure edge;
- `dead` removes unread instructions; and
- `registers` compacts the surviving register space.

Each pass re-verifies the result. General constant folding, inlining, loop
optimization, vectorization, and instruction selection belong to LLVM rather
than a second optimizer written in Luce's front end.

## Code generation and artifacts

`codegen/lower.zig` lowers every verified MIR instruction to LLVM IR.
`codegen/loops.zig` and `codegen/mutability.zig` derive the narrow facts LLVM
cannot infer through opaque runtime calls. `codegen/emit.zig` is the only file
that calls libLLVM; it runs the selected optimization pipeline and emits an
object. Application code links that object with `libluce_rt` into an
executable or `.lc` library.

Generated code reaches host effects only through the versioned table in
`codegen/abi.zig`. The current host ABI version is **24**. Internal runtime
changes do not bump it; changing a table field, order, signature, or published
value representation does. Before 1.0, a coherent change may remove or reorder
fields; every host and generated slot moves atomically, and stale artifacts are
refused rather than adapted.

Every artifact records its machine, ABI, content identity, and generator.
Loaders refuse a stale or foreign artifact by name. There is no interpreter
fallback.

## Supporting modules, not stages

| Module | Role |
|---|---|
| `runtime/` | the one implementation of ARC, classes, weak handles, closures, containers, resources, text, operators, workers, and traps |
| `interpreter/` | differential-oracle dispatch, frames, traces, and host adaptation; ships in nothing |
| `support/` | diagnostics, types, and trap/error vocabulary shared across stages |
| `std/` | embedded standard modules written in Luce |
| `specs/` | executable language specification, built as its own module with LLVM available |
| `compile/` | module-graph orchestration and whole-compiler integration tests |

## Where the two execution paths meet

The front end produces one optimized, verified `mir.Program`.

- The shipping path lowers it to native code and links an artifact.
- The oracle interprets the same MIR only inside tests.

Both call `runtime/` for dynamic semantics. Each program specification runs on
both paths and compares output, raised error, trap code and text, frame trace,
host world, and live-object census. Agreement is evidence of one language;
duplicating a semantic above this seam creates two languages and is therefore
a bug.
