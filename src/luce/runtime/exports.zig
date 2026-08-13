//! The C surface of `libluce_rt` — what a compiled Luce artifact
//! actually calls.
//!
//! Everything here is `callconv(.c)` over plain scalars and pointers to
//! `Value`; no Zig-only type crosses this line, so the same library
//! links into a native executable, a shared `.lc`, or a wasm32 module
//! (docs/CODEGEN.md).
//!
//! ## Conventions, all three of them
//!
//! * **A fallible call returns `i32`: 1 means the program trapped.**
//!   That is the convention generated code already uses for Luce
//!   functions (`08_llvm/lower.zig`), so a runtime call propagates
//!   through the same `if (trapped) return true` edge as any other Luce
//!   call, with no second mechanism to keep in step.  It is an `i32`
//!   rather than a C `_Bool` because `_Bool` is the one scalar whose
//!   width and extension rules differ between LLVM's IR-level `i1` and
//!   the platform ABI's byte; a full word cannot be got wrong.
//! * **Results travel through an out-pointer**, again as Luce functions
//!   do.  Nothing is returned by value except a plain scalar answer.
//! * **The trap is announced once, when the program has stopped.**  A
//!   trap raised inline by generated code and a trap raised inside this
//!   library both land in `Runtime.pending`; every frame records itself
//!   on the way out; and `luce_rt_report` hands the host the code, the
//!   words, and the finished call trace together.  One trap channel,
//!   and it reports the whole trap rather than half of it — the trace
//!   does not exist until unwinding is over (trace.zig).
//!
//! Allocation failure is normally not a Luce trap: no running program
//! can cause it deliberately and none can catch it.  It sets
//! `Runtime.exhausted`, reports itself as a trapped call, and
//! `luce_rt_status` turns it into a status of its own so a host can tell
//! "the program failed" from "the machine ran out".  Eager constant
//! materialization is the one named allocation in front of `main`, so
//! failure there is the located `allocation_failed` trap its declaration
//! promised (CONSTANTS.md R-C).
//!
//! ## Who owns what
//!
//! Two more conventions, and they are what a caller most needs:
//!
//! * **Every `*const Value` argument is a borrow the call does not
//!   keep**, unless the symbol or its section says the call *consumes*
//!   it.  Consuming means the storage that value owned now belongs to
//!   whatever received it, and the caller must not release it again —
//!   the copy, where one is needed, stands in the IR in front of the
//!   call as `own_storage` (docs/STRINGS.md), never inside it.
//! * **Every `out: *Value` is written only on success**, and what it
//!   receives is owned by the statement that asked for it until
//!   something stores it.  A call that answers 1 leaves `out` untouched,
//!   because a trapped call has no result to give.
//!
//! Nothing here hands back memory a caller has to free by itself: the
//! run owns every object and every byte of storage, and `luce_rt_close`
//! ends all of it at once.
//!
//! ## Why the entry points are `pub`
//!
//! Nothing in Zig calls them — they exist for the linker.  They are
//! `pub` so that `08_llvm/runtime_effects.zig` can name them: the
//! backend keeps a second description of this surface, one arm per
//! symbol, from which it builds the LLVM `declare`.  A C object file
//! carries no signatures, so a `declare` with the wrong arity links
//! cleanly and corrupts the stack at run time; the only thing that can
//! catch it is a test that reads *this* signature.  One does
//! (`runtime_effects.zig`, last test), and it needs a name to read.

const builtin = @import("builtin");
const std = @import("std");
const vocabulary = @import("../support/vocabulary.zig");
const containers = @import("containers.zig");
const files = @import("files.zig");
const heap = @import("heap.zig");
const operators = @import("operators.zig");
const text = @import("text.zig");
const trace = @import("trace.zig");
const workers = @import("workers.zig");
const value = @import("value.zig");

const Runtime = heap.Runtime;
const Value = value.Value;

/// What `luce_rt_status` answers, and what `luce_main` returns.
///
/// **`errored` is 3 and not 2.**  docs/FAILURE.md said "1 is trapped,
/// 2 becomes errored" — and 2 was already `exhausted`, which had
/// arrived between the memo and the build.  Renumbering a published
/// status to make room would have been a silent change of meaning for
/// every existing loader, so the new answer took the next free number.
pub const Status = enum(i32) {
    ok = 0,
    trapped = 1,
    /// The arena gave up; nothing about the program was wrong.
    exhausted = 2,
    /// The program ended with an uncaught error — `main() -> !` said
    /// so out loud.  Not a trap: nothing about the program is wrong,
    /// the world said no and nobody caught it.
    errored = 3,
    /// The program said `exit(status)` — its chosen end, the fourth
    /// way a run stops.  The status itself is `Runtime.exit_status`,
    /// read through `luce_rt_exit_status`.
    exited = 4,
};

/// The outcome of a call, as generated code passes it around: what a
/// Luce function returns, and what a fallible `luce_rt_*` call
/// answers.  A runtime call is never `raised_error` — the runtime
/// library implements semantics, and no semantic is an error
/// (docs/FAILURE.md).
const survived: i32 = 0;
const raised_trap: i32 = 1;
const raised_error: i32 = 2;

/// The runtime plus the memory it draws on, for the C entry point that
/// has no allocator to be given.  Heap-allocated and never moved: the
/// runtime holds an allocator pointing into `arena`.
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    runtime: Runtime,
};

/// Where a compiled artifact's heap objects live.  Unlike the values
/// arena this one has to give memory back — scope ownership frees
/// objects while the program runs (`heap.Memory`) — so it is a real
/// general-purpose allocator rather than a bump.
///
/// libc's is the one to use when there is a libc, and there is: the
/// library is built with `link_libc`.  The alternative was measured
/// rather than assumed — a loop creating and freeing 300k small lists
/// peaks at 1 MB under `c_allocator` and 514 MB under
/// `smp_allocator`, which bump-allocates a slab per size class and did
/// not reuse this pattern, at identical speed.  The fallback is only
/// for a future freestanding build, which has no other option.
const object_allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.smp_allocator;

/// Where a compiled artifact's Strings and struct runs live: a bump
/// arena over whole pages, dropped in one go by `luce_rt_close`.
const value_pages = std.heap.page_allocator;

/// Start a run.  `functions` describes the artifact's own functions —
/// their names, their source files, and (in a debug build) where each
/// instruction came from — which is what turns a recorded frame into a
/// line of a call trace (trace.zig).  Null when there is no memory to
/// start in.
pub export fn luce_rt_open(
    functions: ?[*]const trace.FunctionInfo,
    count: i64,
) callconv(.c) ?*Runtime {
    const function_count = std.math.cast(usize, count) orelse return null;
    if (functions == null and function_count != 0) return null;
    const owned = object_allocator.create(Owned) catch return null;
    owned.arena = .init(value_pages);
    owned.runtime = .init(.{
        .arena = owned.arena.allocator(),
        .objects = object_allocator,
    });
    if (functions) |described| owned.runtime.functions = described[0..function_count];
    return &owned.runtime;
}

/// End a run: every object still alive, every string, and the object
/// table go at once.  The runtime pointer is invalid afterwards.
pub export fn luce_rt_close(runtime: *Runtime) callconv(.c) void {
    const owned: *Owned = @fieldParentPtr("runtime", runtime);
    owned.runtime.deinit();
    owned.arena.deinit();
    object_allocator.destroy(owned);
}

/// Objects allocated and never freed — the leak census.  Memory is
/// explicit in Luce, so this is part of what a run did, and every host
/// (native, wasm, the specs) reads it from here.
pub export fn luce_rt_leaked(runtime: *const Runtime) callconv(.c) i64 {
    return runtime.leaked();
}

/// How the run ended, given the outcome the entry function answered.
pub export fn luce_rt_status(runtime: *const Runtime, outcome: i32) callconv(.c) Status {
    if (runtime.exhausted) return .exhausted;
    if (runtime.exit_status != null) return .exited;
    if (outcome == raised_error) return .errored;
    return if (outcome != survived) .trapped else .ok;
}

/// The program chose to stop: record the status and let the unwind
/// ride the trap edge, exactly as exhaustion does.  Nothing lands in
/// `Runtime.pending`, so `luce_rt_report` reports nothing — an exit
/// is not news about a bug.  The status itself travels through the
/// host's `exited` slot, called at the exit site before this; here it
/// only decides what `luce_rt_status` answers.
pub export fn luce_rt_exit(runtime: *Runtime, status: i64) callconv(.c) void {
    runtime.exit_status = status;
}

// ---------------------------------------------------------------------------
// Traps and the trace they carry
// ---------------------------------------------------------------------------

/// A trap generated code raised itself — a failed check, an explicit
/// `trap("...")`.  It lands in the same place as a trap raised inside
/// this library, so the host hears about both the same way.
///
/// `message` is borrowed for the length of this call and no longer:
/// the trap channel copies it (`heap.failMessage`), because a Luce
/// String short enough to live inside its value points into the
/// caller's own frame, and that frame goes as soon as this returns.
/// `code` is `vocabulary.TrapCode` from
/// the build that generated the code, which is this one — an artifact
/// carrying anything else is corrupt, and the conversion says so
/// loudly rather than inventing a trap.
pub export fn luce_rt_raise(
    runtime: *Runtime,
    code: i32,
    message: [*c]const u8,
    length: i64,
) callconv(.c) void {
    const words = checkedBytes(runtime, message, length) catch return;
    const raised: vocabulary.TrapCode = std.enums.fromInt(vocabulary.TrapCode, code) orelse {
        _ = runtime.fail(.host_unavailable) catch {};
        return;
    };
    runtime.failMessage(raised, words) catch {};
}

/// One frame of the unwinding stack, recorded on the way out: the
/// function it was in and the instruction it was at.  Called once per
/// frame, innermost first, so what arrives is the trace in order.
pub export fn luce_rt_unwound(
    runtime: *Runtime,
    function: u32,
    instruction: u32,
) callconv(.c) void {
    runtime.recordFrame(function, instruction);
}

/// Hand the host the whole trap: its code, its words, and the call
/// trace the unwind collected.  Called once, from `luce_main`, after
/// the program has stopped — nothing is reported for a run that ended
/// any other way, and a run that ran out of memory reports nothing at
/// all because nothing about the program was wrong.
pub export fn luce_rt_report(
    runtime: *const Runtime,
    context: ?*anyopaque,
    report: ?trace.ReportFn,
) callconv(.c) void {
    if (runtime.exhausted) return;
    const raised = runtime.pending orelse return;
    const callback = report orelse return;
    callback(
        context,
        @intFromEnum(raised.code),
        raised.message.ptr,
        @intCast(raised.message.len),
        runtime.unwound.items.ptr,
        @intCast(runtime.unwound.items.len),
        runtime.dropped_frames,
    );
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// `error("…")` — the program raised an error of its own.  The words
/// are a Luce String, which outlives the run.  `function` and
/// `instruction` say where it was written, and are resolved here and
/// only here: an error records its raise site and nothing else.
pub export fn luce_rt_raise_error(
    runtime: *Runtime,
    code: i32,
    message: [*c]const u8,
    length: i64,
    function: u32,
    instruction: u32,
) callconv(.c) void {
    const words = checkedBytes(runtime, message, length) catch return;
    const raised: vocabulary.ErrorCode = std.enums.fromInt(vocabulary.ErrorCode, code) orelse {
        _ = runtime.fail(.host_unavailable) catch {};
        return;
    };
    runtime.raise(raised, words, runtime.frameAt(function, instruction));
}

/// A host file service answered `no`.  The words that names the path
/// are built in the library, so both engines report the same sentence.
pub export fn luce_rt_raise_io(
    runtime: *Runtime,
    act: i32,
    path: [*c]const u8,
    length: i64,
    function: u32,
    instruction: u32,
) callconv(.c) void {
    const named = checkedBytes(runtime, path, length) catch return;
    const action: vocabulary.FileAct = std.enums.fromInt(vocabulary.FileAct, act) orelse {
        _ = runtime.fail(.host_unavailable) catch {};
        return;
    };
    runtime.raiseIo(
        action,
        named,
        runtime.frameAt(function, instruction),
    );
}

/// The words the pending error carries — what `catch NAME:` binds.
///
/// A **borrow**, exactly as `key_text` is: the message lives in the
/// run's arena, which nothing releases, so handing back a view costs no
/// allocation and the place that keeps it copies in the ordinary way
/// (docs/STRINGS.md).  Stage 4 emits this — and the copy — in front of
/// the `forget` beside it, so the channel it reads is never the empty
/// one; an empty channel would mean damaged IR, and answering `""`
/// keeps a damaged module from reading whatever the last error left
/// behind.
pub export fn luce_rt_error_message(runtime: *Runtime, out: [*c]Value) callconv(.c) void {
    if (!requireValueOut(runtime, out)) return;
    const raised = runtime.raised orelse {
        out.* = Value.ofString("");
        return;
    };
    out.* = Value.ofString(raised.message);
}

/// `catch` handled it: forget the error and its words.
pub export fn luce_rt_forget_error(runtime: *Runtime) callconv(.c) void {
    runtime.forget();
}

/// Hand the host an uncaught error: its code, its words, and the one
/// position it carries.  Called once, from `luce_main`, and only when
/// the entry function came back errored.
pub export fn luce_rt_report_error(
    runtime: *const Runtime,
    context: ?*anyopaque,
    report: ?trace.ErrorReportFn,
) callconv(.c) void {
    if (runtime.exhausted) return;
    const raised = runtime.raised orelse return;
    const callback = report orelse return;
    callback(
        context,
        @intFromEnum(raised.code),
        raised.message.ptr,
        @intCast(raised.message.len),
        &raised.origin,
    );
}

/// A serial no other live frame carries — one per call, so ownership
/// bindings from two frames of the same function never collide.
pub export fn luce_rt_serial(runtime: *Runtime) callconv(.c) u64 {
    return runtime.takeSerial();
}

/// The host ran out of memory inside a service call.  Nothing about
/// the program was wrong, so this is not a trap: the run ends
/// `exhausted`, exactly as it does when the arena gives up.
pub export fn luce_rt_exhaust(runtime: *Runtime) callconv(.c) void {
    runtime.exhausted = true;
}

/// Copy host-owned bytes into fresh owned storage as a Luce String.
/// Every string a host service hands back is borrowed for the duration
/// of that call only; this is where it becomes a value the program can
/// keep — owned by the statement that asked for it until something
/// stores it (docs/STRINGS.md).
pub export fn luce_rt_intern_text(
    runtime: *Runtime,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    const borrowed = checkedBytes(runtime, bytes, length) catch |mistake|
        return failed(runtime, mistake);
    out.* = runtime.ownValue(Value.ofString(borrowed)) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// The same, for a service that may have nothing to hand over:
/// `read_line` at end of input, `env` for a variable nobody set.
/// `present` zero answers `Value.none` — the very value the
/// interpreter parks in the same slot, so a `T?` means one thing on
/// both engines (docs/FAILURE.md).
pub export fn luce_rt_maybe_text(
    runtime: *Runtime,
    present: i32,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    const is_present = checkedPresence(runtime, present) catch |mistake|
        return failed(runtime, mistake);
    if (!is_present) {
        out.* = Value.none;
        return survived;
    }
    const borrowed = checkedBytes(runtime, bytes, length) catch |mistake|
        return failed(runtime, mistake);
    out.* = runtime.ownValue(Value.ofString(borrowed)) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// A directory listing, as the `List(String)` `dir_list` answers.
///
/// The names arrive NUL-separated in one borrowed buffer, which is the
/// one shape the host ABI already carries — a service hands back bytes
/// and a length, never a vector — and NUL is the one byte no file name
/// on any supported system may contain, so the joining is lossless.
/// An empty buffer is an empty directory and not one empty name.
pub export fn luce_rt_names_list(
    runtime: *Runtime,
    bytes: [*c]const u8,
    length: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    const joined = checkedBytes(runtime, bytes, length) catch |mistake|
        return failed(runtime, mistake);
    out.* = containers.listOfJoinedText(runtime, joined) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// `main`'s `args`: the command line as the `List(String)` the entry's
/// parameter receives (OWNERSHIP.md S44).
///
/// The two vtable slots are handed straight over rather than read out
/// of a `LuceHost` here, because effects travel in that table and
/// semantics do not: this library never learns the table's shape, and
/// building a list out of borrowed text is the semantic.  A null
/// `count` or `get` yields an **empty** list — a program compiled
/// without the host gate reads no arguments and touches nothing, which
/// is strictly better than the trap `arg(0)` used to give it.
pub export fn luce_rt_args_list(
    runtime: *Runtime,
    context: ?*anyopaque,
    count: ?*const fn (context: ?*anyopaque) callconv(.c) i64,
    get: ?containers.ArgumentFn,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    const total: i64 = if (count) |callback| callback(context) else 0;
    out.* = containers.listOfArguments(runtime, total, context, get) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// Remember the text payload of the key just read, for `key_text`.
/// One owned slot: the previous payload goes back as this one arrives.
pub export fn luce_rt_set_key_text(
    runtime: *Runtime,
    bytes: [*c]const u8,
    length: i64,
) callconv(.c) i32 {
    const borrowed = checkedBytes(runtime, bytes, length) catch |mistake|
        return failed(runtime, mistake);
    runtime.setKeyText(borrowed) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// A copy of a value whose storage nothing else owns — what every
/// store into a place that outlives the statement takes first
/// (docs/STRINGS.md).  Scalars and object handles pass straight
/// through.
pub export fn luce_rt_own_storage(
    runtime: *Runtime,
    held: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = runtime.ownValue(held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

/// A value with storage that outlives the frame that made it — what
/// `ret` hands the caller.  Text that lives inside the value is copied
/// out to an allocation; everything else moves untouched
/// (docs/STRINGS.md).
pub export fn luce_rt_export_storage(
    runtime: *Runtime,
    held: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = runtime.exportValue(held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

/// Give back the storage a value owns, and answer the emptied value
/// the place should hold from here on.  Objects are untouched: they
/// are freed by `luce_rt_unbind`, which is a different question.
pub export fn luce_rt_drop_storage(
    runtime: *Runtime,
    held: [*c]const Value,
    out: [*c]Value,
) callconv(.c) void {
    if (!requireValueOut(runtime, out)) return;
    if (!requireValueInput(runtime, held)) return;
    runtime.dropStorage(held.*);
    out.* = heap.Runtime.emptied(held.*);
}

/// The text payload of the most recent `key_read`.
pub export fn luce_rt_key_text(runtime: *Runtime, out: [*c]Value) callconv(.c) void {
    if (!requireValueOut(runtime, out)) return;
    out.* = Value.ofString(runtime.last_key_text);
}

// ---------------------------------------------------------------------------
// Files: the byte channel, and text as a validation over it
// ---------------------------------------------------------------------------
//
// The five slots arrive once, at the start of a run, rather than at
// each call (docs/BYTES.md R2): a handle is closed when its owning
// scope ends, and that release happens inside the ownership walk, where
// no generated code is standing to hand a host in.  Everything below
// reads them out of the runtime.
//
// The three fallible answers follow the same convention as every other
// export — 0 survived, 1 trapped — with the world's `no` carried in an
// out-parameter the caller branches on, because "the file could not be
// opened" is news a program may catch and not a bug (docs/FAILURE.md).

/// `parse_string(xs)` — a `list(byte)` as text, or absent when the
/// bytes are not valid UTF-8 (docs/BYTES.md R3).
pub export fn luce_rt_parse_string(
    runtime: *Runtime,
    held: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = files.parseString(runtime, held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

// ---------------------------------------------------------------------------
// Workers (docs/THREADS.md)
// ---------------------------------------------------------------------------
//
// The same installed-channel shape the byte channel established, and
// for the same reason: a task's join happens at the end of the scope
// that owns it, inside the ownership walk, where no generated code is
// standing to hand a host in.  What is new is the *second* channel —
// how this engine makes a runtime for a worker and runs one function in
// it — because that is the one question a host cannot answer.  Both
// halves arrive in one call, at the top of `luce_main`, and **only in a
// program that contains a `spawn`**: a program without one emits none
// of this and pays nothing (D11).
//
// `open` and `close` are not parameters: they are this library's own,
// and generated code has no business naming them.

/// A runtime for a worker, on the same allocators the run's own uses.
fn workerOpen(context: ?*anyopaque) callconv(.c) ?*Runtime {
    _ = context;
    return luce_rt_open(null, 0);
}

fn workerClose(context: ?*anyopaque, worker: *Runtime) callconv(.c) void {
    _ = context;
    luce_rt_close(worker);
}

pub export fn luce_rt_workers_install(
    runtime: *Runtime,
    context: ?*anyopaque,
    spawn: ?workers.SpawnFn,
    join: ?workers.JoinFn,
    engine: ?*anyopaque,
    run: ?workers.RunFn,
    depth: i64,
) callconv(.c) void {
    runtime.workers = .{ .context = context, .spawn = spawn, .join = join };
    runtime.nursery = .{
        .context = engine,
        .open = workerOpen,
        .close = workerClose,
        .run = run,
    };
    runtime.depth_budget = depth;
}

/// `spawn f(args)` — the arguments arrive as a run of boxes and are
/// moved into the worker's runtime here, on this thread, before the
/// thread starts (docs/THREADS.md D2).
pub export fn luce_rt_spawn(
    runtime: *Runtime,
    function: i64,
    arguments: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    const argument_count = checkedCount(runtime, count) catch |mistake|
        return failed(runtime, mistake);
    // LLVM deliberately passes a null pointer for the empty argument
    // run.  A null pointer is therefore valid exactly when `count` is
    // zero; every non-empty run still has to cross the borrowed C
    // pointer boundary with a real input buffer.
    if (argument_count != 0 and !requireValueInput(runtime, arguments)) return raised_trap;
    const empty: [0]Value = .{};
    const passed: []const Value = if (argument_count == 0)
        &empty
    else
        arguments[0..argument_count];
    workers.spawn(runtime, function, passed, out) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// `t.wait()` — join, and move the worker's result here (D4).
///
/// Answers all three outcomes, because all three can cross a join: a
/// worker that returned, a worker that raised, and a worker that
/// trapped — the last of which is this frame's trap now, carrying the
/// worker's own frames in front of its own (D6).
pub export fn luce_rt_task_wait(
    runtime: *Runtime,
    task: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, task)) return raised_trap;
    return workers.wait(runtime, task.*, out) catch |mistake| failed(runtime, mistake);
}

/// The two halves of the effect lock (D9), emitted around every host
/// service call — and **only** in a program that contains a `spawn`.
///
/// A pair of calls rather than one guarded region because a host
/// service is a call, and what has to be atomic is the call: a `print`
/// from three workers is line-atomic exactly when nothing else is
/// inside the host between the enter and the leave.
pub export fn luce_rt_effects_enter(runtime: *Runtime) callconv(.c) void {
    runtime.enterEffects();
}

pub export fn luce_rt_effects_leave(runtime: *Runtime) callconv(.c) void {
    runtime.leaveEffects();
}

pub export fn luce_rt_files_install(
    runtime: *Runtime,
    context: ?*anyopaque,
    open: ?files.OpenFn,
    read: ?files.ReadFn,
    write: ?files.WriteFn,
    flush: ?files.FlushFn,
    close: ?files.CloseFn,
) callconv(.c) void {
    runtime.files = .{
        .context = context,
        .open = open,
        .read = read,
        .write = write,
        .flush = flush,
        .close = close,
    };
}

pub export fn luce_rt_file_open(
    runtime: *Runtime,
    path: [*c]const u8,
    length: i64,
    mode: i64,
    out: [*c]Value,
    opened: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireScalarOut(i32, runtime, opened)) return raised_trap;
    const named = checkedBytes(runtime, path, length) catch |mistake|
        return failed(runtime, mistake);
    const selected_mode = checkedFileMode(runtime, mode) catch |mistake|
        return failed(runtime, mistake);
    const answer = files.open(runtime, named, selected_mode) catch |mistake|
        return failed(runtime, mistake);
    opened.* = @intFromBool(answer != null);
    if (answer) |made| {
        out.* = made;
    } else {
        runtime.raiseIo(.open, named, runtime.frameAt(function, instruction));
    }
    return survived;
}

pub export fn luce_rt_file_read(
    runtime: *Runtime,
    held: [*c]const Value,
    buffer: [*c]const Value,
    filled: [*c]i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, held) or !requireValueInput(runtime, buffer)) return raised_trap;
    if (!requireScalarOut(i64, runtime, filled) or
        !requireScalarOut(i32, runtime, ok)) return raised_trap;
    const answer = files.read(runtime, held.*, buffer.*) catch |mistake|
        return failed(runtime, mistake);
    ok.* = @intFromBool(answer != null);
    filled.* = answer orelse 0;
    if (answer == null) runtime.raiseIo(
        .read,
        files.pathOf(runtime, held.*),
        runtime.frameAt(function, instruction),
    );
    return survived;
}

pub export fn luce_rt_file_write(
    runtime: *Runtime,
    held: [*c]const Value,
    buffer: [*c]const Value,
    count: i64,
    written: [*c]i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, held) or !requireValueInput(runtime, buffer)) return raised_trap;
    if (!requireScalarOut(i64, runtime, written) or
        !requireScalarOut(i32, runtime, ok)) return raised_trap;
    const answer = files.write(runtime, held.*, buffer.*, count) catch |mistake|
        return failed(runtime, mistake);
    ok.* = @intFromBool(answer != null);
    written.* = answer orelse 0;
    if (answer == null) runtime.raiseIo(
        .write,
        files.pathOf(runtime, held.*),
        runtime.frameAt(function, instruction),
    );
    return survived;
}

pub export fn luce_rt_file_flush(
    runtime: *Runtime,
    held: [*c]const Value,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, held)) return raised_trap;
    if (!requireScalarOut(i32, runtime, ok)) return raised_trap;
    const answered = files.flush(runtime, held.*) catch |mistake|
        return failed(runtime, mistake);
    ok.* = @intFromBool(answered);
    if (!answered) runtime.raiseIo(
        .flush,
        files.pathOf(runtime, held.*),
        runtime.frameAt(function, instruction),
    );
    return survived;
}

/// `file_read(path)` — the whole file as a `string`, open-read-close
/// over the byte channel with this library's own UTF-8 validation.
pub export fn luce_rt_file_read_text(
    runtime: *Runtime,
    path: [*c]const u8,
    length: i64,
    out: [*c]Value,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireScalarOut(i32, runtime, ok)) return raised_trap;
    const named = checkedBytes(runtime, path, length) catch |mistake|
        return failed(runtime, mistake);
    const answer = files.readText(runtime, named) catch |mistake|
        return failed(runtime, mistake);
    ok.* = @intFromBool(answer != null);
    if (answer) |made| {
        out.* = made;
    } else {
        runtime.raiseIo(.read, named, runtime.frameAt(function, instruction));
    }
    return survived;
}

/// `file_write(path, text)` at `mode` 1 and `file_append(path, text)`
/// at `mode` 2 — one door, because they differ only in where the write
/// starts.
pub export fn luce_rt_file_write_text(
    runtime: *Runtime,
    path: [*c]const u8,
    path_length: i64,
    content: [*c]const u8,
    content_length: i64,
    mode: i64,
    ok: [*c]i32,
    function: u32,
    instruction: u32,
) callconv(.c) i32 {
    if (!requireScalarOut(i32, runtime, ok)) return raised_trap;
    const named = checkedBytes(runtime, path, path_length) catch |mistake|
        return failed(runtime, mistake);
    const body = checkedBytes(runtime, content, content_length) catch |mistake|
        return failed(runtime, mistake);
    const selected_mode = checkedFileMode(runtime, mode) catch |mistake|
        return failed(runtime, mistake);
    const answered = files.writeText(
        runtime,
        named,
        body,
        @enumFromInt(selected_mode),
    ) catch |mistake| return failed(runtime, mistake);
    ok.* = @intFromBool(answered);
    if (!answered) runtime.raiseIo(
        if (selected_mode == @intFromEnum(files.Mode.append)) .append else .write,
        named,
        runtime.frameAt(function, instruction),
    );
    return survived;
}

/// Record allocation failure and report the call as trapped.  Every
/// export funnels its errors through here, so `error.OutOfMemory` never
/// escapes into C as a silent success.
fn failed(runtime: *Runtime, mistake: heap.Error) i32 {
    switch (mistake) {
        error.OutOfMemory => if (runtime.materializing_constants) {
            // A constant container is an eager allocation the program
            // requested in its declaration.  RAM saying no is the
            // located `allocation_failed` trap promised before main,
            // not an exhausted run with no source location.
            runtime.exhausted = false;
            _ = runtime.fail(.allocation_failed) catch {};
        } else {
            runtime.exhausted = true;
        },
        error.Trap => {},
    }
    return raised_trap;
}

/// Convert a signed scalar supplied by C into a safe slice length.  Generated
/// code emits non-negative values, but this public boundary also has to be
/// total for a damaged artifact or an embedding host that passes nonsense.
fn checkedCount(runtime: *Runtime, raw: i64) heap.Error!usize {
    return std.math.cast(usize, raw) orelse runtime.fail(.host_unavailable);
}

fn checkedFileMode(runtime: *Runtime, raw: i64) heap.Error!i64 {
    if (raw < @intFromEnum(files.Mode.read) or raw > @intFromEnum(files.Mode.append)) {
        return runtime.fail(.host_unavailable);
    }
    return raw;
}

/// The generated path supplies a zero-extended Boolean here.  Keep the C
/// door just as strict: treating every nonzero integer as present would make
/// a malformed artifact read a buffer that the producer did not authorize.
fn checkedPresence(runtime: *Runtime, raw: i32) heap.Error!bool {
    return switch (raw) {
        0 => false,
        1 => true,
        else => runtime.fail(.host_unavailable),
    };
}

fn checkedBytes(runtime: *Runtime, bytes: [*c]const u8, raw: i64) heap.Error![]const u8 {
    if (bytes == null) return runtime.fail(.host_unavailable);
    const length = try checkedCount(runtime, raw);
    return bytes[0..length];
}

// ---------------------------------------------------------------------------
// Constant-container materialization (CONSTANTS.md R-C, R-D)
// ---------------------------------------------------------------------------
//
// A generated prologue builds ordinary loose containers through the
// exports below this section, then publishes each completed handle into
// one runtime-local program-root slot.  `begin` owns the table;
// `publish` consumes the loose object's lifetime (the Value itself is a
// borrow); `load` returns a borrowed handle; `finish` keeps the roots for
// the run.  On a trapped prologue, generated cleanup discards the one
// unpublished construction, then aborts every already-published root.

/// Allocate `count` root slots and enter materialization.  Nothing is
/// returned or retained on failure; the trap waits in `runtime.pending`.
pub export fn luce_rt_constants_begin(runtime: *Runtime, count: u32) callconv(.c) i32 {
    runtime.beginConstants(count) catch |mistake| return failed(runtime, mistake);
    return survived;
}

/// Publish a completed loose object at `slot`.  On failure the object
/// remains loose and the caller must pass it to `luce_rt_discard_loose`.
pub export fn luce_rt_constant_publish(
    runtime: *Runtime,
    slot: u32,
    held: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, held)) return raised_trap;
    runtime.publishConstant(slot, held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

/// Load the borrowed program-root handle at a verified pool slot.
pub export fn luce_rt_constant_load(
    runtime: *Runtime,
    slot: u32,
    out: [*c]Value,
) callconv(.c) void {
    if (!requireValueOut(runtime, out)) return;
    if (runtime.materializing_constants or slot >= runtime.constant_roots.len) {
        _ = runtime.fail(.not_owned) catch {};
        return;
    }
    out.* = runtime.constant(slot);
}

/// Leave materialization successfully; every published root now lives
/// until this runtime closes.
pub export fn luce_rt_constants_finish(runtime: *Runtime) callconv(.c) void {
    runtime.finishConstants();
}

/// Tear down all roots already published by a failed materialization.
pub export fn luce_rt_constants_abort(runtime: *Runtime) callconv(.c) void {
    runtime.abortConstants();
}

/// Tear down the unpublished loose container a failed prologue was
/// filling.  Stale or non-loose values are harmless no-ops.
pub export fn luce_rt_discard_loose(runtime: *Runtime, held: [*c]const Value) callconv(.c) void {
    if (!requireValueInput(runtime, held)) return;
    runtime.discardLoose(held.*);
}

// ---------------------------------------------------------------------------
// Objects and ownership
// ---------------------------------------------------------------------------
//
// The `new_*` four **create**: each writes a fresh object into `out`,
// owned by nothing yet, and answers 1 only when there was no memory.
// `luce_rt_new_array` reads `rank` dimensions from `dims` and copies
// `zero` into every cell; both arguments are borrowed for the call.
//
// The other six are scope ownership itself (docs/OWNERSHIP.md), and
// three of their arguments are one idea:
//
//   * `serial` — the frame, as `luce_rt_serial` handed it out.  One per
//     call, so two live frames of the same function never collide.
//   * `local` — which binding in that frame, as stage 6 numbered it.
//   * `owned` — whether the caller is claiming to *be* that binding.
//     Nonzero means "I am the owner named by (serial, local), check
//     me"; zero means the verb was written on something with no name to
//     check — a temporary, a field, an element.
//
// So `(owned, serial, local)` is one optional answer to "who says so",
// and a mismatch is not a technicality: `free x` where `x` is not the
// owner is the `not_owned` trap (S6, S23), which is what stops a borrow
// from ending an object the lender still holds.
//
// All six walk a value's *top* objects — the object a handle names, or
// a struct's object fields recursively — and never descend into an
// object's elements, which already belong to it.
//
//   `bind`               the objects in `held` now belong to
//                        (serial, local).  Nothing is freed.
//   `unbind`             free the objects in `held` still bound to
//                        (serial, local); scope exit is a run of these.
//                        Anything owned elsewhere by now is left alone,
//                        which is what makes a release safe on every
//                        path, including a path that already gave.
//   `loosen_from_frame`  drop frame `serial`'s claim without freeing —
//                        what `return` does to what it hands back, so
//                        the value leaves loose and the caller owns it
//                        (S16).
//   `free`               end the object now.
//   `give`               check that giving is legal and answer the
//                        object to hold from here.  It is the same
//                        object: what stops the old name being used
//                        again is the compiler (S10), and what this
//                        checks is that the giver had it to give.
//   `copy`               answer a fresh deep copy the caller owns,
//                        leaving the original alone.
//
// `free`, `give` and `copy` are the three a program writes, so all
// three trap rather than proceed on a freed object, an unfilled slot
// (S42), or an owner that is not the one named.

pub export fn luce_rt_new_list(
    runtime: *Runtime,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, zero)) return raised_trap;
    out.* = runtime.newList(zero.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_new_map(runtime: *Runtime, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    out.* = runtime.newMap() catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_new_builder(runtime: *Runtime, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    out.* = runtime.newBuilder() catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_new_array(
    runtime: *Runtime,
    dims: [*c]const i64,
    rank: i64,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireI64Input(runtime, dims) or !requireValueInput(runtime, zero)) return raised_trap;
    const dimension_count = checkedCount(runtime, rank) catch |mistake|
        return failed(runtime, mistake);
    out.* = runtime.newArray(dims[0..dimension_count], zero.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_bind(
    runtime: *Runtime,
    held: [*c]const Value,
    serial: u64,
    local: u32,
) callconv(.c) void {
    if (!requireValueInput(runtime, held)) return;
    runtime.bind(held.*, serial, local);
}

pub export fn luce_rt_unbind(
    runtime: *Runtime,
    held: [*c]const Value,
    serial: u64,
    local: u32,
) callconv(.c) void {
    if (!requireValueInput(runtime, held)) return;
    runtime.unbind(held.*, serial, local);
}

pub export fn luce_rt_loosen_from_frame(
    runtime: *Runtime,
    held: [*c]const Value,
    serial: u64,
) callconv(.c) void {
    if (!requireValueInput(runtime, held)) return;
    runtime.loosenFromFrame(held.*, serial);
}

pub export fn luce_rt_free(
    runtime: *Runtime,
    held: [*c]const Value,
    owned: i32,
    serial: u64,
    local: u32,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, held)) return raised_trap;
    const names_owner = checkedPresence(runtime, owned) catch |mistake|
        return failed(runtime, mistake);
    const expected: ?heap.OwnedBy = if (names_owner) .{ .serial = serial, .local = local } else null;
    containers.freeVerb(runtime, held.*, expected) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_give(
    runtime: *Runtime,
    held: [*c]const Value,
    owned: i32,
    serial: u64,
    local: u32,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    const names_owner = checkedPresence(runtime, owned) catch |mistake|
        return failed(runtime, mistake);
    const expected: ?heap.OwnedBy = if (names_owner) .{ .serial = serial, .local = local } else null;
    out.* = containers.giveVerb(runtime, held.*, expected) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_copy(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = containers.copyVerb(runtime, held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

// ---------------------------------------------------------------------------
// Struct values
// ---------------------------------------------------------------------------
//
// A struct travels as a pointer to `count` consecutive `Value`s, and
// the run that backs it is never written to after it is built — so
// generated code copies a struct by copying the pointer, and both
// entry points below allocate a fresh run.
//
// Both **consume** the fields they are given: a store site never
// copies, because the copy — where one is needed at all — stands in
// the IR in front of the call as `own_storage` (docs/STRINGS.md).
// `luce_rt_struct_set` copies only the fields it did not replace,
// which belong to the value it read them out of.

pub export fn luce_rt_struct_make(
    runtime: *Runtime,
    fields: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, fields)) return raised_trap;
    const field_count = checkedCount(runtime, count) catch |mistake|
        return failed(runtime, mistake);
    out.* = runtime.makeStruct(fields[0..field_count]) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// A function value's run: `count` consecutive `Value`s under the tag
/// that says the objects inside are **borrowed** (docs/BINDING.md D4).
/// Its own entry point rather than a flag on `struct_make`, because
/// what differs is what the ownership walks do with the result, and a
/// caller that picked the wrong one would be picking that.
pub export fn luce_rt_function_make(
    runtime: *Runtime,
    slots: [*c]const Value,
    count: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, slots)) return raised_trap;
    const slot_count = checkedCount(runtime, count) catch |mistake|
        return failed(runtime, mistake);
    out.* = runtime.makeFunction(slots[0..slot_count]) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_struct_set(
    runtime: *Runtime,
    held: [*c]const Value,
    field: i64,
    to: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held) or !requireValueInput(runtime, to)) return raised_trap;
    if (held.*.tag != .strukt) return rejected(runtime, .not_owned);
    const index = std.math.cast(usize, field) orelse return rejected(runtime, .index_bounds);
    out.* = runtime.setField(held.*, index, to.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// Turn an invalid scalar supplied across the C boundary into the same
/// ordinary trap the checked runtime door would have raised.  Generated code
/// never takes this path; it exists so a damaged artifact cannot make a
/// negative index reach a Zig `@intCast` or slice operation.
fn rejected(runtime: *Runtime, code: vocabulary.TrapCode) i32 {
    _ = runtime.fail(code) catch {};
    return raised_trap;
}

/// C callers may pass a null result slot even though generated code never
/// does.  Reject it before any input is read, allocation is attempted, or
/// ownership is changed.  The C pointer spelling keeps the ABI nullable;
/// this helper keeps the implementation from ever dereferencing null.
fn requireValueOut(runtime: *Runtime, out: [*c]Value) bool {
    if (out != null) return true;
    _ = runtime.fail(.host_unavailable) catch {};
    return false;
}

/// The C surface spells borrowed values as C-nullable pointers so a host
/// cannot turn an absent input into an unchecked Zig dereference.  Generated
/// code always supplies a non-null slot; this is for damaged artifacts and
/// embedding hosts, and it leaves the runtime in the same fail-closed state
/// as the other malformed scalar boundaries.
fn requireValueInput(runtime: *Runtime, held: [*c]const Value) bool {
    if (held != null) return true;
    _ = runtime.fail(.host_unavailable) catch {};
    return false;
}

fn requireI64Input(runtime: *Runtime, values: [*c]const i64) bool {
    if (values != null) return true;
    _ = runtime.fail(.host_unavailable) catch {};
    return false;
}

fn requireScalarOut(comptime T: type, runtime: *Runtime, out: [*c]T) bool {
    if (out != null) return true;
    _ = runtime.fail(.host_unavailable) catch {};
    return false;
}

// ---------------------------------------------------------------------------
// Containers
// ---------------------------------------------------------------------------
//
// List, Map, Array and Builder, reached through the `target` they act
// on.  `target` is always a borrow, and a wrong shape, a bad index, a
// missing key or a freed object is a trap rather than a return value —
// which is why most of these answer nothing but "did the program
// survive".
//
// **What is consumed is called out per symbol**, because it is not
// uniform: a container that takes ownership of what it is handed says
// so, and one that copies instead (a Builder's bytes, a Map's key) says
// that.  Everything unmarked borrows.  What comes back through `out` is
// owned by the statement that asked for it, including the fresh Lists
// `list_slice`, `map_keys` and `map_values` build.

pub export fn luce_rt_len(runtime: *Runtime, target: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.length(runtime, target.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_index_get(
    runtime: *Runtime,
    target: [*c]const Value,
    indices: [*c]const Value,
    rank: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, indices)) return raised_trap;
    const index_count = checkedCount(runtime, rank) catch |mistake|
        return failed(runtime, mistake);
    out.* = containers.indexGet(runtime, target.*, indices[0..index_count]) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// Consumes `held` — see `containers.indexSet`.  The key stays a
/// borrow the map copies for itself.
pub export fn luce_rt_index_set(
    runtime: *Runtime,
    target: [*c]const Value,
    indices: [*c]const Value,
    rank: i64,
    held: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, indices) or
        !requireValueInput(runtime, held)) return raised_trap;
    const index_count = checkedCount(runtime, rank) catch |mistake|
        return failed(runtime, mistake);
    containers.indexSet(runtime, target.*, indices[0..index_count], held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_list_slice(
    runtime: *Runtime,
    target: [*c]const Value,
    start: i64,
    end: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.listSlice(runtime, target.*, start, end) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// A list consumes `held`; a Builder copies its bytes and borrows —
/// see `containers.append`.
pub export fn luce_rt_append(
    runtime: *Runtime,
    target: [*c]const Value,
    held: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, held)) return raised_trap;
    containers.append(runtime, target.*, held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_append_ascii(
    runtime: *Runtime,
    target: [*c]const Value,
    code: i64,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target)) return raised_trap;
    containers.appendAscii(runtime, target.*, code) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_pop(runtime: *Runtime, target: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.pop(runtime, target.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// Consumes `held` — see `containers.insert`.
pub export fn luce_rt_insert(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    held: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, held)) return raised_trap;
    containers.insert(runtime, target.*, index, held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_remove(
    runtime: *Runtime,
    target: [*c]const Value,
    which: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, which)) return raised_trap;
    containers.remove(runtime, target.*, which.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_has_key(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, key)) return raised_trap;
    out.* = containers.hasKey(runtime, target.*, key.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_key_at(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.keyAt(runtime, target.*, index) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_value_at(
    runtime: *Runtime,
    target: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.valueAt(runtime, target.*, index) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_dim_size(
    runtime: *Runtime,
    target: [*c]const Value,
    axis: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target)) return raised_trap;
    out.* = containers.dimSize(runtime, target.*, axis) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_sort(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32 {
    if (!requireValueInput(runtime, target)) return raised_trap;
    containers.sort(runtime, target.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_reverse(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32 {
    if (!requireValueInput(runtime, target)) return raised_trap;
    containers.reverse(runtime, target.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_find(
    runtime: *Runtime,
    target: [*c]const Value,
    wanted: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, wanted)) return raised_trap;
    out.* = containers.find(runtime, target.*, wanted.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_contains(
    runtime: *Runtime,
    target: [*c]const Value,
    wanted: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, wanted)) return raised_trap;
    const at = containers.find(runtime, target.*, wanted.*) catch |mistake|
        return failed(runtime, mistake);
    out.* = Value.ofBoolean(!at.isNone());
    return survived;
}

pub export fn luce_rt_clear(runtime: *Runtime, target: [*c]const Value) callconv(.c) i32 {
    if (!requireValueInput(runtime, target)) return raised_trap;
    containers.clear(runtime, target.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

/// `zero` is the element zero of the list this answers, exactly as
/// `luce_rt_new_list` takes one: it carries the *kind* the elements
/// are stored at, and a `list(long)` is packed whether the program
/// built it or `m.keys()` did (docs/BYTES.md R1).
pub export fn luce_rt_map_keys(
    runtime: *Runtime,
    target: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, zero)) return raised_trap;
    out.* = containers.mapKeys(runtime, target.*, zero.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_map_values(
    runtime: *Runtime,
    target: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, zero)) return raised_trap;
    out.* = containers.mapValues(runtime, target.*, zero.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_map_get(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, key)) return raised_trap;
    out.* = containers.mapGet(runtime, target.*, key.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

/// The key and the zero are both borrows the map copies for itself
/// when it defines the entry — see `containers.mapPlace`.
pub export fn luce_rt_map_place(
    runtime: *Runtime,
    target: [*c]const Value,
    key: [*c]const Value,
    zero: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, key) or
        !requireValueInput(runtime, zero)) return raised_trap;
    out.* = containers.mapPlace(runtime, target.*, key.*, zero.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_array_fill(
    runtime: *Runtime,
    target: [*c]const Value,
    held: [*c]const Value,
) callconv(.c) i32 {
    if (!requireValueInput(runtime, target) or !requireValueInput(runtime, held)) return raised_trap;
    containers.arrayFill(runtime, target.*, held.*) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

// ---------------------------------------------------------------------------
// Strings and conversions
// ---------------------------------------------------------------------------
//
// The String primitives and the pure conversions.  Every argument is
// borrowed and nothing here mutates: a Luce String is a value, so each
// of these answers a *new* one through `out`, owned by the statement
// that asked for it (docs/STRINGS.md).
//
// They fail the way the language says they fail.  A slice that is out
// of bounds or splits a UTF-8 sequence traps, and so does `chr` of a
// number that is not a codepoint.  `parse_int` and `parse_float` do
// not: they answer `Value.none` for text that is not a number, because
// parsing is a question and "no" is an answer.

pub export fn luce_rt_concat(
    runtime: *Runtime,
    left: [*c]const Value,
    right: [*c]const Value,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, left) or !requireValueInput(runtime, right)) return raised_trap;
    out.* = text.concat(runtime, left.*.asString(), right.*.asString()) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_string_slice(
    runtime: *Runtime,
    held: [*c]const Value,
    start: i64,
    end: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.slice(runtime, held.*, start, end) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_string_byte(
    runtime: *Runtime,
    held: [*c]const Value,
    index: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.byteAt(runtime, held.*, index) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_string_find_byte(
    runtime: *Runtime,
    held: [*c]const Value,
    byte: i64,
    start: i64,
    out: [*c]Value,
) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.findByte(runtime, held.*, byte, start) catch |mistake|
        return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_str(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.str(runtime, held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_parse_int(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.parseInt(runtime, held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_parse_float(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.parseFloat(runtime, held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_chr(runtime: *Runtime, code: i64, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    out.* = text.chr(runtime, code) catch |mistake| return failed(runtime, mistake);
    return survived;
}

pub export fn luce_rt_ord(runtime: *Runtime, held: [*c]const Value, out: [*c]Value) callconv(.c) i32 {
    if (!requireValueOut(runtime, out)) return raised_trap;
    if (!requireValueInput(runtime, held)) return raised_trap;
    out.* = text.ord(runtime, held.*) catch |mistake| return failed(runtime, mistake);
    return survived;
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

/// Comparison for the types generated code cannot compare inline —
/// String, structs.  The one export that answers its result
/// directly rather than through an out-pointer, because comparison is
/// the one operation here that cannot fail.  `op` is `vocabulary.BinaryOp`.
pub export fn luce_rt_compare(
    op: i32,
    left: [*c]const Value,
    right: [*c]const Value,
) callconv(.c) i32 {
    if (left == null or right == null) return 0;
    const operation = std.enums.fromInt(vocabulary.BinaryOp, op) orelse return 0;
    return @intFromBool(operators.compare(operation, left.*, right.*));
}

/// `%` on doubles: the floor modulus (docs/NUMERICS.md §3).  Two scalars
/// in, one out; it reads no memory and cannot fail.
///
/// **A call rather than an inline sequence**, which is unlike the
/// other float arithmetic, because this operator's answer is not one
/// machine instruction and not what any host `fmod` gives: it is a
/// `frem`, a zero case that takes the divisor's sign, and a correction
/// on opposed signs.  Written twice it would be two chances to differ
/// on `-0.0` and the infinities, and `frem` is already a libm call, so
/// what the extra frame buys is that there is only one of it.
pub export fn luce_rt_float_mod(left: f64, right: f64) callconv(.c) f64 {
    return operators.floorMod(f64, left, right);
}

/// The same operator at binary32.  A width of its own rather than a
/// widening through `double`: `%` on floats must answer what a float
/// `%` answers, and the round trip through binary64 disagrees exactly
/// where the correction fires.
pub export fn luce_rt_float32_mod(left: f32, right: f32) callconv(.c) f32 {
    return operators.floorMod(f32, left, right);
}

/// Comparison across the long/double line, exactly (docs/NUMERICS.md).
/// Two scalars and an operator: it reads no memory at all, cannot
/// fail, and takes no runtime.  The long is always the left operand —
/// stage 4 mirrors the operator when the double was written first.
pub export fn luce_rt_compare_long_double(
    op: i32,
    left: i64,
    right: f64,
) callconv(.c) i32 {
    const operation = std.enums.fromInt(vocabulary.BinaryOp, op) orelse return 0;
    return @intFromBool(operators.compareLongDouble(operation, left, right));
}
