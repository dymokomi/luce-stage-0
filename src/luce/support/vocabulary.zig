//! The words the compiler and `libluce_rt` both have to say.
//!
//! Four enums: what a binary operator is, what a trap is called, what
//! an error is called, and which file service a failed effect was.
//! They are the whole of what the runtime library needs from the
//! compiler's vocabulary — every other name in `06_mir/defs.zig` is
//! about the shape of a program, which a runtime never sees.
//!
//! **Here rather than in the IR, so the library can stand alone.**
//! `libluce_rt` builds as a real static library and is linked into
//! every artifact; a library that is supposed to stand on its own must
//! not have a source dependency on the front end that happens to share
//! its vocabulary, or a reader cannot tell from the import graph where
//! the library ends.  So the four live below both, in `support/`, and
//! `06_mir.zig` re-exports them: the compiler still says `mir.TrapCode`
//! and there is still exactly one definition of it.  Go solved this
//! with `internal/abi` and Rust by factoring out `rustc_abi`; both
//! treat "the runtime must not depend on the compiler" as a hard line.
//!
//! Trap and error codes are part of the serialized module's wire
//! surface, so adding or reordering one bumps `format_version`.

const std = @import("std");

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    /// `//`.  The integer pair with `modulo`, and they floor together
    /// (docs/NUMERICS.md §3) — the name of the thing is *floor
    /// division*, and under the other pairing `a // b` would not be
    /// `floor(a / b)` for negative operands.
    floor_divide,
    /// `%`.  A modulus and not a remainder: it takes the sign of the
    /// **divisor**, so `-7 % 3` is `2`.  It was called `remainder`
    /// while it was C's, and the two differ on exactly the negatives
    /// the memo spent a table on.
    modulo,
    /// The bit set (docs/BITWISE.md): two's complement on the
    /// integers, Go's precedence, and shifts that move bits rather
    /// than multiply — with the count checked (`shift_out_of_range`),
    /// which is the one place these trap.
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    /// Arithmetic — the operands are signed, and manufacturing a
    /// positive number out of a negative one silently is not the
    /// house posture (D3).  Mask first for the logical reading.
    shift_right,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,

    pub fn isComparison(self: BinaryOp) bool {
        return switch (self) {
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
            else => false,
        };
    }

    /// The same comparison with its operands the other way round.
    ///
    /// Exact long/double comparison is implemented once, in one shape —
    /// the long on the left (docs/NUMERICS.md §5) — so a comparison
    /// written the other way round arrives here rather than at a
    /// second implementation of the same judgment.  Equality is its
    /// own mirror image; arithmetic has none and is refused.
    pub fn mirrored(self: BinaryOp) BinaryOp {
        return switch (self) {
            .equal => .equal,
            .not_equal => .not_equal,
            .less => .greater,
            .less_equal => .greater_equal,
            .greater => .less,
            .greater_equal => .less_equal,
            .add,
            .subtract,
            .multiply,
            .divide,
            .floor_divide,
            .modulo,
            .bit_and,
            .bit_or,
            .bit_xor,
            .shift_left,
            .shift_right,
            => unreachable,
        };
    }
};

/// Why a call failed, from the closed set an error may carry
/// (docs/FAILURE.md).
///
/// **Two codes, and deliberately not four.**  `not_found` and
/// `permission_denied` are the pair every reader expects, and neither
/// can be told the truth here: a host service answers `abi.Answer`,
/// which is `yes`/`no`/`exhausted`, so the boundary the errors come
/// through physically cannot distinguish them.  Inventing the codes
/// would be inventing the distinction.
pub const ErrorCode = enum {
    /// The world said no to an effect: a file that would not read, a
    /// write that did not land.
    io_failed,
    /// `error("…")` — the program decided, and supplied the words.
    user_error,

    /// A static string; the caller owns nothing.
    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .io_failed => "the file operation failed",
            .user_error => "error",
        };
    }
};

/// What a file service was asked to do, so the `io_failed` it raises
/// can say which thing the world refused.  "cannot read x" and "cannot
/// delete x" are different news, and a program that catches one prints
/// what it was told.
///
/// Not part of the `.lcm` wire surface — it names an argument the two
/// engines pass to one runtime call — but it is written here beside
/// `ErrorCode` because both engines have to spell the same verb.
pub const FileAct = enum(i32) {
    read,
    write,
    append,
    delete,
    rename,
    list,
    /// The byte channel's own three (docs/BYTES.md).  Appended, so
    /// nothing renumbers: the ordinal is what crosses into
    /// `luce_rt_raise_io`.
    open,
    flush,

    /// A static string, with its trailing space; the caller owns
    /// nothing.
    pub fn verb(self: FileAct) []const u8 {
        return switch (self) {
            .read => "cannot read ",
            .write => "cannot write ",
            .append => "cannot append to ",
            .delete => "cannot delete ",
            .rename => "cannot rename ",
            .list => "cannot list ",
            .open => "cannot open ",
            .flush => "cannot flush ",
        };
    }
};

pub const TrapCode = enum {
    integer_overflow,
    divide_by_zero,
    conversion_range,
    assertion_failed,
    explicit_trap,
    missing_return,
    call_depth_exceeded,
    string_bounds,
    string_boundary,
    host_unavailable,
    index_bounds,
    key_missing,
    empty_collection,
    use_after_free,
    null_object,
    bad_codepoint,
    not_owned,
    /// A shift count below zero or at/past the operand's width
    /// (docs/BITWISE.md R2).  C leaves this undefined and Go silently
    /// masks; Luce says it out loud.  Appended, so nothing renumbers.
    shift_out_of_range,

    /// The machine could not give the memory a container asked for.
    ///
    /// **This is where an array's ceiling went** (docs/BYTES.md, the
    /// folded ruling): the flat `1 << 24` element cap was a policy
    /// number nothing could see, and what actually limits an array is
    /// the machine.  So a request beyond what it can meet stops the
    /// program *at the site that asked*, with a location and a call
    /// trace like every other trap, rather than being refused at an
    /// arbitrary size or ending the run `exhausted` from somewhere
    /// else.
    ///
    /// **The Linux caveat, stated rather than hidden**: under the
    /// default `vm.overcommit_memory = 0`, a large allocation succeeds
    /// against address space the kernel has not got, and the program is
    /// killed by the OOM killer when it touches the pages instead of
    /// meeting this trap.  Luce cannot fix that from inside the
    /// process, and this trap is honest about what it does catch: a
    /// refusal the allocator reported.
    allocation_failed,

    /// A static string; the caller owns nothing.
    pub fn message(self: TrapCode) []const u8 {
        return switch (self) {
            .integer_overflow => "integer overflow",
            .divide_by_zero => "division by zero",
            .conversion_range => "conversion out of range",
            .assertion_failed => "assertion failed",
            .explicit_trap => "explicit trap",
            .missing_return => "function ended without returning a value",
            .call_depth_exceeded => "call depth exceeded",
            .string_bounds => "string index out of bounds",
            .string_boundary => "string slice splits a UTF-8 sequence",
            .host_unavailable => "host service unavailable",
            .index_bounds => "index out of bounds",
            .key_missing => "key not found in map",
            .empty_collection => "pop from an empty list",
            .use_after_free => "object used after free",
            .null_object => "null object reference",
            .bad_codepoint => "invalid character code",
            .not_owned => "object is owned by a container",
            .shift_out_of_range => "shift count out of range",
            .allocation_failed => "not enough memory for this container",
        };
    }
};
