//! What the language spells for itself — its small public prelude, the
//! compiler-only services used by embedded `std`, the method names each
//! receiver kind answers to, and what each one lowers to.
//!
//! **Data, and one question asked of it.**  Nothing here checks a call
//! or emits an instruction; `builder.zig` does both, and reads these
//! tables to know what it is looking at.  The boundary is honest because
//! the two surfaces are separate data: `builtins` is the public prelude;
//! `standard_intrinsics` is reachable only from compiler-owned standard
//! source through `Builtin.NAME`.  `tools/grammar.zig` generates the
//! editor's TextMate grammar from the public table rather than from a copy,
//! and `www/luce/src/coverage.zig` reads those rows *textually* and holds
//! the public reference to both the names and the parameter names.  The
//! internal table is intentionally neither highlighted nor documented as
//! user syntax.
//!
//! So a public name added to the language reaches the grammar, the
//! reference page and the checker from one row here.  The tests at the
//! bottom hold public rows to the reserved-name list and internal rows out
//! of it: adding a host service must never confiscate an ordinary program
//! name again.

const std = @import("std");
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../mir.zig");
const context = @import("context.zig");
const isReserved = context.isReserved;

const Type = types.Type;

// ---------------------------------------------------------------------------
// The two free-call surfaces
// ---------------------------------------------------------------------------

/// One parameter slot of a builtin: its name, and its default where
/// the corpus asked for one (docs/ARGS.md D10) — the same folded
/// constant a user parameter's default is, at the type the checking
/// switch in `builder.zig` expects for that slot.
pub const Slot = struct {
    name: []const u8,
    default: ?context.TypedConstant = null,
};

/// One compiler-lowered call: what it is called, what it lowers to, the
/// slots it takes, whether it needs the host gate, whether a call to it can
/// leave a container different from how it found it, and whether it
/// answers its operand's own width.  Which source may spell it is decided
/// by the table containing the row, never by this shape.
pub const Builtin = struct {
    name: []const u8,
    kind: mir.Intrinsic,
    /// The signature: **a builtin is a declaration the compiler
    /// writes in a table instead of in Luce, and the table is its
    /// signature** (docs/ARGS.md §3).  `parameters.len` is what
    /// `arity` used to be; the names are what a call site may write,
    /// and the defaults are trailing exactly as a declaration's are.
    parameters: []const Slot = &.{},
    host: bool = false,
    /// False for the two calls that are not a pure walk over their
    /// arguments: `free` ends an object's life, and `error` leaves by
    /// unwinding.  `isPure` reads it, which is what decides whether a
    /// container resolution may be lifted out of a loop
    /// (`effects.zig`).
    pure: bool = true,
    /// True for the eight whose result type *is* their operand's, so
    /// their operands must land where the whole call lands
    /// (docs/TYPES.md §9).  Every other builtin names its own operand
    /// types and takes no landing.  `builder.zig`'s `lowerIntrinsic`
    /// reads it; it was an `else`-guarded switch thousands of lines
    /// away from this table, which is a per-builtin fact written away
    /// from the row it belongs to.
    polymorphic: bool = false,
};

/// `-1` and `false`, as `term_style`'s table row spells them — the
/// two defaults the shipped corpus asked for (docs/ARGS.md §3), and
/// today the only ones any builtin has.
const default_background: context.TypedConstant = .{ .value = .{ .integer = -1 }, .value_type = .i64 };
const default_not_bold: context.TypedConstant = .{ .value = .{ .boolean = false }, .value_type = .boolean };

/// The public prelude: the deliberately small set a program may call
/// without importing a module.  These names are language names and are
/// therefore reserved.  Host APIs other than the universal `print` door do
/// not belong here; they live behind ordinary `std` declarations below.
pub const builtins = [_]Builtin{
    .{ .name = "abs", .kind = .abs, .parameters = &.{.{ .name = "value" }}, .polymorphic = true },
    .{ .name = "min", .kind = .min, .parameters = &.{ .{ .name = "a" }, .{ .name = "b" } }, .polymorphic = true },
    .{ .name = "max", .kind = .max, .parameters = &.{ .{ .name = "a" }, .{ .name = "b" } }, .polymorphic = true },
    .{ .name = "clamp", .kind = .clamp, .parameters = &.{ .{ .name = "value" }, .{ .name = "low" }, .{ .name = "high" } }, .polymorphic = true },
    .{ .name = "sqrt", .kind = .sqrt, .parameters = &.{.{ .name = "value" }}, .polymorphic = true },
    .{ .name = "floor", .kind = .floor, .parameters = &.{.{ .name = "value" }}, .polymorphic = true },
    .{ .name = "ceil", .kind = .ceil, .parameters = &.{.{ .name = "value" }}, .polymorphic = true },
    .{ .name = "trunc", .kind = .trunc, .parameters = &.{.{ .name = "value" }}, .polymorphic = true },
    .{ .name = "len", .kind = .len, .parameters = &.{.{ .name = "value" }} },
    .{ .name = "assert", .kind = .assert_true, .parameters = &.{.{ .name = "condition" }} },
    .{ .name = "trap", .kind = .trap_message, .parameters = &.{.{ .name = "message" }} },
    .{ .name = "error", .kind = .raise_error, .parameters = &.{.{ .name = "message" }}, .pure = false },
    .{ .name = "parse_i64", .kind = .parse_i64, .parameters = &.{.{ .name = "text" }} },
    .{ .name = "parse_f64", .kind = .parse_f64, .parameters = &.{.{ .name = "text" }} },
    .{ .name = "parse_str", .kind = .parse_str, .parameters = &.{.{ .name = "data" }} },
    .{ .name = "print", .kind = .print, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "exit", .kind = .exit_program, .parameters = &.{.{ .name = "status" }}, .host = true, .pure = false },
};

/// The compiler-only bridge used by embedded standard-library source.
/// A standard module spells one of these as `Builtin.NAME`; ordinary
/// project and package source cannot reach this table.  The names are not
/// reserved, highlighted, or part of the language reference.  Their public
/// contracts are the Luce declarations in `src/luce/std/`.
pub const standard_intrinsics = [_]Builtin{
    .{ .name = "file_read", .kind = .file_read, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "file_write", .kind = .file_write, .parameters = &.{ .{ .name = "path" }, .{ .name = "content" } }, .host = true },
    .{ .name = "term_rows", .kind = .term_rows, .host = true },
    .{ .name = "term_cols", .kind = .term_cols, .host = true },
    .{ .name = "term_clear", .kind = .term_clear, .host = true },
    .{ .name = "term_move", .kind = .term_move, .parameters = &.{ .{ .name = "row" }, .{ .name = "column" } }, .host = true },
    .{ .name = "term_style", .kind = .term_style, .host = true, .parameters = &.{
        .{ .name = "fg" },
        .{ .name = "bg", .default = default_background },
        .{ .name = "bold", .default = default_not_bold },
    } },
    .{ .name = "term_write", .kind = .term_write, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "term_copy", .kind = .term_copy, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "term_flush", .kind = .term_flush, .host = true },
    .{ .name = "key_read", .kind = .key_read, .host = true },
    .{ .name = "key_text", .kind = .key_text, .host = true },
    .{ .name = "read_line", .kind = .read_line, .parameters = &.{.{ .name = "prompt" }}, .host = true },
    .{ .name = "print_error", .kind = .print_error, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "clock_ms", .kind = .clock_ms, .host = true },
    .{ .name = "epoch_ms", .kind = .epoch_ms, .host = true },
    .{ .name = "sleep_ms", .kind = .sleep_ms, .parameters = &.{.{ .name = "milliseconds" }}, .host = true },
    .{ .name = "env", .kind = .env_get, .parameters = &.{.{ .name = "name" }}, .host = true },
    .{ .name = "file_append", .kind = .file_append, .parameters = &.{ .{ .name = "path" }, .{ .name = "content" } }, .host = true },
    .{ .name = "file_delete", .kind = .file_delete, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "file_rename", .kind = .file_rename, .parameters = &.{ .{ .name = "from" }, .{ .name = "to" } }, .host = true },
    .{ .name = "dir_list", .kind = .dir_list, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "dir_create", .kind = .dir_create, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "path_kind", .kind = .path_kind, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "gpu_backend", .kind = .gpu_backend, .host = true },
    .{ .name = "ui_window_open", .kind = .ui_window_open, .parameters = &.{
        .{ .name = "title" },
        .{ .name = "width" },
        .{ .name = "height" },
    }, .host = true },
    .{ .name = "ui_window_surface", .kind = .ui_window_surface, .parameters = &.{.{ .name = "window" }}, .host = true },
    .{ .name = "gpu_surface_size", .kind = .gpu_surface_size, .parameters = &.{ .{ .name = "surface" }, .{ .name = "axis" } }, .host = true },
    .{ .name = "gpu_surface_clear", .kind = .gpu_surface_clear, .parameters = &.{ .{ .name = "surface" }, .{ .name = "red" }, .{ .name = "green" }, .{ .name = "blue" }, .{ .name = "alpha" } }, .host = true },
    .{ .name = "gpu_surface_fill_rect", .kind = .gpu_surface_fill_rect, .parameters = &.{
        .{ .name = "surface" }, .{ .name = "x" },     .{ .name = "y" },    .{ .name = "width" }, .{ .name = "height" },
        .{ .name = "red" },     .{ .name = "green" }, .{ .name = "blue" }, .{ .name = "alpha" },
    }, .host = true },
    .{ .name = "gpu_surface_present", .kind = .gpu_surface_present, .parameters = &.{.{ .name = "surface" }}, .host = true },
    .{ .name = "file_open", .kind = .file_open, .parameters = &.{ .{ .name = "path" }, .{ .name = "mode" } }, .host = true },
    .{ .name = "socket_connect", .kind = .socket_connect, .parameters = &.{ .{ .name = "host" }, .{ .name = "port" } }, .host = true },
    .{ .name = "socket_listen", .kind = .socket_listen, .parameters = &.{.{ .name = "port" }}, .host = true },
    .{ .name = "socket_accept", .kind = .socket_accept, .parameters = &.{.{ .name = "listener" }}, .host = true },
    .{ .name = "socket_port", .kind = .socket_port, .parameters = &.{.{ .name = "listener" }}, .host = true },
    .{ .name = "handle_read", .kind = .handle_read, .parameters = &.{ .{ .name = "from" }, .{ .name = "into" } }, .host = true },
    .{ .name = "handle_write", .kind = .handle_write, .parameters = &.{ .{ .name = "to" }, .{ .name = "from" }, .{ .name = "count" } }, .host = true },
    .{ .name = "handle_flush", .kind = .handle_flush, .parameters = &.{.{ .name = "of" }}, .host = true },
    .{ .name = "os_total_memory", .kind = .os_total_memory, .host = true },
    .{ .name = "os_available_memory", .kind = .os_available_memory, .host = true },
    .{ .name = "os_cpu_count", .kind = .os_cpu_count, .host = true },
    .{ .name = "shell_run", .kind = .shell_run, .parameters = &.{ .{ .name = "command" }, .{ .name = "input" } }, .host = true },
    .{ .name = "os_standard_stream", .kind = .os_standard_stream, .parameters = &.{.{ .name = "which" }}, .host = true },
    .{ .name = "process_spawn", .kind = .process_spawn, .parameters = &.{.{ .name = "command" }}, .host = true },
    .{ .name = "process_ready", .kind = .process_ready, .parameters = &.{.{ .name = "child" }}, .host = true },
    .{ .name = "process_wait", .kind = .process_wait, .parameters = &.{.{ .name = "child" }}, .host = true },
    .{ .name = "process_finish_input", .kind = .process_finish_input, .parameters = &.{.{ .name = "child" }}, .host = true },
    .{ .name = "term_event_data", .kind = .term_event_data, .parameters = &.{.{ .name = "field" }}, .host = true },
};

/// Whether a bare public-prelude call can leave a container different from
/// how it found it.  False for anything not named here, including every
/// user function and every `Builtin` method-shaped call, which is the
/// conservative answer `effects.mayMutateContainers` needs.
pub fn isPure(callee: []const u8) bool {
    // `i64(...)` and `f64(...)` are conversions rather than
    // intrinsics, so they are not in the table above; both are pure.
    if (conversionNamed(callee)) |produces| return produces != .str;
    for (builtins) |builtin| {
        if (std.mem.eql(u8, callee, builtin.name)) return builtin.pure;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The methods each receiver kind answers to
// ---------------------------------------------------------------------------

/// The primitive text methods the language keeps for itself, and what each
/// lowers to. Everything else a program writes on `str` routes
/// to the std `strings` module (`builder.zig`'s `stringsCall`,
/// docs/STD.md), so this table is the whole closed set — a table
/// rather than the two `if`s it used to be, because it is the only
/// place these two names are written and the editor grammar reads it
/// (`tools/grammar.zig`).
pub const string_methods = [_]struct {
    name: []const u8,
    kind: mir.Intrinsic,
    takes: []const Type,
    result: Type,
}{
    // The language's primitive byte access.
    // **The one builtin that answers a `u8`** (docs/TYPES.md
    // §9): its result is definitionally one, both engines have
    // always produced 0..255, and it is the natural producer for
    // an `array[u8, _]` gets filled from. A numeric literal compared with the
    // result takes the result's u8 context.
    .{ .name = "byte_at", .kind = .string_byte, .takes = &.{.i64}, .result = .u8 },
    // The scanning primitive that `byte_at` is the access
    // primitive: std strings builds substring search on it, and it
    // is the seam SIMD would enter through (docs/STD.md).
    .{ .name = "find_byte", .kind = .string_find_byte, .takes = &.{ .u8, .i64 }, .result = .i64 },
};

/// The method names each receiver kind answers to — `builder.zig`'s
/// dispatch turns on them, and a "did you mean" needs the same list to
/// measure against.
pub const list_methods = [_][]const u8{
    "append", "insert",  "remove",  "pop",  "clear",
    "sort",   "sort_by", "reverse", "find", "contains",
};
pub const array_methods = [_][]const u8{ "dim", "fill", "sort", "reverse", "find", "contains" };
pub const map_methods = [_][]const u8{ "has", "get", "remove", "keys", "values", "clear" };
pub const builder_methods = [_][]const u8{ "append", "append_ascii", "build", "clear" };

/// A task's one method (docs/THREADS.md D4).  There is no `cancel`
/// and no `done`: a worker owns its own runtime and nothing outside
/// it may reach in, and a question whose answer is stale before it is
/// read is not a question worth answering.  Its last strong release
/// joins it, exactly as a handle's closes it.  The raw `handle` has
/// no method table at all — its byte channel is the
/// `Builtin.handle_*` rows above, called by the standard class that
/// owns the descriptor.
pub const task_methods = [_][]const u8{"wait"};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "every public prelude name is reserved" {
    for (builtins) |builtin| {
        if (!isReserved(builtin.name)) {
            std.debug.print(
                "builtin '{s}' is dispatched but not in reserved_names\n",
                .{builtin.name},
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "compiler-only standard intrinsics reserve no program names" {
    for (standard_intrinsics) |intrinsic| {
        if (isReserved(intrinsic.name)) {
            std.debug.print(
                "standard intrinsic '{s}' leaked into reserved_names\n",
                .{intrinsic.name},
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "receiver methods reserve no program names" {
    inline for (.{ list_methods, array_methods, map_methods, builder_methods, task_methods }) |methods| {
        for (methods) |name| {
            if (isReserved(name)) {
                std.debug.print("receiver method '{s}' leaked into reserved_names\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
    for (string_methods) |method| {
        if (isReserved(method.name)) {
            std.debug.print("string method '{s}' leaked into reserved_names\n", .{method.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "every scalar conversion's name is reserved" {
    for (types.builtin_names) |name| {
        if (types.conversionNamed(name) == null) continue;
        if (!isReserved(name)) {
            std.debug.print("conversion '{s}' is dispatched but not reserved\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "no name is reserved twice" {
    // A duplicate is harmless to `isReserved` and a lie to every
    // reader of the list, including the site page that mirrors it.
    for (context.reserved_names, 0..) |name, index| {
        for (context.reserved_names[index + 1 ..]) |later| {
            if (std.mem.eql(u8, name, later)) {
                std.debug.print("'{s}' is reserved twice\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
}
