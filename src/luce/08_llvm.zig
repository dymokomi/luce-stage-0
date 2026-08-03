//! Stage 8 — LLVM lowering.  MIR in, LLVM bitcode out.
//!
//! Consumes: an optimized, verified `mir.Program`.
//! Produces: LLVM IR built with `std.zig.llvm.Builder` — pure Zig,
//! linking nothing — for a module that is position-independent, exports
//! exactly `luce_main`, and declares no undefined symbols beyond
//! `libluce_rt`.
//!
//! **Turning that bitcode into an object is a separate module, and the
//! separation is the point.**  `emit.zig` is the one file in the tree
//! that calls libLLVM, so it is its own build module (`emit`), and only
//! the `luce` compiler links it.  `loom` — which runs programs and asks
//! `luce` to build one when it must — carries no libLLVM at all, and a
//! machine that only ever *runs* Luce programs needs no LLVM installed.
//! Everything left in this stage is reachable from both.
//!
//! **Partial, and it names its own gaps.**  Two rules make that true:
//! the switches over `mir.Instruction` and `mir.Intrinsic` have no
//! `else` arm, so a new instruction is a compile error here rather
//! than a silent fallthrough; and nothing is `unreachable` for "not
//! yet" — anything without a lowering returns `.unsupported` naming
//! the tag.  A gap is therefore always a message, never wrong code.
//!
//! **The lowering is total over the instruction set.**  Everything a
//! program can say lowers: integers, floats, strings, structs, all
//! four container kinds, `T?`, `T!`, ownership, the math builtins, and
//! every host service.  There is no list of gaps here because there
//! are none.
//!
//! The `fail` messages that remain in `lower.zig` are not gaps.  They
//! name invariants the front end already guarantees — a block without
//! a terminator, arithmetic on a type that has none, an entry function
//! with parameters — and exist so IR that could only arrive damaged
//! reports itself instead of being `unreachable`.
//! `lower.zig` is the authority; docs/CODEGEN.md keeps the prose.
//!
//! `src/apps/luce/object.zig` carries a lowered program the rest of the
//! way — `emit` for the object, then `cc` for the loadable `.lc` or a
//! standalone executable — and `loom run FILE.lc` opens exactly that.
//! What makes an artifact safe to hand to a loader is
//! `abi.Artifact`: the tag this stage stamps every
//! module with, naming the machine, the host ABI, and the program it
//! was built from, so the wrong one is refused by name.
//!
//! **The numeric prefix is load-bearing; do not drop it.**  Zig derives
//! symbol names from the source path and LLVM claims every symbol
//! beginning `llvm.` as one of its own intrinsics, so a file at
//! `src/luce/llvm/abi.zig` makes the Zig compiler abort outright with
//! "llvm intrinsics cannot be defined!".  `08_llvm/abi.zig` yields
//! `08_llvm.abi.…`, which does not begin `llvm.`, and the check never
//! fires.  The prefix is what lets this folder carry the honest name.
//!
//! Flat pieces beside this file, in this module:
//!
//!   abi.zig    — the published host ABI a compiled artifact links
//!                against: the `luce_main` entry point, the `LuceHost`
//!                service table, and the artifact tag a loader reads.
//!   lower.zig  — typed MIR to LLVM IR, built with the pure-Zig
//!                `std.zig.llvm.Builder`.  No libLLVM, no `else` arms.
//!   loops.zig  — where a container resolution may be lifted to.
//!   runtime_effects.zig
//!             — what the artifact tells LLVM about `libluce_rt`:
//!               one arm per entry point saying what it does to
//!               memory, whether it unwinds, whether it comes back,
//!               and what each argument is.  A declaration without
//!               that is the most pessimistic thing LLVM can be
//!               handed.
//!
//! And in the `emit` module beside them, which links libLLVM:
//!
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

test {
    _ = abi;
    _ = effects;
    _ = @import("08_llvm/loops.zig");
}
