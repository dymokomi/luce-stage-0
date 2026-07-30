//! Structured Luce diagnostics.
//!
//! Diagnostics are part of the editing experience, not terminal noise:
//! each carries a stable code, a severity, a concise message, and the
//! source span it points at.

const std = @import("std");
const source_mod = @import("source.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    code: []const u8, // stable, e.g. "luce.parse.expected"
    severity: Severity,
    message: []u8, // owned by the list
    span: Span,
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
//
// An append-only diagnostic list.  Owns every message.
//
pub const Diagnostics = struct {
    allocator: Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |item| self.allocator.free(item.message);
        self.list.deinit(self.allocator);
        self.* = undefined;
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
        try self.list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
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

    /// Render every diagnostic as "line:column: message" lines.  The
    /// caller owns the text.
    pub fn render(self: *const Diagnostics, allocator: Allocator, source: []const u8) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        for (self.list.items) |item| {
            const at_place = source_mod.place(source, item.span.start);
            const line = try std.fmt.allocPrint(allocator, "{d}:{d}: {s} [{s}]\n", .{
                at_place.line,
                at_place.column,
                item.message,
                item.code,
            });
            defer allocator.free(line);
            try text.appendSlice(allocator, line);
        }
        return text.toOwnedSlice(allocator);
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
