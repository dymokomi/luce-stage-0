//! The Luce IR interpreter machine — the differential oracle's engine
//! (`../interpreter.zig`).
//!
//! Deterministic and safe: checked integer arithmetic, explicit
//! conversion range checks, and a call-depth limit.  All temporary
//! storage comes from the evaluation arena; the interpreter itself
//! allocates nothing that outlives one evaluation.
//!
//! What is *not* here is the point of the file.  Every semantic below
//! the instruction level — the object heap, reference counting, the
//! containers, string storage, the conversions, checked arithmetic —
//! lives in `libluce_rt` (`../runtime.zig`), and this file only decodes
//! instructions and calls it.  There is one implementation of each
//! semantic and compiled code reaches the same one (docs/CODEGEN.md);
//! a second copy here would be a second place for the same bug.

const std = @import("std");
const mir = @import("../mir.zig");
const interpreter = @import("../interpreter.zig");
const runtime = @import("../runtime.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const RuntimeValue = runtime.Value;
const Result = interpreter.Result;
const Budget = interpreter.Budget;

const containers = runtime.containers;
const files = runtime.files;
const sockets = runtime.sockets;
const graphics = runtime.graphics;
const operators = runtime.operators;
const text = runtime.text;

// ---------------------------------------------------------------------------
// Running a program
// ---------------------------------------------------------------------------

/// Run one verified program through the differential oracle.  When
/// `host.workers` is installed, `memory.objects` and any allocator it
/// shares with `memory.arena` must support concurrent calls: the root
/// and its worker runtimes allocate from that backing store until their
/// structured joins finish.
pub fn run(
    memory: runtime.Memory,
    program: *const mir.Program,
    budget: Budget,
    host: ?interpreter.Host,
) error{OutOfMemory}!Result {
    var machine: Machine = .{
        .arena = memory.arena,
        .runtime = .init(memory),
        .program = program,
        .max_depth = budget.call_depth,
        .host = host,
    };
    // The host's file channel goes into the runtime, which is what
    // calls it: a handle closes on its last strong release inside the
    // ARC walk (docs/BYTES.md R2).  The
    // compiled path installs the same five pointers through
    // `luce_rt_files_install`, so both engines reach one channel.
    if (host) |given| machine.runtime.files = given.files;
    if (host) |given| machine.runtime.sockets = given.sockets;
    if (host) |given| machine.runtime.graphics = given.graphics;
    // And the thread channel, plus this engine's own answer to what a
    // worker's runtime is and how one function is run in it
    // (docs/THREADS.md D10).  The oracle threads for real: a `Machine`
    // and a `Runtime` are a self-contained pair by construction, so a
    // worker here is a second one of exactly what the root run is.
    var nursery: Nursery = .{ .program = program, .host = host, .base = memory.objects };
    machine.runtime.finalizers = nursery.finalizerChannel(@intCast(budget.call_depth));
    if (host) |given| {
        machine.runtime.workers = given.workers;
        machine.runtime.nursery = nursery.channel();
        machine.runtime.depth_budget = @intCast(budget.call_depth);
    }
    // Object storage is a real allocator now, so the run has to hand
    // it back: ARC frees what a clean program finished with, and this
    // frees what a trap unwound past or a strong cycle left behind
    // (S34).  The result is built first — it carries the census and a
    // trap's words, which live in the arena, not here.
    defer machine.runtime.deinit();
    switch (try machine.execute(program.entry_function)) {
        // The census is this runtime's plus every worker's: a leak in
        // a worker is a leak in the program, and both engines report
        // the one number (docs/THREADS.md D10).
        .value => return .{ .success = .{
            .leaked_objects = @intCast(machine.runtime.leaked()),
        } },
        // An uncaught error is news, not a bug: every frame released
        // what it owned on the way out, so the census is honest and
        // there is nothing standing to sweep (docs/FAILURE.md).  The
        // words live in the arena the caller reads them from.
        .errored => {
            const raised = machine.runtime.raised.?;
            return .{ .errored = .{
                .code = raised.code,
                .message = raised.message,
                .origin = .{
                    .function = raised.origin.function[0..@intCast(raised.origin.function_length)],
                    .source = raised.origin.source[0..@intCast(raised.origin.source_length)],
                    .line = raised.origin.line,
                    .column = raised.origin.column,
                },
                .leaked_objects = @intCast(machine.runtime.leaked()),
            } };
        },
        .trap => |trap| {
            var reported = trap;
            // The frame stack survives a trap intact, so the trace
            // costs nothing until a trap actually happens — the
            // debug tables are never read on the execution path.
            machine.traceback(&reported) catch |mistake| switch (mistake) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            // A trap unwinds past every release (S34), which is what
            // keeps the object census honest — but value storage is
            // not in the census, and the frames that own it are still
            // standing right here, so it goes back now
            // (docs/STRINGS.md).  Reported after the traceback: a
            // trap's words may be a string the program built.
            machine.releaseFrameStorage();
            reported.leaked_objects = @intCast(machine.runtime.leaked());
            return .{ .trap = reported };
        },
        // The unwind skipped releases the way a trap's does, so the
        // census counts what was standing; the frames are standing
        // here too, and their value storage goes back the same way.
        .exited => {
            machine.releaseFrameStorage();
            return .{ .exited = .{
                .status = machine.runtime.exit_status.?,
                .leaked_objects = @intCast(machine.runtime.leaked()),
            } };
        },
    }
}

// ---------------------------------------------------------------------------
// Workers — the oracle threads for real (docs/THREADS.md D10)
// ---------------------------------------------------------------------------

/// This engine's answer to "what is a worker's runtime, and how is one
/// function run in it".
///
/// A host supplies threads and nothing else, so this half is the
/// engine's and each engine fills it differently: a compiled artifact
/// hands `libluce_rt` a generated trampoline and lets the library open
/// the runtime, and the oracle hands it the three functions below.
/// Everything *between* the two — moving the arguments across, the
/// join, the census, adopting a worker's trap — is `runtime/workers.zig`
/// and is one implementation, which is the only reason the two arms can
/// be compared at all.
///
/// **A `Machine` and a `Runtime` are a self-contained pair**, which is
/// what makes this cheap: a worker here is a second one of exactly what
/// the root run is, with its own arena, its own frame stack and its own
/// depth budget, and nothing static anywhere for the two to share.
const Nursery = struct {
    program: *const mir.Program,
    host: ?interpreter.Host,
    /// The allocator every worker's own arena and object table draw
    /// on.  The root run's, so a spec's leak checker sees one pool.
    base: Allocator,

    /// A worker's runtime, plus the arena it draws values from — one
    /// allocation, never moved, because the runtime holds an allocator
    /// pointing into the arena beside it.
    const Owned = struct {
        arena: std.heap.ArenaAllocator,
        runtime: runtime.Runtime,
    };

    fn channel(self: *Nursery) runtime.workers.Nursery {
        return .{
            .context = self,
            .open = open,
            .close = close,
            .run = runWorker,
        };
    }

    fn finalizerChannel(self: *Nursery, depth: i64) runtime.Finalizers {
        return .{
            .context = self,
            .run = runFinalizer,
            .depth = depth,
        };
    }

    fn open(context: ?*anyopaque) callconv(.c) ?*runtime.Runtime {
        const self: *Nursery = @ptrCast(@alignCast(context.?));
        const owned = self.base.create(Owned) catch return null;
        owned.arena = .init(self.base);
        owned.runtime = .init(.{
            .arena = owned.arena.allocator(),
            .objects = self.base,
        });
        return &owned.runtime;
    }

    fn close(context: ?*anyopaque, worker: *runtime.Runtime) callconv(.c) void {
        const self: *Nursery = @ptrCast(@alignCast(context.?));
        const owned: *Owned = @fieldParentPtr("runtime", worker);
        owned.runtime.deinit();
        owned.arena.deinit();
        self.base.destroy(owned);
    }

    /// Run one function on the worker's thread, in a `Machine` of its
    /// own.  The arguments are already in `worker`'s runtime; what
    /// comes back is the outcome, with the worker's trap, error or
    /// chosen exit left in its runtime for the join to read.
    fn runWorker(
        context: ?*anyopaque,
        worker: *runtime.Runtime,
        function: i64,
        arguments: [*]const runtime.Value,
        count: i64,
        out: *runtime.Value,
        depth: i64,
    ) callconv(.c) i32 {
        const self: *Nursery = @ptrCast(@alignCast(context.?));
        const owned: *Owned = @fieldParentPtr("runtime", worker);
        const function_index = std.math.cast(u32, function) orelse {
            _ = worker.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        };
        if (function_index >= self.program.functions.len) {
            _ = worker.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        }
        const argument_count = std.math.cast(usize, count) orelse {
            _ = worker.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        };
        const max_depth = std.math.cast(u32, depth) orelse {
            _ = worker.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        };
        var machine: Machine = .{
            .arena = owned.arena.allocator(),
            .runtime = undefined,
            .program = self.program,
            .max_depth = max_depth,
            .host = self.host,
        };
        // The runtime is the one `open` made and `workers.spawn` filled
        // in: it already holds the channels, the shared lock and the
        // arguments.  The machine borrows it rather than making one.
        const outcome = self.execute(&machine, worker, function_index, arguments[0..argument_count], out);
        return outcome;
    }

    /// Run the hidden `Class.deinit` body in a fresh interpreter machine
    /// against the same runtime.  A separate machine keeps a nested finalizer
    /// call from reallocating the suspended caller's frame arrays, while
    /// moving the runtime in and back preserves the one object table in which
    /// the receiver lives.
    fn runFinalizer(
        context: ?*anyopaque,
        runtime_pointer: *runtime.Runtime,
        function: i64,
        receiver: *const runtime.Value,
        depth: i64,
    ) callconv(.c) i32 {
        const self: *Nursery = @ptrCast(@alignCast(context orelse {
            _ = runtime_pointer.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        }));
        const function_index = std.math.cast(u32, function) orelse {
            _ = runtime_pointer.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        };
        const max_depth = std.math.cast(u32, depth) orelse {
            _ = runtime_pointer.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        };
        if (function_index >= self.program.functions.len) {
            _ = runtime_pointer.fail(.host_unavailable) catch {};
            return runtime.workers.raised_trap;
        }

        var scratch: std.heap.ArenaAllocator = .init(runtime_pointer.objects);
        defer scratch.deinit();
        var machine: Machine = .{
            .arena = scratch.allocator(),
            .runtime = runtime_pointer.*,
            .program = self.program,
            .max_depth = max_depth,
            .host = self.host,
        };
        defer runtime_pointer.* = machine.runtime;

        const arguments = [_]runtime.Value{receiver.*};
        const outcome = machine.call(function_index, &arguments) catch |mistake| {
            if (mistake == error.OutOfMemory) machine.runtime.exhausted = true;
            machine.releaseFrameStorage();
            return runtime.workers.raised_trap;
        };
        return switch (outcome) {
            .value => |answered| successful: {
                // Verification requires `none`; clean up defensively if a
                // malformed engine callback nevertheless hands back storage.
                machine.runtime.freeValue(answered);
                break :successful runtime.workers.survived;
            },
            .errored => malformed: {
                machine.runtime.forget();
                _ = machine.runtime.fail(.host_unavailable) catch {};
                machine.recordUnwind();
                machine.releaseFrameStorage();
                break :malformed runtime.workers.raised_trap;
            },
            .exited => stopped: {
                machine.releaseFrameStorage();
                break :stopped runtime.workers.raised_trap;
            },
            .trap => |trapped| trapped_outcome: {
                machine.runtime.pending = .{
                    .code = trapped.code,
                    .message = trapped.message,
                };
                machine.recordUnwind();
                machine.releaseFrameStorage();
                break :trapped_outcome runtime.workers.raised_trap;
            },
        };
    }

    /// The body of `runWorker`, with the machine already standing.
    /// Split out only so the runtime pointer can be swapped in without
    /// a second `undefined` in sight.
    fn execute(
        self: *Nursery,
        machine: *Machine,
        worker: *runtime.Runtime,
        function: u32,
        arguments: []const runtime.Value,
        out: *runtime.Value,
    ) i32 {
        _ = self;
        // `Machine.runtime` is a value, not a pointer, so the worker's
        // runtime is moved in and moved back: `workers.spawn` filled it
        // and the join reads it, and in between it is the machine's.
        machine.runtime = worker.*;
        defer worker.* = machine.runtime;
        defer machine.stack.deinit(machine.arena);
        defer machine.frame_storage.deinit(machine.arena);

        const outcome = if (machine.materializeConstants()) |failed|
            failed
        else
            machine.call(function, arguments) catch |mistake| {
                if (mistake == error.OutOfMemory) machine.runtime.exhausted = true;
                return runtime.workers.raised_trap;
            };
        switch (outcome) {
            .value => |answered| {
                out.* = answered;
                return runtime.workers.survived;
            },
            .errored => return runtime.workers.raised_error,
            .exited => {
                machine.releaseFrameStorage();
                return runtime.workers.raised_trap;
            },
            .trap => |trapped| {
                machine.runtime.pending = .{
                    .code = trapped.code,
                    .message = trapped.message,
                };
                machine.recordUnwind();
                machine.releaseFrameStorage();
                return runtime.workers.raised_trap;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Frames and their outcome
// ---------------------------------------------------------------------------

/// Deep recursion reports the innermost frames and drops the rest;
/// a call_depth_exceeded trace would otherwise be the whole budget.
/// One number for both engines: compiled code caps its unwind trace at
/// the same point (`runtime/trace.zig`), so the same trap reports the
/// same frames whichever engine ran it.
const max_trace_frames = runtime.trace.max_frames;

pub const CallOutcome = union(enum) {
    value: RuntimeValue,
    trap: interpreter.Trap,
    /// The entry function left with an error nobody caught.  What it
    /// was is in `Runtime.raised`; the run ends here, but unlike a
    /// trap every frame on the way out released what it owned, so
    /// there is nothing standing to sweep.
    errored,
    /// The program said `exit(status)`.  The status is
    /// `Runtime.exit_status`; the unwind skipped releases the way a
    /// trap's does, and nothing is reported — an exit is not news
    /// about a bug.
    exited,
};

/// One live call.  Frames live on an explicit heap-allocated stack, so
/// call depth is bounded by the budget and available memory — never by
/// the native stack.
pub const Frame = struct {
    function: u32,
    /// Where this frame's slots start in `frame_storage`: registers
    /// first, then locals, one contiguous run released when the frame
    /// returns.  Offsets, not slices — the storage array reallocates
    /// as the stack deepens, and offsets survive that.
    slots_at: usize,
    register_count: u32,
    local_count: u32,
    block: mir.BlockId = 0,
    position: usize = 0,
    /// The caller register receiving this frame's return value.
    destination: mir.Register = 0,
    /// The caller slot aliased by logical local zero.  The slot is an
    /// index because `frame_storage` may move while calls deepen.
    inout: ?Inout = null,
};

const Register = mir.Register;

const Inout = union(enum) {
    /// A slot in the reallocating frame-storage vector. Keep it as an index.
    frame: usize,
    /// A payload cell in an owned interface run. Runtime run allocations are
    /// stable for their lifetime, so this pointer survives deeper calls.
    external: *RuntimeValue,
};

// ---------------------------------------------------------------------------
// The machine
// ---------------------------------------------------------------------------

pub const Machine = struct {
    arena: Allocator,
    /// Luce's semantics: the object heap, ownership, containers,
    /// strings, conversions, and the trap channel.
    runtime: runtime.Runtime,
    program: *const mir.Program,
    max_depth: u32,
    host: ?interpreter.Host,
    stack: std.ArrayList(Frame) = .empty,
    /// Every live frame's registers and locals, as one stack that
    /// pops on return.  Frames used to take a fresh arena slice each
    /// call, which the arena never reclaimed: memory then grew with
    /// the number of calls a program *made* rather than with what it
    /// held, and a long-running loop over a function grew without
    /// bound.  Reused storage makes it O(depth) instead.
    frame_storage: std.ArrayList(RuntimeValue) = .empty,
    /// Scratch for one call's arguments, reused across calls; live
    /// only until pushFrame copies them into the callee's locals.
    argument_scratch: std.ArrayList(RuntimeValue) = .empty,
    /// Scratch for one indexing operation's subscripts, reused; an
    /// array index carries one per axis.
    index_scratch: std.ArrayList(RuntimeValue) = .empty,
    /// Scratch for one `struct_make`'s fields, reused; live only until
    /// the runtime copies them into arena storage.
    field_scratch: std.ArrayList(RuntimeValue) = .empty,
    /// Scratch for one `new array`'s dimension sizes, reused; live
    /// only until the runtime copies them into the array's own shape.
    /// Reused rather than freshly allocated because the arena never
    /// gives a slice back, and a loop that allocates arrays would
    /// otherwise grow memory with the number of arrays it ever made.
    dims_scratch: std.ArrayList(i64) = .empty,
    /// One zero template per struct layout, shared by every zero-
    /// initialized local and element (see zeroValue for why sharing
    /// is safe).  Allocated lazily, sized by program.structs.
    struct_zeros: []?RuntimeValue = &.{},
    /// The same, one per union (docs/UNION.md D13).  Allocated
    /// lazily, sized by program.variants.
    variant_zeros: []?RuntimeValue = &.{},
    /// The declaration being materialized before a function may run.
    /// It is a frame-shaped value because a failed worker must carry
    /// the same located prelude through the ordinary unwind channel as
    /// a trapped function.  Null on every instruction path.
    constant_trace: ?runtime.trace.Frame = null,

    pub const EvalError = runtime.Error;

    // -- trapping, and the traceback a trap carries --------------------

    fn trap(self: *Machine, code: mir.TrapCode) CallOutcome {
        _ = self;
        return .{ .trap = .{ .code = code, .message = code.message() } };
    }

    /// Turn the runtime's pending trap into the boundary's, or pass an
    /// allocation failure through.  Instruction handlers fail with
    /// error.Trap after the runtime records the details; the dispatch
    /// loop catches once, here.  This is the ceval-style pending-error
    /// pattern — no per-operation outcome plumbing.
    fn caught(self: *Machine, mistake: EvalError) error{OutOfMemory}!CallOutcome {
        return switch (mistake) {
            error.OutOfMemory => error.OutOfMemory,
            // An exit rides the trap edge with nothing pending —
            // recorded status, no report — exactly as the compiled
            // path's unwind does (runtime/exports.zig).
            error.Trap => if (self.runtime.exit_status != null)
                .exited
            else
                .{ .trap = .{
                    .code = self.runtime.pending.?.code,
                    .message = self.runtime.pending.?.message,
                } },
        };
    }

    /// Fill a trap's stack trace from the live frame stack, innermost
    /// first.  Each frame's current instruction resolves through the
    /// function's origins table when the module carries one (debug);
    /// a stripped module still names the function, with line 0.
    /// A worker's frames arrive already recorded (`recordUnwind`) and
    /// stand **in front of** this stack's: the trap happened inside the
    /// worker, and the join is only where it was spoken
    /// (docs/THREADS.md D6).  Empty for every program that never
    /// spawned, which is every program the interpreter used to run.
    fn traceback(self: *Machine, reported: *interpreter.Trap) error{OutOfMemory}!void {
        const adopted = self.runtime.unwound.items;
        const depth = self.stack.items.len;
        var room = max_trace_frames -| adopted.len;
        const kept_constant: usize = if (self.constant_trace != null and room != 0) 1 else 0;
        room -= kept_constant;
        const kept = @min(depth, room);
        const frames = try self.arena.alloc(
            interpreter.TraceFrame,
            adopted.len + kept_constant + kept,
        );
        for (adopted, frames[0..adopted.len]) |carried, *slot| {
            slot.* = .{
                .function = carried.function[0..@intCast(carried.function_length)],
                .source = carried.source[0..@intCast(carried.source_length)],
                .line = carried.line,
                .column = carried.column,
            };
        }
        if (kept_constant != 0) {
            const declared = self.constant_trace.?;
            frames[adopted.len] = .{
                .function = declared.function[0..@intCast(declared.function_length)],
                .source = declared.source[0..@intCast(declared.source_length)],
                .line = declared.line,
                .column = declared.column,
            };
        }
        for (frames[adopted.len + kept_constant ..], 0..) |*slot, out_index| {
            const frame = self.stack.items[depth - 1 - out_index];
            const function = &self.program.functions[frame.function];
            const items = function.blocks[frame.block].items;
            // position already advanced past the current instruction,
            // so position - 1 is the instruction that trapped; at
            // position 0 the block's first instruction is the one
            // about to run.  Compiled code names the trapping
            // instruction directly on its unwinding edge, so this is
            // the arithmetic that makes the two traces agree frame for
            // frame — which `specs/agree.zig` checks on every program.
            const at = items[if (frame.position == 0) 0 else frame.position - 1];
            slot.* = .{
                .function = function.name,
                .source = function.source,
                .line = if (at < function.origins.len) function.origins[at].line else 0,
                .column = if (at < function.origins.len) function.origins[at].column else 0,
            };
        }
        reported.trace = frames;
        const dropped_constant: u32 = if (self.constant_trace != null and kept_constant == 0) 1 else 0;
        reported.dropped = @as(u32, @intCast(depth - kept)) +|
            dropped_constant +| self.runtime.dropped_frames;
    }

    /// Record this trap's frames where a **join** can read them
    /// (docs/THREADS.md D6).
    ///
    /// A worker's trace has to outlive the worker's own arena — the
    /// join is where it is spoken, and by then the worker's runtime is
    /// closing — so it goes into `Runtime.unwound`, which is the same
    /// place a compiled worker's frames go and is read by the same
    /// code.  Nothing is copied and nothing needs to be: a frame names
    /// a function and a file out of the *program*, which outlives every
    /// runtime in it.
    ///
    /// Best-effort, exactly as the compiled path's recorder is: a frame
    /// there is no memory for is counted as dropped rather than lost.
    fn recordUnwind(self: *Machine) void {
        if (self.constant_trace) |declared| {
            if (self.runtime.unwound.items.len >= max_trace_frames) {
                self.runtime.dropped_frames +|= 1;
            } else {
                self.runtime.unwound.append(self.runtime.objects, declared) catch {
                    self.runtime.dropped_frames +|= 1;
                };
            }
        }
        const depth = self.stack.items.len;
        const room = max_trace_frames -| self.runtime.unwound.items.len;
        const kept = @min(depth, room);
        self.runtime.dropped_frames +|= @intCast(depth - kept);
        for (0..kept) |out_index| {
            const frame = self.stack.items[depth - 1 - out_index];
            const function = &self.program.functions[frame.function];
            const items = function.blocks[frame.block].items;
            const at = items[if (frame.position == 0) 0 else frame.position - 1];
            self.runtime.unwound.append(self.runtime.objects, .{
                .function = function.name.ptr,
                .function_length = @intCast(function.name.len),
                .source = function.source.ptr,
                .source_length = @intCast(function.source.len),
                .line = if (at < function.origins.len) function.origins[at].line else 0,
                .column = if (at < function.origins.len) function.origins[at].column else 0,
            }) catch {
                self.runtime.dropped_frames +|= 1;
            };
        }
    }

    /// Give back the value storage one frame's slots still own.
    ///
    /// Called as the frame dies, whichever way it died: a return pops
    /// it, and a trap leaves it standing until the sweep below.  Scope
    /// ownership has usually emptied the slots already — a release
    /// writes the emptied value back — so this is the backstop that
    /// makes "a frame's storage dies with the frame" true on every
    /// path, including the one a trap unwinds past (S34).
    ///
    /// Only the slots the module marks `owns_storage` are touched: a
    /// parameter borrows its caller's bytes and a spill carries a
    /// borrow across a branch, so freeing either would be a double
    /// free (docs/STRINGS.md).
    // -- the frame stack, and the world a frame is given ----------------

    fn releaseSlots(self: *Machine, frame: Frame) void {
        const function = &self.program.functions[frame.function];
        const locals = self.frame_storage.items[frame.slots_at + frame.register_count ..][0..frame.local_count];
        for (function.locals, 0..) |local, index| {
            if (!local.owns_storage or local.inout) continue;
            self.runtime.dropStorage(locals[index]);
            locals[index] = runtime.Runtime.emptied(locals[index]);
        }
    }

    fn localSlot(self: *Machine, frame: *const Frame, local: mir.LocalId) *RuntimeValue {
        if (local == 0) {
            if (frame.inout) |inout| return switch (inout) {
                .frame => |slot| &self.frame_storage.items[slot],
                .external => |slot| slot,
            };
        }
        return &self.frame_storage.items[frame.slots_at + frame.register_count + local];
    }

    fn inoutFrom(frame: *const Frame, receiver: mir.LocalId) Inout {
        if (receiver == 0) {
            if (frame.inout) |inout| return inout;
        }
        return .{ .frame = frame.slots_at + frame.register_count + receiver };
    }

    /// The same, for every frame a trap left standing.
    fn releaseFrameStorage(self: *Machine) void {
        for (self.stack.items) |frame| self.releaseSlots(frame);
    }

    fn service(self: *Machine) EvalError!interpreter.Host {
        return self.host orelse return self.runtime.fail(.host_unavailable);
    }

    /// The `list[str]` `main`'s parameter receives (MEMORY.md
    /// S44).
    ///
    /// A host with no arguments to offer — including no host at all —
    /// supplies an **empty** list rather than a trap: `args` is handed
    /// to the program, not called by it, so the gate that covers the
    /// host builtins does not cover this and the entry cannot fail
    /// before `main` starts.  The list itself is `libluce_rt`'s, the
    /// same construction a compiled artifact reaches through
    /// `luce_rt_args_list`.
    fn commandLine(self: *Machine) EvalError!RuntimeValue {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.arena);
        if (self.host) |host| {
            if (host.arg_count) |count| {
                if (host.arg) |get| {
                    const total = count(host.context);
                    var index: u32 = 0;
                    while (index < total) : (index += 1) {
                        // A host that says no about an index it counted
                        // itself has nothing left to say about the ones
                        // after it.
                        const name = (try get(host.context, self.arena, index)) orelse break;
                        try names.append(self.arena, name);
                    }
                }
            }
        }
        return containers.listOfText(&self.runtime, names.items);
    }

    fn terminal(self: *Machine) EvalError!interpreter.Terminal {
        const host = try self.service();
        return host.terminal orelse return self.runtime.fail(.host_unavailable);
    }

    // -- constant-container prologue ------------------------------------

    /// Materialize every reachable constant container into this
    /// runtime's program root before any function executes
    /// (CONSTANTS.md R-C).  The root run and every worker enter through
    /// this one path, so no handle is shared between runtimes.
    fn materializeConstants(self: *Machine) ?CallOutcome {
        const declared = self.program.container_constants;
        if (declared.len != 0) self.constant_trace = self.constantPlace(declared[0]);
        self.runtime.beginConstants(@intCast(declared.len)) catch |mistake| {
            return self.failedConstant(.none, false, mistake);
        };

        var current: RuntimeValue = .none;
        for (declared, 0..) |constant, slot| {
            self.constant_trace = self.constantPlace(constant);
            current = self.materializeConstant(constant, &current) catch |mistake| {
                return self.failedConstant(current, true, mistake);
            };
            self.runtime.publishConstant(@intCast(slot), current) catch |mistake| {
                return self.failedConstant(current, true, mistake);
            };
            current = .none;
        }
        self.runtime.finishConstants();
        self.constant_trace = null;
        return null;
    }

    /// Build one pool row as an ordinary loose container.  `current`
    /// receives its handle as soon as one exists, so the caller can
    /// reclaim a partially filled object on every failing edge.
    fn materializeConstant(
        self: *Machine,
        declared: mir.ContainerConstant,
        current: *RuntimeValue,
    ) EvalError!RuntimeValue {
        switch (self.program.heap_types[declared.heap]) {
            .class => unreachable, // classes are runtime values, never constants
            .list => |element| {
                current.* = try self.runtime.newList(try self.zeroValue(element));
                for (declared.payload.sequence) |encoded| {
                    const held = try self.constantValue(encoded, element);
                    try containers.append(&self.runtime, current.*, held);
                }
            },
            .array => |shape| {
                const encoded = declared.payload.sequence;
                const dims = [_]i64{@intCast(encoded.len)};
                current.* = try self.runtime.newArray(&dims, try self.zeroValue(shape.element));
                for (encoded, 0..) |value, index| {
                    const held = try self.constantValue(value, shape.element);
                    try containers.indexSet(
                        &self.runtime,
                        current.*,
                        &.{RuntimeValue.ofI64(@intCast(index))},
                        held,
                    );
                }
            },
            .map => |pair| {
                current.* = try self.runtime.newMap();
                for (declared.payload.map) |entry| {
                    const held = try self.constantValue(entry.value, pair.value);
                    try containers.indexSet(
                        &self.runtime,
                        current.*,
                        &.{self.constantKey(entry.key, pair.key)},
                        held,
                    );
                }
            },
            // The verifier refuses all three from this pool.  Keeping
            // the switch total documents the trust boundary rather
            // than inventing a second recovery for damaged MIR here.
            .builder, .handle, .task => unreachable,
        }
        return current.*;
    }

    /// Turn one encoded atom into storage the destination container may
    /// consume.  Strings and struct field runs take their own storage;
    /// scalars are already values.  The verifier has checked the
    /// encoding against `wanted`, including enum membership and the
    /// one legal optional position.
    fn constantValue(
        self: *Machine,
        encoded: mir.ConstantValue,
        wanted: types.Type,
    ) EvalError!RuntimeValue {
        if (encoded == .absent) return .none;
        const landed = if (wanted == .optional) wanted.optional.asType() else wanted;
        return switch (encoded) {
            .boolean => |held| .ofBoolean(held),
            .integer => |held| switch (landed.storage()) {
                .u8 => .ofU8(@intCast(held)),
                .u16 => .ofU16(@intCast(held)),
                .u32 => .ofU32(@intCast(held)),
                .u64 => .ofU64(@intCast(held)),
                .i8 => .ofI8(@intCast(held)),
                .i16 => .ofI16(@intCast(held)),
                .i32 => .ofI32(@intCast(held)),
                .i64 => .ofI64(@intCast(held)),
                .char => .ofChar(@intCast(held)),
                else => unreachable,
            },
            .float => |held| switch (landed) {
                .f16 => .ofF16(@floatCast(held)),
                .f32 => .ofF32(@floatCast(held)),
                else => .ofF64(held),
            },
            .str => |index| self.runtime.ownValue(if (landed == .bytes)
                .ofBytes(self.program.constants[index])
            else
                .ofStr(self.program.constants[index])),
            .strukt => |held| self.constantStruct(held),
            .absent => .none,
        };
    }

    /// Materialize one object-free value struct.  The staging slice is
    /// run-lifetime scratch; `makeStruct` consumes every filled value
    /// whether its own allocation succeeds or fails.
    fn constantStruct(self: *Machine, encoded: mir.ConstantValue.Struct) EvalError!RuntimeValue {
        const layout = self.program.structs[encoded.layout];
        const fields = try self.arena.alloc(RuntimeValue, encoded.fields.len);
        var filled: usize = 0;
        errdefer for (fields[0..filled]) |field| self.runtime.dropStorage(field);
        for (encoded.fields, layout.fields, fields) |field, declared, *slot| {
            const materialized = try self.constantValue(field, declared.field_type);
            if (declared.weak) {
                slot.* = self.runtime.weaken(materialized) catch |mistake| {
                    self.runtime.freeValue(materialized);
                    return mistake;
                };
                self.runtime.freeValue(materialized);
            } else {
                slot.* = materialized;
            }
            filled += 1;
        }
        const made = self.runtime.makeStruct(fields) catch |mistake| {
            // `makeStruct` consumes every field on both outcomes.
            filled = 0;
            return mistake;
        };
        filled = 0;
        return made;
    }

    /// A map key is borrowed for `indexSet`, which takes its own copy only
    /// when a new entry keeps it. Integers retain their explicit width and
    /// an enum uses its backing width, exactly as a later lookup does.
    fn constantKey(
        self: *const Machine,
        encoded: mir.ConstantValue,
        written: types.Type,
    ) RuntimeValue {
        return switch (encoded) {
            .integer => |held| switch (mir.mapKeyStorage(written)) {
                .u8 => .ofU8(@intCast(held)),
                .u16 => .ofU16(@intCast(held)),
                .u32 => .ofU32(@intCast(held)),
                .u64 => .ofU64(@intCast(held)),
                .i8 => .ofI8(@intCast(held)),
                .i16 => .ofI16(@intCast(held)),
                .i32 => .ofI32(@intCast(held)),
                .i64 => .ofI64(@intCast(held)),
                else => unreachable,
            },
            .str => |index| .ofStr(self.program.constants[index]),
            else => unreachable,
        };
    }

    fn constantPlace(self: *const Machine, declared: mir.ContainerConstant) runtime.trace.Frame {
        _ = self;
        return .{
            .function = declared.name.ptr,
            .function_length = @intCast(declared.name.len),
            .source = declared.source.ptr,
            .source_length = @intCast(declared.source.len),
            .line = declared.origin.line,
            .column = declared.origin.column,
        };
    }

    /// Close a failed prologue and return the trap already waiting in
    /// the shared runtime channel.  Raw allocator failure from an
    /// ordinary construction becomes the declaration's located
    /// `allocation_failed` trap, just as the C export funnel does for
    /// generated code.
    fn failedConstant(
        self: *Machine,
        current: RuntimeValue,
        began: bool,
        mistake: EvalError,
    ) CallOutcome {
        if (mistake == error.OutOfMemory) {
            const raised = self.runtime.fail(.allocation_failed);
            std.debug.assert(raised == error.Trap);
        }
        if (began) {
            self.runtime.discardLoose(current);
            self.runtime.abortConstants();
        }
        const pending = self.runtime.pending.?;
        return .{ .trap = .{ .code = pending.code, .message = pending.message } };
    }

    fn pushFrame(
        self: *Machine,
        function_index: u32,
        arguments: []const RuntimeValue,
        destination: Register,
        inout: ?Inout,
    ) error{OutOfMemory}!?CallOutcome {
        if (self.stack.items.len >= self.max_depth) return self.trap(.call_depth_exceeded);
        const function = &self.program.functions[function_index];
        const slots_at = self.frame_storage.items.len;
        const register_count = function.instructions.len;
        const local_count = function.locals.len;
        try self.frame_storage.appendNTimes(self.arena, .none, register_count + local_count);
        // Safe to hold across zeroValue: it allocates struct fields
        // from the arena and never touches frame_storage.
        const locals = self.frame_storage.items[slots_at + register_count ..][0..local_count];
        const argument_start: usize = if (inout == null) 0 else 1;
        @memcpy(locals[argument_start..][0..arguments.len], arguments);
        // Every non-parameter local starts at its type's zero value,
        // not a bare .none: a well-formed function sets locals before
        // reading them, but a hand-forged or bit-flipped module may
        // read one early, and a typed zero (0/false/""/null object)
        // keeps that a clean value or a null_object trap instead of a
        // crash on an untagged .none.  This is the same rule as S40's
        // late declarations, applied defensively at the trust
        // boundary.  Parameter slots are copied over whole, so zeroing
        // them first would only buy per-call allocations for struct
        // parameters.
        for (locals[function.parameter_count..], function.locals[function.parameter_count..]) |*slot, local| {
            // A slot that owns its storage starts *empty* rather than
            // at the shared zero: the zero template is one value per
            // layout, and the release this slot will get must never
            // hand a shared run back (docs/STRINGS.md).
            slot.* = if (local.weak)
                .ofWeak(.none)
            else if (local.owns_storage)
                emptyValue(local.local_type)
            else
                try self.zeroValue(local.local_type);
        }
        try self.stack.append(self.arena, .{
            .function = function_index,
            .slots_at = slots_at,
            .register_count = @intCast(register_count),
            .local_count = @intCast(local_count),
            .destination = destination,
            .inout = inout,
        });
        return null;
    }

    // -- the dispatch loop ----------------------------------------------

    pub fn execute(self: *Machine, entry: u32) error{OutOfMemory}!CallOutcome {
        if (self.materializeConstants()) |failed| return failed;
        // `func main(args: list[str]):` receives the command line;
        // `func main():` receives nothing, and those are the only two
        // shapes stage 4 lets through (docs/LANGUAGE.md).  The list is
        // built the same way the compiled arm builds it — `libluce_rt`
        // owns the semantic and each engine hands it what its own host
        // spells the arguments in (MEMORY.md).
        var received: [1]RuntimeValue = .{.none};
        var arguments: []const RuntimeValue = &.{};
        const takes_arguments = self.program.functions[entry].parameter_count == 1;
        if (takes_arguments) {
            received[0] = self.commandLine() catch |mistake| return self.caught(mistake);
            arguments = &received;
        }
        const outcome = try self.call(entry, arguments);
        // The parameter was a borrow, so `main` left the list alive; the
        // entry that built it releases it now, the way the compiled arm
        // does before the census is read (docs/MEMORY.md).
        if (takes_arguments) self.runtime.freeObjectsIn(received[0]);
        return outcome;
    }

    /// Run one function with the arguments already in hand — what the
    /// entry does once the command line is built, and what a worker's
    /// thread does with the arguments `workers.spawn` moved across
    /// (docs/THREADS.md).  One dispatch loop, entered two ways.
    pub fn call(
        self: *Machine,
        entry: u32,
        arguments: []const RuntimeValue,
    ) error{OutOfMemory}!CallOutcome {
        if (try self.pushFrame(entry, arguments, 0, null)) |failed| return failed;

        dispatch: while (true) {
            // Re-derived every time round the dispatch loop: pushing a
            // frame may reallocate the storage, and every path that
            // pushes one continues here rather than reusing these.
            const frame = &self.stack.items[self.stack.items.len - 1];
            const function = &self.program.functions[frame.function];
            const slots = self.frame_storage.items[frame.slots_at..];
            const registers = slots[0..frame.register_count];
            const items = function.blocks[frame.block].items;

            while (frame.position < items.len) {
                const item = items[frame.position];
                frame.position += 1;
                const instruction = function.instructions[item];
                switch (instruction) {
                    .const_boolean => |value| registers[item] = .ofBoolean(value),
                    // A numeric constant travels at the widest member
                    // of its family and lands at the register's own
                    // width (docs/TYPES.md §1).
                    // An enum member is a constant at its backing width
                    // (docs/ENUMS.md D10), so `storage()` answers for
                    // it here exactly as it does on the compiled path.
                    .const_integer => |value| registers[item] = switch (function.result_types[item].storage()) {
                        .u8 => .ofU8(@intCast(value)),
                        .u16 => .ofU16(@intCast(value)),
                        .u32 => .ofU32(@intCast(value)),
                        .u64 => .ofU64(@intCast(value)),
                        .i8 => .ofI8(@intCast(value)),
                        .i16 => .ofI16(@intCast(value)),
                        .i32 => .ofI32(@intCast(value)),
                        .i64 => .ofI64(@intCast(value)),
                        .char => .ofChar(@intCast(value)),
                        else => unreachable,
                    },
                    .const_float => |value| registers[item] = switch (function.result_types[item]) {
                        .f16 => .ofF16(@floatCast(value)),
                        .f32 => .ofF32(@floatCast(value)),
                        else => .ofF64(value),
                    },
                    .const_str => |constant| {
                        registers[item] = if (function.result_types[item] == .bytes)
                            .ofBytes(self.program.constants[constant])
                        else
                            .ofStr(self.program.constants[constant]);
                    },
                    .const_container => |constant| {
                        registers[item] = self.runtime.constant(constant);
                    },
                    // A function value is a two-slot run: the function
                    // it names, then the receiver it carries or `none`
                    // (docs/BINDING.md D12).  Built the way a struct
                    // value is built and worn under a tag of its own,
                    // so every ownership walk stops at it — the
                    // receiver is borrowed and the run owns none of it
                    // (D4) — and so the compiled path holds the same
                    // bytes and the two engines compare and print
                    // alike.
                    .const_function => |named| {
                        self.field_scratch.clearRetainingCapacity();
                        try self.field_scratch.ensureTotalCapacity(
                            self.arena,
                            mir.function_run_length,
                        );
                        self.field_scratch.appendAssumeCapacity(.ofI32(@intCast(named.function)));
                        self.field_scratch.appendAssumeCapacity(
                            if (named.receiver) |receiver| registers[receiver] else .none,
                        );
                        registers[item] = self.runtime.makeFunction(self.field_scratch.items) catch |mistake|
                            return self.caught(mistake);
                    },
                    .local_get => |local| registers[item] = self.localSlot(frame, local).*,
                    .local_set => |set| self.localSlot(frame, set.local).* = registers[set.value],
                    .weak_local_get => |local| {
                        registers[item] = self.runtime.strengthen(self.localSlot(frame, local).*) catch |mistake|
                            return self.caught(mistake);
                    },
                    .weak_local_set => |set| {
                        self.localSlot(frame, set.local).* = self.runtime.weaken(registers[set.value]) catch |mistake|
                            return self.caught(mistake);
                    },
                    .binary => |operation| {
                        registers[item] = operators.binary(
                            &self.runtime,
                            operation.op,
                            registers[operation.left],
                            registers[operation.right],
                        ) catch |mistake| return self.caught(mistake);
                    },
                    .unary => |operation| {
                        const operand = registers[operation.operand];
                        registers[item] = switch (operation.op) {
                            .logic_not => operators.logicalNot(operand),
                            .bit_not => operators.bitNot(operand),
                            .negate => operators.negate(&self.runtime, operand) catch |mistake|
                                return self.caught(mistake),
                        };
                    },
                    .convert => |operand_register| {
                        const operand = registers[operand_register];
                        registers[item] = operators.convert(
                            &self.runtime,
                            operand,
                            mir.boxTag(function.result_types[item]).?,
                        ) catch |mistake| return self.caught(mistake);
                    },
                    .interface_make => |make| {
                        self.field_scratch.clearRetainingCapacity();
                        try self.field_scratch.ensureTotalCapacity(
                            self.arena,
                            mir.interface_run_length,
                        );
                        self.field_scratch.appendAssumeCapacity(.ofI64(make.witness + 1));
                        self.field_scratch.appendAssumeCapacity(registers[make.receiver]);
                        registers[item] = self.runtime.makeStruct(self.field_scratch.items) catch |mistake|
                            return self.caught(mistake);
                    },
                    .struct_make => |make| {
                        const layout = self.program.structs[make.layout];
                        self.field_scratch.clearRetainingCapacity();
                        try self.field_scratch.ensureTotalCapacity(self.arena, make.fields.len);
                        for (make.fields, layout.fields) |field_register, field| {
                            self.field_scratch.appendAssumeCapacity(if (field.weak)
                                self.runtime.weaken(registers[field_register]) catch |mistake|
                                    return self.caught(mistake)
                            else
                                registers[field_register]);
                        }
                        registers[item] = (if (layout.reference)
                            self.runtime.newClass(
                                make.layout,
                                layout.deinitializer,
                                self.field_scratch.items,
                            )
                        else
                            self.runtime.makeStruct(self.field_scratch.items)) catch |mistake|
                            return self.caught(mistake);
                    },
                    .struct_get => |get| {
                        registers[item] = if (self.program.structs[get.layout].reference)
                            self.runtime.classField(registers[get.target], get.layout, get.field) catch |mistake|
                                return self.caught(mistake)
                        else
                            registers[get.target].asStruct()[get.field];
                    },
                    .weak_struct_get => |get| {
                        registers[item] = self.runtime.strengthen(
                            if (self.program.structs[get.layout].reference)
                                self.runtime.classField(registers[get.target], get.layout, get.field) catch |mistake|
                                    return self.caught(mistake)
                            else
                                registers[get.target].asStruct()[get.field],
                        ) catch |mistake| return self.caught(mistake);
                    },
                    .struct_set => |set| {
                        if (self.program.structs[set.layout].reference) {
                            self.runtime.setClassField(
                                registers[set.target],
                                set.layout,
                                set.field,
                                registers[set.value],
                            ) catch |mistake| return self.caught(mistake);
                            registers[item] = .none;
                        } else {
                            registers[item] = self.runtime.setField(
                                registers[set.target],
                                set.field,
                                registers[set.value],
                            ) catch |mistake| return self.caught(mistake);
                        }
                    },
                    // A union value is a struct value whose slot 0 is
                    // the member index (docs/UNION.md D8): the same
                    // runtime path builds it, and the run is padded to
                    // the union's one static length with `none` slots
                    // that own nothing (`types.VariantType.runLength`).
                    .variant_make => |make| {
                        const declared = self.program.variants[make.variant];
                        const span = declared.runLength();
                        self.field_scratch.clearRetainingCapacity();
                        try self.field_scratch.ensureTotalCapacity(self.arena, span);
                        self.field_scratch.appendAssumeCapacity(.ofI64(make.member));
                        for (make.fields) |field_register| {
                            self.field_scratch.appendAssumeCapacity(registers[field_register]);
                        }
                        while (self.field_scratch.items.len < span) {
                            self.field_scratch.appendAssumeCapacity(.none);
                        }
                        registers[item] = self.runtime.makeStruct(self.field_scratch.items) catch |mistake|
                            return self.caught(mistake);
                    },
                    .weak_struct_set => |set| {
                        const weak = self.runtime.weaken(registers[set.value]) catch |mistake|
                            return self.caught(mistake);
                        if (self.program.structs[set.layout].reference) {
                            self.runtime.setClassField(
                                registers[set.target],
                                set.layout,
                                set.field,
                                weak,
                            ) catch |mistake| return self.caught(mistake);
                            registers[item] = .none;
                        } else {
                            registers[item] = self.runtime.setField(
                                registers[set.target],
                                set.field,
                                weak,
                            ) catch |mistake| return self.caught(mistake);
                        }
                    },
                    .variant_tag => |tag| {
                        registers[item] = registers[tag.target].asStruct()[0];
                    },
                    .variant_field => |get| {
                        registers[item] = registers[get.target].asStruct()[1 + get.field];
                    },
                    .heap_new => |new| {
                        registers[item] = self.allocateObject(new, registers) catch |mistake|
                            return self.caught(mistake);
                    },
                    .call => |called| {
                        // Reused scratch, not a fresh arena slice per
                        // call: pushFrame copies it into the callee's
                        // locals and nothing outlives that.
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(self.arena, called.arguments.len);
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        if (try self.pushFrame(called.function, self.argument_scratch.items, item, null)) |failed| {
                            return failed;
                        }
                        continue :dispatch;
                    },
                    .call_inout => |called| {
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(self.arena, called.arguments.len);
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        const inout = inoutFrom(frame, called.receiver);
                        if (try self.pushFrame(
                            called.function,
                            self.argument_scratch.items,
                            item,
                            inout,
                        )) |failed| return failed;
                        continue :dispatch;
                    },
                    .interface_call => |called| {
                        const erased = self.interfaceValue(registers[called.receiver], called.layout) orelse
                            return self.trap(.null_object);
                        const target_index = erased.witness.methods[called.method];
                        const target = &self.program.functions[target_index];
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(
                            self.arena,
                            called.arguments.len + 1,
                        );
                        const inout: ?Inout = if (target.locals[0].inout)
                            .{ .external = erased.payload }
                        else blk: {
                            self.argument_scratch.appendAssumeCapacity(erased.payload.*);
                            break :blk null;
                        };
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        if (try self.pushFrame(
                            target_index,
                            self.argument_scratch.items,
                            item,
                            inout,
                        )) |failed| return failed;
                        continue :dispatch;
                    },
                    .interface_call_inout => |called| {
                        const erased = self.interfaceValue(
                            self.localSlot(frame, called.receiver).*,
                            called.layout,
                        ) orelse return self.trap(.null_object);
                        const target_index = erased.witness.methods[called.method];
                        const target = &self.program.functions[target_index];
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(
                            self.arena,
                            called.arguments.len + 1,
                        );
                        const inout: ?Inout = if (target.locals[0].inout)
                            .{ .external = erased.payload }
                        else blk: {
                            self.argument_scratch.appendAssumeCapacity(erased.payload.*);
                            break :blk null;
                        };
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        if (try self.pushFrame(
                            target_index,
                            self.argument_scratch.items,
                            item,
                            inout,
                        )) |failed| return failed;
                        continue :dispatch;
                    },
                    // A call through a function value: the callee's
                    // index is in a register instead of the
                    // instruction, and everything after that is the
                    // call above, unchanged (docs/FUNCTIONS.md D2).
                    .call_indirect => |called| {
                        // The value names a function or it names
                        // nothing, and nothing is what an unwritten slot
                        // holds; the compiled path makes the same
                        // refusal at the same call.
                        const bound = self.boundValue(registers[called.callee]) orelse
                            return self.trap(.null_object);
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(
                            self.arena,
                            called.arguments.len + 1,
                        );
                        // **The receiver is argument zero**, exactly
                        // where the callee's own parameter zero is, so a
                        // bound call is the direct call it always was
                        // with one more value in front (BINDING.md D12).
                        if (bound.receiver) |receiver| {
                            self.argument_scratch.appendAssumeCapacity(receiver);
                        }
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        if (try self.pushFrame(
                            bound.named,
                            self.argument_scratch.items,
                            item,
                            null,
                        )) |failed| return failed;
                        continue :dispatch;
                    },
                    // `spawn f(args)` — the arguments are gathered the
                    // way a call's are and handed to `libluce_rt`,
                    // which opens the worker's runtime, moves them
                    // into it and starts the thread
                    // (docs/THREADS.md D2).  Nothing about the callee
                    // is entered here: the worker enters it, on its own
                    // thread, through the nursery.
                    .spawn => |called| {
                        self.argument_scratch.clearRetainingCapacity();
                        try self.argument_scratch.ensureTotalCapacity(self.arena, called.arguments.len);
                        for (called.arguments) |argument| {
                            self.argument_scratch.appendAssumeCapacity(registers[argument]);
                        }
                        var started: RuntimeValue = .none;
                        runtime.workers.spawn(
                            &self.runtime,
                            called.function,
                            self.argument_scratch.items,
                            &started,
                        ) catch |mistake| return self.caught(mistake);
                        registers[item] = started;
                    },
                    .intrinsic => |operation| {
                        registers[item] = self.intrinsic(
                            operation,
                            registers,
                            .{ .function = frame.function, .instruction = item },
                        ) catch |mistake| return self.caught(mistake);
                    },
                    .jump => |target| {
                        frame.block = target;
                        frame.position = 0;
                        continue :dispatch;
                    },
                    .branch => |branched| {
                        frame.block = if (registers[branched.condition].asBoolean())
                            branched.then_block
                        else
                            branched.else_block;
                        frame.position = 0;
                        continue :dispatch;
                    },
                    .ret => |value| {
                        const returned: RuntimeValue = if (value) |register| registers[register] else .none;
                        const finished = self.stack.pop().?;
                        // `returned` is this frame's own — `ret` copies
                        // out anything it borrowed (docs/STRINGS.md) —
                        // so whatever the slots still hold dies here,
                        // and then the slots go back.
                        self.releaseSlots(finished);
                        self.frame_storage.shrinkRetainingCapacity(finished.slots_at);
                        if (self.stack.items.len == 0) return .{ .value = returned };
                        const parent = &self.stack.items[self.stack.items.len - 1];
                        const parent_function = &self.program.functions[parent.function];
                        if (parent_function.result_types[finished.destination] != .none) {
                            self.frame_storage.items[parent.slots_at + finished.destination] = returned;
                        }
                        continue :dispatch;
                    },
                    .trap => |code| return self.trap(code),
                    // The error is already in the channel — `try` put
                    // it there by not catching it, `error(…)` by
                    // raising it — and the releases it owes stand in
                    // the block in front of this.  So this is `ret`
                    // with nothing to hand back and one thing left
                    // behind (docs/FAILURE.md).
                    .unwind => {
                        const finished = self.stack.pop().?;
                        self.releaseSlots(finished);
                        self.frame_storage.shrinkRetainingCapacity(finished.slots_at);
                        if (self.stack.items.len == 0) return .{ .errored = {} };
                        // **A call that raised answered nothing, and
                        // the register it would have answered into has
                        // to say so.**  Registers are frame storage
                        // reused turn after turn, so leaving it alone
                        // leaves the answer this same instruction gave
                        // the *last* time it ran — and stage 4 stores
                        // that register into the slot that carries the
                        // answer across the branch on the outcome
                        // (`openFallible`), on the failing edge as
                        // well as the returning one, because a
                        // register may not cross a block.  Releasing
                        // the slot then gives back storage the earlier
                        // turn already gave back.
                        //
                        // Emptying it is exactly what the compiled
                        // path does before it returns `errored`
                        // (`codegen/lower.zig`'s `leaveErrored`), and
                        // the same shape: the tag it had, with no
                        // storage under it, which every release reads
                        // as nothing to free.
                        const parent = &self.stack.items[self.stack.items.len - 1];
                        const parent_function = &self.program.functions[parent.function];
                        if (parent_function.result_types[finished.destination] != .none) {
                            const answered = &self.frame_storage.items[parent.slots_at + finished.destination];
                            answered.* = runtime.Runtime.emptied(answered.*);
                        }
                        continue :dispatch;
                    },
                }
                // Some ownership operations return no value yet may release
                // the last reference to a class.  Its deinitializer runs
                // inside that runtime operation and can trap, exit, or
                // exhaust the run; surface that terminal state before the
                // next Luce instruction executes.
                if (self.runtime.exhausted) return error.OutOfMemory;
                if (self.runtime.pending != null or self.runtime.exit_status != null) {
                    return self.caught(error.Trap);
                }
            }
            unreachable; // the verifier guarantees a terminator
        }
    }

    // -- allocation and zero values ------------------------------------
    //
    // The two places the interpreter still shapes values itself, both
    // because they read the program's type tables — which the runtime
    // library deliberately does not know.  Compiled code resolves both
    // at compile time instead.

    /// `new list[T]` / `new map[K, V]` / `new array[T, ...]` / `new
    /// builder`: read the shape from the program's heap-type table and
    /// ask the runtime for the object.
    pub fn allocateObject(
        self: *Machine,
        new: mir.Instruction.HeapNew,
        registers: []const RuntimeValue,
    ) EvalError!RuntimeValue {
        switch (self.program.heap_types[new.heap]) {
            .class => unreachable, // constructed through the nominal aggregate path
            .list => |element| return self.runtime.newList(try self.zeroValue(element)),
            .map => return self.runtime.newMap(),
            .builder => return self.runtime.newBuilder(),
            // A file is made by `file_open` and by nothing else, so
            // there is no `new handle` for this to answer; stage 4
            // refuses one and the verifier refuses the IR.
            .handle => unreachable,
            // Nor is there a `new task`: `spawn` is the only door in,
            // for the same reason (docs/THREADS.md D3).
            .task => unreachable,
            .array => |shape| {
                self.dims_scratch.clearRetainingCapacity();
                try self.dims_scratch.ensureTotalCapacity(self.arena, new.dims.len);
                for (new.dims) |register| {
                    self.dims_scratch.appendAssumeCapacity(registers[register].asI64());
                }
                return self.runtime.newArray(
                    self.dims_scratch.items,
                    try self.zeroValue(shape.element),
                );
            },
        }
    }

    /// The `Value` a map key travels as, read out of the register that
    /// holds it. Integers keep their explicit width and an enum uses its
    /// backing width (`mir.mapKeyStorage`).
    ///
    /// This is the whole of what enum keys cost the engines, and it is
    /// why `libluce_rt` hashes and compares exactly two payloads
    /// (docs/ENUMS.md, As built 2026-08-12).  The compiled path says
    /// the same thing as a `sext`/`zext` into the box it fills.
    ///
    /// A subscript that is not a key—a list index or array axis—is
    /// `i64` already, so this is the identity there and every
    /// indexing door can go through it without asking what it indexes.
    fn storedKey(self: *const Machine, site: Site, held: RuntimeValue, register: Register) RuntimeValue {
        const written = self.program.functions[site.function].result_types[register];
        _ = written;
        return held;
    }

    /// A key read back out of a map at the exact type the program keys by.
    /// Storage preserved that width, so both execution paths return it
    /// without a representation change.
    fn keyOfStored(self: *const Machine, site: Site, held: RuntimeValue) RuntimeValue {
        const written = self.program.functions[site.function].result_types[site.instruction];
        _ = written;
        return held;
    }

    /// The element type of the list an intrinsic answers, read off the
    /// program's type table.
    ///
    /// `m.keys()` and `m.values()` build a list out of values the
    /// runtime is holding, and the *kind* its cells are stored at is a
    /// fact of the program's element type rather than of the builder
    /// (`runtime/containers.zig`'s `emptyList`).  The oracle knows the
    /// type table directly, where compiled code carries the zero to
    /// the call; both ask the same question of the same table.
    fn answeredElement(self: *Machine, site: Site) types.Type {
        const answered = self.program.functions[site.function].result_types[site.instruction];
        return switch (self.program.heap_types[answered.heap]) {
            .list => |element| element,
            // The verifier admits nothing else here: keys and values
            // answer a list and only a list.
            .class, .map, .array, .builder, .handle, .task => unreachable,
        };
    }

    /// What a function value holds: the function it names, and the
    /// receiver it carries or nothing (docs/BINDING.md D12).
    const Bound = struct { named: u32, receiver: ?RuntimeValue };

    /// Read one, or null when the value names no function at all —
    /// which is what an unwritten function-typed slot holds, and what a
    /// hand-made module could put anywhere.
    ///
    /// Every reader of a function value goes through here, so the
    /// refusal is written once and says the same thing the compiled
    /// path's `namedFunction` says at the same place.
    fn boundValue(self: *Machine, held: RuntimeValue) ?Bound {
        if (held.tag != .function or held.bits == 0) return null;
        const slots = held.asStruct();
        if (slots.len != mir.function_run_length) return null;
        const named = slots[mir.function_run_named].asI32();
        if (named < 0 or named >= self.program.functions.len) return null;
        const receiver = slots[mir.function_run_receiver];
        return .{
            .named = @intCast(named),
            .receiver = if (receiver.tag == .none) null else receiver,
        };
    }

    const InterfaceValue = struct {
        witness: *const mir.InterfaceWitness,
        payload: *RuntimeValue,
    };

    /// Resolve the private two-slot existential run. Zero/uninitialized and
    /// malformed values all take the ordinary null-object trap at the call.
    fn interfaceValue(
        self: *Machine,
        held: RuntimeValue,
        layout: u32,
    ) ?InterfaceValue {
        if (held.tag != .strukt) return null;
        const slots = held.asStruct();
        if (slots.len != mir.interface_run_length) return null;
        if (slots[mir.interface_run_witness].tag != .i64) return null;
        const one_based = slots[mir.interface_run_witness].asI64();
        if (one_based <= 0 or one_based > self.program.interface_witnesses.len)
            return null;
        const witness = &self.program.interface_witnesses[@intCast(one_based - 1)];
        if (witness.interface != layout) return null;
        return .{
            .witness = witness,
            .payload = &slots[mir.interface_run_payload],
        };
    }

    /// The zero value a fresh local or array element carries, per type.
    pub fn zeroValue(self: *Machine, written: types.Type) error{OutOfMemory}!RuntimeValue {
        // An enum-typed slot starts at the enum's **first declared
        // member** (docs/ENUMS.md): zero is a value no member need
        // hold, and every value of an enum is a member.
        if (written == .enumeration) {
            const declared = self.program.enums[written.enumeration.index];
            const first = declared.members[0].value;
            return switch (declared.backing) {
                .u8 => .ofU8(@intCast(first)),
                .u16 => .ofU16(@intCast(first)),
                .u32 => .ofU32(@intCast(first)),
                .u64 => .ofU64(@intCast(first)),
                .i8 => .ofI8(@intCast(first)),
                .i16 => .ofI16(@intCast(first)),
                .i32 => .ofI32(@intCast(first)),
                .i64 => .ofI64(@intCast(first)),
            };
        }
        const of = written;
        return switch (of) {
            .none => .none,
            .boolean => .ofBoolean(false),
            .u8 => .ofU8(0),
            .u16 => .ofU16(0),
            .u32 => .ofU32(0),
            .u64 => .ofU64(0),
            .i8 => .ofI8(0),
            .i16 => .ofI16(0),
            .i32 => .ofI32(0),
            .i64 => .ofI64(0),
            .f16 => .ofF16(0.0),
            .f32 => .ofF32(0.0),
            .f64 => .ofF64(0.0),
            .char => .ofChar(0),
            .str => .ofStr(""),
            .bytes => .ofBytes(""),
            .heap => .null_object,
            // The zero of a `T?` is absence, which owns nothing (S43).
            .optional => .none,
            .enumeration => unreachable, // answered above
            // The slot fill of a function-typed local, which nothing a
            // program can write ever reads: stage 4 refuses the one
            // declaration that would ask for a function value's zero,
            // and every reader of one refuses the run that is nowhere,
            // exactly as the compiled path does (docs/FUNCTIONS.md, As
            // built; docs/BINDING.md D12).
            .function => .{ .tag = .function, .length = mir.function_run_length },
            .strukt => |layout_index| blk: {
                // One shared zero template per layout, built on first
                // use.  Sharing the fields slice across every
                // zero-initialized local and element is safe because
                // struct field arrays are never mutated in place —
                // struct_set always allocates a fresh array (value
                // semantics).  If in-place struct mutation is ever
                // added, this template must be copied out instead.
                // Without the cache, a loop calling a function with a
                // struct local allocated per call, growing evaluation
                // memory with calls made rather than data held.
                if (self.struct_zeros.len == 0) {
                    self.struct_zeros = try self.arena.alloc(?RuntimeValue, self.program.structs.len);
                    @memset(self.struct_zeros, null);
                }
                if (self.struct_zeros[layout_index]) |zero| break :blk zero;
                const layout = self.program.structs[layout_index];
                const fields = try self.arena.alloc(RuntimeValue, layout.runLength());
                if (layout.interface) {
                    fields[mir.interface_run_witness] = .ofI64(0);
                    fields[mir.interface_run_payload] = .none;
                } else {
                    for (layout.fields, fields) |field, *slot| {
                        slot.* = if (field.weak)
                            .ofWeak(.none)
                        else
                            try self.zeroValue(field.field_type);
                    }
                }
                const zero: RuntimeValue = .ofStruct(fields);
                self.struct_zeros[layout_index] = zero;
                break :blk zero;
            },
            // A union's zero is its first declared member with every
            // payload field at its own zero (docs/UNION.md D13): the
            // run is the member index in slot 0, then that member's
            // field zeros (D8), padded to the union's one static run
            // length with `none` slots that own nothing.  One shared
            // template per union, cached for the same reason a struct
            // layout's is, and shareable for the same reason: runs are
            // never mutated in place.
            .variant => |index| blk: {
                if (self.variant_zeros.len == 0) {
                    self.variant_zeros = try self.arena.alloc(?RuntimeValue, self.program.variants.len);
                    @memset(self.variant_zeros, null);
                }
                if (self.variant_zeros[index]) |zero| break :blk zero;
                const declared = self.program.variants[index];
                const member = declared.members[0];
                const slots = try self.arena.alloc(RuntimeValue, declared.runLength());
                slots[0] = .ofI64(0);
                for (member.fields, slots[1..][0..member.fields.len]) |field, *slot| {
                    slot.* = try self.zeroValue(field.field_type);
                }
                @memset(slots[1 + member.fields.len ..], .none);
                const zero: RuntimeValue = .ofStruct(slots);
                self.variant_zeros[index] = zero;
                break :blk zero;
            },
        };
    }

    // -- intrinsic dispatch -------------------------------------------
    //
    // Read the operands out of the registers and hand them to the
    // runtime library.  The only arms with a body of their own are the
    // host effects, which are not language semantics but services.

    /// Where the instruction being run was written — what an error
    /// records, and the one position it carries (docs/FAILURE.md).
    /// Two indices passed in registers, so nothing is resolved until
    /// something actually raises.
    pub const Site = struct { function: u32, instruction: mir.Register };

    /// The frame an error raised at `site` reports.  Resolved through
    /// the program's own tables — the interpreter has the program, so
    /// unlike compiled code it never needs `Runtime.functions`.
    fn placeOf(self: *const Machine, site: Site) runtime.trace.Frame {
        const function = &self.program.functions[site.function];
        const has_origin = site.instruction < function.origins.len;
        return .{
            .function = function.name.ptr,
            .function_length = @intCast(function.name.len),
            .source = function.source.ptr,
            .source_length = @intCast(function.source.len),
            .line = if (has_origin) function.origins[site.instruction].line else 0,
            .column = if (has_origin) function.origins[site.instruction].column else 0,
        };
    }

    /// One machine fact, once its host has been asked.  Null is the
    /// host saying it cannot tell — `abi.MachineFactFn`'s `no` — and
    /// it refuses exactly as a withheld service does, because the one
    /// thing a program must never be handed is a number nobody
    /// measured.
    fn machineFact(self: *Machine, told: ?i64) EvalError!RuntimeValue {
        return .ofI64(told orelse return self.runtime.fail(.host_unavailable));
    }

    pub fn intrinsic(
        self: *Machine,
        operation: mir.Instruction.IntrinsicCall,
        registers: []const RuntimeValue,
        site: Site,
    ) EvalError!RuntimeValue {
        // The effect lock, around exactly the intrinsics that call a
        // host service (docs/THREADS.md D9).  It costs a program that
        // never spawns nothing at all — `Runtime.effects` stays null
        // and both halves are a load and a branch on it — and it is
        // what makes `print` from three workers line-atomic without
        // any host being thread-safe.
        if (operation.kind.reachesHost()) {
            self.runtime.enterEffects();
            defer self.runtime.leaveEffects();
            return self.effect(operation, registers, site);
        }
        return self.effect(operation, registers, site);
    }

    fn effect(
        self: *Machine,
        operation: mir.Instruction.IntrinsicCall,
        registers: []const RuntimeValue,
        site: Site,
    ) EvalError!RuntimeValue {
        const arguments = operation.arguments;
        switch (operation.kind) {
            .abs => return operators.absolute(&self.runtime, registers[arguments[0]]),
            .min, .max => return operators.extremum(
                operation.kind == .min,
                registers[arguments[0]],
                registers[arguments[1]],
            ),
            .clamp => return operators.clamp(
                registers[arguments[0]],
                registers[arguments[1]],
                registers[arguments[2]],
            ),
            .sqrt => return operators.squareRoot(registers[arguments[0]]),
            .floor => return operators.floor(registers[arguments[0]]),
            .ceil => return operators.ceil(registers[arguments[0]]),
            .trunc => return operators.truncate(registers[arguments[0]]),
            .len => return containers.length(&self.runtime, registers[arguments[0]]),
            .null_object => return .null_object,

            // Optionals.  A `RuntimeValue` already carries its own tag,
            // so absence is the tag and presence is the payload as it
            // stands: widening and unwrapping move no bits.  Unwrap is
            // what narrowing licensed and never checks — the analyzer
            // proved the value is there (docs/FAILURE.md).
            .none_value => return .none,
            .is_none => return .ofBoolean(registers[arguments[0]].isNone()),

            // Errors.  The channel is a field on the runtime, so
            // "did that call raise" is a load and "forget it" a store
            // (docs/FAILURE.md).  `errored` reads the channel rather
            // than its argument: it can only stand where the call it
            // names has just returned, and nothing else can be in it.
            .errored => return .ofBoolean(self.runtime.raised != null),
            // The words, borrowed out of the arena that holds them, so
            // both engines hand `catch NAME:` the same view and the
            // binding's own store is what copies.
            .error_message => {
                const raised = self.runtime.raised orelse return .ofStr("");
                return .ofStr(raised.message);
            },
            .forget => {
                self.runtime.forget();
                return .none;
            },
            .raise_error => {
                // `raise` takes the copy that outlives the releases
                // the unwind is about to emit — one implementation of
                // that rule, and both engines reach it.
                self.runtime.raise(
                    .user_error,
                    registers[arguments[0]].asStr(),
                    self.placeOf(site),
                );
                return .none;
            },
            .optional_wrap, .optional_unwrap => return registers[arguments[0]],
            .own_storage => return self.runtime.ownValue(registers[arguments[0]]),
            .export_storage => return self.runtime.exportValue(registers[arguments[0]]),
            .drop_storage => {
                const held = registers[arguments[0]];
                self.runtime.dropStorage(held);
                return runtime.Runtime.emptied(held);
            },
            // ARC: raise or drop one reference to every object the value
            // names.  The oracle counts exactly as `libluce_rt` does, so
            // both engines agree on when an object is reclaimed.
            .retain => {
                try self.runtime.retainValue(registers[arguments[0]]);
                return .none;
            },
            .release => {
                self.runtime.freeObjectsIn(registers[arguments[0]]);
                return .none;
            },
            .index_get => return containers.indexGet(
                &self.runtime,
                registers[arguments[0]],
                try self.subscripts(site, registers, arguments[1..]),
            ),
            .index_set => {
                const held = registers[arguments[arguments.len - 1]];
                const indices = try self.subscripts(site, registers, arguments[1 .. arguments.len - 1]);
                try containers.indexSet(&self.runtime, registers[arguments[0]], indices, held);
                return .none;
            },
            .list_slice => return containers.listSlice(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
                registers[arguments[2]].asI64(),
            ),
            .append_value => {
                try containers.append(&self.runtime, registers[arguments[0]], registers[arguments[1]]);
                return .none;
            },
            .append_ascii => {
                try containers.appendAscii(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asI64(),
                );
                return .none;
            },
            .pop_value => return containers.pop(&self.runtime, registers[arguments[0]]),
            .insert_value => {
                try containers.insert(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asI64(),
                    registers[arguments[2]],
                );
                return .none;
            },
            .remove_entry => {
                try containers.remove(
                    &self.runtime,
                    registers[arguments[0]],
                    self.storedKey(site, registers[arguments[1]], arguments[1]),
                );
                return .none;
            },
            .has_key => return containers.hasKey(
                &self.runtime,
                registers[arguments[0]],
                self.storedKey(site, registers[arguments[1]], arguments[1]),
            ),
            .key_at => return self.keyOfStored(site, try containers.keyAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
            )),
            .value_at => return containers.valueAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
            ),
            .dim_size => return containers.dimSize(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
            ),
            .copy_object => return containers.copyVerb(&self.runtime, registers[arguments[0]]),
            .list_sort => {
                try containers.sort(&self.runtime, registers[arguments[0]]);
                return .none;
            },
            .list_reverse => {
                try containers.reverse(&self.runtime, registers[arguments[0]]);
                return .none;
            },
            .list_find => return containers.find(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
            ),
            .list_contains => return .ofBoolean(!(try containers.find(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
            )).isNone()),
            .clear_object => {
                try containers.clear(&self.runtime, registers[arguments[0]]);
                return .none;
            },
            .map_keys => return containers.mapKeys(
                &self.runtime,
                registers[arguments[0]],
                try self.zeroValue(self.answeredElement(site)),
            ),
            .map_values => return containers.mapValues(
                &self.runtime,
                registers[arguments[0]],
                try self.zeroValue(self.answeredElement(site)),
            ),
            .map_get => return containers.mapGet(
                &self.runtime,
                registers[arguments[0]],
                self.storedKey(site, registers[arguments[1]], arguments[1]),
            ),
            .map_place => return containers.mapPlace(
                &self.runtime,
                registers[arguments[0]],
                self.storedKey(site, registers[arguments[1]], arguments[1]),
                registers[arguments[2]],
            ),
            .array_fill => {
                try containers.arrayFill(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]],
                );
                return .none;
            },
            .str_value => return text.str(&self.runtime, registers[arguments[0]]),
            .bytes_value => return text.bytes(&self.runtime, registers[arguments[0]]),
            // `str(f)` — the name out of the program's own function
            // table (docs/FUNCTIONS.md D3).  Borrowed, not allocated:
            // the name lives as long as the program does, which is what
            // the compiled path's constant table is too.
            .function_name => {
                const bound = self.boundValue(registers[arguments[0]]) orelse
                    return self.runtime.fail(.null_object);
                return .ofStr(self.program.functions[bound.named].name);
            },
            .parse_i64 => return text.parseI64(&self.runtime, registers[arguments[0]]),
            .parse_f64 => return text.parseF64(&self.runtime, registers[arguments[0]]),
            .parse_str => return text.parseStr(&self.runtime, registers[arguments[0]]),
            .string_slice => return text.slice(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
                registers[arguments[2]].asI64(),
            ),
            .string_byte => return text.byteAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asI64(),
            ),
            .string_find_byte => return text.findByte(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asU8(),
                registers[arguments[2]].asI64(),
            ),
            .assert_true => {
                if (!registers[arguments[0]].asBoolean()) {
                    return self.runtime.fail(.assertion_failed);
                }
                return .none;
            },
            .trap_message => {
                // The borrow ends at this call: `asStr()` of short
                // text points into the register itself, and the frame
                // holding it is about to unwind.  `failMessage` takes
                // the copy that outlives it, for both engines at once.
                return self.runtime.failMessage(
                    .explicit_trap,
                    registers[arguments[0]].asStr(),
                );
            },
            .exit_program => {
                // The host records the number at the site, while the
                // program is still leaving — the same moment the
                // compiled path calls `abi.Host.exited` — then the
                // unwind rides the trap edge with nothing pending.
                const host = try self.service();
                const callback = host.exited orelse return self.runtime.fail(.host_unavailable);
                callback(host.context, registers[arguments[0]].asI64());
                self.runtime.exit_status = registers[arguments[0]].asI64();
                return error.Trap;
            },

            // -- host effects, not semantics --------------------------

            .print => {
                const host = try self.service();
                const callback = host.print orelse return self.runtime.fail(.host_unavailable);
                try callback(host.context, registers[arguments[0]].asStr());
                return .none;
            },
            // The three whole-file text services, over the byte channel
            // (docs/BYTES.md R2).  No host callback of their own any
            // more: they are open-read-close inside `libluce_rt` plus
            // its own UTF-8 validation, so what "not text" means is one
            // decision and both engines reach it.  A file the world
            // would not read is the world deciding, and `file_exists`
            // in front of it is a race — so it is an error, not a trap.
            .file_read => {
                const path = registers[arguments[0]].asStr();
                const found = try files.readText(&self.runtime, path);
                return found orelse blk: {
                    // A value nothing reads: the `errored` in front of
                    // the branch has already seen the channel.
                    self.runtime.raiseIo(.read, path, self.placeOf(site));
                    break :blk .ofStr("");
                };
            },
            .file_write, .file_append => {
                const appending = operation.kind == .file_append;
                const path = registers[arguments[0]].asStr();
                const landed = try files.writeText(
                    &self.runtime,
                    path,
                    registers[arguments[1]].asStr(),
                    if (appending) .append else .write,
                );
                if (!landed) {
                    self.runtime.raiseIo(
                        if (appending) .append else .write,
                        path,
                        self.placeOf(site),
                    );
                }
                return .none;
            },
            .file_delete => {
                const host = try self.service();
                const callback = host.file_delete orelse return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asStr();
                if (!callback(host.context, path)) {
                    self.runtime.raiseIo(.delete, path, self.placeOf(site));
                }
                return .none;
            },
            .file_rename => {
                const host = try self.service();
                const callback = host.file_rename orelse return self.runtime.fail(.host_unavailable);
                const from = registers[arguments[0]].asStr();
                if (!callback(host.context, from, registers[arguments[1]].asStr())) {
                    self.runtime.raiseIo(.rename, from, self.placeOf(site));
                }
                return .none;
            },
            .dir_create => {
                const host = try self.service();
                const callback = host.dir_create orelse
                    return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asStr();
                if (!callback(host.context, path)) {
                    self.runtime.raiseIo(.make, path, self.placeOf(site));
                }
                return .none;
            },
            .dir_list => {
                const host = try self.service();
                const callback = host.dir_list orelse
                    return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asStr();
                const names = (try callback(host.context, self.arena, path)) orelse {
                    // The `errored` in front of the branch has already
                    // seen the channel, so the value nobody reads is
                    // the null handle rather than a live object.
                    self.runtime.raiseIo(.list, path, self.placeOf(site));
                    return .none;
                };
                return containers.listOfText(&self.runtime, names);
            },
            .read_line => {
                const host = try self.service();
                const callback = host.read_line orelse return self.runtime.fail(.host_unavailable);
                const prompt = registers[arguments[0]].asStr();
                // End of input is absence and not failure: there is
                // nothing there, and no reason worth carrying
                // (docs/FAILURE.md).
                const line = (try callback(host.context, self.arena, prompt)) orelse
                    return .none;
                return text.ownHost(&self.runtime, line);
            },
            .print_error => {
                const host = try self.service();
                const callback = host.print_error orelse
                    return self.runtime.fail(.host_unavailable);
                try callback(host.context, registers[arguments[0]].asStr());
                return .none;
            },
            .clock_ms => {
                const host = try self.service();
                const callback = host.clock_ms orelse return self.runtime.fail(.host_unavailable);
                return .ofI64(callback(host.context));
            },
            // A host that cannot tell the time refuses the call, the
            // same way one that cannot measure its machine does —
            // `machineFact` is that refusal, and the wall clock takes
            // it rather than a number nobody could stand behind.
            .epoch_ms => {
                const host = try self.service();
                const callback = host.epoch_ms orelse return self.runtime.fail(.host_unavailable);
                return self.machineFact(callback(host.context));
            },
            .os_total_memory => {
                const host = try self.service();
                const callback = host.os_total_memory orelse
                    return self.runtime.fail(.host_unavailable);
                return self.machineFact(callback(host.context));
            },
            .os_available_memory => {
                const host = try self.service();
                const callback = host.os_available_memory orelse
                    return self.runtime.fail(.host_unavailable);
                return self.machineFact(callback(host.context));
            },
            .os_cpu_count => {
                const host = try self.service();
                const callback = host.os_cpu_count orelse
                    return self.runtime.fail(.host_unavailable);
                return self.machineFact(callback(host.context));
            },
            .sleep_ms => {
                const host = try self.service();
                const callback = host.sleep_ms orelse return self.runtime.fail(.host_unavailable);
                // A duration that has already elapsed is not a bug:
                // `deadline - now` goes negative on a slow frame, and
                // the answer is "no time left to wait".
                callback(host.context, registers[arguments[0]].asI64());
                return .none;
            },
            .env_get => {
                const host = try self.service();
                const callback = host.env orelse return self.runtime.fail(.host_unavailable);
                const name = registers[arguments[0]].asStr();
                const found = (try callback(host.context, self.arena, name)) orelse
                    return .none;
                return text.ownHost(&self.runtime, found);
            },
            .shell_run => {
                const host = try self.service();
                const callback = host.shell_run orelse
                    return self.runtime.fail(.host_unavailable);
                const command = registers[arguments[0]].asStr();
                const output = (try callback(host.context, self.arena, command)) orelse {
                    self.runtime.raiseIo(.run, command, self.placeOf(site));
                    return .ofStr("");
                };
                return text.ownHost(&self.runtime, output);
            },
            .term_event_data => {
                const screen = try self.terminal();
                return .ofI64(screen.event_data(
                    screen.context,
                    registers[arguments[0]].asI64(),
                ));
            },
            .path_kind => {
                const host = try self.service();
                const callback = host.path_kind orelse
                    return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asStr();
                // Null is the world refusing to say, which is a
                // different fact from "nothing is there" and travels
                // in the other channel (docs/FAILURE.md).  The zero
                // left behind is never read: the `errored` beside the
                // call has already seen the error.
                const code = callback(host.context, path) orelse {
                    self.runtime.raiseIo(.inspect, path, self.placeOf(site));
                    return .ofI64(0);
                };
                return .ofI64(code);
            },
            // -- backend-neutral window/GPU channel ------------------
            //
            // The runtime owns native-resource validation and close.  The
            // interpreter only supplies the source site for an ordinary
            // refused operation, keeping the result and error shape equal to
            // the compiled runtime exports.
            .gpu_backend => return .ofI64(try graphics.backend(&self.runtime)),
            .ui_window_open => {
                const title = registers[arguments[0]].asStr();
                const answer = try graphics.openWindow(
                    &self.runtime,
                    title,
                    registers[arguments[1]].asI64(),
                    registers[arguments[2]].asI64(),
                );
                return answer orelse blk: {
                    self.runtime.raiseIo(.open, title, self.placeOf(site));
                    break :blk .none;
                };
            },
            .ui_window_surface => {
                const answer = try graphics.windowSurface(
                    &self.runtime,
                    registers[arguments[0]],
                );
                return answer orelse blk: {
                    self.runtime.raiseIo(.open, "ui.window", self.placeOf(site));
                    break :blk .none;
                };
            },
            .gpu_surface_size => {
                const answer = try graphics.size(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asI64(),
                );
                return .ofI64(answer orelse blk: {
                    self.runtime.raiseIo(.inspect, "gpu.surface", self.placeOf(site));
                    break :blk 0;
                });
            },
            .gpu_surface_clear => {
                const answered = try graphics.clear(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asI64(),
                    registers[arguments[2]].asI64(),
                    registers[arguments[3]].asI64(),
                    registers[arguments[4]].asI64(),
                );
                if (!answered) self.runtime.raiseIo(.write, "gpu.surface", self.placeOf(site));
                return .none;
            },
            .gpu_surface_fill_rect => {
                const answered = try graphics.fillRect(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asI64(),
                    registers[arguments[2]].asI64(),
                    registers[arguments[3]].asI64(),
                    registers[arguments[4]].asI64(),
                    registers[arguments[5]].asI64(),
                    registers[arguments[6]].asI64(),
                    registers[arguments[7]].asI64(),
                    registers[arguments[8]].asI64(),
                );
                if (!answered) self.runtime.raiseIo(.write, "gpu.surface", self.placeOf(site));
                return .none;
            },
            .gpu_surface_present => {
                const answered = try graphics.present(&self.runtime, registers[arguments[0]]);
                if (!answered) self.runtime.raiseIo(.flush, "gpu.surface", self.placeOf(site));
                return .none;
            },
            .term_rows => {
                const screen = try self.terminal();
                return .ofI64(screen.term_rows(screen.context));
            },
            .term_cols => {
                const screen = try self.terminal();
                return .ofI64(screen.term_cols(screen.context));
            },
            .term_clear => {
                const screen = try self.terminal();
                try screen.term_clear(screen.context);
                return .none;
            },
            .term_move => {
                const screen = try self.terminal();
                try screen.term_move(
                    screen.context,
                    registers[arguments[0]].asI64(),
                    registers[arguments[1]].asI64(),
                );
                return .none;
            },
            .term_style => {
                const screen = try self.terminal();
                try screen.term_style(
                    screen.context,
                    registers[arguments[0]].asI64(),
                    registers[arguments[1]].asI64(),
                    registers[arguments[2]].asBoolean(),
                );
                return .none;
            },
            .term_write => {
                const screen = try self.terminal();
                try screen.term_write(screen.context, registers[arguments[0]].asStr());
                return .none;
            },
            .term_copy => {
                const screen = try self.terminal();
                try screen.term_copy(screen.context, registers[arguments[0]].asStr());
                return .none;
            },
            .term_flush => {
                const screen = try self.terminal();
                try screen.term_flush(screen.context);
                return .none;
            },
            .key_read => {
                const screen = try self.terminal();
                // A keyboard that has run dry answers `none`, and the
                // payload goes back to empty with it: `key_text()`
                // after the end of input must not still be holding the
                // last key's text.  The compiled path clears the same
                // two out-parameters for the same reason.
                const event = try screen.key_read(screen.context, self.arena) orelse {
                    try self.runtime.setKeyText("");
                    return .none;
                };
                try text.requireHost(&self.runtime, event.text);
                try self.runtime.setKeyText(event.text);
                return text.ownHost(&self.runtime, event.name);
            },
            .key_text => return .ofStr(self.runtime.last_key_text),

            // -- the byte channel (docs/BYTES.md) ---------------------
            //
            // No `host` lookup and no callback of this file's own:
            // `libluce_rt` holds the five slots and every semantic
            // below is written there, so the oracle decodes the
            // instruction and calls the same body a compiled artifact
            // calls.  All four raise `io_failed` where the world said
            // no, with the path the handle remembers.
            .file_open => {
                const path = registers[arguments[0]].asStr();
                const opened = try files.open(
                    &self.runtime,
                    path,
                    registers[arguments[1]].asI64(),
                );
                return opened orelse blk: {
                    self.runtime.raiseIo(.open, path, self.placeOf(site));
                    break :blk .none;
                };
            },
            .socket_connect => {
                const host = registers[arguments[0]].asStr();
                const opened = try sockets.connect(
                    &self.runtime,
                    host,
                    registers[arguments[1]].asI64(),
                );
                return opened orelse blk: {
                    self.runtime.raiseIo(.connect, host, self.placeOf(site));
                    break :blk .none;
                };
            },
            .socket_listen => {
                const port = registers[arguments[0]].asI64();
                const opened = try sockets.listen(&self.runtime, port);
                return opened orelse blk: {
                    var label: [24]u8 = undefined;
                    const named = std.fmt.bufPrint(&label, ":{d}", .{port}) catch ":?";
                    self.runtime.raiseIo(.listen, named, self.placeOf(site));
                    break :blk .none;
                };
            },
            .socket_accept => {
                const held = registers[arguments[0]];
                const accepted = try sockets.accept(&self.runtime, held);
                return accepted orelse blk: {
                    self.runtime.raiseIo(
                        .accept,
                        files.pathOf(&self.runtime, held),
                        self.placeOf(site),
                    );
                    break :blk .none;
                };
            },
            .socket_port => {
                const held = registers[arguments[0]];
                const port = try sockets.portOf(&self.runtime, held);
                return .ofI64(port orelse blk: {
                    self.runtime.raiseIo(
                        .ask,
                        files.pathOf(&self.runtime, held),
                        self.placeOf(site),
                    );
                    break :blk 0;
                });
            },
            .handle_read => {
                const held = registers[arguments[0]];
                const filled = try files.read(&self.runtime, held, registers[arguments[1]]);
                return .ofI64(filled orelse blk: {
                    self.runtime.raiseIo(
                        .read,
                        files.pathOf(&self.runtime, held),
                        self.placeOf(site),
                    );
                    break :blk 0;
                });
            },
            .handle_write => {
                const held = registers[arguments[0]];
                const written = try files.write(
                    &self.runtime,
                    held,
                    registers[arguments[1]],
                    registers[arguments[2]].asI64(),
                );
                return .ofI64(written orelse blk: {
                    self.runtime.raiseIo(
                        .write,
                        files.pathOf(&self.runtime, held),
                        self.placeOf(site),
                    );
                    break :blk 0;
                });
            },
            // `t.wait()` — join the worker and take its answer
            // (docs/THREADS.md D4, D6).  One implementation, shared
            // with the compiled path: a trap comes back as
            // `error.Trap` with the worker's frames already recorded,
            // and a raised error lands in this runtime's channel for
            // the `errored` beside the call to read.
            .task_wait => {
                var answered: RuntimeValue = .none;
                _ = try runtime.workers.wait(&self.runtime, registers[arguments[0]], &answered);
                return answered;
            },
            .handle_flush => {
                const held = registers[arguments[0]];
                if (!try files.flush(&self.runtime, held)) {
                    self.runtime.raiseIo(
                        .flush,
                        files.pathOf(&self.runtime, held),
                        self.placeOf(site),
                    );
                }
                return .none;
            },
        }
    }

    /// The subscripts of one indexing operation, gathered out of the
    /// registers into reused scratch.  An array carries one per axis;
    /// a list or map carries exactly one.
    ///
    /// Each goes through `storedKey`, which is the identity for every
    /// subscript that is not an enum map key.
    fn subscripts(
        self: *Machine,
        site: Site,
        registers: []const RuntimeValue,
        of: []const Register,
    ) error{OutOfMemory}![]const RuntimeValue {
        self.index_scratch.clearRetainingCapacity();
        try self.index_scratch.ensureTotalCapacity(self.arena, of.len);
        for (of) |register| self.index_scratch.appendAssumeCapacity(
            self.storedKey(site, registers[register], register),
        );
        return self.index_scratch.items;
    }
};

// ---------------------------------------------------------------------------
// Values a slot starts life with, and who may end one
// ---------------------------------------------------------------------------

/// What a slot that owns its storage holds before anything is stored
/// in it: the type's tag and no storage, so the release it will get
/// frees nothing.  Deliberately not `zeroValue`, whose struct answer is
/// one template shared by every slot of that layout.
fn emptyValue(of: types.Type) RuntimeValue {
    return switch (of) {
        .str => .ofStr(""),
        .bytes => .ofBytes(""),
        // A union value's run empties exactly as a struct's does
        // (docs/UNION.md D8): the same tag and no run, which a
        // release walks past.
        .strukt, .variant => .{ .tag = .strukt },
        .optional => .none,
        else => .none,
    };
}

test "the constant prologue materializes every flat shape with declaration identity" {
    const testing = std.testing;
    const long_label = "a label whose bytes must belong to the constant container";
    const long_key = "a map key whose bytes must belong to the constant container";

    var fields = [_]types.StructField{
        .{ .name = "enabled", .field_type = .boolean },
        .{ .name = "count", .field_type = .i32 },
        .{ .name = "ratio", .field_type = .f32 },
        .{ .name = "label", .field_type = .str },
        .{ .name = "missing", .field_type = .{ .optional = .str } },
    };
    var layouts = [_]types.StructLayout{.{ .name = "Entry", .fields = &fields }};
    var heaps = [_]types.HeapType{
        .{ .list = .{ .strukt = 0 } },
        .{ .array = .{ .element = .u8, .rank = 1 } },
        .{ .map = .{ .key = .str, .value = .f64 } },
    };
    const strings = [_][]const u8{ long_label, long_key };
    var encoded_fields = [_]mir.ConstantValue{
        .{ .boolean = true },
        .{ .integer = 7 },
        .{ .float = 1.5 },
        .{ .str = 0 },
        .absent,
    };
    var list_values = [_]mir.ConstantValue{.{ .strukt = .{
        .layout = 0,
        .fields = &encoded_fields,
    } }};
    var byte_values = [_]mir.ConstantValue{ .{ .integer = 1 }, .{ .integer = 255 } };
    var map_entries = [_]mir.ContainerConstant.MapEntry{.{
        .key = .{ .str = 1 },
        .value = .{ .float = 2.5 },
    }};
    var constants = [_]mir.ContainerConstant{
        .{
            .name = "entries",
            .heap = 0,
            .payload = .{ .sequence = &list_values },
            .source = "tables.luc",
            .origin = .{ .line = 3, .column = 1 },
        },
        .{
            .name = "bytes",
            .heap = 1,
            .payload = .{ .sequence = &byte_values },
            .source = "tables.luc",
            .origin = .{ .line = 7, .column = 1 },
        },
        .{
            .name = "weights",
            .heap = 2,
            .payload = .{ .map = &map_entries },
            .source = "tables.luc",
            .origin = .{ .line = 11, .column = 1 },
        },
        .{
            .name = "same_entries",
            .heap = 0,
            .payload = .{ .sequence = &list_values },
            .source = "tables.luc",
            .origin = .{ .line = 15, .column = 1 },
        },
    };

    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.structs = &layouts;
    program.heap_types = &heaps;
    program.constants = &strings;
    program.container_constants = &constants;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var machine: Machine = .{
        .arena = arena.allocator(),
        .runtime = .init(.{ .arena = arena.allocator(), .objects = testing.allocator }),
        .program = &program,
        .max_depth = 1,
        .host = null,
    };
    defer machine.runtime.deinit();

    try testing.expect(machine.materializeConstants() == null);
    try testing.expectEqual(@as(i64, 0), machine.runtime.leaked());

    const entries = machine.runtime.constant(0);
    const record = try containers.indexGet(&machine.runtime, entries, &.{RuntimeValue.ofI64(0)});
    const stored = record.asStruct();
    try testing.expect(stored[0].asBoolean());
    try testing.expectEqual(@as(i32, 7), stored[1].asI32());
    try testing.expectEqual(@as(f32, 1.5), stored[2].asF32());
    try testing.expectEqualStrings(long_label, stored[3].asStr());
    try testing.expect(stored[4].isNone());

    const bytes = machine.runtime.constant(1);
    const last = try containers.indexGet(&machine.runtime, bytes, &.{RuntimeValue.ofI64(1)});
    try testing.expectEqual(@as(u8, 255), last.asU8());

    const weights = machine.runtime.constant(2);
    const weight = try containers.indexGet(
        &machine.runtime,
        weights,
        &.{RuntimeValue.ofStr(long_key)},
    );
    try testing.expectEqual(@as(f64, 2.5), weight.asF64());

    const same_entries = machine.runtime.constant(3);
    try testing.expect(!entries.asObject().same(same_entries.asObject()));
    try testing.expect((try machine.runtime.resolve(entries)).constant);
    try testing.expect((try machine.runtime.resolve(bytes)).constant);
    try testing.expect((try machine.runtime.resolve(weights)).constant);
}

test "const_container loads the runtime root and mutation reaches the immutable backstop" {
    const testing = std.testing;
    var values = [_]mir.ConstantValue{.{ .integer = 1 }};
    var constants = [_]mir.ContainerConstant{.{
        .name = "numbers",
        .heap = 0,
        .payload = .{ .sequence = &values },
        .source = "numbers.luc",
        .origin = .{ .line = 1, .column = 1 },
    }};
    var heaps = [_]types.HeapType{.{ .list = .i64 }};
    var append_arguments = [_]Register{ 0, 1 };
    var instructions = [_]mir.Instruction{
        .{ .const_container = 0 },
        .{ .const_integer = 2 },
        .{ .intrinsic = .{ .kind = .append_value, .arguments = &append_arguments } },
        .{ .ret = null },
    };
    var result_types = [_]types.Type{ .{ .heap = 0 }, .i64, .none, .none };
    var items = [_]Register{ 0, 1, 2, 3 };
    var blocks = [_]mir.Block{.{ .items = &items }};
    var functions = [_]mir.Function{.{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = &instructions,
        .result_types = &result_types,
        .blocks = &blocks,
    }};

    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.heap_types = &heaps;
    program.functions = &functions;
    program.container_constants = &constants;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var machine: Machine = .{
        .arena = arena.allocator(),
        .runtime = .init(.{ .arena = arena.allocator(), .objects = testing.allocator }),
        .program = &program,
        .max_depth = 4,
        .host = null,
    };
    defer machine.runtime.deinit();

    const outcome = try machine.execute(0);
    try testing.expectEqual(mir.TrapCode.immutable_object, outcome.trap.code);
    try testing.expectEqual(@as(i64, 1), (try containers.length(
        &machine.runtime,
        machine.runtime.constant(0),
    )).asI64());
    try testing.expectEqual(@as(i64, 0), machine.runtime.leaked());
}

test "each interpreter worker materializes constants in its own runtime" {
    const testing = std.testing;
    var values = [_]mir.ConstantValue{ .{ .integer = 4 }, .{ .integer = 8 } };
    var constants = [_]mir.ContainerConstant{.{
        .name = "numbers",
        .heap = 0,
        .payload = .{ .sequence = &values },
        .source = "worker.luc",
        .origin = .{ .line = 2, .column = 1 },
    }};
    var heaps = [_]types.HeapType{.{ .list = .i64 }};
    var len_arguments = [_]Register{0};
    var instructions = [_]mir.Instruction{
        .{ .const_container = 0 },
        .{ .intrinsic = .{ .kind = .len, .arguments = &len_arguments } },
        .{ .ret = 1 },
    };
    var result_types = [_]types.Type{ .{ .heap = 0 }, .i64, .none };
    var items = [_]Register{ 0, 1, 2 };
    var blocks = [_]mir.Block{.{ .items = &items }};
    var functions = [_]mir.Function{.{
        .name = "measure",
        .parameter_count = 0,
        .return_type = .i64,
        .locals = &.{},
        .instructions = &instructions,
        .result_types = &result_types,
        .blocks = &blocks,
    }};

    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.heap_types = &heaps;
    program.functions = &functions;
    program.container_constants = &constants;

    var nursery: Nursery = .{ .program = &program, .host = null, .base = testing.allocator };
    const first = Nursery.open(&nursery).?;
    defer Nursery.close(&nursery, first);
    const second = Nursery.open(&nursery).?;
    defer Nursery.close(&nursery, second);
    const no_arguments = [_]RuntimeValue{.none};
    var first_answer: RuntimeValue = .none;
    var second_answer: RuntimeValue = .none;
    try testing.expectEqual(
        runtime.workers.survived,
        Nursery.runWorker(&nursery, first, 0, &no_arguments, 0, &first_answer, 8),
    );
    try testing.expectEqual(
        runtime.workers.survived,
        Nursery.runWorker(&nursery, second, 0, &no_arguments, 0, &second_answer, 8),
    );
    try testing.expectEqual(@as(i64, 2), first_answer.asI64());
    try testing.expectEqual(@as(i64, 2), second_answer.asI64());
    try testing.expectEqual(@as(i64, 0), first.leaked());
    try testing.expectEqual(@as(i64, 0), second.leaked());
    try testing.expect(
        (try first.resolve(first.constant(0))) != (try second.resolve(second.constant(0))),
    );
}

test "an interpreter worker marks arena exhaustion before it returns" {
    const testing = std.testing;
    var instructions = [_]mir.Instruction{
        .{ .const_integer = 7 },
        .{ .ret = 0 },
    };
    var result_types = [_]types.Type{ .i64, .i64 };
    var items = [_]Register{ 0, 1 };
    var blocks = [_]mir.Block{.{ .items = &items }};
    var functions = [_]mir.Function{.{
        .name = "worker",
        .parameter_count = 0,
        .return_type = .i64,
        .locals = &.{},
        .instructions = &instructions,
        .result_types = &result_types,
        .blocks = &blocks,
    }};

    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.functions = &functions;

    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var nursery: Nursery = .{ .program = &program, .host = null, .base = objects.allocator() };
    const worker = Nursery.open(&nursery) orelse return error.OutOfMemory;
    var answer: RuntimeValue = .none;
    try testing.expectEqual(
        runtime.workers.raised_trap,
        Nursery.runWorker(&nursery, worker, 0, &.{}, 0, &answer, 8),
    );
    try testing.expect(worker.exhausted);
    Nursery.close(&nursery, worker);
    try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
}

test "an interpreter worker rejects malformed entry inputs" {
    const testing = std.testing;
    var instructions = [_]mir.Instruction{
        .{ .const_integer = 7 },
        .{ .ret = 0 },
    };
    var result_types = [_]types.Type{ .i64, .i64 };
    var items = [_]Register{ 0, 1 };
    var blocks = [_]mir.Block{.{ .items = &items }};
    var functions = [_]mir.Function{.{
        .name = "worker",
        .parameter_count = 0,
        .return_type = .i64,
        .locals = &.{},
        .instructions = &instructions,
        .result_types = &result_types,
        .blocks = &blocks,
    }};

    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.functions = &functions;

    var nursery: Nursery = .{ .program = &program, .host = null, .base = testing.allocator };
    const worker = Nursery.open(&nursery).?;
    defer Nursery.close(&nursery, worker);
    var answer: RuntimeValue = RuntimeValue.none;

    try testing.expectEqual(
        runtime.workers.raised_trap,
        Nursery.runWorker(&nursery, worker, -1, &.{}, 0, &answer, 8),
    );
    try testing.expectEqual(mir.TrapCode.host_unavailable, worker.pending.?.code);
    worker.pending = null;
    try testing.expectEqual(
        runtime.workers.raised_trap,
        Nursery.runWorker(&nursery, worker, 99, &.{}, 0, &answer, 8),
    );
    try testing.expectEqual(mir.TrapCode.host_unavailable, worker.pending.?.code);
    worker.pending = null;
    try testing.expectEqual(
        runtime.workers.raised_trap,
        Nursery.runWorker(&nursery, worker, 0, &.{}, -1, &answer, 8),
    );
    try testing.expectEqual(mir.TrapCode.host_unavailable, worker.pending.?.code);
    worker.pending = null;
    try testing.expectEqual(
        runtime.workers.raised_trap,
        Nursery.runWorker(&nursery, worker, 0, &.{}, 0, &answer, -1),
    );
    try testing.expectEqual(mir.TrapCode.host_unavailable, worker.pending.?.code);
    worker.pending = null;
    try testing.expectEqual(@as(i64, 0), worker.leaked());
}

test "a failed constant prologue cleans partial roots and reports the declaration" {
    const testing = std.testing;
    const long_text = "materialization owns these bytes, and cleanup must return every one";
    const strings = [_][]const u8{long_text};
    var values = [_]mir.ConstantValue{.{ .str = 0 }};
    var constants = [_]mir.ContainerConstant{
        .{
            .name = "first",
            .heap = 0,
            .payload = .{ .sequence = &values },
            .source = "failure.luc",
            .origin = .{ .line = 4, .column = 1 },
        },
        .{
            .name = "second",
            .heap = 0,
            .payload = .{ .sequence = &values },
            .source = "failure.luc",
            .origin = .{ .line = 9, .column = 1 },
        },
    };
    var heaps = [_]types.HeapType{.{ .list = .str }};
    var program: mir.Program = .{ .arena = .init(testing.allocator) };
    defer program.deinit();
    program.heap_types = &heaps;
    program.constants = &strings;
    program.container_constants = &constants;

    var saw_second = false;
    for (0..12) |fail_at| {
        var objects: std.testing.FailingAllocator = .init(testing.allocator, .{});
        objects.fail_index = fail_at;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        var machine: Machine = .{
            .arena = arena.allocator(),
            .runtime = .init(.{ .arena = arena.allocator(), .objects = objects.allocator() }),
            .program = &program,
            .max_depth = 1,
            .host = null,
        };

        if (machine.materializeConstants()) |failed| {
            try testing.expectEqual(mir.TrapCode.allocation_failed, failed.trap.code);
            try testing.expectEqual(@as(i64, 0), machine.runtime.leaked());
            // A second begin succeeds only if the failed prologue gave
            // back both its root table and its materializing state.
            try machine.runtime.beginConstants(0);
            machine.runtime.finishConstants();

            var reported = failed.trap;
            try machine.traceback(&reported);
            try testing.expectEqual(@as(usize, 1), reported.trace.len);
            try testing.expectEqualStrings("failure.luc", reported.trace[0].source);
            const name = reported.trace[0].function;
            if (std.mem.eql(u8, name, "second")) {
                saw_second = true;
                try testing.expectEqual(@as(u32, 9), reported.trace[0].line);
                try testing.expectEqual(@as(u32, 1), reported.trace[0].column);
            }
        }

        machine.runtime.deinit();
        arena.deinit();
        try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
    }
    try testing.expect(saw_second);

    // The public run boundary carries the same declaration-shaped
    // frame, rather than replacing a pre-main failure with `main`.
    var objects: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    const result = try run(
        .{ .arena = arena.allocator(), .objects = objects.allocator() },
        &program,
        .{},
        null,
    );
    try testing.expectEqual(mir.TrapCode.allocation_failed, result.trap.code);
    try testing.expectEqual(@as(usize, 1), result.trap.trace.len);
    try testing.expectEqualStrings("first", result.trap.trace[0].function);
    try testing.expectEqualStrings("failure.luc", result.trap.trace[0].source);
    try testing.expectEqual(@as(u32, 4), result.trap.trace[0].line);
    arena.deinit();
    try testing.expectEqual(objects.allocated_bytes, objects.freed_bytes);
}
