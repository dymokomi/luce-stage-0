//! ANSI color for the loom shell.
//!
//! One Palette travels with the shell.  When disabled (not a tty, or
//! NO_COLOR set), every code renders as the empty string, so printing
//! code never branches on color support.  Styles are semantic — the
//! palette decides what a prompt or an error looks like, callers say
//! what a thing *is*.

/// The styles the shell actually asks for, and no others.  A palette
/// entry nobody names is a colour decision nobody can see — failure
/// text, in particular, is written by the runner onto standard error
/// and is never coloured, because standard error may not be the same
/// terminal standard output is.
pub const Style = enum {
    reset,
    bold,
    dim,
    prompt,

    fn sequence(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .prompt => "\x1b[36m",
        };
    }
};

pub const Palette = struct {
    enabled: bool = false,

    /// The escape code for a style, or nothing when color is off.
    /// A static escape sequence, empty when colour is off; the caller
    /// owns nothing.
    pub fn sgr(self: Palette, style: Style) []const u8 {
        if (!self.enabled) return "";
        return style.sequence();
    }
};

const std = @import("std");

test "a disabled palette renders nothing" {
    const off: Palette = .{};
    const on: Palette = .{ .enabled = true };
    // Every style, both ways: a palette that is off must be off for
    // all of them, since printing code never branches on colour.
    inline for (@typeInfo(Style).@"enum".fields) |field| {
        const style = @field(Style, field.name);
        try std.testing.expectEqualStrings("", off.sgr(style));
        try std.testing.expect(on.sgr(style).len != 0);
    }
    try std.testing.expectEqualStrings("\x1b[36m", on.sgr(.prompt));
}
