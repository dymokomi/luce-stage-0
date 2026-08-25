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

pub const Register = @import("mir/defs.zig").Register;
pub const BlockId = @import("mir/defs.zig").BlockId;
pub const LocalId = @import("mir/defs.zig").LocalId;
pub const BinaryOp = @import("mir/defs.zig").BinaryOp;
pub const UnaryOp = @import("mir/defs.zig").UnaryOp;
pub const Intrinsic = @import("mir/defs.zig").Intrinsic;
pub const TrapCode = @import("mir/defs.zig").TrapCode;
pub const ErrorCode = @import("mir/defs.zig").ErrorCode;
pub const FileAct = @import("mir/defs.zig").FileAct;
pub const Instruction = @import("mir/defs.zig").Instruction;
pub const ForeignFunction = @import("mir/defs.zig").ForeignFunction;
pub const ForeignVariable = @import("mir/defs.zig").ForeignVariable;
pub const Local = @import("mir/defs.zig").Local;
pub const Block = @import("mir/defs.zig").Block;
pub const Origin = @import("mir/defs.zig").Origin;
pub const ConstantValue = @import("mir/defs.zig").ConstantValue;
pub const ContainerConstant = @import("mir/defs.zig").ContainerConstant;
pub const Function = @import("mir/defs.zig").Function;
pub const InterfaceWitness = @import("mir/defs.zig").InterfaceWitness;
pub const Program = @import("mir/defs.zig").Program;
pub const strip = @import("mir/defs.zig").strip;
pub const boxTag = @import("mir/defs.zig").boxTag;
pub const mapKeyStorage = @import("mir/defs.zig").mapKeyStorage;
pub const function_run_length = @import("mir/defs.zig").function_run_length;
pub const function_run_named = @import("mir/defs.zig").function_run_named;
pub const function_run_receiver = @import("mir/defs.zig").function_run_receiver;
pub const interface_run_length = @import("mir/defs.zig").interface_run_length;
pub const interface_run_witness = @import("mir/defs.zig").interface_run_witness;
pub const interface_run_payload = @import("mir/defs.zig").interface_run_payload;

/// Building the MIR: the emitter stage 4 records on, and the pass that
/// closes what it recorded into a `Program`.
pub const build = @import("mir/build.zig");

pub const verify = @import("mir/verify.zig").verify;
pub const VerifyError = @import("mir/verify.zig").VerifyError;
pub const print = @import("mir/print.zig").print;

/// The `.lcm` module format.  It lives with the representation it
/// serializes, so a change to the instruction set and the bump of
/// `format_version` it forces are one edit in one folder.
pub const module = @import("mir/module.zig");

test {
    _ = build;
    _ = module;
    _ = @import("mir/verify.zig");
    _ = @import("mir/test.zig");
}
