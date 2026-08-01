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
//! first: the native fingerprint (`native.fingerprint()` — target,
//! layout offsets, service roster, MIR source/build identity), the
//! hash of the `.lc` bytes, and the hash of the lowered MIR text
//! (`native.textHash`) — lowering is pure and costs well under a
//! millisecond, so any lowering change invalidates every image
//! automatically, with no version constant to remember to bump.  A
//! stale or foreign image is simply ignored; the runner falls back to
//! code generation and rewrites it.  The header also carries a hash
//! of the body, so a torn write
//! or flipped bit is a clean cache miss instead of a jump into
//! corrupt machine code — the image meets the same bar as the .lc,
//! which re-verifies on every decode.  Like the .lc, what remains
//! out of scope is deliberate tampering: an image is trusted like
//! an executable.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Bump on any change to this file's layout.  Code generation is
/// covered independently by the native fingerprint and text hash.
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

/// Grow a serialized or mapped size without allowing wraparound to
/// turn a large input into a too-small allocation.
fn addSize(total: *usize, amount: usize) error{OutOfMemory}!void {
    total.* = std.math.add(usize, total.*, amount) catch return error.OutOfMemory;
}

fn alignForwardChecked(value: usize, alignment: usize) error{OutOfMemory}!usize {
    const with_slop = std.math.add(usize, value, alignment - 1) catch
        return error.OutOfMemory;
    return with_slop & ~(alignment - 1);
}

fn addAlignedSize(total: *usize, amount: usize, alignment: usize) error{OutOfMemory}!void {
    try addSize(total, try alignForwardChecked(amount, alignment));
}

// ---------------------------------------------------------------------------
// Format
// ---------------------------------------------------------------------------

/// Serialize one function-code span per function, packed after a
/// keyed header.  Caller owns the bytes.
pub fn encode(gpa: Allocator, spans: []const []const u8, keys: Keys) Allocator.Error![]u8 {
    if (spans.len > std.math.maxInt(u32)) return error.OutOfMemory;
    var total: usize = header_size;
    const span_table_size = std.math.mul(usize, @sizeOf(u64), spans.len) catch
        return error.OutOfMemory;
    try addSize(&total, span_table_size);
    for (spans) |span| try addSize(&total, span.len);
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
    const span_table_size = std.math.mul(usize, @sizeOf(u64), @as(usize, count)) catch
        return error.Truncated;
    const body_at = std.math.add(usize, header_size, span_table_size) catch
        return error.Truncated;
    if (bytes.len < body_at) return error.Truncated;

    const spans = try gpa.alloc([]const u8, count);
    errdefer gpa.free(spans);
    var table_at: usize = header_size;
    var at: usize = body_at;
    for (spans) |*span| {
        const length = std.mem.readInt(
            u64,
            bytes[table_at..][0..8],
            .little,
        );
        table_at += @sizeOf(u64);
        if (length == 0 or length > bytes.len - at) return error.Truncated;
        span.* = bytes[at..][0..@intCast(length)];
        at += @intCast(length);
    }
    // The image format is canonical: every byte after the header is
    // either one length word or function code.  Accepting ignored
    // suffixes would let distinct files describe the same image and
    // would hide interrupted/incorrect writers behind a valid hash.
    if (at != bytes.len) return error.WrongShape;
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

// ---------------------------------------------------------------------------
// Platform: executable memory
// ---------------------------------------------------------------------------
//
// Everything the OS needs to turn writable bytes into runnable code
// lives in one comptime-selected namespace, so `map` below is pure
// orchestration with no platform branch of its own — the same split
// the code generators use (aarch64 in codegen.zig, x86-64 in
// codegen_x86.zig).  Each namespace declares its own mmap flags, a
// write-gate (macOS arms per-thread W^X around the copy; nowhere
// else), and instruction-cache synchronization (needed on aarch64,
// a no-op on x86-64's coherent icache).  A platform's externs are
// declared *inside* its namespace, so a build for another platform
// never references — nor demands from the linker — a symbol it does
// not have.  Adding Windows (VirtualAlloc + FlushInstructionCache)
// is one more prong here and nothing else.

const CodeMemory = switch (builtin.os.tag) {
    .macos => MacosCodeMemory,
    .linux => LinuxCodeMemory,
    else => UnsupportedCodeMemory,
};

const MacosCodeMemory = struct {
    extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
    extern "c" fn pthread_jit_write_protect_supported_np() c_int;
    extern "c" fn sys_icache_invalidate(start: *anyopaque, length: usize) void;

    const map_flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };

    /// Open the per-thread write gate so the JIT pages accept the
    /// copy; the returned token says whether it was actually opened
    /// (older kernels lack the gate).
    fn openWrite() bool {
        if (pthread_jit_write_protect_supported_np() == 0) return false;
        pthread_jit_write_protect_np(0);
        return true;
    }

    fn closeWrite(opened: bool) void {
        if (opened) pthread_jit_write_protect_np(1);
    }

    fn syncInstructionCache(pages: []u8) void {
        sys_icache_invalidate(pages.ptr, pages.len);
    }
};

const LinuxCodeMemory = struct {
    // aarch64 needs an explicit cache flush after writing code; x86-64
    // has a coherent instruction cache, so the extern is referenced
    // only in the branch that needs it.
    extern fn __clear_cache(start: *anyopaque, end: *anyopaque) void;

    const map_flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };

    fn openWrite() bool {
        return false;
    }

    fn closeWrite(opened: bool) void {
        _ = opened;
    }

    fn syncInstructionCache(pages: []u8) void {
        if (builtin.cpu.arch == .aarch64) {
            __clear_cache(pages.ptr, pages.ptr + pages.len);
        }
    }
};

const UnsupportedCodeMemory = struct {
    const map_flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    fn openWrite() bool {
        return false;
    }
    fn closeWrite(opened: bool) void {
        _ = opened;
    }
    fn syncInstructionCache(pages: []u8) void {
        _ = pages;
    }
};

pub const MapError = error{Unsupported} || Allocator.Error || std.posix.MMapError;

/// Copy each span into fresh executable pages, 16-aligned (at least
/// as strict as any base alignment the generator assumed; the code
/// itself is position-independent — that is M1's guarantee).
pub fn map(gpa: Allocator, spans: []const []const u8) MapError!Loaded {
    if (!supported) return error.Unsupported;
    var total: usize = 0;
    for (spans) |span| try addAlignedSize(&total, span.len, 16);
    const mapped_size = try alignForwardChecked(@max(total, 1), std.heap.page_size_min);
    const pages = try std.posix.mmap(
        null,
        mapped_size,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        CodeMemory.map_flags,
        -1,
        0,
    );
    errdefer std.posix.munmap(pages);
    const addresses = try gpa.alloc(*const anyopaque, spans.len);

    // Copy behind the write gate, then re-arm it and make the new
    // bytes visible to the instruction fetcher — all through the
    // platform namespace, so this body names no OS or ISA.  The
    // errdefer re-arms only if the copy fails before the explicit
    // close below; on success the gate closes exactly once.
    var gate_open = CodeMemory.openWrite();
    errdefer CodeMemory.closeWrite(gate_open);
    var at: usize = 0;
    for (spans, addresses) |span, *address| {
        @memcpy(pages[at..][0..span.len], span);
        address.* = @ptrCast(&pages[at]);
        at += try alignForwardChecked(span.len, 16);
    }
    CodeMemory.closeWrite(gate_open);
    gate_open = false;
    CodeMemory.syncInstructionCache(pages);
    return .{ .pages = pages, .addresses = addresses };
}

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

test "an image rejects a validly hashed trailing suffix" {
    const spans = [_][]const u8{"code"};
    const encoded = try encode(testing.allocator, &spans, test_keys);
    defer testing.allocator.free(encoded);
    const extended = try testing.allocator.alloc(u8, encoded.len + 1);
    defer testing.allocator.free(extended);
    @memcpy(extended[0..encoded.len], encoded);
    extended[encoded.len] = 0xA5;
    std.mem.writeInt(
        u64,
        extended[32..40],
        std.hash.Wyhash.hash(0, extended[header_size..]),
        .little,
    );

    try testing.expectError(
        error.WrongShape,
        decode(testing.allocator, extended, test_keys, spans.len),
    );
}

test "image size arithmetic rejects overflow" {
    var total: usize = std.math.maxInt(usize) - 7;
    try testing.expectError(error.OutOfMemory, addSize(&total, 8));
    total = 0;
    try testing.expectError(
        error.OutOfMemory,
        addAlignedSize(&total, std.math.maxInt(usize), 16),
    );
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
