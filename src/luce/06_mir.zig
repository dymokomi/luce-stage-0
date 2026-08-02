//! Stage 6 — MIR: the typed mid-level intermediate representation.
//!
//! Consumes: the validated program from stage 4 (which, today, hands
//! MIR over already built — see below).
//! Produces: `Program` — an instruction pool plus basic blocks per
//! function, with struct layouts, heap-type shapes, constants, and the
//! entry.  Registers never cross a block boundary; state that must
//! survive a loop lives in a mutable local.  This is the form the `.lc`
//! serializes, the verifier checks, the interpreter runs, and stage 8
//! lowers to LLVM.
//!
//! **What is not done yet.**  The *lowering into* MIR is not here.  It
//! is still fused into `04_semantics/builder.zig`, which type-checks
//! and emits in one walk; this folder holds the representation, the
//! verifier, the printer, and the on-disk format, but not the pass
//! that produces them.  Moving that pass here is the seam 04's header
//! describes.
//!
//! The verifier is a compiler invariant rather than a user diagnostic:
//! every successful compile passes it, `module.decode` re-runs it so a
//! damaged `.lc` is rejected, and a failure is reported as an internal
//! compiler error.  Instruction *types* beyond what the verifier
//! checks are trusted — treat a `.lc` like an executable.
//!
//! Flat pieces beside this file:
//!
//!   defs.zig   — the instruction set, blocks, functions, `Program`,
//!                trap codes, and `strip` (the --release origin drop).
//!   verify.zig — the shape and type checks every program must pass.
//!   print.zig  — the deterministic textual dump behind `luce ir`.
//!   module.zig — the `.lc` format: a direct binary serialization of
//!                everything above, and the decoder that re-verifies.
//!   test.zig   — the representation and verifier proved on their own.

pub const Register = @import("06_mir/defs.zig").Register;
pub const BlockId = @import("06_mir/defs.zig").BlockId;
pub const LocalId = @import("06_mir/defs.zig").LocalId;
pub const BinaryOp = @import("06_mir/defs.zig").BinaryOp;
pub const UnaryOp = @import("06_mir/defs.zig").UnaryOp;
pub const ConvertKind = @import("06_mir/defs.zig").ConvertKind;
pub const Intrinsic = @import("06_mir/defs.zig").Intrinsic;
pub const TrapCode = @import("06_mir/defs.zig").TrapCode;
pub const Instruction = @import("06_mir/defs.zig").Instruction;
pub const Local = @import("06_mir/defs.zig").Local;
pub const Block = @import("06_mir/defs.zig").Block;
pub const Origin = @import("06_mir/defs.zig").Origin;
pub const Function = @import("06_mir/defs.zig").Function;
pub const Program = @import("06_mir/defs.zig").Program;
pub const strip = @import("06_mir/defs.zig").strip;
pub const verify = @import("06_mir/verify.zig").verify;
pub const VerifyError = @import("06_mir/verify.zig").VerifyError;
pub const print = @import("06_mir/print.zig").print;

/// The `.lc` module format.  It lives with the representation it
/// serializes, so a change to the instruction set and the bump of
/// `format_version` it forces are one edit in one folder.
pub const module = @import("06_mir/module.zig");

test {
    _ = module;
    _ = @import("06_mir/test.zig");
}
