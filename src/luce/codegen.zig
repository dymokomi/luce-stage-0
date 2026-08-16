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
//! **Every unsupported shape names itself.** Two rules make that true:
//! the switches over `mir.Instruction` and `mir.Intrinsic` have no
//! `else` arm, so a new instruction is a compile error here rather
//! than a silent fallthrough; and nothing is `unreachable` for "not
//! yet" — anything without a lowering returns `.unsupported` naming
//! the tag.  A gap is therefore always a message, never wrong code.
//!
//! **The lowering is total over the instruction set.**  Everything a
//! program can say lowers: integers, floats, strings, structs, all
//! four container kinds, file/task resources and worker operations,
//! `T?`, `T!`, the math builtins, and every host service.
//! There is no list of gaps here because there are none.
//!
//! **What that sentence rests on, stated once because it was once
//! untrue.**  A handful of `unreachable`s in `lower.zig` are not "not
//! yet" but *never* — a bare function type has no cell shape and no
//! field zero, because the storable form is `(func(...) -> R)?`
//! (docs/BINDING.md D7) — and a "never" is only honest while something
//! upstream actually refuses the shape it names.  On 2026-08-12 nothing
//! did: `m.values()` on a `map(K, func(...))` manufactured a
//! `list(func(...))`, a type no program can write, and `luce build`
//! aborted the compiler with no diagnostic on a program `luce check`
//! had accepted.  Two refusals now hold the claim up — stage 4 at
//! `values()`, and `mir/verify.zig` rejecting the heap descriptor
//! outright — so those arms are unreachable rather than merely
//! unreached.  **Any new `unreachable` here owes the same pair**: name
//! the shape, and point at what refuses it.
//!
//! The `fail` messages that remain in `lower.zig` are not gaps.  They
//! name invariants the front end already guarantees — a block without
//! a terminator, arithmetic on a type that has none, an entry function
//! with more than one parameter — and exist so IR that could only
//! arrive damaged reports itself instead of being `unreachable`.
//! `lower.zig` is the authority; docs/CODEGEN.md keeps the prose.
//!
//! `src/apps/luce/object.zig` carries a lowered program the rest of the
//! way — `emit` for the object, then `cc` for the loadable `.lc` or a
//! standalone executable — and `loom run FILE.lc` opens exactly that.
//! What makes an artifact safe to hand to a loader is
//! `artifact.Artifact`: the tag this stage stamps every module with,
//! naming the machine, the host ABI, the code generator, and the
//! program it was built from, so the wrong one is refused by name.
//!
//! **The stage is named `codegen`, not `llvm`, on purpose.** Zig derives
//! symbol names from source paths, while LLVM reserves every symbol that
//! begins `llvm.` for intrinsics. A top-level `llvm/abi.zig` therefore
//! makes Zig abort with "llvm intrinsics cannot be defined!". The
//! responsibility name also keeps the backend boundary honest: LLVM is
//! the current implementation of code generation, not the compiler API.
//!
//! Flat pieces beside this file, in this module:
//!
//!   abi.zig    — the published host ABI a compiled artifact links
//!                against: the `luce_main` entry point and the
//!                `LuceHost` service table.
//!   artifact.zig
//!             — the tag a compiled module carries and a loader reads
//!               before it believes anything else: the machine, the
//!               host ABI version, the code generator, and the program
//!               it was built from.  A separate contract with its own
//!               version number, because a loader has to read the tag
//!               before it can trust the ABI version *in* the tag.
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

pub const abi = @import("codegen/abi.zig");
pub const artifact = @import("codegen/artifact.zig");
pub const effects = @import("codegen/runtime_effects.zig");

pub const Options = @import("codegen/lower.zig").Options;
pub const Result = @import("codegen/lower.zig").Result;
pub const TextResult = @import("codegen/lower.zig").TextResult;
pub const lower = @import("codegen/lower.zig").lower;
pub const lowerToText = @import("codegen/lower.zig").lowerToText;

test {
    _ = abi;
    _ = artifact;
    _ = effects;
    _ = @import("codegen/loops.zig");
    _ = @import("codegen/builder.zig");
}
