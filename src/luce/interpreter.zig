//! The Luce IR interpreter — the first engine behind the backend
//! boundary.
//!
//! Deterministic and safe: checked integer arithmetic, explicit
//! conversion range checks, a step budget standing in for a deadline,
//! and a call-depth limit.  All temporary storage comes from the
//! evaluation arena; the interpreter itself allocates nothing that
//! outlives one evaluation.

const std = @import("std");
const ir = @import("ir.zig");
const fabric = @import("fabric.zig");
const backend = @import("backend.zig");

const Allocator = std.mem.Allocator;
const RuntimeValue = backend.RuntimeValue;
const InputValue = backend.InputValue;
const Result = backend.Result;
const Budget = backend.Budget;

pub fn run(
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    budget: Budget,
    host: ?backend.Host,
) error{OutOfMemory}!Result {
    // Gate on availability before executing anything: a program whose
    // read inputs are not all available computes nothing.
    for (program.reads) |port| {
        if (port >= inputs.len or inputs[port] == .unavailable) return .unavailable;
    }

    var machine: Machine = .{
        .arena = arena,
        .program = program,
        .inputs = inputs,
        .outputs = outputs,
        .steps = budget.steps,
        .max_depth = budget.call_depth,
        .host = host,
    };
    switch (try machine.execute(program.entry_function)) {
        .value => return .{ .success = .{
            .intents = machine.intents,
            .leaked_objects = machine.live_objects,
        } },
        .trap => |trap| return .{ .trap = trap },
    }
}

const CallOutcome = union(enum) {
    value: RuntimeValue,
    trap: backend.Trap,
};

/// One live call.  Frames live on an explicit heap-allocated stack, so
/// call depth is bounded by the budget and available memory — never by
/// the native stack.
const Frame = struct {
    function: u32,
    registers: []RuntimeValue,
    locals: []RuntimeValue,
    block: ir.BlockId = 0,
    position: usize = 0,
    /// The caller register receiving this frame's return value.
    destination: Register = 0,
    /// Unique per call: object ownership names (serial, local) pairs,
    /// so recursion never confuses two frames' bindings.
    serial: u32 = 0,
};

const Register = ir.Register;

const Machine = struct {
    arena: Allocator,
    program: *const ir.Program,
    inputs: []const InputValue,
    outputs: []?RuntimeValue,
    steps: u64,
    max_depth: u32,
    host: ?backend.Host,
    /// Intents recorded by the fabric builtins, in order.  Arena-owned;
    /// the caller copies what it applies.
    intents: fabric.Intents = .{},
    /// The text payload of the most recent key_read "text" event.
    last_key_text: []const u8 = "",
    stack: std.ArrayList(Frame) = .empty,
    /// Every allocated object, alive or freed; handles index this
    /// table.  Slots are never reused, so a freed handle stays
    /// detectably dead for the whole evaluation.
    heap: std.ArrayList(HeapObject) = .empty,
    live_objects: u32 = 0,
    next_serial: u32 = 1,
    pending_trap: ?backend.Trap = null,

    /// Instruction handlers fail with error.Trap after recording the
    /// trap here; the dispatch loop catches once (`caught`).  This is
    /// the ceval-style pending-error pattern — no per-operation
    /// outcome plumbing.
    const EvalError = error{ OutOfMemory, Trap };

    fn trap(self: *Machine, code: ir.TrapCode) CallOutcome {
        _ = self;
        return .{ .trap = .{ .code = code, .message = code.message() } };
    }

    fn failure(self: *Machine, code: ir.TrapCode) EvalError {
        self.pending_trap = .{ .code = code, .message = code.message() };
        return error.Trap;
    }

    fn failureMessage(self: *Machine, code: ir.TrapCode, message: []const u8) EvalError {
        self.pending_trap = .{ .code = code, .message = message };
        return error.Trap;
    }

    fn caught(self: *Machine, mistake: EvalError) error{OutOfMemory}!CallOutcome {
        return switch (mistake) {
            error.OutOfMemory => error.OutOfMemory,
            error.Trap => .{ .trap = self.pending_trap.? },
        };
    }

    /// Resolve a handle to its live object, or fail: null slots trap
    /// null_object, freed ones use_after_free.
    fn resolve(self: *Machine, value: RuntimeValue) EvalError!*HeapObject {
        const handle = value.object;
        if (handle.isNull()) return self.failure(.null_object);
        if (handle.index >= self.heap.items.len) return self.failure(.use_after_free);
        const found = &self.heap.items[handle.index];
        if (!found.alive) return self.failure(.use_after_free);
        return found;
    }

    fn service(self: *Machine) EvalError!backend.Host {
        return self.host orelse return self.failure(.host_unavailable);
    }

    fn terminal(self: *Machine) EvalError!backend.Terminal {
        const host = try self.service();
        return host.terminal orelse return self.failure(.host_unavailable);
    }

    fn pushFrame(
        self: *Machine,
        function_index: u32,
        arguments: []const RuntimeValue,
        destination: Register,
    ) error{OutOfMemory}!?CallOutcome {
        if (self.stack.items.len >= self.max_depth) return self.trap(.call_depth_exceeded);
        const function = &self.program.functions[function_index];
        const registers = try self.arena.alloc(RuntimeValue, function.instructions.len);
        const locals = try self.arena.alloc(RuntimeValue, function.locals.len);
        @memset(locals, .none);
        @memcpy(locals[0..arguments.len], arguments);
        const serial = self.next_serial;
        self.next_serial += 1;
        try self.stack.append(self.arena, .{
            .function = function_index,
            .registers = registers,
            .locals = locals,
            .destination = destination,
            .serial = serial,
        });
        return null;
    }

    fn execute(self: *Machine, entry: u32) error{OutOfMemory}!CallOutcome {
        if (try self.pushFrame(entry, &.{}, 0)) |failed| return failed;

        dispatch: while (true) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            const function = &self.program.functions[frame.function];
            const registers = frame.registers;
            const locals = frame.locals;
            const items = function.blocks[frame.block].items;

            while (frame.position < items.len) {
                if (self.steps == 0) return self.trap(.step_budget_exhausted);
                self.steps -= 1;

                const item = items[frame.position];
                frame.position += 1;
                const instruction = function.instructions[item];
                switch (instruction) {
                    .const_boolean => |value| registers[item] = .{ .boolean = value },
                    .const_int => |value| registers[item] = .{ .int = value },
                    .const_float => |value| registers[item] = .{ .float = value },
                    .const_data => |data| {
                        const stored = self.program.constants[data.constant];
                        registers[item] = if (data.data_type == .string)
                            .{ .string = stored }
                        else
                            .{ .bytes = stored };
                    },
                    .local_get => |local| registers[item] = locals[local],
                    .local_set => |set| locals[set.local] = registers[set.value],
                    .input_load => |port| registers[item] = self.inputs[port].value,
                    .output_store => |store| self.outputs[store.port] = registers[store.value],
                    .binary => |operation| {
                        registers[item] = self.binary(operation, registers) catch |mistake|
                            return self.caught(mistake);
                    },
                    .unary => |operation| {
                        switch (operation.op) {
                            .logic_not => registers[item] = .{ .boolean = !registers[operation.operand].boolean },
                            .negate => switch (registers[operation.operand]) {
                                .int => |value| {
                                    if (value == std.math.minInt(i64)) return self.trap(.integer_overflow);
                                    registers[item] = .{ .int = -value };
                                },
                                .float => |value| registers[item] = .{ .float = -value },
                                else => unreachable,
                            },
                        }
                    },
                    .convert => |operation| switch (operation.kind) {
                        .int_to_float => registers[item] = .{
                            .float = @floatFromInt(registers[operation.operand].int),
                        },
                        .float_to_int => {
                            const value = registers[operation.operand].float;
                            if (std.math.isNan(value) or
                                value < -9223372036854775808.0 or
                                value >= 9223372036854775808.0)
                            {
                                return self.trap(.conversion_range);
                            }
                            registers[item] = .{ .int = @intFromFloat(@trunc(value)) };
                        },
                    },
                    .struct_make => |make| {
                        const fields = try self.arena.alloc(RuntimeValue, make.fields.len);
                        for (make.fields, fields) |field_register, *slot| {
                            slot.* = registers[field_register];
                        }
                        registers[item] = .{ .strukt = fields };
                    },
                    .struct_get => |get| {
                        registers[item] = registers[get.target].strukt[get.field];
                    },
                    .struct_set => |set| {
                        const source = registers[set.target].strukt;
                        const fields = try self.arena.alloc(RuntimeValue, source.len);
                        @memcpy(fields, source);
                        fields[set.field] = registers[set.value];
                        registers[item] = .{ .strukt = fields };
                    },
                    .heap_new => |new| {
                        registers[item] = self.allocateObject(new, registers) catch |mistake|
                            return self.caught(mistake);
                    },
                    .object_bind => |bind| self.bindValue(registers[bind.value], frame.serial, bind.local),
                    .object_unbind => |unbind| self.unbindValue(registers[unbind.value], frame.serial, unbind.local),
                    .call => |called| {
                        const arguments_storage = try self.arena.alloc(RuntimeValue, called.arguments.len);
                        for (called.arguments, arguments_storage) |argument, *slot| {
                            slot.* = registers[argument];
                        }
                        if (try self.pushFrame(called.function, arguments_storage, item)) |failed| {
                            return failed;
                        }
                        continue :dispatch;
                    },
                    .intrinsic => |operation| {
                        registers[item] = self.intrinsic(operation, registers, frame.serial) catch |mistake|
                            return self.caught(mistake);
                    },
                    .jump => |target| {
                        frame.block = target;
                        frame.position = 0;
                        continue :dispatch;
                    },
                    .branch => |branched| {
                        frame.block = if (registers[branched.condition].boolean)
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
                        self.loosenFromFrame(returned, finished.serial);
                        if (self.stack.items.len == 0) return .{ .value = returned };
                        const parent = &self.stack.items[self.stack.items.len - 1];
                        const parent_function = &self.program.functions[parent.function];
                        if (parent_function.result_types[finished.destination] != .none) {
                            parent.registers[finished.destination] = returned;
                        }
                        continue :dispatch;
                    },
                    .trap => |code| return self.trap(code),
                }
            }
            unreachable; // the verifier guarantees a terminator
        }
    }

    // -- the object heap ----------------------------------------------

    const MapEntry = struct { key: RuntimeValue, value: RuntimeValue };

    /// Who frees an object (OWNERSHIP.md): `loose` — a fresh value or
    /// statement temporary; `container` — an element some container
    /// adopted and frees with itself; `binding` — a named local of one
    /// specific call frame, released when that scope exits.
    const OwnedBy = struct { serial: u32, local: u32 };

    const Owner = union(enum) {
        loose,
        container,
        binding: OwnedBy,
    };

    const HeapObject = struct {
        alive: bool = true,
        owner: Owner = .loose,
        data: Data,

        const Data = union(enum) {
            list: std.ArrayList(RuntimeValue),
            map: std.ArrayList(MapEntry),
            array: struct { dims: []i64, elements: []RuntimeValue },
            builder: std.ArrayList(u8),
        };
    };

    // -- ownership walks ----------------------------------------------
    //
    // Bind/adopt/release walk a value's top objects: the object a
    // handle names, or a struct's object fields recursively.  They
    // never descend into an object's elements — those already belong
    // to it.  Nesting depth is bounded by the (finite) type shape.

    fn liveObject(self: *Machine, handle: backend.ObjectHandle) ?*HeapObject {
        if (handle.isNull() or handle.index >= self.heap.items.len) return null;
        const object = &self.heap.items[handle.index];
        if (!object.alive) return null;
        return object;
    }

    /// The objects in `value` now belong to `local` of frame `serial`.
    fn bindValue(self: *Machine, value: RuntimeValue, serial: u32, local: u32) void {
        switch (value) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                object.owner = .{ .binding = .{ .serial = serial, .local = local } };
            },
            .strukt => |fields| for (fields) |field| self.bindValue(field, serial, local),
            else => {},
        }
    }

    /// The objects in `value` were adopted by a container (S20).
    fn adoptValue(self: *Machine, value: RuntimeValue) void {
        switch (value) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                object.owner = .container;
            },
            .strukt => |fields| for (fields) |field| self.adoptValue(field),
            else => {},
        }
    }

    /// The objects in `value` belong to nobody yet: pop results and
    /// returned values (the receiver adopts or binds them next).
    fn loosenValue(self: *Machine, value: RuntimeValue) void {
        switch (value) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                object.owner = .loose;
            },
            .strukt => |fields| for (fields) |field| self.loosenValue(field),
            else => {},
        }
    }

    /// On return, everything the finished frame still owned in the
    /// returned value moves out loose; the caller owns it (S16).
    fn loosenFromFrame(self: *Machine, value: RuntimeValue, serial: u32) void {
        switch (value) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner == .binding and object.owner.binding.serial == serial) {
                    object.owner = .loose;
                }
            },
            .strukt => |fields| for (fields) |field| self.loosenFromFrame(field, serial),
            else => {},
        }
    }

    /// Free the objects in `value` still bound to (serial, local); the
    /// scope-exit release.  Objects owned elsewhere by now are left
    /// alone, which makes releases safe on every path.
    fn unbindValue(self: *Machine, value: RuntimeValue, serial: u32, local: u32) void {
        switch (value) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner == .binding and
                    object.owner.binding.serial == serial and
                    object.owner.binding.local == local)
                {
                    self.freeObject(handle.index);
                }
            },
            .strukt => |fields| for (fields) |field| self.unbindValue(field, serial, local),
            else => {},
        }
    }

    /// Free one object and everything it owns, recursively (S20).
    fn freeObject(self: *Machine, index: u32) void {
        const object = &self.heap.items[index];
        if (!object.alive) return;
        object.alive = false;
        self.live_objects -= 1;
        switch (object.data) {
            .list => |list| for (list.items) |item| self.freeValue(item),
            .map => |map| for (map.items) |entry| self.freeValue(entry.value),
            .array => |array| for (array.elements) |item| self.freeValue(item),
            .builder => {},
        }
    }

    /// Free the objects in a value unconditionally (owned elements
    /// being dropped by their container: overwrite, remove, clear).
    fn freeValue(self: *Machine, value: RuntimeValue) void {
        switch (value) {
            .object => |handle| {
                if (self.liveObject(handle) != null) self.freeObject(handle.index);
            },
            .strukt => |fields| for (fields) |field| self.freeValue(field),
            else => {},
        }
    }

    /// give/free verification (S23): never an object a container
    /// owns, and — when the verb names an owned binding — only an
    /// object that binding still owns (an alias may have moved it).
    /// Struct values check every filled field; unfilled fields are
    /// simply carried along.
    fn checkGivable(self: *Machine, value: RuntimeValue, expected: ?OwnedBy) EvalError!void {
        switch (value) {
            .object => |handle| {
                if (handle.isNull()) return;
                if (handle.index >= self.heap.items.len) return self.failure(.use_after_free);
                const found = &self.heap.items[handle.index];
                if (!found.alive) return self.failure(.use_after_free);
                if (found.owner == .container) return self.failure(.not_owned);
                if (expected) |owner| {
                    if (!(found.owner == .binding and
                        found.owner.binding.serial == owner.serial and
                        found.owner.binding.local == owner.local))
                    {
                        return self.failure(.not_owned);
                    }
                }
            },
            .strukt => |fields| for (fields) |field| try self.checkGivable(field, expected),
            else => {},
        }
    }

    /// Deep copy (S31): duplicate the object and everything it owns,
    /// recursively.  Values pass through; unfilled slots stay unfilled
    /// (only the copy verb itself demands a filled top-level object).
    fn deepCopy(self: *Machine, value: RuntimeValue) EvalError!RuntimeValue {
        switch (value) {
            .object => |handle| {
                if (handle.isNull()) return value;
                if (handle.index >= self.heap.items.len) return self.failure(.use_after_free);
                if (!self.heap.items[handle.index].alive) return self.failure(.use_after_free);
                const data: HeapObject.Data = switch (self.heap.items[handle.index].data) {
                    .list => |list| blk: {
                        var copied: std.ArrayList(RuntimeValue) = .empty;
                        try copied.ensureTotalCapacity(self.arena, list.items.len);
                        for (list.items) |item| {
                            copied.appendAssumeCapacity(try self.deepCopy(item));
                        }
                        break :blk .{ .list = copied };
                    },
                    .map => |map| blk: {
                        var copied: std.ArrayList(MapEntry) = .empty;
                        try copied.ensureTotalCapacity(self.arena, map.items.len);
                        for (map.items) |entry| {
                            copied.appendAssumeCapacity(.{
                                .key = entry.key,
                                .value = try self.deepCopy(entry.value),
                            });
                        }
                        break :blk .{ .map = copied };
                    },
                    .array => |array| blk: {
                        const dims = try self.arena.dupe(i64, array.dims);
                        const elements = try self.arena.alloc(RuntimeValue, array.elements.len);
                        for (array.elements, elements) |item, *slot| {
                            slot.* = try self.deepCopy(item);
                        }
                        break :blk .{ .array = .{ .dims = dims, .elements = elements } };
                    },
                    .builder => |builder| blk: {
                        var copied: std.ArrayList(u8) = .empty;
                        try copied.appendSlice(self.arena, builder.items);
                        break :blk .{ .builder = copied };
                    },
                };
                const index: u32 = @intCast(self.heap.items.len);
                try self.heap.append(self.arena, .{ .data = data });
                self.live_objects += 1;
                const duplicate: RuntimeValue = .{ .object = .{ .index = index } };
                // The copy's own elements belong to it.
                switch (self.heap.items[index].data) {
                    .list => |list| for (list.items) |item| self.adoptValue(item),
                    .map => |map| for (map.items) |entry| self.adoptValue(entry.value),
                    .array => |array| for (array.elements) |item| self.adoptValue(item),
                    .builder => {},
                }
                return duplicate;
            },
            .strukt => |fields| {
                const copied = try self.arena.alloc(RuntimeValue, fields.len);
                for (fields, copied) |field, *slot| {
                    slot.* = try self.deepCopy(field);
                }
                return .{ .strukt = copied };
            },
            else => return value,
        }
    }

    /// A safety valve, not a design limit: one array allocation cannot
    /// exceed this many elements.
    const max_array_elements = 1 << 24;

    fn allocateObject(
        self: *Machine,
        new: ir.Instruction.HeapNew,
        registers: []const RuntimeValue,
    ) EvalError!RuntimeValue {
        const data: HeapObject.Data = switch (self.program.heap_types[new.heap]) {
            .list => .{ .list = .empty },
            .map => .{ .map = .empty },
            .builder => .{ .builder = .empty },
            .array => |shape| blk: {
                const dims = try self.arena.alloc(i64, new.dims.len);
                var total: usize = 1;
                for (new.dims, dims) |register, *dimension| {
                    const size = registers[register].int;
                    if (size < 0 or size > max_array_elements) return self.failure(.index_bounds);
                    dimension.* = size;
                    total = std.math.mul(usize, total, @intCast(size)) catch
                        return self.failure(.index_bounds);
                    if (total > max_array_elements) return self.failure(.index_bounds);
                }
                const elements = try self.arena.alloc(RuntimeValue, total);
                const zero = try self.zeroValue(shape.element);
                @memset(elements, zero);
                break :blk .{ .array = .{ .dims = dims, .elements = elements } };
            },
        };
        const index: u32 = @intCast(self.heap.items.len);
        try self.heap.append(self.arena, .{ .data = data });
        self.live_objects += 1;
        return .{ .object = .{ .index = index } };
    }

    /// The zero value a fresh array element carries, per element type.
    fn zeroValue(self: *Machine, of: types.Type) error{OutOfMemory}!RuntimeValue {
        return switch (of) {
            .none => .none,
            .boolean => .{ .boolean = false },
            .int => .{ .int = 0 },
            .float => .{ .float = 0.0 },
            .string => .{ .string = "" },
            .bytes => .{ .bytes = "" },
            .heap => .{ .object = backend.ObjectHandle.null_object },
            .strukt => |layout_index| blk: {
                const layout = self.program.structs[layout_index];
                const fields = try self.arena.alloc(RuntimeValue, layout.fields.len);
                for (layout.fields, fields) |field, *slot| {
                    slot.* = try self.zeroValue(field.field_type);
                }
                break :blk .{ .strukt = fields };
            },
        };
    }

    fn keyEquals(left: RuntimeValue, right: RuntimeValue) bool {
        return switch (left) {
            .int => |value| value == right.int,
            .string => |value| std.mem.eql(u8, value, right.string),
            else => unreachable, // the analyzer keys maps by Int or String
        };
    }

    fn findEntry(entries: []MapEntry, key: RuntimeValue) ?usize {
        for (entries, 0..) |entry, index| {
            if (keyEquals(entry.key, key)) return index;
        }
        return null;
    }

    /// Flatten a multi-dimensional index against the array's dims;
    /// null when any index is out of range.
    fn flattenIndex(
        dims: []const i64,
        registers: []const RuntimeValue,
        indices: []const Register,
    ) ?usize {
        var flat: usize = 0;
        for (dims, indices) |size, register| {
            const index = registers[register].int;
            if (index < 0 or index >= size) return null;
            flat = flat * @as(usize, @intCast(size)) + @as(usize, @intCast(index));
        }
        return flat;
    }

    fn binary(
        self: *Machine,
        operation: ir.Instruction.Binary,
        registers: []const RuntimeValue,
    ) EvalError!RuntimeValue {
        const left = registers[operation.left];
        const right = registers[operation.right];
        switch (operation.op) {
            .add, .subtract, .multiply, .divide, .remainder => {},
            else => return .{ .boolean = self.compare(operation.op, left, right) },
        }

        switch (left) {
            .int => |left_int| {
                const right_int = right.int;
                switch (operation.op) {
                    .add => {
                        const result = @addWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.failure(.integer_overflow);
                        return .{ .int = result[0] };
                    },
                    .subtract => {
                        const result = @subWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.failure(.integer_overflow);
                        return .{ .int = result[0] };
                    },
                    .multiply => {
                        const result = @mulWithOverflow(left_int, right_int);
                        if (result[1] != 0) return self.failure(.integer_overflow);
                        return .{ .int = result[0] };
                    },
                    .divide => {
                        if (right_int == 0) return self.failure(.divide_by_zero);
                        if (left_int == std.math.minInt(i64) and right_int == -1) {
                            return self.failure(.integer_overflow);
                        }
                        return .{ .int = @divTrunc(left_int, right_int) };
                    },
                    .remainder => {
                        if (right_int == 0) return self.failure(.divide_by_zero);
                        if (left_int == std.math.minInt(i64) and right_int == -1) {
                            return self.failure(.integer_overflow);
                        }
                        return .{ .int = @rem(left_int, right_int) };
                    },
                    else => unreachable,
                }
            },
            .float => |left_float| {
                const right_float = right.float;
                // IEEE 754 semantics: division by zero and overflow
                // produce infinities and NaN, never traps.
                const computed: f64 = switch (operation.op) {
                    .add => left_float + right_float,
                    .subtract => left_float - right_float,
                    .multiply => left_float * right_float,
                    .divide => left_float / right_float,
                    .remainder => @rem(left_float, right_float),
                    else => unreachable,
                };
                return .{ .float = computed };
            },
            .string => |left_string| {
                // The analyzer only admits + for strings.
                const joined = try std.mem.concat(self.arena, u8, &.{ left_string, right.string });
                return .{ .string = joined };
            },
            else => unreachable,
        }
    }

    fn compare(self: *const Machine, operation: ir.BinaryOp, left: RuntimeValue, right: RuntimeValue) bool {
        switch (left) {
            .int => |value| {
                const other = right.int;
                return switch (operation) {
                    .equal => value == other,
                    .not_equal => value != other,
                    .less => value < other,
                    .less_equal => value <= other,
                    .greater => value > other,
                    .greater_equal => value >= other,
                    else => unreachable,
                };
            },
            .float => |value| {
                const other = right.float;
                return switch (operation) {
                    .equal => value == other,
                    .not_equal => value != other,
                    .less => value < other,
                    .less_equal => value <= other,
                    .greater => value > other,
                    .greater_equal => value >= other,
                    else => unreachable,
                };
            },
            .string => |value| {
                const order = std.mem.order(u8, value, right.string);
                return switch (operation) {
                    .equal => order == .eq,
                    .not_equal => order != .eq,
                    .less => order == .lt,
                    .less_equal => order != .gt,
                    .greater => order == .gt,
                    .greater_equal => order != .lt,
                    else => unreachable,
                };
            },
            .bytes => |value| {
                const same = std.mem.eql(u8, value, right.bytes);
                return if (operation == .equal) same else !same;
            },
            .boolean => |value| {
                const same = value == right.boolean;
                return if (operation == .equal) same else !same;
            },
            .strukt => |value| {
                var same = true;
                for (value, right.strukt) |left_field, right_field| {
                    if (!self.compare(.equal, left_field, right_field)) same = false;
                }
                return if (operation == .equal) same else !same;
            },
            .object => |value| {
                // Object equality is identity: same object, not same
                // contents.
                const same = value.index == right.object.index;
                return if (operation == .equal) same else !same;
            },
            .none => unreachable,
        }
    }

    fn intrinsic(
        self: *Machine,
        operation: ir.Instruction.IntrinsicCall,
        registers: []const RuntimeValue,
        serial: u32,
    ) EvalError!RuntimeValue {
        const arguments = operation.arguments;
        switch (operation.kind) {
            .abs => switch (registers[arguments[0]]) {
                .int => |value| {
                    if (value == std.math.minInt(i64)) return self.failure(.integer_overflow);
                    return .{ .int = @intCast(@abs(value)) };
                },
                .float => |value| return .{ .float = @abs(value) },
                else => unreachable,
            },
            .min, .max => {
                const wants_minimum = operation.kind == .min;
                switch (registers[arguments[0]]) {
                    .int => |left| {
                        const right = registers[arguments[1]].int;
                        const chosen = if (wants_minimum) @min(left, right) else @max(left, right);
                        return .{ .int = chosen };
                    },
                    .float => |left| {
                        const right = registers[arguments[1]].float;
                        const chosen = if (wants_minimum) @min(left, right) else @max(left, right);
                        return .{ .float = chosen };
                    },
                    else => unreachable,
                }
            },
            .clamp => switch (registers[arguments[0]]) {
                .int => |value| {
                    const low = registers[arguments[1]].int;
                    const high = registers[arguments[2]].int;
                    return .{ .int = @min(@max(value, low), high) };
                },
                .float => |value| {
                    const low = registers[arguments[1]].float;
                    const high = registers[arguments[2]].float;
                    return .{ .float = @min(@max(value, low), high) };
                },
                else => unreachable,
            },
            .sqrt => return .{ .float = @sqrt(registers[arguments[0]].float) },
            .floor => return .{ .float = @floor(registers[arguments[0]].float) },
            .ceil => return .{ .float = @ceil(registers[arguments[0]].float) },
            .len => {
                const measured: usize = switch (registers[arguments[0]]) {
                    .string => |value| value.len,
                    .bytes => |value| value.len,
                    .object => blk: {
                        const object = try self.resolve(registers[arguments[0]]);
                        break :blk switch (object.data) {
                            .list => |list| list.items.len,
                            .map => |map| map.items.len,
                            .array => |array| if (array.dims.len == 0) 0 else @intCast(array.dims[0]),
                            .builder => |builder| builder.items.len,
                        };
                    },
                    else => unreachable,
                };
                return .{ .int = @intCast(measured) };
            },
            .null_object => {
                return .{ .object = backend.ObjectHandle.null_object };
            },
            .index_get => {
                const object = try self.resolve(registers[arguments[0]]);
                switch (object.data) {
                    .list => |list| {
                        const index = registers[arguments[1]].int;
                        if (index < 0 or index >= list.items.len) return self.failure(.index_bounds);
                        return list.items[@intCast(index)];
                    },
                    .map => |map| {
                        const at = findEntry(map.items, registers[arguments[1]]) orelse
                            return self.failure(.key_missing);
                        return map.items[at].value;
                    },
                    .array => |array| {
                        const flat = flattenIndex(array.dims, registers, arguments[1..]) orelse
                            return self.failure(.index_bounds);
                        return array.elements[flat];
                    },
                    .builder => unreachable,
                }
            },
            .index_set => {
                const object = try self.resolve(registers[arguments[0]]);
                const value = registers[arguments[arguments.len - 1]];
                switch (object.data) {
                    .list => |*list| {
                        const index = registers[arguments[1]].int;
                        if (index < 0 or index >= list.items.len) return self.failure(.index_bounds);
                        // An element overwrite frees the old owned
                        // element (S22).
                        self.freeValue(list.items[@intCast(index)]);
                        list.items[@intCast(index)] = value;
                    },
                    .map => |*map| {
                        const key = registers[arguments[1]];
                        if (findEntry(map.items, key)) |at| {
                            self.freeValue(map.items[at].value);
                            map.items[at].value = value;
                        } else {
                            try map.append(self.arena, .{ .key = key, .value = value });
                        }
                    },
                    .array => |array| {
                        const flat = flattenIndex(array.dims, registers, arguments[1 .. arguments.len - 1]) orelse
                            return self.failure(.index_bounds);
                        self.freeValue(array.elements[flat]);
                        array.elements[flat] = value;
                    },
                    .builder => unreachable,
                }
                self.adoptValue(value);
                return .none;
            },
            .list_slice => {
                const object = try self.resolve(registers[arguments[0]]);
                const list = object.data.list;
                const start = registers[arguments[1]].int;
                const end = registers[arguments[2]].int;
                if (start < 0 or end < start or end > list.items.len) return self.failure(.index_bounds);
                // Slices copy — including deep copies of object
                // elements, since two containers can never own one
                // object (S23, S31).
                var copied: std.ArrayList(RuntimeValue) = .empty;
                for (list.items[@intCast(start)..@intCast(end)]) |element| {
                    const duplicate = try self.deepCopy(element);
                    try copied.append(self.arena, duplicate);
                    self.adoptValue(duplicate);
                }
                const index: u32 = @intCast(self.heap.items.len);
                try self.heap.append(self.arena, .{ .data = .{ .list = copied } });
                self.live_objects += 1;
                return .{ .object = .{ .index = index } };
            },
            .append_value => {
                const object = try self.resolve(registers[arguments[0]]);
                switch (object.data) {
                    .list => |*list| {
                        try list.append(self.arena, registers[arguments[1]]);
                        self.adoptValue(registers[arguments[1]]);
                    },
                    .builder => |*builder| try builder.appendSlice(self.arena, registers[arguments[1]].string),
                    else => unreachable,
                }
                return .none;
            },
            .pop_value => {
                const object = try self.resolve(registers[arguments[0]]);
                const list = &object.data.list;
                const taken = list.pop() orelse return self.failure(.empty_collection);
                // pop hands the element out of the container (S22);
                // whatever receives it owns it next.
                self.loosenValue(taken);
                return taken;
            },
            .insert_value => {
                const object = try self.resolve(registers[arguments[0]]);
                const list = &object.data.list;
                const index = registers[arguments[1]].int;
                if (index < 0 or index > list.items.len) return self.failure(.index_bounds);
                try list.insert(self.arena, @intCast(index), registers[arguments[2]]);
                self.adoptValue(registers[arguments[2]]);
                return .none;
            },
            .remove_entry => {
                const object = try self.resolve(registers[arguments[0]]);
                switch (object.data) {
                    .list => |*list| {
                        const index = registers[arguments[1]].int;
                        if (index < 0 or index >= list.items.len) return self.failure(.index_bounds);
                        // Removing an owned element frees it (S22).
                        self.freeValue(list.orderedRemove(@intCast(index)));
                    },
                    .map => |*map| {
                        if (findEntry(map.items, registers[arguments[1]])) |at| {
                            self.freeValue(map.orderedRemove(at).value);
                        }
                    },
                    else => unreachable,
                }
                return .none;
            },
            .has_key => {
                const object = try self.resolve(registers[arguments[0]]);
                const found = findEntry(object.data.map.items, registers[arguments[1]]) != null;
                return .{ .boolean = found };
            },
            .key_at => {
                const object = try self.resolve(registers[arguments[0]]);
                const map = object.data.map;
                const index = registers[arguments[1]].int;
                if (index < 0 or index >= map.items.len) return self.failure(.index_bounds);
                return map.items[@intCast(index)].key;
            },
            .dim_size => {
                const object = try self.resolve(registers[arguments[0]]);
                const array = object.data.array;
                const axis = registers[arguments[1]].int;
                if (axis < 0 or axis >= array.dims.len) return self.failure(.index_bounds);
                return .{ .int = array.dims[@intCast(axis)] };
            },
            .free_object => {
                // Only the named owner frees (S6, S23): a second
                // argument carries the binding to verify against.
                const value = registers[arguments[0]];
                _ = try self.resolve(value);
                const expected: ?OwnedBy = if (arguments.len == 2)
                    .{ .serial = serial, .local = @intCast(registers[arguments[1]].int) }
                else
                    null;
                try self.checkGivable(value, expected);
                self.freeObject(value.object.index);
                return .none;
            },
            .give_object => {
                // The dynamic ownership check (S23): giving what a
                // container owns — or what the named binding no longer
                // owns — would forge a second owner.  Verbs demand an
                // object, so an unfilled slot traps (S42).
                const value = registers[arguments[0]];
                const expected: ?OwnedBy = if (arguments.len == 2)
                    .{ .serial = serial, .local = @intCast(registers[arguments[1]].int) }
                else
                    null;
                switch (value) {
                    .object => {
                        _ = try self.resolve(value);
                        try self.checkGivable(value, expected);
                    },
                    .strukt => try self.checkGivable(value, expected),
                    else => unreachable,
                }
                return value;
            },
            .copy_object => {
                const value = registers[arguments[0]];
                if (value == .object) {
                    // Verbs demand an object (S42): copying an
                    // unfilled or freed slot traps.
                    _ = try self.resolve(value);
                }
                return try self.deepCopy(value);
            },
            .str_find => {
                const haystack = registers[arguments[0]].string;
                const needle = registers[arguments[1]].string;
                const found = std.mem.indexOf(u8, haystack, needle);
                return .{ .int = if (found) |at| @intCast(at) else -1 };
            },
            .str_contains => {
                const found = std.mem.indexOf(u8, registers[arguments[0]].string, registers[arguments[1]].string);
                return .{ .boolean = found != null };
            },
            .str_starts => {
                const matches = std.mem.startsWith(u8, registers[arguments[0]].string, registers[arguments[1]].string);
                return .{ .boolean = matches };
            },
            .str_ends => {
                const matches = std.mem.endsWith(u8, registers[arguments[0]].string, registers[arguments[1]].string);
                return .{ .boolean = matches };
            },
            .str_trim => {
                const trimmed = std.mem.trim(u8, registers[arguments[0]].string, " \t\r\n");
                return .{ .string = trimmed };
            },
            .str_lower, .str_upper => {
                const text = registers[arguments[0]].string;
                const folded = try self.arena.dupe(u8, text);
                for (folded) |*byte| {
                    byte.* = if (operation.kind == .str_lower)
                        std.ascii.toLower(byte.*)
                    else
                        std.ascii.toUpper(byte.*);
                }
                return .{ .string = folded };
            },
            .str_replace => {
                const text = registers[arguments[0]].string;
                const old = registers[arguments[1]].string;
                const fresh = registers[arguments[2]].string;
                if (old.len == 0) return .{ .string = text };
                var replaced: std.ArrayList(u8) = .empty;
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, text, at, old)) |found| {
                    try replaced.appendSlice(self.arena, text[at..found]);
                    try replaced.appendSlice(self.arena, fresh);
                    at = found + old.len;
                }
                try replaced.appendSlice(self.arena, text[at..]);
                return .{ .string = replaced.items };
            },
            .str_repeat => {
                const text = registers[arguments[0]].string;
                const times = registers[arguments[1]].int;
                if (times <= 0 or text.len == 0) return .{ .string = "" };
                const total = std.math.mul(usize, text.len, @intCast(times)) catch
                    return self.failure(.string_bounds);
                if (total > max_string_size) return self.failure(.string_bounds);
                const repeated = try self.arena.alloc(u8, total);
                var at: usize = 0;
                while (at < total) : (at += text.len) {
                    @memcpy(repeated[at .. at + text.len], text);
                }
                return .{ .string = repeated };
            },
            .str_split => {
                const text = registers[arguments[0]].string;
                const separator = registers[arguments[1]].string;
                var pieces: std.ArrayList(RuntimeValue) = .empty;
                if (separator.len == 0) {
                    // Whitespace runs, Python's split() with no argument.
                    var scan = std.mem.tokenizeAny(u8, text, " \t\r\n");
                    while (scan.next()) |piece| {
                        try pieces.append(self.arena, .{ .string = piece });
                    }
                } else {
                    var scan = std.mem.splitSequence(u8, text, separator);
                    while (scan.next()) |piece| {
                        try pieces.append(self.arena, .{ .string = piece });
                    }
                }
                const index: u32 = @intCast(self.heap.items.len);
                try self.heap.append(self.arena, .{ .data = .{ .list = pieces } });
                self.live_objects += 1;
                return .{ .object = .{ .index = index } };
            },
            .list_sort, .list_reverse => {
                const object = try self.resolve(registers[arguments[0]]);
                const elements: []RuntimeValue = switch (object.data) {
                    .list => |*list| list.items,
                    .array => |array| array.elements,
                    else => unreachable,
                };
                if (operation.kind == .list_reverse) {
                    std.mem.reverse(RuntimeValue, elements);
                } else {
                    std.sort.insertion(RuntimeValue, elements, {}, orderedBefore);
                }
                return .none;
            },
            .list_find, .list_contains => {
                const object = try self.resolve(registers[arguments[0]]);
                const elements: []const RuntimeValue = switch (object.data) {
                    .list => |list| list.items,
                    .array => |array| array.elements,
                    else => unreachable,
                };
                const wanted = registers[arguments[1]];
                var found: i64 = -1;
                for (elements, 0..) |element, at| {
                    if (self.compare(.equal, element, wanted)) {
                        found = @intCast(at);
                        break;
                    }
                }
                if (operation.kind == .list_find) return .{ .int = found };
                return .{ .boolean = found != -1 };
            },
            .list_join => {
                const object = try self.resolve(registers[arguments[0]]);
                const separator = registers[arguments[1]].string;
                var joined: std.ArrayList(u8) = .empty;
                for (object.data.list.items, 0..) |element, at| {
                    if (at != 0) try joined.appendSlice(self.arena, separator);
                    try joined.appendSlice(self.arena, element.string);
                }
                return .{ .string = joined.items };
            },
            .clear_object => {
                const object = try self.resolve(registers[arguments[0]]);
                switch (object.data) {
                    .list => |*list| {
                        // clear frees all owned elements (S22).
                        for (list.items) |item| self.freeValue(item);
                        list.clearRetainingCapacity();
                    },
                    .map => |*map| {
                        for (map.items) |entry| self.freeValue(entry.value);
                        map.clearRetainingCapacity();
                    },
                    .builder => |*builder| builder.clearRetainingCapacity(),
                    .array => unreachable,
                }
                return .none;
            },
            .map_keys => {
                const object = try self.resolve(registers[arguments[0]]);
                var listed: std.ArrayList(RuntimeValue) = .empty;
                for (object.data.map.items) |entry| {
                    try listed.append(self.arena, entry.key);
                }
                const index: u32 = @intCast(self.heap.items.len);
                try self.heap.append(self.arena, .{ .data = .{ .list = listed } });
                self.live_objects += 1;
                return .{ .object = .{ .index = index } };
            },
            .array_fill => {
                const object = try self.resolve(registers[arguments[0]]);
                @memset(object.data.array.elements, registers[arguments[1]]);
                return .none;
            },
            .str_value => {
                switch (registers[arguments[0]]) {
                    .int => |value| {
                        const text = try std.fmt.allocPrint(self.arena, "{d}", .{value});
                        return .{ .string = text };
                    },
                    .float => |value| {
                        const text = try std.fmt.allocPrint(self.arena, "{d}", .{value});
                        return .{ .string = text };
                    },
                    .boolean => |value| {
                        return .{ .string = if (value) "true" else "false" };
                    },
                    .string => |value| return .{ .string = value },
                    .object => {
                        const object = try self.resolve(registers[arguments[0]]);
                        const text = try self.arena.dupe(u8, object.data.builder.items);
                        return .{ .string = text };
                    },
                    else => unreachable,
                }
            },
            .parse_int => {
                const text = registers[arguments[0]].string;
                const value = std.fmt.parseInt(i64, text, 10) catch return self.failure(.parse_failed);
                return .{ .int = value };
            },
            .parse_float => {
                const text = registers[arguments[0]].string;
                const value = std.fmt.parseFloat(f64, text) catch return self.failure(.parse_failed);
                if (std.math.isNan(value) or std.math.isInf(value)) return self.failure(.parse_failed);
                return .{ .float = value };
            },
            .chr_code => {
                const code = registers[arguments[0]].int;
                if (code < 0 or code > 0x10FFFF) return self.failure(.bad_codepoint);
                const codepoint: u21 = @intCast(code);
                const encoded = try self.arena.alloc(u8, 4);
                const length = std.unicode.utf8Encode(codepoint, encoded) catch
                    return self.failure(.bad_codepoint);
                return .{ .string = encoded[0..length] };
            },
            .ord_text => {
                const text = registers[arguments[0]].string;
                if (text.len == 0) return self.failure(.bad_codepoint);
                const length = std.unicode.utf8ByteSequenceLength(text[0]) catch
                    return self.failure(.bad_codepoint);
                if (text.len < length) return self.failure(.bad_codepoint);
                const codepoint = std.unicode.utf8Decode(text[0..length]) catch
                    return self.failure(.bad_codepoint);
                return .{ .int = codepoint };
            },
            .string_slice => {
                const value = registers[arguments[0]].string;
                const start = registers[arguments[1]].int;
                const end = registers[arguments[2]].int;
                if (start < 0 or end < start or end > value.len) {
                    return self.failure(.string_bounds);
                }
                const start_index: usize = @intCast(start);
                const end_index: usize = @intCast(end);
                if (!isStringBoundary(value, start_index) or
                    !isStringBoundary(value, end_index))
                {
                    return self.failure(.string_boundary);
                }
                return .{ .string = value[start_index..end_index] };
            },
            .string_byte => {
                const value = registers[arguments[0]].string;
                const index = registers[arguments[1]].int;
                if (index < 0 or index >= value.len) return self.failure(.string_bounds);
                return .{ .int = value[@intCast(index)] };
            },
            .assert_true => {
                if (!registers[arguments[0]].boolean) return self.failure(.assertion_failed);
                return .none;
            },
            .trap_message => {
                return self.failureMessage(.explicit_trap, registers[arguments[0]].string);
            },
            .print => {
                const host = try self.service();
                const callback = host.printFn orelse return self.failure(.host_unavailable);
                try callback(host.context, registers[arguments[0]].string);
                return .none;
            },
            .file_read => {
                const host = try self.service();
                const callback = host.readFileFn orelse return self.failure(.host_unavailable);
                const path = registers[arguments[0]].string;
                return switch (try callback(host.context, self.arena, path)) {
                    .content => |content| .{ .string = content },
                    .failed => self.failure(.file_read_failed),
                };
            },
            .file_write => {
                const host = try self.service();
                const callback = host.writeFileFn orelse return self.failure(.host_unavailable);
                const written = callback(
                    host.context,
                    registers[arguments[0]].string,
                    registers[arguments[1]].string,
                );
                return .{ .boolean = written };
            },
            .file_exists => {
                const host = try self.service();
                const callback = host.fileExistsFn orelse return self.failure(.host_unavailable);
                const found = callback(host.context, registers[arguments[0]].string);
                return .{ .boolean = found };
            },
            .arg_count => {
                const host = try self.service();
                const callback = host.argCountFn orelse return self.failure(.host_unavailable);
                return .{ .int = callback(host.context) };
            },
            .arg_get => {
                const host = try self.service();
                const callback = host.argFn orelse return self.failure(.host_unavailable);
                const index = registers[arguments[0]].int;
                if (index < 0 or index > std.math.maxInt(u32)) return self.failure(.argument_bounds);
                const value = (try callback(host.context, self.arena, @intCast(index))) orelse
                    return self.failure(.argument_bounds);
                return .{ .string = value };
            },
            .term_rows => {
                const screen = try self.terminal();
                return .{ .int = screen.rowsFn(screen.context) };
            },
            .term_cols => {
                const screen = try self.terminal();
                return .{ .int = screen.colsFn(screen.context) };
            },
            .term_clear => {
                const screen = try self.terminal();
                try screen.clearFn(screen.context);
                return .none;
            },
            .term_move => {
                const screen = try self.terminal();
                try screen.moveFn(
                    screen.context,
                    registers[arguments[0]].int,
                    registers[arguments[1]].int,
                );
                return .none;
            },
            .term_style => {
                const screen = try self.terminal();
                try screen.styleFn(
                    screen.context,
                    registers[arguments[0]].int,
                    registers[arguments[1]].int,
                    registers[arguments[2]].boolean,
                );
                return .none;
            },
            .term_write => {
                const screen = try self.terminal();
                try screen.writeFn(screen.context, registers[arguments[0]].string);
                return .none;
            },
            .term_flush => {
                const screen = try self.terminal();
                try screen.flushFn(screen.context);
                return .none;
            },
            .key_read => {
                const screen = try self.terminal();
                const event = try screen.keyFn(screen.context, self.arena);
                self.last_key_text = event.text;
                return .{ .string = event.name };
            },
            .key_text => {
                return .{ .string = self.last_key_text };
            },
            .fabric_image => {
                const path = registers[arguments[0]].string;
                const pages = registers[arguments[1]].int;
                if (path.len == 0 or pages <= 0) return self.failure(.invalid_image);
                try self.intents.images.append(self.arena, .{
                    .path = path,
                    .pages = @intCast(pages),
                });
                return .none;
            },
            .fabric_create => {
                const handle: i64 = @intCast(self.intents.texels.items.len);
                try self.intents.texels.append(self.arena, .{
                    .name = registers[arguments[0]].string,
                });
                return .{ .int = handle };
            },
            .fabric_input, .fabric_output => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.failure(.invalid_handle);
                const declared = fabric.portTypeNamed(registers[arguments[2]].string) orelse
                    return self.failure(.invalid_port_type);
                const spec: fabric.PortSpec = .{
                    .name = registers[arguments[1]].string,
                    .declared = declared,
                };
                if (operation.kind == .fabric_input) {
                    try intent.inputs.append(self.arena, spec);
                } else {
                    try intent.outputs.append(self.arena, spec);
                }
                return .none;
            },
            .fabric_content => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.failure(.invalid_handle);
                intent.content = registers[arguments[1]].string;
                return .none;
            },
            .fabric_evaluator => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.failure(.invalid_handle);
                intent.evaluator = registers[arguments[1]].string;
                return .none;
            },
            .fabric_set => {
                const intent = self.intentAt(registers[arguments[0]].int) orelse
                    return self.failure(.invalid_handle);
                const value: fabric.SourceValue = switch (registers[arguments[2]]) {
                    .boolean => |flag| .{ .boolean = flag },
                    .int => |number| .{ .int = number },
                    .float => |number| .{ .float = number },
                    .string => |text| .{ .text = text },
                    else => unreachable,
                };
                try intent.sets.append(self.arena, .{
                    .output = registers[arguments[1]].string,
                    .value = value,
                });
                return .none;
            },
        }
    }

    fn intentAt(self: *Machine, handle: i64) ?*fabric.NewTexel {
        if (handle < 0 or handle >= self.intents.texels.items.len) return null;
        return &self.intents.texels.items[@intCast(handle)];
    }
};

fn isStringBoundary(value: []const u8, index: usize) bool {
    return index == value.len or value[index] & 0xc0 != 0x80;
}

/// One string operation cannot produce more than this many bytes.
const max_string_size = 64 * 1024 * 1024;

/// Ordering for sort: elements are Int, Float, or String (the
/// analyzer guarantees it).
fn orderedBefore(context: void, left: RuntimeValue, right: RuntimeValue) bool {
    _ = context;
    return switch (left) {
        .int => |value| value < right.int,
        .float => |value| value < right.float,
        .string => |value| std.mem.order(u8, value, right.string) == .lt,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("compile.zig");
const types = @import("types.zig");

const Bench = struct {
    program: ir.Program,
    arena: std.heap.ArenaAllocator,
    outputs: []?RuntimeValue,

    fn setup(source: []const u8, schema: types.PortSchema, options: types.CompileOptions) !Bench {
        var result = try compile_mod.compile(testing.allocator, source, schema, options);
        switch (result) {
            .success => {},
            .failure => |*diagnostics| {
                const rendered = try diagnostics.render(testing.allocator, source);
                defer testing.allocator.free(rendered);
                std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
                result.deinit();
                return error.TestUnexpectedResult;
            },
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const outputs = try arena.allocator().alloc(?RuntimeValue, schema.outputs.len);
        @memset(outputs, null);
        return .{ .program = result.success, .arena = arena, .outputs = outputs };
    }

    fn deinit(self: *Bench) void {
        self.arena.deinit();
        self.program.deinit();
    }

    fn evaluate(self: *Bench, inputs: []const InputValue) !Result {
        @memset(self.outputs, null);
        return backend.evaluate(
            self.arena.allocator(),
            &self.program,
            inputs,
            self.outputs,
            .{ .steps = 200_000, .call_depth = 64 },
        );
    }

    fn evaluateHosted(self: *Bench, inputs: []const InputValue, host: backend.Host) !Result {
        @memset(self.outputs, null);
        return backend.evaluateHosted(
            self.arena.allocator(),
            &self.program,
            inputs,
            self.outputs,
            .{ .steps = 200_000, .call_depth = 64 },
            host,
        );
    }
};

test "the plan's vertical slice: smooth pointer transform" {
    var bench = try Bench.setup(
        \\struct Point:
        \\    x: Float
        \\    y: Float
        \\
        \\func smooth(current: Point, target: Point, amount: Float) -> Point:
        \\    return Point(
        \\        x = current.x + (target.x - current.x) * amount,
        \\        y = current.y + (target.y - current.y) * amount,
        \\    )
        \\
        \\func evaluate(input: Input, output: Output):
        \\    let previous = Point(x = input.previous_x, y = input.previous_y)
        \\    let pointer = Point(x = input.pointer_x, y = input.pointer_y)
        \\    let eased = smooth(previous, pointer, input.amount)
        \\    output.x = eased.x
        \\    output.y = eased.y
        \\
    , .{
        .inputs = &.{
            .{ .name = "previous_x", .declared = .float },
            .{ .name = "previous_y", .declared = .float },
            .{ .name = "pointer_x", .declared = .float },
            .{ .name = "pointer_y", .declared = .float },
            .{ .name = "amount", .declared = .float },
        },
        .outputs = &.{
            .{ .name = "x", .declared = .float },
            .{ .name = "y", .declared = .float },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{
        .{ .value = .{ .float = 0.0 } },
        .{ .value = .{ .float = 0.0 } },
        .{ .value = .{ .float = 10.0 } },
        .{ .value = .{ .float = -4.0 } },
        .{ .value = .{ .float = 0.25 } },
    });
    try testing.expect(result == .success);
    try testing.expectEqual(@as(f64, 2.5), bench.outputs[0].?.float);
    try testing.expectEqual(@as(f64, -1.0), bench.outputs[1].?.float);
}

test "namespaced struct functions execute through qualified calls" {
    var bench = try Bench.setup(
        \\struct Math:
        \\    func twice(value: Int) -> Int:
        \\        return value * 2
        \\
        \\    func plus(left: Int, right: Int) -> Int:
        \\        return left + right
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = Math.twice(Math.plus(input.left, input.right))
        \\
    , .{
        .inputs = &.{
            .{ .name = "left", .declared = .int },
            .{ .name = "right", .declared = .int },
        },
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{
        .{ .value = .{ .int = 3 } },
        .{ .value = .{ .int = 4 } },
    });
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 14), bench.outputs[0].?.int);
}

test "loops, recursion, strings, and builtins compute" {
    var bench = try Bench.setup(
        \\func factorial(value: Int) -> Int:
        \\    if value <= 1:
        \\        return 1
        \\    return value * factorial(value - 1)
        \\
        \\func evaluate(input: Input, output: Output):
        \\    var total = 0
        \\    for index in range(1, 11):
        \\        total = total + index
        \\    output.sum = total
        \\    output.fact = factorial(10)
        \\    output.label = "sum " + input.name
        \\    output.small = min(clamp(total, 0, 40), abs(-3))
        \\
    , .{
        .inputs = &.{.{ .name = "name", .declared = .string }},
        .outputs = &.{
            .{ .name = "sum", .declared = .int },
            .{ .name = "fact", .declared = .int },
            .{ .name = "label", .declared = .string },
            .{ .name = "small", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "of ten" } }});
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 55), bench.outputs[0].?.int);
    try testing.expectEqual(@as(i64, 3628800), bench.outputs[1].?.int);
    try testing.expectEqualStrings("sum of ten", bench.outputs[2].?.string);
    try testing.expectEqual(@as(i64, 3), bench.outputs[3].?.int);
}

test "checked string intrinsics slice and inspect UTF-8 bytes" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.prefix = input.text[0:2]
        \\    output.middle = input.text[2:6]
        \\    output.byte = input.text.byte_at(2)
        \\
    , .{
        .inputs = &.{.{ .name = "text", .declared = .string }},
        .outputs = &.{
            .{ .name = "prefix", .declared = .string },
            .{ .name = "middle", .declared = .string },
            .{ .name = "byte", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "ab\xF0\x9F\x99\x82cd\nnext" } }});
    try testing.expect(result == .success);
    try testing.expectEqualStrings("ab", bench.outputs[0].?.string);
    try testing.expectEqualStrings("\xF0\x9F\x99\x82", bench.outputs[1].?.string);
    try testing.expectEqual(@as(i64, 0xf0), bench.outputs[2].?.int);
}

test "string intrinsics implement multiline UTF-8-safe edits" {
    var bench = try Bench.setup(
        \\func continuation(byte: Int) -> Bool:
        \\    return byte >= 128 and byte < 192
        \\
        \\func previous(value: String, cursor: Int) -> Int:
        \\    var at = cursor - 1
        \\    while at > 0 and continuation(value.byte_at(at)):
        \\        at = at - 1
        \\    return at
        \\
        \\func evaluate(input: Input, output: Output):
        \\    if input.insert:
        \\        output.text = input.text[0:input.cursor] + input.added + input.text[input.cursor:len(input.text)]
        \\        output.cursor = input.cursor + len(input.added)
        \\    else:
        \\        let before = previous(input.text, input.cursor)
        \\        output.text = input.text[0:before] + input.text[input.cursor:len(input.text)]
        \\        output.cursor = before
        \\
    , .{
        .inputs = &.{
            .{ .name = "insert", .declared = .boolean },
            .{ .name = "text", .declared = .string },
            .{ .name = "cursor", .declared = .int },
            .{ .name = "added", .declared = .string },
        },
        .outputs = &.{
            .{ .name = "text", .declared = .string },
            .{ .name = "cursor", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const original = "A\xF0\x9F\x99\x82\nB";
    const inserted = try bench.evaluate(&.{
        .{ .value = .{ .boolean = true } },
        .{ .value = .{ .string = original } },
        .{ .value = .{ .int = 5 } },
        .{ .value = .{ .string = "x" } },
    });
    try testing.expect(inserted == .success);
    try testing.expectEqualStrings("A\xF0\x9F\x99\x82x\nB", bench.outputs[0].?.string);
    try testing.expectEqual(@as(i64, 6), bench.outputs[1].?.int);

    const erased = try bench.evaluate(&.{
        .{ .value = .{ .boolean = false } },
        .{ .value = .{ .string = original } },
        .{ .value = .{ .int = 5 } },
        .{ .value = .{ .string = "" } },
    });
    try testing.expect(erased == .success);
    try testing.expectEqualStrings("A\nB", bench.outputs[0].?.string);
    try testing.expectEqual(@as(i64, 1), bench.outputs[1].?.int);
}

test "checked string intrinsics trap on bounds and UTF-8 splits" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        output.text = input.text[-1:0]
        \\    elif input.mode == 2:
        \\        output.text = input.text[0:len(input.text) + 1]
        \\    elif input.mode == 3:
        \\        output.text = input.text[0:2]
        \\    else:
        \\        output.byte = input.text.byte_at(len(input.text))
        \\
    , .{
        .inputs = &.{
            .{ .name = "mode", .declared = .int },
            .{ .name = "text", .declared = .string },
        },
        .outputs = &.{
            .{ .name = "text", .declared = .string },
            .{ .name = "byte", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const text: InputValue = .{ .value = .{ .string = "a\xF0\x9F\x99\x82b" } };
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 1 } }, text }, .string_bounds);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 2 } }, text }, .string_bounds);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 3 } }, text }, .string_boundary);
    try expectTrap(&bench, &.{ .{ .value = .{ .int = 4 } }, text }, .string_bounds);
}

test "string intrinsics reject wrong argument types" {
    var result = try compile_mod.compile(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    output.text = 1[0:1]
        \\
    , .{ .outputs = &.{.{ .name = "text", .declared = .string }} }, .{});
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqualStrings("luce.sema.index", result.failure.at(0).?.code);
}

test "an unavailable read input gates evaluation" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    output.doubled = input.value * 2
        \\
    , .{
        .inputs = &.{.{ .name = "value", .declared = .int }},
        .outputs = &.{.{ .name = "doubled", .declared = .int }},
    }, .{});
    defer bench.deinit();

    try testing.expectEqual(Result.unavailable, try bench.evaluate(&.{.unavailable}));
    try testing.expectEqual(@as(?RuntimeValue, null), bench.outputs[0]);

    const available = try bench.evaluate(&.{.{ .value = .{ .int = 21 } }});
    try testing.expect(available == .success);
    try testing.expectEqual(@as(i64, 42), bench.outputs[0].?.int);
}

fn expectTrap(bench: *Bench, inputs: []const InputValue, code: ir.TrapCode) !void {
    const result = try bench.evaluate(inputs);
    try testing.expect(result == .trap);
    try testing.expectEqual(code, result.trap.code);
}

test "checked arithmetic and conversions trap" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        output.value = 9223372036854775807 + input.mode
        \\    elif input.mode == 2:
        \\        output.value = 1 / (input.mode - 2)
        \\    elif input.mode == 3:
        \\        output.value = Int(1.0e300)
        \\    elif input.mode == 4:
        \\        assert(input.mode == 0)
        \\    elif input.mode == 5:
        \\        trap("torn seam")
        \\    else:
        \\        output.value = 0
        \\
    , .{
        .inputs = &.{.{ .name = "mode", .declared = .int }},
        .outputs = &.{.{ .name = "value", .declared = .int }},
    }, .{});
    defer bench.deinit();

    try expectTrap(&bench, &.{.{ .value = .{ .int = 1 } }}, .integer_overflow);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 2 } }}, .divide_by_zero);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 3 } }}, .conversion_range);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 4 } }}, .assertion_failed);

    const explicit = try bench.evaluate(&.{.{ .value = .{ .int = 5 } }});
    try testing.expect(explicit == .trap);
    try testing.expectEqual(ir.TrapCode.explicit_trap, explicit.trap.code);
    try testing.expectEqualStrings("torn seam", explicit.trap.message);

    const fine = try bench.evaluate(&.{.{ .value = .{ .int = 0 } }});
    try testing.expect(fine == .success);
}

test "the step budget stops an infinite loop" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    var spinning = 0
        \\    while true:
        \\        spinning = spinning + 1
        \\    output.value = spinning
        \\
    , .{ .outputs = &.{.{ .name = "value", .declared = .int }} }, .{});
    defer bench.deinit();
    try expectTrap(&bench, &.{}, .step_budget_exhausted);
}

test "unbounded recursion hits the call depth limit" {
    var bench = try Bench.setup(
        \\func dive(depth: Int) -> Int:
        \\    return dive(depth + 1)
        \\
        \\func evaluate(input: Input, output: Output):
        \\    output.value = dive(0)
        \\
    , .{ .outputs = &.{.{ .name = "value", .declared = .int }} }, .{});
    defer bench.deinit();
    try expectTrap(&bench, &.{}, .call_depth_exceeded);
}

test "unwritten outputs stay unwritten; conditional writes land" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.flag:
        \\        output.first = 1
        \\    else:
        \\        output.second = 2
        \\
    , .{
        .inputs = &.{.{ .name = "flag", .declared = .boolean }},
        .outputs = &.{
            .{ .name = "first", .declared = .int },
            .{ .name = "second", .declared = .int },
        },
    }, .{});
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .boolean = true } }});
    try testing.expect(result == .success);
    try testing.expectEqual(@as(i64, 1), bench.outputs[0].?.int);
    try testing.expectEqual(@as(?RuntimeValue, null), bench.outputs[1]);
}

test "fabric builtins record complete texel intents" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    let adder = create_texel(input.name)
        \\    texel_input(adder, "left", "int")
        \\    texel_input(adder, "right", "int")
        \\    texel_output(adder, "value", "int")
        \\    texel_evaluator(adder, "luce")
        \\    texel_content(adder, "func evaluate(input: Input, output: Output):\n    output.value = input.left + input.right\n")
        \\    let label = create_texel("banner")
        \\    texel_output(label, "text", "text")
        \\    texel_set(label, "text", "hello")
        \\    output.made = 2
        \\
    , .{
        .inputs = &.{.{ .name = "name", .declared = .string }},
        .outputs = &.{.{ .name = "made", .declared = .int }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .string = "adder" } }});
    try testing.expect(result == .success);
    const intents = result.success.intents.texels.items;
    try testing.expectEqual(@as(usize, 2), intents.len);

    try testing.expectEqualStrings("adder", intents[0].name);
    try testing.expectEqual(@as(usize, 2), intents[0].inputs.items.len);
    try testing.expectEqualStrings("left", intents[0].inputs.items[0].name);
    try testing.expectEqual(@as(usize, 1), intents[0].outputs.items.len);
    try testing.expectEqualStrings("luce", intents[0].evaluator.?);
    try testing.expect(std.mem.indexOf(u8, intents[0].content.?, "input.left + input.right") != null);

    try testing.expectEqualStrings("banner", intents[1].name);
    try testing.expectEqualStrings("hello", intents[1].sets.items[0].value.text);
}

test "create_image records an image intent and validates its shape" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.bad:
        \\        create_image("", 0)
        \\    else:
        \\        create_image("fresh.img", 64)
        \\
    , .{
        .inputs = &.{.{ .name = "bad", .declared = .boolean }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();

    const result = try bench.evaluate(&.{.{ .value = .{ .boolean = false } }});
    try testing.expect(result == .success);
    const images = result.success.intents.images.items;
    try testing.expectEqual(@as(usize, 1), images.len);
    try testing.expectEqualStrings("fresh.img", images[0].path);
    try testing.expectEqual(@as(u64, 64), images[0].pages);

    try expectTrap(&bench, &.{.{ .value = .{ .boolean = true } }}, .invalid_image);
}

test "fabric builtins trap on bad handles and types, and need the gate" {
    var bench = try Bench.setup(
        \\func evaluate(input: Input, output: Output):
        \\    if input.mode == 1:
        \\        texel_output(7, "value", "int")
        \\    else:
        \\        let t = create_texel("x")
        \\        texel_output(t, "value", "matrix")
        \\
    , .{
        .inputs = &.{.{ .name = "mode", .declared = .int }},
    }, .{ .allow_fabric = true });
    defer bench.deinit();
    try expectTrap(&bench, &.{.{ .value = .{ .int = 1 } }}, .invalid_handle);
    try expectTrap(&bench, &.{.{ .value = .{ .int = 2 } }}, .invalid_port_type);

    // Without the gate, the builtins do not exist.
    var gated = try compile_mod.compile(testing.allocator,
        \\func evaluate(input: Input, output: Output):
        \\    let t = create_texel("x")
        \\
    , .{}, .{});
    defer gated.deinit();
    try testing.expect(gated == .failure);
    try testing.expectEqualStrings("luce.sema.fabric", gated.failure.at(0).?.code);
}

/// A scripted host for the v2 builtins: collected prints, fixed
/// arguments, one readable file, and a queue of key events driving a
/// recorded terminal.
const TestHost = struct {
    printed: std.ArrayList(u8) = .empty,
    screen: std.ArrayList(u8) = .empty,
    arguments: []const []const u8 = &.{},
    file_path: []const u8 = "",
    file_content: []const u8 = "",
    written_path: []const u8 = "",
    written_content: []const u8 = "",
    fail_write: bool = false,
    keys: []const backend.KeyEvent = &.{},
    next_key: usize = 0,

    fn deinit(self: *TestHost) void {
        self.printed.deinit(testing.allocator);
        self.screen.deinit(testing.allocator);
    }

    fn printLine(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.printed.appendSlice(testing.allocator, text);
        try self.printed.append(testing.allocator, '\n');
    }

    fn argCount(context: *anyopaque) u32 {
        const self: *TestHost = @ptrCast(@alignCast(context));
        return @intCast(self.arguments.len);
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (index >= self.arguments.len) return null;
        return try arena.dupe(u8, self.arguments[index]);
    }

    fn readFile(context: *anyopaque, arena: Allocator, path: []const u8) error{OutOfMemory}!backend.FileRead {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, self.file_path)) return .failed;
        return .{ .content = try arena.dupe(u8, self.file_content) };
    }

    fn writeFile(context: *anyopaque, path: []const u8, content: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.fail_write) return false;
        self.written_path = path;
        self.written_content = content;
        return true;
    }

    fn fileExists(context: *anyopaque, path: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        return std.mem.eql(u8, path, self.file_path);
    }

    fn rows(context: *anyopaque) i64 {
        _ = context;
        return 24;
    }

    fn cols(context: *anyopaque) i64 {
        _ = context;
        return 80;
    }

    fn record(self: *TestHost, comptime format: []const u8, values: anytype) error{OutOfMemory}!void {
        const line = try std.fmt.allocPrint(testing.allocator, format, values);
        defer testing.allocator.free(line);
        try self.screen.appendSlice(testing.allocator, line);
    }

    fn clear(context: *anyopaque) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[clear]", .{});
    }

    fn move(context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[move {d},{d}]", .{ row, col });
    }

    fn style(context: *anyopaque, foreground: i64, background: i64, bold: bool) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[style {d},{d},{}]", .{ foreground, background, bold });
    }

    fn write(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("{s}", .{text});
    }

    fn flush(context: *anyopaque) error{OutOfMemory}!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try self.record("[flush]", .{});
    }

    fn key(context: *anyopaque, arena: Allocator) error{OutOfMemory}!backend.KeyEvent {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (self.next_key >= self.keys.len) return .{ .name = "none" };
        const event = self.keys[self.next_key];
        self.next_key += 1;
        return .{
            .name = try arena.dupe(u8, event.name),
            .text = try arena.dupe(u8, event.text),
        };
    }

    fn host(self: *TestHost) backend.Host {
        return .{
            .context = self,
            .printFn = printLine,
            .argCountFn = argCount,
            .argFn = argAt,
            .readFileFn = readFile,
            .writeFileFn = writeFile,
            .fileExistsFn = fileExists,
            .terminal = .{
                .context = self,
                .rowsFn = rows,
                .colsFn = cols,
                .clearFn = clear,
                .moveFn = move,
                .styleFn = style,
                .writeFn = write,
                .flushFn = flush,
                .keyFn = key,
            },
        };
    }
};

const hosted_options: types.CompileOptions = .{ .entry_mode = .script, .allow_host = true };

test "host builtins fail closed without a host" {
    var bench = try Bench.setup(
        \\func main():
        \\    print("hello")
        \\
    , .{}, hosted_options);
    defer bench.deinit();
    try expectTrap(&bench, &.{}, .host_unavailable);
}

test "print, arguments, and files flow through the host" {
    var bench = try Bench.setup(
        \\func main():
        \\    print("args: " + Int_to_text(arg_count()))
        \\    let path = arg(0)
        \\    if file_exists(path):
        \\        print(file_read(path))
        \\    assert(file_write("out.txt", "saved"))
        \\
        \\func Int_to_text(value: Int) -> String:
        \\    if value == 0:
        \\        return "0"
        \\    var text = ""
        \\    var left = value
        \\    while left > 0:
        \\        let digit = left % 10
        \\        text = "0123456789"[digit:digit + 1] + text
        \\        left = left / 10
        \\    return text
        \\
    , .{}, hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .arguments = &.{"notes.txt"},
        .file_path = "notes.txt",
        .file_content = "file body",
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(&.{}, host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings("args: 1\nfile body\n", host.printed.items);
    try testing.expectEqualStrings("out.txt", host.written_path);
    try testing.expectEqualStrings("saved", host.written_content);
}

test "argument reads out of range trap and failed writes report false" {
    var bench = try Bench.setup(
        \\func main():
        \\    if file_write("out.txt", "ignored"):
        \\        print("wrote")
        \\    let missing = arg(5)
        \\
    , .{}, hosted_options);
    defer bench.deinit();

    var host: TestHost = .{ .fail_write = true };
    defer host.deinit();
    const result = try bench.evaluateHosted(&.{}, host.host());
    try testing.expectEqual(ir.TrapCode.argument_bounds, result.trap.code);
    try testing.expectEqualStrings("", host.printed.items);
}

test "terminal builtins drive the host screen and key queue" {
    var bench = try Bench.setup(
        \\func main():
        \\    term_clear()
        \\    term_move(1, 2)
        \\    term_style(114, -1, true)
        \\    term_write("hi ")
        \\    term_write(key_read())
        \\    term_write(key_text())
        \\    let quit = key_read()
        \\    term_flush()
        \\    print(quit)
        \\    print(Int_pair(term_rows(), term_cols()))
        \\
        \\func Int_pair(rows: Int, cols: Int) -> String:
        \\    var text = ""
        \\    if rows == 24 and cols == 80:
        \\        text = "24x80"
        \\    return text
        \\
    , .{}, hosted_options);
    defer bench.deinit();

    var host: TestHost = .{
        .keys = &.{
            .{ .name = "text", .text = "λ" },
            .{ .name = "ctrl_q" },
        },
    };
    defer host.deinit();
    const result = try bench.evaluateHosted(&.{}, host.host());
    try testing.expect(result == .success);
    try testing.expectEqualStrings(
        "[clear][move 1,2][style 114,-1,true]hi textλ[flush]",
        host.screen.items,
    );
    try testing.expectEqualStrings("ctrl_q\n24x80\n", host.printed.items);
}

// ---------------------------------------------------------------------------
// Collections, explicit memory, and conversions
// ---------------------------------------------------------------------------

const script_options: types.CompileOptions = .{ .entry_mode = .script };

fn expectLeaks(bench: *Bench, wanted: u32) !void {
    const result = try bench.evaluate(&.{});
    try testing.expect(result == .success);
    try testing.expectEqual(wanted, result.success.leaked_objects);
}

test "lists grow, index, slice, iterate, and free explicitly" {
    var bench = try Bench.setup(
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    assert(len(xs) == 3)
        \\    xs.append(9)
        \\    assert(xs[3] == 9)
        \\    xs[0] = 30
        \\    assert(xs[0] == 30)
        \\    xs.insert(1, 7)
        \\    assert(xs[1] == 7)
        \\    xs.remove(0)
        \\    assert(xs[0] == 7)
        \\    assert(xs.pop() == 9)
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    assert(total == 10)
        \\    let mid = xs[1:]
        \\    assert(len(mid) == 2)
        \\    assert(mid[0] == 1)
        \\    assert(mid != xs)
        \\    assert(xs == xs)
        \\    free(mid)
        \\    free(xs)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "maps upsert, look up, and iterate keys in insertion order" {
    var bench = try Bench.setup(
        \\func main():
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    ages["ada"] = 37
        \\    assert(len(ages) == 2)
        \\    assert(ages["ada"] == 37)
        \\    assert(ages.has("alan"))
        \\    var joined = new Builder()
        \\    for key in ages:
        \\        joined.append(key)
        \\    assert(str(joined) == "adaalan")
        \\    ages.remove("alan")
        \\    assert(not ages.has("alan"))
        \\    ages.remove("ghost")
        \\    assert(len(ages) == 1)
        \\    free(ages)
        \\    free(joined)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "arrays are fixed, zeroed, multi-dimensional, and typed" {
    var bench = try Bench.setup(
        \\func corner(grid: Array(Int, _, _)) -> Int:
        \\    return grid[grid.dim(0) - 1, grid.dim(1) - 1]
        \\
        \\func main():
        \\    var grid = new Array(Int, 3, 4)
        \\    assert(grid.dim(0) == 3)
        \\    assert(grid.dim(1) == 4)
        \\    assert(len(grid) == 3)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(corner(grid) == 7)
        \\    var row = new Array(Float, 4)
        \\    row[0] = 2.5
        \\    var total = 0.0
        \\    for value in row:
        \\        total = total + value
        \\    assert(total == 2.5)
        \\    free(grid)
        \\    free(row)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "conversions: str, parse_int, parse_float, chr, ord" {
    var bench = try Bench.setup(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(-7) == "-7")
        \\    assert(str(true) == "true")
        \\    assert(str(2.5) == "2.5")
        \\    assert(parse_int("123") == 123)
        \\    assert(parse_int("-9") == -9)
        \\    assert(parse_float("2.5") == 2.5)
        \\    assert(chr(65) == "A")
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\    assert(ord("A") == 65)
        \\
    , .{}, script_options);
    defer bench.deinit();
    const result = try bench.evaluate(&.{});
    try testing.expect(result == .success);
}

test "structs and nested collections share objects by reference" {
    var bench = try Bench.setup(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var inner = [1, 2]
        \\    var bag = Bag(label = "first", items = give inner)
        \\    let same_bag = bag
        \\    same_bag.items.append(3)
        \\    assert(len(bag.items) == 3)
        \\    var nested = new List(List(Int))
        \\    nested.append(copy bag.items)
        \\    nested[0].append(4)
        \\    assert(len(nested[0]) == 4)
        \\    assert(len(bag.items) == 3)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "collection misuse traps with stable codes" {
    const cases = [_]struct { source: []const u8, code: ir.TrapCode }{
        .{ .source =
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs[5]
        \\
        , .code = .index_bounds },
        .{ .source =
        \\func main():
        \\    var xs: List(Int) = []
        \\    let bad = xs.pop()
        \\
        , .code = .empty_collection },
        .{ .source =
        \\func main():
        \\    var m = new Map(String, Int)
        \\    let bad = m["ghost"]
        \\
        , .code = .key_missing },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    view.append(2)
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var cells = new Array(List(Int), 2)
        \\    cells[0].append(1)
        \\
        , .code = .null_object },
        .{ .source =
        \\func main():
        \\    let bad = parse_int("not a number")
        \\
        , .code = .parse_failed },
        .{ .source =
        \\func main():
        \\    let bad = chr(11141111)
        \\
        , .code = .bad_codepoint },
        .{ .source =
        \\func main():
        \\    var grid = new Array(Int, 2, 2)
        \\    grid[2, 0] = 1
        \\
        , .code = .index_bounds },
    };
    for (cases) |case| {
        var bench = try Bench.setup(case.source, .{}, script_options);
        defer bench.deinit();
        try expectTrap(&bench, &.{}, case.code);
    }
}

test "S33: nothing leaks — scope ownership frees what free() used to" {
    var bench = try Bench.setup(
        \\func main():
        \\    let kept = [1, 2, 3]
        \\    let copied = kept[0:2]
        \\    var released = new Builder()
        \\    free(released)
        \\    assert(len(copied) == 2)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "the explicit frame stack survives deep recursion" {
    var result = try compile_mod.compile(testing.allocator,
        \\func dive(left: Int) -> Int:
        \\    if left == 0:
        \\        return 0
        \\    return dive(left - 1)
        \\
        \\func main():
        \\    assert(dive(50000) == 0)
        \\
    , .{}, script_options);
    defer result.deinit();
    try testing.expect(result == .success);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deep = try backend.evaluate(arena.allocator(), &result.success, &.{}, &.{}, .{
        .steps = 10_000_000,
        .call_depth = 60_000,
    });
    try testing.expect(deep == .success);

    // The same program under a tighter policy traps instead.
    _ = arena.reset(.retain_capacity);
    const shallow = try backend.evaluate(arena.allocator(), &result.success, &.{}, &.{}, .{
        .steps = 10_000_000,
        .call_depth = 1_000,
    });
    try testing.expectEqual(ir.TrapCode.call_depth_exceeded, shallow.trap.code);
}

test "string methods: search, case, trim, replace, repeat, split" {
    var bench = try Bench.setup(
        \\func main():
        \\    let text = "  Hello, Luce World  "
        \\    let cleaned = text.trim()
        \\    assert(cleaned == "Hello, Luce World")
        \\    assert(cleaned.find("Luce") == 7)
        \\    assert(cleaned.find("zig") == -1)
        \\    assert(cleaned.contains("World"))
        \\    assert(cleaned.starts_with("Hello"))
        \\    assert(cleaned.ends_with("World"))
        \\    assert(cleaned.lower() == "hello, luce world")
        \\    assert(cleaned.upper() == "HELLO, LUCE WORLD")
        \\    assert(cleaned.replace("Luce", "brave") == "Hello, brave World")
        \\    assert("ab".repeat(3) == "ababab")
        \\    assert("x".repeat(0) == "")
        \\    assert("na".byte_at(0) == 110)
        \\    var words = cleaned.replace(",", "").split("")
        \\    assert(len(words) == 3)
        \\    assert(words[0] == "Hello")
        \\    var csv = "a;b;;c".split(";")
        \\    assert(len(csv) == 4)
        \\    assert(csv[2] == "")
        \\    assert(csv.join("|") == "a|b||c")
        \\    free(words)
        \\    free(csv)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}

test "list and array methods: sort, reverse, find, contains, fill, clear" {
    var bench = try Bench.setup(
        \\func main():
        \\    var xs = [3, 1, 4, 1, 5]
        \\    xs.sort()
        \\    assert(xs[0] == 1)
        \\    assert(xs[4] == 5)
        \\    xs.reverse()
        \\    assert(xs[0] == 5)
        \\    assert(xs.find(4) == 1)
        \\    assert(xs.find(9) == -1)
        \\    assert(xs.contains(3))
        \\    assert(not xs.contains(9))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\    var names = ["cyan", "amber"]
        \\    names.sort()
        \\    assert(names[0] == "amber")
        \\    var row = new Array(Int, 4)
        \\    row.fill(7)
        \\    assert(row[3] == 7)
        \\    assert(row.contains(7))
        \\    row[1] = 2
        \\    row.sort()
        \\    assert(row[0] == 2)
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    var listed = ages.keys()
        \\    assert(listed.join(",") == "ada,alan")
        \\    ages.clear()
        \\    assert(len(ages) == 0)
        \\    free(xs)
        \\    free(names)
        \\    free(row)
        \\    free(ages)
        \\    free(listed)
        \\
    , .{}, script_options);
    defer bench.deinit();
    try expectLeaks(&bench, 0);
}
