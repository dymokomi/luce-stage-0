//! The native image — generated machine code cached beside the .lc.
//!
//! Milestone 5b (docs/NATIVE.md): the `.lc` stays the portable,
//! verified artifact; a `.lci` beside it holds the machine code the
//! native engine generated for one loom build on one target, so the
//! next `loom run` maps it into executable pages, fills the State
//! address table, and calls the entry — no code generation, no MIR
//! context.  M1's hermetic codegen is what makes this a plain copy:
//! the bytes contain no host address and every call target is read
//! from the table at run time, so functions can land anywhere.
//!
//! Validity is decided by three keys the runner checks, cheapest
//! first: the ABI fingerprint (`native.fingerprint()` — target,
//! layout offsets, service roster), the hash of the `.lc` bytes, and
//! the hash of the lowered MIR text (`native.textHash`) — lowering
//! is pure and costs well under a millisecond, so any change to the
//! code generator invalidates every image automatically, with no
//! version constant to remember to bump.  A stale or foreign image
//! is simply ignored; the runner falls back to the JIT and rewrites
//! it.  The header also carries a hash of the body, so a torn write
//! or flipped bit is a clean cache miss instead of a jump into
//! corrupt machine code — the image meets the same bar as the .lc,
//! which re-verifies on every decode.  Like the .lc, what remains
//! out of scope is deliberate tampering: an image is trusted like
//! an executable.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Bump on any change to this file's layout.  The codegen itself
/// needs no version here — the lowered-text hash covers it.
pub const format_version: u32 = 1;

const magic = "LCIM";
const header_size = 4 + 4 + 8 * 4 + 4;

/// Everything that must match for an image to be usable.
pub const Keys = struct {
    fingerprint: u64,
    module_hash: u64,
    text_hash: u64,
};

/// Whether this platform can map and run an image.  Windows would
/// need VirtualAlloc plumbing; until then it JITs every run.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub fn hashModule(encoded: []const u8) u64 {
    return std.hash.Wyhash.hash(0, encoded);
}

// ---------------------------------------------------------------------------
// Format
// ---------------------------------------------------------------------------

/// Serialize one function-code span per function, packed after a
/// keyed header.  Caller owns the bytes.
pub fn encode(gpa: Allocator, spans: []const []const u8, keys: Keys) Allocator.Error![]u8 {
    var total: usize = header_size + 8 * spans.len;
    for (spans) |span| total += span.len;
    const bytes = try gpa.alloc(u8, total);
    var at: usize = header_size;
    for (spans) |span| {
        std.mem.writeInt(u64, bytes[at..][0..8], span.len, .little);
        at += 8;
    }
    for (spans) |span| {
        @memcpy(bytes[at..][0..span.len], span);
        at += span.len;
    }
    // Header last: the body hash covers everything after it, so a
    // torn write or flipped bit reads as a cache miss, never as
    // machine code.
    at = 0;
    @memcpy(bytes[at..][0..4], magic);
    at += 4;
    std.mem.writeInt(u32, bytes[at..][0..4], format_version, .little);
    at += 4;
    const body_hash = std.hash.Wyhash.hash(0, bytes[header_size..]);
    for ([_]u64{ keys.fingerprint, keys.module_hash, keys.text_hash, body_hash }) |key| {
        std.mem.writeInt(u64, bytes[at..][0..8], key, .little);
        at += 8;
    }
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(spans.len), .little);
    return bytes;
}

pub const DecodeError = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    WrongFingerprint,
    WrongModule,
    WrongCode,
    WrongShape,
    Damaged,
} || Allocator.Error;

/// Validate an image against the keys and the expected function
/// count; the returned spans borrow `bytes`.
pub fn decode(
    gpa: Allocator,
    bytes: []const u8,
    keys: Keys,
    function_count: usize,
) DecodeError![]const []const u8 {
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.WrongMagic;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.WrongVersion;
    if (std.mem.readInt(u64, bytes[8..16], .little) != keys.fingerprint) return error.WrongFingerprint;
    if (std.mem.readInt(u64, bytes[16..24], .little) != keys.module_hash) return error.WrongModule;
    if (std.mem.readInt(u64, bytes[24..32], .little) != keys.text_hash) return error.WrongCode;
    if (std.mem.readInt(u64, bytes[32..40], .little) !=
        std.hash.Wyhash.hash(0, bytes[header_size..])) return error.Damaged;
    const count = std.mem.readInt(u32, bytes[40..44], .little);
    if (count != function_count) return error.WrongShape;
    if (bytes.len < header_size + 8 * @as(usize, count)) return error.Truncated;

    const spans = try gpa.alloc([]const u8, count);
    errdefer gpa.free(spans);
    var at: usize = header_size + 8 * @as(usize, count);
    for (spans, 0..) |*span, index| {
        const length = std.mem.readInt(
            u64,
            bytes[header_size + 8 * index ..][0..8],
            .little,
        );
        if (length == 0 or length > bytes.len - at) return error.Truncated;
        span.* = bytes[at..][0..@intCast(length)];
        at += @intCast(length);
    }
    return spans;
}

// ---------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------

/// Code mapped into executable pages: the same recipe as the JIT's
/// own allocator (vendor/mir mir-code-alloc-default.c) — RWX pages,
/// on macOS with MAP_JIT and the per-thread write gate, instruction
/// caches invalidated after the copy.  Pages are OS-owned (munmap on
/// deinit), the address slice is `gpa`-owned.
pub const Loaded = struct {
    pages: []align(std.heap.page_size_min) u8,
    addresses: []*const anyopaque,

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        std.posix.munmap(self.pages);
        gpa.free(self.addresses);
        self.* = undefined;
    }
};

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, length: usize) void;
extern fn __clear_cache(start: *anyopaque, end: *anyopaque) void;

pub const MapError = error{Unsupported} || Allocator.Error || std.posix.MMapError;

/// Copy each span into fresh executable pages, 16-aligned (at least
/// as strict as any base alignment the generator assumed; the code
/// itself is position-independent — that is M1's guarantee).
pub fn map(gpa: Allocator, spans: []const []const u8) MapError!Loaded {
    if (!supported) return error.Unsupported;
    var total: usize = 0;
    for (spans) |span| total += std.mem.alignForward(usize, span.len, 16);
    const pages = try std.posix.mmap(
        null,
        std.mem.alignForward(usize, @max(total, 1), std.heap.page_size_min),
        .{ .READ = true, .WRITE = true, .EXEC = true },
        map_flags,
        -1,
        0,
    );
    errdefer std.posix.munmap(pages);
    const addresses = try gpa.alloc(*const anyopaque, spans.len);

    if (builtin.os.tag == .macos) pthread_jit_write_protect_np(0);
    var at: usize = 0;
    for (spans, addresses) |span, *address| {
        @memcpy(pages[at..][0..span.len], span);
        address.* = @ptrCast(&pages[at]);
        at += std.mem.alignForward(usize, span.len, 16);
    }
    if (builtin.os.tag == .macos) {
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(pages.ptr, pages.len);
    } else if (builtin.cpu.arch == .aarch64) {
        __clear_cache(pages.ptr, pages.ptr + pages.len);
    }
    return .{ .pages = pages, .addresses = addresses };
}

const map_flags: std.posix.MAP = if (builtin.os.tag == .macos)
    .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true }
else
    .{ .TYPE = .PRIVATE, .ANONYMOUS = true };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_keys: Keys = .{ .fingerprint = 7, .module_hash = 11, .text_hash = 13 };

test "an image round-trips its spans and keys" {
    const spans = [_][]const u8{ "one", "twotwo", "x" };
    const bytes = try encode(testing.allocator, &spans, test_keys);
    defer testing.allocator.free(bytes);

    const decoded = try decode(testing.allocator, bytes, test_keys, spans.len);
    defer testing.allocator.free(decoded);
    for (spans, decoded) |expected, got| {
        try testing.expectEqualSlices(u8, expected, got);
    }
}

test "stale, foreign, and damaged images are rejected" {
    const spans = [_][]const u8{"code"};
    const bytes = try encode(testing.allocator, &spans, test_keys);
    defer testing.allocator.free(bytes);

    // Every key mismatch has its own rejection, so a cache miss can
    // be told from damage when debugging.
    var wrong = test_keys;
    wrong.fingerprint = 8;
    try testing.expectError(error.WrongFingerprint, decode(testing.allocator, bytes, wrong, 1));
    wrong = test_keys;
    wrong.module_hash = 8;
    try testing.expectError(error.WrongModule, decode(testing.allocator, bytes, wrong, 1));
    wrong = test_keys;
    wrong.text_hash = 8;
    try testing.expectError(error.WrongCode, decode(testing.allocator, bytes, wrong, 1));
    try testing.expectError(error.WrongShape, decode(testing.allocator, bytes, test_keys, 2));

    const mangled = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(mangled);
    mangled[0] = 'X';
    try testing.expectError(error.WrongMagic, decode(testing.allocator, mangled, test_keys, 1));
    // A truncated body is caught by the hash; a truncated header by
    // the size check.
    try testing.expectError(error.Damaged, decode(testing.allocator, bytes[0 .. bytes.len - 1], test_keys, 1));
    try testing.expectError(error.Truncated, decode(testing.allocator, bytes[0..10], test_keys, 1));

    // One flipped bit anywhere in the body — the span table or the
    // machine code itself — must be a cache miss, never a jump into
    // corrupt code (this exact segfault happened before the body
    // hash existed).
    for ([_]usize{ header_size, bytes.len - 1 }) |flip| {
        const bitten = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(bitten);
        bitten[flip] ^= 0xFF;
        try testing.expectError(error.Damaged, decode(testing.allocator, bitten, test_keys, 1));
    }
}

test "mapping copies spans into aligned executable pages" {
    if (!supported) return;
    const spans = [_][]const u8{ "0123456789abcdef!", "short" };
    var loaded = try map(testing.allocator, &spans);
    defer loaded.deinit(testing.allocator);
    for (spans, loaded.addresses) |span, address| {
        const copied: [*]const u8 = @ptrCast(address);
        try testing.expectEqualSlices(u8, span, copied[0..span.len]);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(address) % 16);
    }
}
