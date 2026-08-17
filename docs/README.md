# The documents

The documents have three jobs, and the distinction is enforced by
[`tools/documents.zig`](../tools/documents.zig):

- **Current reference** describes the repository and language that exist now.
  Every Luce fence compiles, refused examples must remain refused, and prose
  and code use the same builtin type vocabulary.
- **Plans** describe the language we intend to build. Syntax the compiler does
  not yet accept is written as `text`, never as a pasteable Luce example.
- **Decision records** preserve a ratified boundary when its history remains
  useful. Only these may use `luce historical` fences.

This separation is an honesty boundary. A feature that merely parses is not a
working language feature, a planned type name is not a current spelling, and
a proposed implementation is not the language reference. Superseded
pre-release designs that never established a useful boundary are deleted
rather than kept as product history.

Start with [V2.md](V2.md) for the product north star and
[ROADMAP.md](ROADMAP.md) for the dated state audit and ordered path to 1.0.
Use [LANGUAGE.md](LANGUAGE.md) and the current pages below when working on the
compiler. Confirmed incorrect behavior belongs in [MISSING.md](MISSING.md),
and completed repairs move to the compact [RESOLVED.md](RESOLVED.md) record.

User-facing documentation lives at
[luce.luciaos.com](https://luce.luciaos.com), built from
[`www/luce/`](../www/luce/). Its Guide and Library describe the released
toolchain; its Status page is the public boundary between current and planned
work. Every Luce sample, claimed output, expected refusal, link, anchor, and
selected surface roster is checked during the site build.

## Current reference

| File | Purpose |
|---|---|
| [LANGUAGE.md](LANGUAGE.md) | The complete current language specification. |
| [MEMORY.md](MEMORY.md) | The current value/reference contract, ARC lifetime rules, worker snapshots, and cycle boundary. |
| [STD.md](STD.md) | Every embedded standard module and the cost of adding one. |
| [CODEGEN.md](CODEGEN.md) | LLVM lowering, the published host ABI, artifacts, and measured backend behavior. |
| [MISSING.md](MISSING.md) | Confirmed bugs only; plans and feature requests do not belong here. |
| [ENGINE.md](ENGINE.md) | The single shipping engine and the differential interpreter oracle. |
| [MODES.md](MODES.md) | Debug and release behavior. |
| [PIPELINE.md](PIPELINE.md) | The compiler stages and their current completion state. |
| [CODING_GUIDE.md](CODING_GUIDE.md) | The repository's authoritative Zig style and testing rules. |
| [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md) | Deep modules, information hiding, naming, and complexity control. |
| [INTERFACES.md](INTERFACES.md) | Current nominal interfaces, struct/class conformance, owned existential storage, mutation, and deliberate non-goals. |
| [CLASSES.md](CLASSES.md) | Final ARC classes, identity, mutation, weak edges, interfaces, and deterministic `deinit`. |
| [UX_UI_DESIGN.md](UX_UI_DESIGN.md) | Operational product and interface-design guidance. |
| [RETURNS.md](RETURNS.md) | Multiple returns without tuple values. |
| [NUMERICS.md](NUMERICS.md) | Current explicit-width arithmetic, division, conversion, and overflow semantics. |
| [STRINGS.md](STRINGS.md) | Current UTF-8 text representation and lifetime behavior. |
| [FAILURE.md](FAILURE.md) | Absence, recoverable errors, traps, `try`, and `catch`. |
| [TYPES.md](TYPES.md) | Current builtin types and type grammar. |
| [ALIASES.md](ALIASES.md) | Transparent type aliases, visibility, construction, diagnostics, and compiler erasure. |
| [ARGS.md](ARGS.md) | Named and default arguments. |
| [VISIBILITY.md](VISIBILITY.md) | Public-by-default declarations and file-scoped privacy. |
| [BITWISE.md](BITWISE.md) | Integer bit operations and literals. |
| [ENUMS.md](ENUMS.md) | Enumerations, backing widths, conversions, and exhaustive matching. |
| [BYTES.md](BYTES.md) | Current byte storage and binary file APIs. |
| [UNION.md](UNION.md) | Tagged unions and payload matching. |
| [THREADS.md](THREADS.md) | Isolated workers and reference-counted task resources. |
| [FUNCTIONS.md](FUNCTIONS.md) | Named functions, expression lambdas, ARC closures, captures, storage, and calls. |
| [PACKAGES.md](PACKAGES.md) | The package consumer and manifest surface that exists today. |
| [TESTING.md](TESTING.md) | Luce tests, engineering lanes, progress output, and the release gate. |
| [BINDING.md](BINDING.md) | Current bound-method representation and lifetime rules. |
| [FILESYSTEM.md](FILESYSTEM.md) | The partly built filesystem surface, with the boundary stated explicitly. |
| [TERMUI.md](TERMUI.md) | The current declarative terminal application package. |
| [SELF.md](SELF.md) | Implied receivers, static members, and value-writer calls. |
| [CONSTANTS.md](CONSTANTS.md) | File-scope constants and immutable program-root containers. |

## Plans

| File | What it decides |
|---|---|
| [V2.md](V2.md) | The language-first product north star, current userland proof, and intentionally deferred systems work. |
| [ROADMAP.md](ROADMAP.md) | The dated state-of-language audit and ordered path through generics, native UI, platform work, and the 1.0 lock. |
| [GENERICS.md](GENERICS.md) | The proposed monomorphized generics design, its real library customers, diagnostics, limits, and acceptance matrix. |
| [VECTOR.md](VECTOR.md) | A future optimization plan for checked vectorized reductions; not current language behavior. |

## Decision records

| File | Boundary preserved |
|---|---|
| [RESOLVED.md](RESOLVED.md) | Confirmed bugs after their repair and proof land. |
