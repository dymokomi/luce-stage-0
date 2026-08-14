//! The macOS graphics adapter used by `loom` and standalone Luce programs.
//!
//! The language and runtime only know the backend-neutral graphics ABI. This
//! file owns the small adapter around the Objective-C/Metal helper and turns
//! its integer answers into the ABI's `Answer` values. Other platforms keep
//! the portable host's fail-closed graphics behavior.

const builtin = @import("builtin");
const luce = @import("luce");
const host = @import("host");

const abi = luce.llvm.abi;

const c = if (builtin.os.tag == .macos) struct {
    extern fn luce_macos_graphics_create() ?*anyopaque;
    extern fn luce_macos_graphics_destroy(state: *anyopaque) void;
    extern fn luce_macos_graphics_backend(state: *anyopaque, backend: *i64) c_int;
    extern fn luce_macos_graphics_window_open(
        state: *anyopaque,
        title: [*]const u8,
        title_length: i64,
        width: i64,
        height: i64,
        handle: *i64,
    ) c_int;
    extern fn luce_macos_graphics_window_surface(state: *anyopaque, window: i64, surface: *i64) c_int;
    extern fn luce_macos_graphics_surface_size(state: *anyopaque, surface: i64, axis: i64, size: *i64) c_int;
    extern fn luce_macos_graphics_surface_clear(
        state: *anyopaque,
        surface: i64,
        red: i64,
        green: i64,
        blue: i64,
        alpha: i64,
    ) c_int;
    extern fn luce_macos_graphics_surface_fill_rect(
        state: *anyopaque,
        surface: i64,
        x: i64,
        y: i64,
        width: i64,
        height: i64,
        red: i64,
        green: i64,
        blue: i64,
        alpha: i64,
    ) c_int;
    extern fn luce_macos_graphics_surface_present(state: *anyopaque, surface: i64) c_int;
    extern fn luce_macos_graphics_close(state: *anyopaque, handle: i64, kind: i64) c_int;
} else struct {};

/// One process-local Metal channel. It is deliberately optional: a target
/// without a native backend still builds and reports `host_unavailable`.
pub const Backend = if (builtin.os.tag == .macos) MacBackend else NullBackend;

const MacBackend = struct {
    state: *anyopaque,

    fn init() ?MacBackend {
        const state = c.luce_macos_graphics_create() orelse return null;
        return .{ .state = state };
    }

    fn deinit(self: *MacBackend) void {
        c.luce_macos_graphics_destroy(self.state);
        self.* = undefined;
    }

    fn hooks(self: *MacBackend) host.Host.GraphicsHooks {
        return .{
            .context = self.state,
            .backend = backend,
            .window_open = windowOpen,
            .window_surface = windowSurface,
            .surface_size = surfaceSize,
            .surface_clear = surfaceClear,
            .surface_fill_rect = surfaceFillRect,
            .surface_present = surfacePresent,
            .close = close,
        };
    }

    fn answer(result: c_int) abi.Answer {
        return switch (result) {
            1 => .yes,
            -1 => .exhausted,
            else => .no,
        };
    }

    fn stateOf(context: ?*anyopaque) ?*anyopaque {
        return context orelse null;
    }

    fn backend(context: ?*anyopaque, selected: *i64) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_backend(stateOf(context) orelse return .no, selected));
    }

    fn windowOpen(
        context: ?*anyopaque,
        title: [*]const u8,
        title_length: i64,
        width: i64,
        height: i64,
        handle: *i64,
    ) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_window_open(
            stateOf(context) orelse return .no,
            title,
            title_length,
            width,
            height,
            handle,
        ));
    }

    fn windowSurface(context: ?*anyopaque, window: i64, surface: *i64) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_window_surface(
            stateOf(context) orelse return .no,
            window,
            surface,
        ));
    }

    fn surfaceSize(context: ?*anyopaque, surface: i64, axis: i64, size: *i64) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_surface_size(
            stateOf(context) orelse return .no,
            surface,
            axis,
            size,
        ));
    }

    fn surfaceClear(
        context: ?*anyopaque,
        surface: i64,
        red: i64,
        green: i64,
        blue: i64,
        alpha: i64,
    ) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_surface_clear(
            stateOf(context) orelse return .no,
            surface,
            red,
            green,
            blue,
            alpha,
        ));
    }

    fn surfaceFillRect(
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
    ) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_surface_fill_rect(
            stateOf(context) orelse return .no,
            surface,
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

    fn surfacePresent(context: ?*anyopaque, surface: i64) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_surface_present(
            stateOf(context) orelse return .no,
            surface,
        ));
    }

    fn close(context: ?*anyopaque, handle: i64, kind: i64) callconv(.c) abi.Answer {
        return answer(c.luce_macos_graphics_close(
            stateOf(context) orelse return .no,
            handle,
            kind,
        ));
    }
};

const NullBackend = struct {
    fn init() ?NullBackend {
        return null;
    }

    fn deinit(_: *NullBackend) void {}

    fn hooks(_: *NullBackend) host.Host.GraphicsHooks {
        unreachable;
    }
};

pub fn init() ?Backend {
    return Backend.init();
}

pub fn install(services: *host.Host, backend: *Backend) void {
    services.installGraphics(backend.hooks());
}

pub fn deinit(backend: *Backend) void {
    backend.deinit();
}
