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

const std = @import("std");

test {
    _ = Builder;
}

test "the extension attaches metadata to loads, stores, and calls, and the printer shows it" {
    // The whole point of the vendored copy, proven in isolation: build
    // one function by hand, attach each kind this tree uses, and read
    // the textual IR back.  The bitcode path is proven by every
    // compiled spec the moment lower.zig attaches anything — libLLVM
    // rejects malformed metadata loudly — so what this test pins is
    // the API's contract: the right instruction, the right kind, the
    // right node.
    const gpa = std.testing.allocator;
    var builder = try Builder.init(.{ .allocator = gpa });
    defer builder.deinit();

    const fn_type = try builder.fnType(.i64, &.{.ptr}, .normal);
    const fn_global = try builder.addFunction(fn_type, try builder.strtabString("probe"), .default);
    var wip = try Builder.WipFunction.init(&builder, .{
        .function = fn_global,
        .strip = true,
    });
    defer wip.deinit();
    wip.cursor = .{ .block = try wip.block(0, "entry") };

    const argument = wip.arg(0);
    const loaded = try wip.load(.normal, .i64, argument, .default, "loaded");
    // !range on the load: the pair [0, 256).
    try wip.attachMetadata(loaded, .range, try builder.metadataTuple(&.{
        try builder.metadataConstant(try builder.intConst(.i64, 0)),
        try builder.metadataConstant(try builder.intConst(.i64, 256)),
    }));
    // !nonnull carries no operands: the empty tuple.
    const pointer_load = try wip.load(.normal, .ptr, argument, .default, "pointer");
    try wip.attachMetadata(pointer_load, .nonnull, try builder.metadataTuple(&.{}));
    // Alias scopes: a domain, a scope in it, and a list holding the
    // scope — the shape ScopedNoAliasAA reads.  Uniqued by their name
    // strings, which is what keeps two scopes two.
    const domain = try builder.metadataTuple(&.{
        (try builder.metadataString("luce.domain")).toMetadata(),
    });
    const scope = try builder.metadataTuple(&.{
        (try builder.metadataString("luce.scope.elements")).toMetadata(),
        domain,
    });
    const scope_list = try builder.metadataTuple(&.{scope});
    const stored = try wip.store(.normal, loaded, argument, .default);
    try wip.attachMetadata(stored.toValue(), .@"alias.scope", scope_list);
    try wip.attachMetadata(stored.toValue(), .@"noalias", scope_list);
    _ = try wip.ret(loaded);
    try wip.finish();

    var rendered: std.Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try builder.print(&rendered.writer);
    const text = rendered.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "!range !") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!nonnull !") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!alias.scope !") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!noalias !") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!\"luce.scope.elements\"") != null);
    // The attachments sit on the memory instructions, not the ret.
    const ret_line_start = std.mem.lastIndexOf(u8, text, "  ret ").?;
    try std.testing.expect(std.mem.indexOf(u8, text[ret_line_start..], "!range") == null);

    // And the bitcode writer accepts the module whole.
    const words = try builder.toBitcode(gpa, .{
        .name = "luce",
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
    });
    defer gpa.free(words);
    try std.testing.expect(words.len > 0);
}
