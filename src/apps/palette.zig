//! ANSI color for the two binaries that write to a person.
//!
//! One Palette travels with whatever is doing the writing — loom's
//! shell, `luce test`'s report.  When disabled (not a tty, or NO_COLOR
//! set), every code renders as the empty string, so printing code never
//! branches on color support.  Styles are semantic — the palette
//! decides what a prompt or a passing test looks like, callers say what
//! a thing *is*.
//!
//! Shared rather than one per binary because there is one decision here
//! and it is not loom's: whether this stream is a terminal, and what a
//! style means when it is.  A second copy would be a second answer.

/// The styles the two callers actually ask for, and no others.  A
/// palette entry nobody names is a colour decision nobody can see —
/// loom's failure text, in particular, is written by the runner onto
/// standard error and is never coloured, because standard error may not
/// be the same terminal standard output is.
pub const Style = enum {
    reset,
    bold,
    dim,
    prompt,
    /// A test that passed, and one that did not (docs/TESTING.md D4).
    /// Both are written onto the report's own stream, which is the
    /// stream the palette was decided from.
    pass,
    fail,

    fn sequence(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .prompt => "\x1b[36m",
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
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
    try std.testing.expectEqualStrings("\x1b[32m", on.sgr(.pass));
    try std.testing.expectEqualStrings("\x1b[31m", on.sgr(.fail));
}
