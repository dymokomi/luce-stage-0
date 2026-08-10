//! Confine a bundled compiler-rt to the compiler's own namespace.
//!
//! `libluce_rt.a` bundles Zig's compiler-rt on targets whose `cc` link
//! cannot supply the compiler-ABI symbols Zig-compiled code references
//! (`__zig_probe_stack`, `__divti3`, the half-float conversions).  The
//! bundled object also defines the C library's own names — `memcpy`,
//! `memset`, `bcmp`, and the whole libm surface — and a definition in
//! a linked archive beats the dynamic libc, so every artifact would
//! quietly trade libSystem's or glibc's optimized routines for generic
//! ones.  Measured on macOS at +52% `strings`, +58% `lists`, +65%
//! `stats` (docs/CODEGEN.md, "The benchmark snapshot").
//!
//! The rule: a defined global stays global only when it belongs to the
//! compiler's namespace (`__*`) or to the runtime's own ABI
//! (`luce_rt_*`).  Everything else — the C library's public names —
//! is made local, so the reference in the runtime's own object stays
//! undefined at the artifact link and binds to the real libc at load,
//! exactly as an unbundled build would.  The list is computed from the
//! archive itself rather than checked in, so a Zig upgrade that grows
//! compiler-rt cannot silently reopen the hole.
//!
//! Usage: localize_rt LLVM-NM LLVM-OBJCOPY IN.a OUT.a
//! The two LLVM tools install beside the `llvm-config` the build
//! already requires, so this adds no dependency.

const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = try init.args.toSlice(arena);
    if (arguments.len != 5) {
        std.debug.print("usage: localize_rt LLVM-NM LLVM-OBJCOPY IN.a OUT.a\n", .{});
        return 2;
    }
    const nm = arguments[1];
    const objcopy = arguments[2];
    const input = arguments[3];
    const output = arguments[4];

    const listed = try std.process.run(gpa, io, .{
        .argv = &.{ nm, "-g", "--defined-only", input },
    });
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);
    if (listed.term != .exited or listed.term.exited != 0) {
        std.debug.print("localize_rt: {s} failed: {s}\n", .{ nm, listed.stderr });
        return 1;
    }

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |raw| {
        // A symbol line is "ADDRESS KIND NAME"; member headers and
        // blank lines have fewer columns, and the kind is one letter.
        const line = std.mem.trim(u8, raw, " \r");
        var columns = std.mem.tokenizeScalar(u8, line, ' ');
        _ = columns.next() orelse continue;
        const kind = columns.next() orelse continue;
        const name = columns.next() orelse continue;
        if (columns.next() != null) continue;
        if (kind.len != 1) continue;
        if (keepsGlobal(name)) continue;
        try names.appendSlice(gpa, name);
        try names.append(gpa, '\n');
    }
    if (names.items.len == 0) {
        // Nothing to confine: copy through unchanged, so this tool is
        // never the reason a build breaks on a target whose bundle is
        // already clean.
        try std.Io.Dir.cwd().copyFile(input, std.Io.Dir.cwd(), output, io, .{});
        return 0;
    }

    const list_path = try std.fmt.allocPrint(arena, "{s}.localize", .{output});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = list_path, .data = names.items });

    const confined = try std.process.run(gpa, io, .{
        .argv = &.{
            objcopy,
            try std.fmt.allocPrint(arena, "--localize-symbols={s}", .{list_path}),
            input,
            output,
        },
    });
    defer gpa.free(confined.stdout);
    defer gpa.free(confined.stderr);
    if (confined.term != .exited or confined.term.exited != 0) {
        std.debug.print("localize_rt: {s} failed: {s}\n", .{ objcopy, confined.stderr });
        return 1;
    }
    return 0;
}

/// A name the artifact link may resolve from the archive: the
/// compiler's own ABI namespace and the runtime's exported one.
/// Mach-O prefixes every C name with one underscore, so the question
/// is asked with that mangling removed; ELF names arrive bare.
fn keepsGlobal(mangled: []const u8) bool {
    const name = if (mangled.len >= 2 and mangled[0] == '_' and mangled[1] != '_')
        mangled[1..]
    else if (std.mem.startsWith(u8, mangled, "___"))
        mangled[1..]
    else
        mangled;
    return std.mem.startsWith(u8, name, "__") or
        std.mem.startsWith(u8, name, "luce_rt");
}

test "the namespace rule keeps the compiler and runtime, and nothing else" {
    // ELF spellings.
    try std.testing.expect(keepsGlobal("__zig_probe_stack"));
    try std.testing.expect(keepsGlobal("__divti3"));
    try std.testing.expect(keepsGlobal("__extendhfsf2"));
    try std.testing.expect(keepsGlobal("__stack_chk_guard"));
    try std.testing.expect(keepsGlobal("luce_rt_len"));
    try std.testing.expect(!keepsGlobal("memcpy"));
    try std.testing.expect(!keepsGlobal("bcmp"));
    try std.testing.expect(!keepsGlobal("cosf"));
    try std.testing.expect(!keepsGlobal("fma"));
    try std.testing.expect(!keepsGlobal("ceilq"));
    // Mach-O spellings: one leading underscore is the C mangling.
    try std.testing.expect(keepsGlobal("___divti3"));
    try std.testing.expect(keepsGlobal("_luce_rt_len"));
    try std.testing.expect(!keepsGlobal("_memcpy"));
    try std.testing.expect(!keepsGlobal("_memmove"));
}
