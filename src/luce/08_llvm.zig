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
//! What is not lowered today: `Bytes`, and the evaluator ports
//! (`input_load`/`output_store`, plus an entry function with
//! parameters).  That is the whole list, and every item on it is v1
//! machinery on its way out — so this stage becomes total over the
//! instruction set the day that goes.  Everything a script can say
//! lowers: integers, floats, strings, structs, all four container
//! kinds, ownership, the math builtins, and every host service.
//!
//! The other `fail` messages in `lower.zig` are not gaps.  They name
//! invariants the front end already guarantees — a block without a
//! terminator, arithmetic on a type that has none — and exist so a
//! broken invariant reports itself instead of being `unreachable`.
//! `lower.zig` is the authority; docs/CODEGEN.md keeps the prose.
//!
//! Linking is still the caller's job: this stage stops at a
//! relocatable object, with no shared-library, executable, or wasm
//! emit mode, so `loom run` still uses the interpreter.
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
//!   runtime_effects.zig
//!             — what the artifact tells LLVM about `libluce_rt`:
//!               one arm per entry point saying what it does to
//!               memory, whether it unwinds, whether it comes back,
//!               and what each argument is.  A declaration without
//!               that is the most pessimistic thing LLVM can be
//!               handed.
//!   emit.zig   — libLLVM's stable C surface: bitcode to object code.
//!   test.zig   — the end-to-end proof: Luce source through LLVM into
//!                a shared library, loaded and run against a host.

pub const abi = @import("08_llvm/abi.zig");
pub const effects = @import("08_llvm/runtime_effects.zig");

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
    _ = effects;
    _ = @import("08_llvm/loops.zig");
    _ = @import("08_llvm/test.zig");
}
