//! The window and GPU host channel.
//!
//! `std.ui` and `std.gpu` deliberately do not know about Metal, Vulkan, or
//! a window-system handle.  They receive the same ARC resource shape
//! as `std.files`; this module is the one place that turns those resources
//! into host callbacks and translates a refused operation into Luce's normal
//! error channel.  A host that does not provide the channel fails closed with
//! `host_unavailable` rather than manufacturing a headless window.

const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

pub const yes: i32 = 1;
pub const no: i32 = 0;
pub const exhausted: i32 = -1;

/// Backend identifiers are intentionally a small stable wire vocabulary.
/// The standard library names them with an enum; the runtime only validates
/// the number and never needs to know a vendor API.
pub const Backend = enum(i64) {
    metal = 0,
    vulkan = 1,
    headless = 2,
    _,
};

pub const BackendFn = *const fn (
    context: ?*anyopaque,
    backend: *i64,
) callconv(.c) i32;

pub const WindowOpenFn = *const fn (
    context: ?*anyopaque,
    title: [*]const u8,
    title_length: i64,
    width: i64,
    height: i64,
    handle: *i64,
) callconv(.c) i32;

pub const WindowSurfaceFn = *const fn (
    context: ?*anyopaque,
    window: i64,
    surface: *i64,
) callconv(.c) i32;

pub const SurfaceSizeFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    axis: i64,
    size: *i64,
) callconv(.c) i32;

pub const SurfaceClearFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) callconv(.c) i32;

pub const SurfaceFillRectFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) callconv(.c) i32;

pub const SurfacePresentFn = *const fn (
    context: ?*anyopaque,
    surface: i64,
) callconv(.c) i32;

/// Window and surface handles have their own close callback.  Keeping it
/// beside the creation channel means a native window can be released by the
/// same ownership walk that closes a file, without teaching the language
/// about platform handles.
pub const CloseFn = *const fn (
    context: ?*anyopaque,
    handle: i64,
    kind: i64,
) callconv(.c) i32;

pub const Channel = struct {
    context: ?*anyopaque = null,
    backend: ?BackendFn = null,
    window_open: ?WindowOpenFn = null,
    window_surface: ?WindowSurfaceFn = null,
    surface_size: ?SurfaceSizeFn = null,
    surface_clear: ?SurfaceClearFn = null,
    surface_fill_rect: ?SurfaceFillRectFn = null,
    surface_present: ?SurfacePresentFn = null,
    close: ?CloseFn = null,
};

fn callBackend(runtime: *Runtime, service: BackendFn, selected: *i64) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, selected);
}

fn callWindowOpen(
    runtime: *Runtime,
    service: WindowOpenFn,
    title: []const u8,
    width: i64,
    height: i64,
    handle: *i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, title.ptr, @intCast(title.len), width, height, handle);
}

fn callWindowSurface(runtime: *Runtime, service: WindowSurfaceFn, window: i64, surface: *i64) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, window, surface);
}

fn callSurfaceSize(runtime: *Runtime, service: SurfaceSizeFn, surface: i64, axis: i64, measured: *i64) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, surface, axis, measured);
}

fn callClear(
    runtime: *Runtime,
    service: SurfaceClearFn,
    surface: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, surface, red, green, blue, alpha);
}

fn callFillRect(
    runtime: *Runtime,
    service: SurfaceFillRectFn,
    surface: i64,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(
        runtime.graphics.context,
        surface,
        x,
        y,
        width,
        height,
        red,
        green,
        blue,
        alpha,
    );
}

fn callPresent(runtime: *Runtime, service: SurfacePresentFn, surface: i64) i32 {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    return service(runtime.graphics.context, surface);
}

fn callClose(runtime: *Runtime, service: CloseFn, handle: i64, kind: heap.Object.File.Kind) void {
    runtime.enterEffects();
    defer runtime.leaveEffects();
    _ = service(runtime.graphics.context, handle, @intFromEnum(kind));
}

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

fn closeFailed(runtime: *Runtime, service: CloseFn, handle: i64, kind: heap.Object.File.Kind) void {
    if (handle < 0) return;
    callClose(runtime, service, handle, kind);
}

/// The backend selected by the host.  `std.gpu` maps the number to its
/// public enum; this function is the only place that validates the wire value.
pub fn backend(runtime: *Runtime) Error!i64 {
    const service = runtime.graphics.backend orelse return runtime.fail(.host_unavailable);
    var selected: i64 = -1;
    if (!try hostAnswer(runtime, callBackend(runtime, service, &selected))) {
        return runtime.fail(.host_unavailable);
    }
    if (selected < @intFromEnum(Backend.metal) or selected > @intFromEnum(Backend.headless)) {
        return runtime.fail(.host_unavailable);
    }
    return selected;
}

/// Open a native window and return a reference-counted resource.
pub fn openWindow(runtime: *Runtime, title: []const u8, width: i64, height: i64) Error!?Value {
    const service = runtime.graphics.window_open orelse return runtime.fail(.host_unavailable);
    const closer = runtime.graphics.close orelse return runtime.fail(.host_unavailable);
    var handle: i64 = -1;
    const answer = callWindowOpen(runtime, service, title, width, height, &handle);
    if (answer != yes and handle >= 0) closeFailed(runtime, closer, handle, .window);
    if (!try hostAnswer(runtime, answer)) return null;
    if (handle < 0) return runtime.fail(.host_unavailable);
    errdefer closeFailed(runtime, closer, handle, .window);
    return try runtime.newResource(handle, "ui.window", .window);
}

/// Create the GPU surface owned by a window.
pub fn windowSurface(runtime: *Runtime, window: Value) Error!?Value {
    const service = runtime.graphics.window_surface orelse return runtime.fail(.host_unavailable);
    const closer = runtime.graphics.close orelse return runtime.fail(.host_unavailable);
    const window_handle = try resourceHandle(runtime, window, .window);
    var surface: i64 = -1;
    const answer = callWindowSurface(runtime, service, window_handle, &surface);
    if (answer != yes and surface >= 0) closeFailed(runtime, closer, surface, .surface);
    if (!try hostAnswer(runtime, answer)) return null;
    if (surface < 0) return runtime.fail(.host_unavailable);
    errdefer closeFailed(runtime, closer, surface, .surface);
    return try runtime.newResource(surface, "gpu.surface", .surface);
}

pub fn size(runtime: *Runtime, surface: Value, axis: i64) Error!?i64 {
    if (axis < 0 or axis > 1) return runtime.fail(.index_bounds);
    const service = runtime.graphics.surface_size orelse return runtime.fail(.host_unavailable);
    const handle = try resourceHandle(runtime, surface, .surface);
    var measured: i64 = 0;
    if (!try hostAnswer(runtime, callSurfaceSize(runtime, service, handle, axis, &measured))) return null;
    if (measured < 0) return runtime.fail(.host_unavailable);
    return measured;
}

pub fn clear(
    runtime: *Runtime,
    surface: Value,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) Error!bool {
    const service = runtime.graphics.surface_clear orelse return runtime.fail(.host_unavailable);
    const handle = try resourceHandle(runtime, surface, .surface);
    return hostAnswer(runtime, callClear(runtime, service, handle, red, green, blue, alpha));
}

pub fn fillRect(
    runtime: *Runtime,
    surface: Value,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
) Error!bool {
    const service = runtime.graphics.surface_fill_rect orelse return runtime.fail(.host_unavailable);
    const handle = try resourceHandle(runtime, surface, .surface);
    return hostAnswer(runtime, callFillRect(
        runtime,
        service,
        handle,
        x,
        y,
        width,
        height,
        red,
        green,
        blue,
        alpha,
    ));
}

pub fn present(runtime: *Runtime, surface: Value) Error!bool {
    const service = runtime.graphics.surface_present orelse return runtime.fail(.host_unavailable);
    const handle = try resourceHandle(runtime, surface, .surface);
    return hostAnswer(runtime, callPresent(runtime, service, handle));
}

/// Return the host handle for one of the two native-resource wrappers.  The
/// ordinary file builtins reject these kinds, so a `Window` cannot accidentally
/// be read as a file even though both use the same ownership representation.
pub fn resourceHandle(runtime: *Runtime, held: Value, wanted: heap.Object.File.Kind) Error!i64 {
    const object = try runtime.resolve(held);
    return switch (object.data) {
        .file => |resource| if (resource.kind == wanted)
            resource.handle
        else
            runtime.fail(.not_owned),
        .instance, .list, .map, .array, .builder, .task => runtime.fail(.not_owned),
    };
}

/// Close a native resource during the ownership walk.  There is no error
/// channel at scope end, matching file close semantics.
pub fn close(runtime: *Runtime, resource: heap.Object.File) void {
    if (resource.handle < 0) return;
    const service = runtime.graphics.close orelse return;
    callClose(runtime, service, resource.handle, resource.kind);
}

test "backend values are a closed, explicit wire vocabulary" {
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(Backend.metal));
    try std.testing.expectEqual(@as(i64, 1), @intFromEnum(Backend.vulkan));
    try std.testing.expectEqual(@as(i64, 2), @intFromEnum(Backend.headless));
}

test "a surface keeps its native resource after the window wrapper is released" {
    const Host = struct {
        closes: usize = 0,
        last_kind: i64 = -1,
        cleared: bool = false,
        filled: bool = false,
        presented: bool = false,

        fn backend(_: ?*anyopaque, selected: *i64) callconv(.c) i32 {
            selected.* = @intFromEnum(Backend.headless);
            return yes;
        }

        fn open(
            _: ?*anyopaque,
            title: [*]const u8,
            title_length: i64,
            width: i64,
            height: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            if (!std.mem.eql(u8, title[0..@intCast(title_length)], "test") or
                width != 320 or height != 240)
            {
                return no;
            }
            handle.* = 11;
            return yes;
        }

        fn surface(_: ?*anyopaque, window: i64, handle: *i64) callconv(.c) i32 {
            if (window != 11) return no;
            handle.* = 22;
            return yes;
        }

        fn size(_: ?*anyopaque, surface_handle: i64, axis: i64, measured: *i64) callconv(.c) i32 {
            if (surface_handle != 22 or axis < 0 or axis > 1) return no;
            measured.* = if (axis == 0) 320 else 240;
            return yes;
        }

        fn clear(context: ?*anyopaque, surface_handle: i64, _: i64, _: i64, _: i64, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (surface_handle != 22) return no;
            self.cleared = true;
            return yes;
        }

        fn fill(context: ?*anyopaque, surface_handle: i64, _: i64, _: i64, _: i64, _: i64, _: i64, _: i64, _: i64, _: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (surface_handle != 22) return no;
            self.filled = true;
            return yes;
        }

        fn present(context: ?*anyopaque, surface_handle: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (surface_handle != 22) return no;
            self.presented = true;
            return yes;
        }

        fn close(context: ?*anyopaque, _: i64, kind: i64) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.closes += 1;
            self.last_kind = kind;
            return yes;
        }
    };

    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var runtime: Runtime = .init(.{
        .arena = arena.allocator(),
        .objects = fixed.allocator(),
    });
    defer {
        runtime.deinit();
        arena.deinit();
    }

    var host: Host = .{};
    runtime.graphics = .{
        .context = &host,
        .backend = Host.backend,
        .window_open = Host.open,
        .window_surface = Host.surface,
        .surface_size = Host.size,
        .surface_clear = Host.clear,
        .surface_fill_rect = Host.fill,
        .surface_present = Host.present,
        .close = Host.close,
    };

    try std.testing.expectEqual(@as(i64, 2), try backend(&runtime));
    const window = (try openWindow(&runtime, "test", 320, 240)).?;
    const surface_value = (try windowSurface(&runtime, window)).?;
    try std.testing.expectEqual(@as(i64, 320), (try size(&runtime, surface_value, 0)).?);
    try std.testing.expectEqual(@as(i64, 240), (try size(&runtime, surface_value, 1)).?);
    try std.testing.expect(try clear(&runtime, surface_value, 1, 2, 3, 4));
    try std.testing.expect(try fillRect(&runtime, surface_value, 0, 0, 10, 20, 1, 2, 3, 4));
    try std.testing.expect(try present(&runtime, surface_value));
    runtime.freeValue(window);
    // Window and Surface are independent ARC resources.  Dropping the
    // wrapper that requested the surface must not invalidate a surface that
    // escaped its scope; the native adapter keeps the parent state until the
    // final derived surface releases it.
    try std.testing.expectEqual(@as(usize, 1), host.closes);
    try std.testing.expectEqual(@as(i64, @intFromEnum(heap.Object.File.Kind.window)), host.last_kind);
    try std.testing.expectEqual(@as(i64, 320), (try size(&runtime, surface_value, 0)).?);
    runtime.freeValue(surface_value);
    try std.testing.expect(host.cleared);
    try std.testing.expect(host.filled);
    try std.testing.expect(host.presented);
    try std.testing.expectEqual(@as(usize, 2), host.closes);
    try std.testing.expectEqual(@as(i64, @intFromEnum(heap.Object.File.Kind.surface)), host.last_kind);
}
