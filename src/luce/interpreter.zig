//! The Luce IR interpreter — the differential oracle, and this is its
//! header.
//!
//! **It ships in nothing.**  `luce` and `loom` do not reach this
//! package: what runs a Luce program is machine code (`08_llvm`), and
//! what runs *this* is the executable specification, where every
//! program is executed on both and the two are compared on printed
//! bytes, trap code, trap message, call trace frame for frame, leak
//! census and the world each left behind (`specs/agree.zig`,
//! docs/ENGINE.md).  A second implementation that exists to disagree —
//! Rust's Miri, Zig's one behaviour suite over every backend — is
//! worth exactly as much as it is consulted, which is why it is the
//! second arm of every spec rather than of a curated few.
//!
//! Implementation lives in interpreter/:
//!   machine.zig  — Machine struct, Frame, CallOutcome, run(),
//!                  execute() dispatch loop, and the instruction
//!                  decoding that calls `libluce_rt` for every
//!                  semantic (docs/CODEGEN.md).
//!   test.zig     — the oracle testing itself: what only it has, which
//!                  is a frame stack.
//!
//! The object heap, ownership, containers, strings, conversions, and
//! arithmetic used to live here too.  They are `runtime.zig` now, so
//! compiled code and this share one implementation — and that rule is
//! the invariant this package must never break: `machine.zig` calls
//! `runtime.zig`, and a semantic is never written on one side of that
//! line only.
//!
//! The types below were `backend.zig` until the boundary they defined
//! stopped being one.  Stage 10 did not slot in behind them: it
//! brought its own published ABI (`08_llvm/abi.zig`) and `apps/host.zig`
//! builds that table from the same services, which is the better
//! outcome and the reason these are the oracle's shapes now and
//! nobody else's.

const std = @import("std");
const mir = @import("06_mir.zig");
const runtime = @import("runtime.zig");
const machine = @import("interpreter/machine.zig");

const Allocator = std.mem.Allocator;

pub const run = machine.run;
pub const CallOutcome = machine.CallOutcome;
pub const Frame = machine.Frame;
pub const Machine = machine.Machine;

// ---------------------------------------------------------------------------
// What a run answers with
// ---------------------------------------------------------------------------

/// One call in a trap's stack trace.  `function` and `source` borrow
/// from the program; a stripped (--release) module reports line 0.
pub const TraceFrame = struct {
    function: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
};

pub const Trap = struct {
    code: mir.TrapCode,
    /// Arena-owned or static; valid until the evaluation arena frees.
    message: []const u8,
    /// The call stack at the trap, innermost first (arena-owned).
    /// Deep recursion is capped; `dropped` counts what the cap cut.
    trace: []const TraceFrame = &.{},
    dropped: u32 = 0,
};

/// An uncaught error: the program said `-> !` and nothing caught what
/// it raised (docs/FAILURE.md).  Not a trap — nothing about the
/// program is wrong — so it carries news rather than a diagnosis: a
/// code from a closed set of two, the words, and the one position it
/// records, the place it was raised.
pub const Raised = struct {
    code: mir.ErrorCode,
    /// Arena-owned or static; valid until the evaluation arena frees.
    message: []const u8,
    /// Where `error(…)` was written, or where the host said no.  A
    /// stripped (--release) module reports line 0 and still names the
    /// function, exactly as a trap's frames do.
    origin: TraceFrame,
};

pub const Success = struct {
    /// Heap objects still alive when the program returned — memory is
    /// explicit in Luce, so the host reports what was not freed.
    leaked_objects: u32 = 0,
};

pub const Result = union(enum) {
    /// `main` returned.
    success: Success,
    /// The program did something the language forbids and stopped.
    trap: Trap,
    /// The program ended with an uncaught error.
    errored: Raised,
};

/// How deep a program may call.  Runaway recursion traps rather than
/// overflowing the machine's stack — a language promise, kept from the
/// same number on both engines (`08_llvm/abi.zig`'s `call_depth`).
pub const Budget = struct {
    call_depth: u32 = 256,
};

// ---------------------------------------------------------------------------
// The world a run is given
// ---------------------------------------------------------------------------

/// Optional trusted services for intrinsically host-facing builtins.
/// Returned slices must remain valid for the evaluation; callbacks may
/// allocate them from `arena`.  Every service is optional and a missing
/// service fails closed — a run given none computes and touches
/// nothing, which is what makes the same program's effects comparable
/// against the compiled arm's `abi.Host` table.
pub const Host = struct {
    context: *anyopaque,
    /// Console line output for `print`.
    printFn: ?*const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void = null,
    /// Program arguments for `arg_count` / `arg`.  `argFn` returns null
    /// when the index is out of range.
    argCountFn: ?*const fn (context: *anyopaque) u32 = null,
    argFn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        index: u32,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// Plain files for `file_read` / `file_write` / `file_exists`.
    readFileFn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!FileRead = null,
    writeFileFn: ?*const fn (
        context: *anyopaque,
        path: []const u8,
        content: []const u8,
    ) bool = null,
    fileExistsFn: ?*const fn (context: *anyopaque, path: []const u8) bool = null,
    /// The four file operations beside read, write and exists.  Each
    /// answers whether it happened; a `false` becomes the `io_failed`
    /// error the program meets, because the world decided and no
    /// non-racy check stands in for the result (docs/FAILURE.md).
    appendFileFn: ?*const fn (
        context: *anyopaque,
        path: []const u8,
        content: []const u8,
    ) bool = null,
    deleteFileFn: ?*const fn (context: *anyopaque, path: []const u8) bool = null,
    renameFileFn: ?*const fn (
        context: *anyopaque,
        from: []const u8,
        to: []const u8,
    ) bool = null,
    /// The names in a directory, without `.` and `..`, or null when it
    /// could not be listed.  The slices may come from `arena`.
    listDirectoryFn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!?[]const []const u8 = null,
    /// One line of standard input, the prompt written and flushed
    /// first.  Null means end of input, which the program meets as
    /// `none` — nothing there, and no reason worth carrying.
    readLineFn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        prompt: []const u8,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// A line of standard error, for what a program says to a person
    /// while its output belongs to a pipe.
    printErrorFn: ?*const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void = null,
    /// Milliseconds on a monotonic clock of unspecified origin, and a
    /// wait of at least that long.  Neither can fail.
    clockFn: ?*const fn (context: *anyopaque) i64 = null,
    sleepFn: ?*const fn (context: *anyopaque, milliseconds: i64) void = null,
    /// One environment variable, or null when it is unset.
    envFn: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// The interactive screen for the `term_*` and `key_*` builtins.
    terminal: ?Terminal = null,
};

pub const FileRead = union(enum) {
    content: []const u8,
    failed,
};

/// The trusted screen behind the terminal builtins.  The host owns raw
/// mode, buffering, and escape sequences; programs only ever describe
/// what to draw and receive decoded keys.
pub const Terminal = struct {
    context: *anyopaque,
    rowsFn: *const fn (context: *anyopaque) i64,
    colsFn: *const fn (context: *anyopaque) i64,
    clearFn: *const fn (context: *anyopaque) error{OutOfMemory}!void,
    moveFn: *const fn (context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void,
    styleFn: *const fn (
        context: *anyopaque,
        foreground: i64,
        background: i64,
        bold: bool,
    ) error{OutOfMemory}!void,
    writeFn: *const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void,
    flushFn: *const fn (context: *anyopaque) error{OutOfMemory}!void,
    /// Blocks until one key arrives.  Slices must stay valid for the
    /// evaluation; the host may allocate them from `arena`.
    keyFn: *const fn (context: *anyopaque, arena: Allocator) error{OutOfMemory}!KeyEvent,
};

/// One decoded key: a stable name ("text", "enter", "up", "ctrl_s",
/// ...) plus the inserted text when the name is "text".
pub const KeyEvent = struct {
    name: []const u8,
    text: []const u8 = "",
};

/// Where a run's memory comes from: a run-lifetime arena for what a
/// program cannot grow without bound, and an ordinary freeing
/// allocator for everything with a death point — heap objects, and
/// since copy-on-store every String's bytes and every struct value's
/// field run (docs/STRINGS.md).  This is the runtime library's own
/// `Memory`, not a second one: the oracle hands `libluce_rt` exactly
/// what compiled code hands it, so nothing is converted on the way in
/// or out.
pub const Memory = runtime.Memory;

test {
    _ = @import("interpreter/test.zig");
}
