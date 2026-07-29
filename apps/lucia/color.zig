//! ANSI color for the lucia terminal.
//!
//! One Palette travels with the session.  When disabled (not a tty, or
//! NO_COLOR set), every code renders as the empty string, so printing
//! code never branches on color support.  Styles are semantic — the
//! palette decides what an identity or an error looks like, callers
//! say what a thing *is*.

pub const Style = enum {
    reset,
    bold,
    dim,
    // Semantic roles.
    identity, // texel ids
    name, // texel names
    value, // available values
    unavailable,
    err,
    created,
    prompt,
    // Editor / syntax roles.
    keyword,
    literal,
    string,
    comment,
    port,
    line_number,
    selected,

    fn sequence(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .identity => "\x1b[2m",
            .name => "\x1b[1m",
            .value => "\x1b[32m",
            .unavailable => "\x1b[33m",
            .err => "\x1b[31m",
            .created => "\x1b[32m",
            .prompt => "\x1b[36m",
            .keyword => "\x1b[35m",
            .literal => "\x1b[33m",
            .string => "\x1b[32m",
            .comment => "\x1b[2m",
            .port => "\x1b[36m",
            .line_number => "\x1b[2m",
            .selected => "\x1b[7m", // inverse video
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
    try std.testing.expectEqualStrings("\x1b[0m", on.sgr(.reset));
}
