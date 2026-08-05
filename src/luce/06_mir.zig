//! Stage 6 — MIR: the typed mid-level intermediate representation, and
//! the pass that builds it.
//!
//! Consumes: `Lowered`, the value stage 4 hands over — struct layouts,
//! heap-type shapes, the constant pool, the entry, and one open
//! `Lowering` per function.
//! Produces: `Program` — an instruction pool plus basic blocks per
//! function.  Registers never cross a block boundary; state that must
//! survive a loop lives in a mutable local.  This is the form a `.lcm`
//! serializes, the verifier checks, stage 8 lowers to LLVM, and the
//! test suite's oracle interprets.
//!
//! **The emitter is here; the walk that drives it is stage 4's.**  A
//! `Lowering` is a tape of already-decided operations: `build.zig`
//! owns register numbering, block bookkeeping, the local table, the
//! ownership instruction pairs, sealing, origin resolution, and the
//! assembly of the program.  Stage 4 decides *what* to record and
//! records it as it type-checks — the two cannot be separated in time,
//! because resolving `xs.append(v)` needs the receiver's type — but
//! they are separated in code, and the hand-over is a plain value with
//! no path back into the checker.
//!
//! The verifier is a compiler invariant rather than a user diagnostic:
//! every successful compile passes it, `module.decode` re-runs it so a
//! damaged `.lcm` is rejected, and a failure is reported as an internal
//! compiler error.  Instruction *types* beyond what the verifier
//! checks are trusted — treat a `.lcm` like the executable it becomes.
//!
//! Flat pieces beside this file:
//!
//!   defs.zig   — the instruction set, blocks, functions, `Program`,
//!                trap codes, and `strip` (the --release origin drop).
//!   build.zig  — the emitter (`Lowering`), the hand-over value
//!                (`Lowered`), and `build`, which closes and assembles.
//!   verify.zig — the shape and type checks every program must pass.
//!   print.zig  — the deterministic textual dump behind `luce ir`.
//!   module.zig — the `.lcm` format: a direct binary serialization of
//!                everything above, and the decoder that re-verifies.
//!   test.zig   — the representation and verifier proved on their own.

pub const Register = @import("06_mir/defs.zig").Register;
pub const BlockId = @import("06_mir/defs.zig").BlockId;
pub const LocalId = @import("06_mir/defs.zig").LocalId;
pub const BinaryOp = @import("06_mir/defs.zig").BinaryOp;
pub const UnaryOp = @import("06_mir/defs.zig").UnaryOp;
pub const Intrinsic = @import("06_mir/defs.zig").Intrinsic;
pub const TrapCode = @import("06_mir/defs.zig").TrapCode;
pub const ErrorCode = @import("06_mir/defs.zig").ErrorCode;
pub const FileAct = @import("06_mir/defs.zig").FileAct;
pub const Instruction = @import("06_mir/defs.zig").Instruction;
pub const Local = @import("06_mir/defs.zig").Local;
pub const Block = @import("06_mir/defs.zig").Block;
pub const Origin = @import("06_mir/defs.zig").Origin;
pub const Function = @import("06_mir/defs.zig").Function;
pub const Program = @import("06_mir/defs.zig").Program;
pub const strip = @import("06_mir/defs.zig").strip;
pub const boxTag = @import("06_mir/defs.zig").boxTag;

/// Building the MIR: the emitter stage 4 records on, and the pass that
/// closes what it recorded into a `Program`.
pub const build = @import("06_mir/build.zig");

pub const verify = @import("06_mir/verify.zig").verify;
pub const VerifyError = @import("06_mir/verify.zig").VerifyError;
pub const print = @import("06_mir/print.zig").print;

/// The `.lcm` module format.  It lives with the representation it
/// serializes, so a change to the instruction set and the bump of
/// `format_version` it forces are one edit in one folder.
pub const module = @import("06_mir/module.zig");

test {
    _ = build;
    _ = module;
    _ = @import("06_mir/test.zig");
}
