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
//! (docs/MEMORY.md, unchanged).
//!
//! **The text conveniences** — `file_read`, `file_write`, `file_append`,
//! unchanged in surface and meaning — are open-read-close over that
//! channel plus this file's own UTF-8 validation.  That validation used
//! to live in `apps/host.zig`, where only loom could say it; it lives
//! here now, so the interpreter, a compiled artifact, and every future
//! host agree byte-for-byte on what "not text" means.

const std = @import("std");
const heap = @import("heap.zig");
const runtime_text = @import("text.zig");
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
/// memory.  The same three `codegen/abi.zig`'s `Answer` gives, spelled
/// as a plain `i32` for the same reason `containers.ArgumentFn` is —
/// this file needs nothing from the host ABI but the calling
/// convention, and `runtime.zig` must not import the backend.
pub const yes: i32 = 1;
pub const no: i32 = 0;
pub const exhausted: i32 = -1;

pub const StandardFn = *const fn (
    context: ?*anyopaque,
    which: i64,
    handle: *i64,
) callconv(.c) i32;

pub const ProcessSpawnFn = *const fn (
    context: ?*anyopaque,
    command: [*]const u8,
    command_length: i64,
    handle: *i64,
) callconv(.c) i32;

pub const ProcessAskFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    answer: *i64,
) callconv(.c) i32;

pub const ProcessPlainFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
) callconv(.c) i32;

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
    /// One of the process's own byte streams as a handle: 0 standard
    /// input, 1 standard output, 2 standard error.  The handle rides
    /// `read`/`write`/`flush` like any other; the host's `close` for
    /// one is a safe no-op, because the descriptor belongs to the
    /// process, not the program.
    standard: ?StandardFn = null,
    /// The child doors (docs/STD.md): spawn answers a handle whose
    /// reads are the child's output and whose writes its input; the
    /// close a released handle runs kills a child still running.
    process_spawn: ?ProcessSpawnFn = null,
    process_ready: ?ProcessAskFn = null,
    process_wait: ?ProcessAskFn = null,
    process_finish_input: ?ProcessPlainFn = null,
    read: ?ReadFn = null,
    write: ?WriteFn = null,
    flush: ?FlushFn = null,
    close: ?CloseFn = null,
};

/// Call one host slot while holding this program's shared Effects
/// guard.  The guard belongs around the callback alone: allocations,
/// validation and whole-file loops stay outside it so another worker
/// can make progress between calls (docs/THREADS.md D9).
///
/// **A socket byte-op skips the guard entirely** (`guarded = false`):
/// a socket read blocks for a peer, and a worker blocked inside the
/// guard would freeze every other worker's host effects for the
/// duration.  The socket channel's callbacks are thread-safe by
/// contract (`sockets.zig`), which is what makes the skip sound.
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
    guarded: bool,
    handle: i64,
    into: []u8,
    filled: *i64,
) i32 {
    if (guarded) runtime.enterEffects();
    defer if (guarded) runtime.leaveEffects();
    return service(runtime.files.context, handle, into.ptr, @intCast(into.len), filled);
}

fn callWrite(
    runtime: *Runtime,
    service: WriteFn,
    guarded: bool,
    handle: i64,
    from: []const u8,
    written: *i64,
) i32 {
    if (guarded) runtime.enterEffects();
    defer if (guarded) runtime.leaveEffects();
    return service(runtime.files.context, handle, from.ptr, @intCast(from.len), written);
}

fn callFlush(runtime: *Runtime, service: FlushFn, guarded: bool, handle: i64) i32 {
    if (guarded) runtime.enterEffects();
    defer if (guarded) runtime.leaveEffects();
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
// The handle, as a reference-counted resource
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

/// `files.open(path, mode)` — a fresh handle carrying one strong reference.
///
/// Answers `null` when the world said no; the caller raises `io_failed`
/// naming the path, exactly as the whole-file services always did.
/// One standard stream as an owned handle resource.  The same object
/// road as `open` — the row's last release calls the host's close,
/// which for a standard handle is a no-op — so a program can hold,
/// share, and drop `os.stdin()` exactly like a file.
pub fn standard(runtime: *Runtime, which: i64) Error!?Value {
    const service = runtime.files.standard orelse return runtime.fail(.host_unavailable);
    if (runtime.files.close == null) return runtime.fail(.host_unavailable);
    var handle: i64 = heap.no_file;
    const answer = service(runtime.files.context, which, &handle);
    if (!try hostAnswer(runtime, answer)) return null;
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    const name = switch (which) {
        0 => "<stdin>",
        1 => "<stdout>",
        else => "<stderr>",
    };
    return try runtime.newFile(handle, name);
}

/// Spawn one child and answer its owned handle resource — `open`'s
/// road exactly, so releasing the last reference closes (kills) it.
pub fn spawn(runtime: *Runtime, command: []const u8) Error!?Value {
    const service = runtime.files.process_spawn orelse return runtime.fail(.host_unavailable);
    if (runtime.files.close == null) return runtime.fail(.host_unavailable);
    var handle: i64 = heap.no_file;
    const answer = service(runtime.files.context, command.ptr, @intCast(command.len), &handle);
    if (!try hostAnswer(runtime, answer)) return null;
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    return try runtime.newFile(handle, command);
}

/// One scalar question of a child: ready (0/1) or the exit status.
pub fn processAsk(
    runtime: *Runtime,
    service: ?ProcessAskFn,
    handle_value: Value,
) Error!?i64 {
    const asked = service orelse return runtime.fail(.host_unavailable);
    const raw = try handleOf(runtime, handle_value);
    var answer: i64 = 0;
    const said = asked(runtime.files.context, raw, &answer);
    if (!try hostAnswer(runtime, said)) return null;
    return answer;
}

pub fn processFinishInput(runtime: *Runtime, handle_value: Value) Error!?void {
    const service = runtime.files.process_finish_input orelse return runtime.fail(.host_unavailable);
    const raw = try handleOf(runtime, handle_value);
    const said = service(runtime.files.context, raw);
    if (!try hostAnswer(runtime, said)) return null;
}

pub fn open(runtime: *Runtime, path: []const u8, mode: i64) Error!?Value {
    const service = runtime.files.open orelse return runtime.fail(.host_unavailable);
    // Opening a resource without a last-release close service would
    // violate the resource contract even on the successful path.  Like
    // the worker channel's spawn/join pair, this pair fails closed
    // before the host acquires anything.
    const closer = runtime.files.close orelse return runtime.fail(.host_unavailable);
    var handle: i64 = -1;
    const answer = callOpen(runtime, service, path, mode, &handle);
    // A well-behaved non-yes callback leaves the output untouched.  If a
    // hostile callback nevertheless publishes a raw handle, close it before
    // interpreting the answer so no external resource can escape through a
    // malformed or exhausted branch.
    if (answer != yes and handle != heap.no_file) closeFailedOpen(runtime, closer, handle);
    if (!try hostAnswer(runtime, answer)) return null;
    // The raw handle belongs here until the object row takes it.  Either
    // allocation in `newFile` may fail; neither may leave the host handle
    // behind.
    errdefer closeFailedOpen(runtime, closer, handle);
    // `-1` is the runtime's post-close sentinel.  Publishing it as a live
    // file would make scope teardown skip the host callback entirely, so a
    // malformed successful open is rejected before a resource row exists.
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    return try runtime.newFile(handle, path);
}

/// `f.read(into)` — fill an `array[u8, n]` and answer how many bytes
/// landed.  Zero means the stream is finished.  Serves files and
/// connected sockets alike: the byte channel is the handle's, and the
/// resource kind decides only whether the Effects guard is held.
pub fn read(runtime: *Runtime, held: Value, buffer: Value) Error!?i64 {
    const service = runtime.files.read orelse return runtime.fail(.host_unavailable);
    const resource = try byteResourceOf(runtime, held);
    // Re-resolved after the handle, because both resolves can trap and
    // neither allocates: the pointer stays good across the pair.
    const into_object = try runtime.resolveMutable(buffer);
    const into = switch (into_object.data) {
        .array => if (into_object.elements.kind == .u8)
            into_object.elements
        else
            return runtime.fail(.not_owned),
        .instance, .list, .map, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    var filled: i64 = 0;
    const cells = into.cells(u8);
    if (!try hostAnswer(runtime, callRead(
        runtime,
        service,
        resource.kind == .file,
        resource.handle,
        cells,
        &filled,
    ))) return null;
    return try hostCount(runtime, filled, cells.len);
}

/// `f.write(from, count)` — write the first `count` bytes of an
/// `array[u8, n]` and answer how many landed.
pub fn write(runtime: *Runtime, held: Value, buffer: Value, count: i64) Error!?i64 {
    const service = runtime.files.write orelse return runtime.fail(.host_unavailable);
    const resource = try byteResourceOf(runtime, held);
    const from_object = try runtime.resolve(buffer);
    const from = switch (from_object.data) {
        .array => if (from_object.elements.kind == .u8)
            from_object.elements
        else
            return runtime.fail(.not_owned),
        .instance, .list, .map, .builder, .file, .task => return runtime.fail(.not_owned),
    };
    const cells = from.cells(u8);
    if (count < 0 or count > cells.len) return runtime.fail(.index_bounds);
    var written: i64 = 0;
    if (!try hostAnswer(runtime, callWrite(
        runtime,
        service,
        resource.kind == .file,
        resource.handle,
        cells[0..@intCast(count)],
        &written,
    ))) return null;
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
/// not success.  Public because `sockets.zig` validates its channel with
/// the same rule — one definition of what an untrusted answer means.
pub fn hostAnswer(runtime: *Runtime, answer: i32) Error!bool {
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
    const resource = try byteResourceOf(runtime, held);
    return try hostAnswer(runtime, callFlush(runtime, service, resource.kind == .file, resource.handle));
}

/// The resource behind a Luce handle, or a trap.  Files and connected
/// sockets carry the byte channel; a listener, window, or surface does
/// not, and answers `not_owned` — asking a door for bytes is a type
/// error the verifier normally catches, met here again for IR that
/// arrived some other way.  A handle used after its scope closed it
/// fails inside `resolve` as `use_after_free`, the same mistake it is
/// everywhere else.
fn byteResourceOf(runtime: *Runtime, held: Value) Error!heap.Object.File {
    const object = try runtime.resolve(held);
    return switch (object.data) {
        .file => |held_file| switch (held_file.kind) {
            .file, .socket => held_file,
            .window, .surface, .listener => runtime.fail(.not_owned),
        },
        .instance, .list, .map, .array, .builder, .task => return runtime.fail(.not_owned),
    };
}

/// The file-kind handle alone, for the whole-file conveniences that
/// opened it themselves.
fn handleOf(runtime: *Runtime, held: Value) Error!i64 {
    const resource = try byteResourceOf(runtime, held);
    if (resource.kind != .file) return runtime.fail(.not_owned);
    return resource.handle;
}

/// The path a handle was opened at, for the sentence an `io_failed`
/// carries.  Answers empty text for a handle that is no longer live
/// rather than trapping: this is only ever asked while an error is
/// being built, and losing the name is better than losing the error.
pub fn pathOf(runtime: *Runtime, held: Value) []const u8 {
    const object = runtime.resolve(held) catch return "";
    return switch (object.data) {
        .file => |held_file| held_file.path,
        .instance, .list, .map, .array, .builder, .task => "",
    };
}

/// `file_read(path)` — the whole file as a `str`, or null when it
/// could not be read *as a string*: the world said no, it is larger
/// than the convenience carries, or its bytes are not text.
///
/// Nothing is normalized: no BOM is stripped and no CRLF is rewritten.
/// A program that reads a CSV and writes it again gets the same bytes
/// out.
pub fn readText(runtime: *Runtime, path: []const u8) Error!?Value {
    return readTextLimited(runtime, path, max_text_file);
}

fn readTextLimited(runtime: *Runtime, path: []const u8, limit: usize) Error!?Value {
    const handle = (try open(runtime, path, @intFromEnum(Mode.read))) orelse return null;
    defer runtime.freeObject(handle.asObject());

    var loaded: std.ArrayList(u8) = .empty;
    defer loaded.deinit(runtime.objects);
    while (true) {
        const before = loaded.items.len;
        var filled: i64 = 0;
        const service = runtime.files.read orelse return runtime.fail(.host_unavailable);
        const handle_id = try handleOf(runtime, handle);

        if (before >= limit) {
            // Do not grow the accumulation buffer past the documented cap
            // merely to discover whether the file has one more byte.  A
            // one-byte probe distinguishes an exact-limit file from an
            // oversized one without raising the peak allocation.
            var probe: [1]u8 = undefined;
            const answered = callRead(runtime, service, true, handle_id, &probe, &filled);
            if (!try hostAnswer(runtime, answered)) return null;
            const taken = try hostCount(runtime, filled, probe.len);
            if (taken != 0) return null;
            break;
        }

        const capacity = @min(read_chunk, limit - before);
        try loaded.resize(runtime.objects, before + capacity);
        const answered = callRead(
            runtime,
            service,
            true,
            handle_id,
            loaded.items[before..],
            &filled,
        );
        if (!try hostAnswer(runtime, answered)) return null;
        const taken = try hostCount(runtime, filled, capacity);
        loaded.shrinkRetainingCapacity(before + @as(usize, @intCast(taken)));
        if (taken == 0) break;
    }
    if (loaded.items.len > limit) return null;
    if (!runtime_text.isValid(loaded.items)) return null;
    return try runtime.ownValue(Value.ofStr(loaded.items));
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
            true,
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
    return try hostAnswer(runtime, callFlush(runtime, flusher, true, try handleOf(runtime, handle)));
}

test "whole-file reads stay within their content limit" {
    const Host = struct {
        oversized: bool,
        reads: usize = 0,
        opened: usize = 0,
        closed: usize = 0,

        fn open(
            context: ?*anyopaque,
            _: [*]const u8,
            _: i64,
            _: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.opened += 1;
            handle.* = 41;
            return yes;
        }

        fn read(
            context: ?*anyopaque,
            _: i64,
            into: [*]u8,
            capacity: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.reads == 0) {
                const amount: usize = @intCast(capacity);
                for (0..amount) |index| into[index] = 'a';
                filled.* = capacity;
                self.reads += 1;
                return yes;
            }
            self.reads += 1;
            filled.* = if (self.oversized) 1 else 0;
            return yes;
        }

        fn close(context: ?*anyopaque, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closed += 1;
            return yes;
        }
    };

    for ([_]bool{ false, true }) |oversized| {
        var backing: [4096]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&backing);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        var runtime: Runtime = .init(.{
            .arena = arena.allocator(),
            .objects = fixed.allocator(),
        });
        var host: Host = .{ .oversized = oversized };
        runtime.files = .{
            .context = &host,
            .open = Host.open,
            .read = Host.read,
            .close = Host.close,
        };

        const answer = try readTextLimited(&runtime, "bounded.txt", 5);
        if (oversized) {
            try std.testing.expect(answer == null);
        } else {
            const held = answer orelse return error.TestExpected;
            try std.testing.expectEqualStrings("aaaaa", held.asStr());
            runtime.dropStorage(held);
        }
        try std.testing.expectEqual(@as(usize, 1), host.opened);
        try std.testing.expectEqual(@as(usize, 1), host.closed);
        try std.testing.expectEqual(@as(u32, 0), runtime.live);
        runtime.deinit();
        arena.deinit();
    }
}
