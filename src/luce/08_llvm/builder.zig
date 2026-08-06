//! The vendored LLVM IR builder — `std.zig.llvm.Builder` at the
//! pinned Zig (0.16), taken in-tree so it can say what the standard
//! library's copy cannot: metadata on loads, stores, and calls.
//!
//! **Why a vendored copy exists at all** (the task-#45 ruling): the
//! std Builder attaches exactly two metadata kinds — `!prof` and
//! `!unpredictable`, on `br_cond` and `switch` — and offers no API to
//! attach anything to a memory instruction.  That forecloses
//! `!alias.scope`/`!noalias` (what lets LICM hoist an element pointer
//! over stores it provably cannot alias), `!range` where MIR knows a
//! bound, and `!nonnull` on handles that cannot be null — measured at
//! 1.8x on the matmul-shaped path (docs/CODEGEN.md).  Building IR
//! against libLLVM's C API instead would reverse the stability
//! decision docs/CODEGEN.md records; owning the file keeps it.
//!
//! **The vendoring contract.**  Three files, byte-identical to the
//! pinned Zig's `lib/std/zig/llvm/` except where a comment says
//! `LUCE:` — one import path at the top of `Builder.zig`, and the
//! metadata-attachment extension.  On a Zig upgrade, re-diff against
//! the new std copy: everything without a `LUCE:` marker is theirs.
//! `BitcodeReader.zig` is deliberately not vendored — nothing here
//! reads bitcode back.

pub const Builder = @import("builder/Builder.zig");

test {
    _ = Builder;
}
