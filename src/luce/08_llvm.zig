//! Stage 8 — LLVM lowering.  MIR in, machine code out.
//!
//! Consumes: an optimized, verified `mir.Program`.
//! Produces: LLVM IR built with `std.zig.llvm.Builder`, then — through
//! libLLVM's stable C surface — a relocatable object for the host
//! triple, position-independent, exporting exactly `luce_main` and
//! declaring no undefined symbols beyond `libluce_rt`.
//!
//! **Partial, and it names its own gaps.**  Two rules make that true:
//! the switches over `mir.Instruction` and `mir.Intrinsic` have no
//! `else` arm, so a new instruction is a compile error here rather
//! than a silent fallthrough; and nothing is `unreachable` for "not
//! yet" — anything without a lowering returns `.unsupported` naming
//! the tag.  A gap is therefore always a message, never wrong code.
//!
//! What is not lowered today: Float in every position, struct values,
//! Bytes, evaluator ports, the scalar math intrinsics, and every host
//! service except `print`.  `lower.zig` is the authority on that list;
//! docs/CODEGEN.md keeps the prose version.  Linking is still the
//! caller's job — there is no shared-library or executable emit mode —
//! so the interpreter, not this stage, is what `loom run` uses.
//!
//! **The numeric prefix is load-bearing; do not drop it.**  Zig derives
//! symbol names from the source path and LLVM claims every symbol
//! beginning `llvm.` as one of its own intrinsics, so a file at
//! `src/luce/llvm/abi.zig` makes the Zig compiler abort outright with
//! "llvm intrinsics cannot be defined!".  `08_llvm/abi.zig` yields
//! `08_llvm.abi.…`, which does not begin `llvm.`, and the check never
//! fires.  The prefix is what lets this folder carry the honest name.
//!
//! Flat pieces beside this file:
//!
//!   abi.zig    — the published host ABI a compiled artifact links
//!                against: the `luce_main` entry point and the
//!                `LuceHost` service table.
//!   lower.zig  — typed MIR to LLVM IR, built with the pure-Zig
//!                `std.zig.llvm.Builder`.  No libLLVM, no `else` arms.
//!   emit.zig   — libLLVM's stable C surface: bitcode to object code.
//!   test.zig   — the end-to-end proof: Luce source through LLVM into
//!                a shared library, loaded and run against a host.

pub const abi = @import("08_llvm/abi.zig");

pub const Options = @import("08_llvm/lower.zig").Options;
pub const Result = @import("08_llvm/lower.zig").Result;
pub const TextResult = @import("08_llvm/lower.zig").TextResult;
pub const lower = @import("08_llvm/lower.zig").lower;
pub const lowerToText = @import("08_llvm/lower.zig").lowerToText;

pub const EmitOptions = @import("08_llvm/emit.zig").Options;
pub const EmitResult = @import("08_llvm/emit.zig").Result;
pub const Relocation = @import("08_llvm/emit.zig").Relocation;
pub const compile = @import("08_llvm/emit.zig").compile;
pub const hostTriple = @import("08_llvm/emit.zig").hostTriple;

test {
    _ = abi;
    _ = @import("08_llvm/test.zig");
}
