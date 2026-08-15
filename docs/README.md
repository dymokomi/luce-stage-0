# The documents

One line each, and one thing you cannot tell from a directory listing:
**whether a file is current or frozen.**  A decision record is written
in the present tense about the world it was written in, and it stays
that way on purpose — the measurements are the record.  A reference
describes the tree as it is now and is wrong the moment it drifts.

**The split below is not editorial.**  It is
[`tools/documents.zig`](../tools/documents.zig), which both guards
read, and it decides something mechanical: a **living** document's Luce
must compile as written, with no exemptions, so a reader is entitled to
paste any of it into a file; a **decision record** may show the
language of its day and says so with a ```` ```luce historical ````
fence.  A memo that needs that fence cannot be listed as current, which
is why [V2.md](V2.md) and [FAILURE.md](FAILURE.md) are records however
current their content is.  The two tables and those two arrays are
pinned to each other by a test — a document in one and not the other
fails `zig build test`.

Start with [V2.md](V2.md) for what the project is for, then
[LANGUAGE.md](LANGUAGE.md) for the language and
[PIPELINE.md](PIPELINE.md) for the compiler.  If you are about to
write code, [CODING_GUIDE.md](CODING_GUIDE.md) is not optional.  For
confirmed incorrect behavior, see [MISSING.md](MISSING.md); proposed
features and deliberate omissions stay in their decision records.

The prose that faces users lives on the documentation site instead —
**[luce.luciaos.com](https://luce.luciaos.com)**, built from
[`www/luce/`](../www/luce/) in this repository, where every Luce sample is
checked by the freshly built toolchain.  Runnable samples execute and
their claimed output is compared byte for byte; expected traps, raises
and refusals are checked as such.  Broken samples and mismatched claimed
results fail the build, as do dead links and anchors and selected
compiler-to-reference vocabulary gaps.  The surrounding prose remains
human-reviewed.  These files are the reasoning behind it.

## Current — describes the tree as it is

| File | What it is |
|---|---|
| [LANGUAGE.md](LANGUAGE.md) | The language specification: types, values, statements, expressions, the entry point. |
| [MEMORY.md](MEMORY.md) | The memory model: value `struct`s and reference `class`es, ARC, and `weak` for cycles. Memory you never think about. |
| [ROADMAP.md](ROADMAP.md) | The sequenced plan for the value/reference + ARC pivot: the phases, the big-bang cut, and what "done" looks like. |
| [PIPELINE.md](PIPELINE.md) | The status table: one row per compiler stage, what it does, and how finished it is. |
| [CODEGEN.md](CODEGEN.md) | The LLVM backend, the published host ABI, and the benchmark snapshot. The one place a benchmark ratio is written down. |
| [MODES.md](MODES.md) | Debug and release, which differ in exactly one thing: what a trap can tell you. |
| [ENGINE.md](ENGINE.md) | Why there is one engine, and what the interpreter is now: the differential oracle every spec's second arm runs on. |
| [STD.md](STD.md) | The standard library, module by module, and what it takes to add one. |
| [CODING_GUIDE.md](CODING_GUIDE.md) | How Zig is written here. Authoritative and intentionally opinionated. |
| [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md) | How to decide what a module is, what it hides, and what it is called — deep modules, information hiding, and the red flags that say an abstraction is not paying for itself. The guide above wins on anything it covers. |
| [INTERFACES.md](INTERFACES.md) | The nominal interface contract: explicit conformance, effect matching, heterogeneous collections, and dispatch to mutating methods. |
| [MISSING.md](MISSING.md) | Confirmed bugs only. Feature requests, design questions, coverage campaigns, refactors, optimizations, and deliberate non-goals do not belong here. |
| [UX_UI_DESIGN.md](UX_UI_DESIGN.md) | How design and coding agents design, implement, and review user experiences: an operational synthesis of Apple's Human Interface Guidelines into software obligations. |
| [TERMUI_EDITOR_REWRITE.md](TERMUI_EDITOR_REWRITE.md) | The plan of record for the clean termui rewrite and the modular editor that adds undo/redo, in-file search, and crash-safe drafts. |

Where a bug **closes**, its entry leaves MISSING.md, so the bug list
contains only current incorrect behavior rather than history.

## Decision records — frozen, and true of when they were written

Each of these argues its way to a decision and keeps the measurements
as taken.  Where one disagrees with a file above, the file above wins,
and each says so in its own preamble.

| File | The decision |
|---|---|
| [V2.md](V2.md) | The north star: what v2 is for, what it is made of, and the order the work goes in. Read first. |
| [TYPES.md](TYPES.md) | The seven-number ladder: Java sizing, lowercase names, `byte` as bits, storage-only narrow types. D1–D8 ratified and built. |
| [NUMERICS.md](NUMERICS.md) | Promotion, true division, the floor pair, `int(x)`-style conversions. Ratified and built. |
| [METHODS.md](METHODS.md) | `main(args)` and the original explicit-receiver design. The entry half shipped; the receiver half was superseded by SELF before lock. |
| [RETURNS.md](RETURNS.md) | Multiple returns without first-class tuples. Ratified and built. |
| [ARGS.md](ARGS.md) | Named and default arguments: names optional everywhere, defaults as trailing folded constants, struct fields on the same clause, nothing below stage 4 moving. D1–D12 ratified and built. |
| [VECTOR.md](VECTOR.md) | Vectorizing checked reductions without weakening a single trap: prove, or speculate-and-replay. All three layers ratified. |
| [STRINGS.md](STRINGS.md) | Why string bytes have an owner, phase by phase, with the timing after each step. |
| [VISIBILITY.md](VISIBILITY.md) | Public until it says `private`: the file as the trust unit, `private:`/`public:` regions in structs, visibility dying in stage 4. Ratified and built. |
| [FAILURE.md](FAILURE.md) | The rule that decides trap versus error versus `T?`, and the `T!`/`try`/`catch` design it produced. Ratified and built. |
| [BITWISE.md](BITWISE.md) | `& \| ^ ~ << >>` at Go's precedence, shifts as checked bit transport, hex/binary/underscore literals. R1–R3 ratified and built. |
| [ENUMS.md](ENUMS.md) | A name for every number that is secretly a set: C-shaped member values, a chosen backing width, `Method(n) -> Method?`, and the `match` that refuses to compile with a member unaccounted for. R1–R3 ratified and built. |
| [BYTES.md](BYTES.md) | The binary half of the host boundary: why a `string` cannot carry a JPEG, the C-shaped byte primitive, and a file handle as a reference-counted resource. Ratified and built. |
| [UNION.md](UNION.md) | One of these, and the language always knows which: members carrying named payload fields, `match` with alias bindings as the only door, and a value that is a struct-shaped run the runtime never learns exists. Eighteen decisions and three held recommendations, ratified and built; the two departures are recorded in "As built". |
| [THREADS.md](THREADS.md) | Workers own their world: `spawn f(x)` onto a second runtime, `task(T)` as a reference-counted resource whose last release joins, races unrepresentable because a reference never crosses a worker boundary. Ratified and built. |
| [FUNCTIONS.md](FUNCTIONS.md) | Functions as values, divided at the capture line: named functions and one-expression lambdas whose types come from where they land — and no closures, because state that travels with behavior is a struct with a method. Ratified and built, including stable `std.lists.sort_by` as D6's proving customer. |
| [PACKAGES.md](PACKAGES.md) | The consuming half of packages: `luce.yaml` roots (a strict YAML subset) and exact-version wants, dotted imports with `as`, probe-every-tier resolution that refuses ambiguity instead of ordering it, the `.luce/` store and compile cache, and the four seam changes package isolation costs the loader. Ratified and built, five steps with as-built notes; authoring, publishing and fetch are deliberately the next memo's. |
| [BINDING.md](BINDING.md) | **Built, D8 outstanding.** Bound methods — the method travels with its struct: `receiver.method` as a function value whose environment is the receiver, value receivers copied at the bind, carrying receivers **borrowing** it (the owning bind refused, so a function value never owns the objects inside it), `(func(...) -> R)?` as the storable form, union constructors as function values, and anonymous captures refused permanently. Closures with a nominal environment and no new ownership rule. |
| [FILESYSTEM.md](FILESYSTEM.md) | **Partly built.** The filesystem surface: `paths` is the name and `files` is the world, because asking is touching; no `Path` value type; and `files.kind(p) -> Kind?!` as the one question, answering absence and refusal separately, subsuming `exists`, with listings that carry kinds. Built through step 4; `open()`, `FileMode` and the file-surface methods are the named remainder. |
| [TESTING.md](TESTING.md) | **Built.** `luce test`: `func test_*()` in `tests/`, discovered by name and refused-not-skipped when malformed, run one `luce_main` call per test through a synthesized entry in a blessed shape — the CLI drives, so a trap fails the test and never the run. |
| [TERMUI.md](TERMUI.md) | **Built.** The terminal-UI package: one renderer owns the screen and event stream, views measure and draw through a small interface, layout is total rectangle arithmetic, and the editor is its end-to-end customer. |
| [SELF.md](SELF.md) | Self implied, `static` for the functions without one, and a call site that cannot lie: `f(x)` never mutates a value, `x.advance(8)` may — and reads like it. `var self` and `var` parameters retired. Ratified and built. |
| [CONSTANTS.md](CONSTANTS.md) | Constant containers: file-scope `const`, the program root, `{k: v}` maps, flat lists and rank-1 arrays, and the static line with one runtime trap behind it. Ratified and built; the EOF appendix records where the implementation superseded the proposal prose. |
| [GENERICS.md](GENERICS.md) | **Proposal, direction ratified, not built.** Parametric generics: monomorphization, interface bounds, `[T]` syntax — and the honest note that a declarative UI framework needs generics only to hide the last loop. |
