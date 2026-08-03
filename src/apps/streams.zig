//! The two standard streams every Luce binary writes through.
//!
//! Three executables open stdout and stderr — `luce`, `loom`, and the
//! `main` shim a compiled program links (`start.zig`) — and all three
//! must open them the same way, because a program's output must not
//! depend on who started it.  Two functions, so there is one place to
//! be right.
//!
//! **Streaming, never positional.**  `File.writer` defaults to
//! positional writes, which is the better default for a file this
//! process opened: the offset is explicit and unaffected by anyone
//! else.  A standard stream is the opposite case.  Its offset lives in
//! an open file description the shell created and may share with other
//! processes, and `>>` is a property of that description rather than
//! of each write.  A positional write ignores all of it and lands at
//! offset zero, so
//!
//!     loom run a > log ; loom run b >> log
//!
//! overwrote the front of the log instead of appending to it, silently
//! destroying however many bytes the second program printed.

const std = @import("std");
const Io = std.Io;

/// stdout, buffered, streaming.  The caller owns `buffer` and must
/// keep it alive as long as the writer, and must `flush()` before the
/// process exits.
pub fn output(io: Io, buffer: []u8) Io.File.Writer {
    return Io.File.stdout().writerStreaming(io, buffer);
}

/// stderr, unbuffered, streaming.  Diagnostics are not buffered
/// because a crash must not be able to swallow the message explaining
/// it.
pub fn diagnostics(io: Io) Io.File.Writer {
    return Io.File.stderr().writerStreaming(io, &.{});
}

test "standard streams are streaming, so a shell's append offset is honoured" {
    // The whole point of this file: `File.writer` would hand back
    // `.positional` here, and a positional write to an appended-to
    // stdout starts at zero and overwrites.  Constructing a streaming
    // writer performs no syscall, so this asserts the mode directly.
    var buffer: [16]u8 = undefined;
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectEqual(Io.File.Writer.Mode.streaming, output(io, &buffer).mode);
    try std.testing.expectEqual(Io.File.Writer.Mode.streaming, diagnostics(io).mode);
}
