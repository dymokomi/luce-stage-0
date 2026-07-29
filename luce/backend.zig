//! The execution boundary of the Luce compiler.
//!
//! Everything in front of this file — lexer, parser, analysis, Luce IR
//! and its verifier — is backend-independent.  This boundary runs one
//! verified program against an Input frame and a scratch Output frame
//! under an explicit budget, per docs/LUCE.md's evaluation model:
//! immutable inputs, candidate outputs, publish-nothing on failure.
//!
//! The first engine behind the boundary is the deterministic Luce IR
//! interpreter.  A native code generator (the plan's LLVM lowering)
//! slots in behind these same types without changing Luce programs or
//! anything in front of the boundary.

const std = @import("std");
const ir = @import("ir.zig");
const interpreter = @import("interpreter.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// A runtime value.  Strings, bytes, and struct storage are borrowed
/// from the program, the caller's input frame, or the evaluation arena
/// — nothing here owns memory, and nothing outlives the evaluation
/// unless the caller copies it out.
pub const RuntimeValue = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    strukt: []RuntimeValue,
};

/// One input port slot: a value borrowed for the duration of the
/// evaluation, or unavailable.
pub const InputValue = union(enum) {
    unavailable,
    value: RuntimeValue,
};

pub const Trap = struct {
    code: ir.TrapCode,
    /// Arena-owned or static; valid until the evaluation arena frees.
    message: []const u8,
};

pub const Result = union(enum) {
    /// The output frame holds every written output.
    success,
    /// The evaluator failed; the output frame must not be published.
    trap: Trap,
    /// An input the program reads was unavailable; nothing ran.
    unavailable,
};

/// Deadline analog: evaluation is bounded by instruction steps and
/// call depth, so an accidental infinite loop traps instead of
/// freezing the caller.
pub const Budget = struct {
    steps: u64 = 10_000_000,
    call_depth: u32 = 256,
};

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

/// Run the program's evaluate entry.  `inputs` parallels
/// program.inputs; `outputs` parallels program.outputs and starts
/// empty — on success, written slots carry the candidate outputs
/// (allocated from `arena` where they need storage).  The caller owns
/// the arena and copies out what it publishes before freeing it.
pub fn evaluate(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
) error{OutOfMemory}!Result {
    return interpreter.run(arena, program, inputs, outputs, budget);
}

test {
    _ = interpreter;
}
