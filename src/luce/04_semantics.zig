//! Stage 4 — semantics: name resolution, type checking, and validation.
//!
//! Consumes: the untyped `ast.Program` of every module in the import
//! graph, plus the Port schema and the compile options (entry mode,
//! host gate, fabric gate).
//! Produces: an `Analyzed` — struct layouts, heap-type shapes, folded
//! constants, and one lowered function per declaration — or
//! `luce.sema.*` diagnostics and nothing at all.
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
//! **What is not done yet.**  This walk *also* performs the AST-to-MIR
//! lowering — the conceptual stage 8 — and that part genuinely is
//! separable: `builder.zig` type-checks an expression and emits the
//! instruction for it in the same visit.  Cutting the emit half out
//! into `06_mir/`, so this stage produces a validated typed tree and
//! nothing else, is the seam to take next.  The internal files are
//! still organised around the fused shape, so that means splitting
//! `builder.zig` before moving anything.
//!
//! Rules enforced here, per docs/LANGUAGE.md: static types with no
//! implicit numeric conversion, immutable `let` and parameters, no
//! shadowing, definite initialization, `return` on every path, struct
//! cycles refused, input read-only and output write-only, and only the
//! ports the schema declares.  Nothing about any backend appears here.
//!
//! Flat pieces beside this file:
//!
//!   declarations.zig — pass one: collect struct layouts, function
//!                      signatures, top-level constants, and the
//!                      selected entry; then drive pass two.
//!   builder.zig      — pass two: the checked walk of every function
//!                      body, which also emits the IR.
//!   helpers.zig      — the small shared predicates both passes use.

pub const Error = @import("04_semantics/declarations.zig").Error;
pub const Analyzed = @import("04_semantics/declarations.zig").Analyzed;
pub const ModuleTree = @import("04_semantics/declarations.zig").ModuleTree;
pub const analyze = @import("04_semantics/declarations.zig").analyze;

pub const declarations = @import("04_semantics/declarations.zig");
pub const builder = @import("04_semantics/builder.zig");
pub const helpers = @import("04_semantics/helpers.zig");
