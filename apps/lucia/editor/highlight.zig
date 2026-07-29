//! Luce syntax highlighting for the editor, one line at a time.
//!
//! The real Luce lexer tokenizes each line; token kinds map to the
//! palette's syntax roles.  Comments are painted by hand (the lexer
//! deliberately skips them), and a line that fails to lex still
//! renders — editing passes through malformed states constantly.

const std = @import("std");
const luce = @import("luce");
const color = @import("../color.zig");

const Allocator = std.mem.Allocator;
const Style = color.Style;

/// Write one source line with syntax styling.  When the palette is
/// disabled this writes the line verbatim.
pub fn writeLine(
    writer: *std.Io.Writer,
    allocator: Allocator,
    palette: color.Palette,
    line: []const u8,
) !void {
    if (!palette.enabled or line.len == 0) {
        try writer.writeAll(line);
        return;
    }

    // Column-to-style map from real tokens.
    const styles = try allocator.alloc(?Style, line.len);
    defer allocator.free(styles);
    @memset(styles, null);

    var diagnostics = luce.diagnostics.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = luce.lexer.lex(allocator, line, &diagnostics) catch &.{};
    defer if (tokens.len > 0) allocator.free(tokens);

    for (tokens) |token| {
        const style = styleFor(token.kind, token.span.slice(line)) orelse continue;
        for (token.span.start..@min(token.span.end, line.len)) |at| {
            styles[at] = style;
        }
    }

    // Comments: '#' to end of line, when outside every string token.
    var comment_start: ?usize = null;
    for (line, 0..) |character, at| {
        if (character == '#' and styles[at] != .string) {
            comment_start = at;
            break;
        }
    }
    if (comment_start) |start| {
        for (start..line.len) |at| styles[at] = .comment;
    }

    // Emit runs of one style.
    var at: usize = 0;
    while (at < line.len) {
        const style = styles[at];
        var run_end = at + 1;
        while (run_end < line.len and equalStyle(styles[run_end], style)) run_end += 1;
        if (style) |chosen| {
            try writer.print("{s}{s}{s}", .{
                palette.sgr(chosen),
                line[at..run_end],
                palette.sgr(.reset),
            });
        } else {
            try writer.writeAll(line[at..run_end]);
        }
        at = run_end;
    }
}

fn equalStyle(left: ?Style, right: ?Style) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return left.? == right.?;
}

fn styleFor(kind: luce.token.Kind, text: []const u8) ?Style {
    return switch (kind) {
        .keyword_fn,
        .keyword_struct,
        .keyword_let,
        .keyword_var,
        .keyword_if,
        .keyword_elif,
        .keyword_else,
        .keyword_while,
        .keyword_for,
        .keyword_in,
        .keyword_return,
        .keyword_break,
        .keyword_continue,
        .keyword_and,
        .keyword_or,
        .keyword_not,
        => .keyword,
        .keyword_true, .keyword_false, .int_literal, .float_literal => .literal,
        .string_literal => .string,
        .identifier => if (std.mem.eql(u8, text, "input") or std.mem.eql(u8, text, "output"))
            .port
        else
            null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderLine(allocator: Allocator, palette: color.Palette, line: []const u8) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try writeLine(&sink.writer, allocator, palette, line);
    return allocator.dupe(u8, sink.written());
}

test "disabled palette renders lines verbatim" {
    const rendered = try renderLine(testing.allocator, .{}, "let x = 1 # note");
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("let x = 1 # note", rendered);
}

test "keywords, ports, literals, strings, and comments style" {
    const palette: color.Palette = .{ .enabled = true };
    const rendered = try renderLine(
        testing.allocator,
        palette,
        "let x = input.a + \"hi\" # note",
    );
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[35mlet\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[36minput\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32m\"hi\"\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2m# note\x1b[0m") != null);
}

test "malformed lines still render" {
    const palette: color.Palette = .{ .enabled = true };
    const rendered = try renderLine(testing.allocator, palette, "let s = \"unterminated");
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "unterminated") != null);
}
