//! What an instruction may be assumed about — the one table every
//! pass in this stage consults before it moves, duplicates, or deletes
//! anything.
//!
//! Two questions come up over and over, and both are answered here so
//! that the answer is written down once:
//!
//!   * `classify` — may a *later* instruction with the same operands
//!     reuse this one's result, and may this one be deleted when
//!     nothing reads it?
//!   * `ownershipTransparent` — can this instruction change which
//!     binding owns an object, or free one?
//!
//! Everything not named is `impure` / not transparent.  A new
//! instruction or intrinsic is therefore pessimised rather than
//! silently assumed harmless — the switches below are exhaustive, so
//! adding one is a compile error here first.
//!
//! **Stage 8 is the other consumer.**  `08_llvm` declares one external
//! `luce_rt_*` per intrinsic, and LLVM's `inferattrs` only infers
//! attributes for known libc names, so an external of ours gets
//! nothing it is not told.  `intrinsicEffect` is public for that: it
//! answers per-intrinsic, without a function to look arguments up in,
//! and the guarantees each level carries are spelled out on `Effect`
//! below.  Read them before turning one into an LLVM attribute —
//! `stable` in particular means "reads nothing another instruction can
//! change", *not* `memory(none)`: several `stable` operations allocate
//! a String or a struct value out of the run arena.

const defs = @import("../06_mir/defs.zig");
const support = @import("../support/types.zig");

const Function = defs.Function;
const Instruction = defs.Instruction;
const Intrinsic = defs.Intrinsic;
const Type = support.Type;

/// How freely a pass may treat an instruction.
pub const Effect = enum {
    /// Same operands, same result; reads nothing mutable, writes
    /// nothing, allocates nothing, cannot trap.  A later duplicate may
    /// be folded away, and an unread one deleted.
    pure,
    /// Same operands, same result, and it reads nothing that another
    /// instruction can change — but it may trap, and it may *allocate*
    /// (a String, a struct value) out of the run arena.  A later
    /// duplicate may be folded away (it is dominated by the first: if
    /// the first did not trap, neither would the second), but an
    /// unread one must stay, because deleting it would delete a trap.
    stable,
    /// Everything else: effects, host services, the heap, object
    /// identity, and every read of mutable state.
    impure,
};

pub fn classify(function: *const Function, instruction: Instruction) Effect {
    return switch (instruction) {
        // Values out of thin air, and reads of things nothing can
        // change: the immutable input frame, a local (invalidated by
        // its own `local_set`, which the caller tracks), a field of an
        // immutable struct value.
        .const_boolean, .const_int, .const_float, .const_data => .pure,
        .local_get, .struct_get => .pure,

        // Reading an input cannot trap, but `Program.reads` records
        // which inputs a program touches, so deleting an unread load
        // would make that record a lie.  Foldable, not deletable.
        .input_load => .stable,

        .unary => |unary| switch (unary.op) {
            .logic_not => .pure,
            // Negating Int(min) overflows; negating a float cannot.
            .negate => if (function.result_types[unary.operand] == .float) .pure else .stable,
        },
        .convert => |convert| switch (convert.kind) {
            .int_to_float => .pure,
            .float_to_int => .stable,
        },
        .binary => |binary| if (binary.op.isComparison())
            .pure
        else if (binary.operand_type == .float)
            // IEEE arithmetic answers everything, including /0.
            .pure
        else
            // Integer arithmetic traps on overflow and on /0; string
            // `+` allocates.  Both are deterministic all the same.
            .stable,

        // Struct values are immutable — `struct_set` returns a fresh
        // one rather than writing through (runtime/heap.zig) — so two
        // identical makes may share a value.  They allocate, so they
        // are not deleted when unread.
        .struct_make, .struct_set => .stable,

        .intrinsic => |call| intrinsicEffect(
            call.kind,
            if (call.arguments.len == 0) null else function.result_types[call.arguments[0]],
        ),

        // A fresh object has an identity: two `heap_new`s of the same
        // shape are two different objects and may never be shared.
        .heap_new => .impure,

        .local_set,
        .output_store,
        .call,
        .object_bind,
        .object_unbind,
        .jump,
        .branch,
        .ret,
        .trap,
        => .impure,
    };
}

/// One intrinsic's effect.  `first_argument` is the type of argument
/// zero where the answer depends on it (`abs`, `str`); pass null for
/// the conservative answer, which is what a caller with no function to
/// look it up in should do.
pub fn intrinsicEffect(kind: Intrinsic, first_argument: ?Type) Effect {
    return switch (kind) {
        // Arithmetic on values.  `abs` is `stable` rather than `pure`
        // for the same reason `negate` is: abs(Int.min) overflows.
        .min, .max, .clamp, .sqrt, .floor, .ceil => .pure,
        .abs => if (first_argument) |argument|
            (if (argument == .float) .pure else .stable)
        else
            .stable,
        .null_object => .pure,

        // Text.  A String is a value, so these read nothing another
        // instruction can change; each of them can trap.
        .string_slice,
        .string_byte,
        .string_find_byte,
        .parse_int,
        .parse_float,
        .chr_code,
        .ord_text,
        => .stable,

        // `str` of a Builder reads the heap; of a scalar or a String
        // it does not.
        .str_value => if (first_argument) |argument|
            (if (argument == .heap) .impure else .stable)
        else
            .impure,

        // Reads of the heap.  These *are* deterministic between two
        // mutations, and folding them is exactly the optimization LLVM
        // cannot do — but it needs a barrier analysis, and measurement
        // over programs/ and bench/ found zero pairs to fold (see
        // 07_optimize.zig's header).  Unwritten, not off by choice.
        .len,
        .dim_size,
        .index_get,
        .has_key,
        .key_at,
        .value_at,
        .map_get,
        .list_find,
        .list_contains,
        => .impure,

        // Fresh objects, mutation, ownership verbs, and every host
        // service.
        .index_set,
        .list_slice,
        .append_value,
        .append_ascii,
        .pop_value,
        .insert_value,
        .remove_entry,
        .free_object,
        .give_object,
        .copy_object,
        .list_sort,
        .list_reverse,
        .clear_object,
        .map_keys,
        .map_values,
        .array_fill,
        .assert_true,
        .trap_message,
        .print,
        .file_read,
        .file_write,
        .file_exists,
        .arg_count,
        .arg_get,
        .term_rows,
        .term_cols,
        .term_clear,
        .term_move,
        .term_style,
        .term_write,
        .term_flush,
        .key_read,
        .key_text,
        => .impure,
    };
}

/// Can this instruction change which binding owns an object, or free
/// one?  `false` for anything that can, which is the safe answer.
///
/// Ownership lives in one field per object (`runtime/heap.zig`), and
/// only `object_bind`, `object_unbind`, the ownership verbs, container
/// adoption, and a call can write it.
///
/// `heap_new` is excluded, but not because it could disturb anything:
/// object slots are never reused, so a fresh object has an identity no
/// live handle shares, and it touches nobody else's owner field.  It
/// is simply not on the list because no pass has needed it to be — the
/// pattern this serves has its allocation before the binds, not
/// between them.
pub fn ownershipTransparent(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .const_boolean,
        .const_int,
        .const_float,
        .const_data,
        .local_get,
        .local_set,
        .input_load,
        .output_store,
        .struct_get,
        .struct_make,
        .struct_set,
        .binary,
        .unary,
        .convert,
        => true,
        .intrinsic => |call| switch (call.kind) {
            // Scalar and text work only: no handle is resolved, no
            // owner is read or written, nothing is freed.
            .abs,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .parse_int,
            .parse_float,
            .chr_code,
            .ord_text,
            .null_object,
            => true,
            .str_value => function.result_types[call.arguments[0]] != .heap,
            else => false,
        },
        else => false,
    };
}
