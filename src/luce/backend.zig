//! The execution boundary of the Luce compiler.
//!
//! Everything in front of this file — lexer, parser, analysis, Luce IR
//! and its verifier — is backend-independent.  This boundary runs one
//! verified program against an Input frame and a scratch Output frame
//! under an explicit budget, per docs/LUCE.md's evaluation model:
//! immutable inputs, candidate outputs, publish-nothing on failure.
//!
//! The first engine behind the boundary is the deterministic Luce IR
//! interpreter.  A native code generator (the plan's LLVM lowering)
//! slots in behind these same types without changing Luce programs or
//! anything in front of the boundary.

const std = @import("std");
const ir = @import("ir.zig");
const fabric = @import("fabric.zig");
const interpreter = @import("interpreter.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// A runtime value.  Strings, bytes, and struct storage are borrowed
/// from the program, the caller's input frame, or the evaluation arena
/// — nothing here owns memory, and nothing outlives the evaluation
/// unless the caller copies it out.  Heap objects (lists, maps,
/// arrays, builders) live in the interpreter's object table; a value
/// only carries the handle.
pub const RuntimeValue = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
    strukt: []RuntimeValue,
    object: ObjectHandle,
};

/// A reference to one heap object for the duration of an evaluation.
/// The zero value of an object-typed place is the null handle; using
/// it traps instead of touching anything.
pub const ObjectHandle = struct {
    index: u32,

    pub const null_object: ObjectHandle = .{ .index = std.math.maxInt(u32) };

    pub fn isNull(self: ObjectHandle) bool {
        return self.index == std.math.maxInt(u32);
    }
};

/// One input port slot: a value borrowed for the duration of the
/// evaluation, or unavailable.
pub const InputValue = union(enum) {
    unavailable,
    value: RuntimeValue,
};

pub const Trap = struct {
    code: ir.TrapCode,
    /// Arena-owned or static; valid until the evaluation arena frees.
    message: []const u8,
};

pub const Success = struct {
    /// Intents the program computed (arena-owned, often empty); the
    /// trusted host applies them after publication.
    intents: fabric.Intents = .{},
    /// Heap objects still alive when the program returned — memory is
    /// explicit in Luce, so the host reports what was not freed.
    leaked_objects: u32 = 0,
};

pub const Result = union(enum) {
    /// The output frame holds every written output.
    success: Success,
    /// The evaluator failed; the output frame must not be published
    /// and any intents are discarded.
    trap: Trap,
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

/// Run the program's evaluate entry.  `inputs` parallels
/// program.inputs; `outputs` parallels program.outputs and starts
/// empty — on success, written slots carry the candidate outputs
/// (allocated from `arena` where they need storage).  The caller owns
/// the arena and copies out what it publishes before freeing it.
pub fn evaluate(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
) error{OutOfMemory}!Result {
    return evaluateHosted(arena, program, inputs, outputs, budget, null);
}

/// Hosted evaluation.  The default `evaluate` API remains pure and
/// supplies no ambient host services.
pub fn evaluateHosted(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
    host: ?Host,
) error{OutOfMemory}!Result {
    return interpreter.run(arena, program, inputs, outputs, budget, host);
}

test {
    _ = interpreter;
}
