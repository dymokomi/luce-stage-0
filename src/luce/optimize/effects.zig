//! What an instruction may be assumed about — the one table every
//! pass in this stage consults before it moves, duplicates, or deletes
//! anything.
//!
//! One question comes up over and over, and it is answered here so
//! that the answer is written down once:
//!
//!   * `classify` — may a *later* instruction with the same operands
//!     reuse this one's result, and may this one be deleted when
//!     nothing reads it?
//!
//! Everything not named is `impure`.  A new
//! instruction or intrinsic is therefore pessimised rather than
//! silently assumed harmless — the switches below are exhaustive, so
//! adding one is a compile error here first.
//!
//! **Stage 8 is the other consumer**, through `viewStable`: the
//! lowering keeps a container's storage pointer live across a run of
//! instructions only while every one of them is an instruction that
//! cannot move it (`codegen/lower.zig`, `codegen/loops.zig`).  That
//! question is asked here rather than there so the two stages cannot
//! come to different answers about the same instruction.
//!
//! Read `Effect` below before turning one of these levels into an LLVM
//! attribute: `stable` means "reads nothing another instruction can
//! change", *not* `memory(none)`.

const defs = @import("../mir/defs.zig");
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
    /// instruction can change — but it may trap.  A later duplicate
    /// may be folded away (it is dominated by the first: if the first
    /// did not trap, neither would the second), but an unread one must
    /// stay, because deleting it would delete a trap.
    ///
    /// **Nothing that allocates value storage is `stable`.**  A string
    /// or a struct value has an owner and a death point now
    /// (docs/STRINGS.md), so two identical makes are two allocations
    /// with two releases, and folding them would leave one release
    /// pointing at memory the other already gave back — the same
    /// reason `heap_new` has always been `impure`.
    stable,
    /// Everything else: effects, host services, the heap, object
    /// identity, and every read of mutable state.
    impure,
};

/// `at` is the register the instruction defines, which in this IR is
/// also its index in the pool.  It is taken rather than the
/// instruction itself because a `convert` reads its own result type to
/// know whether it can trap: the destination is the register, and
/// there is no second copy of it to disagree with.
pub fn classify(function: *const Function, at: defs.Register) Effect {
    return switch (function.instructions[at]) {
        // Values out of thin air, and reads of things nothing can
        // change: a local (invalidated by its own `local_set`, which
        // the caller tracks), a field of an immutable struct value.
        .const_boolean, .const_integer, .const_float, .const_str, .const_container => .pure,
        // A function value is a fresh two-slot run — the function it
        // names beside the receiver it carries — so making one has the
        // identity and the allocation `struct_make` has, and for the
        // same reason (docs/BINDING.md D12).
        .const_function => .impure,
        .local_get, .struct_get => .pure,

        .unary => |unary| switch (unary.op) {
            .logic_not => .pure,
            // A complement moves bits and nothing else — no width of
            // it can trap (docs/BITWISE.md D3).
            .bit_not => .pure,
            // Negating the smallest integer overflows at either
            // width; negating a float cannot, at either width.
            .negate => if (function.result_types[unary.operand].isFloating()) .pure else .stable,
        },
        // A conversion is pure unless it can refuse the value it was
        // given, which is exactly the two families `conversionTraps`
        // names: float to integer, and integer to a narrower integer.
        .convert => |operand| if (Type.conversionTraps(
            function.result_types[operand],
            function.result_types[at],
        )) .stable else .pure,
        .binary => |binary| if (binary.op.isComparison())
            // **A function value has no comparison at all** — no order
            // (FUNCTIONS.md D3) and, since BINDING.md D6, no equality
            // either, wherever a comparison reaches one.  Stage 4
            // refuses it and `mir/verify.zig` refuses the shape in a
            // decoded module, so this arm classifies something that
            // cannot arrive; it stays, and stays `.stable`, because
            // reading a function out of its run is a read of a run and
            // every reader of one refuses the run that is nowhere
            // (D12) — which is the honest answer if it ever did.
            // `function_name` is `.stable` for that reason and no other.
            (if (binary.operand_type == .function) .stable else .pure)
        else if (binary.operand_type.isFloating())
            // IEEE arithmetic answers everything, `/0` included, so
            // every double operator is pure — and since `/` is real
            // division and always answers a double
            // (docs/NUMERICS.md §2), `/` is now always in this arm.
            // The operators that can still trap are `//` and `%`, the
            // two that produce a long.
            .pure
        else if (binary.operand_type == .str)
            // string `+` allocates bytes somebody has to free.
            .impure
        else
            // Integer arithmetic traps on overflow and on `// 0`, and
            // is deterministic all the same.
            .stable,

        // A fresh struct value has an identity for the same reason a
        // fresh object does: it owns a field run exactly one place
        // will give back (docs/STRINGS.md).
        .struct_make, .struct_set => .impure,

        // A union value is a struct value whose field 0 is the tag
        // (docs/UNION.md D8): making one allocates a run, and reading
        // the tag or a payload slot reads a value nothing can change.
        .variant_make => .impure,
        .variant_tag, .variant_field => .pure,

        .intrinsic => |call| intrinsicEffect(
            call.kind,
            if (call.arguments.len == 0) null else function.result_types[call.arguments[0]],
        ),

        // A fresh object has an identity: two `heap_new`s of the same
        // shape are two different objects and may never be shared.
        .heap_new => .impure,

        .local_set,
        .call,
        .call_inout,
        // A call through a value runs a function this pass cannot see,
        // exactly as a direct call does.
        .call_indirect,
        // A spawn makes a task nothing else is, and hands a thread
        // everything it was given (docs/THREADS.md D2).
        .spawn,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => .impure,
    };
}

/// One intrinsic's effect.  `first_argument` is the type of argument
/// zero where the answer depends on it (`abs`, `str_value`); pass null for
/// the conservative answer, which is what a caller with no function to
/// look it up in should do.
///
/// Private: `classify` above is the whole interface this file offers
/// for the instruction stream, and `viewStable` below the one it
/// offers stage 8.  Nothing outside asks about an intrinsic in
/// isolation, and a second entry point would be a second place for the
/// table to be consulted incompletely.
fn intrinsicEffect(kind: Intrinsic, first_argument: ?Type) Effect {
    return switch (kind) {
        // Arithmetic on values.  `abs` is `stable` rather than `pure`
        // for the same reason `negate` is: abs(long.min) overflows.
        .min, .max, .clamp, .sqrt, .floor, .ceil, .trunc, .compare_i64_f64 => .pure,
        .abs => if (first_argument) |argument|
            (if (argument.isFloating()) .pure else .stable)
        else
            .stable,
        .null_object => .pure,
        // Reading a valid function's name reads a constant table
        // (docs/FUNCTIONS.md D3).  A verified decoded function value
        // can still hold the unwritten-local sentinel, however, and
        // both engines range-check it as `null_object`; deleting an
        // unread lookup would delete that trap.
        .function_name => .stable,

        // Optionals move no bits and touch no heap: absence is a tag.
        .none_value, .is_none, .optional_wrap, .optional_unwrap => .pure,

        // The error channel is mutable state one instruction writes
        // and the next reads, so none may be folded or deleted:
        // `errored` reads what the call in front of it left,
        // `error_message` reads the words the same error carries, and
        // `forget` is the whole of what a `catch` does.  `.impure` says
        // nothing about *order* — nothing here reorders — and the order
        // that matters is `error_message` before `forget`, which stage
        // 4 emits and LLVM keeps because both take the runtime pointer
        // and one of them writes through it.
        .errored, .error_message, .forget, .raise_error => .impure,

        // Text.  A string is a value, so these read nothing another
        // instruction can change.  The parsers answer absence rather
        // than trapping, so they are pure; the rest can trap.
        .parse_int,
        .parse_float,
        => .pure,

        // `parse_string` is the parse family's third member and the
        // one exception to their purity: it reads a list's elements,
        // which an append can change, and it makes fresh owned text.
        .parse_string => .impure,
        // A slice is a borrow and the rest answer scalars, so none of
        // these allocates.
        .string_slice,
        .string_byte,
        .string_find_byte,
        .ord_text,
        => .stable,

        // Both make fresh owned text, so both have an identity
        // (docs/STRINGS.md); `str` of a builder reads the heap on top
        // of that.
        .chr_code, .str_value => .impure,

        // Reads of the heap.  These *are* deterministic between two
        // mutations, and folding them is exactly the optimization LLVM
        // cannot do — but it needs a barrier analysis, and measurement
        // over examples/ and bench/ found zero pairs to fold (see
        // optimize.zig's header).  Unwritten, not off by choice.
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

        // Value storage: one allocates and one frees, and the second
        // is a deallocation — deleting an unread one would leak, and
        // folding two would double free (docs/STRINGS.md).
        .own_storage,
        .drop_storage,
        .export_storage,
        // A refcount adjustment mutates the object's row and can free it,
        // so it is never dead and never foldable — the ARC-elision pass
        // reasons about retain/release pairs specifically, not this table.
        .retain,
        .release,
        => .impure,

        // Fresh objects, mutation, and every host service.
        .index_set,
        .list_slice,
        .append_value,
        .append_ascii,
        .pop_value,
        .insert_value,
        .remove_entry,
        .copy_object,
        .list_sort,
        .list_reverse,
        .clear_object,
        .map_keys,
        .map_values,
        // Reads a place and may define it: a store, and one that can
        // grow the map's buffer.
        .map_place,
        .array_fill,
        .assert_true,
        .trap_message,
        .print,
        .file_read,
        .file_write,
        .path_kind,
        .term_rows,
        .term_cols,
        .term_clear,
        .term_move,
        .term_style,
        .term_write,
        .term_flush,
        .key_read,
        .key_text,
        .read_line,
        .print_error,
        .clock_ms,
        .epoch_ms,
        .sleep_ms,
        .env_get,
        .file_append,
        .file_delete,
        .file_rename,
        .dir_list,
        .dir_create,
        // The byte channel: `file_open` takes a table row and every
        // other one reaches the world through a handle.
        .file_open,
        .handle_read,
        .handle_write,
        .handle_flush,
        .exit_program,
        // A wait joins a thread, adopts whatever it left behind, and
        // moves its result into this runtime.
        .task_wait,
        // A machine fact is a host call, and one of them — available
        // memory — answers differently each time it is asked, which
        // is the reason a program asks it twice.
        .os_total_memory,
        .os_available_memory,
        .os_cpu_count,
        .shell_run,
        .term_event_data,
        .gpu_backend,
        .ui_window_open,
        .ui_window_surface,
        .gpu_surface_size,
        .gpu_surface_clear,
        .gpu_surface_fill_rect,
        .gpu_surface_present,
        => .impure,
    };
}

/// Can a resolved array view survive this instruction?
///
/// Stage 8 resolves a handle *once per basic block* and reuses the SSA
/// values it got — the row's address, the axis lengths, the element
/// base — for every later access in that block (`codegen/lower.zig`).
/// Three things have to hold for that to be sound, and this answers
/// whether all three still do:
///
///   * **the table does not grow** — its rows are one allocation, and
///     a row's address moves when it is reallocated, so any
///     instruction that can attach an object invalidates every view;
///   * **nothing is freed** — a freed row's generation moves on and
///     the row itself may be handed straight to the next `new`, so a
///     view reused past a free would skip the `use_after_free` the
///     next access owes and could read a whole different object's
///     storage;
///   * **no array's storage is replaced** — `dims` and `elements`
///     never move for a *live* array, which is the whole reason this
///     is the container the inline path starts with.
///
/// The question is asked *after* the instruction is emitted, so an
/// instruction may use the view it then invalidates: `a[i] = a[i] + 1`
/// resolves once, and the write happens before the invalidation it
/// causes.
///
/// `false` for anything that can disturb any of the three, which is
/// the safe answer.  It needs no `Function`: unlike `classify`, no
/// answer here turns on an operand's type.
pub fn viewStable(instruction: Instruction) bool {
    return switch (instruction) {
        // Values, locals, immutable struct storage, control flow: the
        // object table is not involved at all.
        .const_boolean,
        .const_integer,
        .const_float,
        .const_str,
        .const_container,
        .const_function,
        .local_get,
        .local_set,
        .struct_get,
        .struct_make,
        .struct_set,
        // Value storage only: a union value is a field run, not the
        // object table (docs/UNION.md D8).
        .variant_make,
        .variant_tag,
        .variant_field,
        .binary,
        .unary,
        .convert,
        .jump,
        .branch,
        .ret,
        .trap,
        .unwind,
        => true,

        // A fresh object appends a row, and the table moves when it
        // grows.
        .heap_new => false,
        // A callee may do any of the three, whether it was named at the
        // call or reached through a value.
        .call, .call_inout, .call_indirect => false,
        // A spawn attaches the task's row, moves every object argument
        // out of this runtime, and hands the table to a second thread.
        // Nothing resolved before it can be believed after it
        // (docs/THREADS.md).
        .spawn => false,

        .intrinsic => |call| switch (call.kind) {
            // Scalars and text: no handle is resolved, nothing is
            // attached, nothing is freed.  `str` of a builder reads a
            // row, which is a read.
            .abs,
            .function_name,
            .min,
            .max,
            .clamp,
            .sqrt,
            .floor,
            .ceil,
            .trunc,
            .compare_i64_f64,
            .string_slice,
            .string_byte,
            .string_find_byte,
            .parse_int,
            .parse_float,
            .parse_string,
            .chr_code,
            .ord_text,
            .null_object,
            .none_value,
            .is_none,
            .optional_wrap,
            .optional_unwrap,
            .str_value,
            .assert_true,
            .trap_message,
            // Ending the run touches no handle either — the frame
            // unwinds and nothing after it reads a view.
            .exit_program,
            // A machine fact is a number in and out; no object table
            // is touched to produce one.
            .os_total_memory,
            .os_available_memory,
            .os_cpu_count,
            .shell_run,
            .term_event_data,
            // The error channel is not the object table.
            .errored,
            .error_message,
            .forget,
            .raise_error,
            => true,

            // Reads of the heap.  Every one of them resolves a handle
            // and looks; none attaches, frees, or moves storage.
            .len,
            .dim_size,
            .index_get,
            .has_key,
            .key_at,
            .value_at,
            .map_get,
            .list_find,
            .list_contains,
            => true,

            // In place over elements already there.
            .list_sort, .list_reverse => true,

            // Value storage only: a string's bytes and a struct's
            // field run are not the object table and not an array's
            // storage (docs/STRINGS.md).
            .own_storage, .drop_storage, .export_storage => true,
            // A retain only increments a count word — no attach, no free,
            // no table growth — so a resolved view survives it.
            .retain => true,

            // Attaches a fresh object, so the table may grow.
            .list_slice, .map_keys, .map_values, .copy_object => false,
            // A release can drop an object's last reference and retire its
            // row, moving a generation; re-resolve a view across it.
            .release => false,
            // Replaces an element that owned something.
            .index_set,
            .array_fill,
            .pop_value,
            .remove_entry,
            .clear_object,
            => false,
            // Grow a container's own buffer.  That buffer is not the
            // table and not an array's, but a list's elements are
            // read through the same row, so this stays conservative.
            .append_value, .append_ascii, .insert_value, .map_place => false,

            // Effects.  A host service reaches the outside world and
            // the run's arena; it has no way to touch the object
            // table.
            .print,
            .file_read,
            .file_write,
            .path_kind,
            .term_rows,
            .term_cols,
            .term_clear,
            .term_move,
            .term_style,
            .term_write,
            .term_flush,
            .key_read,
            .key_text,
            .read_line,
            .print_error,
            .clock_ms,
            .epoch_ms,
            .sleep_ms,
            .env_get,
            .file_append,
            .file_delete,
            .file_rename,
            // Making a directory takes no table row: it is a path in
            // and an outcome back, like deleting one.
            .dir_create,
            // Reading and writing through a handle resolves that
            // handle and the buffer, which are reads.
            .handle_read,
            .handle_write,
            .handle_flush,
            => true,
            // The two host services that make an object: each takes a
            // table row, which is exactly what a resolved array view
            // cannot survive.
            .dir_list,
            .file_open,
            .gpu_backend,
            .ui_window_open,
            .ui_window_surface,
            .gpu_surface_size,
            .gpu_surface_clear,
            .gpu_surface_fill_rect,
            .gpu_surface_present,
            => false,
            // A wait moves the worker's result in, which attaches
            // rows to *this* table.
            .task_wait => false,
        },
    };
}
