//! The Luce IR interpreter — the differential oracle, and this is its
//! header.
//!
//! **It ships in nothing.**  `luce` and `loom` do not reach this
//! package: what runs a Luce program is machine code (`llvm`), and
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
//! brought its own published ABI (`codegen/abi.zig`) and `apps/host.zig`
//! builds that table from the same services, which is the better
//! outcome and the reason these are the oracle's shapes now and
//! nobody else's.

const std = @import("std");
const mir = @import("mir.zig");
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
    /// Heap objects still alive when the trap stopped the run.  A trap
    /// unwinds without scope releases, so the census is part of the
    /// observable result just as it is for a normal return.
    leaked_objects: u32 = 0,
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
    /// Heap objects still alive when the uncaught error stopped the run.
    leaked_objects: u32 = 0,
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
    /// The program said `exit(status)` — its chosen end, the fourth
    /// way a run stops (docs/LANGUAGE.md).  The unwind skips releases
    /// exactly as a trap's does, so `leaked_objects` counts what was
    /// standing, the same census the compiled path reports.
    exited: Exited,
};

pub const Exited = struct {
    status: i64,
    leaked_objects: u32 = 0,
};

/// How deep a program may call.  Runaway recursion traps rather than
/// overflowing the machine's stack — a language promise, kept from the
/// same number on both engines (`codegen/abi.zig`'s `call_depth`).
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
///
/// **One naming rule, and it is the ABI's:** every slot below is named
/// for the Luce builtin it stands behind, spelled exactly as
/// `codegen/abi.zig`'s `LuceHost` spells it — `file_read`, `dir_list`,
/// `clock_ms`, `term_write`.  The two tables are the one seam the
/// executable specification exists to compare frame for frame
/// (docs/ENGINE.md), so they line up row for row and a reader who has
/// learned one has learned the other.  No `Fn` suffix: the field's type
/// already says it is a function.
pub const Host = struct {
    context: *anyopaque,
    /// Console line output for `print`.
    print: ?*const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void = null,
    /// Program arguments for `arg_count` / `arg`.  `arg` returns null
    /// when the index is out of range.
    arg_count: ?*const fn (context: *anyopaque) u32 = null,
    arg: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        index: u32,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// What is at a path — 0 nothing, 1 a file, 2 a directory, 3
    /// something else — or null for a world that will not say, which
    /// the program meets as `io_failed` (docs/FILESYSTEM.md D16).
    ///
    /// **Links are followed**, so the kind is the kind of the thing
    /// the path names and a dangling link is 0.  It replaces
    /// `file_exists`, whose bool could not tell "nothing is there"
    /// from "I was not allowed to look".
    path_kind: ?*const fn (context: *anyopaque, path: []const u8) ?i64 = null,
    /// The file operations that are about a *name* rather than about
    /// bytes.  Each answers whether it happened; a `false` becomes the
    /// `io_failed` error the program meets, because the world decided
    /// and no non-racy check stands in for the result
    /// (docs/FAILURE.md).
    ///
    /// **`file_read`, `file_write` and `file_append` are not here any
    /// more** (docs/BYTES.md R2).  They were whole-file text services
    /// each host implemented, which meant each host owned an opinion
    /// about what "not text" means; they are open-read-close over
    /// `files` below plus `libluce_rt`'s own UTF-8 validation now, and
    /// there is one opinion.  The `abi.Host` slots they answered to
    /// retired in the same movement.
    file_delete: ?*const fn (context: *anyopaque, path: []const u8) bool = null,
    file_rename: ?*const fn (
        context: *anyopaque,
        from: []const u8,
        to: []const u8,
    ) bool = null,
    /// The names in a directory, without `.` and `..`, or null when it
    /// could not be listed.  The slices may come from `arena`.
    dir_list: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!?[]const []const u8 = null,
    /// Make a directory and every directory leading to it, answering
    /// whether there is one there now.  A directory already in place
    /// is `true`, and a *file* holding the name is `false` — the
    /// caller asked for a directory and there is not one.  The `false`
    /// becomes the `io_failed` the program meets, exactly as the file
    /// services above do (`abi.DirCreateFn` says the same rules on the
    /// other table).
    dir_create: ?*const fn (context: *anyopaque, path: []const u8) bool = null,
    /// One line of standard input, the prompt written and flushed
    /// first.  Null means end of input, which the program meets as
    /// `none` — nothing there, and no reason worth carrying.
    read_line: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        prompt: []const u8,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// A line of standard error, for what a program says to a person
    /// while its output belongs to a pipe.
    print_error: ?*const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void = null,
    /// Milliseconds on a monotonic clock of unspecified origin, and a
    /// wait of at least that long.  Neither can fail.
    clock_ms: ?*const fn (context: *anyopaque) i64 = null,
    sleep_ms: ?*const fn (context: *anyopaque, milliseconds: i64) void = null,
    /// Milliseconds since the Unix epoch — what time it is, which the
    /// monotonic clock above cannot say.  Null *from* it — as distinct
    /// from the slot itself being null — means this host has no
    /// calendar, which the program meets as `host_unavailable`: the
    /// same shape the machine facts take, and for the same reason
    /// (`abi.EpochFn`).
    epoch_ms: ?*const fn (context: *anyopaque) ?i64 = null,
    /// One environment variable, or null when it is unset.
    env: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// Run one command through the host shell, feeding `input` to its
    /// standard input.  The returned text is borrowed from `arena`; a
    /// null answer means the shell itself could not be started and
    /// becomes `io_failed` for the command.
    shell_run: ?*const fn (
        context: *anyopaque,
        arena: Allocator,
        command: []const u8,
        input: []const u8,
    ) error{OutOfMemory}!?[]const u8 = null,
    /// The program said `exit(status)`.  Called at the site, before
    /// the unwind, so the host holds the number while the program is
    /// still leaving — the same moment `abi.Host.exited` is called on
    /// the compiled path.
    exited: ?*const fn (context: *anyopaque, status: i64) void = null,
    /// The machine's own facts, behind `std.os`: bytes of physical
    /// memory, bytes still available, processors.  Null *from* one of
    /// these — as distinct from the slot itself being null — means
    /// this host cannot tell, which the program meets as
    /// `host_unavailable` exactly as a withheld service would.  It is
    /// the `no` on `abi.MachineFactFn`, and no host is ever made to
    /// invent a number.
    os_total_memory: ?*const fn (context: *anyopaque) ?i64 = null,
    os_available_memory: ?*const fn (context: *anyopaque) ?i64 = null,
    os_cpu_count: ?*const fn (context: *anyopaque) ?i64 = null,
    /// The interactive screen for the `term_*` and `key_*` builtins.
    terminal: ?Terminal = null,

    /// The byte channel behind file handles (docs/BYTES.md R2).
    ///
    /// **The one slot on this table that is C-shaped, and deliberately
    /// so.**  Every other row here is a Zig twin of an `abi.Host` row,
    /// written twice because the two engines reach a host differently;
    /// this one is not reached by the engine at all.  `libluce_rt`
    /// holds it for the whole run and calls it — a handle's close
    /// happens inside the ownership walk, where no engine is standing
    /// — so both engines install the *same five function pointers*,
    /// and a host writes them once.  That is one implementation of the
    /// file channel rather than two that could disagree, which is what
    /// moving UTF-8 validation into the runtime was for.
    files: runtime.files.Channel = .{},

    /// The transport channel behind `std.network` (docs/NETWORK.md).
    /// C-shaped for the reason `files` is, with one contract of its
    /// own: its callbacks block for a peer, run outside the Effects
    /// serialization, and must therefore be thread-safe.
    sockets: runtime.sockets.Channel = .{},

    /// The backend-neutral window/GPU channel behind `std.ui` and
    /// `std.gpu`.  Like files, it is C-shaped and installed into the
    /// shared runtime so resource close happens after the owning scope
    /// releases, not in a second interpreter-only lifetime path.
    graphics: runtime.graphics.Channel = .{},

    /// The thread channel behind `spawn` (docs/THREADS.md D8).
    ///
    /// C-shaped for the reason `files` is, and one step more so: a
    /// task's join happens inside the ownership walk, and the thing
    /// the host is asked to start is a C function `libluce_rt` wrote.
    /// Both engines install the *same two function pointers*, so a
    /// host writes its threading once and neither engine has an
    /// opinion about it.
    ///
    /// What the two engines *do* differ on is the other half — how a
    /// runtime is made for a worker and how one function is run in it
    /// — and that is `runtime.workers.Nursery`, filled by each engine
    /// rather than by a host, because a machine has no answer to it.
    workers: runtime.workers.Channel = .{},
};

/// The trusted screen behind the terminal builtins.  The host owns raw
/// mode, buffering, and escape sequences; programs only ever describe
/// what to draw and receive decoded keys.
///
/// Its slots keep the builtin's whole name, `term_` and all, because
/// `abi.Host` is one flat table and the rule above is that the two line
/// up: `terminal.term_write` and `abi.Host.term_write` are the same row.
pub const Terminal = struct {
    context: *anyopaque,
    term_rows: *const fn (context: *anyopaque) i64,
    term_cols: *const fn (context: *anyopaque) i64,
    term_clear: *const fn (context: *anyopaque) error{OutOfMemory}!void,
    term_move: *const fn (context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void,
    term_style: *const fn (
        context: *anyopaque,
        foreground: i64,
        background: i64,
        bold: bool,
    ) error{OutOfMemory}!void,
    term_write: *const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void,
    term_copy: *const fn (context: *anyopaque, text: []const u8) error{OutOfMemory}!void,
    term_flush: *const fn (context: *anyopaque) error{OutOfMemory}!void,
    /// Numeric data belonging to the most recently returned event: row,
    /// column, button, modifiers, or wheel value by field number.  The
    /// result is zero for unknown fields and keyboard events use defaults.
    event_data: *const fn (context: *anyopaque, field: i64) i64,
    /// Blocks until one key arrives, or answers null when no key ever
    /// will — the pipe driving it ended, the terminal closed.  Slices
    /// must stay valid for the evaluation; the host may allocate them
    /// from `arena`.
    ///
    /// Null and not a name in the closed set: end of input is absence,
    /// which the program meets as `none`, and it is the same fact
    /// `read_line` answers null for off the same descriptor
    /// (docs/FAILURE.md).  A host that cannot say it is a host whose
    /// caller loops forever asking.
    key_read: *const fn (context: *anyopaque, arena: Allocator, timeout_ms: i64) error{OutOfMemory}!?KeyEvent,
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
/// since copy-on-store every string's bytes and every struct value's
/// field run (docs/STRINGS.md).  This is the runtime library's own
/// `Memory`, not a second one: the oracle hands `libluce_rt` exactly
/// what compiled code hands it, so nothing is converted on the way in
/// or out.
pub const Memory = runtime.Memory;

test {
    _ = machine;
    _ = @import("interpreter/test.zig");
}
