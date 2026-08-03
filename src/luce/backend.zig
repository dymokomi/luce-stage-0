//! The execution boundary of the Luce compiler.
//!
//! Everything in front of this file — lexer, parser, analysis, Luce IR
//! and its verifier — is backend-independent.  This boundary runs one
//! verified program against an Input frame and a scratch Output frame
//! under an explicit budget, per the v1 evaluation model (docs/v1/LUCE.md):
//! immutable inputs, candidate outputs, publish-nothing on failure.
//!
//! The first engine behind the boundary is the deterministic Luce IR
//! interpreter.  A native code generator (the plan's LLVM lowering)
//! slots in behind these same types without changing Luce programs or
//! anything in front of the boundary.

const std = @import("std");
const mir = @import("06_mir.zig");
const runtime = @import("runtime.zig");
const interpreter = @import("interpreter.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// A runtime value.  Strings, bytes, and struct storage are borrowed
/// from the program, the caller's input frame, or the evaluation arena
/// — nothing here owns memory, and nothing outlives the evaluation
/// unless the caller copies it out.  Heap objects (lists, maps,
/// arrays, builders) live in the runtime library's object table; a
/// value only carries the handle.
///
/// This is `libluce_rt`'s own value, not a second one: the boundary
/// hands the engines exactly what the runtime library operates on, so
/// nothing is converted on the way in or out (docs/CODEGEN.md).
pub const RuntimeValue = runtime.Value;

/// One input port slot: a value borrowed for the duration of the
/// evaluation, or unavailable.
pub const InputValue = union(enum) {
    unavailable,
    value: RuntimeValue,
};

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
    /// The output frame holds every written output.
    success: Success,
    /// The evaluator failed; the output frame must not be published.
    trap: Trap,
    /// The program ended with an uncaught error.  The output frame
    /// must not be published either: `main` did not finish.
    errored: Raised,
    /// An input the program reads was unavailable; nothing ran.
    unavailable,
};

/// Deadline analog: evaluation is bounded by instruction steps and
/// call depth, so an accidental infinite loop traps instead of
/// freezing the caller.
pub const Budget = struct {
    steps: u64 = 10_000_000,
    call_depth: u32 = 256,
};

/// Optional trusted services for intrinsically host-facing builtins.
/// Returned slices must remain valid for the evaluation; callbacks may
/// allocate them from `arena`.  Every service is optional and a missing
/// service fails closed — the pure `evaluate` API supplies none, so a
/// program that touches the host traps instead of touching anything.
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

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

/// Where an evaluation's memory comes from: a run-lifetime arena for
/// what a program cannot grow without bound, and an ordinary freeing
/// allocator for everything with a death point — heap objects, and
/// since copy-on-store every String's bytes and every struct value's
/// field run (docs/STRINGS.md).  This is the runtime library's own
/// `Memory`, not a second one.
pub const Memory = runtime.Memory;

/// Run the program's evaluate entry.  `inputs` parallels
/// program.inputs; `outputs` parallels program.outputs and starts
/// empty — on success, written slots carry the candidate outputs
/// (allocated from `memory.arena` where they need storage).  The caller
/// owns both allocators and copies out what it publishes before
/// freeing the arena.
pub fn evaluate(
    memory: Memory,
    program: *const mir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
) error{OutOfMemory}!Result {
    return evaluateHosted(memory, program, inputs, outputs, budget, null);
}

/// Hosted evaluation.  The default `evaluate` API remains pure and
/// supplies no ambient host services.
pub fn evaluateHosted(
    memory: Memory,
    program: *const mir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
    host: ?Host,
) error{OutOfMemory}!Result {
    return interpreter.run(memory, program, inputs, outputs, budget, host);
}

test {
    _ = interpreter;
}
