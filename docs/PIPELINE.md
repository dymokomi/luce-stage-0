# The pipeline — what each stage does, and how complete it is

`src/luce/compile.zig` is the driver: it walks one source file through
every stage below, in order, and produces verified MIR.  Each stage is
a numbered folder beside it, so the pipeline is legible from a
directory listing:

```text
src/luce/
  luce.zig        the module root: one exported name per stage
  compile.zig     THE DRIVER — the stage sequence, in order
  01_source/      load
  02_lex/         lex
  03_parse/       parse
  04_semantics/   resolve, type-check, validate
  05_hir/         (barrel only — nothing to put in a folder yet)
  06_mir/         the typed MIR, its verifier, and the .lc format
  07_optimize/    optimize MIR
  08_llvm/        lower MIR to machine code
  compile/        the driver's implementation siblings
  runtime/        libluce_rt — the semantics both engines call
  interpreter/    the reference engine
  support/        diagnostics, types — cross-cutting, not a stage
  std/            the Luce standard library, in Luce
  specs/          the executable specification
```

Only stages are numbered.  Exported names in `luce.zig` drop the
prefixes (`luce.mir`, `luce.llvm`): the numbers order the listing, they
are not part of the vocabulary.

## Status

| # | Stage | Folder | Input | Output | Status |
|---|-------|--------|-------|--------|--------|
| 1 | Loading | `01_source/` | a module name or path | source text + `Span`/`Place` | **Partial.** Positions only. Nothing in this folder opens a file: `compile.zig`'s `Loader` is the seam, `src/apps/files.zig` the one implementation, and std resolves ahead of both from `@embedFile` tables in `compile/modules.zig`. Consolidating "what are the bytes of module X" here is the work it owes. |
| 2 | Lexing | `02_lex/` | source text | `[]Token`, layout resolved | **Complete.** Indentation becomes `indent`/`dedent`/`newline`; tabs rejected; never fails hard — bad input yields `luce.lex.*` diagnostics plus the closest reasonable stream. |
| 3 | Parsing | `03_parse/` | `[]Token` | untyped `ast.Program` | **Complete for the grammar**, with one wart: it desugars f-strings into `str(x) + …` and `elif` chains into nested `if`s while it still has only syntax. That belongs in stage 5. Recovery at line and block boundaries; expression nesting bounded. |
| 4 | Name resolution | `04_semantics/` | `ast.Program` per module, Port schema, options | `Analyzed`: struct layouts, heap-type shapes, folded constants, lowered functions | **Complete, and fused on purpose.** Stages 4, 5 and 6 are mutually recursive — resolving `xs.append(v)` needs the receiver's type — so they are one subsystem, not three folders. The numbering is contiguous because this is the intended end state. **What is a to-do:** this walk also performs stage 8's lowering, and that part *is* separable. |
| 5 | Type checking | `04_semantics/` | ″ | ″ | ″ — no implicit numeric conversion, immutable `let`, no shadowing, definite initialization. |
| 6 | Semantic validation | `04_semantics/` | ″ | ″ | ″ — `return` on every path, struct cycles refused, ownership verbs checked, input read-only / output write-only, host and fabric gates. |
| 7 | High-level lowering | `05_hir.zig` | — | — | **Not started.** A barrel with no code and no directory, named so the gap is visible. It is where the desugaring now scattered across stages 3 and 4 (f-strings, `elif`, methods, `for x in xs`, compound assignment) belongs: one explicit pass, after meaning is known and before control flow is flattened. |
| 8 | Mid-level lowering | `06_mir/` | validated program | `mir.Program` — instruction pool + basic blocks | **The representation is complete; the pass into it is not here.** `defs.zig`, `verify.zig`, `print.zig` and the `.lc` format (`module.zig`) all live here, but the AST→MIR emit is still inside `04_semantics/builder.zig`. Moving it is the seam to cut next. |
| 9 | MIR optimization | `07_optimize/` | verified MIR | smaller MIR, re-verified | **One pass: dead-code elimination.** `prune` drops every function unreachable from the entry (`import math` then one call: 26 functions become 2). No constant folding beyond what stage 4 folds while checking, no inlining, no CSE, no loop work, no dead-store elimination. Not off by choice — unwritten. |
| 10 | LLVM lowering | `08_llvm/` | optimized MIR | LLVM IR → relocatable object | **Partial, and it names its own gaps.** No `else` arms and no `unreachable`-for-"not yet", so anything unlowered returns `.unsupported` naming the tag. Missing: Float everywhere, struct values, Bytes, evaluator ports, the scalar math intrinsics, and every host service except `print`. No shared-library or executable emit mode; linking is the caller's job. `lower.zig` is the authority, docs/CODEGEN.md the prose. |

Ten conceptual stages, eight folders.  Stages 4-6 collapse into
`04_semantics/` by design; every other number maps one-to-one.

## Not stages

| Folder | What it is |
|--------|------------|
| `compile/` | the driver's implementation siblings: `modules.zig` (the import graph — stages 1-3 for every module the root reaches, std first) and `test.zig` (whole-compiler integration coverage). |
| `runtime/` | `libluce_rt`: the object heap, ownership, containers, strings, conversions, checked arithmetic, the trap channel. One implementation of every semantic, called by the interpreter *and* by compiled code. |
| `interpreter/` | the reference engine — the dispatch loop, the explicit frame stack, the traceback, host effects. Everything below the instruction level is a `runtime` call. |
| `support/` | `diagnostics.zig` and `types.zig`: cross-cutting, used by every stage, owned by none. |
| `std/` | the standard library, written in Luce and embedded with `@embedFile`. |
| `specs/` | the executable specification: ownership (S1-S43), behaviour, errors, std. |

## Where the compiled path diverges

`compileProject` stops at stage 9.  That verified, optimized MIR is
what `luce build` serializes as a `.lc` and what the interpreter runs;
`luce build --backend=llvm` takes the same program on to stage 10.
Both paths call `runtime`, which is why they agree.
