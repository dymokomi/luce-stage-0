//! The call trace a trapped program reports, and the constant tables
//! it is resolved through.
//!
//! The interpreter can build a trace whenever it likes: its frames sit
//! on an explicit heap stack that survives a trap intact, so it walks
//! that stack once, after the fact (`interpreter/machine.zig`).
//! Compiled code has no such stack.  Its frames are native frames, and
//! by the time anything could walk them they are gone — so a compiled
//! program builds its trace **as it unwinds**: every frame records
//! itself on the way out, innermost first, and `luce_main` hands the
//! finished trace to the host together with the trap.
//!
//! That keeps docs/MODES.md's bargain on this path too.  Nothing here
//! is touched while a program is running: not a load, not a branch.
//! The whole cost sits on the far side of "the program already
//! failed", which is why a debug build and a `--release` build run at
//! identical speed.
//!
//! A frame records nothing but two indices — which function, which
//! instruction — because that is all generated code knows about
//! itself.  The names and the source positions live in a constant
//! table the code generator emits beside the code and hands to
//! `luce_rt_open`.  A `--release` build emits the names and leaves the
//! origins out, so a stripped program still says `at divide / at
//! ratio / at main`; names are structure, not debug info.

const std = @import("std");

/// Where one instruction came from: the line and column of the
/// statement it lowered from.  `mir.Origin` in C layout.
pub const Origin = extern struct {
    line: u32,
    column: u32,
};

/// What a compiled artifact says about a traceable source site.  Luce
/// functions come first in `mir.Program.functions` order, so an ordinary
/// function index addresses the table directly.  Synthetic constant
/// declaration rows follow them for failures in the pre-entry materializer.
pub const FunctionInfo = extern struct {
    name: [*]const u8,
    name_length: i64,
    /// The file the function was written in, empty in a `--release`
    /// build.
    source: [*]const u8,
    source_length: i64,
    /// One origin per IR instruction, or null in a `--release` build.
    origins: ?[*]const Origin,
    origin_count: i64,
};

/// One call in a reported trace, innermost first.  The text is
/// borrowed from the artifact's constant data, and — like every string
/// crossing this boundary — only for the duration of the call.
pub const Frame = extern struct {
    function: [*]const u8,
    function_length: i64,
    source: [*]const u8,
    source_length: i64,
    /// Zero when the artifact carries no origins (`--release`), which
    /// is exactly when the interpreter reports zero as well.
    line: u32,
    column: u32,
};

/// How a trap reaches the host: once, from `luce_main`, after the
/// program has finished unwinding — the earliest moment the trace
/// exists.  `code` is the numeric value of `mir.TrapCode`; `message`,
/// `frames`, and the text inside them are borrowed for the duration of
/// the call.
pub const ReportFn = *const fn (
    context: ?*anyopaque,
    code: i32,
    message: [*]const u8,
    message_length: i64,
    frames: [*]const Frame,
    frame_count: i64,
    dropped: i64,
) callconv(.c) void;

/// How an uncaught error reaches the host: once, from `luce_main`,
/// when nothing caught it.  `code` is the numeric value of
/// `mir.ErrorCode`; `message` and `origin` are borrowed for the
/// duration of the call.
///
/// **One frame, not a trace** (docs/FAILURE.md).  `origin` is where
/// the error was raised and the only position it carries, because the
/// alternative charges the success path for it.
pub const ErrorReportFn = *const fn (
    context: ?*anyopaque,
    code: i32,
    message: [*]const u8,
    message_length: i64,
    origin: *const Frame,
) callconv(.c) void;

/// A trace keeps this many innermost frames and counts the rest.
/// Runaway recursion would otherwise report the whole depth budget,
/// and the innermost frames are the ones that say anything.  The
/// interpreter caps at the same number, so the two engines report the
/// same trace for the same trap.
pub const max_frames: usize = 64;

test "the C layout is what the code generator builds" {
    // The generator writes these structs as LLVM constants field by
    // field; if the two ever disagree a trace would read rubbish, so
    // the sizes and offsets are asserted rather than assumed.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Origin));
    try std.testing.expectEqual(@as(usize, 6 * 8), @sizeOf(FunctionInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(FunctionInfo, "name"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(FunctionInfo, "name_length"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(FunctionInfo, "source"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(FunctionInfo, "source_length"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(FunctionInfo, "origins"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(FunctionInfo, "origin_count"));
    try std.testing.expectEqual(@as(usize, 5 * 8), @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Frame, "line"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Frame, "column"));
}
