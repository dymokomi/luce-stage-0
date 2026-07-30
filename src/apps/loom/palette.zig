//! ANSI color for the loom shell.
//!
//! One Palette travels with the shell.  When disabled (not a tty, or
//! NO_COLOR set), every code renders as the empty string, so printing
//! code never branches on color support.  Styles are semantic — the
//! palette decides what a prompt or an error looks like, callers say
//! what a thing *is*.

pub const Style = enum {
    reset,
    bold,
    dim,
    prompt,
    err,
    ok,
    path,

    fn sequence(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .prompt => "\x1b[36m",
            .err => "\x1b[31m",
            .ok => "\x1b[32m",
            .path => "\x1b[1m",
        };
    }
};

pub const Palette = struct {
    enabled: bool = false,

    /// The escape code for a style, or nothing when color is off.
    pub fn sgr(self: Palette, style: Style) []const u8 {
        if (!self.enabled) return "";
        return style.sequence();
    }
};

const std = @import("std");

test "a disabled palette renders nothing" {
    const off: Palette = .{};
    try std.testing.expectEqualStrings("", off.sgr(.err));
    const on: Palette = .{ .enabled = true };
    try std.testing.expectEqualStrings("\x1b[31m", on.sgr(.err));
}
