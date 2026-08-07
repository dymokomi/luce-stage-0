# The documents

One line each, and one thing you cannot tell from a directory listing:
**whether a file is current or frozen.**  A decision record is written
in the present tense about the world it was written in, and it stays
that way on purpose — the measurements are the record.  A reference
describes the tree as it is now and is wrong the moment it drifts.

Start with [V2.md](V2.md) for what the project is for, then
[LANGUAGE.md](LANGUAGE.md) for the language and
[PIPELINE.md](PIPELINE.md) for the compiler.  If you are about to
write code, [CODING_GUIDE.md](CODING_GUIDE.md) is not optional.  If
you want to know what is *not* here, [MISSING.md](MISSING.md).

The prose that faces users lives on the documentation site instead —
**[luce.luciaos.com](https://luce.luciaos.com)**, built from
[`site/`](../site/) in this repository, where every Luce sample is
compiled and run by the freshly built toolchain and a wrong claim
fails the build.  These files are the reasoning behind it.

## Current — describes the tree as it is

| File | What it is |
|---|---|
| [V2.md](V2.md) | The north star: what v2 is for, what it is made of, and the order the work goes in. Read first. |
| [LANGUAGE.md](LANGUAGE.md) | The language specification: types, values, statements, expressions, the entry point. |
| [OWNERSHIP.md](OWNERSHIP.md) | Scope ownership as 43 ratified situations, S1–S43. The compiler's diagnostics quote these by number. |
| [PIPELINE.md](PIPELINE.md) | The status table: one row per compiler stage, what it does, and how finished it is. |
| [CODEGEN.md](CODEGEN.md) | The LLVM backend, the published host ABI, and the benchmark snapshot. The one place a benchmark ratio is written down. |
| [MODES.md](MODES.md) | Debug and release, which differ in exactly one thing: what a trap can tell you. |
| [FAILURE.md](FAILURE.md) | The rule that decides trap versus error versus `T?`, and the `T!`/`try`/`catch` design it produced. |
| [STD.md](STD.md) | The standard library, module by module, and what it takes to add one. |
| [CODING_GUIDE.md](CODING_GUIDE.md) | How Zig is written here. Authoritative and intentionally opinionated. |
| [MISSING.md](MISSING.md) | The honest gap list, re-derived against the tree rather than carried forward. The closest thing to a work queue. |

## Decision records — frozen, and true of when they were written

Each of these argues its way to a decision and keeps the measurements
as taken.  Where one disagrees with a file above, the file above wins,
and each says so in its own preamble.

| File | The decision |
|---|---|
| [ENGINE.md](ENGINE.md) | Why there is one engine. Written before the nine steps that retired the interpreter; its seven "Hat" sections describe the world it measured, not this one. |
| [MEMORY.md](MEMORY.md) | Why scope ownership won over reference counting, tracing GC, arenas and borrow checking. |
| [TYPES.md](TYPES.md) | The seven-number ladder: Java sizing, lowercase names, `byte` as bits, storage-only narrow types. D1–D8 ratified and built. |
| [NUMERICS.md](NUMERICS.md) | Promotion, true division, the floor pair, `int(x)`-style conversions. Ratified and built. |
| [METHODS.md](METHODS.md) | `main(args)`, `self`, `var self` as copy-in/copy-out. Ratified and built. |
| [RETURNS.md](RETURNS.md) | Multiple returns without first-class tuples. Ratified and built. |
| [ARGS.md](ARGS.md) | Named and default arguments: names optional everywhere, defaults as trailing folded constants, struct fields on the same clause, nothing below stage 4 moving. D1–D12 ratified and built. |
| [VECTOR.md](VECTOR.md) | Vectorizing checked reductions without weakening a single trap: prove, or speculate-and-replay. All three layers ratified. |
| [STRINGS.md](STRINGS.md) | Why string bytes have an owner, phase by phase, with the timing after each step. |
| [VISIBILITY.md](VISIBILITY.md) | Public until it says `private`: the file as the trust unit, `private:`/`public:` regions in structs, visibility dying in stage 4. Ratified and built. |
| [BITWISE.md](BITWISE.md) | `& \| ^ ~ << >>` at Go's precedence, shifts as checked bit transport, hex/binary/underscore literals. R1–R3 ratified and built. |
| [ENUMS.md](ENUMS.md) | A name for every number that is secretly a set: C-shaped member values, a chosen backing width, `Method(n) -> Method?`, and the `match` that refuses to compile with a member unaccounted for. R1–R3 ratified and built. |
| [CONCURRENCY_RESEARCH.md](CONCURRENCY_RESEARCH.md) | **Not a decision.** The survey behind one not yet taken: nine concurrency models, cited, priced against S8, the no-collector rule and the differential oracle — and the questions the ruling turns on. |

## History

[v1/](v1/) preserves the Fabric era — Texels, Fibers, capabilities,
the C ABI — alongside the `main-v1` branch.  Nothing there describes
this tree, and nothing here builds toward it.

## Audits

[audit/](audit/) holds point-in-time reviews of the repository against
itself: [DOCS.md](audit/DOCS.md) checked every prose claim in both
directions, [STRUCTURE.md](audit/STRUCTURE.md) the seams,
[NAMING.md](audit/NAMING.md) the names and the in-code documentation.
They are dated to the commit they were taken at and are not
maintained; what they found is fixed in the files above.
