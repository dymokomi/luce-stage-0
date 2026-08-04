//! Input hygiene: the one gate every byte slice passes on its way to
//! becoming a Luce source file.
//!
//! A compiler is handed whatever a filesystem holds — a Windows file
//! with CRLF line endings, an editor's byte-order mark, half a JPEG,
//! a directory listing's worth of bytes.  Each of those is decided
//! here, once, so no later stage has to wonder:
//!
//!   * a leading UTF-8 byte-order mark is stripped (the convention
//!     every compiler follows; it is encoding metadata, not text);
//!   * CRLF becomes LF, so a file edited on Windows lays out exactly
//!     like one edited anywhere else.  Only the terminator changes:
//!     every line and every column keeps its number;
//!   * a stray carriage return — one not followed by a newline — is
//!     refused.  Classic-Mac line endings would silently change block
//!     structure, and a lone CR anywhere else is a mangled file;
//!   * a NUL byte is refused: this is not text;
//!   * invalid UTF-8 is refused, naming the byte that broke it.  The
//!     lexer may then assume every non-ASCII run is well formed;
//!   * a UTF-16 or UTF-32 byte-order mark is refused *by name*.  Those
//!     files are reachable — PowerShell's `>` redirection and old
//!     Notepad both write UTF-16 — and diagnosing them as generic
//!     invalid UTF-8 (or, for the big-endian forms, as "a NUL byte")
//!     tells the author nothing they can act on.  Four bytes of
//!     sniffing turns a puzzle into "save it as UTF-8";
//!   * anything over `max_bytes` is refused before it is read, let
//!     alone copied.
//!
//! Everything else — a form feed, an escape character, a vertical tab
//! — reaches the lexer, which reports it as an unexpected character
//! with a span.  This gate is only for what a *file* can be wrong
//! about, not for what a *program* can be wrong about.
//!
//! **Declined:** UTF-16 *without* a byte-order mark.  Detecting it
//! means guessing from the density of NUL bytes, and a wrong guess
//! renames a real problem; the BOM-less case is already refused as
//! `luce.source.binary` at its first NUL, which is true and points at
//! a byte the author can look at.
//!
//! Offsets in a `Problem` count from the start of the original bytes,
//! so they name a position in the file on disk; `load.zig` turns them
//! into a line and a column against those same bytes.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The largest source file the compiler accepts, per module.
///
/// Two reasons for a limit at all, and one reason for this number.
/// Debug info stores line and column as `u32` and the line index as
/// `[]u32`, so a source larger than 4 GiB would silently truncate or
/// trap on the cast; and a "source file" of that size is a mistake
/// (a binary passed to `luce build`), which deserves a diagnostic
/// rather than an out-of-memory kill.  64 MiB is far past any real
/// program — the whole standard library is 16 KiB — and far below
/// the point where the `u32` arithmetic could be in doubt.
pub const max_bytes: usize = 64 << 20;

/// An encoding a byte-order mark announces and Luce does not accept.
/// Named so the diagnostic can say which one, and how to fix it.
pub const Encoding = enum {
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,

    pub fn label(self: Encoding) []const u8 {
        return switch (self) {
            .utf16_le => "UTF-16 (little-endian)",
            .utf16_be => "UTF-16 (big-endian)",
            .utf32_le => "UTF-32 (little-endian)",
            .utf32_be => "UTF-32 (big-endian)",
        };
    }
};

/// Why a byte slice cannot be Luce source.  Every variant carries a
/// byte offset into the original input (or, for `too_large`, a size).
pub const Problem = union(enum) {
    too_large: usize,
    nul_byte: usize,
    stray_carriage_return: usize,
    invalid_utf8: usize,
    /// A byte-order mark for an encoding that is not UTF-8; always at
    /// offset 0, so the variant carries the encoding instead.
    wrong_encoding: Encoding,
};

/// A prepared source text, or the reason there is none.  `text` is
/// allocated from the allocator passed to `prepare` and belongs to
/// the caller.
pub const Prepared = union(enum) {
    text: []u8,
    problem: Problem,
};

/// Turn raw bytes into source text the rest of the compiler can trust:
/// no BOM, no CR, no NUL, valid UTF-8, within `max_bytes`.
///
/// The result is always a fresh copy — spans index *it*, not the file
/// — so the caller may free the input immediately.
pub fn prepare(allocator: Allocator, bytes: []const u8) error{OutOfMemory}!Prepared {
    // The wrong-encoding sniff comes first: a UTF-16BE file starts
    // with NUL bytes and a UTF-16LE one is ill-formed UTF-8, so either
    // of the checks below would otherwise answer first and answer
    // uselessly.
    if (announcedEncoding(bytes)) |wrong| return .{ .problem = .{ .wrong_encoding = wrong } };

    const bom = "\xEF\xBB\xBF";
    const start: usize = if (std.mem.startsWith(u8, bytes, bom)) bom.len else 0;
    const body = bytes[start..];

    if (body.len > max_bytes) return .{ .problem = .{ .too_large = bytes.len } };

    var carriage_returns: usize = 0;
    for (body, 0..) |character, offset| {
        if (character == 0) return .{ .problem = .{ .nul_byte = start + offset } };
        if (character != '\r') continue;
        if (offset + 1 == body.len or body[offset + 1] != '\n') {
            return .{ .problem = .{ .stray_carriage_return = start + offset } };
        }
        carriage_returns += 1;
    }
    if (firstInvalidUtf8(body)) |offset| {
        return .{ .problem = .{ .invalid_utf8 = start + offset } };
    }

    const text = try allocator.alloc(u8, body.len - carriage_returns);
    errdefer allocator.free(text);
    var written: usize = 0;
    for (body, 0..) |character, offset| {
        // Every CR here is the first half of a CRLF: the scan above
        // refused any other kind.
        if (character == '\r' and body[offset + 1] == '\n') continue;
        text[written] = character;
        written += 1;
    }
    std.debug.assert(written == text.len);
    return .{ .text = text };
}

/// The encoding a leading byte-order mark announces, when it is one
/// Luce does not accept, or null.  The UTF-8 mark is not a problem —
/// `prepare` strips it — and neither is text that simply begins with
/// one of these bytes, since none of them can start a UTF-8 sequence
/// that is also a valid mark.
///
/// The four-byte marks are tested before the two-byte ones: UTF-32LE
/// begins with the whole of the UTF-16LE mark.
fn announcedEncoding(bytes: []const u8) ?Encoding {
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE\x00\x00")) return .utf32_le;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\xFE\xFF")) return .utf32_be;
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .utf16_le;
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .utf16_be;
    return null;
}

/// Byte offset of the first ill-formed UTF-8 sequence, or null when
/// the whole slice decodes.  Doubles as the validator: locating the
/// break costs the same walk as proving there is none.
fn firstInvalidUtf8(text: []const u8) ?usize {
    var offset: usize = 0;
    while (offset < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch return offset;
        if (offset + length > text.len) return offset;
        _ = std.unicode.utf8Decode(text[offset..][0..length]) catch return offset;
        offset += length;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectText(bytes: []const u8, wanted: []const u8) !void {
    const prepared = try prepare(testing.allocator, bytes);
    switch (prepared) {
        .text => |text| {
            defer testing.allocator.free(text);
            try testing.expectEqualStrings(wanted, text);
        },
        .problem => return error.TestUnexpectedResult,
    }
}

fn expectRejected(bytes: []const u8, wanted: Problem) !void {
    const prepared = try prepare(testing.allocator, bytes);
    switch (prepared) {
        .text => |text| {
            testing.allocator.free(text);
            return error.TestUnexpectedResult;
        },
        .problem => |problem| try testing.expectEqual(wanted, problem),
    }
}

test "ordinary text survives byte for byte, empty included" {
    try expectText("func main():\n    return\n", "func main():\n    return\n");
    try expectText("", "");
    try expectText("no trailing newline", "no trailing newline");
}

test "a leading byte-order mark is stripped and only a leading one" {
    try expectText("\xEF\xBB\xBFfunc main():\n", "func main():\n");
    // Mid-file it is an ordinary (if pointless) character: valid
    // UTF-8, and the lexer's business to reject.
    try expectText("a\xEF\xBB\xBFb", "a\xEF\xBB\xBFb");
}

test "CRLF collapses to LF and keeps every line and column" {
    try expectText("a = 1\r\n\r\n    b = 2\r\n", "a = 1\n\n    b = 2\n");
    // The BOM and CRLF cases compose: a Windows-edited file.
    try expectText("\xEF\xBB\xBFfunc main():\r\n", "func main():\n");
}

test "a stray carriage return is refused, naming the byte" {
    try expectRejected("a\rb\n", .{ .stray_carriage_return = 1 });
    try expectRejected("a\r", .{ .stray_carriage_return = 1 });
    // Offsets count from the start of the file, BOM included.
    try expectRejected("\xEF\xBB\xBFa\rb", .{ .stray_carriage_return = 4 });
}

test "a NUL byte is refused: this is not a text file" {
    try expectRejected("func main():\x00\n", .{ .nul_byte = 12 });
    try expectRejected("\x00", .{ .nul_byte = 0 });
}

test "invalid UTF-8 is refused at the byte that broke it" {
    // A continuation byte with no lead.
    try expectRejected("let a = 1\n\x80\n", .{ .invalid_utf8 = 10 });
    // A lead byte whose sequence runs off the end.
    try expectRejected("x\xE2\x82", .{ .invalid_utf8 = 1 });
    // An overlong encoding of '/'.
    try expectRejected("\xC0\xAF", .{ .invalid_utf8 = 0 });
    // Well-formed multi-byte text is not touched.
    try expectText("# héllo — ok\n", "# héllo — ok\n");
}

test "a source larger than the limit is refused before it is copied" {
    // The rejection happens on the length alone: nothing is scanned,
    // nothing is duplicated, so this costs one allocation and no copy.
    const oversized = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try expectRejected(oversized, .{ .too_large = max_bytes + 1 });
}

test "a UTF-16 or UTF-32 byte-order mark is refused by name" {
    // "func\n" as each of the four, mark included.
    try expectRejected(
        "\xFF\xFEf\x00u\x00n\x00c\x00\n\x00",
        .{ .wrong_encoding = .utf16_le },
    );
    try expectRejected(
        "\xFE\xFF\x00f\x00u\x00n\x00c\x00\n",
        .{ .wrong_encoding = .utf16_be },
    );
    try expectRejected(
        "\xFF\xFE\x00\x00f\x00\x00\x00u\x00\x00\x00",
        .{ .wrong_encoding = .utf32_le },
    );
    try expectRejected(
        "\x00\x00\xFE\xFF\x00\x00\x00f\x00\x00\x00u",
        .{ .wrong_encoding = .utf32_be },
    );
    // The mark alone, with nothing after it, is still the same answer.
    try expectRejected("\xFF\xFE", .{ .wrong_encoding = .utf16_le });

    // The four-byte marks win over the two-byte prefix they contain:
    // UTF-32LE begins with the whole UTF-16LE mark.
    try expectRejected("\xFF\xFE\x00\x00", .{ .wrong_encoding = .utf32_le });

    // Mid-file those bytes are just bytes, judged by the ordinary
    // rules — this is a sniff of the mark, not a search for it.
    try expectRejected("a\xFF\xFEb", .{ .invalid_utf8 = 1 });
}

test "UTF-16 with no byte-order mark is still refused, as binary" {
    // Declined on purpose: guessing at BOM-less UTF-16 renames a real
    // problem when the guess is wrong.  The NUL is true and locatable.
    try expectRejected("f\x00u\x00n\x00c\x00", .{ .nul_byte = 1 });
}

// Property fuzzing: `prepare` is the first thing untrusted bytes
// touch, so the invariant worth proving is total — every input either
// yields text the rest of the compiler may assume is well formed, or
// a problem whose offset points inside the input.  Under `zig build
// test` this runs the corpus; `zig build test --fuzz` explores from it.
test "fuzz: prepare either refuses bytes or hands back trustworthy text" {
    try testing.fuzz({}, prepareAnything, .{ .corpus = &.{
        "func main():\n    return\n",
        "\xEF\xBB\xBFa = 1\r\n",
        "\xFF\xFEf\x00u\x00n\x00",
        "\xFE\xFF\x00f\x00u",
        "\xFF\xFE\x00\x00f\x00\x00\x00",
        "\x00\x00\xFE\xFF\x00\x00\x00f",
        "a\rb\n",
        "let s = \"h\xC3\xA9llo\"\n",
        "\xC0\xAF\xE2\x82",
        "x\x00y",
    } });
}

fn prepareAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    // Weighted toward the bytes this gate exists for: the marks, the
    // terminators, NUL, and continuation bytes.
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .rangeAtMost(u8, 0x80, 0xbf, 2),
        .value(u8, 0x00, 4),
        .value(u8, 0xff, 4),
        .value(u8, 0xfe, 4),
        .value(u8, 0xef, 3),
        .value(u8, 0xbb, 3),
        .value(u8, '\n', 4),
        .value(u8, '\r', 4),
    });
    const bytes = buffer[0..length];

    switch (try prepare(testing.allocator, bytes)) {
        .text => |text| {
            defer testing.allocator.free(text);
            // What every later stage is allowed to assume.
            try testing.expect(text.len <= bytes.len);
            try testing.expect(std.unicode.utf8ValidateSlice(text));
            try testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
            try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
            try testing.expect(!std.mem.startsWith(u8, text, "\xEF\xBB\xBF"));
            // Only terminators were dropped: the count of newlines is
            // preserved exactly, so every line keeps its number.
            try testing.expectEqual(
                std.mem.count(u8, bytes, "\n"),
                std.mem.count(u8, text, "\n"),
            );
        },
        .problem => |problem| switch (problem) {
            // Nothing this small can be too large, and the offsets
            // must name a byte that is really there.
            .too_large => return error.TestUnexpectedResult,
            .wrong_encoding => try testing.expect(bytes.len >= 2),
            .nul_byte, .stray_carriage_return, .invalid_utf8 => |offset| {
                try testing.expect(offset < bytes.len);
            },
        },
    }
}
