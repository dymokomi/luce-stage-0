//! The one rule that keeps a program's own text from forging the
//! terminal: a newline becomes a real line break (CR LF, because raw
//! mode may be on); every other C0, DEL, C1, or malformed sequence
//! becomes `?`; everything else passes through as itself.
//!
//! **The rule lives in one function** because host text reaches a
//! terminal three ways that cannot share a mechanism: the frame
//! buffer, which allocates; a diagnostic line, which allocates; and a
//! trap report, which must not.  Two copies of the rule would be two
//! answers to "what counts as safe", so there is one `step` and two
//! sinks over it.
//!
//! Its own file, and not `host.zig`'s, because the trap report moved
//! out to `report.zig` and the rule has to stay visible from both.  It
//! imports nothing but `std`: what counts as safe does not depend on
//! who is asking.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One step of the rule: the bytes to emit for the front of `text`,
/// and how many input bytes they stand for.  `text` must not be empty.
pub const Step = struct { emit: []const u8, consumed: usize };

pub fn step(text: []const u8) Step {
    const first = text[0];
    if (first == '\n') return .{ .emit = "\r\n", .consumed = 1 };
    const length: usize = std.unicode.utf8ByteSequenceLength(first) catch
        return .{ .emit = "?", .consumed = 1 };
    // A sequence cut off by the end of the text is one `?` for the
    // whole remainder: there is nothing left to decode it against.
    if (length > text.len) return .{ .emit = "?", .consumed = text.len };
    const sequence = text[0..length];
    const codepoint = std.unicode.utf8Decode(sequence) catch
        return .{ .emit = "?", .consumed = 1 };
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
        return .{ .emit = "?", .consumed = length };
    }
    return .{ .emit = sequence, .consumed = length };
}

/// Append UTF-8 display text without letting the program smuggle
/// terminal controls.  Appends to `buffer`, which the caller owns.
pub fn append(
    buffer: *std.ArrayList(u8),
    gpa: Allocator,
    text: []const u8,
) error{OutOfMemory}!void {
    var offset: usize = 0;
    while (offset < text.len) {
        const taken = step(text[offset..]);
        try buffer.appendSlice(gpa, taken.emit);
        offset += taken.consumed;
    }
}

/// The same rewriting, straight onto a writer: no allocator, no
/// scratch buffer, and no length a long message could exceed.  That is
/// what the failure path needs — a trap report has nothing left to
/// allocate from and no message it is allowed to refuse.  Best-effort,
/// like every other write in a trap report: a closed pipe ends the
/// text and is not an error.
pub fn write(err: *std.Io.Writer, text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const taken = step(text[offset..]);
        err.writeAll(taken.emit) catch return;
        offset += taken.consumed;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "program text cannot inject terminal controls" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try append(&buffer, testing.allocator, "safe\x1b[2J\r\t λ \xc2\x9b tail\xff\nnext");
    try testing.expectEqualStrings("safe?[2J?? λ ? tail?\r\nnext", buffer.items);
}

test "every shape a byte sequence can be broken in becomes one question mark" {
    // The rule has four exits and the test above walks two of them.
    // These are the rest, said as `step` answers them — how many bytes
    // are emitted *and* how many the step stands for, which is what
    // decides whether the text after a broken sequence is read as text
    // or as more rubbish.
    const cases = [_]struct { text: []const u8, emit: []const u8, consumed: usize }{
        // A sequence the end of the text cuts off: nothing is left to
        // decode it against, so the whole remainder is one `?`.
        .{ .text = "\xe2\x82", .emit = "?", .consumed = 2 },
        .{ .text = "\xf0\x9f\x92", .emit = "?", .consumed = 3 },
        // A lead byte whose continuation bytes are not continuations:
        // the length is believable and the decode is not, so exactly
        // one byte is consumed and the `(` after it is read as text.
        .{ .text = "\xe2\x28\xa1", .emit = "?", .consumed = 1 },
        // DEL, which is not a C0 control and is not printable either.
        .{ .text = "\x7f", .emit = "?", .consumed = 1 },
        // The far end of the C1 block, three bytes wide in UTF-8's
        // two-byte form.
        .{ .text = "\xc2\x9f", .emit = "?", .consumed = 2 },
        // And the first codepoint past it, which is text.
        .{ .text = "\xc2\xa0", .emit = "\xc2\xa0", .consumed = 2 },
    };
    for (cases) |case| {
        const taken = step(case.text);
        try testing.expectEqualStrings(case.emit, taken.emit);
        try testing.expectEqual(case.consumed, taken.consumed);
    }

    // End to end, so the two sinks agree: a truncated sequence, a bad
    // one, and a DEL in one run of text.
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try append(&buffer, testing.allocator, "a\x7fb\xe2\x28\xa1c\xe2\x82");
    try testing.expectEqualStrings("a?b?(?c?", buffer.items);

    var streamed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer streamed.deinit();
    write(&streamed.writer, "a\x7fb\xe2\x28\xa1c\xe2\x82");
    try testing.expectEqualStrings(buffer.items, streamed.written());
}
