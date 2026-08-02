//! Structured Luce diagnostics.
//!
//! Diagnostics are part of the editing experience, not terminal noise:
//! each carries a stable code, a severity, a concise message, and the
//! source span it points at.

const std = @import("std");
const source_mod = @import("../01_source.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    code: []const u8, // stable, e.g. "luce.parse.expected"
    severity: Severity,
    message: []u8, // owned by the list
    span: Span,
    /// Which module's source the span points into; "" is the root.
    module: []u8, // owned by the list
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
//
// An append-only diagnostic list.  Owns every message.
//
pub const NamedSource = struct {
    name: []u8, // owned
    source: []u8, // owned
};

pub const Diagnostics = struct {
    allocator: Allocator,
    list: std.ArrayList(Diagnostic) = .empty,
    /// Stamped onto every added diagnostic; the compile driver and
    /// analyzer set it to the module being worked on ("" = root).
    scope: []const u8 = "",
    /// Copies of imported module sources, so multi-file diagnostics
    /// render with real line numbers after the compile arena is gone.
    sources: std.ArrayList(NamedSource) = .empty,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |item| {
            self.allocator.free(item.message);
            self.allocator.free(item.module);
        }
        self.list.deinit(self.allocator);
        for (self.sources.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.source);
        }
        self.sources.deinit(self.allocator);
        self.* = undefined;
    }

    /// Keep a module's source for later rendering.
    pub fn registerSource(self: *Diagnostics, name: []const u8, source: []const u8) error{OutOfMemory}!void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        try self.sources.append(self.allocator, .{ .name = owned_name, .source = owned_source });
    }

    pub fn add(
        self: *Diagnostics,
        code: []const u8,
        span: Span,
        comptime format: []const u8,
        arguments: anytype,
    ) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.allocator, format, arguments);
        errdefer self.allocator.free(message);
        const module = try self.allocator.dupe(u8, self.scope);
        errdefer self.allocator.free(module);
        try self.list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
            .module = module,
        });
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    pub fn at(self: *const Diagnostics, index: usize) ?*const Diagnostic {
        if (index >= self.list.items.len) return null;
        return &self.list.items[index];
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.list.items) |item| {
            if (item.severity == .err) return true;
        }
        return false;
    }

    /// Render every diagnostic as "line:column: message" lines; spans
    /// into imported modules render as "name.luc:line:column" using
    /// the registered sources.  The caller owns the text.
    pub fn render(self: *const Diagnostics, allocator: Allocator, source: []const u8) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        for (self.list.items) |item| {
            const line = blk: {
                if (item.module.len == 0) {
                    const at_place = source_mod.place(source, item.span.start);
                    break :blk try std.fmt.allocPrint(allocator, "{d}:{d}: {s} [{s}]\n", .{
                        at_place.line,
                        at_place.column,
                        item.message,
                        item.code,
                    });
                }
                if (self.findSource(item.module)) |module_source| {
                    const at_place = source_mod.place(module_source, item.span.start);
                    break :blk try std.fmt.allocPrint(allocator, "{s}.luc:{d}:{d}: {s} [{s}]\n", .{
                        item.module,
                        at_place.line,
                        at_place.column,
                        item.message,
                        item.code,
                    });
                }
                break :blk try std.fmt.allocPrint(allocator, "{s}.luc: {s} [{s}]\n", .{
                    item.module,
                    item.message,
                    item.code,
                });
            };
            defer allocator.free(line);
            try text.appendSlice(allocator, line);
        }
        return text.toOwnedSlice(allocator);
    }

    fn findSource(self: *const Diagnostics, name: []const u8) ?[]const u8 {
        for (self.sources.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.source;
        }
        return null;
    }
};

test "diagnostics own their messages and render places" {
    const allocator = std.testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();

    try diagnostics.add("luce.test", .{ .start = 3, .end = 4 }, "unexpected {s}", .{"thing"});
    try std.testing.expectEqual(@as(usize, 1), diagnostics.count());
    try std.testing.expect(diagnostics.hasErrors());

    const rendered = try diagnostics.render(allocator, "ab\ncd");
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("2:1: unexpected thing [luce.test]\n", rendered);
}
