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
//! internally instead.  That is why the numbering runs 03, 04, 05 with
//! no gap: this is the intended end state, not a pending split.
//!
//! **Where this stage stops.**  It decides *what* the program does and
//! records each decision as it is reached, on a `mir.build.Lowering` —
//! stage 6's tape.  It does not know how MIR is made: register
//! numbering, block bookkeeping, the local table, the constant pool,
//! sealing, debug origins, and the assembly of a `mir.Program` are all
//! `06_mir/build.zig`'s.  What crosses the seam is a plain value with
//! no path back into the checker, which is why stage 6 can close it
//! long after this stage has finished.  Recording cannot be *deferred*
//! — it happens in the same visit as the check that decides it,
//! because the check is what decides it — but it is not this stage's
//! code.
//!
//! Rules enforced here, per docs/LANGUAGE.md: static types with no
//! implicit numeric conversion, immutable `let` and parameters, no
//! shadowing, definite initialization, `return` on every path, and
//! struct cycles refused.  Nothing about any backend appears here.
//!
//! **This stage is the last word on the memory model.**  The MIR
//! verifier checks structure and types, not meaning, so `let`
//! immutability, poisoning after `give`/`free`, the rule that a borrow
//! may not be kept, the ban on storing a bare name into a container,
//! `fill` on an array of objects, and the host gate are all checked
//! here and nowhere else.  That is deliberate — a `.lc` is an
//! executable and is trusted like one (docs/PIPELINE.md) — but it
//! means a change here is a change to what the language guarantees,
//! and `specs/ownership_spec.zig` is where that is pinned down.
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
//!                      selected entry; then drive pass two.
//!   builder.zig      — pass two: the checked walk of every function
//!                      body, recording what it decides on stage 6's
//!                      tape as it goes.
//!   helpers.zig      — the small shared predicates both passes use.

pub const Error = @import("04_semantics/context.zig").Error;
pub const Analyzed = @import("04_semantics/context.zig").Analyzed;
pub const ModuleTree = @import("04_semantics/context.zig").ModuleTree;
pub const analyze = @import("04_semantics/declarations.zig").analyze;
pub const max_diagnostics = @import("04_semantics/declarations.zig").max_diagnostics;

test {
    _ = @import("04_semantics/context.zig");
    _ = @import("04_semantics/declarations.zig");
    _ = @import("04_semantics/builder.zig");
    _ = @import("04_semantics/helpers.zig");
}
