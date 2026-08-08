//! What the language spells for itself — the free builtins, the method
//! names each receiver kind answers to, and what each one lowers to.
//!
//! **Data, and one question asked of it.**  Nothing here checks a call
//! or emits an instruction; `builder.zig` does both, and reads these
//! tables to know what it is looking at.  The boundary is honest
//! because the tables were already published: the compiler is not their
//! only reader.  `tools/grammar.zig` generates the editor's TextMate
//! grammar from them rather than from a copy, and `www/luce/src/coverage.zig`
//! reads the rows *textually* out of this file and holds
//! `ref/builtins.md` to both the names and the parameter names.  A copy
//! is exactly how the old grammar came to highlight builtins the
//! language had deleted (tools/vscode-luce/README.md).
//!
//! So a name added to the language reaches the grammar, the reference
//! page and the checker from one row here, and the two tests at the
//! bottom hold that row to the reserved-name list it must also be on.

const std = @import("std");
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../06_mir.zig");
const context = @import("context.zig");
const isReserved = context.isReserved;

const Type = types.Type;

// ---------------------------------------------------------------------------
// The free builtins
// ---------------------------------------------------------------------------

/// One parameter slot of a builtin: its name, and its default where
/// the corpus asked for one (docs/ARGS.md D10) — the same folded
/// constant a user parameter's default is, at the type the checking
/// switch in `builder.zig` expects for that slot.
pub const Slot = struct {
    name: []const u8,
    default: ?context.TypedConstant = null,
};

/// One free builtin: what it is called, what it lowers to, the slots
/// it takes, whether it needs the host gate, whether a call to it can
/// leave a container different from how it found it, and whether it
/// answers its operand's own width.
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
const default_background: context.TypedConstant = .{ .value = .{ .long = -1 }, .value_type = .long };
const default_not_bold: context.TypedConstant = .{ .value = .{ .boolean = false }, .value_type = .boolean };

/// **The one table.**  `builder.zig`'s `lowerIntrinsic` resolves a call
/// through it and `isPure` below asks it what a call costs.  Those were
/// two lists of the same thirty-nine names, 3,375 lines apart in one
/// file, with nothing checking they agreed — so a builtin added to one
/// and not the other silently changed the ownership analysis.
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
    .{ .name = "free", .kind = .free_object, .parameters = &.{.{ .name = "object" }}, .pure = false },
    .{ .name = "parse_int", .kind = .parse_int, .parameters = &.{.{ .name = "text" }} },
    .{ .name = "parse_float", .kind = .parse_float, .parameters = &.{.{ .name = "text" }} },
    .{ .name = "parse_string", .kind = .parse_string, .parameters = &.{.{ .name = "bytes" }} },
    .{ .name = "chr", .kind = .chr_code, .parameters = &.{.{ .name = "code" }} },
    .{ .name = "ord", .kind = .ord_text, .parameters = &.{.{ .name = "text" }} },
    .{ .name = "print", .kind = .print, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "file_read", .kind = .file_read, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "file_write", .kind = .file_write, .parameters = &.{ .{ .name = "path" }, .{ .name = "content" } }, .host = true },
    .{ .name = "file_exists", .kind = .file_exists, .parameters = &.{.{ .name = "path" }}, .host = true },
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
    .{ .name = "term_flush", .kind = .term_flush, .host = true },
    .{ .name = "key_read", .kind = .key_read, .host = true },
    .{ .name = "key_text", .kind = .key_text, .host = true },
    .{ .name = "read_line", .kind = .read_line, .parameters = &.{.{ .name = "prompt" }}, .host = true },
    .{ .name = "print_error", .kind = .print_error, .parameters = &.{.{ .name = "text" }}, .host = true },
    .{ .name = "clock_ms", .kind = .clock_ms, .host = true },
    .{ .name = "sleep_ms", .kind = .sleep_ms, .parameters = &.{.{ .name = "milliseconds" }}, .host = true },
    .{ .name = "env", .kind = .env_get, .parameters = &.{.{ .name = "name" }}, .host = true },
    .{ .name = "file_append", .kind = .file_append, .parameters = &.{ .{ .name = "path" }, .{ .name = "content" } }, .host = true },
    .{ .name = "file_delete", .kind = .file_delete, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "file_rename", .kind = .file_rename, .parameters = &.{ .{ .name = "from" }, .{ .name = "to" } }, .host = true },
    .{ .name = "dir_list", .kind = .dir_list, .parameters = &.{.{ .name = "path" }}, .host = true },
    .{ .name = "file_open", .kind = .file_open, .parameters = &.{ .{ .name = "path" }, .{ .name = "mode" } }, .host = true },
    .{ .name = "exit", .kind = .exit_program, .parameters = &.{.{ .name = "status" }}, .host = true, .pure = false },
    .{ .name = "os_total_memory", .kind = .os_total_memory, .host = true },
    .{ .name = "os_available_memory", .kind = .os_available_memory, .host = true },
    .{ .name = "os_cpu_count", .kind = .os_cpu_count, .host = true },
};

/// Names the language spelled once and does not any more, and what to
/// write instead.
///
/// **A table to empty, never to grow.**  A deleted builtin is normally
/// just an unknown name, and that is the right answer for a private
/// program — but these two are on a public documentation site, and
/// `unknown function arg` points nowhere.  One release of a pointer is
/// worth more here than the purity of having deleted the row; the row
/// itself comes out when the site no longer teaches the old spelling.
pub const retired_builtins = [_]struct {
    name: []const u8,
    instead: []const u8,
}{
    .{ .name = "arg", .instead = "declare func main(args: list(string)): and index args" },
    .{ .name = "arg_count", .instead = "declare func main(args: list(string)): and write len(args)" },
};

/// Whether a call to this builtin can leave a container different
/// from how it found it.  False for anything not named here,
/// including every user function, which is the conservative answer
/// `effects.mayMutateContainers` needs.
pub fn isPure(callee: []const u8) bool {
    // `long(...)` and `double(...)` are conversions rather than
    // intrinsics, so they are not in the table above; both are pure.
    if (conversionNamed(callee)) |produces| return produces != .string;
    for (builtins) |builtin| {
        if (std.mem.eql(u8, callee, builtin.name)) return builtin.pure;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The methods each receiver kind answers to
// ---------------------------------------------------------------------------

/// The string methods the language keeps for itself, and what each
/// lowers to.  Everything else a program writes on a string routes
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
    // **The one builtin that answers a `byte`** (docs/TYPES.md
    // §9): its result is definitionally one, both engines have
    // always produced 0..255, and it is the natural producer for
    // the one place an `array(byte, _)` gets filled from.  It
    // costs nothing at a call site, because a `byte` reaches a
    // `long` parameter and a comparison with nothing written down.
    .{ .name = "byte_at", .kind = .string_byte, .takes = &.{.long}, .result = .byte },
    // The scanning primitive that `byte_at` is the access
    // primitive: std strings builds substring search on it, and it
    // is the seam SIMD would enter through (docs/STD.md).
    .{ .name = "find_byte", .kind = .string_find_byte, .takes = &.{ .byte, .long }, .result = .long },
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
/// The byte channel's three (docs/BYTES.md R4).  There is no
/// `close`: a handle is scope-owned, so `free f` is the close and
/// the end of the owning scope is the automatic one.
pub const file_methods = [_][]const u8{ "read", "write", "flush" };

/// A task's one method (docs/THREADS.md D4).  There is no `cancel`
/// and no `done`: a worker owns its own runtime and nothing outside
/// it may reach in, and a question whose answer is stale before it is
/// read is not a question worth answering.  `free t` is an early join
/// and the end of the owning scope is the automatic one, exactly as
/// for `file`.
pub const task_methods = [_][]const u8{"wait"};

/// Builtin value methods whose result is a fresh object the caller
/// owns (S22).  These three are intrinsics with no signature to
/// consult, so the list is the signature; the method tables above
/// must agree with it.  A method that routes into the standard library
/// is *not* here — `builder.zig`'s `routedMethodYieldsObject` asks its
/// declaration instead, so adding an object-returning `strings`
/// function cannot quietly leak what it returns.
/// `wait` is here for the same reason `pop` is: what it hands back
/// belonged to somebody else a moment ago and belongs to nobody now.
/// A worker's result is *moved* into the joiner's runtime as it
/// crosses (docs/THREADS.md D4), so the binding that receives it owns
/// it, exactly as S16 says of a return.
pub const fresh_object_methods = [_][]const u8{ "pop", "keys", "values", "wait" };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "every free builtin's name is reserved" {
    // Read from the two tables rather than from a copy of either, so
    // adding a builtin and forgetting to reserve its name fails here
    // instead of shipping a name a program can quietly take over.
    //
    // It shipped that way seven times.  The `term_*` services were
    // added to `builtins` and not to `reserved_names`, so
    // `func term_rows():` compiled and stood in front of the builtin
    // for the rest of the program — a name collision the language
    // refuses everywhere else, missed because nothing was checking.
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
