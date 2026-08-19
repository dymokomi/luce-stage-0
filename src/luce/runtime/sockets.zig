//! Socket handles: the host's transport channel (docs/NETWORK.md).
//!
//! A socket is the file pattern worn by a network endpoint: an ordinary
//! heap resource whose create is `connect` (or `accept`), whose
//! scope-end release closes the descriptor, and whose bytes travel the
//! same five-slot handle channel files use — `files.zig` reads and
//! writes a connected socket without a second byte protocol, which is
//! why those slots were named for the handle and not for the file.
//! This file owns only what is socket-shaped: making endpoints, and the
//! listener that answers them.
//!
//! **The concurrency contract is the one deliberate difference from the
//! file channel, and it is load-bearing.**  A file callback runs under
//! the program's shared Effects guard; a socket callback must not,
//! because `accept` and a socket `read` block for a *peer* — seconds,
//! or forever — and a worker blocked inside the guard would freeze
//! every other worker's print and file I/O for the duration
//! (docs/THREADS.md D9 names the guard; `workers.zig` holds it).  So
//! this channel's callbacks take no lock here and MAY BE ENTERED
//! CONCURRENTLY from different runtimes: the host keeps its handle
//! registry behind its own short-held mutex and performs the blocking
//! system call outside every lock.  That is safe on the language side
//! because a resource never crosses a worker boundary, so the one
//! socket a blocked read holds can never be closed by another thread —
//! the only concurrency is *different* sockets on *different* workers,
//! which is exactly what the host mutex serializes registry access for.

const std = @import("std");
const heap = @import("heap.zig");
const files = @import("files.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

/// The three-valued answer every slot gives, shared with the file
/// channel: 1 yes, 0 no, -1 the host ran out of memory.
const yes = files.yes;

/// Open a TCP connection to `host:port`.  Name resolution happens
/// behind this slot — a program says where it wants to go and the host
/// owns how an address is found and which family answers — so no
/// address vocabulary crosses the boundary.  Blocking; thread-safe.
pub const ConnectFn = *const fn (
    context: ?*anyopaque,
    host: [*]const u8,
    host_length: i64,
    port: i64,
    handle: *i64,
) callconv(.c) i32;

/// Open a listener on `port`, on every interface.  Port `0` asks the
/// host for an ephemeral port; `port_of` answers which one landed.
pub const ListenFn = *const fn (
    context: ?*anyopaque,
    port: i64,
    handle: *i64,
) callconv(.c) i32;

/// Wait for one connection on a listener and answer its handle.
/// Blocking; thread-safe; callable concurrently on one shared host
/// listener from several workers — the pre-fork accept shape a
/// multithreaded server needs.
pub const AcceptFn = *const fn (
    context: ?*anyopaque,
    listener: i64,
    handle: *i64,
) callconv(.c) i32;

/// The port a listener actually holds — the answer to `listen(0)`.
pub const PortFn = *const fn (
    context: ?*anyopaque,
    listener: i64,
    port: *i64,
) callconv(.c) i32;

/// Close a socket or listener handle.  Called from `freeObject` where
/// no engine is standing and, unlike the file close, without the
/// Effects guard — a close must never queue behind another worker's
/// blocked read.
pub const CloseFn = *const fn (context: ?*anyopaque, handle: i64) callconv(.c) i32;

/// The host's socket channel, installed once at the start of a run.
/// Every slot is optional and fail-closed: a missing one traps
/// `host_unavailable` rather than touching anything.
pub const Channel = struct {
    context: ?*anyopaque = null,
    connect: ?ConnectFn = null,
    listen: ?ListenFn = null,
    accept: ?AcceptFn = null,
    port_of: ?PortFn = null,
    close: ?CloseFn = null,
};

/// How long a name a `connect` will carry into the label an `io_failed`
/// names.  A label, not a protocol limit: the full host text still
/// crosses to the callback.
const max_label: usize = 256;

/// `network.connect(host, port)` — a fresh connected-socket handle
/// carrying one strong reference, or null when the world said no.
pub fn connect(runtime: *Runtime, host: []const u8, port: i64) Error!?Value {
    const service = runtime.sockets.connect orelse return runtime.fail(.host_unavailable);
    // A resource without a close service would violate the resource
    // contract even on the successful path; fail closed before the
    // host acquires anything, as `files.open` and `spawn` do.
    const closer = runtime.sockets.close orelse return runtime.fail(.host_unavailable);
    var handle: i64 = heap.no_file;
    const answer = service(runtime.sockets.context, host.ptr, @intCast(host.len), port, &handle);
    if (answer != yes and handle != heap.no_file) _ = closer(runtime.sockets.context, handle);
    if (!try files.hostAnswer(runtime, answer)) return null;
    errdefer _ = closer(runtime.sockets.context, handle);
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    const label = try endpointLabel(runtime, host, port);
    defer runtime.objects.free(label);
    return try runtime.newResource(handle, label, .socket);
}

/// `network.listen(port)` — a fresh listener handle, or null.
pub fn listen(runtime: *Runtime, port: i64) Error!?Value {
    const service = runtime.sockets.listen orelse return runtime.fail(.host_unavailable);
    const closer = runtime.sockets.close orelse return runtime.fail(.host_unavailable);
    var handle: i64 = heap.no_file;
    const answer = service(runtime.sockets.context, port, &handle);
    if (answer != yes and handle != heap.no_file) _ = closer(runtime.sockets.context, handle);
    if (!try files.hostAnswer(runtime, answer)) return null;
    errdefer _ = closer(runtime.sockets.context, handle);
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    const label = try endpointLabel(runtime, "", port);
    defer runtime.objects.free(label);
    return try runtime.newResource(handle, label, .listener);
}

/// `listener.accept()` — one connection, when a peer arrives.  Blocks
/// without the Effects guard; see the module doc for why that is safe.
pub fn accept(runtime: *Runtime, held: Value) Error!?Value {
    const service = runtime.sockets.accept orelse return runtime.fail(.host_unavailable);
    const closer = runtime.sockets.close orelse return runtime.fail(.host_unavailable);
    const object = try runtime.resolve(held);
    const listener = switch (object.data) {
        .file => |resource| if (resource.kind == .listener)
            resource.handle
        else
            return runtime.fail(.not_owned),
        .instance, .list, .map, .array, .builder, .task, .channel => return runtime.fail(.not_owned),
    };
    // The listener's label is borrowed for the error message only; the
    // accepted socket gets a label of its own so a later read failure
    // names the connection, not the door it came through.
    const door = object.data.file.path;
    var handle: i64 = heap.no_file;
    const answer = service(runtime.sockets.context, listener, &handle);
    if (answer != yes and handle != heap.no_file) _ = closer(runtime.sockets.context, handle);
    if (!try files.hostAnswer(runtime, answer)) return null;
    errdefer _ = closer(runtime.sockets.context, handle);
    if (handle == heap.no_file) return runtime.fail(.host_unavailable);
    const label = try std.fmt.allocPrint(runtime.objects, "accepted on {s}", .{door});
    defer runtime.objects.free(label);
    return try runtime.newResource(handle, label, .socket);
}

/// `listener.port()` — which port the listener holds, which is the
/// whole point of `listen(0)`.
pub fn portOf(runtime: *Runtime, held: Value) Error!?i64 {
    const service = runtime.sockets.port_of orelse return runtime.fail(.host_unavailable);
    const object = try runtime.resolve(held);
    const listener = switch (object.data) {
        .file => |resource| if (resource.kind == .listener)
            resource.handle
        else
            return runtime.fail(.not_owned),
        .instance, .list, .map, .array, .builder, .task, .channel => return runtime.fail(.not_owned),
    };
    var port: i64 = 0;
    if (!try files.hostAnswer(runtime, service(runtime.sockets.context, listener, &port))) return null;
    if (port < 0 or port > 65535) return runtime.fail(.host_unavailable);
    return port;
}

/// Close a socket-kind resource from the ARC sweep.  No Effects guard,
/// deliberately: see the module doc.
pub fn close(runtime: *Runtime, resource: heap.Object.File) void {
    const service = runtime.sockets.close orelse return;
    _ = service(runtime.sockets.context, resource.handle);
}

/// The name an `io_failed` will carry for an endpoint: `host:port`, or
/// `:port` for a listener, truncated to a label-sized prefix.
fn endpointLabel(runtime: *Runtime, host: []const u8, port: i64) Error![]u8 {
    const shown = host[0..@min(host.len, max_label)];
    return std.fmt.allocPrint(runtime.objects, "{s}:{d}", .{ shown, port });
}
