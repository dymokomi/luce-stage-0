# Structure audit — module boundaries, separation of concerns, file organization

Audited at `0a22b81` (merge of `refusal-tests`).  `zig build test`:
48/48 steps, **944/944 tests passed**.  56,400 lines of Zig across 74
files.  Nothing in this document changes code; it is a judgment of the
tree against `docs/CODING_GUIDE.md` and against how Zig, Rust and Go
organize compilers of this size.

## The reconciliation this audit had to make

The owner's instinct says large files should be split.  The guide says
**split only where a subproblem has a one-to-three-function interface,
never because a file is long** — and that a file boundary in Zig is a
privacy boundary, so a split that forces `pub` for a sibling is the
wrong split.

These agree, and the test that reconciles them is:

> **A large file is fine if it is one subject, well-sectioned.  A large
> file hiding several subjects is the finding, at any size.**

Applied honestly, that test acquits the two biggest files in the tree
and convicts several smaller ones.  It also has a second half the tree
has been reading selectively: the licence to keep a 4,000-line file is
conditional on the sectioning that makes it navigable.  Where the
sectioning is absent, the licence has not been earned.

---

## Summary of verdicts

| # | Finding | Verdict | Effort |
|---|---|---|---|
| 1 | `declarations.zig` publishes pass two's state to pass two | Change | M |
| 2 | `host.zig` holds a reporting module with no interface | Change | S–M |
| 3 | The two `product.zig` harnesses are duplicated, and drifted | Change | M |
| 4 | `libluce_rt` imports the compiler's IR stage | Change | S |
| 5 | `abi.zig` holds two contracts with two version numbers | Change | S |
| 6 | Navigation is bimodal — eight large files have no sections | Change | S, broad |
| 7 | Constant-folding rules written twice, verbatim | Change | M |
| 8 | The builtin-name list lives in three places | Change | S |
| 9 | `writeWhole` and `stemOf` each exist twice, with different contracts | Change | S |
| 10 | `07_optimize/effects.zig` is right, and in the wrong stage | Change | S |
| 11 | Two barrel blemishes in an otherwise clean discipline | Change | XS |
| 12 | `helpers.zig` is a junk drawer by its own description | Change | S |
| 13 | `key.zig` is a private detail sitting among shared modules | Change | XS |
| 14 | The guide and CLAUDE.md name files that have moved | Change | XS |
| 15 | `builder.zig` and `lower.zig` are each one subject | **Fine as is** | — |
| 16 | The parser's sibling cycle, `05_hir.zig`, sanitization, the layering law | **Fine as is** | — |

---

## 1. `declarations.zig` publishes pass two's state to pass two

**Evidence.** `04_semantics/builder.zig:20-31` imports fifteen types
from its sibling: `Analyzer`, `Scope`, `LocalInfo`, `FoundLocal`,
`LoopFrame`, `OwnershipClass`, `Poison`, `FunctionInfo`,
`ConstantValue`, `ModuleTree`, `Analyzed`, `Error`, `isReserved`, and
the two range messages.  `declarations.zig:18` imports exactly one name
back — `FunctionBuilder`.  Fifteen out, one in.

Seven of those fifteen are not pass one's types at all.
`OwnershipClass` (`declarations.zig:180`), `Poison` (182), `LocalInfo`
(184), `Release` (203), `Scope` (209), `FoundLocal` (216) and
`LoopFrame` (222) are pass **two**'s state.  `LoopFrame`'s own doc
comments at `declarations.zig:226` and `:229` reference
`self.scopes.items.len` and `self.temps.items.len` — fields that exist
only on `FunctionBuilder`, in the other file.  `Scope` and `LoopFrame`
are never constructed in `declarations.zig`.  They are `pub` there for
one reason: `builder.zig` imports them.

That is the guide's own failure test, met exactly
(`docs/CODING_GUIDE.md:128-132`), in the stage that quotes the guide.

On top of it, `Analyzer` carries 25 `pub fn`
(`declarations.zig:265-1336`) and `builder.zig` needs eleven of them —
`carriesObjects`, `heapOf`, `importsModule`, `importSpelling`,
`internHeapType`, `ownsStorage`, `qualify`, `refuseOptionalPart`,
`resolveType`, `typeName`, `fail`.  The other fourteen —
`collectStructs`, `collectConstants`, `collectFunctions`,
`collectFunction`, `checkEntry`, `evaluateConstant`, `constantError`,
`foldConstant`, `foldConvert`, `foldConstruct`, `foldBinary`,
`lowerFunction`, `deinitScratch`, `run` — are `pub` for nobody.
Outside `04_semantics/`, the entire stage is consumed through four
names: `analyze`, `ModuleTree`, `max_diagnostics`, `Error`
(`compile.zig:117`, `compile/modules.zig:48`,
`specs/errors_spec.zig:1416`).

**Verdict: change.** Not by merging — the pass-one/pass-two seam is a
real subject boundary — but by giving the shared vocabulary a home.
Extract `OwnershipClass`, `Poison`, `LocalInfo`, `Release`, `Scope`,
`FoundLocal`, `LoopFrame`, `FunctionInfo`, `StructShape`,
`ConstantValue`, `ConstantInfo`, `TypedConstant` into
`04_semantics/context.zig`.  Those types are then `pub` because the
file's job is to be the stage's shared vocabulary — a real API
boundary — rather than `pub` because a sibling reached for them.  Then
drop `pub` from the fourteen methods that have no caller.

**Precedent.** This is the shape Go and Rust both settled on.
`cmd/compile/internal/ir` holds the node and symbol vocabulary;
`typecheck` and `walk` are separate packages that operate on it and do
not export their state to each other.  Rust puts the vocabulary in
`rustc_middle::ty` and runs `rustc_hir_analysis` and `rustc_hir_typeck`
over it as separate crates.  Neither language has a pass exporting its
own working state to the pass beside it.

**Effort: M.** Mechanical move plus import updates; no logic changes.

---

## 2. `host.zig` holds a reporting module with no interface

**Evidence.** `src/apps/host.zig` is 1,835 lines with exactly one
full-width section header — `Tests`, at line 1171.  Lines 900–1024 are
a coherent subject that never touches the `Host` struct: `max_file_size`
(900), `max_printed_frames` (904), the five exit codes (`exit_ok`,
`exit_trapped`, `exit_errored`, `exit_exhausted`, `exit_broken`,
920–927), `printTrap` (951), `printError` (990), `printLeaks` (1018).
A grep for `self.` or `Host` across those 125 lines returns **zero**
hits.  Its consumers are `loom/runner.zig:578,586,594` and
`start.zig:108,116,124` — two files, neither of which wants a terminal.

Three free functions and a table of constants, with two external
consumers and no dependence on the parent's state, is precisely the
one-to-three-function interface the guide says to split on.

The tell that it was never extracted is in the signatures:
`printTrap(…, trace: anytype, …)` at `host.zig:956` and
`printError(…, origin: anytype, …)` at `:995`.  Those are two of only
four non-format `anytype` parameters in the entire 56,400-line tree
(the others are `runtime/test.zig:59` and `helpers.zig:60`), and the
guide bans exactly this — *"`anytype` is for format arguments, not for
data"* (`docs/CODING_GUIDE.md:35-36`).  The boundary has no type
because the boundary was never drawn.

The sanitizer at 1084–1141 (`sanitizeStep`, `appendSanitized`,
`writeSanitized`) is the same shape: one rule, two adapters, no `Host`
state.

**Verdict: change.** Move 900–1024 to `src/apps/report.zig` and give
`trace` and `origin` real types; the trace shape is already
`luce.llvm.abi`'s, and typing it is what makes the file movable.  The
sanitizer can follow or stay — it is genuinely terminal-adjacent, and
`host.zig:1091-1094` argues well for keeping the rule beside the two
channels that use it.

**Precedent.** Go keeps this seam in `cmd/go/internal/base`: exit
codes, `Fatalf`, and error reporting are their own package precisely
because every command needs them and none of them is the command.

**Effort: S–M.**  The move is small; typing the two `anytype`
parameters is the real work.

---

## 3. The two `product.zig` harnesses are duplicated, and have drifted

**Evidence.** `apps/loom/product.zig:213-232` and
`apps/luce/product.zig:150-169` are **byte-for-byte identical** —
verified by `diff` — down to the doc comment `/// What one run of a
real binary did.`  The install tree is the same object under two names:
`Install` (`loom/product.zig:51`) and `Tree` (`luce/product.zig:37`),
with identical `make` preambles (59-66 / 42-49), identical `at`
(100-102 / 76-78), identical `exists` (104-108 / 87-91), and a `spawn`
whose body matches line for line (263-295 / 118-147) apart from an
environment map.  Even the `//!` header paragraph is copied
(loom 34-38 / luce 20-24).

**And it has already cost something.**
`luce/product.zig:80-85` creates parent directories before writing:

```zig
if (std.fs.path.dirname(name)) |directory| {
    try self.scratch.dir.createDirPath(io, directory);
}
```

`loom/product.zig:110-112` does not.  Two copies of one function, one
of which has since learned something the other has not — so loom's
harness cannot write a nested source file at all, and nobody noticed
because the two copies are 900 lines apart in different directories.
That is the whole argument against duplication, demonstrated.

Related: the artifact tag's field offsets are hardcoded as literals at
`loom/product.zig:756-765` and spelled out again as C at `:900-921`,
making three descriptions of `abi.Artifact` — while the same file
already imports `luce` (`loom/product.zig:42`) and could read them.

**Verdict: change.** A shared `src/apps/harness.zig`, test-only,
imported by both product modules in `build.zig`: `Install` (with
`make`/`at`/`write`/`exists`/`read`/`deinit`), `Ran`, and one `spawn`.
Roughly 200 of loom's 1,062 lines and 150 of luce's 694 are harness
rather than assertion; what remains in each file is then what its name
promises — the assertions about *that* product.  The loom-specific
pieces (`plantCompiler`, `calls`, `corrupt`, `resign`) stay put.

**Precedent.** Go shares exactly this: `internal/testenv` and the
`cmd/go` script harness are common infrastructure, and each test file
carries only its own assertions.  Rust does the same with `compiletest`.
Neither ships two copies of "make a temp install tree and run the
binary".

**Effort: M.**

---

## 4. `libluce_rt` imports the compiler's IR stage

**Evidence.** `build.zig:37-38` builds the runtime as its own module
rooted at `src/luce/runtime.zig`.  That module's source graph reaches
the entire front end: `runtime/heap.zig:18`, `runtime/operators.zig:10`
and `runtime/exports.zig:37` each `@import("../06_mir.zig")`, and
`06_mir/module.zig:502-503` imports `../compile.zig` and
`../interpreter.zig` in turn.

What the runtime actually needs from all that is **four enums**:
`TrapCode` (`06_mir/defs.zig:220`), `ErrorCode` (177), `BinaryOp` (15),
`FileAct` (200).  Nothing else.

Zig's lazy analysis means no compiler code lands in `libluce_rt.a`, so
this costs no bytes.  It costs the claim.  `runtime.zig` is described
as *"Luce's semantics as a linkable library behind a C ABI"* that
*"builds as a real static library"* — and a library that stands alone
should not have a source dependency on the front end that happens to
share its vocabulary.  Today a reader cannot tell from the import
graph where the library ends.

**Verdict: change.** Move the four enums to `support/` — either into
`support/types.zig`, whose doc already says *"this is the only type
language the checker and the IR both speak"*
(`support/types.zig:1-6`), or a sibling `support/vocabulary.zig` — and
have `06_mir.zig` re-export them so no existing call site changes.
`runtime/` then imports `support/`, which is what `support/` is for
(`luce.zig:35`: *"Cross-cutting support: not a stage, used by all of
them"*).

**Precedent.** This is the exact problem Go solved with
`internal/abi`: shared constants live there specifically so `runtime`
never imports `cmd/compile`.  Rust factored `rustc_abi` out as a
separate crate for the same reason.  Both languages treat "the runtime
must not depend on the compiler" as a hard line.

**Effort: S.**  Four enum moves and a re-export.

---

## 5. `abi.zig` holds two contracts with two version numbers

**Evidence.** `08_llvm/abi.zig` is 755 lines and carries two things
that the file itself says move independently.

The published host ABI: `version` (97), `Status` (263), `Entry` (284),
`Answer` (293), thirty `*Fn` typedefs (311–568), `Host` (569),
`Slot` (617), `entry_symbol` (141).

The artifact tag: `machine` (113), `generator` (137),
`artifact_symbol` (142), `artifact_format` (152), `artifact_magic`
(156), `Artifact` (171), `sourceHash` (213), `Mismatch` (218),
`checkArtifact` (247).

`abi.zig:144-148` states the separation outright: *"The layout version
of `Artifact` itself.  **Separate from `version`** because a loader has
to read the tag before it can believe anything else in it."*  Two
independent version numbers in one file is two contracts in one file.
CLAUDE.md agrees: the generator identity *"is deliberately not part of
the host ABI and moves on its own schedule."*

The consumers are disjoint.  The host ABI is consumed by `lower.zig`
and by host implementations.  The tag is consumed by
`apps/native.zig:429,461,462`, `apps/start.zig:42,70`,
`apps/luce/main.zig:273`, `apps/luce/object.zig:248`,
`apps/loom/runner.zig:278`, `apps/loom/product.zig:783,851,856` —
eight loader sites, none of which needs `Host`.  `lower.zig` touches
the tag at exactly one place, `describeArtifact` (773).

The interface is `sourceHash`, `checkArtifact`, `Artifact`, `Mismatch`
— one-to-three functions.  Nothing is forced `pub`: the only
compile-time coupling is `abi_version: u32 = version` at line 177, one
field default that an import carries.

**Verdict: change.**  `08_llvm/artifact.zig`, re-exported from
`08_llvm.zig` beside `abi`.  Note this is the precise inverse of
finding 15: `abi.zig` is a 755-line file hiding two subjects, while
`lower.zig` is a 4,672-line file holding one.  Size predicted neither.

**Effort: S.**

---

## 6. Navigation is bimodal — eight large files have no sections

**Evidence.** The guide requires dashed section headers
(`docs/CODING_GUIDE.md:73-78`), and that requirement is what makes the
"never split because it is long" rule survivable.  Two header styles
are in use — the full-width box (`native.zig:38`) and an indented
inline rule (`builder.zig:158`) — and both are legitimate.  Counting
both:

**Exemplary:** `06_mir/build.zig` 867 lines / 11 sections,
`runtime/exports.zig` 838 / 7, `apps/native.zig` 652 / 7,
`specs/agree.zig` 1,451 / 6, `03_parse/grammar.zig` 1,341 / 6,
`apps/luce/product.zig` 694 / 5, `04_semantics/builder.zig` 4,677 / 13.

**Absent or near-absent:**

| file | lines | sections |
|---|---|---|
| `apps/host.zig` | 1,835 | 1 (`Tests`) |
| `08_llvm/lower.zig` | 4,672 | 3 |
| `runtime/heap.zig` | 1,401 | 2 |
| `interpreter/machine.zig` | 1,003 | **0** |
| `06_mir/verify.zig` | 856 | **0** |
| `03_parse/expressions.zig` | 867 | **0** |
| `08_llvm/abi.zig` | 755 | **0** |
| `08_llvm/runtime_effects.zig` | 733 | **0** |

Two existing headers are also actively misleading — worse than absent,
because a reader trusts them:

- `builder.zig:2550` `Errors` spans 842 lines, but from `lowerGive`
  (2765) to 3391 it holds `emitConstant`, `lowerCopy`, `lowerNew`,
  `lowerListLiteral`, `lowerIndex`, `lowerField`, `lowerBinary`,
  `lowerCoalesce`, `lowerShortCircuit`, `lowerUnary` — 627 lines of
  ordinary expression lowering filed under "Errors", while the
  `Expressions` header at 2417 covers only two dispatch functions.
- `lower.zig:4486` `-- scalar math helpers` covers `emitHeapNew`
  (4585), `emitOwnership` (4630), `namedBinding` (4647) and
  `emitTrapMessage` (4668) — 87 of its 187 lines are not scalar math.

**Verdict: change.**  This is the correct answer to the owner's
instinct.  The guide is right that these files should not be split; it
is also right that they need internal navigation, and that half has
been applied unevenly.  A sectioning pass over the eight files above,
plus the two mislabelled sections, is the cheapest large improvement
in this document.  Pick one header style and say which in the guide.

**Precedent.** Zig's `x86_64/CodeGen.zig` — the 190k-line file the
guide cites as licence — is navigable only because it is rigorously
organized around a dispatch switch that acts as its table of contents,
with `airX` handlers grouped beneath it.  rustc's `late.rs` groups by
`impl` block per visitor concern.  Neither is a flat 4,000 lines.  The
licence and the sectioning are the same argument.

**Effort: S per file, broad.**  No logic changes.

---

## 7. Constant-folding rules are written twice, verbatim

**Evidence.**  Stage 4 decides the same rules in both passes, with the
diagnostic text duplicated as literals rather than shared:

| rule | pass one | pass two |
|---|---|---|
| binary operand typing | `foldBinary` `declarations.zig:1114` | `lowerBinary` `builder.zig:3106` |
| `Int()`/`Float()` conversion | `foldConvert` `declarations.zig:1038` | `lowerConvert` `builder.zig:4161` |
| struct construction | `foldConstruct` `declarations.zig:1062` | `lowerConstruct` `builder.zig:4068` |
| `ord()` folding | `declarations.zig:992-1006` | `builder.zig:4269-4278` |

Message text duplicated verbatim: *"operands are {s} and {s}
(conversions are explicit)"* at `declarations.zig:1130` and
`builder.zig:3132`; *"field {s} given twice"* at 1089 / 4105; *"{s} is
missing field {s}"* at 1105 / 4147; *"{s} is a function namespace and
has no value fields"* at 1075 / 4079.

The stage already knows this is a hazard — `declarations.zig:35-36`
shares `integer_range_message` and `float_range_message` for exactly
this reason.  The remedy was applied to two strings and not to the
dozen others.

**Verdict: change.**  Finish what lines 35-36 started: move the shared
message texts beside them, and where the *rule* rather than the wording
is duplicated (operand typing, field checking), have both passes call
one predicate.  A constant folder and a lowering walk legitimately
differ in what they do with the answer; they must not differ in the
answer.

**Effort: M.**

---

## 8. The builtin-name list lives in three places

**Evidence.** `builder.zig:4216-4258` (`lowerIntrinsic`'s table, 39
names), `builder.zig:843-853` (`isPureBuiltin`, the same 39 plus `Int`
and `Float`), and `declarations.zig:49-61` (`reserved_names`, 51
overlapping names).  The first two are 3,375 lines apart in one file.
Nothing enforces agreement, so a builtin added to one and not the
others silently changes ownership analysis or lets a user shadow a
builtin.

Three further cases are duplicated *and acknowledged in comments but
unenforced*: `mayMutateContainers` (`builder.zig:747`) vs
`07_optimize/effects.zig` — noted at `builder.zig:744`;
`isFallibleIntrinsic` (`builder.zig:4660`) vs `06_mir/verify.zig` —
noted at 4657 (*"keeps the same list"*); `fresh_object_methods`
(`builder.zig:931`) vs the method tables — noted at 926 (*"must agree
with it"*).

**Verdict: change.**  A comment saying two lists must agree is a
statement that nothing checks they do.  These should be one table, or
an exhaustive switch over `mir.Intrinsic` so adding a member is a
compile error — the pattern `07_optimize/effects.zig:15-17` already
uses deliberately and describes well.

**Effort: S.**

---

## 9. `writeWhole` and `stemOf` each exist twice, with different contracts

**Evidence — the sharper one.**  Two functions, same name, same
signature shape, different durability:

`apps/files.zig:278` — atomic, synced, replaces:
```zig
pub fn writeWhole(io: std.Io, path: []const u8, content: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ ... });
    try atomic.file.sync(io);
    try atomic.replace(io);
}
```

`apps/native.zig:413` — private, neither:
```zig
fn writeWhole(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try file.writePositionalAll(io, bytes, 0);
}
```

`native.zig` does not import `files`, so a reader cannot tell which
they are looking at without checking imports.  The guide's rule is
*"Do not hide durability"* (`docs/CODING_GUIDE.md:152-153`); two
functions of one name with two durability contracts hide it by
construction.

**`stemOf` twice**, `loom/runner.zig:538` returns `?[]const u8` for
`.luc` only; `luce/main.zig:330` returns `[]const u8` for `.luc` and
`.lcm`.  Same name, different type, different failure meaning.

**And the smaller repeats.**  The sibling-temp-file idiom
(`writerTag` + `allocPrint` + `defer deleteFile`) at `native.zig:322`,
`native.zig:360`, `runner.zig:368` — three sites, with the comment
paraphrased at two.  The `".lc"` extension decided at `native.zig:62`,
`runner.zig:465`, `loom/main.zig:94` and `shell.zig:146`.  The
temp-dir realpath idiom inlined at sixteen sites, though
`runner.zig:642` already extracted it — privately.  The libc environ
walk open-coded at `host.zig:1149` and `loom/product.zig:203`.

**Verdict: change.**  Rename `native.zig`'s to say what it is
(`writeFast`, or better, call `files.writeWhole` and take the sync).
Pick one `stemOf` and put it beside `native.Kind.extension()`, which
already owns the extension vocabulary.  Add
`native.siblingTemporary(gpa, output, suffix)`.  Make
`runner.scratchDirectory` public to the apps tree.

**Effort: S.**

---

## 10. `07_optimize/effects.zig` is right, and in the wrong stage

**Evidence.**  `08_llvm/lower.zig:91` and `08_llvm/loops.zig:54` both
import `../07_optimize.zig`, and the only thing either uses is
`optimize.effects.viewStable`.  Stage 8 reads a predicate that lives
inside stage 7.

The *reason* is excellent and the file states it
(`07_optimize/effects.zig:19-25`): the question is asked in one place
*"so the two stages cannot come to different answers about the same
instruction."*  That is exactly right.  But the answer is a property of
the **instruction set**, not of the optimizer — `effects.zig` imports
`../06_mir/defs.zig` and nothing from its own stage — so its home
should be `06_mir/effects.zig`, where both consumers reach it forwards.

A second, smaller cost of the current placement: `08_llvm` now has two
files called "effects" for unrelated things, and `lower.zig:96` aliases
`runtime_effects.zig` as `effects` while `lower.zig:91` imports
`optimize`, whose submodule is *also* `effects`.  The doc comments at
`lower.zig:1369` and `:2344` write "`effects.viewStable`", which under
that file's own aliases resolves to the wrong module.
`loops.zig:45` gets it right.

**Verdict: change.**  Move to `06_mir/effects.zig`; rename
`08_llvm/runtime_effects.zig`'s export from `effects` to something that
is not a homonym (it is a table of `libluce_rt` symbol attributes —
`services` would say so).

**Precedent.** Go puts `Op` properties on `cmd/compile/internal/ir`;
the SSA passes consult them and do not own them.  LLVM puts
instruction properties on the IR, not in an analysis pass.

**Effort: S.**

---

## 11. Two barrel blemishes in an otherwise clean discipline

Barrel discipline is, on the whole, **good** — see finding 16.  Two
blemishes:

**`04_semantics.zig:72-74` publishes the stage's entire inside**:
```zig
pub const declarations = @import("04_semantics/declarations.zig");
pub const builder = @import("04_semantics/builder.zig");
pub const helpers = @import("04_semantics/helpers.zig");
```
solely so its test block at 76-80 can reference them.  No consumer
outside the stage uses any of the three.  Three sibling barrels do the
same job without publishing anything —
`03_parse.zig:87` (`_ = @import("03_parse/test.zig")`),
`08_llvm.zig:87`, `02_lex.zig:58-59`.  Drop the three `pub const`s and
import directly in the test block.

**`06_mir/module.zig:26` routes through its own stage barrel**
(`@import("../06_mir.zig")`) for seventeen names that all originate in
`06_mir/defs.zig`, creating a self-cycle `06_mir.zig → module.zig →
06_mir.zig`.  Its four siblings — `verify.zig:5`, `print.zig:4`,
`test.zig:4`, `defs.zig` — all import `defs.zig` directly and have no
cycle.  One-line fix, and it makes the stage's internal graph acyclic.

**Effort: XS.**

---

## 12. `helpers.zig` is a junk drawer by its own description

**Evidence.** Its `//!` says *"Small standalone helpers shared across
the analyzer modules"* — which is the definition of a junk drawer — and
the file is one.  Six unrelated subjects, three with no header at all:
limits (14, 21), dotted-name chains (26–38), a comparison shim (60), a
depth guard (76), `// Literals` (113–156), `// Name suggestions`
(158–235), and an unheaded control-flow block at 237–289
(`returnsOnAllPaths` 250, `alwaysExits` 274).

Mitigating, and it matters: every declaration is a pure function of
one to three inputs, and it is the only file in the stage with tests
(297–394).  So the contents are fine; the container is not a subject.

**Verdict: change, lightly.**  `Suggestion` + `editDistance` (158–235)
is a genuine standalone subject and would survive on its own as
`04_semantics/suggest.zig`.  `returnsOnAllPaths`/`alwaysExits` is a
second one (control-flow reachability over the AST).  What is left is
literal parsing plus two constants, which is a legitimate small file if
it is *named* for that.  Failing all of it, at minimum give the three
unheaded regions headers.

**Effort: S.**

---

## 13. `key.zig` is a private detail sitting among shared modules

`src/apps/key.zig` is 102 lines, is **not** a build module, and has
exactly one importer — `host.zig:19`, by relative path.  It sits at
`src/apps/` top level beside `files.zig`, `native.zig`, `streams.zig`,
`host.zig` and `start.zig`, every one of which *is* a shared build
module, so it reads as a sixth.

It is also half of one subject: `key.zig:30-92` decodes bytes into a
`Key`, and `host.zig:1037-1060` (`keyView`) maps a `Key` to the stable
name the Luce ABI promises.  No logic is duplicated — the union's
variants are enumerated once and switched on once, which is what a
total switch is for — but the seam is drawn through the middle of
"keys" rather than around it.

**Verdict: change.**  Either move `keyView` into `key.zig`, making it
the whole keys subject with a two-function interface (`decode`,
`name`), or fold it into `host.zig`.  The current line buys nothing.

**Effort: XS.**

---

## 14. The guide and CLAUDE.md name files that have moved

`docs/CODING_GUIDE.md:53` and `CLAUDE.md:79` both cite
`src/apps/loom/host.zig` as the `setup` pattern's example, and
`docs/CODING_GUIDE.md:97` lists *"src/apps/loom/ — the terminal:
shell, runner, host, keys, palette."*  Both files live at
`src/apps/host.zig` and `src/apps/key.zig`, and have since `host.zig`
became a module shared by loom and the standalone start library.

The map not matching the territory is a structure finding: the guide is
the first thing a contributor reads, and its organization block is
where they learn the layout.  Two smaller drifts in the same file:
`docs/CODING_GUIDE.md:11` links `[docs/CODEGEN.md](docs/CODEGEN.md)`
from inside `docs/`, which resolves to `docs/docs/CODEGEN.md` and is
dead; and `:100` lists the docs directory as *"V2.md LANGUAGE.md
OWNERSHIP.md docs/CODEGEN.md CODEGEN.md"*, naming one file twice.
`:88`'s note on `05_hir` — *"a named seam; nothing in it yet"* — is
still accurate.

**Effort: XS.**

---

## 15. `builder.zig` and `lower.zig` are each one subject — fine as is

Both were read in full against the split test.  Both pass.

**`04_semantics/builder.zig`, 4,677 lines.**  `FunctionBuilder`
(`builder.zig:52`) has thirteen fields, eleven of them mutable and
cross-cutting, and they are genuinely interlocked rather than merely
adjacent: `takeStorage` (664) mutates `temps` *and* emits to `code`;
`openFallible` (2561) sets `opened`, pushes `carried` and reads
`temps.items.len`; `producesFreshStorage` (589) reads
`code.instructions` through `sourceOf`, which reads `carried`.
Ownership, storage, narrowing, temps and the tape are one state
machine.  Nine functions in the file take no `self` at all — about 200
lines out of 4,677.

Every candidate split fails.  Ownership checking is the most tempting
and the most wrong: it would export `takeStorage`, `ownedForStore`,
`parkFreshStorage`, `registerTemp`, `yieldsOwnership`,
`failNeedsOwnership`, `producesFreshStorage`, `sourceOf`, `TempSlot`
and `Carried` — a dozen `pub`s for one sibling.  `lowerIntrinsic`
(4204, 456 lines) looks separable and is not: its `free_object` arm
(4354) mutates `scopes`, `loops` and `LocalInfo.poisoned`.  Type
fitting is 18 lines.  F-strings are not here at all — they desugar in
`03_parse/expressions.zig:603-800`.

The one real seam is method resolution by receiver shape —
`objectMethod` (3900), `sequenceMethod` (4004), `methodFail` (3765) and
the four name tables (3887–3893), about 300 lines that touch **zero**
`FunctionBuilder` fields and need only `analyzer.fail`,
`analyzer.carriesObjects` and `analyzer.internHeapType`.  It is
blocked by one thing: the interface currently passes `[]const Value`,
and `Value` (47) is the builder's private currency used ~200 times.
Change the parameter to `[]const Type` — the tables only ever read
`.value_type` — and the exported surface is two functions and a
two-field result.  **That one is worth doing; the rest are not.**

**`08_llvm/lower.zig`, 4,672 lines.**  This one is the tree's best
structural argument, and it runs opposite to what "too big" would
predict.  The file has exactly **five** `pub` declarations (114, 132,
144, 161, 170) — all five re-exported by `08_llvm.zig:78-82` as the
stage's real API.  `Module`, `Body`, `Error` and all 133 methods are
private.  **Nothing in it is `pub` for a sibling.**

Its two prior splits are textbook-correct.  `loops.zig` and
`runtime_effects.zig` do not import `lower.zig` **at all**; the
dependency is one-way.  `loops.zig` publishes one function — `plan`
(103) — which `lower.zig` calls at four points, and is pure MIR
analysis that never mentions LLVM.  `runtime_effects.zig` publishes
`attributes` (676), which `lower.zig` calls once, at line 434.  Both
are one-to-three-function interfaces understandable without the
parent's state.  This is what the guide's rule looks like applied
correctly, and it should be cited as the in-repo example.

The walk itself is `self.values[register] = …`; every candidate — the
76-arm intrinsic switch, the arithmetic block, the array-view cache,
the type mapping — needs `*Body`, and each would force six to twenty
declarations `pub`.  The trap machinery is genuinely one subject but is
*scattered* across four sections (`Module` 1125–1230, `Body`
3213–3282, `propagate` 3846, `checkExhausted` 2933, `emitTrapMessage`
4668) — which is finding 6, sectioning, not a split.

**Verdict on both: fine as is.**  The owner's instinct is right about
the tree in general and wrong about these two files specifically, and
the guide's rule is what tells them apart.  What both files need is
finding 6.

---

## 16. Fine as is, and worth saying out loud

Several things this audit went looking for and did not find.

**The layering law holds.**  No file in `src/apps/` names a numbered
stage in code — every `0N_` string in the apps tree is inside a
comment.  Access is exclusively through barrel re-exports (`luce.mir.*`,
`luce.llvm.*`, `luce.compile.*`).  The one exception,
`apps/luce/object.zig:17` importing `emit` directly, is a documented,
load-bearing promotion: `08_llvm/emit.zig` is its own build module
(`build.zig:81-89`) precisely so libLLVM stays out of `luce`, and
`08_llvm.zig:75-82` deliberately does not re-export it.  Worth a line
in `object.zig`'s header where a reader will see it.

**The host never touches IR internals** and the language module never
touches the host.  `host.zig` reaches `luce.llvm.abi` (the published
ABI) and two enum tags for reporting — nothing structural.  And
`host.zig:10-15` records that it *used* to build a second vtable for
the interpreter and no longer does, so the ABI mapping exists once.

**Sanitization is single-sourced, and the file says why.**
`host.zig:1091-1094`: *"The rule lives in one function… Two copies of
the rule would be two answers to 'what counts as safe'."*  One
`sanitizeStep` (1095), two adapters (1116, 1134), and all eight call
sites route through them.  Exactly the discipline finding 8 asks for
elsewhere.  (One loose end nearby: the screen-clear escape sequence is
written at both `host.zig:474` and `shell.zig:114`, and SGR generation
exists at `host.zig:1064` and `palette.zig:20` by two mechanisms — in a
file whose stated rule is *"the host writes every control byte
itself"*.)

**Barrel test coverage is complete.**  Every stage barrel's `test`
block reaches every file in its directory that has tests — checked file
by file.  Nothing's tests are silently not running, which is the
classic Zig failure and the one the guide warns about.

**The parser's sibling cycle is fine.**  `grammar.zig:33` ↔
`expressions.zig:12` is mutual, but narrow: expressions needs two names
(`Error`, `Parser`), grammar needs four (`expression`, `make`,
`endsList`, `startsExpression`).  Recursive-descent parsing is mutually
recursive by nature, and six names across the seam is not the
fifteen-and-eleven of finding 1.  Similarly `interpreter/machine.zig:19`
importing `../interpreter.zig` is a deliberate header/implementation
split — six vocabulary types one way, `run` the other —
and `interpreter.zig` describes itself as the header.

**`05_hir.zig` is an empty file and should stay.**  Eighty lines of
`//!` explaining what an HIR is for, what currently does the desugaring
instead (`03_parse` for f-strings and `elif`, `builder.zig` for
methods, `for`, compound assignment), what building it would cost, and
the one decision that cannot be taken back (*"whole-array operations
survive HIR and MIR as single nodes"*).  A named gap with the reasoning
attached is worth more than a number that never appears.  The only
quibble: eighty lines of design record in a barrel is really
`docs/PIPELINE.md` material, and a reader looking for the stage list
has to scroll past it.

**Naming is near-perfect on the mechanical axis.**  937 distinct
function names across `src/luce/` and `src/apps/`: **zero** contain an
underscore, **zero** are named `get*`, and there is no `Manager`,
`Factory` or `Helper` type in the tree.  Three names use verbs the
guide's spirit rejects — `handleParts` (`lower.zig:2246`), `makeStruct`
(`runtime/heap.zig:1050`), `processEnvironment` (`host.zig:1149`).
That is three out of 937.

**There is no debt ledger.**  A grep for `TODO`, `FIXME`, `XXX`,
`HACK` and `deprecated` across 56,400 lines returns **zero** real hits
— the only matches are the words appearing inside prose and one
citation of an upstream LLVM FIXME.  Very few codebases of this size
can say that, and it is strong evidence the guiding principle in
CLAUDE.md is actually being followed.

**Local naming inversions**, for whoever does the sectioning pass:
`methodFail` (`builder.zig:3765`) against six `failX` siblings in the
same file; `constantError` (`declarations.zig:883`) where the stage's
word is `fail`; `blockMayMutateContainers`/`statementMayMutateContainers`
(804/811), redundant type nouns the parameter already carries;
`narrowSave`/`narrowRestore`/`narrowIntersect` (183/187/196), noun-first
beside a correct `narrow`/`widen`; `rt` and `of` as locals at
`lower.zig:3928-3929`, where `of` is the file's standard name for a
`types.Type` at twenty other sites; `Install` vs `Tree` and `Emit` vs
`Kind`, one concept under two names in each pair.

---

## The answer to the owner

**Yes — this tree is contributor-ready, and by a wider margin than the
file sizes suggest.**  The layering law holds under grep: no app
reaches into a stage, no stage reaches forward, the host never touches
IR internals, every barrel's tests actually run, sanitization and the
ABI mapping each exist exactly once, and 56,400 lines contain not one
`TODO`.  The two files that look most alarming are the two that need
the least: `lower.zig` has five `pub` declarations and two prior splits
that are textbook-correct, and `builder.zig` is a genuinely irreducible
state machine — the guide is right to protect both, and the owner's
instinct to split them is the one instinct here to overrule.  What is
real is smaller and more fixable.  Four seams are drawn in the wrong
place: `declarations.zig` exports pass two's state to pass two (the
guide's own failure test, in the file that quotes the guide),
`host.zig` hides a reporting module with two external consumers and no
typed interface, `abi.zig` carries two contracts with two version
numbers that its own comments say move independently, and
`libluce_rt` — the library that is supposed to stand alone — imports
the compiler's IR for four enums.  Three decisions are made twice and
one has already drifted into a bug: the two `product.zig` harnesses are
copies, and loom's copy never learned to create parent directories.
And the licence to keep a 4,000-line file has been claimed without
always paying for it — eight large files, `interpreter/machine.zig` and
`08_llvm/abi.zig` among them, have no section headers at all, and two
of the headers that do exist name the wrong thing.  None of that is
architecture; all of it is a week of careful, low-risk work, and the
ranked list above is the order to do it in.
