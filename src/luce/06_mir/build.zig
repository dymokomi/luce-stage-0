//! Building the MIR: the emitter, and the assembly of a `Program`.
//!
//! Stage 4 decides *what* a function does — which name, which type,
//! which intrinsic, which ownership verb — and records the decision
//! here as it goes.  Nothing in this file looks at an AST, a scope, or
//! a diagnostic: a `Lowering` is a tape of already-decided operations,
//! and every method on it is mechanical.
//!
//! What stage 4 hands over is `Lowered`, a plain value: struct
//! layouts, heap-type shapes, the constant pool, the entry index, and
//! one open `Lowering` per function.  `build` closes
//! them — every block gets a terminator, block membership freezes into
//! `Block` slices, each instruction's source *offset* becomes a
//! line-and-column `Origin`, and the whole thing becomes a
//! `mir.Program`.  It reads only that value; it never calls back into
//! the checker.
//!
//! The hand-over types live here rather than in `04_semantics`
//! because they are made of MIR — instructions, registers, locals,
//! types — so defining them beside the representation keeps the
//! imports pointing one way, stage 4 to stage 6, the way the pipeline
//! runs.
//!
//! Everything a `Lowering` allocates comes from the program arena, so
//! the hand-over needs no teardown and no lifetime rule beyond the
//! program's own.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const types = @import("../support/types.zig");
const defs = @import("defs.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Register = defs.Register;
const BlockId = defs.BlockId;
const LocalId = defs.LocalId;

pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------------------
// The constant pool
// ---------------------------------------------------------------------------

/// The program's string and byte constants, interned: one slot per
/// distinct value, so `const_string` is an index and two identical
/// literals cost one copy.
///
/// Interning happens while stage 4 checks — a string literal is a
/// constant the moment it type-checks — but the pool is `Program`'s,
/// so it lives here.  The index is a hash map because a linear scan
/// made a program of N distinct literals cost N² comparisons, which a
/// page of `print("...")` lines can feel.
pub const ConstantPool = struct {
    /// Where the constants themselves live: the program arena.
    arena: Allocator,
    /// Where the lookup index lives; freed with `deinit`.
    scratch: Allocator,
    items: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *ConstantPool) void {
        self.index.deinit(self.scratch);
    }

    pub fn intern(self: *ConstantPool, bytes: []const u8) Error!u32 {
        if (self.index.get(bytes)) |slot| return slot;
        const owned = try self.arena.dupe(u8, bytes);
        const slot: u32 = @intCast(self.items.items.len);
        try self.items.append(self.arena, owned);
        // Keyed on the arena copy: the caller's bytes may be a slice
        // of an AST that outlives nothing in particular.
        try self.index.put(self.scratch, owned, slot);
        return slot;
    }
};

// ---------------------------------------------------------------------------
// The tape
// ---------------------------------------------------------------------------

/// A basic block while it is still open: the registers written into it,
/// in order, and whether a terminator has closed it.  `build` freezes
/// each one into a `mir.Block`.
pub const OpenBlock = struct {
    items: std.ArrayList(Register) = .empty,
    terminated: bool = false,
};

/// One function's decided lowering, still open.
///
/// A register *is* the index of the instruction that produced it, so
/// `emit` is the only way to make one and the order of calls is the
/// order of the program.  Registers never cross a block boundary —
/// anything a later block needs goes through a local, which is what
/// `spill`/`load` are for.
pub const Lowering = struct {
    /// The program arena: everything here outlives the build.
    arena: Allocator,
    /// The program's constant pool, shared by every function.  A
    /// recording-time input, like `structs`: `build` reads the
    /// finished pool off `Lowered` and never follows this.
    pool: *ConstantPool,
    /// The program's struct layouts, settled before any lowering runs.
    structs: []const StructLayout,

    name: []const u8,
    parameter_count: u32 = 0,
    return_type: Type,
    /// Written `-> T!` or `-> !` (docs/FAILURE.md).
    fallible: bool = false,
    /// Stage 1's registry entry every origin offset indexes.  `build`
    /// turns the offsets into lines and columns through it, and names
    /// the function's file from it for tracebacks.
    file: source_mod.FileId,

    locals: std.ArrayList(defs.Local) = .empty,
    instructions: std.ArrayList(defs.Instruction) = .empty,
    result_types: std.ArrayList(Type) = .empty,
    blocks: std.ArrayList(OpenBlock) = .empty,
    /// Debug info: the source offset stamped on every instruction,
    /// parallel to `instructions`.  Statement granularity — the caller
    /// sets `origin` once per statement.
    origin_offsets: std.ArrayList(u32) = .empty,

    /// The block `emit` appends to.
    current: BlockId = 0,
    /// The source offset the next instruction is stamped with.
    origin: u32 = 0,

    // Blocks ---------------------------------------------------------------

    /// Open a block and make it current.
    pub fn openBlock(self: *Lowering) Error!void {
        try self.blocks.append(self.arena, .{});
        self.current = @intCast(self.blocks.items.len - 1);
    }

    /// Reserve a block to jump to later, without leaving the current one.
    pub fn reserveBlock(self: *Lowering) Error!BlockId {
        try self.blocks.append(self.arena, .{});
        return @intCast(self.blocks.items.len - 1);
    }

    pub fn switchTo(self: *Lowering, block: BlockId) void {
        self.current = block;
    }

    /// Record one instruction and hand back the register holding its
    /// result.  An instruction recorded after its block's terminator
    /// still enters the pool — the register numbering must not shift
    /// under anything already recorded — but is left out of the block:
    /// the code is unreachable, and a checker that keeps walking after
    /// a `return` must not be able to make a malformed block.  Stage 7
    /// drops what no block claims.
    pub fn emit(self: *Lowering, instruction: defs.Instruction, result: Type) Error!Register {
        const register: Register = @intCast(self.instructions.items.len);
        try self.instructions.append(self.arena, instruction);
        try self.result_types.append(self.arena, result);
        try self.origin_offsets.append(self.arena, self.origin);
        const block = &self.blocks.items[self.current];
        if (!block.terminated) {
            try block.items.append(self.arena, register);
            if (instruction.isTerminator()) block.terminated = true;
        }
        return register;
    }

    // Reading back what was recorded ---------------------------------------

    pub fn resultType(self: *const Lowering, register: Register) Type {
        return self.result_types.items[register];
    }

    pub fn localType(self: *const Lowering, local: LocalId) Type {
        return self.locals.items[local].local_type;
    }

    /// Does this slot have to give its string bytes and struct field
    /// runs back when it dies (docs/STRINGS.md)?
    pub fn localOwnsStorage(self: *const Lowering, local: LocalId) bool {
        return self.locals.items[local].owns_storage;
    }

    /// Retract a temporary's claim on its storage: something else took
    /// it and will give it back instead (docs/STRINGS.md).
    ///
    /// Only ever called on a hidden slot that is written and never
    /// loaded, so the store into it becomes dead and `07_optimize`
    /// removes it — a slot that stopped owning storage would hand a
    /// load the register shape, and a string's form does not survive
    /// that round trip.
    pub fn disownStorage(self: *Lowering, local: LocalId) void {
        self.locals.items[local].owns_storage = false;
    }

    // Locals ---------------------------------------------------------------

    /// A named slot.  The name reaches the `.lcm` and a traceback, so it
    /// is duped into the program arena.
    pub fn addLocal(
        self: *Lowering,
        name: []const u8,
        local_type: Type,
        owns_storage: bool,
    ) Error!LocalId {
        const local: LocalId = @intCast(self.locals.items.len);
        try self.locals.append(self.arena, .{
            .name = try self.arena.dupe(u8, name),
            .local_type = local_type,
            .owns_storage = owns_storage,
        });
        return local;
    }

    /// Every hidden local shares one name: it is never written to, and
    /// a fresh copy per spill is a copy per operator in a large
    /// function.
    const hidden_name = "(temporary)";

    /// An unnamed slot the lowering needs for itself — a spill, a loop
    /// counter, a statement temporary.
    pub fn hiddenLocal(self: *Lowering, local_type: Type, owns_storage: bool) Error!LocalId {
        const local: LocalId = @intCast(self.locals.items.len);
        try self.locals.append(self.arena, .{
            .name = hidden_name,
            .local_type = local_type,
            .owns_storage = owns_storage,
        });
        return local;
    }

    pub fn load(self: *Lowering, local: LocalId) Error!Register {
        return self.emit(.{ .local_get = local }, self.localType(local));
    }

    pub fn store(self: *Lowering, local: LocalId, value: Register) Error!void {
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value } }, .none);
    }

    /// Carry a value across a block boundary: park it in a hidden local
    /// now, `load` it back where it is needed.
    pub fn spill(self: *Lowering, value: Register, value_type: Type) Error!LocalId {
        // A spill carries a borrow across a branch and dies with the
        // statement that made it, so it owns nothing.
        const local = try self.hiddenLocal(value_type, false);
        try self.store(local, value);
        return local;
    }

    /// The same crossing, for a value that is *this frame's own*: a
    /// fallible call's result has to survive the branch on its outcome
    /// (docs/FAILURE.md), and unlike a spill it arrives owning
    /// something.
    ///
    /// So the slot that carries it is the slot that owns it — one
    /// place rather than two, and the caller registers it as the
    /// statement's temporary on the side where the call returned.
    /// **A borrowing slot would not do**, and not only for tidiness: a
    /// slot that owns its storage holds a whole `runtime.Value`, which
    /// is the only shape short text survives in, and one that holds
    /// the register shape instead would carry a pointer into whatever
    /// scratch the call answered into (docs/STRINGS.md).
    pub fn carry(
        self: *Lowering,
        value: Register,
        value_type: Type,
        owns_storage: bool,
    ) Error!LocalId {
        const local = try self.hiddenLocal(value_type, owns_storage);
        try self.store(local, value);
        return local;
    }

    // Ownership plumbing ----------------------------------------------------
    //
    // Which binding owns which object is stage 4's to decide; saying it
    // in instructions is mechanical.

    pub fn bind(self: *Lowering, local: LocalId, value: Register) Error!void {
        _ = try self.emit(.{ .object_bind = .{ .local = local, .value = value } }, .none);
    }

    pub fn unbind(self: *Lowering, local: LocalId, value: Register) Error!void {
        _ = try self.emit(.{ .object_unbind = .{ .local = local, .value = value } }, .none);
    }

    /// Release one owned local, in whichever of the two senses it
    /// owns something: `objects` frees whatever object in its slot is
    /// still bound to it, `storage` gives its string bytes and struct
    /// field runs back.  Safe on any path and safe twice over — an
    /// object given away or adopted elsewhere is skipped at run time,
    /// and a storage release writes the emptied value back, so a
    /// second one frees nothing (docs/STRINGS.md).
    pub fn release(self: *Lowering, local: LocalId, objects: bool, storage: bool) Error!void {
        if (!objects and !storage) return;
        const value = try self.load(local);
        if (objects) try self.unbind(local, value);
        if (storage) try self.store(local, try self.dropStorage(value));
    }

    /// A copy of `value` whose storage nothing else owns — what a
    /// store into a place outliving this statement takes first.
    pub fn ownStorage(self: *Lowering, value: Register) Error!Register {
        const arguments = try self.arena.alloc(Register, 1);
        arguments[0] = value;
        return self.emit(
            .{ .intrinsic = .{ .kind = .own_storage, .arguments = arguments } },
            self.resultType(value),
        );
    }

    /// `value` with storage that outlives this frame — what `ret` hands
    /// the caller.  Text that fits inside a value lives in the slot
    /// holding it, and a slot dies with its frame, so this is where it
    /// moves out (docs/STRINGS.md).
    pub fn exportStorage(self: *Lowering, value: Register) Error!Register {
        const arguments = try self.arena.alloc(Register, 1);
        arguments[0] = value;
        return self.emit(
            .{ .intrinsic = .{ .kind = .export_storage, .arguments = arguments } },
            self.resultType(value),
        );
    }

    /// Give `value`'s storage back; the result is the emptied value the
    /// place it came from should hold from here on.
    pub fn dropStorage(self: *Lowering, value: Register) Error!Register {
        const arguments = try self.arena.alloc(Register, 1);
        arguments[0] = value;
        return self.emit(
            .{ .intrinsic = .{ .kind = .drop_storage, .arguments = arguments } },
            self.resultType(value),
        );
    }

    /// Park a value in a fresh hidden local that owns it: the objects
    /// in it when `objects` is set, and its storage when `storage` is.
    pub fn park(
        self: *Lowering,
        value: Register,
        value_type: Type,
        objects: bool,
        storage: bool,
    ) Error!LocalId {
        const local = try self.hiddenLocal(value_type, storage);
        try self.store(local, value);
        if (objects) try self.bind(local, value);
        return local;
    }

    /// The zero value of a type, as instructions: numbers zero, bool
    /// false, text empty, structs zeroed field by field, objects null.
    /// What `var name: Type` with no initializer starts at, and the
    /// null object traps on use until something assigns over it (S40).
    pub fn zeroOf(self: *Lowering, of: Type) Error!Register {
        return switch (of) {
            .none => unreachable, // no annotation resolves to None
            .boolean => try self.emit(.{ .const_boolean = false }, .boolean),
            .byte, .short, .int, .long => try self.emit(.{ .const_long = 0 }, of),
            .half, .float, .double => try self.emit(.{ .const_double = 0.0 }, of),
            .string => try self.emit(.{ .const_string = try self.pool.intern("") }, .string),
            .heap => try self.emit(
                .{ .intrinsic = .{ .kind = .null_object, .arguments = &.{} } },
                of,
            ),
            // The zero of a `T?` is absence, and holding it owns
            // nothing (S43) — which is why `var x: T? = none` needs no
            // trap to guard it the way a null object does.
            .optional => try self.emit(
                .{ .intrinsic = .{ .kind = .none_value, .arguments = &.{} } },
                of,
            ),
            .strukt => |layout_index| blk: {
                const layout = self.structs[layout_index];
                const fields = try self.arena.alloc(Register, layout.fields.len);
                for (layout.fields, fields) |field, *slot| {
                    const zero = try self.zeroOf(field.field_type);
                    // `struct_make` keeps what it is given, so a zero
                    // that is only a view of a constant is copied in
                    // and a nested struct's own run moves in whole
                    // (docs/STRINGS.md).
                    slot.* = switch (field.field_type) {
                        .string => try self.ownStorage(zero),
                        else => zero,
                    };
                }
                break :blk try self.emit(
                    .{ .struct_make = .{ .layout = layout_index, .fields = fields } },
                    of,
                );
            },
        };
    }

    // Nested places ----------------------------------------------------------

    /// One step down a nested place: a struct field, or an index into a
    /// container.  Stage 4 records the steps on the way down — it is
    /// the one that knows the types — and `rebuild` puts the place back
    /// together from the leaf.
    pub const Step = union(enum) {
        field: struct { parent: Register, layout: u32, field_index: u32 },
        index: struct { object: Register, subscripts: []Register },
    };

    /// Write `value` back into the place `steps` descended to.  Struct
    /// fields functionally update and carry to the root, which is why
    /// the root local is stored at the end; the first container index
    /// writes in place and stops, because an object is a reference and
    /// everything above it already points at the same thing.
    ///
    /// `value` arrives already owned — the caller is the one that knows
    /// whether the leaf could move — and every step consumes what the
    /// step below it built, so nothing along the chain is copied twice
    /// (docs/STRINGS.md).
    pub fn rebuild(
        self: *Lowering,
        root: LocalId,
        steps: []const Step,
        value: Register,
    ) Error!void {
        var updated = value;
        var at = steps.len;
        while (at > 0) {
            at -= 1;
            switch (steps[at]) {
                .field => |field| {
                    // struct_set copies the parent struct with one
                    // field replaced, so its result type is the parent
                    // register's type.
                    updated = try self.emit(.{ .struct_set = .{
                        .target = field.parent,
                        .layout = field.layout,
                        .field = field.field_index,
                        .value = updated,
                    } }, self.resultType(field.parent));
                },
                .index => |step| {
                    const arguments = try self.arena.alloc(Register, step.subscripts.len + 2);
                    arguments[0] = step.object;
                    @memcpy(arguments[1 .. 1 + step.subscripts.len], step.subscripts);
                    arguments[arguments.len - 1] = updated;
                    _ = try self.emit(
                        .{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } },
                        .none,
                    );
                    return; // the object mutated in place
                },
            }
        }
        // The root's old value is what every parent register above was
        // read out of, so it can only go once the rebuild is complete.
        try self.release(root, false, self.locals.items[root].owns_storage);
        try self.store(root, updated);
    }

    // Terminators -----------------------------------------------------------

    pub fn jump(self: *Lowering, target: BlockId) Error!void {
        _ = try self.emit(.{ .jump = target }, .none);
    }

    pub fn branch(self: *Lowering, condition: Register, then_block: BlockId, else_block: BlockId) Error!void {
        _ = try self.emit(.{ .branch = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        } }, .none);
    }

    pub fn ret(self: *Lowering, value: ?Register) Error!void {
        _ = try self.emit(.{ .ret = value }, .none);
    }

    /// `try` on a call that raised — leave this frame with whatever
    /// the callee already put in the channel.  The releases stand in
    /// the block in front of it.
    pub fn unwind(self: *Lowering) Error!void {
        _ = try self.emit(.unwind, .none);
    }

    /// Did the fallible call or intrinsic in `register` come back
    /// errored?  Must be emitted in the block the call stands in.
    pub fn errored(self: *Lowering, register: Register) Error!Register {
        const arguments = try self.arena.alloc(Register, 1);
        arguments[0] = register;
        return self.emit(
            .{ .intrinsic = .{ .kind = .errored, .arguments = arguments } },
            .boolean,
        );
    }

    /// `catch` handled it: the error and its words are discarded.
    pub fn forget(self: *Lowering) Error!void {
        _ = try self.emit(
            .{ .intrinsic = .{ .kind = .forget, .arguments = &.{} } },
            .none,
        );
    }

    // Control flow ----------------------------------------------------------
    //
    // Structured source constructs, shaped into basic blocks.  Which
    // block a `break` unwinds to is stage 4's business — it holds the
    // ids these hand back — but how many blocks an `if` or a `while`
    // takes, and in what order, is decided here and nowhere else.

    pub const Conditional = struct { then_block: BlockId, else_block: BlockId, merge: BlockId };

    /// `if c:` — branch into the then arm.  Without an else, the false
    /// side lands straight on the merge.
    pub fn openIf(self: *Lowering, condition: Register, has_else: bool) Error!Conditional {
        const then_block = try self.reserveBlock();
        const merge = try self.reserveBlock();
        const else_block = if (has_else) try self.reserveBlock() else merge;
        try self.branch(condition, then_block, else_block);
        self.switchTo(then_block);
        return .{ .then_block = then_block, .else_block = else_block, .merge = merge };
    }

    /// End the then arm and open the else arm.
    pub fn elseArm(self: *Lowering, arms: Conditional) Error!void {
        try self.jump(arms.merge);
        self.switchTo(arms.else_block);
    }

    /// End the last arm and continue after the conditional.
    pub fn closeIf(self: *Lowering, arms: Conditional) Error!void {
        try self.jump(arms.merge);
        self.switchTo(arms.merge);
    }

    pub const WhileLoop = struct { header: BlockId, body: BlockId, exit: BlockId };

    /// `while c:` — the header re-runs the condition every iteration,
    /// so it is a block of its own and the caller lowers the condition
    /// into it.
    pub fn openWhile(self: *Lowering) Error!WhileLoop {
        const header = try self.reserveBlock();
        const body = try self.reserveBlock();
        const exit = try self.reserveBlock();
        try self.jump(header);
        self.switchTo(header);
        return .{ .header = header, .body = body, .exit = exit };
    }

    pub fn enterWhileBody(self: *Lowering, loop: WhileLoop, condition: Register) Error!void {
        try self.branch(condition, loop.body, loop.exit);
        self.switchTo(loop.body);
    }

    pub fn closeWhile(self: *Lowering, loop: WhileLoop) Error!void {
        try self.jump(loop.header);
        self.switchTo(loop.exit);
    }

    /// Give up on a loop whose condition did not check out: the header
    /// still has to terminate, and the code after it still has to be
    /// somewhere.
    pub fn abandonLoop(self: *Lowering, exit: BlockId) Error!void {
        try self.jump(exit);
        self.switchTo(exit);
    }

    pub const CountedLoop = struct {
        index: LocalId,
        limit: LocalId,
        header: BlockId,
        body: BlockId,
        step: BlockId,
        exit: BlockId,
    };

    /// `for i in range(a, b):` — the counter is the caller's named
    /// binding; the limit is a hidden local so the bound is evaluated
    /// once.
    pub fn openCountedLoop(
        self: *Lowering,
        index: LocalId,
        start: Register,
        limit_value: Register,
    ) Error!CountedLoop {
        const limit = try self.hiddenLocal(.long, false);
        try self.store(index, start);
        try self.store(limit, limit_value);

        const header = try self.reserveBlock();
        const body = try self.reserveBlock();
        const step = try self.reserveBlock();
        const exit = try self.reserveBlock();
        try self.jump(header);

        self.switchTo(header);
        const counter = try self.load(index);
        const bound = try self.load(limit);
        const keep_going = try self.emit(.{ .binary = .{
            .op = .less,
            .operand_type = .long,
            .left = counter,
            .right = bound,
        } }, .boolean);
        try self.branch(keep_going, body, exit);
        self.switchTo(body);
        return .{
            .index = index,
            .limit = limit,
            .header = header,
            .body = body,
            .step = step,
            .exit = exit,
        };
    }

    pub fn closeCountedLoop(self: *Lowering, loop: CountedLoop) Error!void {
        try self.jump(loop.step);
        self.switchTo(loop.step);
        try self.advance(loop.index);
        try self.jump(loop.header);
        self.switchTo(loop.exit);
    }

    /// A long local, one higher.
    fn advance(self: *Lowering, counter: LocalId) Error!void {
        const current = try self.load(counter);
        const one = try self.emit(.{ .const_long = 1 }, .long);
        const stepped = try self.emit(.{ .binary = .{
            .op = .add,
            .operand_type = .long,
            .left = current,
            .right = one,
        } }, .long);
        try self.store(counter, stepped);
    }

    pub const Iteration = struct {
        /// The collection, held for the loop's duration.
        object: LocalId,
        /// The position within it.
        position: LocalId,
        header: BlockId = 0,
        body: BlockId = 0,
        step: BlockId = 0,
        exit: BlockId = 0,
    };

    /// `for x in xs:` — the two hidden locals that drive it.  Made
    /// before the caller declares the loop's named bindings, because
    /// that is the order the slots come out in.
    pub fn openIteration(self: *Lowering, object_type: Type) Error!Iteration {
        return .{
            .object = try self.hiddenLocal(object_type, false),
            .position = try self.hiddenLocal(.long, false),
        };
    }

    /// Take the collection, start at zero, and open the header.  The
    /// length is re-read every step, so mutating the collection during
    /// iteration stays bounds-safe.
    pub fn startIteration(self: *Lowering, loop: *Iteration, object: Register) Error!void {
        try self.store(loop.object, object);
        const zero = try self.emit(.{ .const_long = 0 }, .long);
        try self.store(loop.position, zero);

        loop.header = try self.reserveBlock();
        loop.body = try self.reserveBlock();
        loop.step = try self.reserveBlock();
        loop.exit = try self.reserveBlock();
        try self.jump(loop.header);

        self.switchTo(loop.header);
        const collection = try self.load(loop.object);
        const arguments = try self.arena.alloc(Register, 1);
        arguments[0] = collection;
        const length = try self.emit(
            .{ .intrinsic = .{ .kind = .len, .arguments = arguments } },
            .long,
        );
        const at = try self.load(loop.position);
        const keep_going = try self.emit(.{ .binary = .{
            .op = .less,
            .operand_type = .long,
            .left = at,
            .right = length,
        } }, .boolean);
        try self.branch(keep_going, loop.body, loop.exit);
        self.switchTo(loop.body);
    }

    /// What one of the loop's names binds to this iteration: the raw
    /// position, or what `getter` reads from the collection at it.
    pub fn iterationValue(
        self: *Lowering,
        loop: Iteration,
        getter: ?defs.Intrinsic,
        value_type: Type,
    ) Error!Register {
        const collection = try self.load(loop.object);
        const at = try self.load(loop.position);
        const kind = getter orelse return at;
        const arguments = try self.arena.alloc(Register, 2);
        arguments[0] = collection;
        arguments[1] = at;
        return self.emit(.{ .intrinsic = .{ .kind = kind, .arguments = arguments } }, value_type);
    }

    pub fn closeIteration(self: *Lowering, loop: Iteration) Error!void {
        try self.jump(loop.step);
        self.switchTo(loop.step);
        try self.advance(loop.position);
        try self.jump(loop.header);
        self.switchTo(loop.exit);
    }

    pub const ShortCircuit = struct { result: LocalId, right_block: BlockId, merge: BlockId };

    /// `a and b` / `a or b`.  The answer lives in a local because the
    /// two sides are written in different blocks and a register never
    /// crosses one.  `evaluate_right_when` is what the left side has
    /// to be for the right side to run at all.
    pub fn openShortCircuit(
        self: *Lowering,
        left: Register,
        evaluate_right_when: bool,
    ) Error!ShortCircuit {
        const result = try self.hiddenLocal(.boolean, false);
        try self.store(result, left);
        const right_block = try self.reserveBlock();
        const merge = try self.reserveBlock();
        if (evaluate_right_when) {
            try self.branch(left, right_block, merge);
        } else {
            try self.branch(left, merge, right_block);
        }
        self.switchTo(right_block);
        return .{ .result = result, .right_block = right_block, .merge = merge };
    }

    /// `a else b` — the same shape as a short circuit, with the result
    /// typed by the fallback rather than bool: park the present value,
    /// then run the fallback only where `absent` says there was none.
    /// `closeShortCircuit` ends it.
    pub fn openCoalesce(
        self: *Lowering,
        absent: Register,
        present: Register,
        result_type: Type,
    ) Error!ShortCircuit {
        const result = try self.hiddenLocal(result_type, false);
        try self.store(result, present);
        const fallback = try self.reserveBlock();
        const merge = try self.reserveBlock();
        try self.branch(absent, fallback, merge);
        self.switchTo(fallback);
        return .{ .result = result, .right_block = fallback, .merge = merge };
    }

    pub fn closeShortCircuit(self: *Lowering, either: ShortCircuit) Error!Register {
        try self.jump(either.merge);
        self.switchTo(either.merge);
        return self.load(either.result);
    }

    // Closing ---------------------------------------------------------------

    /// Every block a function ends with must terminate; an unreachable
    /// or fall-through end gets an explicit terminator.  A typed
    /// function that fell out of its body traps: stage 4 has already
    /// said so as a diagnostic, and this keeps the shape legal anyway.
    fn seal(self: *Lowering) Error!void {
        for (self.blocks.items, 0..) |*block, index| {
            if (block.terminated and block.items.items.len > 0) continue;
            self.current = @intCast(index);
            block.terminated = false;
            if (self.return_type == .none) {
                try self.ret(null);
            } else {
                _ = try self.emit(.{ .trap = .missing_return }, .none);
            }
        }
    }

    /// Freeze the open blocks into the representation's own.
    fn freezeBlocks(self: *Lowering) Error![]defs.Block {
        const finished = try self.arena.alloc(defs.Block, self.blocks.items.len);
        for (self.blocks.items, finished) |*open, *block| {
            block.* = .{ .items = try open.items.toOwnedSlice(self.arena) };
        }
        self.blocks.deinit(self.arena);
        return finished;
    }
};

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

/// Everything stage 4 hands over, all of it arena-owned.
pub const Lowered = struct {
    structs: []StructLayout,
    heap_types: []types.HeapType,
    /// The constant pool, in the order the checker interned it.
    constants: []const []const u8,
    entry_function: u32,
    functions: []Lowering,
};

/// Close every function and assemble the program.  `program` must
/// already own its arena; `arena` is that arena's allocator.
pub fn build(
    arena: Allocator,
    scratch: Allocator,
    sources: *const source_mod.Sources,
    lowered: Lowered,
    program: *defs.Program,
) Error!void {
    // One display name per file, not per function: a module of forty
    // functions should not dupe its path forty times.
    var file_names: std.AutoHashMapUnmanaged(source_mod.FileId, []const u8) = .empty;
    defer file_names.deinit(scratch);

    const functions = try arena.alloc(defs.Function, lowered.functions.len);
    for (lowered.functions, functions) |*lowering, *function| {
        try lowering.seal();
        const origins = try arena.alloc(defs.Origin, lowering.origin_offsets.items.len);
        for (lowering.origin_offsets.items, origins) |offset, *slot| {
            const at = sources.place(lowering.file, offset);
            slot.* = .{ .line = @intCast(at.line), .column = @intCast(at.column) };
        }
        function.* = .{
            .name = lowering.name,
            .parameter_count = lowering.parameter_count,
            .return_type = lowering.return_type,
            .fallible = lowering.fallible,
            .locals = try lowering.locals.toOwnedSlice(arena),
            .instructions = try lowering.instructions.toOwnedSlice(arena),
            .result_types = try lowering.result_types.toOwnedSlice(arena),
            .blocks = try lowering.freezeBlocks(),
            .origins = origins,
            .source = try fileName(arena, scratch, sources, &file_names, lowering.file),
        };
    }

    program.structs = lowered.structs;
    program.heap_types = lowered.heap_types;
    program.functions = functions;
    program.constants = lowered.constants;
    program.entry_function = lowered.entry_function;
}

/// How a trap trace names a file ("editor.luc").  The root source may
/// have arrived without a path — a pipe, a string in a test — and a
/// traceback still has to call it something.
fn fileName(
    arena: Allocator,
    scratch: Allocator,
    sources: *const source_mod.Sources,
    cache: *std.AutoHashMapUnmanaged(source_mod.FileId, []const u8),
    file: source_mod.FileId,
) Error![]const u8 {
    if (cache.get(file)) |name| return name;
    const path = sources.pathOf(file);
    const name = try arena.dupe(u8, if (path.len != 0) path else "main.luc");
    try cache.put(scratch, file, name);
    return name;
}
