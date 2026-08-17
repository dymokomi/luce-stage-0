//! Stage 4 — semantics: name resolution, type checking, and validation.
//!
//! Consumes: the untyped `ast.Program` of every module in the import
//! graph, plus the compile options (the host gate).
//! Produces: an `Analyzed` — struct layouts, heap-type shapes, the
//! constant pool, the entry, and one function's worth of decided
//! operations per declaration — or `luce.sema.*` diagnostics and
//! nothing at all.
//!
//! **The three concerns are one subsystem by design, not by neglect.**
//! Resolution, typing, and validation are mutually recursive in any
//! real compiler: resolving `xs.append(v)` needs the receiver's type,
//! and typing it needs the name resolved first.  Three sibling stage
//! folders would advertise an independence that does not exist and
//! could not be built, so they live here together and are named
//! internally instead.  The seam this stage *does* have is a different
//! one, and it is real: checking ends here and emission begins at
//! stage 5 (`hir/`).
//!
//! **Where this stage stops.**  It decides *what* the program does and
//! records each decision as it is reached — onto `hir`'s typed
//! tree, and **onto nothing else: nothing here emits an
//! instruction**.  Stage 5 lowers that tree, and how MIR is then made
//! — register numbering, block bookkeeping, the local table, the
//! constant pool, sealing, debug origins, the assembly of a
//! `mir.Program` — is `mir/build.zig`'s.  Recording cannot be
//! *deferred*: it happens in the same visit as the check that decides
//! it, because the check is what decides it.  What crosses each seam
//! is a plain value with no path back into the checker, which is why
//! the later stages can close long after this one has finished.
//!
//! Rules enforced here, per docs/LANGUAGE.md: static types with no
//! implicit numeric conversion, immutable `let` and parameters, no
//! shadowing, definite initialization, `return` on every path, and
//! struct cycles refused.  Nothing about any backend appears here.
//!
//! **This stage is the last word on the memory model.**  The MIR
//! verifier checks structure and types, not meaning, so `let`
//! immutability, reference stores, worker sendability, `fill` on an
//! array of objects, and the host gate are all checked here and nowhere
//! else.  That is deliberate — a `.lc` is an executable and is trusted
//! like one (docs/PIPELINE.md) — but it means a change here is a change
//! to what the language guarantees. Behavioral proofs live in the
//! differential specs and refusals in `specs/errors_spec.zig`.
//!
//! **Bounds.**  Reporting is capped at `max_diagnostics`, and the
//! expression walk is bounded at `helpers.max_expression_depth`.
//! Stage 3 bounds recursive *descent*, which a left-leaning chain
//! never exercises — `1 + 1 + ... + 1` parses in a Pratt loop and
//! yields a tree as deep as the chain is long, as does an f-string
//! with enough holes — so this stage needs a bound of its own.  Struct
//! layouts are bounded too (`helpers.max_struct_values`): nesting
//! multiplies, and a struct that flattens to a million values would
//! cost a million instructions to zero.
//!
//! Flat pieces beside this file:
//!
//!   context.zig      — the vocabulary both passes speak: collected
//!                      declarations, folded constants, and the scope,
//!                      local and loop state a body is checked against.
//!   declarations.zig — pass one: collect struct layouts, function
//!                      signatures, top-level constants, and the
//!                      selected entry; then drive pass two.  The
//!                      `Analyzer` and its tables live here; each
//!                      concern that can be named on its own is a
//!                      file beside it, holding free functions over
//!                      `*Analyzer`:
//!   naming.zig       — what a declaration is called, where it was
//!                      written, and who may see it.
//!   resolve.zig      — a written type name to a `Type`, and the
//!                      interning behind the shapes it mints.
//!   shapes.zig       — what a type carries, how wide it is, and the
//!                      one graph walk that settles both.
//!   layouts.zig      — the declared type tables: enums, unions and
//!                      structs, names first and contents after.
//!   signatures.zig   — the function table: every signature, the
//!                      lambda and the specialization the compiler
//!                      adds to it, and the layout a return shape
//!                      rides in.
//!   entry.zig        — which row the runtime starts: the four shapes
//!                      a program may declare, and the one the
//!                      compiler writes for `luce test`.
//!   defaults.zig     — the folded defaults of a parameter, a struct
//!                      field, and a union payload field.
//!   receiver.zig     — whether a method writes its implicit `self`.
//!   constants.zig    — compile-time evaluation: the one folder every
//!                      constant, enum value and default goes through.
//!                      It answers with a value and never emits, which
//!                      is what makes it a file rather than a region
//!                      of pass one.
//!   builder.zig      — pass two: the checked walk of every function
//!                      body, recording what it decides on stage 6's
//!                      tape as it goes.  `FunctionBuilder` and its
//!                      spine live here; each concern that can be
//!                      named on its own is a file beside it, holding
//!                      free functions over `*FunctionBuilder`:
//!   flow.zig         — narrowing and root provenance: what a branch
//!                      saves, restores and joins.
//!   ledger.zig       — the statement-temporary ledger: who owns a
//!                      fresh value until something adopts it.
//!   recorder.zig     — the typed tree's recording API, and the one
//!                      place that writes a `nodes` node.
//!   refusals.zig     — what the walk says when it says no: the
//!                      unknown name and the ownership verb.
//!   statements.zig   — the statement walk, and pass one's entry to it.
//!   assign.zig       — assignment and the three shapes of place.
//!   expressions.zig  — the expression forms, one at a time.
//!   calls.zig        — which callable a call names and which slot
//!                      each argument fills.
//!   construct.zig    — construction, conversion, and the free
//!                      builtins: the call-shaped forms that build a
//!                      value rather than run a body.
//!   builtins.zig     — what the language spells for itself: the free
//!                      builtins, the method tables, and what each
//!                      lowers to.  Data, read by the walk *and* by
//!                      the editor grammar and the site's coverage
//!                      test, which is why it is its own file.
//!   effects.zig      — what running an AST subtree could disturb,
//!                      asked before it is lowered.
//!   helpers.zig      — the small shared predicates both passes use.

pub const Error = @import("semantics/context.zig").Error;
pub const Analyzed = @import("semantics/context.zig").Analyzed;
pub const ModuleTree = @import("semantics/context.zig").ModuleTree;
pub const analyze = @import("semantics/declarations.zig").analyze;
pub const max_diagnostics = @import("semantics/declarations.zig").max_diagnostics;

// What the language spells, published for the tools that have to say
// the same words the compiler does: `tools/grammar.zig` generates the
// editor's TextMate grammar from these tables, so a name added to the
// language reaches the grammar without anyone remembering to copy it.
// The tables themselves are `semantics/builtins.zig`.
pub const reserved_names = @import("semantics/context.zig").reserved_names;
pub const isReserved = @import("semantics/context.zig").isReserved;
pub const Builtin = @import("semantics/builtins.zig").Builtin;
pub const builtins = @import("semantics/builtins.zig").builtins;
pub const list_methods = @import("semantics/builtins.zig").list_methods;
pub const array_methods = @import("semantics/builtins.zig").array_methods;
pub const map_methods = @import("semantics/builtins.zig").map_methods;
pub const builder_methods = @import("semantics/builtins.zig").builder_methods;
pub const string_methods = @import("semantics/builtins.zig").string_methods;
pub const task_methods = @import("semantics/builtins.zig").task_methods;

test {
    _ = @import("semantics/context.zig");
    _ = @import("semantics/declarations.zig");
    _ = @import("semantics/naming.zig");
    _ = @import("semantics/resolve.zig");
    _ = @import("semantics/shapes.zig");
    _ = @import("semantics/layouts.zig");
    _ = @import("semantics/signatures.zig");
    _ = @import("semantics/entry.zig");
    _ = @import("semantics/defaults.zig");
    _ = @import("semantics/receiver.zig");
    _ = @import("semantics/builder.zig");
    _ = @import("semantics/flow.zig");
    _ = @import("semantics/ledger.zig");
    _ = @import("semantics/recorder.zig");
    _ = @import("semantics/refusals.zig");
    _ = @import("semantics/statements.zig");
    _ = @import("semantics/assign.zig");
    _ = @import("semantics/expressions.zig");
    _ = @import("semantics/calls.zig");
    _ = @import("semantics/construct.zig");
    _ = @import("semantics/builtins.zig");
    _ = @import("semantics/constants.zig");
    _ = @import("semantics/effects.zig");
    _ = @import("semantics/helpers.zig");
}
