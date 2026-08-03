//! Block-local value numbering: store-to-load forwarding for locals,
//! then common-subexpression elimination for everything deterministic.
//!
//! **This pass exists for the interpreter only, and it is here on a
//! measurement rather than on a principle.**  LLVM already does all of
//! it and more: `default<O2>` runs mem2reg and GVN, so on the compiled
//! path this buys nothing but a slightly smaller module to hand over
//! (measured: 2.5% off LLVM compile time across eight programs, which
//! on its own would not be worth the risk).  The interpreter gets no
//! optimization at all, and is the engine `loom run` executes today.
//!
//! Over `programs/` and `bench/`, after `flow.zig` has merged blocks,
//! this removes 545 of 5091 MIR instructions — about 227 re-read
//! locals and the rest recomputed expressions.  Each one was a
//! dispatch, a step off the budget, and a slot in every frame of every
//! call.  Interleaved A/B on the interpreter: **3-4% of a further 6-9%
//! total** on the scalar benchmarks (`loops`, `math`, `matmul`), and
//! nothing measurable on the allocation-bound ones, which spend their
//! time inside the runtime rather than in the dispatch loop.
//!
//! If the interpreter ever stops being a shipping engine, turn
//! `Passes.values` off and delete this file; nothing else depends on
//! it.
//!
//! **Why a block is the whole horizon.**  MIR registers never cross a
//! basic block (`06_mir/verify.zig` clears the defined set per block);
//! anything that has to outlive a branch is already in a local.  So
//! there is no dominance to compute and no phi to build — the analysis
//! is one forward walk per block, and it is complete for the shape of
//! the IR rather than a cheap approximation of something larger.
//!
//! **Two rewrites, one walk:**
//!
//!   * *store-to-load forwarding.*  `local_set %L, rV` makes rV the
//!     value of `%L`; a later `local_get %L` in the same block, with
//!     no `local_set %L` between, is rV.  Nothing else in MIR can
//!     write a local — there is no address-of, and a call gets copies
//!     of its arguments — so the invalidation rule is exactly "another
//!     store to the same local".  The first `local_get %L` seeds the
//!     same slot, which folds repeated reads together as well.
//!
//!   * *common-subexpression elimination.*  An instruction that is
//!     `pure` or `stable` (`effects.zig`) and whose tag, immediates,
//!     and already-canonicalised operands match an earlier one in the
//!     block is that earlier one.  `stable` covers operations that can
//!     trap: the duplicate is dominated by the original, so if the
//!     original did not trap the duplicate could not have either, and
//!     no trap is added, removed, or reordered.
//!
//! Folded instructions are unlinked from their block; the pool itself
//! is compacted later, by `dead.zig`.

const std = @import("std");
const defs = @import("../06_mir/defs.zig");
const support = @import("../support/types.zig");
const effects = @import("effects.zig");
const registers = @import("registers.zig");

const Allocator = std.mem.Allocator;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Program = defs.Program;
const Register = defs.Register;
const Type = support.Type;

/// Number values block by block across the whole program.
pub fn values(arena: Allocator, program: *Program) Allocator.Error!void {
    for (program.functions) |*function| try numberFunction(arena, function);
}

fn numberFunction(arena: Allocator, function: *Function) Allocator.Error!void {
    const count = function.instructions.len;
    if (count == 0) return;

    // Identity to start with: `canonical[r]` is the register that now
    // produces what r used to.  Operands are rewritten through it as
    // the walk reaches them, so by the time an instruction is hashed
    // its operands are already canonical and structural equality is
    // value equality.
    const canonical = try arena.alloc(Register, count);
    for (canonical, 0..) |*slot, index| slot.* = @intCast(index);

    // The value each local holds right now, as a register in this
    // block, or null when the block has not seen a store or a load of
    // it yet.
    const held = try arena.alloc(?Register, function.locals.len);

    var table: std.StringHashMapUnmanaged(Register) = .empty;
    var key: std.ArrayList(u8) = .empty;

    for (function.blocks) |*block| {
        table.clearRetainingCapacity();
        @memset(held, null);

        var kept: usize = 0;
        for (block.items) |item| {
            const instruction = &function.instructions[item];
            try registers.mapOperands(arena, instruction, canonical);

            switch (instruction.*) {
                .local_set => |set| {
                    // A slot that owns its storage does not hold the
                    // register that was stored into it: it holds an
                    // owned copy, and for text the runtime chooses the
                    // form — short text goes inside the value, long
                    // text stays an allocation (docs/STRINGS.md).  So
                    // the store says nothing about what a later load
                    // answers, and forwarding it would hand the release
                    // a value that is not the one in the slot.
                    held[set.local] = if (function.locals[set.local].owns_storage)
                        null
                    else
                        set.value;
                    block.items[kept] = item;
                    kept += 1;
                    continue;
                },
                .local_get => |local| {
                    if (held[local]) |value| {
                        canonical[item] = value;
                        continue;
                    }
                    held[local] = item;
                    block.items[kept] = item;
                    kept += 1;
                    continue;
                },
                else => {},
            }

            switch (effects.classify(function, instruction.*)) {
                .impure => {},
                .pure, .stable => {
                    key.clearRetainingCapacity();
                    try encode(&key, arena, instruction.*, function.result_types[item]);
                    if (table.get(key.items)) |earlier| {
                        canonical[item] = earlier;
                        continue;
                    }
                    try table.put(arena, try arena.dupe(u8, key.items), item);
                },
            }
            block.items[kept] = item;
            kept += 1;
        }
        block.items = block.items[0..kept];
    }
}

/// The whole of a type, in the key.  Every distinguishing part has to
/// be here: two argument-free intrinsics of the same kind differ only
/// by their result type, so a `List(Int)?` and a `Builder?` that both
/// come from `none_value` are the same instruction and *not* the same
/// value.
fn encodeType(key: *std.ArrayList(u8), arena: Allocator, of: Type) Allocator.Error!void {
    try word(key, arena, @intFromEnum(std.meta.activeTag(of)));
    switch (of) {
        .strukt, .heap => |index| try word(key, arena, index),
        .optional => |payload| try encodeType(key, arena, payload.asType()),
        else => {},
    }
}

/// A structural key for one instruction: its tag, its immediates, and
/// its (already canonical) operands.  Two instructions with equal keys
/// compute equal values.
fn encode(
    key: *std.ArrayList(u8),
    arena: Allocator,
    instruction: Instruction,
    result_type: Type,
) Allocator.Error!void {
    try key.append(arena, @intFromEnum(std.meta.activeTag(instruction)));
    try encodeType(key, arena, result_type);
    switch (instruction) {
        .const_boolean => |flag| try key.append(arena, @intFromBool(flag)),
        .const_int => |number| try word(key, arena, number),
        // Bit pattern, not value: -0.0 and 0.0 are different constants
        // and NaN is never equal to itself, so neither may be folded
        // together by an accident of numeric comparison.
        .const_float => |number| try word(key, arena, @as(u64, @bitCast(number))),
        .const_data => |data| try word(key, arena, data.constant),
        .local_get => |local| try word(key, arena, local),
        .input_load => |port| try word(key, arena, port),
        .binary => |binary| {
            try key.append(arena, @intFromEnum(binary.op));
            try word(key, arena, binary.left);
            try word(key, arena, binary.right);
        },
        .unary => |unary| {
            try key.append(arena, @intFromEnum(unary.op));
            try word(key, arena, unary.operand);
        },
        .convert => |convert| {
            try key.append(arena, @intFromEnum(convert.kind));
            try word(key, arena, convert.operand);
        },
        .struct_make => |make| {
            try word(key, arena, make.layout);
            for (make.fields) |field| try word(key, arena, field);
        },
        .struct_get => |get| {
            try word(key, arena, get.layout);
            try word(key, arena, get.field);
            try word(key, arena, get.target);
        },
        .struct_set => |set| {
            try word(key, arena, set.layout);
            try word(key, arena, set.field);
            try word(key, arena, set.target);
            try word(key, arena, set.value);
        },
        .intrinsic => |call| {
            try key.append(arena, @intFromEnum(call.kind));
            for (call.arguments) |argument| try word(key, arena, argument);
        },
        // Never classified `pure` or `stable`, so never reached — but
        // an exhaustive switch means a new instruction cannot be
        // silently keyed by its tag alone.
        .local_set,
        .output_store,
        .call,
        .heap_new,
        .object_bind,
        .object_unbind,
        .jump,
        .branch,
        .ret,
        .trap,
        => unreachable,
    }
}

fn word(key: *std.ArrayList(u8), arena: Allocator, number: anytype) Allocator.Error!void {
    const widened: u64 = switch (@typeInfo(@TypeOf(number))) {
        .int => |shape| if (shape.signedness == .signed)
            @bitCast(@as(i64, number))
        else
            @as(u64, number),
        else => number,
    };
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, widened, .little);
    try key.appendSlice(arena, &bytes);
}
