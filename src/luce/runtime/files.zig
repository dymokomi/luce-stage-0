//! File handles: the host's byte channel, and text as a validation the
//! language performs over it (docs/BYTES.md R2, R4, R5).
//!
//! Three things live here, and they are one idea in three sizes.
//!
//! **The channel** is five host slots — open, read into a caller's
//! buffer answering the count, write from one, flush, close — carrying
//! raw bytes with no opinion about encoding.  The runtime holds them
//! for the whole run rather than being handed them at each call, for a
//! reason that decides the shape: a handle is closed when its owning
//! scope ends, and that release happens inside `Runtime.freeObject`,
//! where no generated code is standing to pass anything in.
//!
//! **The handle** is an ordinary heap object whose create is `open` and
//! whose scope-end release is `close`, so a file cannot leak by the
//! same construction that keeps every list from leaking, and a use
//! after close traps `use_after_free` because it is the same mistake
//! (docs/OWNERSHIP.md, unchanged).
//!
//! **The text conveniences** — `file_read`, `file_write`, `file_append`,
//! unchanged in surface and meaning — are open-read-close over that
//! channel plus this file's own UTF-8 validation.  That validation used
//! to live in `apps/host.zig`, where only loom could say it; it lives
//! here now, so the interpreter, a compiled artifact, and every future
//! host agree byte-for-byte on what "not text" means.

const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

// ---------------------------------------------------------------------------
// The channel
// ---------------------------------------------------------------------------

/// What a handle is opened for.  The number is what crosses the C
/// boundary; a host that does not recognise one says no.
pub const Mode = enum(i64) {
    /// Read from the start; the file must exist.
    read = 0,
    /// Write from the start, creating the file and truncating it.
    write = 1,
    /// Write at the end, creating the file if it is not there.
    append = 2,
    _,
};

/// What every slot here answers: 1 yes, 0 no, -1 the host ran out of
/// memory.  The same three `08_llvm/abi.zig`'s `Answer` gives, spelled
/// as a plain `i32` for the same reason `containers.ArgumentFn` is —
/// this file needs nothing from the host ABI but the calling
/// convention, and `runtime.zig` must not import the backend.
pub const yes: i32 = 1;
pub const no: i32 = 0;
pub const exhausted: i32 = -1;

pub const OpenFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    mode: i64,
    handle: *i64,
) callconv(.c) i32;

/// Fill `into` with at most `capacity` bytes and say how many landed.
/// Zero with a `yes` is the end of the file — the C shape, and the one
/// a socket will want too (docs/BYTES.md R4).
pub const ReadFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    into: [*]u8,
    capacity: i64,
    filled: *i64,
) callconv(.c) i32;

/// Write `length` bytes and say how many landed.  A short write is not
/// a failure; the caller loops.
pub const WriteFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    from: [*]const u8,
    length: i64,
    written: *i64,
) callconv(.c) i32;

pub const FlushFn = *const fn (context: ?*anyopaque, handle: i64) callconv(.c) i32;

/// Close a handle.  Called from `freeObject`, which cannot fail and has
/// nobody to report to, so the answer is read by nothing: a host that
/// cannot close has already lost the file.
pub const CloseFn = *const fn (context: ?*anyopaque, handle: i64) callconv(.c) i32;

/// The host's handle channel, installed once at the start of a run.
/// Every slot is optional and fail-closed like every other effect: a
/// missing one traps `host_unavailable` rather than touching anything.
pub const Channel = struct {
    context: ?*anyopaque = null,
    open: ?OpenFn = null,
    read: ?ReadFn = null,
    write: ?WriteFn = null,
    flush: ?FlushFn = null,
    close: ?CloseFn = null,
};

/// Call one host slot while holding this program's shared Effects
/// guard.  The guard belongs around the callback alone: allocations,
/// validation and whole-file loops stay outside it so another worker
/// can make progress between calls (docs/THREADS.md D9).
fn callOpen(
    runtime: *Runtime,
    service: OpenFn,
    path: []const u8,
    mode: i64,
    handle: *i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.files.context, path.ptr, @intCast(path.len), mode, handle);
}

fn callRead(
    runtime: *Runtime,
    service: ReadFn,
    handle: i64,
    into: []u8,
    filled: *i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.files.context, handle, into.ptr, @intCast(into.len), filled);
}

fn callWrite(
    runtime: *Runtime,
    service: WriteFn,
    handle: i64,
    from: []const u8,
    written: *i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.files.context, handle, from.ptr, @intCast(from.len), written);
}

fn callFlush(runtime: *Runtime, service: FlushFn, handle: i64) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.files.context, handle);
}

/// Give back a raw handle whose open succeeded but which could not be
/// attached to a Luce resource.  Close cannot report a failure at this
/// boundary, matching scope-end close in `Runtime.freeObject`.
fn closeFailedOpen(runtime: *Runtime, service: CloseFn, handle: i64) void {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    _ = service(runtime.files.context, handle);
}

// ---------------------------------------------------------------------------
// The handle, as a scope-owned object
// ---------------------------------------------------------------------------

/// What a whole-file text read will carry into memory before it gives
/// up.  A host policy rather than a language limit, kept because the
/// convenience is defined as "the whole file in one string": a program
/// that wants more wants the byte channel, which is now there to want.
pub const max_text_file: usize = 64 * 1024 * 1024;

/// How much of a file one read asks for.  Big enough that a whole-file
/// read of an ordinary file is a handful of calls, small enough that
/// the buffer is not itself the memory problem.
const read_chunk: usize = 64 * 1024;

/// `files.open(path, mode)` — a fresh handle the caller's scope owns.
///
/// Answers `null` when the world said no; the caller raises `io_failed`
/// naming the path, exactly as the whole-file services always did.
pub fn open(runtime: *Runtime, path: []const u8, mode: i64) Error!?Value {
    const service = runtime.files.open orelse return runtime.fail(.host_unavailable);
    // Opening a scope-owned resource without a way to close it would
    // violate the resource contract even on the successful path.  Like
    // the worker channel's spawn/join pair, this pair fails closed
    // before the host acquires anything.
    const closer = runtime.files.close orelse return runtime.fail(.host_unavailable);
    var handle: i64 = -1;
    if (!try hostAnswer(runtime, callOpen(runtime, service, path, mode, &handle))) return null;
    // The raw handle belongs here until the object row takes it.  Either
    // allocation in `newFile` may fail; neither may leave the host handle
    // behind.
    errdefer closeFailedOpen(runtime, closer, handle);
    return try runtime.newFile(handle, path);
}

/// `f.read(into)` — fill an `array(byte, n)` and answer how many bytes
/// landed.  Zero means the file is finished.
pub fn read(runtime: *Runtime, held: Value, buffer: Value) Error!?i64 {
    const service = runtime.files.read orelse return runtime.fail(.host_unavailable);
    const handle = try handleOf(runtime, held);
    // Re-resolved after the handle, because both resolves can trap and
    // neither allocates: the pointer stays good across the pair.
    const into = (try runtime.resolveMutable(buffer)).elements;
    var filled: i64 = 0;
    const cells = into.cells(u8);
    if (!try hostAnswer(runtime, callRead(runtime, service, handle, cells, &filled))) return null;
    return try hostCount(runtime, filled, cells.len);
}

/// `f.write(from, count)` — write the first `count` bytes of an
/// `array(byte, n)` and answer how many landed.
pub fn write(runtime: *Runtime, held: Value, buffer: Value, count: i64) Error!?i64 {
    const service = runtime.files.write orelse return runtime.fail(.host_unavailable);
    const handle = try handleOf(runtime, held);
    const from = (try runtime.resolve(buffer)).elements;
    const cells = from.cells(u8);
    if (count < 0 or count > cells.len) return runtime.fail(.index_bounds);
    var written: i64 = 0;
    if (!try hostAnswer(
        runtime,
        callWrite(runtime, service, handle, cells[0..@intCast(count)], &written),
    )) return null;
    return try hostCount(runtime, written, @intCast(count));
}

/// Validate a byte count returned by an untrusted host callback before it can
/// become a slice bound or a progress increment.  The callback receives the
/// capacity, so a negative or oversized answer is a protocol violation, not
/// an ordinary I/O refusal; fail closed before the runtime performs any
/// arithmetic with it.
fn hostCount(runtime: *Runtime, count: i64, capacity: usize) Error!i64 {
    const measured = std.math.cast(usize, count) orelse
        return runtime.fail(.host_unavailable);
    if (measured > capacity) return runtime.fail(.host_unavailable);
    return count;
}

/// Validate the answer itself before a file operation interprets it.  The C
/// callback is an untrusted enum-shaped integer: only the three published
/// values are meaningful.  In particular, an arbitrary negative value is a
/// malformed host, not memory exhaustion, and an arbitrary positive value is
/// not success.
fn hostAnswer(runtime: *Runtime, answer: i32) Error!bool {
    return switch (answer) {
        yes => true,
        no => false,
        exhausted => blk: {
            runtime.exhausted = true;
            break :blk error.OutOfMemory;
        },
        else => runtime.fail(.host_unavailable),
    };
}

/// `f.flush()` — everything written so far is on the device.
pub fn flush(runtime: *Runtime, held: Value) Error!bool {
    const service = runtime.files.flush orelse return runtime.fail(.host_unavailable);
    const handle = try handleOf(runtime, held);
    return try hostAnswer(runtime, callFlush(runtime, service, handle));
}

/// The host handle behind a Luce one, or a trap.  A handle used after
/// its scope closed it fails here as `use_after_free`, which is what
/// `resolve` answers for every other object and is the same mistake.
fn handleOf(runtime: *Runtime, held: Value) Error!i64 {
    const object = try runtime.resolve(held);
    return switch (object.data) {
        .file => |held_file| held_file.handle,
        // The verifier admits only a `file` here.
        .list, .map, .array, .builder, .task => unreachable,
    };
}

/// The path a handle was opened at, for the sentence an `io_failed`
/// carries.  Answers empty text for a handle that is no longer live
/// rather than trapping: this is only ever asked while an error is
/// being built, and losing the name is better than losing the error.
pub fn pathOf(runtime: *Runtime, held: Value) []const u8 {
    const object = runtime.resolve(held) catch return "";
    return switch (object.data) {
        .file => |held_file| held_file.path,
        .list, .map, .array, .builder, .task => "",
    };
}

// ---------------------------------------------------------------------------
// Text, as a validation over the bytes
// ---------------------------------------------------------------------------

/// True when `bytes` can be a Luce `string`.
///
/// **The one place this sentence is written.**  A `string` is valid
/// UTF-8, which is what lets `s[a:b]` be checked against character
/// boundaries and `len` mean what it says; a half-read JPEG handed over
/// as text would make both of those lies, and the trap they raise would
/// fire on the contents of a file rather than on anything the program
/// did.  Both engines reach this function, so "not text" is one
/// decision rather than each host's opinion.
pub fn isText(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

/// `parse_string(xs)` — a `list(byte)` as text, or absent when the
/// bytes are not valid UTF-8 (docs/BYTES.md R3).
///
/// The `parse_int` shape, for the `parse_int` reason: "not text" is
/// the same reason every time and the name already implies it, so
/// absence carries all the information there is.  The bytes are copied
/// into storage the answer owns, like every other value that leaves a
/// container.
pub fn parseString(runtime: *Runtime, held: Value) Error!Value {
    const object = try runtime.resolve(held);
    const stored = object.elements;
    // A packed `list(byte)` *is* its bytes, which is the whole point
    // of R1: the validator reads the run in place and nothing is
    // gathered first.  The verifier admits nothing else here.
    const bytes = stored.cells(u8);
    if (!isText(bytes)) return Value.none;
    return runtime.ownValue(Value.ofString(bytes));
}

/// `file_read(path)` — the whole file as a `string`, or null when it
/// could not be read *as a string*: the world said no, it is larger
/// than the convenience carries, or its bytes are not text.
///
/// Nothing is normalized: no BOM is stripped and no CRLF is rewritten.
/// A program that reads a CSV and writes it again gets the same bytes
/// out.
pub fn readText(runtime: *Runtime, path: []const u8) Error!?Value {
    const handle = (try open(runtime, path, @intFromEnum(Mode.read))) orelse return null;
    defer runtime.freeObject(handle.asObject());

    var loaded: std.ArrayList(u8) = .empty;
    defer loaded.deinit(runtime.objects);
    while (true) {
        const before = loaded.items.len;
        if (before > max_text_file) return null;
        try loaded.resize(runtime.objects, before + read_chunk);
        var filled: i64 = 0;
        const service = runtime.files.read orelse return runtime.fail(.host_unavailable);
        const answered = callRead(
            runtime,
            service,
            try handleOf(runtime, handle),
            loaded.items[before..],
            &filled,
        );
        if (!try hostAnswer(runtime, answered)) return null;
        const taken = try hostCount(runtime, filled, loaded.items.len - before);
        loaded.shrinkRetainingCapacity(before + @as(usize, @intCast(taken)));
        if (taken == 0) break;
    }
    if (loaded.items.len > max_text_file) return null;
    if (!isText(loaded.items)) return null;
    return try runtime.ownValue(Value.ofString(loaded.items));
}

/// `file_write(path, text)` and `file_append(path, text)` — the whole
/// of a file, or added to the end of one.  Both are open-write-close
/// over the same channel, and the mode is the only difference.
pub fn writeText(runtime: *Runtime, path: []const u8, text: []const u8, mode: Mode) Error!bool {
    const handle = (try open(runtime, path, @intFromEnum(mode))) orelse return false;
    defer runtime.freeObject(handle.asObject());
    const service = runtime.files.write orelse return runtime.fail(.host_unavailable);
    const flusher = runtime.files.flush orelse return runtime.fail(.host_unavailable);
    var sent: usize = 0;
    while (sent < text.len) {
        var written: i64 = 0;
        const answered = callWrite(
            runtime,
            service,
            try handleOf(runtime, handle),
            text[sent..],
            &written,
        );
        if (!try hostAnswer(runtime, answered)) return false;
        const moved = try hostCount(runtime, written, text.len - sent);
        // A host that accepts nothing forever is a host that has
        // stopped writing; say so rather than spin.
        if (moved == 0) return false;
        sent += @intCast(moved);
    }
    return try hostAnswer(runtime, callFlush(runtime, flusher, try handleOf(runtime, handle)));
}
