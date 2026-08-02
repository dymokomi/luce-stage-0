//! The published Luce host ABI — the contract between a compiled
//! Luce artifact and whatever loads it (loom, a test, an embedder).
//!
//! A compiled artifact exports exactly one symbol, `luce_main`:
//!
//! ```c
//! int32_t luce_main(const LuceHost *host);
//! ```
//!
//! It returns `0` when the program ran to completion, `1` when it
//! trapped, and `2` when the runtime ran out of memory.  Every *effect*
//! the program needs reaches the outside world through the `LuceHost`
//! table passed in — the artifact declares no undefined symbols beyond
//! `libluce_rt`, which it links statically.  That is deliberate: an
//! undefined `luce_host_print` does not link into a two-level-namespace
//! macOS dylib, and a vtable is the same shape `backend.Host` already
//! has for the interpreter.
//!
//! Effects come through this table; *semantics* do not.  Lists, maps,
//! strings, ownership, and the conversions are `libluce_rt` calls, not
//! host calls, because they are the language rather than a capability
//! the host may withhold (docs/CODEGEN.md).
//!
//! Compatibility rules for this file:
//!
//!   * Fields are append-only and never reordered.  Their order is the
//!     memory layout the generated code indexes with `getelementptr`.
//!   * Any change to an existing field's meaning or signature bumps
//!     `version`.
//!   * A host that supplies a table built for an older `version` must
//!     be refused by the loader, not tolerated.

const std = @import("std");
const runtime = @import("../runtime.zig");

/// The ABI version a compiled artifact was built against.  Bumped
/// whenever a field's meaning or signature changes.
///
/// 2 — `str_int` left the table for `libluce_rt`, where a pure
/// conversion belongs, and `finished` arrived to carry the leak census.
///
/// 3 — the remaining host services arrived (files, arguments, the
/// terminal), and with them the one answer every service now gives:
/// `print` returns an `Answer` where it used to return nothing.
///
/// 4 — a trap became a whole trap.  `trap` now carries the call trace
/// as well as the code and the words, and is called once when the
/// program has stopped rather than at the site, because the trace does
/// not exist until unwinding is over (`runtime/trace.zig`).  The
/// `call_depth` service arrived with it: how many Luce frames the host
/// allows, which is what makes runaway recursion a `call_depth_exceeded`
/// trap on this path instead of a native stack overflow.
pub const version: u32 = 4;

/// The one symbol a compiled Luce artifact exports.
pub const entry_symbol = "luce_main";

/// What `luce_main` returns.  The same three answers `libluce_rt`'s
/// `luce_rt_status` gives, because that is where they come from.
pub const Status = enum(i32) {
    /// The program ran to completion.
    ok = 0,
    /// The program trapped; `Host.trap` was called with the details.
    trapped = 1,
    /// The runtime could not get memory.  Nothing about the program
    /// was wrong, so this is not a trap.
    exhausted = 2,
    _,
};

/// The C signature of `luce_main`.
pub const Entry = *const fn (host: *const Host) callconv(.c) Status;

/// What every host service answers.  One convention for all of them,
/// so generated code checks the same two things at every call site.
///
/// Strings a service hands back travel through out-parameters and are
/// borrowed for the duration of the call only: the generated code
/// copies them into the run's arena before the host can reuse the
/// storage.
pub const Answer = enum(i32) {
    /// The host could not get memory.  Nothing about the program was
    /// wrong, so this is not a trap: the run ends `exhausted`, the same
    /// answer the runtime library gives when its arena gives up.
    exhausted = -1,
    /// The service says no — the file could not be read, the argument
    /// index is out of range.  What that means is the caller's to
    /// decide; a service whose only job is an effect never answers it.
    no = 0,
    /// Done.  Anything produced is in the out-parameters.
    yes = 1,
    _,
};

/// Console line output for `print`.  Optional: a null slot means the
/// service does not exist, and the program traps `host_unavailable`
/// rather than touching anything (`docs/V2.md`'s fail-closed rule).
/// Every service below is optional on the same terms.
pub const PrintFn = *const fn (
    context: ?*anyopaque,
    text: [*]const u8,
    length: i64,
) callconv(.c) Answer;

/// Report a trap.  Called once, when the program has stopped and
/// immediately before `luce_main` returns `.trapped`.  `code` is the
/// numeric value of `mir.TrapCode`; the message, the frames, and the
/// text inside them are borrowed for the duration of the call only.
///
/// Not at the trap site, which is where it used to be: a trap carries
/// its call trace, and the trace does not exist until the program has
/// finished unwinding.  Every frame records itself on the way out and
/// the finished trace arrives here with the trap it belongs to, rather
/// than the host being told half of it twice (`runtime/trace.zig`).
///
/// `dropped` counts the frames the trace's cap cut, so a runaway
/// recursion reports its innermost calls and a number, not a wall of
/// text.
///
/// Required: unlike the effect services this is part of the runtime
/// contract, not a capability, and `luce_main` calls it without a null
/// check.  A trap raised inside `libluce_rt` and one raised inline by
/// generated code arrive here by the same door.
pub const TrapFn = runtime.trace.ReportFn;

/// One call in a trap's trace, innermost first.  A `--release`
/// artifact reports line and column zero and still names the function.
pub const TraceFrame = runtime.trace.Frame;

/// How many nested Luce calls the host allows before the program traps
/// `call_depth_exceeded`.  Optional: a null slot means
/// `default_call_depth`.
///
/// This is the same policy limit the interpreter takes as
/// `backend.Budget.call_depth`, and it exists for the same reason.
/// Luce promises that runaway recursion is a trap with a message and a
/// trace, never a native stack overflow — so somebody has to say how
/// deep is too deep, and it is the host, which is the only party that
/// knows how much stack it has.  Answering an absurd number does not
/// make the promise stronger: the machine's own stack is still finite,
/// and a limit above what it can hold is a limit that never fires.
pub const CallDepthFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// The depth a host that says nothing gets.  Identical to
/// `backend.Budget.call_depth`, so a program that recurses too far
/// traps at the same call on both engines.
pub const default_call_depth: i64 = 256;

/// The run ended without trapping, leaving `leaked` objects alive.
/// Memory is explicit in Luce, so what a program did not free is part
/// of what it did, and a host that wants to say so reads it here.
/// Optional: a null slot simply means nobody is counting.
pub const FinishedFn = *const fn (
    context: ?*anyopaque,
    leaked: i64,
) callconv(.c) void;

/// Read a whole file.  `yes` fills `text`/`length` with bytes borrowed
/// for the duration of the call; `no` means the read failed and the
/// program traps `file_read_failed`.
pub const FileReadFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// Write a whole file.  `no` is the answer `file_write` gives the
/// program as `false`, not a trap: a program may ask whether a write
/// worked.
pub const FileWriteFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
    content: [*]const u8,
    content_length: i64,
) callconv(.c) Answer;

/// Whether a file exists.  `no` is the program-visible `false`.
pub const FileExistsFn = *const fn (
    context: ?*anyopaque,
    path: [*]const u8,
    path_length: i64,
) callconv(.c) Answer;

/// How many program arguments there are.  Cannot fail, so it answers
/// the count directly rather than an `Answer`.
pub const ArgCountFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// One program argument, borrowed for the duration of the call.  `no`
/// means the index is out of range and the program traps
/// `argument_bounds`.
pub const ArgFn = *const fn (
    context: ?*anyopaque,
    index: i64,
    text: *[*]const u8,
    length: *i64,
) callconv(.c) Answer;

/// The screen's size.  Cannot fail: a host with no real terminal
/// answers whatever it considers the window to be.
pub const TermSizeFn = *const fn (context: ?*anyopaque) callconv(.c) i64;

/// `term_clear` and `term_flush`, which take nothing and only ever
/// answer `yes` or `exhausted`.
pub const TermPlainFn = *const fn (context: ?*anyopaque) callconv(.c) Answer;

pub const TermMoveFn = *const fn (
    context: ?*anyopaque,
    row: i64,
    col: i64,
) callconv(.c) Answer;

pub const TermStyleFn = *const fn (
    context: ?*anyopaque,
    foreground: i64,
    background: i64,
    bold: i32,
) callconv(.c) Answer;

pub const TermWriteFn = *const fn (
    context: ?*anyopaque,
    text: [*]const u8,
    length: i64,
) callconv(.c) Answer;

/// Block until one key arrives, and describe it: a stable name
/// ("text", "enter", "ctrl_s", ...) and the inserted text when the name
/// is "text".  Both are borrowed for the duration of the call.
///
/// `key_text` has no slot of its own and needs none: it answers what
/// the last `key_read` carried, which the runtime remembers, so it
/// reaches nothing and a program that never read a key gets "".
pub const KeyReadFn = *const fn (
    context: ?*anyopaque,
    name: *[*]const u8,
    name_length: *i64,
    text: *[*]const u8,
    text_length: *i64,
) callconv(.c) Answer;

/// The service table handed to `luce_main`.
///
/// The struct is `extern` so its layout is the C layout the generated
/// code assumes: `context` first, then one pointer-sized slot per
/// service in declaration order.  `Slot` names those positions once so
/// the lowering and this struct cannot drift.
pub const Host = extern struct {
    /// Opaque host state, passed back to every callback.
    context: ?*anyopaque = null,
    /// Optional — a null slot traps `host_unavailable`.
    print: ?PrintFn = null,
    /// Required.
    trap: TrapFn,
    /// Optional — the leak census, reported once at the end of a run
    /// that did not trap.
    finished: ?FinishedFn = null,
    file_read: ?FileReadFn = null,
    file_write: ?FileWriteFn = null,
    file_exists: ?FileExistsFn = null,
    arg_count: ?ArgCountFn = null,
    arg: ?ArgFn = null,
    term_rows: ?TermSizeFn = null,
    term_cols: ?TermSizeFn = null,
    term_clear: ?TermPlainFn = null,
    term_move: ?TermMoveFn = null,
    term_style: ?TermStyleFn = null,
    term_write: ?TermWriteFn = null,
    term_flush: ?TermPlainFn = null,
    key_read: ?KeyReadFn = null,
    /// Optional — a null slot means `default_call_depth`.  Not an
    /// effect: a policy the host sets, like the interpreter's budget.
    call_depth: ?CallDepthFn = null,
};

/// The index of each `Host` field, as the generated code addresses it.
/// `getelementptr` walks a struct of `count` pointers with these
/// indices, so the order here is the memory layout above.
pub const Slot = enum(u32) {
    context = 0,
    print = 1,
    trap = 2,
    finished = 3,
    file_read = 4,
    file_write = 5,
    file_exists = 6,
    arg_count = 7,
    arg = 8,
    term_rows = 9,
    term_cols = 10,
    term_clear = 11,
    term_move = 12,
    term_style = 13,
    term_write = 14,
    term_flush = 15,
    key_read = 16,
    call_depth = 17,

    pub const count = @typeInfo(Slot).@"enum".fields.len;
};

test "the slot table matches the struct layout" {
    inline for (@typeInfo(Slot).@"enum".fields) |field| {
        try std.testing.expectEqual(
            @as(usize, field.value) * @sizeOf(usize),
            @offsetOf(Host, field.name),
        );
    }
    try std.testing.expectEqual(@as(usize, Slot.count) * @sizeOf(usize), @sizeOf(Host));
}

test "the host's trap callback is the runtime's reporter, not a copy of it" {
    try std.testing.expect(TrapFn == runtime.trace.ReportFn);
    try std.testing.expect(TraceFrame == runtime.trace.Frame);
}
