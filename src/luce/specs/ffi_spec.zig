//! The FFI boundary, on both engines (docs/FFI.md).
//!
//! The probe symbols live in `runtime/ffi.zig` and ride `libluce_rt`,
//! so the compiled arm resolves them at link time and the oracle
//! resolves them in its own image through the shim — one set of
//! symbols, two dispatch strategies, compared like everything else.
//!
//! What is deliberately absent: an unknown-symbol session.  The two
//! arms answer that case at different times by design — the compiled
//! arm at link, the oracle at the call — so there is no one behavior
//! to compare, and the compile-time refusals below are where the
//! boundary's rules are pinned.

const std = @import("std");
const luce = @import("luce");
const agree = @import("agree.zig");

const testing = std.testing;

fn expectRejected(source: []const u8, code: []const u8) !void {
    var result = try luce.compile.compile(testing.allocator, source, .{ .allow_host = true });
    defer result.deinit();
    switch (result) {
        .success => {
            std.debug.print("expected {s}, but the program compiled:\n{s}\n", .{ code, source });
            return error.TestUnexpectedResult;
        },
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, code)) return;
            }
            std.debug.print("expected {s}, but the diagnostics were:\n", .{code});
            for (0..diagnostics.count()) |index| {
                const one = diagnostics.at(index).?;
                std.debug.print("  {s}: {s}\n", .{ one.code, one.message });
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "an extern call crosses the boundary and back, every Tier-1 return kind" {
    try agree.prints(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\extern func luce_ffi_probe_narrow(a: u32) -> u32
        \\extern func luce_ffi_probe_pi() -> f64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(40, 2)))
        \\    print(str(luce_ffi_probe_narrow(9)))
        \\    print(str(luce_ffi_probe_pi()))
        \\    let held = luce_ffi_probe_add(luce_ffi_probe_add(1, 2), 3)
        \\    print(str(held))
        \\
    ,
        \\42
        \\10
        \\3.5
        \\6
        \\
    );
}

test "the extern declaration's refusals keep the C shape the whole truth" {
    // A parameter outside the Tier-1 vocabulary.
    try expectRejected(
        \\extern func speaks(words: str) -> i64
        \\
        \\func main():
        \\    print(str(speaks("no")))
        \\
    , "luce.sema.extern");
    // A named argument: the C shape promises no names.
    try expectRejected(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(a = 1, b = 2)))
        \\
    , "luce.sema.extern");
    // Arity is exact.
    try expectRejected(
        \\extern func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(1)))
        \\
    , "luce.sema.extern");
    // A narrow width the ABI would need extension attributes for.
    try expectRejected(
        \\extern func tiny(a: u8) -> i64
        \\
        \\func main():
        \\    print(str(tiny(1)))
        \\
    , "luce.sema.extern");
}

test "the scoped buffer form hands real memory across and back" {
    // `zstring` builds the NUL-terminated bytes, `with_bytes` pins
    // them for the scope and hands over the address, and the C side
    // reads the actual memory: 'A' + 'B' + 0 = 131 on both engines.
    try agree.prints(
        \\import std.c
        \\
        \\extern func luce_ffi_probe_sum_bytes(at: foreign, count: u64) -> i64
        \\
        \\func main():
        \\    var data = c.zstring("AB")
        \\    let total = c.with_bytes(data, (p) => luce_ffi_probe_sum_bytes(p, 3))
        \\    print(str(total))
        \\    var empty = list[u8]()
        \\    print(str(c.with_bytes(empty, (p) => luce_ffi_probe_sum_bytes(p, 0))))
        \\
    ,
        \\131
        \\0
        \\
    );
}

test "a blocking extern answers outside the effect lock on both engines" {
    // `blocking` is the declaration's opt-out of the effect lock — the
    // callee promises its own thread-safety and may park the thread.
    // The answer is the same either way; what this pins is that the
    // unlocked path executes at all, on both engines, and stays a
    // per-declaration fact rather than a call-site one.
    try agree.prints(
        \\extern blocking func luce_ffi_probe_add(a: i64, b: i64) -> i64
        \\
        \\func main():
        \\    print(str(luce_ffi_probe_add(20, 22)))
        \\
    ,
        \\42
        \\
    );
}
