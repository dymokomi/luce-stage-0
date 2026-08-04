# Audit — naming and in-code documentation

Read against `docs/CODING_GUIDE.md`'s "Naming" and "Comments and docs"
sections.  Base: `0a22b81` (merge of `refusal-tests`), `zig build test`
= 944/944 passed.  Scope: all 88 `.zig` files under `src/` and
`site/src/`, 59,040 lines.

## The answer

**Yes — with one seam that reads like a different codebase.**  The
mechanical rules are kept to a degree the named languages do not
themselves reach: every one of 88 files opens with a `//!` purpose
line, not one of 1,281 function names breaks camelCase, not one type
name breaks TitleCase, and the forbidden-name list (`fd`, `buf`, `n`,
`ptr`, `idx`) has zero hits in identifiers this project wrote.  One
line in five of the tree is a comment, and the good comments are very
good — `heap.zig`, `abi.zig` and `agree.zig` state ownership,
invalidation and *why the alternative was rejected* at a standard Zig's
own std does not hold.  The verb vocabulary is coherent and follows a
real rule (`lower` walks a structure into the next representation;
`emit` appends code for one thing), which the week's new names —
`ownStorage`/`exportStorage`/`dropStorage`, `agreeOk`/`agreeTrap`,
`fileIn`/`runnableIn` — obey.  What breaks the illusion is
concentrated and cheap to fix: `interpreter.Host` and
`interpreter.Terminal` carry 23 camelCase `…Fn` fields whose words are
*also* reordered against the `abi.Host` table they are meant to mirror
(`readFileFn` against `file_read`, `listDirectoryFn` against
`dir_list`), which is the one seam the entire specification suite
exists to compare; forty of sixty-six published `luce_rt_*` ABI symbols
carry no contract at all; and the four largest engine files —
4,677 and 4,672 lines among them — have between zero and three dashed
section headers, in a tree whose spec files average one per sixty
lines.  Fix those three and the answer loses its qualifier.

## 1. Mechanical sweep

| Rule | Result |
| --- | --- |
| `//!` file purpose line, first line | **88 / 88** — no exceptions |
| Function names camelCase | **1,281 / 1,281 conforming** |
| — of which C ABI exports | 66 `luce_rt_*`, snake_case *correctly* (C symbols) |
| — of which TitleCase | 1: `heap.Cell`, a type-returning function (Zig convention) |
| Type declarations TitleCase | 463 `pub const`; **1 exception**: `heap.layout`, a lowercase namespace struct — deliberate, matches `std.mem` |
| Fields snake_case | **24 violations**, all `…Fn` (below) |
| Forbidden names (`fd` `buf` `n` `ptr` `idx` `tmp` `val` `cnt`) | **0** in this project's identifiers |
| `///` on public functions | 294 / 501 = **58 %** |
| Comment density | 5,109 `///` + 2,462 `//!` + 4,379 `//` = 11,950 lines = **20 %** |

Forbidden-name hits judged in context and cleared: `ptr` (170) is
always Zig's own slice `.ptr` field, LLVM's `.ptr` type tag, or LLVM IR
quoted in a doc comment; `ret` (70) is the MIR terminator, which is
LLVM's word for it and a domain term; `tmp` (27) is
`std.testing.tmpDir`; `n` appears only inside embedded Luce test
programs.  None are parameters or fields.  **This rule is clean.**

### The 24 field violations

All of them are function-pointer slots in three tables:

| File | Type | camelCase fields |
| --- | --- | --- |
| `src/luce/interpreter.zig` | `Host` | 15 — `printFn` `argCountFn` `argFn` `readFileFn` `writeFileFn` `fileExistsFn` `appendFileFn` `deleteFileFn` `renameFileFn` `listDirectoryFn` `readLineFn` `printErrorFn` `clockFn` `sleepFn` `envFn` |
| `src/luce/interpreter.zig` | `Terminal` | 8 — `rowsFn` `colsFn` `clearFn` `moveFn` `styleFn` `writeFn` `flushFn` `keyFn` |
| `src/luce/01_source/load.zig` | `Loader` | 1 — `loadFn` |

`interpreter.Host` mixes them with two snake-shaped fields (`context`,
`terminal`) inside the same struct, so the inconsistency is visible
without leaving the declaration.

## 2. Verb inventory

The leading-verb census over 1,049 distinct function names (C ABI
exports excluded):

| Family | Verbs in use | Verdict |
| --- | --- | --- |
| produce next representation | `lower` (49) | **coherent** — one word, both lowerings (AST→MIR, MIR→LLVM), which is rustc's and LLVM's own usage |
| append code for one thing | `emit` (37) | **coherent** — `Lowering.emit(instruction)` in 06_mir, `emitCall`/`emitBinary` in 08_llvm; always the leaf action, never the walk |
| write an object file | `emit` (the file `08_llvm/emit.zig`, whose entry point is `compile`) | **flagged** — a third sense of `emit`, and the file's own verb (`compile`) is a fourth stage's word |
| create | `new*` (5, all C ABI), `make*` (2), `build*` (2), `init` (5) | coherent: `new` = runtime object, `make` = value aggregate, `init` = Zig convention, `build` = a whole artifact |
| create a scope | `open*` (10) / `close*` (5) paired | **exemplary** — `openIf`/`closeIf`, `openWhile`/`closeWhile`, every pair matched |
| destroy | `deinit` (31), `free*` (5), `release*` (4), `drop*` (2), `clear` (5) | **flagged** — see `drop_storage`/`releaseStorage` below |
| look up | `get` `find` `at` `has` `resolve` (18) | coherent; matches the guide's `count has get put remove at` |
| serialize | `encode`/`decode` (module format), `read`/`write` (files), `load` (sources) | **coherent** — three layers, three word-pairs, no crossover |
| check | `check*` (12), `verify*` (6), `is*` (19), `expect*` (24) | coherent by role: `check` = a runtime guard, `verify` = the IR verifier, `is` = a predicate, `expect` = a test helper |
| report a failure | `fail` (13), `report*` (10) | coherent — `fail` raises, `report` hands out |

### Flagged inconsistencies

**A. The two host tables disagree word for word.**  This is the
finding.  `abi.Host` names every service exactly as the Luce builtin is
spelled; `interpreter.Host`, which `docs/ENGINE.md` and `agree.zig`
exist to prove is *the same table*, renames most of them:

| `abi.Host` (and the Luce builtin) | `interpreter.Host` |
| --- | --- |
| `file_read` `file_write` `file_exists` | `readFileFn` `writeFileFn` `fileExistsFn` — **word order reversed** |
| `file_append` `file_delete` `file_rename` | `appendFileFn` `deleteFileFn` `renameFileFn` — reversed |
| `dir_list` | `listDirectoryFn` — **different word entirely** |
| `arg_count` `arg` | `argCountFn` `argFn` |
| `clock_ms` `sleep_ms` | `clockFn` `sleepFn` — **units dropped** |
| `term_rows` `term_cols` `term_clear` … | `Terminal.rowsFn` `colsFn` `clearFn` … |
| `print` `print_error` `read_line` `env` | `printFn` `printErrorFn` `readLineFn` `envFn` |

Two conventions, two word orders and one outright synonym across the
one seam every specification compares frame for frame.  A reader who
learns one table has to learn the other.

**B. `drop_storage` is `releaseStorage`.**  The three storage
intrinsics are named `own_storage` / `export_storage` / `drop_storage`
in MIR and exported as `luce_rt_own_storage` / `_export_storage` /
`_drop_storage`.  Two of the three call a runtime method of the same
name (`ownValue`, `exportValue`); the third calls `releaseStorage`.
One act, two verbs, and `release*` is already spoken for by three
other methods (`releaseSlots`, `releaseFrameStorage`).

**C. `free_object` is `freeVerb`.**  The MIR intrinsics
`free_object`/`give_object`/`copy_object` map to
`freeVerb`/`giveVerb`/`copyVerb` in `containers.zig`.  The `Verb`
suffix is a fine disambiguator and is used consistently across all
three — but it is the third spelling of one operation (Luce's `free`,
MIR's `free_object`, the runtime's `freeVerb`), and nothing in the
tree says so.

**D. `listOfText` and `namesList` build the same thing.**  Both return
a fresh `List(String)`; they differ only in the shape of their input
(a slice of slices, versus one NUL-joined buffer).  The names put the
same two nouns in opposite orders.  `listOfText` / `listOfJoinedText`
would read as the pair they are.

**E. Six spellings of "this program must be rejected."**
`expectFails` (compile/test), `expectDiagnostics` (03_parse/test and
compile/test), `expectOwnError` (ownership_spec), `expectError`
(errors_spec), `expectProblem` (01_source/encoding), `expectComplaint`
(site/verify), `expectRefused` (loom/shell).  Each is file-private, so
nothing is ambiguous at a call site — but a contributor writing the
eighth test helper has no precedent to copy.

**The week's new vocabulary is coherent with the old.**
`ownStorage`/`exportStorage`/`dropStorage` obey the create/derive/end
shape; `sanitizeStep`/`appendSanitized`/`writeSanitized` are one
predicate and two sinks over one adjective, which is the right shape;
`keepText`/`fittingLength` and `fileIn`/`runnableIn` are local pairs
with a matching suffix; `agreeOk`/`agreeTrap`/`agreeClean`/`agreeGiven`
share a prefix and read as a family.  No finding here.

## 3. Doc quality on the load-bearing seams

| Seam | Verdict |
| --- | --- |
| `08_llvm/abi.zig` | **Exemplary.** 755 lines, every version bump reasoned in place, every field's optionality and fail-closed behaviour stated. |
| `runtime/heap.zig` | **Exemplary.** Ownership stated at every entry point; 41/47 public functions documented. |
| `specs/agree.zig` | **Header exemplary, accessors bare.** |
| `apps/native.zig` | **Good.** The discovery contract is stated at file level and `fileIn` names its owner; `runnableIn` has no doc. |
| The three storage intrinsics | **Good.** All three carry contracts naming what copies and what passes through. |
| `runtime/exports.zig` | **Header exemplary, 40 of 66 ABI symbols undocumented.** |

What good looks like here — `heap.releaseStorage`, which states the
invariant that makes double-release safe rather than narrating the
switch below it:

> `/// Safe on anything that owns nothing, which is what makes a`
> `/// released slot safe to release again: every release writes the`
> `/// emptied value back, and an empty value frees nothing.`

And `native.fileIn`, one clause that answers the only question a caller
has:

> `/// The path of `name` inside `directory` when it is really there, or`
> `/// an empty string.  The caller owns a non-empty answer.`

**The gap in `exports.zig`.**  The file uses dashed section headers
with prose contracts covering a group instead of per-symbol `///`,
which is a legitimate and legible style — but only one of seven
sections actually carries the prose.  "Struct values" states
consumption and ownership for both symbols under it.  "Objects and
ownership", "Containers" and "Strings and conversions" are bare
headers, and beneath the first of them sit `luce_rt_bind`,
`luce_rt_unbind`, `luce_rt_loosen_from_frame`, `luce_rt_free`,
`luce_rt_give` and `luce_rt_copy` — the ownership ABI — with no
contract anywhere.  `luce_rt_free`'s signature is
`(runtime, held, owned: i32, serial: u64, local: u32) -> i32`; nothing
in the file says what `owned` selects, what `serial`/`local` identify,
or that a mismatch is the `not_owned` trap.

**The gap in `agree.zig`.**  `Capture.printed`, `trapMessage`,
`trapTrace`, `errorMessage` and `errorOrigin` each return `[]const u8`
into a fixed buffer that the next run overwrites, and none of the five
has a doc comment.  That is exactly the "what invalidates this borrow"
case the guide names, in the file whose own header explains at length
why those buffers are fixed.

**Narration is not a problem.**  Of 692 functions carrying a `///`
block, a scan for docs that merely restate every word of the name
turned up 30 candidates, of which nearly all add a real fact
(`"Text borrows from \`bytes\`"`, `"caller-owned bytes"`,
`"interned by content"`, `"or -1"`, `"(S22)"`).  Perhaps four are true
narration (`openBlock`, `elseArm`, `dead`).  Nothing to act on.

## 4. Ownership-comment coverage

Every public function returning a slice or a pointer:

| | count |
| --- | --- |
| Total | 52 |
| Carrying any `///` | 31 (60 %) |
| Whose `///` speaks to lifetime, ownership or invalidation | **20 (38 %)** |

By file, the ones that fall short:

| File | total | doc'd | states lifetime |
| --- | --- | --- | --- |
| `specs/agree.zig` | 10 | 5 | **1** |
| `03_parse/expressions.zig` | 3 | 0 | 0 |
| `06_mir/defs.zig` | 3 | 0 | 0 |
| `04_semantics/declarations.zig` | 3 | 2 | 0 |
| `04_semantics/helpers.zig` | 2 | 0 | 0 |
| `01_source/sources.zig` | 4 | 4 | **4** |
| `runtime/heap.zig` | 2 | 2 | **2** |

Judged honestly: many of the silent ones return static strings
(`TrapCode.message`, `ErrorCode.message`, `FileAct.verb`,
`palette.sgr`, `runtime_effects.symbol`), where the answer is one
clause — "a static string" — not a paragraph.  The ones that genuinely
matter are `value.asStruct` (returns `[]Value` — a *mutable* alias into
a struct run, undocumented), `positions.slice`, and the five
`agree.Capture` accessors above.

## 5. What Zig, Rust and Go actually do

- **Zig std** is terse and ownership-explicit: `allocPrint`'s doc is
  one line naming who frees. It does *not* document every public
  symbol; large files (`x86_64/CodeGen.zig`, 190k lines) rely on
  dashed section headers to navigate. This tree already documents more
  than Zig std does — and uses fewer section headers in its largest
  files, which is the wrong way round.
- **Rust** requires a sentence per public item by lint
  (`missing_docs`), with structured `# Errors` / `# Panics` /
  `# Safety` sections. This tree will not adopt rustdoc markup, but
  the *discipline* — every public item answers what, who owns, and how
  it fails — is worth stating as a rule.
- **Go** requires one sentence per exported symbol, beginning with the
  symbol's name, enforced by `golint`. Its package docs are one
  paragraph, not an essay. This tree's `//!` blocks are far longer than
  Go's and better for it; its per-symbol coverage is lower.

**Concrete recommendation, one paragraph for `docs/CODING_GUIDE.md`:**

> Every published symbol answers three questions: **what** it does,
> **who owns** what it returns or is given, and **how it fails**.  A
> symbol whose answers are all obvious needs one clause; a symbol on a
> published boundary — a `luce_rt_*` export, an `abi.Host` field, a
> function returning a borrow — needs all three, in writing.  A dashed
> section header may carry the answer for a group, but then it must
> actually carry it: a bare header over undocumented exports documents
> nothing.

## 6. One-word names and collisions

Thirty-two type names are declared more than once in the tree.  Most
are the AST/MIR twins — `Binary`, `Unary`, `Call`, `Block`, `Program`,
`BinaryOp`, `UnaryOp`, `Conditional` — always reached as `ast.Binary`
against `mir.Binary`, which is the same concept at two stages and is
exactly how Zig's own `Zir.Inst` / `Air.Inst` read.  No finding.

The ones judged:

- **`Host` × 3** — `abi.Host` (the C vtable), `interpreter.Host` (the
  oracle's Zig vtable), `apps.host.Host` (the concrete implementation).
  Same concept at three altitudes, and **documented as such**:
  `interpreter.Host`'s doc names `abi.Host` explicitly. Correct as it
  stands. (Their *field* names are finding A.)
- **`Value` × 2** — `runtime.Value` is the runtime's tagged value;
  `04_semantics/builder.zig`'s private `Value` is `{ register,
  value_type }`, a typed register. **A genuine mislead** in a
  4,677-line file. `Typed` or `TypedRegister` says what it is.
- **`FunctionInfo` × 2** — `trace.FunctionInfo` is the extern ABI row a
  compiled artifact publishes about itself; `04_semantics/declarations
  .zig`'s is the analyzer's collected declaration. Both `pub`, the
  second undocumented. **Rename the analyzer's** to `FunctionDeclInfo`,
  matching its own neighbour `StructDeclInfo` two declarations below.
- **`Frame` × 4, `Origin` × 3, `Result` × 5, `Status` × 2** — all
  either module-private or genuine per-module concepts reached through
  a namespace. No finding.

Entry points and core types read well: `Runtime`, `Lowering`, `Module`,
`Body`, `Machine`, `Capture`, `Reference`, `Session` each say what they
are, and `05_hir.zig`'s empty-but-honest barrel and `luce.zig`'s
numbered-prefix-dropping re-exports are model work.

## 7. Ranked findings

| # | Finding | Fix | Size | What happened |
| --- | --- | --- | --- | --- |
| 1 | `interpreter.Host` / `Terminal` — 23 camelCase fields, word order and vocabulary diverging from `abi.Host` | Rename every field to the `abi.Host` spelling: `printFn`→`print`, `readFileFn`→`file_read`, `listDirectoryFn`→`dir_list`, `clockFn`→`clock_ms`, `Terminal.rowsFn`→`term_rows`, … Drop the `Fn` suffix (the type already says it). Only three files touch these: the declaration (`interpreter.zig`), the reads (`interpreter/machine.zig`, 23 sites) and the one construction site (`specs/agree.zig`, `Reference.host()`). Mechanical, compiler-checked. | **~1 h** | **Fixed**, `d0e2508` |
| 2 | Four largest engine files have 0–3 dashed section headers | `04_semantics/builder.zig` (4,677 lines, 1 header at line 44), `08_llvm/lower.zig` (4,672, last header at 1,294 — 3,378 unmarked lines), `apps/host.zig` (1,835, one header, and it says "Tests"), `04_semantics/declarations.zig` (1,410, none), `03_parse/grammar.zig` (1,341, none), `interpreter/machine.zig` (1,003, none). Add headers at the natural seams. The tree's own spec files average one per 58 lines; aim for one per ~150 in engine code. **Headers, not splits** — the guide is explicit that length is not a split signal. | **~3 h** | **Fixed**, `87b37cf` |
| 3 | 40 of 66 `luce_rt_*` ABI symbols carry no contract | Either a `///` per symbol or prose under each of the four bare section headers, on the model of "Struct values" which already does it right. The ownership six (`bind` `unbind` `loosen_from_frame` `free` `give` `copy`) need it most: `owned`/`serial`/`local` are undocumented today. | **~2 h** | **Fixed**, `3b16407` |
| 4 | `agree.Capture`'s five accessors return borrows into buffers the next run overwrites, undocumented | One shared `///` above the group naming the invalidation. | **~15 min** | **Fixed**, `3b16407` |
| 5 | `drop_storage` → `releaseStorage`; one act, two verbs | Rename `Runtime.releaseStorage` → `Runtime.dropStorage`, matching the intrinsic and the export. (Or move the intrinsic to `release_storage` — but the intrinsic name is in `format_version`, so renaming the Zig method is the cheap direction.) `releaseSlots`/`releaseFrameStorage` are a different act and keep their word. | **~30 min** | **Fixed**, `685d8f9` |
| 6 | `builder.Value` (a typed register) shadows `runtime.Value` conceptually | Rename to `Typed`. Private to one file. | **~10 min** | **Fixed**, `685d8f9` — `Typed` |
| 7 | `declarations.FunctionInfo` collides with the ABI's `trace.FunctionInfo` | Rename to `FunctionDeclInfo` beside its existing `StructDeclInfo`, and give it a `///`. | **~20 min** | **Fixed**, `685d8f9` |
| 8 | `listOfText` / `namesList` are the same product under mirrored names | Rename `namesList` → `listOfJoinedText`. | **~10 min** | **Fixed**, `685d8f9` |
| 9 | `08_llvm/emit.zig`'s entry point is `compile`, a fourth stage's word, in a file whose name is a third sense of `emit` | Rename `emit.compile` → `emit.object` (it returns a relocatable object). | **~15 min** | Open |
| 10 | Six file-private spellings of "expect a rejection" | Standardise on `expectRejected` where the file has no reason to differ. Cosmetic; no ambiguity exists today. | **~30 min** | **Fixed**, `685d8f9` — `expectRejected` |
| 11 | The `lower` / `emit` rule is real but nowhere written | One sentence in `docs/CODING_GUIDE.md`'s Naming section: *`lower` walks a structure into the next representation; `emit` appends code for one thing.* | **~5 min** | Open |
| 12 | 20 of 52 borrow-returning public functions state a lifetime | Add one clause to the rest. Static-string returners need only "a static string"; `value.asStruct` needs the real answer (it hands out a mutable alias). | **~1 h** | **Fixed**, `3b16407` |

Findings 1–3 are the ones that change how the tree reads.  The rest are
half a day together.

## What happened next

Worked at `f333e12` (merge of `org-naming`), ten commits, `zig build
test` 944/944 throughout, `bench/compare.sh f333e12` every row within
±2%.  Eleven of the twelve are done; the notes are where the code had
something to say back.

* **1, the host tables.**  One rule, stated at the top of
  `interpreter.Host`: every slot is named for the Luce builtin it
  stands behind, spelled exactly as `LuceHost` spells it, no `Fn`
  suffix.  `Terminal` keeps the `term_` prefix — `abi.Host` is one flat
  table, and the two lining up row for row is the point, so
  `terminal.term_write` and `abi.Host.term_write` are the same row.
  `01_source`'s `Loader.loadFn`, the 24th violation, is `load`; the
  tree has no camelCase field left.
* **3, the ABI contracts.**  Written as section prose, on the model of
  "Struct values", because that is the style the file chose and it is a
  good one for a table of similar things.  The ownership six got the
  most: `(owned, serial, local)` is named as the one idea it is — the
  frame, the binding, and whether the caller is claiming to *be* that
  binding — and each of `bind`, `unbind`, `loosen_from_frame`, `free`,
  `give` and `copy` gets a line saying what it does to an owner.  The
  file header gained the two rules a caller most needs: a
  `*const Value` argument is a borrow unless it says otherwise, and an
  `out` is written only on success.
* **5, `drop_storage`.**  `Runtime.releaseStorage` is `dropStorage`, as
  the audit's cheap direction says; the intrinsic's name is in
  `format_version` and did not move.
* **9, `emit.compile`.**  Open — outside the brief this pass was given.
* **10, the rejection helpers.**  All six are `expectRejected`, no
  shared helper: the assertions genuinely differ, and only the name
  needed settling.  **Dissent on the seventh:** `expectDiagnostics` is
  not one of them.  It asserts an exhaustive list of diagnostics with
  their positions, which is a different claim from "this was rejected",
  and it already has one name across the two files that use it.
* **11, the `lower`/`emit` sentence.**  Open — the guide took the two
  paragraphs findings 3 and STRUCTURE 6 asked for, and this one was
  outside the brief.
* **12, the borrow-returners.**  `value.asStruct` was the one that
  mattered and it is documented as what it is: a *mutable alias* into
  the field run, which is why `setField` builds a new run rather than
  storing in place.  `agree.Capture`'s five share one comment naming
  the invalidation.  The static-string returners took the one clause
  that is their whole answer.
* **One thing the audit called and the code confirmed harder than
  stated.**  `freeVerb`'s suffix is fine and is used consistently, as
  the audit says — but nothing in the tree said that one operation is
  spelled three times on its way down (Luce's `free`, MIR's
  `free_object`, the runtime's `freeVerb`).  A note above the three
  verbs says it now; no rename.
