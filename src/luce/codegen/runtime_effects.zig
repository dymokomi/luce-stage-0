//! What a compiled artifact tells LLVM about `libluce_rt`.
//!
//! Generated code calls a runtime entry point for every semantic in
//! the language — one per tag of `Service` below, which is exactly the
//! set `runtime/exports.zig` publishes, proved by the last test in this
//! file.  Until this file existed it declared every one of them bare:
//!
//! ```llvm
//! declare i32 @luce_rt_len(ptr, ptr, ptr)
//! ```
//!
//! A bare declaration is the most pessimistic thing LLVM can be told.
//! It must assume the call reads and writes *all* memory, may not
//! return, and may unwind — so `len(xs)` cannot leave a loop even when
//! nothing in the loop touches the list, the boxes handed to it must be
//! refilled every iteration because the call might have scribbled on
//! them, and every trap edge looks as likely as the path through.  None
//! of that is true of any function in `runtime/exports.zig`, and this
//! file is where the truth is written down.
//!
//! ## The three claims, and why each holds
//!
//! **`nounwind`.**  `libluce_rt` is Zig with `link_libc`; nothing in it
//! raises an exception.  A Luce trap is a *value* — `1` returned
//! through the `i32` every fallible export answers with — not an
//! unwind, which is the whole reason the C surface has that convention
//! (docs/CODEGEN.md).  Host callbacks follow that same C boundary and
//! may return normally or not at all; the two final reporting exports
//! conservatively withhold the promise because they hand off the
//! stopped run to arbitrary host code.
//!
//! **`willreturn`.**  Most exports terminate: the container algorithms
//! are bounded by the container, the text ones by the string, and a
//! trap returns rather than using `longjmp`.  The promise is withheld
//! from direct host or worker callbacks, the effect-lock wait, and
//! release paths that can transitively close a file or join a task.
//! Deep-copy operations withhold it too: ownership cycles are refused,
//! but an acyclic graph's native recursive depth remains data-dependent
//! and can exhaust the stack.  Those calls may wait forever, hand control
//! to a callback that never returns, or exhaust the native stack.  The
//! exact set is pinned below; everything outside it still carries
//! `willreturn`.
//!
//! **`memory(...)`.**  This is the claim with teeth, so it is made per
//! function from what the body actually does.  Three locations matter:
//!
//!   * **argmem** — everything reachable *based on* a pointer argument:
//!     the `*Runtime` itself (its trap slot, its serial counter, its
//!     leak count), a borrowed `*const Value`, an out-parameter.  Every
//!     export that can trap writes `runtime.pending`, so every one of
//!     them is at least `argmem: readwrite`.  "Based on" is LangRef's
//!     term and it is narrow: a pointer *loaded out of* argument
//!     memory is based on nothing, so an object's element buffer is
//!     **not** argmem even though `%rt` is how the runtime finds it.
//!   * **inaccessiblemem** — the run's private storage: the value
//!     arena (String bytes, struct field runs), a List's, Map's or
//!     Builder's element buffer, and the unwind trace.  Generated code
//!     cannot reach any of it — it holds Strings as `{ptr, len}` pairs
//!     it never loads through, and it has no way at all to find a
//!     List's buffer.  That is exactly LangRef's "not accessible by
//!     the current module".
//!   * **the default** — globals, and **the object heap**: the table's
//!     rows, and the `dims` and `elements` of an Array.  Generated code
//!     *does* reach those: since inline container access
//!     (docs/CODEGEN.md) it loads the table base out of `%rt`, tests a
//!     row's generation, and loads and stores array elements
//!     directly.  The moment it did, calling that storage inaccessible
//!     became false, and a false `inaccessiblemem` is not a lost
//!     optimization — it lets LLVM conclude that `luce_rt_append`
//!     cannot disturb an element this module just stored.  So anything
//!     that resolves a handle names the default location, and what is
//!     left in `inaccessiblemem` is only what generated code still
//!     cannot see.  Reading a *constant* global — `luce_rt_unwound`
//!     and the `luce.functions` table — is permitted whatever the
//!     summary says.
//!
//! The distinction that survives is the one that pays: a reader
//! (`luce_rt_len`) still promises to write nothing but its arguments,
//! so it cannot disturb an element store, while a mutator
//! (`luce_rt_append`) promises nothing about the heap and is assumed
//! to move everything in it.
//!
//! ## Parameters
//!
//! `Parameter` names the handful of shapes a runtime argument comes in,
//! and each shape carries the promises that are true of it at **every**
//! call site — that is the bar, because these attributes sit on one
//! shared declaration.  Two consequences worth naming:
//!
//!   * A pointer the runtime *keeps* is not `nocapture`.  There is
//!     exactly one: `luce_rt_open`'s function table, which the run
//!     reads back when it unwinds.  A trap's message is not among them
//!     — the trap channel copies its words rather than keeping the
//!     caller's, because a short String lives in the frame that raised
//!     the trap (`heap.failMessage`).
//!   * A pointer that came from a *host* service gets no `nonnull`, no
//!     `dereferenceable`, and no `noundef`.  The host fills those slots,
//!     and a host is not ours to promise for.
//!
//! Nothing here is a hint.  A wrong attribute is a miscompile, not a
//! slowdown, so anything this file cannot justify from the body of the
//! function it describes is simply left unsaid.

const std = @import("std");
const runtime = @import("../runtime.zig");

const Builder = @import("builder.zig").Builder;
const Memory = Builder.Attribute.Memory;

/// Every `libluce_rt` entry point generated code calls.  The tag is the
/// C symbol, so `@tagName` is the name that reaches the object file and
/// there is no second spelling to keep in step.
// ---------------------------------------------------------------------------
// The services, and the vocabulary that describes one
// ---------------------------------------------------------------------------

pub const Service = enum {
    // -- the run ------------------------------------------------------
    luce_rt_open,
    luce_rt_close,
    luce_rt_leaked,
    luce_rt_status,
    luce_rt_exhaust,

    // -- constant-container roots (docs/CONSTANTS.md R-C) -----------
    luce_rt_constants_begin,
    luce_rt_constant_publish,
    luce_rt_constant_load,
    luce_rt_constants_finish,
    luce_rt_constants_abort,
    luce_rt_discard_loose,

    // -- traps and the trace they carry -------------------------------
    luce_rt_raise,
    luce_rt_unwound,
    luce_rt_report,
    luce_rt_exit,

    // -- errors, and the one position they carry ----------------------
    luce_rt_raise_error,
    luce_rt_raise_io,
    luce_rt_error_message,
    luce_rt_forget_error,
    luce_rt_report_error,

    // -- host text ----------------------------------------------------
    luce_rt_intern_text,
    luce_rt_maybe_text,
    luce_rt_names_list,
    luce_rt_args_list,
    luce_rt_set_key_text,
    luce_rt_key_text,

    // -- files: the byte channel, and text over it --------------------
    luce_rt_files_install,
    luce_rt_file_open,
    luce_rt_file_read,
    luce_rt_file_write,
    luce_rt_file_flush,
    luce_rt_file_read_text,
    luce_rt_file_write_text,

    // -- windows and GPU surfaces ------------------------------------
    luce_rt_graphics_install,
    luce_rt_gpu_backend,
    luce_rt_ui_window_open,
    luce_rt_ui_window_surface,
    luce_rt_gpu_surface_size,
    luce_rt_gpu_surface_clear,
    luce_rt_gpu_surface_fill_rect,
    luce_rt_gpu_surface_present,

    // -- workers (docs/THREADS.md) ------------------------------------
    luce_rt_workers_install,
    luce_rt_spawn,
    luce_rt_task_wait,
    luce_rt_effects_enter,
    luce_rt_effects_leave,

    // -- objects ------------------------------------------------------
    luce_rt_new_list,
    luce_rt_new_map,
    luce_rt_new_builder,
    luce_rt_new_array,
    luce_rt_copy,

    // -- struct values ------------------------------------------------
    luce_rt_struct_make,
    luce_rt_struct_set,
    /// A function value's run — the same allocation `struct_make`
    /// makes, under the tag that says its objects are borrowed
    /// (docs/BINDING.md D4).
    luce_rt_function_make,

    // -- containers ---------------------------------------------------
    luce_rt_len,
    luce_rt_index_get,
    luce_rt_index_set,
    luce_rt_list_slice,
    luce_rt_append,
    luce_rt_append_ascii,
    luce_rt_pop,
    luce_rt_insert,
    luce_rt_remove,
    luce_rt_has_key,
    luce_rt_key_at,
    luce_rt_value_at,
    luce_rt_dim_size,
    luce_rt_sort,
    luce_rt_reverse,
    luce_rt_find,
    luce_rt_contains,
    luce_rt_clear,
    luce_rt_map_keys,
    luce_rt_map_values,
    luce_rt_map_get,
    luce_rt_map_place,
    luce_rt_array_fill,

    // -- strings and conversions --------------------------------------
    luce_rt_concat,
    luce_rt_string_slice,
    luce_rt_string_byte,
    luce_rt_string_find_byte,
    luce_rt_str,
    luce_rt_parse_int,
    luce_rt_parse_float,
    luce_rt_parse_str,
    luce_rt_chr,
    luce_rt_ord,
    luce_rt_bytes,

    // -- operators ----------------------------------------------------
    luce_rt_compare,
    luce_rt_compare_i64_f64,
    luce_rt_float_mod,
    luce_rt_float32_mod,

    // -- value storage --------------------------------------------------
    luce_rt_own_storage,
    luce_rt_drop_storage,
    luce_rt_export_storage,

    // -- reference counting (ARC, docs/MEMORY.md) --------------------
    luce_rt_retain,
    luce_rt_release,
    luce_rt_weak_store,
    luce_rt_weak_load,

    /// The C symbol this service is declared under: a static string —
    /// the enum's own tag name — that the caller owns nothing of.
    pub fn symbol(self: Service) []const u8 {
        return @tagName(self);
    }
};

/// The shape of one runtime argument, and with it the promises that
/// hold at every call site that passes one.
pub const Parameter = enum {
    /// A scalar — an index, a length, a trap code, a serial.  Nothing
    /// to promise: some of them are answers a host handed back, and a
    /// host's answers are not ours to describe.
    plain,
    /// The `*Runtime` this run belongs to.  Never null (generated code
    /// checks `luce_rt_open` before it calls anything else), never
    /// kept: no export stores the runtime pointer anywhere.
    run,
    /// A borrowed `*const Value` — read for the duration of the call
    /// and not kept.  Always an entry-block `alloca` in generated code.
    value_in,
    /// A run of borrowed `Value`s (`[*]const Value`): subscripts,
    /// struct fields.  Always an `alloca`, but possibly an empty one,
    /// so it promises no size.
    values_in,
    /// A run of borrowed `i64`s — an array's dimensions.
    numbers_in,
    /// Where the answer goes: a `*Value` the callee writes and never
    /// reads.
    value_out,
    /// Borrowed bytes — a String's, or a buffer a host service filled
    /// in.  Read, not kept, and nothing else is promised, because the
    /// host end of the pair is not ours to promise for.
    bytes_in,
    /// Borrowed bytes the run *keeps*: the function table.  Read but
    /// not `nocapture`.
    bytes_kept,
    /// A pointer with nothing to promise — a host context, a host
    /// callback.
    unknown,

    /// Whether this shape describes a pointer.  Every shape but
    /// `plain` does, and the lowering checks that against the type the
    /// call site actually passes: a pointer attribute on an integer is
    /// invalid IR, and a `plain` where a pointer travels is a promise
    /// silently not made.
    pub fn isPointer(self: Parameter) bool {
        return switch (self) {
            .plain => false,
            .run,
            .value_in,
            .values_in,
            .numbers_in,
            .value_out,
            .bytes_in,
            .bytes_kept,
            .unknown,
            => true,
        };
    }
};

/// What one entry point does, as LLVM needs to hear it.
pub const Effect = struct {
    /// The memory summary, or null when the call reaches code this
    /// compiler knows nothing about and every effect must be assumed.
    memory: ?Memory,
    /// One entry per parameter, in declaration order.
    parameters: []const Parameter,
    /// Whether the callee can raise an exception through this frame.
    /// Host callbacks obey the C boundary; final reporting alone
    /// conservatively withholds the promise.
    nounwind: bool = true,
    /// Whether the call is guaranteed to come back.  Host callbacks,
    /// waits, cyclic deep copies, and release paths that may reach a
    /// wait or callback withhold it.
    willreturn: bool = true,
    /// Only reached while the program is failing.  LLVM sinks the
    /// blocks that call these out of the straight-line path, which is
    /// the whole point of putting the trap machinery behind a call.
    cold: bool = false,
    /// The result is freshly allocated storage nothing else points at.
    returns_noalias: bool = false,
};

// ---------------------------------------------------------------------------
// The memory shapes a service can have
// ---------------------------------------------------------------------------
//
// The summaries the table below is written in terms of.  Naming them
// once keeps the table readable and keeps a reader from having to
// re-derive what `argmem: readwrite, inaccessiblemem: read` means
// fifteen times.
//
// They come in two families, and which family an export belongs to is
// decided by one question: **does it resolve an object handle?**  If it
// does it touches the object table, which generated code can now reach,
// and it must name the default location.  If it only moves bytes
// through the arena or a String, it does not.

/// Touches no memory whatsoever: everything it needs arrives in
/// registers and the answer goes back the same way.
const reads_nothing: Memory = .{};
/// Reads through its arguments and nothing else.
const reads_run: Memory = .{ .argmem = .read };
/// Writes only through its arguments.
const touches_run: Memory = .{ .argmem = .readwrite };

/// Reads its arguments and the run's private storage; writes neither.
const reads_private: Memory = .{ .argmem = .read, .inaccessiblemem = .read };
/// Reads the run's private storage, and writes only through its
/// arguments — an out-parameter, and the trap slot when it fails.
const reads_text: Memory = .{ .argmem = .readwrite, .inaccessiblemem = .read };
/// Reads and writes its arguments and the run's private storage, and
/// nothing generated code can see.
const touches_text: Memory = .{ .argmem = .readwrite, .inaccessiblemem = .readwrite };

/// Resolves a handle — so it reads the object heap, which this module
/// reaches — and writes only through its arguments.
const reads_heap: Memory = .{
    .argmem = .readwrite,
    .inaccessiblemem = .read,
    .other = .read,
};
/// The general case: allocates, frees, or mutates an object, so
/// everything is assumed to move.
const touches_heap: Memory = .{
    .argmem = .readwrite,
    .inaccessiblemem = .readwrite,
    .other = .readwrite,
};
/// Reads the object heap and writes the run's private storage:
/// `String(x)` and `Builder.build()`,
/// which renders a Builder's bytes into fresh arena text.
const reads_heap_makes_text: Memory = .{
    .argmem = .readwrite,
    .inaccessiblemem = .readwrite,
    .other = .read,
};

/// What each entry point does.  One arm per service, no `else`: a new
/// runtime call is a compile error here, which is the only way a
/// declaration can never go out again bare or, worse, wrong.
///
/// The justification for each summary is the body of the corresponding
/// export in `runtime/exports.zig`; where that body only reads, the
/// summary says `read`, and where it allocates, frees, or mutates a
/// container it says `readwrite`.
// ---------------------------------------------------------------------------
// What each service does
// ---------------------------------------------------------------------------

pub fn describe(service: Service) Effect {
    return switch (service) {
        // -- the run --------------------------------------------------
        //
        // `open` allocates the runtime and its arena and reads the
        // function table it is handed; the storage it returns is fresh,
        // which is what `noalias` says.  `close` gives all of it back.
        .luce_rt_open => .{
            .memory = .{ .argmem = .read, .inaccessiblemem = .readwrite },
            .parameters = &.{ .bytes_kept, .plain },
            .returns_noalias = true,
        },
        .luce_rt_close => .{
            .memory = touches_heap,
            .parameters = &.{.run},
            .willreturn = false,
        },
        .luce_rt_leaked => .{ .memory = reads_run, .parameters = &.{.run} },
        .luce_rt_status => .{ .memory = reads_run, .parameters = &.{ .run, .plain } },
        // One store into the runtime, on the way out of a run that ran
        // out of memory.
        .luce_rt_exhaust => .{
            .memory = .{ .argmem = .write },
            .parameters = &.{.run},
            .cold = true,
        },

        // -- constant-container roots -------------------------------
        // `begin` allocates the runtime-local root table.  `publish`
        // resolves one loose object and makes that row program-owned;
        // `load` borrows the stored handle.  A failed prologue calls
        // `discard_loose` for its unfinished row and `abort` for the
        // rows already published, so those two may release any part of
        // the object heap.  `finish` only leaves materialization mode.
        .luce_rt_constants_begin => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .plain },
        },
        .luce_rt_constant_publish => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .plain, .value_in },
        },
        .luce_rt_constant_load => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .plain, .value_out },
        },
        .luce_rt_constants_finish => .{
            .memory = touches_run,
            .parameters = &.{.run},
        },
        .luce_rt_constants_abort => .{
            .memory = touches_heap,
            .parameters = &.{.run},
            .willreturn = false,
            .cold = true,
        },
        .luce_rt_discard_loose => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in },
            .willreturn = false,
            .cold = true,
        },

        // -- traps and the trace they carry ---------------------------
        //
        // `raise` records the pending trap and **copies** the words
        // into the run's own storage, because short text lives in the
        // caller's frame and the frame goes as this returns
        // (`heap.failMessage`).  So the pointer is read and released —
        // `nocapture` — and the copy is a write to memory generated
        // code cannot see.
        .luce_rt_raise => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .bytes_in, .plain },
            .cold = true,
        },
        // Appends one frame to the trace, which allocates.  It reads
        // the `luce.functions` table too — a constant global, which any
        // memory summary permits.
        .luce_rt_unwound => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .plain },
            .cold = true,
        },
        // Calls the host's trap callback.  Everything below this line
        // is the host's, so nothing is promised: not the memory it
        // touches, not that it comes back, not that it does not unwind.
        .luce_rt_report => .{
            .memory = null,
            .parameters = &.{ .run, .unknown, .unknown },
            .nounwind = false,
            .willreturn = false,
            .cold = true,
        },
        // Records that the program chose to stop; the unwind that
        // follows rides the trap edge (docs/LANGUAGE.md).
        .luce_rt_exit => .{
            .memory = touches_run,
            .parameters = &.{ .run, .plain },
            .cold = true,
        },

        // -- errors ---------------------------------------------------
        //
        // `raise_error` copies the program's words into run-lifetime
        // storage, because the releases the unwind emits run after it
        // and would otherwise take them back (docs/FAILURE.md); that
        // copy is why it allocates and why the bytes are only read.
        // `raise_io` builds its words the same way.  Neither is `cold`
        // — a file that will not open is ordinary weather, and a
        // program built around `catch` runs this edge as often as the
        // other one.
        .luce_rt_raise_error => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .bytes_in, .plain, .plain, .plain },
        },
        .luce_rt_raise_io => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .bytes_in, .plain, .plain, .plain },
        },
        // One load: the words already in the channel, borrowed.  It
        // allocates nothing — the arena holding them outlives the run —
        // so this is a read of the runtime and a write of the box.
        .luce_rt_error_message => .{
            .memory = touches_run,
            .parameters = &.{ .run, .value_out },
        },
        // One store: the channel is empty again.
        .luce_rt_forget_error => .{
            .memory = .{ .argmem = .write },
            .parameters = &.{.run},
        },
        // The host's, like `luce_rt_report`, and promised nothing for
        // the same reason.
        .luce_rt_report_error => .{
            .memory = null,
            .parameters = &.{ .run, .unknown, .unknown },
            .nounwind = false,
            .willreturn = false,
            .cold = true,
        },

        // -- host text ------------------------------------------------
        //
        // Both copy borrowed bytes into the run's arena, which
        // allocates; `key_text` only hands back the copy already made.
        .luce_rt_intern_text => .{
            .memory = touches_text,
            .parameters = &.{ .run, .bytes_in, .plain, .value_out },
        },
        // The same copy, plus the flag that says whether there was
        // anything to copy.  The bytes are a host's, so nothing is
        // promised about the pointer beyond that it is not kept.
        .luce_rt_maybe_text => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .bytes_in, .plain, .value_out },
        },
        // Splits the host's joined names and builds a List of them,
        // which takes a table row: the object heap moves, so this one
        // names the default location as well.
        .luce_rt_names_list => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .bytes_in, .plain, .value_out },
        },
        // The command line, as the `List(String)` the entry receives.
        // It calls back into the host through the two function pointers
        // it is handed, so nothing about memory can be narrowed beyond
        // "the heap moves": a host callback is anybody's code.
        .luce_rt_args_list => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .unknown, .unknown, .unknown, .value_out },
            .willreturn = false,
        },
        // The byte channel (docs/BYTES.md).  Every one of them calls
        // back into the host through the slots installed at the start
        // of the run, and a host callback is anybody's code — so
        // nothing about memory can be narrowed beyond "the heap
        // moves", the same reason `luce_rt_args_list` cannot be
        // narrowed.
        .luce_rt_files_install => .{
            .memory = touches_run,
            .parameters = &.{ .run, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown },
        },
        // The worker services, every one of them as wide as a call can
        // be: a spawn starts a thread that runs *this module's own
        // code*, and a join waits for one that already did.  Whatever
        // the worker touched, it touched — so nothing here may be
        // narrowed past `touches_heap`, for the reason the file
        // channel's cannot be narrowed past a host callback.
        .luce_rt_workers_install => .{
            .memory = touches_run,
            .parameters = &.{ .run, .unknown, .unknown, .unknown, .unknown, .unknown, .plain },
        },
        .luce_rt_spawn => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .plain, .unknown, .plain, .value_out },
            .willreturn = false,
        },
        .luce_rt_task_wait => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out },
            .willreturn = false,
        },
        // The lock is a store on shared state and a wait on other
        // threads; nothing about it may be moved across anything.
        .luce_rt_effects_enter => .{
            .memory = touches_heap,
            .parameters = &.{.run},
            .willreturn = false,
        },
        .luce_rt_effects_leave => .{
            .memory = touches_heap,
            .parameters = &.{.run},
        },
        .luce_rt_file_open => .{
            .memory = touches_heap,
            .parameters = &.{
                .run,
                .bytes_in,
                .plain,
                .plain,
                .value_out,
                .unknown,
                .plain,
                .plain,
            },
            .willreturn = false,
        },
        .luce_rt_file_read => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in, .unknown, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_file_write => .{
            .memory = touches_heap,
            .parameters = &.{
                .run,
                .value_in,
                .value_in,
                .plain,
                .unknown,
                .unknown,
                .plain,
                .plain,
            },
            .willreturn = false,
        },
        .luce_rt_file_flush => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_file_read_text => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .bytes_in, .plain, .value_out, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_file_write_text => .{
            .memory = touches_heap,
            .parameters = &.{
                .run,
                .bytes_in,
                .plain,
                .bytes_in,
                .plain,
                .plain,
                .unknown,
                .plain,
                .plain,
            },
            .willreturn = false,
        },
        // The backend-neutral window/GPU channel.  These exports resolve
        // resource handles and call arbitrary host callbacks, so the object
        // heap and all host-visible memory remain conservative.  The runtime
        // reports ordinary I/O refusal through the `ok`/outcome pair; a
        // missing channel or malformed answer is a trap.
        .luce_rt_graphics_install => .{
            .memory = touches_run,
            .parameters = &.{
                .run,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
                .unknown,
            },
        },
        .luce_rt_gpu_backend => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .unknown },
            .willreturn = false,
        },
        .luce_rt_ui_window_open => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .bytes_in, .plain, .plain, .plain, .value_out, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_ui_window_surface => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_gpu_surface_size => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .plain, .unknown, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_gpu_surface_clear => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .plain, .plain, .plain, .plain, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_gpu_surface_fill_rect => .{
            .memory = touches_heap,
            .parameters = &.{
                .run,
                .value_in,
                .plain,
                .plain,
                .plain,
                .plain,
                .plain,
                .plain,
                .plain,
                .plain,
                .unknown,
                .plain,
                .plain,
            },
            .willreturn = false,
        },
        .luce_rt_gpu_surface_present => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .unknown, .plain, .plain },
            .willreturn = false,
        },
        .luce_rt_set_key_text => .{
            .memory = touches_text,
            .parameters = &.{ .run, .bytes_in, .plain },
        },
        .luce_rt_key_text => .{
            .memory = touches_run,
            .parameters = &.{ .run, .value_out },
        },

        // -- objects and ownership ------------------------------------
        //
        // Every one of these allocates, frees, or moves ownership in the
        // object table, so every one of them writes the runtime's
        // storage as well as its arguments.
        .luce_rt_new_map,
        .luce_rt_new_builder,
        => .{ .memory = touches_heap, .parameters = &.{ .run, .value_out } },
        // A list is packed at its element's width now, so it is handed
        // the element zero exactly as an array is (docs/BYTES.md R1).
        .luce_rt_new_list => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_new_array => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .numbers_in, .plain, .value_in, .value_out },
        },
        .luce_rt_copy => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out },
            .willreturn = false,
        },

        // -- value storage --------------------------------------------
        //
        // One allocates a String's bytes or a struct's field run, the
        // other gives them back (docs/STRINGS.md).  Neither resolves a
        // handle, so neither names the default location; both write the
        // run's private storage, so neither may be folded or sunk.
        .luce_rt_own_storage => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_drop_storage => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_export_storage => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },

        // -- reference counting (ARC, docs/MEMORY.md) -----------------
        //
        // One raises the reference count of every object a value names,
        // the other drops it and reclaims the objects whose last name is
        // gone.  Both resolve handles and touch the heap, and read a
        // value in without writing one out.
        .luce_rt_retain, .luce_rt_release => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in },
        },
        .luce_rt_weak_store, .luce_rt_weak_load => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out },
        },

        // -- struct values --------------------------------------------
        //
        // Both allocate a fresh run of fields.
        .luce_rt_struct_make, .luce_rt_function_make => .{
            .memory = touches_text,
            .parameters = &.{ .run, .values_in, .plain, .value_out },
        },
        .luce_rt_struct_set => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .plain, .value_in, .value_out },
        },

        // -- containers that only look --------------------------------
        //
        // These resolve the handle, read the container, and write the
        // answer into the out-parameter — plus the trap slot when the
        // index is out of range.  Saying so is what lets `len(xs)` leave
        // a loop that never touches `xs`.
        .luce_rt_len => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_index_get => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .value_in, .values_in, .plain, .value_out },
        },
        .luce_rt_has_key, .luce_rt_find, .luce_rt_contains => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .value_in, .value_in, .value_out },
        },
        .luce_rt_key_at, .luce_rt_value_at, .luce_rt_dim_size => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .value_in, .plain, .value_out },
        },
        .luce_rt_map_get => .{
            .memory = reads_heap,
            .parameters = &.{ .run, .value_in, .value_in, .value_out },
        },

        // -- containers that change something -------------------------
        // `map_place` reads like `map_get` and writes like a store:
        // a key it does not find, it defines.
        .luce_rt_map_place => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in, .value_in, .value_out },
        },
        .luce_rt_index_set => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .values_in, .plain, .value_in },
            .willreturn = false,
        },
        .luce_rt_list_slice => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .plain, .plain, .value_out },
            .willreturn = false,
        },
        .luce_rt_append, .luce_rt_array_fill => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in },
        },
        .luce_rt_remove => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in },
            .willreturn = false,
        },
        .luce_rt_append_ascii => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .plain },
        },
        .luce_rt_pop => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_insert => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .plain, .value_in },
        },
        .luce_rt_sort, .luce_rt_reverse => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in },
        },
        .luce_rt_clear => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in },
            .willreturn = false,
        },
        .luce_rt_map_keys => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in, .value_out },
        },
        .luce_rt_map_values => .{
            .memory = touches_heap,
            .parameters = &.{ .run, .value_in, .value_in, .value_out },
            .willreturn = false,
        },

        // -- strings and conversions ----------------------------------
        //
        // The ones that allocate arena storage write the runtime's
        // memory; the ones that only look at the bytes they were given
        // do not.  `slice` is a borrow of the original bytes, which is
        // why it is on the reading side.
        .luce_rt_concat => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .value_in, .value_out },
        },
        .luce_rt_string_slice => .{
            .memory = reads_text,
            .parameters = &.{ .run, .value_in, .plain, .plain, .value_out },
        },
        .luce_rt_parse_int, .luce_rt_parse_float, .luce_rt_ord => .{
            .memory = reads_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        // Reads immutable bytes and makes valid text.
        .luce_rt_parse_str => .{
            .memory = touches_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        .luce_rt_string_byte => .{
            .memory = reads_text,
            .parameters = &.{ .run, .value_in, .plain, .value_out },
        },
        .luce_rt_string_find_byte => .{
            .memory = reads_text,
            .parameters = &.{ .run, .value_in, .plain, .plain, .value_out },
        },
        .luce_rt_str => .{
            .memory = reads_heap_makes_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },
        // `chr` takes the codepoint itself, not a boxed value.
        .luce_rt_chr => .{
            .memory = touches_text,
            .parameters = &.{ .run, .plain, .value_out },
        },
        .luce_rt_bytes => .{
            .memory = reads_heap_makes_text,
            .parameters = &.{ .run, .value_in, .value_out },
        },

        // -- operators ------------------------------------------------
        //
        // `compare` reads both values, and the String and struct storage
        // behind them, and cannot fail — it takes no runtime at all.
        .luce_rt_compare => .{
            .memory = reads_private,
            .parameters = &.{ .plain, .value_in, .value_in },
        },
        // Three scalars in, an answer out: it reads nothing at all,
        // which is the strongest summary in this file and the only
        // service that earns it.
        .luce_rt_compare_i64_f64 => .{
            .memory = reads_nothing,
            .parameters = &.{ .plain, .plain, .plain },
        },
        // Two scalars in, one out, and the same nothing read — at
        // either float width.
        .luce_rt_float_mod, .luce_rt_float32_mod => .{
            .memory = reads_nothing,
            .parameters = &.{ .plain, .plain },
        },
    };
}

/// How big a `runtime.Value` is, which is what makes a boxed argument
/// `dereferenceable`.  Read from the Zig struct so the promise cannot
/// drift from the layout generated code writes.
// ---------------------------------------------------------------------------
// What each argument promises
// ---------------------------------------------------------------------------

pub const value_size: u32 = @sizeOf(runtime.Value);

/// The alignment every boxed `Value` is allocated at (`lower.zig`'s
/// `value_alignment`), and therefore the alignment a pointer to one
/// carries.
pub const value_align: u32 = @alignOf(runtime.Value);

/// The attributes one parameter shape carries, appended to `into`.
pub fn describeParameter(
    into: *Builder.FunctionAttributes.Wip,
    at: usize,
    shape: Parameter,
    builder: *Builder,
) std.mem.Allocator.Error!void {
    const word: Builder.Alignment.Lazy = .wrap(.fromByteUnits(value_align));
    switch (shape) {
        .plain => {},
        .run => {
            try into.addParamAttr(at, .nocapture, builder);
            try into.addParamAttr(at, .nonnull, builder);
            try into.addParamAttr(at, .noundef, builder);
        },
        .value_in => {
            try into.addParamAttr(at, .nocapture, builder);
            try into.addParamAttr(at, .readonly, builder);
            try into.addParamAttr(at, .nonnull, builder);
            try into.addParamAttr(at, .noundef, builder);
            try into.addParamAttr(at, .{ .dereferenceable = value_size }, builder);
            try into.addParamAttr(at, .{ .@"align" = word }, builder);
        },
        // A run may be empty — a struct with no fields — so it promises
        // its alignment and that it is a real address, but no size.
        .values_in, .numbers_in => {
            try into.addParamAttr(at, .nocapture, builder);
            try into.addParamAttr(at, .readonly, builder);
            try into.addParamAttr(at, .nonnull, builder);
            try into.addParamAttr(at, .noundef, builder);
            try into.addParamAttr(at, .{ .@"align" = word }, builder);
        },
        .value_out => {
            try into.addParamAttr(at, .nocapture, builder);
            try into.addParamAttr(at, .writeonly, builder);
            try into.addParamAttr(at, .nonnull, builder);
            try into.addParamAttr(at, .noundef, builder);
            try into.addParamAttr(at, .{ .dereferenceable = value_size }, builder);
            try into.addParamAttr(at, .{ .@"align" = word }, builder);
        },
        .bytes_in => {
            try into.addParamAttr(at, .nocapture, builder);
            try into.addParamAttr(at, .readonly, builder);
        },
        .bytes_kept => {
            try into.addParamAttr(at, .readonly, builder);
        },
        .unknown => {},
    }
}

/// Every function-level attribute one service carries, as a finished
/// `FunctionAttributes` ready to hang on the declaration.
// ---------------------------------------------------------------------------
// The attribute list a declaration carries
// ---------------------------------------------------------------------------

pub fn attributes(
    service: Service,
    parameters: []const Builder.Type,
    builder: *Builder,
) std.mem.Allocator.Error!Builder.FunctionAttributes {
    const effect = describe(service);
    // The table and the call site have to agree about the shape of
    // every argument, because a pointer promise made about an integer
    // is invalid IR and a pointer described as a scalar is a promise
    // quietly dropped.  Both are compiler bugs, so both assert here
    // rather than reaching LLVM.
    std.debug.assert(effect.parameters.len == parameters.len);
    for (effect.parameters, parameters) |shape, passed| {
        std.debug.assert(shape.isPointer() == (passed == .ptr));
    }

    var wip: Builder.FunctionAttributes.Wip = .{};
    defer wip.deinit(builder);

    if (effect.nounwind) try wip.addFnAttr(.nounwind, builder);
    if (effect.willreturn) try wip.addFnAttr(.willreturn, builder);
    if (effect.cold) try wip.addFnAttr(.cold, builder);
    if (effect.memory) |summary| try wip.addFnAttr(.{ .memory = summary }, builder);
    if (effect.returns_noalias) try wip.addRetAttr(.@"noalias", builder);
    for (effect.parameters, 0..) |shape, at| {
        try describeParameter(&wip, at, shape, builder);
    }
    return wip.finish(builder);
}

test "every service describes exactly the arguments it is called with" {
    // `describe` is total over the enum by construction — the switch has
    // no `else` arm — so what is left to check is that each arm names a
    // plausible parameter list: a runtime-taking export always takes it
    // first, and nothing claims a shape it has no parameter for.
    for (std.enums.values(Service)) |service| {
        const effect = describe(service);
        try std.testing.expect(effect.parameters.len > 0);
        for (effect.parameters[1..]) |shape| {
            try std.testing.expect(shape != .run);
        }
    }
}

test "the boxed-value promises match the layout generated code writes" {
    try std.testing.expectEqual(@as(u32, 24), value_size);
    try std.testing.expectEqual(@as(u32, 8), value_align);
}

test "only final host reporting withholds nounwind and a memory summary" {
    for (std.enums.values(Service)) |service| {
        const effect = describe(service);
        const opaque_to_us = service == .luce_rt_report or service == .luce_rt_report_error;
        try std.testing.expectEqual(!opaque_to_us, effect.nounwind);
        try std.testing.expectEqual(opaque_to_us, effect.memory == null);
    }
}

test "exactly callbacks, waits, deep copies, and release-reachable services withhold willreturn" {
    for (std.enums.values(Service)) |service| {
        const expected = switch (service) {
            .luce_rt_report,
            .luce_rt_report_error,
            .luce_rt_args_list,
            .luce_rt_file_open,
            .luce_rt_file_read,
            .luce_rt_file_write,
            .luce_rt_file_flush,
            .luce_rt_file_read_text,
            .luce_rt_file_write_text,
            .luce_rt_gpu_backend,
            .luce_rt_ui_window_open,
            .luce_rt_ui_window_surface,
            .luce_rt_gpu_surface_size,
            .luce_rt_gpu_surface_clear,
            .luce_rt_gpu_surface_fill_rect,
            .luce_rt_gpu_surface_present,
            .luce_rt_spawn,
            .luce_rt_task_wait,
            .luce_rt_effects_enter,
            .luce_rt_close,
            .luce_rt_constants_abort,
            .luce_rt_discard_loose,
            .luce_rt_copy,
            .luce_rt_index_set,
            .luce_rt_list_slice,
            .luce_rt_remove,
            .luce_rt_clear,
            .luce_rt_map_values,
            => false,
            else => true,
        };
        try std.testing.expectEqual(expected, describe(service).willreturn);
    }
}

// ---------------------------------------------------------------------------
// The description, against the thing described
// ---------------------------------------------------------------------------

/// The pointer `T` is, seeing through an optional, or null when `T` is
/// not one.  A `?[*]const u8` and a `[*]const u8` promise the same
/// thing about the memory; only nullability differs, and that is the
/// caller's business rather than the shape's.
fn pointerOf(comptime T: type) ?std.builtin.Type.Pointer {
    return switch (@typeInfo(T)) {
        .pointer => |shape| shape,
        .optional => |option| switch (@typeInfo(option.child)) {
            .pointer => |shape| shape,
            else => null,
        },
        else => null,
    };
}

/// Whether a Zig parameter type is what `shape` says it is.  Every
/// shape promises pointer-or-not; the six that name a pointee promise
/// that too, and the two that describe memory this compiler knows
/// nothing about (`bytes_kept`, `unknown`) promise only the pointer.
fn describes(comptime shape: Parameter, comptime T: type) bool {
    const pointer = pointerOf(T);
    if (shape.isPointer() != (pointer != null)) return false;
    const at = pointer orelse return true;
    return switch (shape) {
        .plain => unreachable, // not a pointer, returned above
        .run => at.size == .one and at.child == runtime.Runtime,
        .value_in => (at.size == .one or at.size == .c) and
            at.is_const and at.child == runtime.Value,
        .value_out => (at.size == .one or at.size == .c) and
            !at.is_const and at.child == runtime.Value,
        .values_in => (at.size == .many or at.size == .c) and
            at.is_const and at.child == runtime.Value,
        .numbers_in => (at.size == .many or at.size == .c) and
            at.is_const and at.child == i64,
        // C-facing byte inputs may be declared as a Zig many-pointer or
        // as a C-nullable pointer.  Both lower to the same LLVM `ptr`; the
        // latter is what lets the export guard null before slicing.
        .bytes_in => (at.size == .many or at.size == .c) and
            at.is_const and at.child == u8,
        .bytes_kept, .unknown => true,
    };
}

test "every service's described shape is the export's real signature" {
    // `Service` and `describe` are a second, hand-written statement of
    // what `runtime/exports.zig` declares.  Names cannot drift — the
    // symbol is `@tagName`, so a missing export is a link error — but
    // **shapes can**, and nothing is standing behind them: a C object
    // file carries no signatures, so a `declare` with the wrong arity
    // or the wrong pointee links cleanly, runs, and corrupts the stack.
    //
    // So this reads the real thing.  One total over the enum, no
    // `else`: a service whose description stops matching its export is
    // a failed build here, at the commit that moved one of them.
    inline for (comptime std.enums.values(Service)) |service| {
        const effect = comptime describe(service);
        const signature = @typeInfo(@TypeOf(@field(runtime.exports, @tagName(service)))).@"fn";

        if (signature.params.len != effect.parameters.len) {
            std.debug.print(
                "{s}: described with {d} parameter(s), declared with {d}\n",
                .{ @tagName(service), effect.parameters.len, signature.params.len },
            );
            return error.ArityDisagrees;
        }
        inline for (signature.params, effect.parameters, 0..) |declared, shape, at| {
            const T = declared.type.?;
            if (!describes(shape, T)) {
                std.debug.print(
                    "{s}: parameter {d} is described .{s} and declared {s}\n",
                    .{ @tagName(service), at, @tagName(shape), @typeName(T) },
                );
                return error.ShapeDisagrees;
            }
        }
        // `noalias` on the result is a promise about a pointer, and an
        // integer cannot carry one.
        if (effect.returns_noalias and pointerOf(signature.return_type.?) == null) {
            std.debug.print(
                "{s}: returns_noalias on a {s}\n",
                .{ @tagName(service), @typeName(signature.return_type.?) },
            );
            return error.ShapeDisagrees;
        }
    }
}

test "every entry point the library exports is a service" {
    // The table outgrew the default: `std.enums.values` walks every
    // field once at compile time, and there are more than a thousand
    // branches' worth of them now.
    @setEvalBranchQuota(4000);
    // The other direction.  The test above cannot see an export with
    // no `Service` tag, and an entry point generated code has no way
    // to call is either a dead symbol or a missing declaration.
    comptime var exported = 0;
    inline for (@typeInfo(runtime.exports).@"struct".decls) |declaration| {
        if (!comptime std.mem.startsWith(u8, declaration.name, "luce_rt_")) continue;
        if (@typeInfo(@TypeOf(@field(runtime.exports, declaration.name))) != .@"fn") continue;
        exported += 1;
        if (@hasField(Service, declaration.name)) continue;
        std.debug.print("{s} is exported and is not a Service\n", .{declaration.name});
        return error.UndeclaredExport;
    }
    try std.testing.expectEqual(std.enums.values(Service).len, exported);
}
