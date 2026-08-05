//! The Luce IR interpreter machine — the differential oracle's engine
//! (`../interpreter.zig`).
//!
//! Deterministic and safe: checked integer arithmetic, explicit
//! conversion range checks, and a call-depth limit.  All temporary
//! storage comes from the evaluation arena; the interpreter itself
//! allocates nothing that outlives one evaluation.
//!
//! What is *not* here is the point of the file.  Every semantic below
//! the instruction level — the object heap, scope ownership, the
//! containers, string storage, the conversions, checked arithmetic —
//! lives in `libluce_rt` (`../runtime.zig`), and this file only decodes
//! instructions and calls it.  There is one implementation of each
//! semantic and compiled code reaches the same one (docs/CODEGEN.md);
//! a second copy here would be a second place for the same bug.

const std = @import("std");
const mir = @import("../06_mir.zig");
const interpreter = @import("../interpreter.zig");
const runtime = @import("../runtime.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const RuntimeValue = runtime.Value;
const Result = interpreter.Result;
const Budget = interpreter.Budget;

const containers = runtime.containers;
const operators = runtime.operators;
const text = runtime.text;

// ---------------------------------------------------------------------------
// Running a program
// ---------------------------------------------------------------------------

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
    // Object storage is a real allocator now, so the run has to hand
    // it back: scope ownership frees what the program finished with,
    // and this frees what a trap unwound past or a leak left behind
    // (S34).  The result is built first — it carries the census and a
    // trap's words, which live in the arena, not here.
    defer machine.runtime.deinit();
    switch (try machine.execute(program.entry_function)) {
        .value => return .{ .success = .{
            .leaked_objects = machine.runtime.live,
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
            return .{ .trap = reported };
        },
    }
}

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
    /// Unique per call; minted by the runtime so ownership bindings
    /// from two frames of the same function never collide.
    serial: u64 = 0,
};

const Register = mir.Register;

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
            error.Trap => .{ .trap = .{
                .code = self.runtime.pending.?.code,
                .message = self.runtime.pending.?.message,
            } },
        };
    }

    /// Fill a trap's stack trace from the live frame stack, innermost
    /// first.  Each frame's current instruction resolves through the
    /// function's origins table when the module carries one (debug);
    /// a stripped module still names the function, with line 0.
    fn traceback(self: *Machine, reported: *interpreter.Trap) error{OutOfMemory}!void {
        const depth = self.stack.items.len;
        const kept = @min(depth, max_trace_frames);
        const frames = try self.arena.alloc(interpreter.TraceFrame, kept);
        for (frames, 0..) |*slot, out_index| {
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
        reported.dropped = @intCast(depth - kept);
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
        const locals = self.frame_storage.items[frame.slots_at + frame.register_count ..];
        for (function.locals, 0..) |local, index| {
            if (!local.owns_storage) continue;
            self.runtime.dropStorage(locals[index]);
            locals[index] = runtime.Runtime.emptied(locals[index]);
        }
    }

    /// The same, for every frame a trap left standing.
    fn releaseFrameStorage(self: *Machine) void {
        for (self.stack.items) |frame| self.releaseSlots(frame);
    }

    fn service(self: *Machine) EvalError!interpreter.Host {
        return self.host orelse return self.runtime.fail(.host_unavailable);
    }

    /// The `list(string)` `main`'s parameter receives (OWNERSHIP.md
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

    fn pushFrame(
        self: *Machine,
        function_index: u32,
        arguments: []const RuntimeValue,
        destination: Register,
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
        @memcpy(locals[0..arguments.len], arguments);
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
        for (locals[arguments.len..], function.locals[arguments.len..]) |*slot, local| {
            // A slot that owns its storage starts *empty* rather than
            // at the shared zero: the zero template is one value per
            // layout, and the release this slot will get must never
            // hand a shared run back (docs/STRINGS.md).
            slot.* = if (local.owns_storage)
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
            .serial = self.runtime.takeSerial(),
        });
        return null;
    }

    // -- the dispatch loop ----------------------------------------------

    pub fn execute(self: *Machine, entry: u32) error{OutOfMemory}!CallOutcome {
        // `func main(args: list(string)):` receives the command line;
        // `func main():` receives nothing, and those are the only two
        // shapes stage 4 lets through (docs/METHODS.md).  The list is
        // built the same way the compiled arm builds it — `libluce_rt`
        // owns the semantic and each engine hands it what its own host
        // spells the arguments in (OWNERSHIP.md S44).
        var received: [1]RuntimeValue = .{.none};
        var arguments: []const RuntimeValue = &.{};
        if (self.program.functions[entry].parameter_count == 1) {
            received[0] = self.commandLine() catch |mistake| return self.caught(mistake);
            arguments = &received;
        }
        if (try self.pushFrame(entry, arguments, 0)) |failed| return failed;

        dispatch: while (true) {
            // Re-derived every time round the dispatch loop: pushing a
            // frame may reallocate the storage, and every path that
            // pushes one continues here rather than reusing these.
            const frame = &self.stack.items[self.stack.items.len - 1];
            const function = &self.program.functions[frame.function];
            const slots = self.frame_storage.items[frame.slots_at..];
            const registers = slots[0..frame.register_count];
            const locals = slots[frame.register_count..][0..frame.local_count];
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
                    .const_long => |value| registers[item] = if (function.result_types[item] == .int)
                        .ofInt(@intCast(value))
                    else
                        .ofLong(value),
                    .const_double => |value| registers[item] = if (function.result_types[item] == .float)
                        .ofFloat(@floatCast(value))
                    else
                        .ofDouble(value),
                    .const_string => |constant| {
                        registers[item] = .ofString(self.program.constants[constant]);
                    },
                    .local_get => |local| registers[item] = locals[local],
                    .local_set => |set| locals[set.local] = registers[set.value],
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
                    .struct_make => |make| {
                        self.field_scratch.clearRetainingCapacity();
                        try self.field_scratch.ensureTotalCapacity(self.arena, make.fields.len);
                        for (make.fields) |field_register| {
                            self.field_scratch.appendAssumeCapacity(registers[field_register]);
                        }
                        registers[item] = self.runtime.makeStruct(self.field_scratch.items) catch |mistake|
                            return self.caught(mistake);
                    },
                    .struct_get => |get| {
                        registers[item] = registers[get.target].asStruct()[get.field];
                    },
                    .struct_set => |set| {
                        registers[item] = self.runtime.setField(
                            registers[set.target],
                            set.field,
                            registers[set.value],
                        ) catch |mistake| return self.caught(mistake);
                    },
                    .heap_new => |new| {
                        registers[item] = self.allocateObject(new, registers) catch |mistake|
                            return self.caught(mistake);
                    },
                    .object_bind => |bind| {
                        self.runtime.bind(registers[bind.value], frame.serial, bind.local);
                    },
                    .object_unbind => |unbind| {
                        self.runtime.unbind(registers[unbind.value], frame.serial, unbind.local);
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
                        if (try self.pushFrame(called.function, self.argument_scratch.items, item)) |failed| {
                            return failed;
                        }
                        continue :dispatch;
                    },
                    .intrinsic => |operation| {
                        registers[item] = self.intrinsic(
                            operation,
                            registers,
                            frame.serial,
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
                        // Whatever the finished frame still owned in
                        // the returned value moves to the caller
                        // (S16): loose until something there binds it.
                        self.runtime.loosenFromFrame(returned, finished.serial);
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
                        continue :dispatch;
                    },
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

    /// `new list(T)` / `new map(K, V)` / `new array(T, ...)` / `new
    /// builder`: read the shape from the program's heap-type table and
    /// ask the runtime for the object.
    pub fn allocateObject(
        self: *Machine,
        new: mir.Instruction.HeapNew,
        registers: []const RuntimeValue,
    ) EvalError!RuntimeValue {
        switch (self.program.heap_types[new.heap]) {
            .list => return self.runtime.newList(),
            .map => return self.runtime.newMap(),
            .builder => return self.runtime.newBuilder(),
            .array => |shape| {
                self.dims_scratch.clearRetainingCapacity();
                try self.dims_scratch.ensureTotalCapacity(self.arena, new.dims.len);
                for (new.dims) |register| {
                    self.dims_scratch.appendAssumeCapacity(registers[register].asLong());
                }
                return self.runtime.newArray(
                    self.dims_scratch.items,
                    try self.zeroValue(shape.element),
                );
            },
        }
    }

    /// The zero value a fresh local or array element carries, per type.
    pub fn zeroValue(self: *Machine, of: types.Type) error{OutOfMemory}!RuntimeValue {
        return switch (of) {
            .none => .none,
            .boolean => .ofBoolean(false),
            .int => .ofInt(0),
            .long => .ofLong(0),
            .float => .ofFloat(0.0),
            .double => .ofDouble(0.0),
            .string => .ofString(""),
            .heap => .null_object,
            // The zero of a `T?` is absence, which owns nothing (S43).
            .optional => .none,
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
                const fields = try self.arena.alloc(RuntimeValue, layout.fields.len);
                for (layout.fields, fields) |field, *slot| {
                    slot.* = try self.zeroValue(field.field_type);
                }
                const zero: RuntimeValue = .ofStruct(fields);
                self.struct_zeros[layout_index] = zero;
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

    pub fn intrinsic(
        self: *Machine,
        operation: mir.Instruction.IntrinsicCall,
        registers: []const RuntimeValue,
        serial: u64,
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
            .compare_long_double => return .ofBoolean(operators.compareLongDouble(
                @enumFromInt(registers[arguments[0]].asLong()),
                registers[arguments[1]].asLong(),
                registers[arguments[2]].asDouble(),
            )),
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
                    registers[arguments[0]].asString(),
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
            .index_get => return containers.indexGet(
                &self.runtime,
                registers[arguments[0]],
                try self.subscripts(registers, arguments[1..]),
            ),
            .index_set => {
                const held = registers[arguments[arguments.len - 1]];
                const indices = try self.subscripts(registers, arguments[1 .. arguments.len - 1]);
                try containers.indexSet(&self.runtime, registers[arguments[0]], indices, held);
                return .none;
            },
            .list_slice => return containers.listSlice(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
                registers[arguments[2]].asLong(),
            ),
            .append_value => {
                try containers.append(&self.runtime, registers[arguments[0]], registers[arguments[1]]);
                return .none;
            },
            .append_ascii => {
                try containers.appendAscii(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asLong(),
                );
                return .none;
            },
            .pop_value => return containers.pop(&self.runtime, registers[arguments[0]]),
            .insert_value => {
                try containers.insert(
                    &self.runtime,
                    registers[arguments[0]],
                    registers[arguments[1]].asLong(),
                    registers[arguments[2]],
                );
                return .none;
            },
            .remove_entry => {
                try containers.remove(&self.runtime, registers[arguments[0]], registers[arguments[1]]);
                return .none;
            },
            .has_key => return containers.hasKey(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
            ),
            .key_at => return containers.keyAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
            ),
            .value_at => return containers.valueAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
            ),
            .dim_size => return containers.dimSize(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
            ),
            .free_object => {
                try containers.freeVerb(
                    &self.runtime,
                    registers[arguments[0]],
                    namedBinding(registers, arguments, serial),
                );
                return .none;
            },
            .give_object => return containers.giveVerb(
                &self.runtime,
                registers[arguments[0]],
                namedBinding(registers, arguments, serial),
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
            .list_find => return .ofLong(try containers.find(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
            )),
            .list_contains => return .ofBoolean(try containers.find(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
            ) != -1),
            .clear_object => {
                try containers.clear(&self.runtime, registers[arguments[0]]);
                return .none;
            },
            .map_keys => return containers.mapKeys(&self.runtime, registers[arguments[0]]),
            .map_values => return containers.mapValues(&self.runtime, registers[arguments[0]]),
            .map_get => return containers.mapGet(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]],
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
            .parse_int => return text.parseInt(&self.runtime, registers[arguments[0]]),
            .parse_float => return text.parseFloat(&self.runtime, registers[arguments[0]]),
            .chr_code => return text.chr(&self.runtime, registers[arguments[0]].asLong()),
            .ord_text => return text.ord(&self.runtime, registers[arguments[0]]),
            .string_slice => return text.slice(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
                registers[arguments[2]].asLong(),
            ),
            .string_byte => return text.byteAt(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
            ),
            .string_find_byte => return text.findByte(
                &self.runtime,
                registers[arguments[0]],
                registers[arguments[1]].asLong(),
                registers[arguments[2]].asLong(),
            ),
            .assert_true => {
                if (!registers[arguments[0]].asBoolean()) {
                    return self.runtime.fail(.assertion_failed);
                }
                return .none;
            },
            .trap_message => {
                // The words outlive every release the unwind skips
                // and are read once the run has stopped, so they go
                // in the arena rather than in owned storage.
                const words = try self.arena.dupe(u8, registers[arguments[0]].asString());
                return self.runtime.failMessage(.explicit_trap, words);
            },

            // -- host effects, not semantics --------------------------

            .print => {
                const host = try self.service();
                const callback = host.print orelse return self.runtime.fail(.host_unavailable);
                try callback(host.context, registers[arguments[0]].asString());
                return .none;
            },
            .file_read => {
                const host = try self.service();
                const callback = host.file_read orelse return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asString();
                return switch (try callback(host.context, self.arena, path)) {
                    // The host allocates from the arena, which cannot
                    // give a slice back; the program keeps an owned
                    // copy and the arena's is scratch.
                    .content => |content| try self.runtime.ownValue(.ofString(content)),
                    // A file that would not read is the world
                    // deciding, and `file_exists` before it is a race
                    // — so it is an error, not a trap.  The answer is
                    // a value nothing reads: the `errored` in front of
                    // the branch has already seen the channel.
                    .failed => blk: {
                        self.runtime.raiseIo(.read, path, self.placeOf(site));
                        break :blk .ofString("");
                    },
                };
            },
            .file_write => {
                const host = try self.service();
                const callback = host.file_write orelse return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asString();
                if (!callback(host.context, path, registers[arguments[1]].asString())) {
                    self.runtime.raiseIo(.write, path, self.placeOf(site));
                }
                return .none;
            },
            .file_append => {
                const host = try self.service();
                const callback = host.file_append orelse return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asString();
                if (!callback(host.context, path, registers[arguments[1]].asString())) {
                    self.runtime.raiseIo(.append, path, self.placeOf(site));
                }
                return .none;
            },
            .file_delete => {
                const host = try self.service();
                const callback = host.file_delete orelse return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asString();
                if (!callback(host.context, path)) {
                    self.runtime.raiseIo(.delete, path, self.placeOf(site));
                }
                return .none;
            },
            .file_rename => {
                const host = try self.service();
                const callback = host.file_rename orelse return self.runtime.fail(.host_unavailable);
                const from = registers[arguments[0]].asString();
                if (!callback(host.context, from, registers[arguments[1]].asString())) {
                    self.runtime.raiseIo(.rename, from, self.placeOf(site));
                }
                return .none;
            },
            .dir_list => {
                const host = try self.service();
                const callback = host.dir_list orelse
                    return self.runtime.fail(.host_unavailable);
                const path = registers[arguments[0]].asString();
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
                const prompt = registers[arguments[0]].asString();
                // End of input is absence and not failure: there is
                // nothing there, and no reason worth carrying
                // (docs/FAILURE.md).
                const line = (try callback(host.context, self.arena, prompt)) orelse
                    return .none;
                return self.runtime.ownValue(.ofString(line));
            },
            .print_error => {
                const host = try self.service();
                const callback = host.print_error orelse
                    return self.runtime.fail(.host_unavailable);
                try callback(host.context, registers[arguments[0]].asString());
                return .none;
            },
            .clock_ms => {
                const host = try self.service();
                const callback = host.clock_ms orelse return self.runtime.fail(.host_unavailable);
                return .ofLong(callback(host.context));
            },
            .sleep_ms => {
                const host = try self.service();
                const callback = host.sleep_ms orelse return self.runtime.fail(.host_unavailable);
                // A duration that has already elapsed is not a bug:
                // `deadline - now` goes negative on a slow frame, and
                // the answer is "no time left to wait".
                callback(host.context, registers[arguments[0]].asLong());
                return .none;
            },
            .env_get => {
                const host = try self.service();
                const callback = host.env orelse return self.runtime.fail(.host_unavailable);
                const name = registers[arguments[0]].asString();
                const found = (try callback(host.context, self.arena, name)) orelse
                    return .none;
                return self.runtime.ownValue(.ofString(found));
            },
            .file_exists => {
                const host = try self.service();
                const callback = host.file_exists orelse return self.runtime.fail(.host_unavailable);
                return .ofBoolean(callback(host.context, registers[arguments[0]].asString()));
            },
            .term_rows => {
                const screen = try self.terminal();
                return .ofLong(screen.term_rows(screen.context));
            },
            .term_cols => {
                const screen = try self.terminal();
                return .ofLong(screen.term_cols(screen.context));
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
                    registers[arguments[0]].asLong(),
                    registers[arguments[1]].asLong(),
                );
                return .none;
            },
            .term_style => {
                const screen = try self.terminal();
                try screen.term_style(
                    screen.context,
                    registers[arguments[0]].asLong(),
                    registers[arguments[1]].asLong(),
                    registers[arguments[2]].asBoolean(),
                );
                return .none;
            },
            .term_write => {
                const screen = try self.terminal();
                try screen.term_write(screen.context, registers[arguments[0]].asString());
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
                try self.runtime.setKeyText(event.text);
                return self.runtime.ownValue(.ofString(event.name));
            },
            .key_text => return .ofString(self.runtime.last_key_text),
        }
    }

    /// The subscripts of one indexing operation, gathered out of the
    /// registers into reused scratch.  An array carries one per axis;
    /// a list or map carries exactly one.
    fn subscripts(
        self: *Machine,
        registers: []const RuntimeValue,
        of: []const Register,
    ) error{OutOfMemory}![]const RuntimeValue {
        self.index_scratch.clearRetainingCapacity();
        try self.index_scratch.ensureTotalCapacity(self.arena, of.len);
        for (of) |register| self.index_scratch.appendAssumeCapacity(registers[register]);
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
        .string => .ofString(""),
        .strukt => .{ .tag = .strukt },
        .optional => .none,
        else => .none,
    };
}

/// Only the named owner frees (S6, S23): a second argument carries the
/// binding `free`/`give` must verify against.
fn namedBinding(
    registers: []const RuntimeValue,
    arguments: []const Register,
    serial: u64,
) ?runtime.OwnedBy {
    if (arguments.len != 2) return null;
    return .{ .serial = serial, .local = @intCast(registers[arguments[1]].asLong()) };
}
