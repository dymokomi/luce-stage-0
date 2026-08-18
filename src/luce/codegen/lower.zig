//! Typed Luce IR to LLVM IR.
//!
//! One walk over a verified `mir.Program` builds an LLVM module with
//! `std.zig.llvm.Builder` — the pure-Zig IR builder in the pinned
//! standard library — and hands back bitcode.  Nothing here links
//! against libLLVM; `emit.zig` owns that boundary.
//!
//! Two rules shape this file, and both come from what the four
//! hand-written backends cost (docs/CODEGEN.md):
//!
//!   * **No `else` arm.**  The switches over `mir.Instruction` and
//!     `mir.Intrinsic` name every tag, so adding an IR instruction is a
//!     compile error here rather than a silent fallthrough — the
//!     deleted backends had 23 `else` arms and that is how a register
//!     corruption bug survived.
//!   * **No `unreachable` for "not yet".**  Anything without a
//!     lowering returns `.unsupported` naming the tag, so a gap is a
//!     clear message rather than a crash or, worse, wrong code.
//!
//! ## What the generated module looks like
//!
//! Each Luce function becomes an `internal` LLVM function
//!
//! ```llvm
//! define internal i32 @"luce.3.gcd"(ptr %host, ptr %rt, i64 %depth, i64 %0, i64 %1, ptr %out)
//! ```
//!
//! whose `i32` result is the **outcome**: zero returned, one trapped,
//! and two raised a catchable Luce error.  A caller branches before
//! reading `%out`; traps unwind, while an error reaches `try`/`catch`.
//! A returned value is written through `%out`, which is absent when
//! the function returns nothing.
//!
//! That convention is internal — `internal` linkage, no stability
//! promise — and it was chosen over the zero-cost alternative (a
//! `noreturn` host callback plus `longjmp`) because it needs no
//! platform unwinding machinery and works unchanged on wasm32, which
//! docs/CODEGEN.md names as a required target.
//!
//! `luce_main` (see `abi.zig`) is the one exported wrapper: it opens a
//! runtime, calls the entry function, and turns the outcome into a status
//! code.
//!
//! Locals live in entry-block `alloca`s that LLVM's mem2reg promotes.
//! Every `alloca` is emitted in the entry block, including scratch
//! slots created deep inside the walk, so nothing accumulates stack
//! inside a loop.
//!
//! ## What is generated and what is called
//!
//! Scalars are generated: checked integer arithmetic, comparison,
//! branches, calls.  Everything below the instruction level —
//! the object heap, ownership, containers, string storage, the
//! conversions — is a call into `libluce_rt` (`../runtime.zig`), which
//! is the same code the interpreter runs.  A Luce value crosses that
//! boundary as a pointer to a 24-byte `Value` in an entry-block
//! `alloca`; `boxed` fills one in and `unboxed` reads one back.
//!
//! Every function therefore carries three hidden arguments before its
//! own: `%host`, `%rt`, and `%depth`.
//!
//! ## Call depth and the call trace
//!
//! Luce promises that runaway recursion traps — with a code, a
//! message, and a call stack — rather than overflowing the machine's
//! own stack.  The interpreter keeps that promise by counting frames
//! on the explicit stack it runs on (`interpreter/machine.zig`).
//! Generated code runs on the native stack, so it counts differently:
//! `%depth` is how many Luce frames are still allowed *including this
//! one*, a callee is handed one less, and a call that would take it to
//! zero traps `call_depth_exceeded` at exactly the call where the
//! interpreter's frame stack would have refused to grow.  It is a
//! subtract and a compare against a constant per call site, in
//! registers, with no memory traffic and nothing to unwind — the
//! cheapest exact form of a limit that has to hold whether or not LLVM
//! inlined the callee.
//!
//! The trace costs nothing at all until a trap happens.  Every exit on
//! the unwinding path — an inline trap, the edge after a call that
//! trapped — first calls `luce_rt_unwound` with this function's index
//! and the instruction it was at, so the trace assembles itself
//! innermost first as the program leaves, and `luce_main` hands the
//! finished thing to the host (`runtime/trace.zig`).  Those two indices
//! are all generated code needs to know: the names and the source
//! positions travel as constant data, emitted once per module and
//! handed to `luce_rt_open`.

const std = @import("std");
const builtin = @import("builtin");
const mir = @import("../mir.zig");
const optimize = @import("../optimize.zig");
const loops = @import("loops.zig");
const mutability = @import("mutability.zig");
const runtime = @import("../runtime.zig");
const types = @import("../support/types.zig");
const abi = @import("abi.zig");
const artifact = @import("artifact.zig");
const effects = @import("runtime_effects.zig");

const Service = effects.Service;

const Allocator = std.mem.Allocator;
const Builder = @import("builder.zig").Builder;
const Tag = Builder.Function.Instruction.Tag;

/// `Builder.WipFunction.Block.Index` is not exported by the standard
/// library, so name it by inference rather than duplicating it.
const BlockIndex = @typeInfo(
    @typeInfo(@TypeOf(Builder.WipFunction.block)).@"fn".return_type.?,
).error_union.payload;

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// The LLVM target triple the generated module carries, e.g.
    /// "arm64-apple-macosx".  A codegen input and nothing else — what
    /// the artifact's *tag* claims is `artifact.machine`, which a loader can
    /// read without LLVM.  `emit.hostTriple` supplies the host one.
    triple: []const u8,
    /// The target whose pointer size and data layout the builder
    /// assumes.  Must describe the same machine as `triple`.
    target: *const std.Target = &builtin.target,
    /// Module name, for readability in dumps.
    name: []const u8 = "luce",
    /// The cache key stamped into the artifact's tag: `artifact.sourceHash`
    /// of the serialized module this program came from.  Zero when the
    /// caller is not building something a loader will cache — an
    /// artifact tagged zero simply never matches a wanted hash.
    source_hash: u64 = 0,
};

pub const Result = union(enum) {
    /// LLVM bitcode; the caller owns it and frees it with the same
    /// allocator it passed to `lower`.
    bitcode: []const u8,
    /// Some construct has no lowering yet.  The payload names it
    /// ("intrinsic.map_get", "opaque type") and is static storage — nothing
    /// was allocated, and there is nothing to free.
    unsupported: []const u8,
};

/// Lower a verified program to LLVM bitcode.  The program is borrowed
/// and unchanged; on success the caller owns `Result.bitcode`.
pub fn lower(
    gpa: Allocator,
    program: *const mir.Program,
    options: Options,
) error{OutOfMemory}!Result {
    var builder = try start(gpa, options);
    defer builder.deinit();
    if (try build(gpa, program, &builder, options)) |what| return .{ .unsupported = what };

    const words = try builder.toBitcode(gpa, .{
        .name = "luce",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    defer gpa.free(words);
    return .{ .bitcode = try gpa.dupe(u8, std.mem.sliceAsBytes(words)) };
}

pub const TextResult = union(enum) {
    /// Textual LLVM IR; the caller owns it.
    text: []const u8,
    /// As `Result.unsupported`.
    unsupported: []const u8,
};

/// The same lowering rendered as textual LLVM IR instead of bitcode —
/// what a reader (or a test) needs to see what was actually generated.
pub fn lowerToText(
    gpa: Allocator,
    program: *const mir.Program,
    options: Options,
) error{OutOfMemory}!TextResult {
    var builder = try start(gpa, options);
    defer builder.deinit();
    if (try build(gpa, program, &builder, options)) |what| return .{ .unsupported = what };

    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    builder.print(&written.writer) catch |mistake| switch (mistake) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return .{ .text = try gpa.dupe(u8, written.written()) };
}

/// An empty module tagged for `options`.  The caller owns it.
fn start(gpa: Allocator, options: Options) error{OutOfMemory}!Builder {
    return Builder.init(.{
        .allocator = gpa,
        .strip = true,
        .name = options.name,
        .target = options.target,
        .triple = options.triple,
    });
}

/// Fill `builder` in from `program`.  Returns the tag that has no
/// lowering yet, or null when the whole program lowered.
fn build(
    gpa: Allocator,
    program: *const mir.Program,
    builder: *Builder,
    options: Options,
) error{OutOfMemory}!?[]const u8 {
    var module: Module = .{
        .gpa = gpa,
        .program = program,
        .builder = builder,
        .options = options,
    };
    defer module.deinit();

    module.build() catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return module.unsupported,
    };
    return null;
}

// ---------------------------------------------------------------------------
// Module-wide state
// ---------------------------------------------------------------------------

const Error = error{ OutOfMemory, Unsupported };

/// What a Luce function answers its caller.  The same three numbers
/// `libluce_rt`'s fallible calls use, plus the one only a Luce call
/// can give: `2` means it came back **errored** rather than returning,
/// and its caller either propagates or catches (docs/FAILURE.md).
/// Internal to the generated module — `internal` linkage, no stability
/// promise — and distinct from `abi.Status`, which is what `luce_main`
/// hands the outside world.
const outcome_ok: u32 = 0;
const outcome_trapped: u32 = 1;
const outcome_errored: u32 = 2;

/// One LLVM module under construction, plus the tables that keep the
/// per-function walks from rebuilding shared things.
const Module = struct {
    gpa: Allocator,
    program: *const mir.Program,
    builder: *Builder,
    /// What the artifact will say about itself (`artifact.Artifact`).
    options: Options,

    /// Set alongside `error.Unsupported`; static storage.
    unsupported: []const u8 = "",

    /// `{ ptr, ptr, ptr, ptr }` — the `abi.Host` table.
    host_type: Builder.Type = .none,
    /// `{ ptr, i64 }` — how a Luce `str` travels in generated code.
    string_type: Builder.Type = .none,
    /// `{ i64, i64, i64 }` — `runtime.Value`, how anything travels into
    /// `libluce_rt`.  The layout is asserted against the Zig struct in
    /// `runtime/value.zig`.
    value_type: Builder.Type = .none,

    /// The two alias scopes generated code distinguishes, built on
    /// first use (task #45): **rows** — the object table's rows, an
    /// array's `dims`, and the table base pointer in the runtime —
    /// and **elements** — the storage element loads and stores reach.
    /// The two never overlap by construction: rows live in the object
    /// table's allocation, dims in their own written only at creation,
    /// elements in theirs — and a Luce program has no way to make one
    /// name the other.  Each access carries its own scope in
    /// `!alias.scope` and the *other* in `!noalias`, which is exactly
    /// what lets LICM hoist a row's facts out of a loop that stores
    /// elements.  Runtime calls carry neither and stay conservative.
    alias_rows_list: Builder.Metadata.Optional = .none,
    alias_elements_list: Builder.Metadata.Optional = .none,

    /// One LLVM function per Luce function, parallel to
    /// `program.functions`.
    functions: []Builder.Function.Index = &.{},
    /// The pointer table a call through a function value dispatches
    /// through, and the name table `str(f)` reads — both built on
    /// first use and null in a program that makes no function value
    /// (docs/FUNCTIONS.md D2, D3).
    function_table: ?Builder.Variable.Index = null,
    function_names: ?Builder.Variable.Index = null,

    /// The eager program-root builder shared by `luce_main` and every
    /// worker runtime.  Absent when reachability pruning left no
    /// container constants, which keeps the old prologue and all six
    /// materialization services out of such a module entirely.
    constant_materializer: ?Builder.Function.Index = null,
    /// Unique suffix for private `Value` runs that represent folded
    /// struct atoms before `luce_rt_own_storage` copies them into one
    /// runtime's storage.
    constant_value_serial: u32 = 0,

    /// The zero value of each struct layout, as a pointer to a private
    /// constant run of `Value`s.  Built on first use, shared by every
    /// zero-initialized local and array element — safe because struct
    /// storage is never written to after it is built (`struct_set`
    /// allocates a fresh run), which is the same reason the interpreter
    /// shares one template per layout.
    struct_zeros: []?Builder.Constant = &.{},

    /// The same, one per union (docs/UNION.md D13): the first declared
    /// member with every payload field at its own zero, padded to the
    /// union's one static run length.
    variant_zeros: []?Builder.Constant = &.{},

    /// Interned `{ ptr, i64 }` constants for text, keyed by content.
    /// Keys are borrowed from the program's arena or from static
    /// storage, both of which outlive this module.
    texts: std.StringHashMapUnmanaged(Builder.Constant) = .empty,

    /// Declarations of the `libluce_rt` entry points this module calls,
    /// one slot per `effects.Service`, filled on first use.
    services: std.EnumMap(Service, Builder.Function.Index) = .{},

    /// One retired object row, read in place of a null handle's when a
    /// resolution is lifted out of a loop (`loops.zig`).  A lifted
    /// resolution loads the row without deciding anything about it, so
    /// it has to be safe to load from even when the handle names no
    /// object; this is what makes it so.  Its element pointer is null
    /// and never read — the null check stays at the access and traps
    /// first — and its generation is `runtime.retired`, which no
    /// handle carries, so an access that somehow reached the liveness
    /// test would still trap rather than follow that pointer.
    dead_row: ?Builder.Constant = null,

    /// Every function this program spawns, in ascending order, or
    /// empty when it never spawns (docs/THREADS.md D11).
    ///
    /// **This list is what D11 is made of.**  When it is empty nothing
    /// below emits a single instruction it would not have emitted
    /// before threads existed: no worker trampoline, no install call in
    /// the prologue, and no effect lock around a host service.  A
    /// spawn-free program's module is the module it always was, which
    /// is a stronger promise than "the lock is cheap" and is checked
    /// rather than asserted (`codegen/test.zig`).
    spawned: []const u32 = &.{},

    /// The `RunFn` a worker's thread enters through, built once when
    /// `spawned` is non-empty.  No closure travels the C boundary and
    /// none exists to: a `spawn` names a top-level function, so what
    /// crosses is a function *index* and a run of boxed arguments, and
    /// this is the switch that turns the first back into a call.
    worker_entry: ?Builder.Function.Index = null,

    /// The engine callback `Runtime` enters when a class reaches its last
    /// strong reference.  It dispatches a verified hidden function index to
    /// the corresponding Luce body and is absent from programs with no
    /// deinitializers.
    finalizer_entry: ?Builder.Function.Index = null,

    /// One entry per program function: the adapter a value of it is
    /// called through, or `null` for a function no value ever names.
    ///
    /// **The table a function value dispatches through is a table of
    /// adapters, not of functions**, because a call site cannot know
    /// whether the value it holds carries a receiver: one
    /// `func(Point, Point) -> bool` place accepts a plain function, a
    /// lambda and a bind, and a C signature is chosen at compile time
    /// (docs/BINDING.md D12).  So every entry takes a receiver, and the
    /// adapter for a plain function ignores it.
    entries: []?Builder.Function.Index = &.{},
    witness_tables: ?WitnessTables = null,

    const WitnessTables = struct {
        layouts: Builder.Variable.Index,
        offsets: Builder.Variable.Index,
        methods: Builder.Variable.Index,
    };

    fn deinit(self: *Module) void {
        self.gpa.free(self.spawned);
        self.gpa.free(self.entries);
        self.gpa.free(self.functions);
        self.gpa.free(self.struct_zeros);
        self.gpa.free(self.variant_zeros);
        self.texts.deinit(self.gpa);
        self.* = undefined;
    }

    /// Record why lowering stopped and bail.  Named for the reporting,
    /// per the coding guide.
    fn fail(self: *Module, what: []const u8) Error {
        if (self.unsupported.len == 0) self.unsupported = what;
        return error.Unsupported;
    }

    // -- types ---------------------------------------------------------

    /// The LLVM type a Luce value of type `of` travels in.  `.none`
    /// maps to `void`, which is only ever a return type.
    fn valueType(self: *Module, written: types.Type) Error!Builder.Type {
        // **An enum is the integer it is stored at**, here and at every
        // other place this file asks a type a machine question
        // (docs/ENUMS.md D10).  Answering it once, at the top, is what
        // keeps that sentence in one place — and what lets the arm
        // below say `unreachable` honestly rather than "not yet".
        const of = written.storage();
        return switch (of) {
            .none => .void,
            .boolean => .i1,
            .u8, .i8 => .i8,
            .u16, .i16 => .i16,
            .u32, .i32, .char => .i32,
            .u64, .i64 => .i64,
            .f16 => .half,
            .f32 => .float,
            .f64 => .double,
            .str, .bytes => self.string_type,
            // A heap object is a `runtime.Handle`: the row of the
            // object table it lives in, and which occupant of that
            // row it is, packed as the `Value.bits` word carries them
            // (index low, generation high).  The row, not the value,
            // owns the object.
            .heap => .i64,
            // A struct is a pointer to its run of `Value` fields —
            // the layout `libluce_rt` already reads, so a struct
            // crosses into the runtime without being rebuilt.
            .strukt => .ptr,
            // `{T, i1}` for every payload — the payload beside a bit
            // that says whether it is there.  One shape, no sentinel.
            //
            // docs/FAILURE.md proposed the null handle for a heap `T?`
            // and that index is already spoken for: the null handle is
            // the zero of an object-typed place (S40), a value that is
            // *present* and traps on use, and a program can put one in
            // a `T?` — `look(raw)` against `func look(xs: list[i64]?)`
            // borrows one in without a diagnostic, and the interpreter
            // answers "present" because absence there is the tag, not
            // the payload.  A sentinel would answer "absent" and the
            // two engines would part company. i64, f64, bool,
            // str and structs have no spare value to sentinel with
            // anyway, so the bit is what the other six payloads cost;
            // spending it on the seventh buys nothing and costs the
            // one representation both engines can be checked against.
            //
            // SROA keeps the pair in registers, so absence is a flag
            // the machine already had.
            .optional => |payload| self.builder.structType(
                .normal,
                &.{ try self.valueType(payload.asType()), .i1 },
            ),
            // A union value is a struct value whose field 0 is the tag
            // (docs/UNION.md D8): a pointer to its run of `Value`s.
            .variant => .ptr,
            // A function value is the two-slot run `boxTag` calls a
            // struct: the function it names, then the receiver it
            // carries (docs/BINDING.md D12).  A pointer to that run,
            // for the same reason a struct is one.
            .function => .ptr,
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// Where the payload and the presence bit sit in a lowered `T?`.
    const optional_payload = 0;
    const optional_present = 1;

    /// The C signature of one host service, as generated code calls it
    /// (`abi.zig`).  One switch with no `else`, so a new slot is a
    /// compile error here rather than a call through a wrong type.
    fn hostType(self: *Module, slot: abi.Slot) Error!Builder.Type {
        const builder = self.builder;
        return switch (slot) {
            .context => self.fail("the host context called as a service"),
            .print => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            // Never called from here: `luce_main` hands the pointer to
            // `luce_rt_report`, which is what knows the trace.  Named
            // and typed anyway, so the table stays fully described.
            .trap => builder.fnType(
                .void,
                &.{ .ptr, .i32, .ptr, .i64, .ptr, .i64, .i64 },
                .normal,
            ),
            // Never called from here either: `luce_main` hands the
            // pointer to `luce_rt_report_error`, which is what holds
            // the error and the one position it carries.
            .raised => builder.fnType(.void, &.{ .ptr, .i32, .ptr, .i64, .ptr }, .normal),
            .finished => builder.fnType(.void, &.{ .ptr, .i64 }, .normal),
            // A path in, a kind code in an out-parameter, an answer
            // that may be "the world will not say".
            .path_kind => builder.fnType(.i32, &.{ .ptr, .ptr, .i64, .ptr }, .normal),
            .arg_count, .term_rows, .term_cols => builder.fnType(.i64, &.{.ptr}, .normal),
            .term_event_data => builder.fnType(.i64, &.{ .ptr, .i64 }, .normal),
            .arg => builder.fnType(.i32, &.{ .ptr, .i64, .ptr, .ptr }, .normal),
            .term_clear, .term_flush => builder.fnType(.i32, &.{.ptr}, .normal),
            .term_move => builder.fnType(.i32, &.{ .ptr, .i64, .i64 }, .normal),
            .term_style => builder.fnType(.i32, &.{ .ptr, .i64, .i64, .i32 }, .normal),
            .term_write => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .term_copy => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .key_read => builder.fnType(.i32, &.{ .ptr, .ptr, .ptr, .ptr, .ptr }, .normal),
            .call_depth => builder.fnType(.i64, &.{.ptr}, .normal),
            // Prompt in, line out — one call, so the prompt is on the
            // screen before the host blocks.
            .read_line, .env => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .ptr, .ptr },
                .normal,
            ),
            .print_error => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .clock_ms => builder.fnType(.i64, &.{.ptr}, .normal),
            .sleep_ms => builder.fnType(.i32, &.{ .ptr, .i64 }, .normal),
            .file_rename => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .ptr, .i64 },
                .normal,
            ),
            .file_delete, .dir_create => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .dir_list => builder.fnType(.i32, &.{ .ptr, .ptr, .i64, .ptr, .ptr }, .normal),
            .exited => builder.fnType(.void, &.{ .ptr, .i64 }, .normal),
            // One shape for all three machine facts and for the wall
            // clock: nothing to ask with, a number in an
            // out-parameter, an answer that may be "cannot tell".
            .os_total_memory,
            .os_available_memory,
            .os_cpu_count,
            .epoch_ms,
            => builder.fnType(.i32, &.{ .ptr, .ptr }, .normal),
            // The backend-neutral window/GPU channel.  These callbacks are
            // installed into the runtime at entry and are not called by
            // generated code directly, but keeping their exact C shapes here
            // makes every ABI slot checked by the same exhaustive table.
            .gpu_backend => builder.fnType(.i32, &.{ .ptr, .ptr }, .normal),
            .ui_window_open => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .i64, .i64, .ptr },
                .normal,
            ),
            .ui_window_surface => builder.fnType(.i32, &.{ .ptr, .i64, .ptr }, .normal),
            .gpu_surface_size => builder.fnType(.i32, &.{ .ptr, .i64, .i64, .ptr }, .normal),
            .gpu_surface_clear => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .i64, .i64, .i64, .i64 },
                .normal,
            ),
            .gpu_surface_fill_rect => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .i64, .i64, .i64, .i64, .i64, .i64, .i64, .i64 },
                .normal,
            ),
            .gpu_surface_present => builder.fnType(.i32, &.{ .ptr, .i64 }, .normal),
            .gpu_close => builder.fnType(.i32, &.{ .ptr, .i64, .i64 }, .normal),
            // The handle channel (docs/BYTES.md).  Named and typed
            // here like `trap` is, and called from here for the same
            // reason it is not: the five pointers are handed to
            // `luce_rt_files_install` at the start of the run, and
            // `libluce_rt` is what calls them.
            .handle_open => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .i64, .ptr },
                .normal,
            ),
            .handle_read => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .ptr, .i64, .ptr },
                .normal,
            ),
            // The transport channel's five (version 25): handed to
            // `luce_rt_sockets_install` at the start of the run like
            // the handle five, and called only by `libluce_rt`.
            .socket_connect => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .i64, .ptr },
                .normal,
            ),
            .socket_listen => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .ptr },
                .normal,
            ),
            .socket_accept => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .ptr },
                .normal,
            ),
            .socket_port => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .ptr },
                .normal,
            ),
            .socket_close => builder.fnType(
                .i32,
                &.{ .ptr, .i64 },
                .normal,
            ),
            .handle_write => builder.fnType(
                .i32,
                &.{ .ptr, .i64, .ptr, .i64, .ptr },
                .normal,
            ),
            .handle_flush, .handle_close => builder.fnType(
                .i32,
                &.{ .ptr, .i64 },
                .normal,
            ),
            // The thread channel (docs/THREADS.md D8).  Named and typed
            // here and called from `libluce_rt`, exactly as the handle
            // channel is: a task's join happens inside the ownership
            // walk, where no generated code is standing.
            .worker_spawn => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .ptr, .ptr },
                .normal,
            ),
            .worker_join => builder.fnType(.i32, &.{ .ptr, .i64 }, .normal),
            .shell_run => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .ptr, .ptr },
                .normal,
            ),
        };
    }

    /// Declare one `libluce_rt` entry point, interned per service.  The
    /// parameter types come from the values at the call site, so this
    /// file never writes a runtime signature down twice — and the
    /// attributes come from `runtime_effects.zig`, which is the one
    /// place that says what a runtime call does to memory, whether it
    /// unwinds, and whether it comes back.  Without them a declaration
    /// is the most pessimistic thing LLVM can be handed.
    fn service(
        self: *Module,
        which: Service,
        result: Builder.Type,
        parameters: []const Builder.Type,
    ) Error!Builder.Function.Index {
        if (self.services.get(which)) |found| return found;
        const signature_type = try self.builder.fnType(result, parameters, .normal);
        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString(which.symbol()),
            .default,
        );
        declared.setLinkage(.external, self.builder);
        declared.setAttributes(
            try effects.attributes(which, parameters, self.builder),
            self.builder,
        );
        self.services.put(which, declared);
        return declared;
    }

    /// Frame alignment for a value of `of`.  Only types `valueType`
    /// accepts ever reach a frame slot; the rest are named anyway so
    /// this file stays free of `else` arms.
    fn valueAlignment(written: types.Type) Builder.Alignment {
        const of = written.storage();
        return switch (of) {
            .boolean, .u8, .i8 => Builder.Alignment.fromByteUnits(1),
            .u16, .i16, .f16 => Builder.Alignment.fromByteUnits(2),
            .u32, .i32, .f32, .char => Builder.Alignment.fromByteUnits(4),
            .none,
            .u64,
            .i64,
            .f64,
            .str,
            .bytes,
            .strukt,
            .variant,
            .function,
            .heap,
            .optional,
            => Builder.Alignment.fromByteUnits(8),
            .enumeration => unreachable, // answered by storage() above
        };
    }

    // -- text constants ------------------------------------------------

    /// A pointer to `text`'s bytes in a private, constant global,
    /// interned by content.
    fn textBytes(self: *Module, text: []const u8) Error!Builder.Constant {
        if (self.texts.get(text)) |found| return found;

        const bytes = try self.builder.string(text);
        const initializer = try self.builder.stringConst(bytes);
        const name = try self.builder.strtabStringFmt("luce.text.{d}", .{self.texts.count()});
        const variable = try self.builder.addVariable(
            name,
            initializer.typeOf(self.builder),
            .default,
        );
        try variable.setInitializer(initializer, self.builder);
        variable.setMutability(.constant, self.builder);
        const global = variable.ptrConst(self.builder).global;
        global.setLinkage(.private, self.builder);
        global.setUnnamedAddr(.unnamed_addr, self.builder);

        const made = variable.toConst(self.builder);
        try self.texts.put(self.gpa, text, made);
        return made;
    }

    /// A `{ ptr, i64 }` constant for `text` — how a Luce `str` travels
    /// through generated code.  The builder interns constants, so
    /// asking twice costs nothing twice.
    fn textConstant(self: *Module, text: []const u8) Error!Builder.Constant {
        return self.builder.structConst(self.string_type, &.{
            try self.textBytes(text),
            try self.builder.intConst(.i64, text.len),
        });
    }

    // -- what the artifact says about itself -----------------------------

    /// The constant table a trap's call trace is resolved through: one
    /// entry per Luce function, in program order, followed by one per
    /// constant-container declaration.  A function holds one
    /// `line:column` per instruction; a declaration holds its one
    /// allocation origin (`runtime/trace.zig`).  Answers a pointer to
    /// the table.
    ///
    /// A `--release` program was stripped before it got here, so its
    /// entries carry names and no origins — which is exactly the
    /// difference docs/MODES.md describes, arrived at by emitting less
    /// rather than by behaving differently.
    fn describeFunctions(self: *Module) Error!Builder.Constant {
        const info_type = try self.builder.structType(
            .normal,
            &.{ .ptr, .i64, .ptr, .i64, .ptr, .i64 },
        );
        var entries: std.ArrayList(Builder.Constant) = .empty;
        defer entries.deinit(self.gpa);
        for (self.program.functions, 0..) |*function, index| {
            try entries.append(self.gpa, try self.builder.structConst(info_type, &.{
                try self.textBytes(function.name),
                try self.builder.intConst(.i64, function.name.len),
                try self.textBytes(function.source),
                try self.builder.intConst(.i64, function.source.len),
                try self.originTable(function, index),
                try self.builder.intConst(.i64, function.origins.len),
            }));
        }
        for (self.program.container_constants, 0..) |constant, index| {
            const stripped = constant.source.len == 0;
            try entries.append(self.gpa, try self.builder.structConst(info_type, &.{
                try self.textBytes(constant.name),
                try self.builder.intConst(.i64, constant.name.len),
                try self.textBytes(constant.source),
                try self.builder.intConst(.i64, constant.source.len),
                if (stripped)
                    try self.builder.nullConst(.ptr)
                else
                    try self.constantOrigin(constant, index),
                try self.builder.intConst(.i64, @intFromBool(!stripped)),
            }));
        }

        const table_type = try self.builder.arrayType(entries.items.len, info_type);
        const variable = try self.builder.addVariable(
            try self.builder.strtabString("luce.functions"),
            table_type,
            .default,
        );
        try variable.setInitializer(
            try self.builder.arrayConst(table_type, entries.items),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        return variable.toConst(self.builder);
    }

    /// One function's `line:column` per instruction, as a private
    /// constant array — or a null pointer when the program was
    /// stripped, which is what tells the runtime to report no lines.
    fn originTable(self: *Module, function: *const mir.Function, index: usize) Error!Builder.Constant {
        if (function.origins.len == 0) return self.builder.nullConst(.ptr);

        const origin_type = try self.builder.structType(.normal, &.{ .i32, .i32 });
        var places: std.ArrayList(Builder.Constant) = .empty;
        defer places.deinit(self.gpa);
        for (function.origins) |origin| {
            try places.append(self.gpa, try self.builder.structConst(origin_type, &.{
                try self.builder.intConst(.i32, origin.line),
                try self.builder.intConst(.i32, origin.column),
            }));
        }

        const run_type = try self.builder.arrayType(places.items.len, origin_type);
        const variable = try self.builder.addVariable(
            try self.builder.strtabStringFmt("luce.origins.{d}", .{index}),
            run_type,
            .default,
        );
        try variable.setInitializer(
            try self.builder.arrayConst(run_type, places.items),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        return variable.toConst(self.builder);
    }

    /// A constant declaration's sole allocation origin.  Unlike a
    /// function's instruction table this is always exactly one entry
    /// in a debug artifact; stripping clears both source and origin,
    /// so the caller omits the global altogether in release output.
    fn constantOrigin(
        self: *Module,
        constant: mir.ContainerConstant,
        index: usize,
    ) Error!Builder.Constant {
        const origin_type = try self.builder.structType(.normal, &.{ .i32, .i32 });
        const run_type = try self.builder.arrayType(1, origin_type);
        const variable = try self.builder.addVariable(
            try self.builder.strtabStringFmt("luce.origins.constant.{d}", .{index}),
            run_type,
            .default,
        );
        try variable.setInitializer(
            try self.builder.arrayConst(run_type, &.{try self.builder.structConst(
                origin_type,
                &.{
                    try self.builder.intConst(.i32, constant.origin.line),
                    try self.builder.intConst(.i32, constant.origin.column),
                },
            )}),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        return variable.toConst(self.builder);
    }

    /// The retired row a lifted resolution reads for a null handle:
    /// `{ generation = runtime.retired, everything else zero }`.
    /// The two scope lists, built once (the field doc has the whole
    /// argument).  A domain, two scopes uniqued by their name strings,
    /// and one single-scope list each.
    fn aliasScopes(self: *Module) Error!struct {
        rows: Builder.Metadata,
        elements: Builder.Metadata,
    } {
        if (self.alias_rows_list.unwrap()) |rows| {
            return .{ .rows = rows, .elements = self.alias_elements_list.unwrap().? };
        }
        const builder = self.builder;
        const domain = try builder.metadataTuple(&.{
            (try builder.metadataString("luce.alias")).toMetadata(),
        });
        const rows_scope = try builder.metadataTuple(&.{
            (try builder.metadataString("luce.rows")).toMetadata(),
            domain,
        });
        const elements_scope = try builder.metadataTuple(&.{
            (try builder.metadataString("luce.elements")).toMetadata(),
            domain,
        });
        const rows = try builder.metadataTuple(&.{rows_scope});
        const elements = try builder.metadataTuple(&.{elements_scope});
        self.alias_rows_list = rows.toOptional();
        self.alias_elements_list = elements.toOptional();
        return .{ .rows = rows, .elements = elements };
    }

    fn deadRow(self: *Module) Error!Builder.Constant {
        if (self.dead_row) |found| return found;
        // Zeroes, the generation where `runtime.layout` says it sits,
        // then zeroes again.  Packed, because the offset comes from
        // `@offsetOf` and Zig places a plain struct's fields where it
        // likes: LLVM must lay these three out exactly as given and
        // insert no padding of its own.
        const leading_type = try self.builder.arrayType(runtime.layout.generation, .i8);
        const trailing_type = try self.builder.arrayType(
            runtime.layout.row_size - runtime.layout.generation - @sizeOf(u32),
            .i8,
        );
        const run_type = try self.builder.structType(
            .@"packed",
            &.{ leading_type, .i32, trailing_type },
        );
        const variable = try self.builder.addVariable(
            try self.builder.strtabString("luce.dead.row"),
            run_type,
            .default,
        );
        try variable.setInitializer(try self.builder.structConst(run_type, &.{
            try self.builder.zeroInitConst(leading_type),
            try self.builder.intConst(.i32, runtime.retired),
            try self.builder.zeroInitConst(trailing_type),
        }), self.builder);
        variable.setMutability(.constant, self.builder);
        variable.setAlignment(
            Builder.Alignment.fromByteUnits(runtime.layout.row_alignment),
            self.builder,
        );
        const global = variable.ptrConst(self.builder).global;
        global.setLinkage(.private, self.builder);
        const made = variable.toConst(self.builder);
        self.dead_row = made;
        return made;
    }

    // -- struct zeros ----------------------------------------------------

    /// A pointer to the zero value of struct layout `which`: a private
    /// constant run of `Value`s, one per field, built once per layout.
    /// Nested struct fields point at their own layout's zero, so the
    /// whole tree is constant and costs nothing at runtime.
    fn structZero(self: *Module, which: u32) Error!Builder.Constant {
        if (self.struct_zeros.len == 0) {
            self.struct_zeros = try self.gpa.alloc(?Builder.Constant, self.program.structs.len);
            @memset(self.struct_zeros, null);
        }
        if (self.struct_zeros[which]) |found| return found;

        const layout = self.program.structs[which];
        var fields: std.ArrayList(Builder.Constant) = .empty;
        defer fields.deinit(self.gpa);
        if (layout.interface) {
            try fields.append(self.gpa, try self.zeroField(.i64));
            try fields.append(self.gpa, try self.zeroField(.none));
        } else {
            for (layout.fields) |field| {
                // The analyzer rejects struct cycles, so this bottoms out.
                try fields.append(self.gpa, if (field.weak)
                    try self.constantBox(
                        .weak,
                        0,
                        try self.builder.intConst(.i64, runtime.null_index),
                        0,
                    )
                else
                    try self.zeroField(field.field_type));
            }
        }

        const run_type = try self.builder.arrayType(layout.runLength(), self.value_type);
        const initializer = try self.builder.arrayConst(run_type, fields.items);
        const name = try self.builder.strtabStringFmt("luce.zero.{s}", .{layout.name});
        const variable = try self.builder.addVariable(name, run_type, .default);
        try variable.setInitializer(initializer, self.builder);
        variable.setMutability(.constant, self.builder);
        const global = variable.ptrConst(self.builder).global;
        global.setLinkage(.private, self.builder);

        const made = variable.toConst(self.builder);
        self.struct_zeros[which] = made;
        return made;
    }

    /// A pointer to the zero value of union `which` (docs/UNION.md
    /// D13): slot 0 holds member index zero — the first declared
    /// member — then that member's field zeros, then `none` padding up
    /// to the union's one static run length.  D12 has already refused
    /// every member that could make this recurse, so it bottoms out
    /// for every union stage 4 accepted.
    fn variantZero(self: *Module, which: u32) Error!Builder.Constant {
        if (self.variant_zeros.len == 0) {
            self.variant_zeros = try self.gpa.alloc(?Builder.Constant, self.program.variants.len);
            @memset(self.variant_zeros, null);
        }
        if (self.variant_zeros[which]) |found| return found;

        const declared = self.program.variants[which];
        const span = declared.runLength();
        var slots: std.ArrayList(Builder.Constant) = .empty;
        defer slots.deinit(self.gpa);
        // Member index zero boxes exactly as a `i64` zero does, which
        // is what the interpreter parks in the same slot.
        try slots.append(self.gpa, try self.zeroField(.i64));
        for (declared.members[0].fields) |field| {
            try slots.append(self.gpa, try self.zeroField(field.field_type));
        }
        while (slots.items.len < span) {
            try slots.append(self.gpa, try self.zeroField(.none));
        }

        const run_type = try self.builder.arrayType(span, self.value_type);
        const initializer = try self.builder.arrayConst(run_type, slots.items);
        const name = try self.builder.strtabStringFmt("luce.zero.{s}", .{declared.name});
        const variable = try self.builder.addVariable(name, run_type, .default);
        try variable.setInitializer(initializer, self.builder);
        variable.setMutability(.constant, self.builder);
        const global = variable.ptrConst(self.builder).global;
        global.setLinkage(.private, self.builder);

        const made = variable.toConst(self.builder);
        self.variant_zeros[which] = made;
        return made;
    }

    /// An integer's bits at the width it is stored at, zero-extended
    /// into the word a `runtime.Value` carries — what boxing a narrow
    /// number does, said for a constant one.
    fn narrowBits(held: i128, at: types.Type) u64 {
        const bits: u64 = @truncate(@as(u128, @bitCast(held)));
        return switch (at.numericBits()) {
            8 => bits & 0xff,
            16 => bits & 0xffff,
            32 => bits & 0xffff_ffff,
            else => bits,
        };
    }

    /// One field of a zero struct, as a constant `runtime.Value`.  The
    /// zeroes here are the interpreter's (`Machine.zeroValue`): an empty
    /// `str` is length zero, and an object-typed field is the null
    /// handle, which traps rather than touching anything.
    fn zeroField(self: *Module, written: types.Type) Error!Builder.Constant {
        // A struct's enum field zeroes at its **first member**, which
        // is a number the enum table holds, not zero (docs/ENUMS.md).
        // Everything after that is the backing width's own zero.
        const of = written.storage();
        const first_member: u64 = switch (written) {
            // Boxed the way `boxBits` boxes one: only the backing
            // width's own bits, so a negative member at a `i16` is
            // 0xffff and not a sign-extended word (`runtime.Value`).
            .enumeration => |reference| narrowBits(
                self.program.enums[reference.index].members[0].value,
                reference.backing.asType(),
            ),
            else => 0,
        };
        const tag: runtime.Tag, const bits: Builder.Constant = switch (of) {
            .none => .{ .none, try self.builder.intConst(.i64, 0) },
            .boolean => .{ .boolean, try self.builder.intConst(.i64, 0) },
            .u8 => .{ .u8, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .u16 => .{ .u16, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .u32 => .{ .u32, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .u64 => .{ .u64, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .i8 => .{ .i8, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .i16 => .{ .i16, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .i32 => .{ .i32, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .i64 => .{ .i64, try self.builder.intConst(.i64, @as(i64, @bitCast(first_member))) },
            .f16 => .{ .f16, try self.builder.intConst(.i64, 0) },
            .f32 => .{ .f32, try self.builder.intConst(.i64, 0) },
            .f64 => .{ .f64, try self.builder.intConst(.i64, 0) },
            .char => .{ .char, try self.builder.intConst(.i64, 0) },
            .str => .{ .str, try self.builder.intConst(.i64, 0) },
            .bytes => .{ .bytes, try self.builder.intConst(.i64, 0) },
            .heap => .{ .object, try self.builder.intConst(.i64, runtime.null_index) },
            .strukt => |nested| .{ .strukt, try self.builder.castConst(
                .ptrtoint,
                try self.structZero(nested),
                .i64,
            ) },
            // The zero of a `T?` is absence, and absence is the `none`
            // tag with no payload — the very `Value` the interpreter
            // parks in the same field (S43).
            .optional => .{ .none, try self.builder.intConst(.i64, 0) },
            // A union field zeroes at its own table's first member
            // (docs/UNION.md D13), never a struct row's — and boxes as
            // the field run it is (D8).
            .variant => |nested| .{ .strukt, try self.builder.castConst(
                .ptrtoint,
                try self.variantZero(nested),
                .i64,
            ) },
            .enumeration => unreachable, // answered by storage() above
            // Compiler-generated interface layouts keep bound function
            // values in private dispatch fields.  A null function value is
            // the representation's zero; calling it follows the same null
            // indirect-call trap as any uninitialized function slot.
            .function => .{ .function, try self.builder.intConst(.i64, 0) },
        };
        const length: u64 = switch (of) {
            .strukt => |nested| self.program.structs[nested].runLength(),
            .variant => |nested| self.program.variants[nested].runLength(),
            .function => mir.function_run_length,
            else => 0,
        };
        // An empty str's zero says its bytes are outside, at the
        // null address, none of them — which reads as `""` and owns
        // nothing, the same value `Value.ofStr("")` is.
        const form: u8 = switch (of) {
            .str, .bytes => runtime.text_outside,
            else => 0,
        };
        const head = try self.builder.arrayType(8 - runtime.inline_at, .i8);
        return self.builder.structConst(self.value_type, &.{
            try self.builder.intConst(.i8, @intFromEnum(tag)),
            try self.builder.intConst(.i8, form),
            try self.builder.zeroInitConst(head),
            bits,
            try self.builder.intConst(.i64, length),
        });
    }

    /// One folded atom as the borrowed `runtime.Value` the
    /// materializer hands to `luce_rt_own_storage`.  The folded union
    /// carries a number at its widest family member; `wanted` supplies
    /// the concrete width and therefore the exact runtime tag, just as
    /// an ordinary MIR result type does when `Body.boxed` lowers it.
    fn constantValue(
        self: *Module,
        folded: mir.ConstantValue,
        wanted: types.Type,
    ) Error!Builder.Constant {
        var expected = wanted;
        if (expected == .optional) {
            if (folded == .absent) return self.constantBox(
                .none,
                0,
                try self.builder.intConst(.i64, 0),
                0,
            );
            expected = expected.optional.asType();
        } else if (folded == .absent) {
            return self.fail("absence outside an optional constant field");
        }

        const stored = expected.storage();
        const tag = mir.boxTag(expected) orelse
            return self.fail("an optional constant atom without a presence decision");
        var form: u8 = 0;
        var length: u64 = 0;
        const bits: Builder.Constant = switch (folded) {
            .boolean => |held| blk: {
                if (stored != .boolean) return self.fail("a Boolean constant at another type");
                break :blk try self.builder.intConst(.i64, @intFromBool(held));
            },
            .integer => |held| blk: {
                if (!stored.isInteger() and stored != .char) return self.fail("an integer constant at another type");
                break :blk try self.builder.intConst(
                    .i64,
                    @as(i64, @bitCast(narrowBits(held, stored))),
                );
            },
            .float => |held| blk: {
                const raw: u64 = switch (stored) {
                    .f16 => raw: {
                        const narrowed: f16 = @floatCast(held);
                        const word: u16 = @bitCast(narrowed);
                        break :raw word;
                    },
                    .f32 => raw: {
                        const narrowed: f32 = @floatCast(held);
                        const word: u32 = @bitCast(narrowed);
                        break :raw word;
                    },
                    .f64 => @bitCast(held),
                    else => return self.fail("a floating constant at another type"),
                };
                break :blk try self.builder.intConst(.i64, @as(i64, @bitCast(raw)));
            },
            .str => |index| blk: {
                if (stored != .str and stored != .bytes) return self.fail("a byte-run constant at another type");
                const text = self.program.constants[index];
                form = runtime.text_outside;
                length = text.len;
                break :blk try self.builder.castConst(
                    .ptrtoint,
                    try self.textBytes(text),
                    .i64,
                );
            },
            .strukt => |held| blk: {
                if (stored != .strukt or stored.strukt != held.layout) {
                    return self.fail("a struct constant at another layout");
                }
                length = held.fields.len;
                break :blk try self.builder.castConst(
                    .ptrtoint,
                    try self.constantFields(held),
                    .i64,
                );
            },
            .absent => unreachable, // answered before the type was peeled
        };
        return self.constantBox(tag, form, bits, length);
    }

    /// The private borrowed field run behind one folded struct atom.
    /// `luce_rt_own_storage` recursively copies it into the runtime, so
    /// these pointers are never retained by a run and remain constant
    /// artifact data.
    fn constantFields(
        self: *Module,
        folded: mir.ConstantValue.Struct,
    ) Error!Builder.Constant {
        const layout = self.program.structs[folded.layout];
        var fields: std.ArrayList(Builder.Constant) = .empty;
        defer fields.deinit(self.gpa);
        for (folded.fields, layout.fields) |field, declared| {
            if (declared.weak) {
                if (field != .absent) return self.fail("a non-absent weak constant field");
                try fields.append(self.gpa, try self.constantBox(
                    .weak,
                    0,
                    try self.builder.intConst(.i64, runtime.null_index),
                    0,
                ));
            } else {
                try fields.append(self.gpa, try self.constantValue(field, declared.field_type));
            }
        }

        const run_type = try self.builder.arrayType(fields.items.len, self.value_type);
        const variable = try self.builder.addVariable(
            try self.builder.strtabStringFmt(
                "luce.constant.fields.{d}",
                .{self.constant_value_serial},
            ),
            run_type,
            .default,
        );
        self.constant_value_serial += 1;
        try variable.setInitializer(
            try self.builder.arrayConst(run_type, fields.items),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        return variable.toConst(self.builder);
    }

    /// Assemble the C layout of one `runtime.Value` constant.
    fn constantBox(
        self: *Module,
        tag: runtime.Tag,
        form: u8,
        bits: Builder.Constant,
        length: u64,
    ) Error!Builder.Constant {
        const head = try self.builder.arrayType(8 - runtime.inline_at, .i8);
        return self.builder.structConst(self.value_type, &.{
            try self.builder.intConst(.i8, @intFromEnum(tag)),
            try self.builder.intConst(.i8, form),
            try self.builder.zeroInitConst(head),
            bits,
            try self.builder.intConst(.i64, @as(i64, @bitCast(length))),
        });
    }

    // -- construction --------------------------------------------------

    fn build(self: *Module) Error!void {
        self.string_type = try self.builder.structType(.normal, &.{ .ptr, .i64 });
        self.value_type = try self.builder.structType(.normal, &.{
            .i8, // tag
            .i8, // inline_length
            // `inline_head`: the inline run's first bytes, up to where
            // `bits` begins.  The rest of the run *is* `bits` and
            // `length`, which is what makes twenty-two of them fit.
            try self.builder.arrayType(8 - runtime.inline_at, .i8),
            .i64, // bits
            .i64, // length
        });
        self.host_type = try self.builder.structType(
            .normal,
            &([_]Builder.Type{.ptr} ** abi.Slot.count),
        );

        // Declare every Luce function before lowering any body, so
        // forward calls and recursion need no fix-up pass.
        self.functions = try self.gpa.alloc(Builder.Function.Index, self.program.functions.len);
        for (self.program.functions, 0..) |*function, index| {
            const signature_type = try self.signature(function);
            const name = try self.builder.strtabStringFmt(
                "luce.{d}.{s}",
                .{ index, function.name },
            );
            const declared = try self.builder.addFunction(signature_type, name, .default);
            declared.setLinkage(.internal, self.builder);
            declared.setAttributes(try self.functionAttributes(function), self.builder);
            self.functions[index] = declared;
        }

        if (self.program.container_constants.len != 0) {
            try self.lowerConstantMaterializer();
        }

        self.spawned = try self.collectSpawned();
        if (self.spawned.len != 0) try self.lowerWorkerEntry();
        try self.lowerFinalizerEntry();

        try self.lowerValueEntries();

        for (self.program.functions, 0..) |*function, index| {
            try self.lowerFunction(function, @intCast(index));
        }
        try self.lowerEntry();
        try self.describeArtifact();
    }

    /// `i32 @luce.constants(ptr rt)` — eagerly build every reachable
    /// constant-container row in this runtime and publish it under the
    /// program root (CONSTANTS.md R-C).
    ///
    /// The same helper is called once by `luce_main` and once by every
    /// worker trampoline, preserving THREADS.md's share-nothing rule.
    /// Every fallible edge converges on one cleanup: discard the one
    /// loose construction, abort earlier roots, record the declaration
    /// whose allocation failed, and answer the ordinary trapped outcome.
    fn lowerConstantMaterializer(self: *Module) Error!void {
        std.debug.assert(self.program.container_constants.len != 0);
        const signature_type = try self.builder.fnType(.i32, &.{.ptr}, .normal);
        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString("luce.constants"),
            .default,
        );
        declared.setLinkage(.internal, self.builder);
        self.constant_materializer = declared;

        var wip: Builder.WipFunction = try .init(self.builder, .{
            .function = declared,
            .strip = true,
        });
        defer wip.deinit();

        const entry = try wip.block(0, "entry");
        const failed = try wip.block(self.materializerFailureEdges(), "constants.failed");
        wip.cursor = .{ .block = entry };
        const rt = wip.arg(0);
        const value_alignment = Builder.Alignment.fromByteUnits(@alignOf(runtime.Value));
        const number_alignment = Builder.Alignment.fromByteUnits(@alignOf(i64));
        const index_alignment = Builder.Alignment.fromByteUnits(@alignOf(u32));
        const target = try wip.alloca(
            .normal,
            self.value_type,
            .none,
            value_alignment,
            .default,
            "constant.target",
        );
        const source = try wip.alloca(
            .normal,
            self.value_type,
            .none,
            value_alignment,
            .default,
            "constant.source",
        );
        const owned = try wip.alloca(
            .normal,
            self.value_type,
            .none,
            value_alignment,
            .default,
            "constant.owned",
        );
        const subscript = try wip.alloca(
            .normal,
            self.value_type,
            .none,
            value_alignment,
            .default,
            "constant.subscript",
        );
        const dimension = try wip.alloca(
            .normal,
            .i64,
            .none,
            number_alignment,
            .default,
            "constant.dimension",
        );
        const current = try wip.alloca(
            .normal,
            .i32,
            .none,
            index_alignment,
            .default,
            "constant.current",
        );
        const none = try self.zeroField(.none);
        _ = try wip.store(.normal, none.toValue(), target, value_alignment);
        _ = try wip.store(
            .normal,
            try self.builder.intValue(.i32, 0),
            current,
            index_alignment,
        );

        try self.materializerChecked(&wip, failed, .luce_rt_constants_begin, &.{
            rt,
            try self.builder.intValue(.i32, self.program.container_constants.len),
        });

        for (self.program.container_constants, 0..) |constant, index| {
            _ = try wip.store(
                .normal,
                try self.builder.intValue(.i32, index),
                current,
                index_alignment,
            );
            _ = try wip.store(.normal, none.toValue(), target, value_alignment);

            const descriptor = self.program.heap_types[constant.heap];
            switch (descriptor) {
                .class => unreachable, // classes are runtime values, never constants
                .list => |element| {
                    _ = try wip.store(
                        .normal,
                        (try self.zeroField(element)).toValue(),
                        source,
                        value_alignment,
                    );
                    try self.materializerChecked(&wip, failed, .luce_rt_new_list, &.{
                        rt,
                        source,
                        target,
                    });
                    for (constant.payload.sequence) |folded| {
                        const held = try self.materializerValue(
                            &wip,
                            failed,
                            rt,
                            source,
                            owned,
                            folded,
                            element,
                        );
                        try self.materializerChecked(&wip, failed, .luce_rt_append, &.{
                            rt,
                            target,
                            held,
                        });
                    }
                },
                .array => |shape| {
                    _ = try wip.store(
                        .normal,
                        try self.builder.intValue(.i64, constant.payload.sequence.len),
                        dimension,
                        number_alignment,
                    );
                    _ = try wip.store(
                        .normal,
                        (try self.zeroField(shape.element)).toValue(),
                        source,
                        value_alignment,
                    );
                    try self.materializerChecked(&wip, failed, .luce_rt_new_array, &.{
                        rt,
                        dimension,
                        try self.builder.intValue(.i64, 1),
                        source,
                        target,
                    });
                    for (constant.payload.sequence, 0..) |folded, at| {
                        _ = try wip.store(
                            .normal,
                            (try self.constantValue(.{ .integer = @intCast(at) }, .i64)).toValue(),
                            subscript,
                            value_alignment,
                        );
                        const held = try self.materializerValue(
                            &wip,
                            failed,
                            rt,
                            source,
                            owned,
                            folded,
                            shape.element,
                        );
                        try self.materializerChecked(&wip, failed, .luce_rt_index_set, &.{
                            rt,
                            target,
                            subscript,
                            try self.builder.intValue(.i64, 1),
                            held,
                        });
                    }
                },
                .map => |pair| {
                    try self.materializerChecked(&wip, failed, .luce_rt_new_map, &.{
                        rt,
                        target,
                    });
                    for (constant.payload.map) |entry_value| {
                        _ = try wip.store(
                            .normal,
                            // A key is stored as the integer a `i64`
                            // key would be, folded or not
                            // (`mir.mapKeyStorage`): the materializer
                            // fills the same slot every lookup will.
                            (try self.constantValue(
                                entry_value.key,
                                mir.mapKeyStorage(pair.key),
                            )).toValue(),
                            subscript,
                            value_alignment,
                        );
                        const held = try self.materializerValue(
                            &wip,
                            failed,
                            rt,
                            source,
                            owned,
                            entry_value.value,
                            pair.value,
                        );
                        try self.materializerChecked(&wip, failed, .luce_rt_index_set, &.{
                            rt,
                            target,
                            subscript,
                            try self.builder.intValue(.i64, 1),
                            held,
                        });
                    }
                },
                .builder, .handle, .task => return self.fail(
                    "a non-container in the constant-container pool",
                ),
            }
            try self.materializerChecked(&wip, failed, .luce_rt_constant_publish, &.{
                rt,
                try self.builder.intValue(.i32, index),
                target,
            });
        }

        _ = try self.callService(&wip, .luce_rt_constants_finish, .void, &.{rt}, "");
        _ = try wip.ret(try self.builder.intValue(.i32, outcome_ok));

        wip.cursor = .{ .block = failed };
        _ = try self.callService(&wip, .luce_rt_discard_loose, .void, &.{ rt, target }, "");
        _ = try self.callService(&wip, .luce_rt_constants_abort, .void, &.{rt}, "");
        const declaration = try wip.bin(
            .add,
            try wip.load(.normal, .i32, current, index_alignment, "constant.failed.at"),
            try self.builder.intValue(.i32, self.program.functions.len),
            "constant.declaration",
        );
        _ = try self.callService(&wip, .luce_rt_unwound, .void, &.{
            rt,
            declaration,
            try self.builder.intValue(.i32, 0),
        }, "");
        _ = try wip.ret(try self.builder.intValue(.i32, outcome_trapped));
        try wip.finish();
    }

    /// Number of branches that converge on the materializer's one
    /// cleanup block: `begin`, one create and one publish per row, one
    /// store per atom, and an additional storage copy only for the atom
    /// kinds that own bytes or a struct run.
    fn materializerFailureEdges(self: *const Module) u32 {
        var count: usize = 1;
        for (self.program.container_constants) |constant| {
            count += 2;
            switch (self.program.heap_types[constant.heap]) {
                .list => |element| for (constant.payload.sequence) |_| {
                    count += 1 + @as(usize, @intFromBool(constantOwnsStorage(element)));
                },
                .array => |shape| for (constant.payload.sequence) |_| {
                    count += 1 + @as(usize, @intFromBool(constantOwnsStorage(shape.element)));
                },
                .map => |pair| for (constant.payload.map) |_| {
                    count += 1 + @as(usize, @intFromBool(constantOwnsStorage(pair.value)));
                },
                .class, .builder, .handle, .task => {},
            }
        }
        return @intCast(count);
    }

    /// Whether a folded atom of this type has storage the row must own
    /// a copy of — bytes or a field run.  A union's run is freed exactly
    /// as a struct's, so it answers the same; no `ConstantValue` builds
    /// one today, and the answer is here rather than in a default so
    /// that stays true by construction and not by luck.
    fn constantOwnsStorage(of: types.Type) bool {
        return switch (of) {
            .str, .bytes, .strukt, .variant => true,
            .optional => |payload| constantOwnsStorage(payload.asType()),
            // Scalars are their own storage; an object is a handle the
            // row's container call takes.
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .f16,
            .f32,
            .f64,
            .char,
            .heap,
            .enumeration,
            .function,
            => false,
        };
    }

    /// Store one folded atom in `source`, copying it through the
    /// runtime only when its type owns storage.  Scalars pass their box
    /// straight to the consuming container call, avoiding a C call per
    /// CRC-table entry while preserving the ordinary store contract.
    fn materializerValue(
        self: *Module,
        wip: *Builder.WipFunction,
        failed: BlockIndex,
        rt: Builder.Value,
        source: Builder.Value,
        owned: Builder.Value,
        folded: mir.ConstantValue,
        of: types.Type,
    ) Error!Builder.Value {
        _ = try wip.store(
            .normal,
            (try self.constantValue(folded, of)).toValue(),
            source,
            Builder.Alignment.fromByteUnits(@alignOf(runtime.Value)),
        );
        if (!constantOwnsStorage(of)) return source;
        try self.materializerChecked(wip, failed, .luce_rt_own_storage, &.{
            rt,
            source,
            owned,
        });
        return owned;
    }

    /// Call one fallible materialization service and continue in a new
    /// block only when it returned zero.  The failed edge owns all
    /// cleanup, so no call site can forget half of it.
    fn materializerChecked(
        self: *Module,
        wip: *Builder.WipFunction,
        failed: BlockIndex,
        which: Service,
        arguments: []const Builder.Value,
    ) Error!void {
        const result = try self.callService(wip, which, .i32, arguments, "constant.result");
        const next = try wip.block(1, "constant.next");
        _ = try wip.brCond(
            try wip.icmp(
                .ne,
                result,
                try self.builder.intValue(.i32, 0),
                "constant.failed",
            ),
            failed,
            next,
            .else_likely,
        );
        wip.cursor = .{ .block = next };
    }

    /// Every function some `spawn` names, ascending and without
    /// duplicates.  The caller owns the slice.
    fn collectSpawned(self: *Module) Error![]const u32 {
        var found: std.ArrayList(u32) = .empty;
        errdefer found.deinit(self.gpa);
        for (self.program.functions) |function| {
            for (function.instructions) |instruction| {
                const target = switch (instruction) {
                    .spawn => |call| call.function,
                    else => continue,
                };
                if (std.mem.indexOfScalar(u32, found.items, target) != null) continue;
                try found.append(self.gpa, target);
            }
        }
        std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
        return found.toOwnedSlice(self.gpa);
    }

    /// One adapter per function named by a function value or interface
    /// witness. Interface targets are bound to the existential payload but
    /// do not allocate a bound-function value at runtime.
    ///
    /// A program that makes no function value emits none of this, the
    /// way a program that never spawns emits no worker entry.
    fn lowerValueEntries(self: *Module) Error!void {
        self.entries = try self.gpa.alloc(?Builder.Function.Index, self.program.functions.len);
        @memset(self.entries, null);
        var any = false;
        for (self.program.interface_witnesses) |witness| {
            for (witness.methods) |function| {
                if (self.entries[function] != null) continue;
                self.entries[function] = try self.lowerValueEntry(function, true);
                any = true;
            }
        }
        for (self.program.functions) |function| {
            for (function.instructions) |instruction| {
                const named = switch (instruction) {
                    .const_function => |value| value,
                    else => continue,
                };
                if (self.entries[named.function] != null) continue;
                self.entries[named.function] = try self.lowerValueEntry(
                    named.function,
                    named.receiver != null,
                );
                any = true;
            }
        }
        if (!any) {
            self.gpa.free(self.entries);
            self.entries = &.{};
        }
    }

    /// `i32 @luce.bound.N(ptr host, ptr rt, i64 depth, ptr receiver,
    /// <written parameters>, ptr result)` — the shape every function
    /// value is called through.
    ///
    /// For a plain function the receiver slot is one unused argument.
    /// For a bind it is the value's own environment, boxed, and this is
    /// where it becomes the callee's parameter zero — the one place in
    /// the backend that knows what a receiver's type is, which is why
    /// the call site does not have to (docs/BINDING.md D12).
    fn lowerValueEntry(
        self: *Module,
        function_index: u32,
        is_bound: bool,
    ) Error!Builder.Function.Index {
        const function = &self.program.functions[function_index];
        const bound: u32 = if (is_bound) 1 else 0;

        var parameters: std.ArrayList(Builder.Type) = .empty;
        defer parameters.deinit(self.gpa);
        try parameters.appendSlice(self.gpa, &.{ .ptr, .ptr, .i64, .ptr });
        for (function.locals[bound..function.parameter_count]) |parameter| {
            try parameters.append(self.gpa, try self.valueType(parameter.local_type));
        }
        if (function.return_type != .none) try parameters.append(self.gpa, .ptr);
        const signature_type = try self.builder.fnType(.i32, parameters.items, .normal);

        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabStringFmt("luce.bound.{d}", .{function_index}),
            .default,
        );
        declared.setLinkage(.internal, self.builder);

        var wip: Builder.WipFunction = try .init(self.builder, .{
            .function = declared,
            .strip = true,
        });
        defer wip.deinit();
        const entry = try wip.block(0, "entry");
        wip.cursor = .{ .block = entry };

        var arm: Body = .{
            .module = self,
            .wip = &wip,
            .function = function,
            .index = function_index,
            .host = wip.arg(0),
            .runtime = wip.arg(1),
            .depth = wip.arg(2),
            .entry_block = entry,
        };
        defer arm.deinit();

        var passed: std.ArrayList(Builder.Value) = .empty;
        defer passed.deinit(self.gpa);
        try passed.appendSlice(self.gpa, &.{ wip.arg(0), wip.arg(1), wip.arg(2) });
        if (bound == 1) {
            try passed.append(self.gpa, if (function.locals[0].inout)
                wip.arg(3)
            else
                try arm.unboxed(
                    function.locals[0].local_type,
                    wip.arg(3),
                    "bound.self",
                ));
        }
        // The written parameters stand after the receiver slot, whether
        // this adapter uses that slot or not.
        for (bound..function.parameter_count) |at| {
            try passed.append(self.gpa, wip.arg(@intCast(4 + at - bound)));
        }
        if (function.return_type != .none) {
            try passed.append(self.gpa, wip.arg(@intCast(4 + function.parameter_count - bound)));
        }

        const target = self.functions[function_index];
        _ = try wip.ret(try wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            target.typeOf(self.builder),
            target.toValue(self.builder),
            passed.items,
            "bound.outcome",
        ));
        try wip.finish();
        return declared;
    }

    /// `i32 @luce.worker(ptr host, ptr rt, i64 which, ptr args, i64
    /// count, ptr out, i64 depth)` — the one door a worker's thread
    /// enters this module through (docs/THREADS.md).
    ///
    /// **This is what a spawn's "entry closure" is, and it is not a
    /// closure.**  Function values exist elsewhere in a Luce program,
    /// but `spawn` itself still names a declaration.  The only two
    /// things that cross this C boundary are which declaration and
    /// what to hand it — an index and a run of boxed `Value`s.  This
    /// switch turns the index back into a direct call, so the worker
    /// entry needs no callback pointer and the callee remains a static
    /// target LLVM can inline into.
    ///
    /// The host table travels as the nursery's context, so the worker
    /// reaches the same services `main` does — serialized, because the
    /// effect lock is installed by then (D9).
    fn lowerWorkerEntry(self: *Module) Error!void {
        const signature_type = try self.builder.fnType(
            .i32,
            &.{ .ptr, .ptr, .i64, .ptr, .i64, .ptr, .i64 },
            .normal,
        );
        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString("luce.worker"),
            .default,
        );
        declared.setLinkage(.internal, self.builder);
        self.worker_entry = declared;

        var wip: Builder.WipFunction = try .init(self.builder, .{
            .function = declared,
            .strip = true,
        });
        defer wip.deinit();

        const entry = try wip.block(0, "entry");
        wip.cursor = .{ .block = entry };
        const host = wip.arg(0);
        const started = wip.arg(1);
        const which = wip.arg(2);
        const arguments = wip.arg(3);
        const out = wip.arg(5);
        const depth = wip.arg(6);

        // A worker owns a runtime of its own (THREADS.md D1), so it
        // owns a program-root table of its own too.  The generated
        // helper is absent when pruning left no pool, and this branch
        // therefore emits literally nothing in the common case.
        if (self.constant_materializer) |materializer| {
            const outcome = try wip.call(
                .normal,
                Builder.CallConv.default,
                .none,
                materializer.typeOf(self.builder),
                materializer.toValue(self.builder),
                &.{started},
                "constants.outcome",
            );
            const failed = try wip.block(1, "constants.failed");
            const dispatching = try wip.block(1, "constants.ready");
            _ = try wip.brCond(
                try wip.icmp(
                    .ne,
                    outcome,
                    try self.builder.intValue(.i32, outcome_ok),
                    "constants.failed",
                ),
                failed,
                dispatching,
                .else_likely,
            );
            wip.cursor = .{ .block = failed };
            _ = try wip.ret(try self.builder.intValue(.i32, outcome_trapped));
            wip.cursor = .{ .block = dispatching };
        }

        // A function index this module never spawns cannot arrive here
        // — `luce_rt_spawn` is only ever called with one of `spawned` —
        // so the default answers "it trapped" without a trap to show,
        // which the join reports as `host_unavailable` rather than
        // inventing news.
        const refused = try wip.block(1, "no.such.worker");
        var blocks: std.ArrayList(BlockIndex) = .empty;
        defer blocks.deinit(self.gpa);
        for (self.spawned) |_| try blocks.append(self.gpa, try wip.block(1, "worker"));

        var chosen = try wip.@"switch"(which, refused, @intCast(self.spawned.len), .none);
        for (self.spawned, blocks.items) |index, block| {
            try chosen.addCase(try self.builder.intConst(.i64, index), block, &wip);
        }
        chosen.finish(&wip);

        wip.cursor = .{ .block = refused };
        _ = try wip.ret(try self.builder.intValue(.i32, outcome_trapped));

        for (self.spawned, blocks.items) |index, block| {
            wip.cursor = .{ .block = block };
            try self.lowerWorkerCase(&wip, entry, index, host, started, arguments, out, depth);
        }
        try wip.finish();
    }

    /// One arm of the trampoline: unbox the arguments, make the call,
    /// and box the answer back.
    ///
    /// A `Body` is built over the callee's own `mir.Function` so the
    /// boxing is the boxing every other runtime call in this file uses.
    /// It walks no instructions — it is here for the value boundary and
    /// nothing else, which is the one thing a worker's entry needs and
    /// the one thing that must not be written twice.
    fn lowerWorkerCase(
        self: *Module,
        wip: *Builder.WipFunction,
        entry: BlockIndex,
        index: u32,
        host: Builder.Value,
        started: Builder.Value,
        arguments: Builder.Value,
        out: Builder.Value,
        depth: Builder.Value,
    ) Error!void {
        const function = &self.program.functions[index];
        var arm: Body = .{
            .module = self,
            .wip = wip,
            .function = function,
            .index = index,
            .host = host,
            .runtime = started,
            .depth = depth,
            .entry_block = entry,
        };
        defer arm.deinit();

        var passed: std.ArrayList(Builder.Value) = .empty;
        defer passed.deinit(self.gpa);
        try passed.append(self.gpa, host);
        try passed.append(self.gpa, started);
        try passed.append(self.gpa, depth);
        for (function.locals[0..function.parameter_count], 0..) |parameter, at| {
            const address = try wip.gep(
                .inbounds,
                self.value_type,
                arguments,
                &.{try self.builder.intValue(.i64, at)},
                "worker.arg",
            );
            try passed.append(self.gpa, try arm.unboxed(parameter.local_type, address, "worker.in"));
        }
        var result_slot: Builder.Value = .none;
        if (function.return_type != .none) {
            result_slot = try arm.scratch(
                try self.valueType(function.return_type),
                valueAlignment(function.return_type),
                "worker.result",
            );
            try passed.append(self.gpa, result_slot);
        }

        const target = self.functions[index];
        const outcome = try wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            target.typeOf(self.builder),
            target.toValue(self.builder),
            passed.items,
            "worker.outcome",
        );

        // The answer is boxed for the join to carry across; a worker
        // that trapped or raised has no answer, and `out` keeps the
        // `none` `luce_rt_spawn` left in it.
        if (function.return_type != .none) {
            const answered = try wip.block(1, "worker.answered");
            const done = try wip.block(2, "worker.done");
            _ = try wip.brCond(
                try wip.icmp(
                    .eq,
                    outcome,
                    try self.builder.intValue(.i32, outcome_ok),
                    "worker.ok",
                ),
                answered,
                done,
                .then_likely,
            );
            wip.cursor = .{ .block = answered };
            const held = try wip.load(
                .normal,
                try self.valueType(function.return_type),
                result_slot,
                valueAlignment(function.return_type),
                "worker.value",
            );
            try arm.fillBoxShape(out, function.return_type);
            try arm.fillBoxValue(out, function.return_type, held);
            _ = try wip.br(done);
            wip.cursor = .{ .block = done };
        }
        _ = try wip.ret(outcome);
    }

    /// Build the one C-shaped dispatcher class releases call back through.
    /// Layout metadata is the only way a finalizer can be named; the MIR
    /// verifier rejects every ordinary call, spawn, and function value edge
    /// to these hidden bodies.
    fn lowerFinalizerEntry(self: *Module) Error!void {
        var count: usize = 0;
        for (self.program.structs) |layout| {
            if (layout.deinitializer != null) count += 1;
        }
        if (count == 0) return;

        const signature_type = try self.builder.fnType(
            .i32,
            &.{ .ptr, .ptr, .i64, .ptr, .i64 },
            .normal,
        );
        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString("luce.finalize"),
            .default,
        );
        declared.setLinkage(.internal, self.builder);
        self.finalizer_entry = declared;

        var wip: Builder.WipFunction = try .init(self.builder, .{
            .function = declared,
            .strip = true,
        });
        defer wip.deinit();
        const entry = try wip.block(0, "entry");
        wip.cursor = .{ .block = entry };
        const host = wip.arg(0);
        const started = wip.arg(1);
        const which = wip.arg(2);
        const receiver = wip.arg(3);
        const depth = wip.arg(4);

        const refused = try wip.block(1, "no.such.finalizer");
        var blocks: std.ArrayList(BlockIndex) = .empty;
        defer blocks.deinit(self.gpa);
        var functions: std.ArrayList(u32) = .empty;
        defer functions.deinit(self.gpa);
        for (self.program.structs) |layout| {
            const function = layout.deinitializer orelse continue;
            try functions.append(self.gpa, function);
            try blocks.append(self.gpa, try wip.block(1, "finalizer"));
        }

        var chosen = try wip.@"switch"(which, refused, @intCast(functions.items.len), .none);
        for (functions.items, blocks.items) |function, block| {
            try chosen.addCase(try self.builder.intConst(.i64, function), block, &wip);
        }
        chosen.finish(&wip);
        wip.cursor = .{ .block = refused };
        _ = try wip.ret(try self.builder.intValue(.i32, outcome_trapped));

        for (functions.items, blocks.items) |function_index, block| {
            wip.cursor = .{ .block = block };
            const function = &self.program.functions[function_index];
            std.debug.assert(function.parameter_count == 1);
            std.debug.assert(function.return_type == .none);
            var arm: Body = .{
                .module = self,
                .wip = &wip,
                .function = function,
                .index = function_index,
                .host = host,
                .runtime = started,
                .depth = depth,
                .entry_block = entry,
            };
            defer arm.deinit();
            const self_value = try arm.unboxed(
                function.locals[0].local_type,
                receiver,
                "finalizer.self",
            );
            const target = self.functions[function_index];
            _ = try wip.ret(try wip.call(
                .normal,
                Builder.CallConv.default,
                .none,
                target.typeOf(self.builder),
                target.toValue(self.builder),
                &.{ host, started, depth, self_value },
                "finalizer.outcome",
            ));
        }
        try wip.finish();
    }

    /// Stamp the artifact with what it is: the magic, the tag's own
    /// layout version, the host ABI it was generated against, the
    /// machine it was generated for, the program it came from, whether
    /// it kept its origins, and what generated it (`artifact.Artifact`).
    ///
    /// Exported, because the whole point is that a loader can read it
    /// *before* deciding to call anything.  A `.lc` from another
    /// machine or another ABI is otherwise a file that loads cleanly
    /// and crashes on the first call, which is the failure mode this
    /// exists to replace with a sentence.
    ///
    /// **And put in a section of its own**, which is what makes
    /// "before" true.  A symbol is something you look up in a library
    /// you have already opened, so a tag reachable only that way is
    /// read *after* the platform loader has had its say — and the
    /// platform loader's say about a damaged file is a crash
    /// (`artifact.section`, `src/apps/native.zig`).  In a section, the
    /// same constant is findable in the file's own bytes.
    ///
    /// The name is spelled once, in `artifact.section`, and the object
    /// format decides which spelling: Mach-O sections live in a
    /// segment, ELF sections do not.
    ///
    /// `artifact.generator` is stamped and never passed in: it is what
    /// wrote these instructions, so it is this file's answer to give
    /// and no caller's to choose.
    fn describeArtifact(self: *Module) Error!void {
        const name_type = try self.builder.structType(.normal, &.{
            .i32,
            try self.builder.arrayType(artifact.machine_capacity, .i8),
        });
        const tag_type = try self.builder.structType(
            .normal,
            &.{ .i64, .i64, .i64, .i32, .i32, .i32, .i32, name_type },
        );
        const debug_functions = for (self.program.functions) |function| {
            if (function.origins.len != 0) break true;
        } else false;
        const debug_build = debug_functions or for (self.program.container_constants) |constant| {
            if (constant.source.len != 0) break true;
        } else false;
        const initializer = try self.builder.structConst(tag_type, &.{
            try self.builder.intConst(.i64, @as(i64, @bitCast(artifact.magic))),
            try self.builder.intConst(.i64, @as(i64, @bitCast(self.options.source_hash))),
            try self.builder.intConst(.i64, @as(i64, @bitCast(artifact.generator))),
            try self.builder.intConst(.i32, artifact.format),
            try self.builder.intConst(.i32, abi.version),
            try self.builder.intConst(.i32, @intFromBool(debug_build)),
            try self.builder.intConst(.i32, 0),
            try self.builder.structConst(name_type, &.{
                try self.builder.intConst(.i32, artifact.machine.len),
                // The whole run, padding included, so the tag a loader
                // reads is the same ninety-six bytes whatever machine
                // wrote it.
                try self.builder.stringConst(
                    try self.builder.string(&artifact.MachineName.here.text),
                ),
            }),
        });
        const variable = try self.builder.addVariable(
            try self.builder.strtabString(artifact.symbol),
            tag_type,
            .default,
        );
        try variable.setInitializer(initializer, self.builder);
        variable.setMutability(.constant, self.builder);
        variable.setSection(
            try self.builder.string(if (self.options.target.os.tag.isDarwin())
                artifact.section.mach
            else
                artifact.section.elf),
            self.builder,
        );
        variable.ptrConst(self.builder).global.setLinkage(.external, self.builder);
    }

    /// `i1 (ptr host, ptr rt, i64 depth, params..., ptr out?)` — see the
    /// file header.
    /// The same shape as `signature`, built from a **written function
    /// type** rather than from a declared function: what a call through
    /// a value is emitted against (docs/FUNCTIONS.md D2).  The two must
    /// agree, and the verifier is what says they do.
    fn indirectSignature(self: *Module, written: types.Signature) Error!Builder.Type {
        var parameters: std.ArrayList(Builder.Type) = .empty;
        defer parameters.deinit(self.gpa);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .i64);
        // The receiver slot, present whether the value carries one or
        // not: `Module.entries` says why (docs/BINDING.md D12).
        try parameters.append(self.gpa, .ptr);
        for (written.parameters) |parameter| {
            try parameters.append(self.gpa, try self.valueType(parameter.value_type));
        }
        if (written.result != .none) {
            _ = try self.valueType(written.result);
            try parameters.append(self.gpa, .ptr);
        }
        return self.builder.fnType(.i32, parameters.items, .normal);
    }

    /// The program's function table: one pointer per Luce function, in
    /// program order, so a function value — whose first slot is an
    /// index — becomes something callable with one `getelementptr` and
    /// one load (docs/FUNCTIONS.md D2).
    ///
    /// **What it holds is adapters** (`Module.entries`), so a row is
    /// null for every function no value ever names.  A null row is
    /// unreachable rather than checked: the collection that built the
    /// adapters walked the same `const_function` instructions the index
    /// can only have come from.
    ///
    /// Built once and only where something asks: a program that never
    /// makes a function value emits none of it, exactly as a program
    /// that never spawns emits no worker entry.
    fn functionTable(self: *Module) Error!Builder.Variable.Index {
        if (self.function_table) |built| return built;
        var entries: std.ArrayList(Builder.Constant) = .empty;
        defer entries.deinit(self.gpa);
        for (self.entries) |entry| {
            try entries.append(self.gpa, if (entry) |declared|
                declared.toConst(self.builder)
            else
                try self.builder.nullConst(.ptr));
        }
        const table_type = try self.builder.arrayType(entries.items.len, .ptr);
        const variable = try self.builder.addVariable(
            try self.builder.strtabString("luce.function_table"),
            table_type,
            .default,
        );
        try variable.setInitializer(
            try self.builder.arrayConst(table_type, entries.items),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        self.function_table = variable;
        return variable;
    }

    /// Static interface witness metadata in three compact parallel tables.
    /// A runtime value keeps only the one-based row index. The descriptor
    /// validates its nominal interface and points into the flattened method
    /// function-index table.
    fn interfaceWitnessTables(self: *Module) Error!WitnessTables {
        if (self.witness_tables) |built| return built;
        var layouts: std.ArrayList(Builder.Constant) = .empty;
        defer layouts.deinit(self.gpa);
        var offsets: std.ArrayList(Builder.Constant) = .empty;
        defer offsets.deinit(self.gpa);
        var methods: std.ArrayList(Builder.Constant) = .empty;
        defer methods.deinit(self.gpa);

        for (self.program.interface_witnesses) |witness| {
            try layouts.append(self.gpa, try self.builder.intConst(.i32, witness.interface));
            try offsets.append(self.gpa, try self.builder.intConst(.i32, methods.items.len));
            for (witness.methods) |function| {
                try methods.append(self.gpa, try self.builder.intConst(.i32, function));
            }
        }

        const layout_type = try self.builder.arrayType(layouts.items.len, .i32);
        const layout_rows = try self.builder.addVariable(
            try self.builder.strtabString("luce.interface_witness_layouts"),
            layout_type,
            .default,
        );
        try layout_rows.setInitializer(
            try self.builder.arrayConst(layout_type, layouts.items),
            self.builder,
        );
        layout_rows.setMutability(.constant, self.builder);
        layout_rows.ptrConst(self.builder).global.setLinkage(.private, self.builder);

        const offset_type = try self.builder.arrayType(offsets.items.len, .i32);
        const offset_rows = try self.builder.addVariable(
            try self.builder.strtabString("luce.interface_witness_offsets"),
            offset_type,
            .default,
        );
        try offset_rows.setInitializer(
            try self.builder.arrayConst(offset_type, offsets.items),
            self.builder,
        );
        offset_rows.setMutability(.constant, self.builder);
        offset_rows.ptrConst(self.builder).global.setLinkage(.private, self.builder);

        const method_type = try self.builder.arrayType(methods.items.len, .i32);
        const method_rows = try self.builder.addVariable(
            try self.builder.strtabString("luce.interface_witness_methods"),
            method_type,
            .default,
        );
        try method_rows.setInitializer(
            try self.builder.arrayConst(method_type, methods.items),
            self.builder,
        );
        method_rows.setMutability(.constant, self.builder);
        method_rows.ptrConst(self.builder).global.setLinkage(.private, self.builder);

        const built: WitnessTables = .{
            .layouts = layout_rows,
            .offsets = offset_rows,
            .methods = method_rows,
        };
        self.witness_tables = built;
        return built;
    }

    /// The program's function *names*, one `{ptr, i64}` per function in
    /// program order: what `str(f)` reads (docs/FUNCTIONS.md D3).
    /// Built lazily beside the table above, for the same reason.
    fn functionNames(self: *Module) Error!Builder.Variable.Index {
        if (self.function_names) |built| return built;
        var entries: std.ArrayList(Builder.Constant) = .empty;
        defer entries.deinit(self.gpa);
        for (self.program.functions) |*function| {
            try entries.append(self.gpa, try self.textConstant(function.name));
        }
        const table_type = try self.builder.arrayType(entries.items.len, self.string_type);
        const variable = try self.builder.addVariable(
            try self.builder.strtabString("luce.function_names"),
            table_type,
            .default,
        );
        try variable.setInitializer(
            try self.builder.arrayConst(table_type, entries.items),
            self.builder,
        );
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.private, self.builder);
        self.function_names = variable;
        return variable;
    }

    fn signature(self: *Module, function: *const mir.Function) Error!Builder.Type {
        var parameters: std.ArrayList(Builder.Type) = .empty;
        defer parameters.deinit(self.gpa);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .i64);
        for (function.locals[0..function.parameter_count]) |parameter| {
            try parameters.append(
                self.gpa,
                if (parameter.inout) .ptr else try self.valueType(parameter.local_type),
            );
        }
        if (function.return_type != .none) {
            _ = try self.valueType(function.return_type); // reject before use
            try parameters.append(self.gpa, .ptr);
        }
        return self.builder.fnType(.i32, parameters.items, .normal);
    }

    /// What each of a Luce function's three hidden arguments — and its
    /// out-parameter, and any struct it takes — is, said in the terms
    /// LLVM reasons in.
    ///
    /// The one that earns its keep is `%host`: the service table is a
    /// `const LuceHost *` for the whole run, so `readonly` is what lets
    /// a `print` inside a loop load its slot once rather than every
    /// iteration.  The rest are true for the same reason the runtime's
    /// are — a frame slot is an `alloca` nobody else can reach — and
    /// they cost nothing to say.
    fn functionAttributes(
        self: *Module,
        function: *const mir.Function,
    ) Error!Builder.FunctionAttributes {
        const word: Builder.Alignment.Lazy = .wrap(.fromByteUnits(8));
        var wip: Builder.FunctionAttributes.Wip = .{};
        defer wip.deinit(self.builder);

        // %host — read, never written, never kept, and always a whole
        // service table (abi.Host is what the ABI obliges the caller to
        // pass).
        try wip.addParamAttr(0, .nocapture, self.builder);
        try wip.addParamAttr(0, .readonly, self.builder);
        try wip.addParamAttr(0, .nonnull, self.builder);
        try wip.addParamAttr(0, .noundef, self.builder);
        try wip.addParamAttr(0, .{ .dereferenceable = @sizeOf(abi.Host) }, self.builder);
        try wip.addParamAttr(0, .{ .@"align" = word }, self.builder);

        // %rt — written (the trap slot, the serial counter), but never
        // kept by anything this module hands it to.
        try wip.addParamAttr(1, .nocapture, self.builder);
        try wip.addParamAttr(1, .nonnull, self.builder);
        try wip.addParamAttr(1, .noundef, self.builder);
        try wip.addParamAttr(1, .{ .@"align" = word }, self.builder);

        // %depth — a count, always initialized.
        try wip.addParamAttr(2, .noundef, self.builder);

        // A struct travels as a pointer to its run of fields, and a run
        // is never written after it is built (`heap.setField` allocates
        // a fresh one), so every struct parameter is read-only storage.
        // It is *not* `nocapture`: returning a struct stores the pointer
        // through `%out`.
        for (function.locals[0..function.parameter_count], 0..) |parameter, index| {
            if (parameter.inout) {
                try wip.addParamAttr(index + 3, .noundef, self.builder);
                continue;
            }
            if (parameter.local_type != .strukt and parameter.local_type != .variant) continue;
            const at = index + 3;
            try wip.addParamAttr(at, .readonly, self.builder);
            try wip.addParamAttr(at, .nonnull, self.builder);
            try wip.addParamAttr(at, .noundef, self.builder);
            try wip.addParamAttr(at, .{ .@"align" = word }, self.builder);
        }

        // %out — written once on the way out and never read.
        if (function.return_type != .none) {
            const at = function.parameter_count + 3;
            _ = try self.valueType(function.return_type); // reject before use
            try wip.addParamAttr(at, .nocapture, self.builder);
            try wip.addParamAttr(at, .writeonly, self.builder);
            try wip.addParamAttr(at, .nonnull, self.builder);
            try wip.addParamAttr(at, .noundef, self.builder);
            try wip.addParamAttr(
                at,
                .{ .dereferenceable = Module.resultSize(function.return_type) },
                self.builder,
            );
            try wip.addParamAttr(
                at,
                .{ .@"align" = .wrap(Module.valueAlignment(function.return_type)) },
                self.builder,
            );
        }
        return wip.finish(self.builder);
    }

    /// How many bytes a returned value occupies in its `%out` slot —
    /// the size of `valueType(of)`, which is what makes the slot
    /// `dereferenceable`.
    fn resultSize(written: types.Type) u32 {
        const of = written.storage();
        return switch (of) {
            .boolean, .u8, .i8 => 1,
            .u16, .i16, .f16 => 2,
            .u32, .i32, .f32, .char => 4,
            // A function value travels as the pointer to its run.
            .u64, .i64, .f64, .strukt, .variant, .function, .heap => 8,
            // `{ ptr, i64 }` — how a str travels.
            .str, .bytes => 16,
            // `{T, i1}`: the payload, then one byte for the bit,
            // rounded up to the payload's own alignment. A bool
            // payload aligns to 1, so `{i1, i1}` really is two bytes —
            // and `dereferenceable` must not claim more than the
            // caller's `alloca` provides.
            .optional => |payload| switch (payload.asType().storage()) {
                .boolean, .u8, .i8 => 2,
                // {i16, i1} and {half, i1} align to 2, so four.
                .u16, .i16, .f16 => 4,
                // {i32, i1} and {float, i1} align to 4, so eight
                // bytes rather than sixteen.
                .u32, .i32, .f32, .char => 8,
                // A function value travels as the pointer to its run,
                // so `(func(...) -> R)?` is a pointer beside the bit —
                // the storable form of every function value
                // (docs/BINDING.md D7), and the one payload that
                // reaches here through a *type* rather than a width.
                .u64, .i64, .f64, .strukt, .variant, .heap, .function => 16,
                .str, .bytes => 24,
                .none, .enumeration, .optional => unreachable, // a payload is a value of a width
            },
            // Never reached: a function returning nothing has no slot.
            .none => 0,
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// The exported wrapper: open a runtime, run the entry function,
    /// hand the host the leak census, and answer a status.
    ///
    /// The runtime is opened here rather than by the host so that a
    /// `.lc`, a standalone executable, and a wasm module all bootstrap
    /// the same way — the host supplies effects, not memory.
    fn lowerEntry(self: *Module) Error!void {
        const entry = &self.program.functions[self.program.entry_function];
        // `func main():` or `func main(args: list[str]):`, with or
        // without `-> !`, and nothing else — stage 4's `checkEntry` is
        // what says so, and this is the shape that survived it.
        if (entry.parameter_count > 1) return self.fail("an entry function with more than one parameter");
        const takes_arguments = entry.parameter_count == 1;

        const signature_type = try self.builder.fnType(.i32, &.{.ptr}, .normal);
        const wrapper = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString(abi.entry_symbol),
            .default,
        );
        wrapper.setLinkage(.external, self.builder);
        wrapper.setAttributes(try self.entryAttributes(), self.builder);

        var wip = try Builder.WipFunction.init(self.builder, .{
            .function = wrapper,
            .strip = true,
        });
        defer wip.deinit();
        const block = try wip.block(0, "entry");
        wip.cursor = .{ .block = block };

        const word = Builder.Alignment.fromByteUnits(8);
        const host = wip.arg(0);
        // Two answers are settled on more than one path, so each gets a
        // slot rather than a phi: how deep the host lets calls go, and
        // whether the program unwound.  Both are entry-block `alloca`s
        // that mem2reg promotes straight back to registers.
        const depth_slot = try wip.alloca(.normal, .i64, .none, word, .default, "depth");
        const outcome_slot = try wip.alloca(.normal, .i32, .none, word, .default, "outcome");
        _ = try wip.store(
            .normal,
            try self.builder.intValue(.i64, abi.default_call_depth),
            depth_slot,
            word,
        );

        const context = try self.loadHostSlot(&wip, host, .context, "context");
        const depth_fn = try self.loadHostSlot(&wip, host, .call_depth, "depth.fn");
        const asking = try wip.block(1, "ask.depth");
        const opening = try wip.block(2, "open");
        _ = try wip.brCond(
            try wip.icmp(.eq, depth_fn, try self.builder.nullValue(.ptr), "no.depth"),
            opening,
            asking,
            .none,
        );
        wip.cursor = .{ .block = asking };
        _ = try wip.store(.normal, try wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            try self.hostType(.call_depth),
            depth_fn,
            &.{context},
            "given.depth",
        ), depth_slot, word);
        _ = try wip.br(opening);

        wip.cursor = .{ .block = opening };
        const limit = try wip.load(.normal, .i64, depth_slot, word, "limit");
        const described = try self.describeFunctions();
        const started = try self.callService(
            &wip,
            .luce_rt_open,
            .ptr,
            &.{
                described.toValue(),
                try self.builder.intValue(
                    .i64,
                    @as(
                        i64,
                        @intCast(self.program.functions.len + self.program.container_constants.len),
                    ),
                ),
            },
            "rt",
        );

        // No memory to start in: nothing ran, and there is no trap to
        // report because no program error happened.
        const empty = try wip.block(1, "no.memory");
        const running = try wip.block(1, "running");
        _ = try wip.brCond(
            try wip.icmp(.eq, started, try self.builder.nullValue(.ptr), "unopened"),
            empty,
            running,
            .else_likely,
        );
        wip.cursor = .{ .block = empty };
        _ = try wip.ret(try self.builder.intValue(.i32, @intFromEnum(runtime.Status.exhausted)));
        wip.cursor = .{ .block = running };

        // Constant containers are the program root of this runtime and
        // exist before the first instruction of `main`.  Keep the old
        // block graph exactly when the pruned pool is empty; otherwise
        // the failed prologue becomes one more predecessor of `ended`,
        // where the ordinary trap report, status, and close already
        // live.
        var constants_ending: ?BlockIndex = null;
        if (self.constant_materializer) |materializer| {
            const ending = try wip.block(if (takes_arguments) 4 else 3, "ended");
            constants_ending = ending;
            const materialized = try wip.call(
                .normal,
                Builder.CallConv.default,
                .none,
                materializer.typeOf(self.builder),
                materializer.toValue(self.builder),
                &.{started},
                "constants.outcome",
            );
            const failed = try wip.block(1, "constants.failed");
            const installing = try wip.block(1, "constants.ready");
            _ = try wip.brCond(
                try wip.icmp(
                    .ne,
                    materialized,
                    try self.builder.intValue(.i32, outcome_ok),
                    "constants.failed",
                ),
                failed,
                installing,
                .else_likely,
            );
            wip.cursor = .{ .block = failed };
            _ = try wip.store(
                .normal,
                try self.builder.intValue(.i32, outcome_trapped),
                outcome_slot,
                word,
            );
            _ = try wip.br(ending);
            wip.cursor = .{ .block = installing };
        }

        // The host's handle channel, handed over once (docs/BYTES.md
        // R2).  It goes into `libluce_rt` rather than being read at
        // each call because a handle's close happens at the end of the
        // scope that owns it — inside the ownership walk, where no
        // generated code is standing to pass a table in.  A host that
        // fills none of the five leaves the runtime fail-closed, which
        // is what every missing service already means.
        _ = try self.callService(&wip, .luce_rt_files_install, .void, &.{
            started,
            context,
            try self.loadHostSlot(&wip, host, .handle_open, "files.open.fn"),
            try self.loadHostSlot(&wip, host, .handle_read, "files.read.fn"),
            try self.loadHostSlot(&wip, host, .handle_write, "files.write.fn"),
            try self.loadHostSlot(&wip, host, .handle_flush, "files.flush.fn"),
            try self.loadHostSlot(&wip, host, .handle_close, "files.close.fn"),
        }, "");

        // The transport channel follows the same lifetime rule — a
        // socket's close happens in the scope walk — and a different
        // concurrency rule: its callbacks block for a peer and run
        // outside the Effects guard (`runtime/sockets.zig`).
        _ = try self.callService(&wip, .luce_rt_sockets_install, .void, &.{
            started,
            context,
            try self.loadHostSlot(&wip, host, .socket_connect, "sockets.connect.fn"),
            try self.loadHostSlot(&wip, host, .socket_listen, "sockets.listen.fn"),
            try self.loadHostSlot(&wip, host, .socket_accept, "sockets.accept.fn"),
            try self.loadHostSlot(&wip, host, .socket_port, "sockets.port.fn"),
            try self.loadHostSlot(&wip, host, .socket_close, "sockets.close.fn"),
        }, "");

        // The backend-neutral window/GPU channel follows the same lifetime
        // rule as files: install its host callbacks once, before `main`, so
        // native windows and surfaces can be closed by the runtime's scope
        // walk even when no generated code remains on the stack.
        _ = try self.callService(&wip, .luce_rt_graphics_install, .void, &.{
            started,
            context,
            try self.loadHostSlot(&wip, host, .gpu_backend, "graphics.backend.fn"),
            try self.loadHostSlot(&wip, host, .ui_window_open, "graphics.window.open.fn"),
            try self.loadHostSlot(&wip, host, .ui_window_surface, "graphics.window.surface.fn"),
            try self.loadHostSlot(&wip, host, .gpu_surface_size, "graphics.surface.size.fn"),
            try self.loadHostSlot(&wip, host, .gpu_surface_clear, "graphics.surface.clear.fn"),
            try self.loadHostSlot(&wip, host, .gpu_surface_fill_rect, "graphics.surface.fill.fn"),
            try self.loadHostSlot(&wip, host, .gpu_surface_present, "graphics.surface.present.fn"),
            try self.loadHostSlot(&wip, host, .gpu_close, "graphics.close.fn"),
        }, "");

        // The thread channel and this engine's nursery, handed over
        // once — **and only when the program contains a `spawn`**
        // (docs/THREADS.md D11).  A program without one emits nothing
        // here, so its prologue is the prologue it always was.
        //
        // The host table travels as the nursery's context because that
        // is what a worker's entry needs to reach the services `main`
        // reaches; the two runtime-shaped slots, `open` and `close`,
        // are `libluce_rt`'s own and are not passed.
        if (self.worker_entry) |entry_point| {
            _ = try self.callService(&wip, .luce_rt_workers_install, .void, &.{
                started,
                context,
                try self.loadHostSlot(&wip, host, .worker_spawn, "workers.spawn.fn"),
                try self.loadHostSlot(&wip, host, .worker_join, "workers.join.fn"),
                host,
                entry_point.toValue(self.builder),
                limit,
            }, "");
        }

        if (self.finalizer_entry) |entry_point| {
            _ = try self.callService(&wip, .luce_rt_finalizers_install, .void, &.{
                started,
                host,
                entry_point.toValue(self.builder),
                limit,
            }, "");
        }

        // A host that allows no frames at all refuses the entry
        // function itself, exactly as the interpreter's frame stack
        // does before it pushes anything.  Nothing ran, so the trap
        // carries no trace.
        const refused = try wip.block(1, "too.deep");
        const calling = try wip.block(1, "calling");
        // Two ways in, or three when the command line has to be built:
        // that build is the one thing between the depth check and the
        // call that can run out of memory.
        const ending = constants_ending orelse
            try wip.block(if (takes_arguments) 3 else 2, "ended");
        _ = try wip.brCond(
            try wip.icmp(.slt, limit, try self.builder.intValue(.i64, 1), "no.frames"),
            refused,
            calling,
            .else_likely,
        );

        wip.cursor = .{ .block = refused };
        try self.raiseIn(&wip, started, .call_depth_exceeded);
        _ = try wip.store(
            .normal,
            try self.builder.intValue(.i32, outcome_trapped),
            outcome_slot,
            word,
        );
        _ = try wip.br(ending);

        wip.cursor = .{ .block = calling };
        var arguments: std.ArrayList(Builder.Value) = .empty;
        defer arguments.deinit(self.gpa);
        try arguments.append(self.gpa, host);
        try arguments.append(self.gpa, started);
        try arguments.append(self.gpa, limit);
        // `args` — the command line, built by `libluce_rt` out of the
        // two vtable slots that already carry it, so nothing is added
        // to the published ABI and `luce_main`'s signature does not
        // move (docs/SELF.md).  A host that supplies neither service
        // yields an empty list; the only way this can fail is running out
        // of memory for the list itself.  The entry made the list, so the
        // entry releases it once `main` — which only borrows the
        // parameter — has returned (docs/MEMORY.md).
        var args_box: ?Builder.Value = null;
        if (takes_arguments) {
            const box = try wip.alloca(
                .normal,
                self.value_type,
                .none,
                Body.value_alignment,
                .default,
                "args.box",
            );
            const built = try self.callService(&wip, .luce_rt_args_list, .i32, &.{
                started,
                context,
                try self.loadHostSlot(&wip, host, .arg_count, "args.count.fn"),
                try self.loadHostSlot(&wip, host, .arg, "args.get.fn"),
                box,
            }, "args.built");
            const unbuilt = try wip.block(1, "args.unbuilt");
            const entering = try wip.block(1, "entering");
            _ = try wip.brCond(
                try wip.icmp(.ne, built, try self.builder.intValue(.i32, 0), "args.failed"),
                unbuilt,
                entering,
                .else_likely,
            );
            // Nothing ran, and the runtime has recorded that it ran out
            // — `luce_rt_status` answers `exhausted` and `luce_rt_report`
            // stays quiet, which is the same pair of answers a failed
            // `luce_rt_open` gets.
            wip.cursor = .{ .block = unbuilt };
            _ = try wip.store(
                .normal,
                try self.builder.intValue(.i32, outcome_trapped),
                outcome_slot,
                word,
            );
            _ = try wip.br(ending);

            wip.cursor = .{ .block = entering };
            args_box = box;
            const handle_at = try wip.gepStruct(self.value_type, box, Body.box_bits, "args.at");
            try arguments.append(self.gpa, try wip.load(
                .normal,
                .i64,
                handle_at,
                Body.value_alignment,
                "args",
            ));
        }
        if (entry.return_type != .none) {
            try arguments.append(self.gpa, try wip.alloca(
                .normal,
                try self.valueType(entry.return_type),
                .none,
                Module.valueAlignment(entry.return_type),
                .default,
                "discard",
            ));
        }

        const called = self.functions[self.program.entry_function];
        _ = try wip.store(.normal, try wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            called.typeOf(self.builder),
            called.toValue(self.builder),
            arguments.items,
            "outcome",
        ), outcome_slot, word);
        // The parameter was a borrow, so `main` left the list alive; the
        // entry that built it releases it now, before the census is read.
        if (args_box) |box| {
            _ = try self.callService(&wip, .luce_rt_release, .i32, &.{ started, box }, "release.args");
        }
        _ = try wip.br(ending);

        wip.cursor = .{ .block = ending };
        const outcome = try wip.load(.normal, .i32, outcome_slot, word, "outcome.word");
        // Three answers, and each one is somebody's to hear: a trap
        // with its trace, an error with its raise site, and the census
        // for every run that got far enough to open a runtime
        // (docs/FAILURE.md).
        const trapped = try wip.icmp(
            .eq,
            outcome,
            try self.builder.intValue(.i32, outcome_trapped),
            "trapped",
        );
        const errored = try wip.icmp(
            .eq,
            outcome,
            try self.builder.intValue(.i32, outcome_errored),
            "errored",
        );
        try self.reportTrap(&wip, host, context, started, trapped);
        try self.reportError(&wip, host, context, started, errored);

        const status = try self.callService(
            &wip,
            .luce_rt_status,
            .i32,
            &.{ started, outcome },
            "status",
        );
        // Publish the census for every run that opened a runtime.  A
        // trap and an uncaught error are still observable program
        // outcomes, so the objects their unwind left alive must be
        // compared just like a normal return.  Only an exhausted run
        // has no reliable runtime to count.
        const exhausted = try wip.icmp(
            .eq,
            status,
            try self.builder.intValue(.i32, @intFromEnum(abi.Status.exhausted)),
            "status.exhausted",
        );
        try self.reportLeaks(
            &wip,
            host,
            context,
            started,
            exhausted,
        );
        _ = try self.callService(&wip, .luce_rt_close, .void, &.{started}, "");
        _ = try wip.ret(status);
        try wip.finish();
    }

    /// `luce_main`'s one argument is the service table, and the same
    /// three things are true of it here as inside a Luce function: it
    /// is read, it is never kept, and the ABI obliges the caller to
    /// pass a whole one.  The function itself promises nothing — it
    /// calls the host's trap reporter, and a host is anybody's code.
    fn entryAttributes(self: *Module) Error!Builder.FunctionAttributes {
        var wip: Builder.FunctionAttributes.Wip = .{};
        defer wip.deinit(self.builder);
        try wip.addParamAttr(0, .nocapture, self.builder);
        try wip.addParamAttr(0, .readonly, self.builder);
        try wip.addParamAttr(0, .nonnull, self.builder);
        try wip.addParamAttr(0, .noundef, self.builder);
        try wip.addParamAttr(0, .{ .dereferenceable = @sizeOf(abi.Host) }, self.builder);
        try wip.addParamAttr(
            0,
            .{ .@"align" = .wrap(.fromByteUnits(8)) },
            self.builder,
        );
        return wip.finish(self.builder);
    }

    /// Raise `code` with its standard message from `luce_main`, which
    /// has no `Body` and no frame of its own to record.
    fn raiseIn(
        self: *Module,
        wip: *Builder.WipFunction,
        started: Builder.Value,
        code: mir.TrapCode,
    ) Error!void {
        const message = code.message();
        _ = try self.callService(wip, .luce_rt_raise, .void, &.{
            started,
            try self.builder.intValue(.i32, @intFromEnum(code)),
            (try self.textBytes(message)).toValue(),
            try self.builder.intValue(.i64, message.len),
        }, "");
    }

    /// Hand the host the trap, once, now that the program has stopped
    /// and its trace is complete.  A run that ended any other way has no
    /// trap report to publish, which `luce_rt_report` decides for itself —
    /// this branch only spares a finished run the call.
    fn reportTrap(
        self: *Module,
        wip: *Builder.WipFunction,
        host: Builder.Value,
        context: Builder.Value,
        started: Builder.Value,
        trapped: Builder.Value,
    ) Error!void {
        const telling = try wip.block(1, "reporting");
        const quiet = try wip.block(2, "reported");
        _ = try wip.brCond(trapped, telling, quiet, .else_likely);
        wip.cursor = .{ .block = telling };
        const report = try self.loadHostSlot(wip, host, .trap, "trap.fn");
        _ = try self.callService(wip, .luce_rt_report, .void, &.{
            started,
            context,
            report,
        }, "");
        _ = try wip.br(quiet);
        wip.cursor = .{ .block = quiet };
    }

    /// Hand the host the error nobody caught, once, now that the
    /// program has stopped.  The same shape as `reportTrap`, and for
    /// the same reason: the runtime holds what happened and decides
    /// for itself whether there is anything to say.
    fn reportError(
        self: *Module,
        wip: *Builder.WipFunction,
        host: Builder.Value,
        context: Builder.Value,
        started: Builder.Value,
        errored: Builder.Value,
    ) Error!void {
        const telling = try wip.block(1, "reporting.error");
        const quiet = try wip.block(2, "reported.error");
        _ = try wip.brCond(errored, telling, quiet, .else_likely);
        wip.cursor = .{ .block = telling };
        const report = try self.loadHostSlot(wip, host, .raised, "raised.fn");
        _ = try self.callService(wip, .luce_rt_report_error, .void, &.{
            started,
            context,
            report,
        }, "");
        _ = try wip.br(quiet);
        wip.cursor = .{ .block = quiet };
    }

    /// Tell the host what remained alive after ARC cleanup, when it has
    /// somewhere to put the census and the runtime opened successfully.
    /// Exhaustion has no reliable runtime to count, so that path is skipped.
    fn reportLeaks(
        self: *Module,
        wip: *Builder.WipFunction,
        host: Builder.Value,
        context: Builder.Value,
        started: Builder.Value,
        skip_census: Builder.Value,
    ) Error!void {
        const service_fn = try self.loadHostSlot(wip, host, .finished, "finished.fn");
        const missing = try wip.icmp(
            .eq,
            service_fn,
            try self.builder.nullValue(.ptr),
            "finished.missing",
        );
        const skip = try wip.bin(.@"or", missing, skip_census, "no.census");
        // Two edges reach `quiet`: the branch that skips the census,
        // and the fall-through from the block that took it.
        const quiet = try wip.block(2, "no.census");
        const counting = try wip.block(1, "census");
        _ = try wip.brCond(skip, quiet, counting, .none);

        wip.cursor = .{ .block = counting };
        const leaked = try self.callService(wip, .luce_rt_leaked, .i64, &.{started}, "leaked");
        _ = try wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            try self.hostType(.finished),
            service_fn,
            &.{ context, leaked },
            "",
        );
        _ = try wip.br(quiet);
        wip.cursor = .{ .block = quiet };
    }

    /// Load one `abi.Host` slot.  `Body` has its own copy for the
    /// common case; this one serves `luce_main`, which has no `Body`.
    fn loadHostSlot(
        self: *Module,
        wip: *Builder.WipFunction,
        host: Builder.Value,
        slot: abi.Slot,
        name: []const u8,
    ) Error!Builder.Value {
        const address = try wip.gepStruct(self.host_type, host, @intFromEnum(slot), "slot");
        return wip.load(.normal, .ptr, address, Builder.Alignment.fromByteUnits(8), name);
    }

    /// Call a `libluce_rt` entry point, declaring it on first use.
    fn callService(
        self: *Module,
        wip: *Builder.WipFunction,
        which: Service,
        result: Builder.Type,
        arguments: []const Builder.Value,
        out_name: []const u8,
    ) Error!Builder.Value {
        var parameters: std.ArrayList(Builder.Type) = .empty;
        defer parameters.deinit(self.gpa);
        for (arguments) |argument| {
            try parameters.append(self.gpa, argument.typeOfWip(wip));
        }
        const target = try self.service(which, result, parameters.items);
        return wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            target.typeOf(self.builder),
            target.toValue(self.builder),
            arguments,
            out_name,
        );
    }

    fn lowerFunction(self: *Module, function: *const mir.Function, index: u32) Error!void {
        var wip = try Builder.WipFunction.init(self.builder, .{
            .function = self.functions[index],
            .strip = true,
        });
        defer wip.deinit();

        var body: Body = .{
            .module = self,
            .wip = &wip,
            .function = function,
            .index = index,
            .host = wip.arg(0),
            .runtime = wip.arg(1),
            .depth = wip.arg(2),
        };
        defer body.deinit();
        try body.lower();
        try wip.finish();
    }
};

// ---------------------------------------------------------------------------
// One function body
// ---------------------------------------------------------------------------

/// What one IR register produced.  Three facts about the same register,
/// written at the same sites — a runtime call that answers a str into
/// a slot sets all three in three consecutive lines — so they are three
/// columns of one row and not three arrays that happen to share a key.
/// Go's register allocator keeps the same shape (`ssa/regalloc.go`'s
/// `valState`, seven per-value facts in one `values []valState`).
///
/// A field a register has nothing to say about stays `.none`, and the
/// states coexist: `box` does not replace `value`, because `boxOf` falls
/// back to re-boxing the value when there is no box to reuse.
const Produced = struct {
    /// The SSA value.  A register whose result type is `.none` keeps
    /// `.none` here.
    value: Builder.Value = .none,
    /// The `runtime.Value` the register was read out of, where there was
    /// one: a runtime call's answer slot, an array cell, a struct's field
    /// run, a local's own slot.  `.none` for a register built any other
    /// way.
    ///
    /// It exists because unboxing a str throws away which form its
    /// text was in, and three places need that back: a store into a slot
    /// that owns its storage, which must keep short text short;
    /// `drop_storage`, which must not free a pointer into a frame; and
    /// `export_storage`, which must not transfer one out of the frame
    /// (docs/STRINGS.md).
    ///
    /// The three are reachable only from a register that *has* a box.  A
    /// store into an owning slot is preceded by `own_storage` or by a
    /// fresh producer, and both answer into one; the two intrinsics take
    /// their argument from the same place.  What is left without one — a
    /// constant, a parameter, a slice — reaches none of them without an
    /// `own_storage` in between, and `dropped` refuses text that arrives
    /// at the freeing one anyway.
    box: Builder.Value = .none,
    /// The *outcome* a fallible call or intrinsic answered, kept beside
    /// its value: `2` where it came back errored.  Only the `errored`
    /// that stands beside it ever reads one, and only in the same block,
    /// so this is the whole of the error channel on the compiled path —
    /// no load, no runtime call (docs/CODEGEN.md).
    outcome: Builder.Value = .none,
};

const Body = struct {
    module: *Module,
    wip: *Builder.WipFunction,
    function: *const mir.Function,
    /// Which function this is in `program.functions` — what a recorded
    /// trace frame names.
    index: u32,
    /// Argument 0: the `abi.Host` table.
    host: Builder.Value,
    /// Argument 1: the `libluce_rt` runtime this run belongs to.
    runtime: Builder.Value,
    /// Argument 2: how many Luce frames are still allowed, this one
    /// included.
    depth: Builder.Value,
    /// The `%out` argument, or `.none` when the function returns
    /// nothing.
    result_slot: Builder.Value = .none,
    /// What a callee is handed: one less than ours, computed in the
    /// entry block the first time this function calls anything.
    /// `.none` until then — a leaf function never subtracts.
    callee_depth: Builder.Value = .none,
    /// The IR instruction being lowered.  Read only when something
    /// goes wrong: it is what a recorded trace frame points at, and it
    /// is how the interpreter's own traceback names a position too.
    current: mir.Register = 0,
    /// Where `alloca`s go, no matter where the walk currently is.
    entry_block: BlockIndex = undefined,
    /// The aliased receiver slot logical local zero arrived in with, an
    /// ordinary pointer parameter.  `.none` in an ordinary function.
    inout: Builder.Value = .none,

    /// What each IR register produced.  Registers never cross blocks
    /// (the verifier enforces it), so one array per function is enough.
    produced: []Produced = &.{},
    /// One entry-block `alloca` per Luce local.
    local_slots: []Builder.Value = &.{},
    /// Which heap registers might name immutable program constants, derived
    /// from final MIR rather than trusted from a serialized flag.
    writable: mutability.Plan = .{},
    /// The first LLVM block of each IR block.  An IR block that
    /// contains a checked operation continues into further LLVM blocks,
    /// which no jump ever targets.
    blocks: []BlockIndex = &.{},

    /// Arrays already resolved in the block being filled, and the axis
    /// lengths they carry.  Both are cleared at every block boundary
    /// and by any instruction `effects.viewStable` refuses.
    views: std.ArrayList(ElementView) = .empty,
    view_bounds: std.ArrayList(Builder.Value) = .empty,

    /// The resolutions this function lifts out of its loops, and the
    /// values each one produced.  `loops.zig` decides which and where;
    /// these are what the preheader left behind.
    hoists: loops.Plan = .{},
    hoisted: []Hoisted = &.{},
    /// Axis lengths belonging to `hoisted`, which — unlike the
    /// block-local ones — outlive the block that made them.
    hoist_bounds: std.ArrayList(Builder.Value) = .empty,
    /// The IR block being filled, which is what says whether a lifted
    /// resolution is in scope.
    block: mir.BlockId = 0,

    fn deinit(self: *Body) void {
        const gpa = self.module.gpa;
        gpa.free(self.produced);
        gpa.free(self.local_slots);
        self.writable.deinit(gpa);
        gpa.free(self.blocks);
        self.views.deinit(gpa);
        self.view_bounds.deinit(gpa);
        self.hoists.deinit(gpa);
        gpa.free(self.hoisted);
        self.hoist_bounds.deinit(gpa);
        self.* = undefined;
    }

    fn fail(self: *Body, what: []const u8) Error {
        return self.module.fail(what);
    }

    /// Move to a freshly created, still-empty block.  Every block this
    /// walk enters is entered exactly once, so the insertion point is
    /// always the start.
    fn seek(self: *Body, block: BlockIndex) void {
        self.wip.cursor = .{ .block = block };
    }

    // -- setup ---------------------------------------------------------

    fn lower(self: *Body) Error!void {
        const gpa = self.module.gpa;
        const function = self.function;

        self.produced = try gpa.alloc(Produced, function.instructions.len);
        @memset(self.produced, .{});
        self.local_slots = try gpa.alloc(Builder.Value, function.locals.len);
        @memset(self.local_slots, .none);
        self.writable = try mutability.plan(gpa, function);
        self.blocks = try gpa.alloc(BlockIndex, function.blocks.len);

        if (function.return_type != .none) {
            self.result_slot = self.wip.arg(function.parameter_count + 3);
        }

        const predecessors = try self.countPredecessors();
        defer gpa.free(predecessors);

        self.entry_block = try self.wip.block(0, "entry");
        for (self.blocks, predecessors) |*slot, incoming| {
            slot.* = try self.wip.block(incoming, "block");
        }

        self.seek(self.entry_block);
        try self.emitFrame();
        _ = try self.wip.br(self.blocks[0]);

        self.hoists = try loops.plan(gpa, self.module.program, function);
        self.hoisted = try gpa.alloc(Hoisted, self.hoists.hoists.len);
        @memset(self.hoisted, .{});

        for (function.blocks, self.blocks, 0..) |block, llvm_block, index| {
            self.block = @intCast(index);
            self.seek(llvm_block);
            // A resolved array is SSA, so it reaches only the blocks
            // the one it was resolved in dominates.  A basic block is
            // the horizon MIR registers already keep to, and it is the
            // horizon a *block-local* view keeps to for the same
            // reason; a lifted one is defined in a preheader that
            // dominates the whole loop, so it outlives the block.
            self.forgetViews();
            for (block.items, 0..) |item, at| {
                // The lifted resolutions go at the very end of the
                // block, in front of its terminator, so everything the
                // block itself does has already happened.
                if (at + 1 == block.items.len) try self.emitHoists();
                try self.emitInstruction(item, function.instructions[item]);
                if (!optimize.effects.viewStable(function.instructions[item])) {
                    self.forgetViews();
                }
            }
        }
    }

    /// How many branch edges reach each IR block.  `WipFunction.finish`
    /// checks this against the branches actually emitted, so it has to
    /// be exact: the synthetic entry block contributes one edge into IR
    /// block 0, and a conditional branch whose arms are the same block
    /// contributes two.
    fn countPredecessors(self: *Body) Error![]u32 {
        const counts = try self.module.gpa.alloc(u32, self.function.blocks.len);
        errdefer self.module.gpa.free(counts);
        @memset(counts, 0);
        counts[0] += 1;
        for (self.function.blocks) |block| {
            const last = block.items[block.items.len - 1];
            switch (self.function.instructions[last]) {
                .jump => |target| counts[target] += 1,
                .branch => |taken| {
                    counts[taken.then_block] += 1;
                    counts[taken.else_block] += 1;
                },
                .ret, .trap, .unwind => {},
                // The verifier guarantees a block ends in a terminator.
                // Naming the rest keeps a new IR instruction a compile
                // error here as well as in the lowering switch.
                .const_boolean,
                .const_integer,
                .const_float,
                .const_str,
                .const_container,
                .const_function,
                .local_get,
                .local_set,
                .weak_local_get,
                .weak_local_set,
                .spawn,
                .call_indirect,
                .binary,
                .unary,
                .convert,
                .interface_make,
                .struct_make,
                .struct_get,
                .struct_set,
                .weak_struct_get,
                .weak_struct_set,
                .variant_make,
                .variant_tag,
                .variant_field,
                .call,
                .call_inout,
                .interface_call,
                .interface_call_inout,
                .intrinsic,
                .heap_new,
                => return self.fail("a block without a terminator"),
            }
        }
        return counts;
    }

    /// What a local's slot holds.
    ///
    /// A slot that owns its storage holds a whole `runtime.Value`,
    /// because that is the only shape short text fits in: unbox a
    /// str into `{ptr, i64}` and the form is gone, so a slot that
    /// stored one would be pointing at whatever scratch the runtime
    /// answered into (docs/STRINGS.md).  Every other slot — a
    /// parameter, a spill, anything that borrows — keeps the register
    /// shape it always had, which is what keeps a str parameter's
    /// inner loop two words in registers.
    fn slotType(self: *Body, local: mir.Local) Error!Builder.Type {
        if (local.owns_storage or local.boxed_storage or local.weak) return self.module.value_type;
        return self.module.valueType(local.local_type);
    }

    fn slotAlignment(local: mir.Local) Builder.Alignment {
        if (local.owns_storage or local.boxed_storage or local.weak) return value_alignment;
        return Module.valueAlignment(local.local_type);
    }

    /// Entry-block frame: one `alloca` per local, parameters stored in,
    /// every other local zeroed the way the interpreter zeroes it.
    fn emitFrame(self: *Body) Error!void {
        const function = self.function;
        for (function.locals, self.local_slots, 0..) |local, *slot, index| {
            if (local.inout) {
                self.inout = self.wip.arg(@intCast(index + 3));
                slot.* = self.inout;
                continue;
            }
            slot.* = try self.wip.alloca(
                .normal,
                try self.slotType(local),
                .none,
                slotAlignment(local),
                .default,
                "local",
            );
        }
        for (function.locals, self.local_slots, 0..) |local, slot, index| {
            if (local.inout) continue;
            if (local.weak) {
                try self.fillWeakZero(slot);
                continue;
            }
            const stored = if (index < function.parameter_count)
                self.wip.arg(@intCast(index + 3))
            else if (local.owns_storage or local.boxed_storage)
                // A slot that owns its storage starts empty, not at
                // the shared zero: `structZero` is one constant run
                // per layout, and a release must never hand a shared
                // run back (docs/STRINGS.md).
                try self.emptyValue(local.local_type)
            else
                try self.zeroValue(local.local_type);
            if (local.owns_storage or local.boxed_storage) {
                try self.fillBoxShape(slot, local.local_type);
                try self.fillBoxValue(slot, local.local_type, stored);
                continue;
            }
            _ = try self.wip.store(
                .normal,
                stored,
                slot,
                Module.valueAlignment(local.local_type),
            );
        }
    }

    /// An `alloca` in the entry block, inserted before its terminator,
    /// no matter which block the walk is currently filling.  Scratch
    /// storage must never sit in a loop body, or a long-running loop
    /// grows the stack a slot at a time.
    ///
    /// Only called once the entry block is complete, which is why the
    /// insertion point can be "one before the end".
    fn scratch(
        self: *Body,
        of: Builder.Type,
        alignment: Builder.Alignment,
        name: []const u8,
    ) Error!Builder.Value {
        const resume_at = self.enterEntry();
        defer self.leaveEntry(resume_at);
        return self.wip.alloca(.normal, of, .none, alignment, .default, name);
    }

    /// `count` consecutive scratch slots of `of`, in the entry block.
    /// One `alloca` with a length operand, so a rank-3 index costs one
    /// stack allocation rather than three.
    fn scratchRun(
        self: *Body,
        of: Builder.Type,
        count: usize,
        alignment: Builder.Alignment,
        name: []const u8,
    ) Error!Builder.Value {
        const resume_at = self.enterEntry();
        defer self.leaveEntry(resume_at);
        const length = try self.module.builder.intValue(.i64, count);
        return self.wip.alloca(.normal, of, length, alignment, .default, name);
    }

    /// Move the cursor to just before the entry block's terminator and
    /// answer where it was.  Everything emitted until the matching
    /// `leaveEntry` runs once per call rather than once per visit, and
    /// dominates every block — which is what a frame slot, a serial,
    /// and the constant half of a box all want.
    ///
    /// Only called once the entry block is complete, which is why the
    /// insertion point can be "one before the end".
    fn enterEntry(self: *Body) Builder.WipFunction.Cursor {
        const resume_at = self.wip.cursor;
        const filled = self.entry_block.ptr(self.wip).instructions.items.len;
        std.debug.assert(filled > 0);
        self.wip.cursor = .{ .block = self.entry_block, .instruction = @intCast(filled - 1) };
        return resume_at;
    }

    fn leaveEntry(self: *Body, resume_at: Builder.WipFunction.Cursor) void {
        self.wip.cursor = resume_at;
    }

    fn zeroValue(self: *Body, written: types.Type) Error!Builder.Value {
        // An enum-typed slot starts at the enum's **first member**
        // (docs/ENUMS.md), which is a number its declaration chose.
        if (written == .enumeration) {
            const reference = written.enumeration;
            const declared = self.module.program.enums[reference.index];
            return self.module.builder.intValue(
                try self.module.valueType(written),
                declared.members[0].value,
            );
        }
        const of = written;
        return switch (of) {
            .boolean => .false,
            .u8, .i8 => try self.module.builder.intValue(.i8, 0),
            .u16, .i16 => try self.module.builder.intValue(.i16, 0),
            .u32, .i32, .char => try self.module.builder.intValue(.i32, 0),
            .u64, .i64 => try self.module.builder.intValue(.i64, 0),
            .f16 => try self.module.builder.halfValue(0.0),
            .f32 => try self.module.builder.floatValue(0.0),
            .f64 => try self.module.builder.doubleValue(0.0),
            .str, .bytes => (try self.module.textConstant("")).toValue(),
            // The zero of an object-typed place is the null handle;
            // using it traps rather than touching anything.
            .heap => try self.module.builder.intValue(.i64, runtime.null_index),
            .strukt => |layout| (try self.module.structZero(layout)).toValue(),
            // A union's zero is the first declared member's run
            // (docs/UNION.md D13), one private constant per union.
            .variant => |index| (try self.module.variantZero(index)).toValue(),
            .none => self.fail("a local of type None"),
            // **A slot's fill, not a value of the type.**  A function
            // value has no zero — every value of the type names a
            // function — and stage 4 refuses the one declaration that
            // would ask a program for one (docs/FUNCTIONS.md, As
            // built).  What is left is the frame slot a function-typed
            // local lives in before its first store, which nothing a
            // program can write ever reads.  It is filled with the run
            // that is nowhere, and every reader of a function value
            // checks for it first, so a hand-made module that reads it
            // anyway traps rather than jumping somewhere.
            .function => try self.module.builder.nullValue(.ptr),
            // The zero of a `T?` is absence: the payload's own zero,
            // beside a bit saying it is not there.  Giving the unused
            // half a defined value rather than `poison` is what makes
            // an absent heap `T?` carry the *null* handle instead of a
            // handle to row zero, which is a live row.
            .optional => |payload| try self.wip.buildAggregate(
                try self.module.valueType(of),
                &.{ try self.zeroValue(payload.asType()), .false },
                "none",
            ),
            .enumeration => unreachable, // answered above
        };
    }

    /// What a slot that owns its storage holds before anything is
    /// stored in it: the same shape, owning nothing, so the release it
    /// is going to get frees nothing (docs/STRINGS.md). A str's
    /// zero is already empty; a struct's is a null run, which
    /// `luce_rt_drop_storage` answers for.
    fn emptyValue(self: *Body, of: types.Type) Error!Builder.Value {
        return switch (of) {
            // A union value's run empties exactly as a struct's does:
            // a null run, which `luce_rt_drop_storage` answers for.
            .strukt, .variant => try self.module.builder.nullValue(.ptr),
            else => self.zeroValue(of),
        };
    }

    // -- the runtime boundary -------------------------------------------
    //
    // A Luce value travels into `libluce_rt` as a pointer to a 24-byte
    // `{ tag, bits, length }` in an entry-block slot.  `boxed` fills one
    // in and `unboxed` reads one back; between them they are the only
    // two places in this file that know that layout — with one named
    // exception, `lowerEntry`, which reads `box_bits` alone to take the
    // command line's handle out of the box `luce_rt_args_list` filled.
    //
    // The fill is split in two on purpose: `fillBoxShape` writes what
    // the *type* decides and goes in the entry block, `fillBoxValue`
    // writes what the *value* decides and goes where the value is.

    const value_alignment = Builder.Alignment.fromByteUnits(8);
    const byte_alignment = Builder.Alignment.fromByteUnits(1);

    /// Which field of `value_type` each part of a `runtime.Value` is.
    /// `inline_head` is never named here: inline text is read as one
    /// run from `box_inline`, not field by field.
    const box_tag = 0;
    const box_inline_length = 1;
    const box_inline = 2;
    const box_bits = 3;
    const box_length = 4;

    /// A pointer to a scratch `runtime.Value` holding `held`, whose
    /// Luce type is `of`.
    ///
    /// **Two of the three words are facts about the type, not the
    /// value**, and MIR knows the type at compile time: the tag always,
    /// and the length for everything but a str. Those are written
    /// once beside the `alloca` in the entry block; only the payload is
    /// stored where the value is produced.  A box inside a loop is
    /// therefore one store per iteration rather than three.
    ///
    /// That motion is sound because nothing writes a box between the
    /// entry block and the call: this slot belongs to exactly one call
    /// site, and every runtime entry point that takes a boxed value
    /// declares the parameter `readonly` (`runtime_effects.zig`).  It is a
    /// motion LLVM cannot make for itself — LICM promotes a store out
    /// of a loop only when every use of the pointer is a load or a
    /// store, and passing it to a call is neither.
    fn boxed(
        self: *Body,
        of: types.Type,
        held: Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        const slot = try self.scratch(self.module.value_type, value_alignment, name);
        {
            const resume_at = self.enterEntry();
            defer self.leaveEntry(resume_at);
            try self.fillBoxShape(slot, of);
        }
        try self.fillBoxValue(slot, of, held);
        return slot;
    }

    /// The value in `register`, boxed.
    fn boxedRegister(self: *Body, register: mir.Register, name: []const u8) Error!Builder.Value {
        return self.boxed(self.function.result_types[register], self.produced[register].value, name);
    }

    /// The value in `register`, boxed **as a map key**. An enum uses its
    /// exact backing width (`mir.mapKeyStorage`); its LLVM value already
    /// has those bits, so only the box tag differs from the named type.
    fn boxedKey(self: *Body, register: mir.Register, name: []const u8) Error!Builder.Value {
        const written = self.function.result_types[register];
        const stored = mir.mapKeyStorage(written);
        if (stored.eql(written)) return self.boxedRegister(register, name);
        return self.boxed(stored, self.produced[register].value, name);
    }

    /// Element `index` of a run of boxes — a subscript list, a struct's
    /// fields — filled the way `boxed` fills a single slot.  The run
    /// itself is an entry-block `alloca`, so the address and the shape
    /// go there too and only the payload is stored here.
    fn boxAt(
        self: *Body,
        run: Builder.Value,
        index: usize,
        of: types.Type,
        held: Builder.Value,
    ) Error!void {
        const address = address: {
            const resume_at = self.enterEntry();
            defer self.leaveEntry(resume_at);
            const address = try self.wip.gep(
                .inbounds,
                self.module.value_type,
                run,
                &.{try self.module.builder.intValue(.i64, index)},
                "box.element",
            );
            try self.fillBoxShape(address, of);
            break :address address;
        };
        try self.fillBoxValue(address, of, held);
    }

    /// Element `index` of a run, filled with the whole `none` value —
    /// the padding a union's run carries past its live member's fields
    /// (docs/UNION.md D8, D12).  Every word is a constant, so the fill
    /// sits in the entry block beside the shapes and runs once however
    /// often the site is visited; the bits and length are written too,
    /// so the run the runtime copies carries no uninitialized words.
    fn noneAt(self: *Body, run: Builder.Value, index: usize) Error!void {
        const builder = self.module.builder;
        const resume_at = self.enterEntry();
        defer self.leaveEntry(resume_at);
        const address = try self.wip.gep(
            .inbounds,
            self.module.value_type,
            run,
            &.{try builder.intValue(.i64, index)},
            "box.none",
        );
        try self.storeBoxByte(address, box_tag, try builder.intValue(
            .i8,
            @intFromEnum(runtime.Tag.none),
        ));
        try self.storeBoxField(address, box_bits, try builder.intValue(.i64, 0));
        try self.storeBoxField(address, box_length, try builder.intValue(.i64, 0));
    }

    /// Initialize a physical weak slot to the null weak handle. The logical
    /// type is `T?`, but this cell is never unboxed directly: dedicated weak
    /// loads upgrade it first.
    fn fillWeakZero(self: *Body, slot: Builder.Value) Error!void {
        const builder = self.module.builder;
        try self.storeBoxByte(slot, box_tag, try builder.intValue(
            .i8,
            @intFromEnum(runtime.Tag.weak),
        ));
        try self.storeBoxField(slot, box_bits, try builder.intValue(.i64, runtime.null_index));
        try self.storeBoxField(slot, box_length, try builder.intValue(.i64, 0));
    }

    /// Element `index` of a run, filled with a value the run is going
    /// to **keep**.
    ///
    /// A store must not lose which form a str's text was in, so a
    /// register that was read out of a box is copied across whole, the
    /// way `emitLocalSet` fills a slot that owns its storage; a
    /// register with no box behind it is outside text by construction
    /// and boxes the ordinary way (docs/STRINGS.md).
    fn storedAt(self: *Body, run: Builder.Value, index: usize, register: mir.Register) Error!void {
        const of = self.function.result_types[register];
        if (self.produced[register].box == .none) {
            return self.boxAt(run, index, of, self.produced[register].value);
        }
        const address = address: {
            const resume_at = self.enterEntry();
            defer self.leaveEntry(resume_at);
            break :address try self.wip.gep(
                .inbounds,
                self.module.value_type,
                run,
                &.{try self.module.builder.intValue(.i64, index)},
                "box.element",
            );
        };
        _ = try self.wip.callMemCpy(
            address,
            value_alignment,
            self.produced[register].box,
            value_alignment,
            try self.module.builder.intValue(.i64, @sizeOf(runtime.Value)),
            .normal,
            true,
        );
    }

    /// Which `runtime.Tag` a value of `of` boxes as.  A `T?` has none
    /// of its own: what it boxes as is decided by whether it is there,
    /// so it is the one type this cannot answer.
    fn boxTag(self: *Body, of: types.Type) Error!runtime.Tag {
        return mir.boxTag(of) orelse self.fail("the tag of a T? read from its type");
    }

    /// The `bits` word a value of `of` puts in a box.
    fn boxBits(self: *Body, written: types.Type, held: Builder.Value) Error!Builder.Value {
        const of = written.storage();
        return switch (of) {
            .none => try self.module.builder.intValue(.i64, 0),
            .boolean => try self.wip.cast(.zext, held, .i64, "box.bits"),
            // A handle already *is* the `bits` word `Value` carries.
            .u64, .i64, .heap => held,
            .f64 => try self.wip.cast(.bitcast, held, .i64, "box.bits"),
            // A narrow scalar sits in the low half of the word,
            // zero-extended: `asI32` reads it back by truncating, so
            // the top half is never read and must not be a sign.
            .u8, .u16, .u32, .i8, .i16, .i32, .char => try self.wip.cast(.zext, held, .i64, "box.bits"),
            .f32 => try self.wip.cast(
                .zext,
                try self.wip.cast(.bitcast, held, .i32, "box.word"),
                .i64,
                "box.bits",
            ),
            .f16 => try self.wip.cast(
                .zext,
                try self.wip.cast(.bitcast, held, .i16, "box.word"),
                .i64,
                "box.bits",
            ),
            .strukt, .variant, .function => try self.wip.cast(.ptrtoint, held, .i64, "box.bits"),
            .str, .bytes => try self.wip.cast(
                .ptrtoint,
                try self.wip.extractValue(held, &.{0}, "box.text"),
                .i64,
                "box.bits",
            ),
            .optional => self.fail("the bits of a T? read from its type"),
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// The `length` word a value of `of` puts in a box.  Every type but
    /// str has one the type alone decides, which is what lets
    /// `fillBoxShape` write it once in the entry block.
    fn boxLength(self: *Body, written: types.Type, held: Builder.Value) Error!Builder.Value {
        const builder = self.module.builder;
        const of = written.storage();
        return switch (of) {
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .heap,
            .f16,
            .f32,
            .f64,
            .char,
            => try builder.intValue(.i64, 0),
            .strukt => |layout| try builder.intValue(
                .i64,
                self.module.program.structs[layout].runLength(),
            ),
            // A union's run length is a fact about the type, exactly
            // as a struct's is: every run of union `U` spans
            // `runLength` slots, the live member's fields first and
            // `none` padding after (docs/UNION.md D8, D12).  It must
            // be — a call's result is a bare pointer, and its box is
            // re-derived from the static type alone.
            .variant => |index| try builder.intValue(
                .i64,
                self.module.program.variants[index].runLength(),
            ),
            // Every function value spans the same two slots, bound or
            // not (docs/BINDING.md D12), which is what lets its box be
            // re-derived from the static type as a struct's is.
            .function => try builder.intValue(.i64, mir.function_run_length),
            .str, .bytes => try self.wip.extractValue(held, &.{1}, "box.length"),
            .optional => self.fail("the length of a T? read from its type"),
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// Whether `of`'s length is settled by the type rather than the
    /// value — true for everything but a str, whose length travels
    /// with its bytes.
    fn boxLengthIsFixed(of: types.Type) bool {
        return of != .str and of != .bytes;
    }

    /// The words of a `runtime.Value` that the Luce type alone decides:
    /// the tag, and the length for every type that has a fixed one.
    ///
    /// A `T?` has neither.  Both of its words turn on whether the value
    /// is there, so all three are written where the value is, and this
    /// writes nothing.
    fn fillBoxShape(self: *Body, slot: Builder.Value, of: types.Type) Error!void {
        if (of == .optional) return;
        const builder = self.module.builder;
        const tag = try self.boxTag(of);
        try self.storeBoxByte(slot, box_tag, try builder.intValue(.i8, @intFromEnum(tag)));
        // **Generated code never writes inline text.** A str in a
        // register is `{ptr, i64}` and boxing one says so, which is
        // what keeps a box one store per word; the runtime is the side
        // that decides to inline, at the store sites where it copies
        // anyway (docs/STRINGS.md).  So the form byte is a constant
        // here and rides to the entry block with the tag.
        if (of == .str or of == .bytes) {
            try self.storeBoxByte(slot, box_inline_length, try self.outsideText());
        }
        if (boxLengthIsFixed(of)) {
            try self.storeBoxField(slot, box_length, try self.boxLength(of, .none));
        }
    }

    fn outsideText(self: *Body) Error!Builder.Value {
        return self.module.builder.intValue(.i8, runtime.text_outside);
    }

    /// The word — or, for a str, the two words — that carry the
    /// value itself, stored where the value is produced.
    fn fillBoxValue(self: *Body, slot: Builder.Value, of: types.Type, held: Builder.Value) Error!void {
        if (of == .none) return;
        if (of == .optional) return self.fillBoxOptional(slot, of.optional, held);
        try self.storeBoxField(slot, box_bits, try self.boxBits(of, held));
        if (!boxLengthIsFixed(of)) {
            try self.storeBoxField(slot, box_length, try self.boxLength(of, held));
        }
    }

    /// All three words of a boxed `T?`, written here because none of
    /// them is a fact about the type.
    ///
    /// Absence boxes as `runtime.Value.none` — tag zero, no payload,
    /// no length — which is the very value the interpreter parks in the
    /// same field, so the runtime's ownership walk finds nothing to own
    /// on either engine and S43 costs no code at all.  Presence boxes
    /// exactly as the payload would on its own.
    fn fillBoxOptional(
        self: *Body,
        slot: Builder.Value,
        payload: types.Type.Payload,
        held: Builder.Value,
    ) Error!void {
        const builder = self.module.builder;
        const of = payload.asType();
        const present = try self.wip.extractValue(held, &.{Module.optional_present}, "box.present");
        const inner = try self.wip.extractValue(held, &.{Module.optional_payload}, "box.held");
        const absent_word = try builder.intValue(.i64, 0);

        try self.storeBoxByte(slot, box_tag, try self.wip.select(
            .normal,
            present,
            try builder.intValue(.i8, @intFromEnum(try self.boxTag(of))),
            try builder.intValue(.i8, @intFromEnum(runtime.Tag.none)),
            "box.tag",
        ));
        // Absence is the `none` tag, and nothing reads the form byte of
        // a value that is not text, so a present str's constant
        // serves for both.
        if (of == .str or of == .bytes) {
            try self.storeBoxByte(slot, box_inline_length, try self.outsideText());
        }
        try self.storeBoxField(slot, box_bits, try self.wip.select(
            .normal,
            present,
            try self.boxBits(of, inner),
            absent_word,
            "box.bits",
        ));
        try self.storeBoxField(slot, box_length, try self.wip.select(
            .normal,
            present,
            try self.boxLength(of, inner),
            absent_word,
            "box.length",
        ));
    }

    fn storeBoxField(
        self: *Body,
        slot: Builder.Value,
        index: usize,
        word: Builder.Value,
    ) Error!void {
        const address = try self.wip.gepStruct(self.module.value_type, slot, index, "box.at");
        _ = try self.wip.store(.normal, word, address, value_alignment);
    }

    fn storeBoxByte(
        self: *Body,
        slot: Builder.Value,
        index: usize,
        byte: Builder.Value,
    ) Error!void {
        const address = try self.wip.gepStruct(self.module.value_type, slot, index, "box.at");
        _ = try self.wip.store(.normal, byte, address, byte_alignment);
    }

    /// Read a Luce value of type `of` back out of the `runtime.Value`
    /// at `slot`.
    fn unboxed(self: *Body, written: types.Type, slot: Builder.Value, name: []const u8) Error!Builder.Value {
        if (written == .none) return .none;
        if (written == .optional) return self.unboxedOptional(written.optional, slot, name);
        const of = written.storage();
        const bits = try self.loadBoxField(slot, box_bits, "unbox.bits");
        return switch (of) {
            .u64, .i64, .heap => bits,
            .u8, .i8 => try self.wip.cast(.trunc, bits, .i8, name),
            .u16, .i16 => try self.wip.cast(.trunc, bits, .i16, name),
            .u32, .i32, .char => try self.wip.cast(.trunc, bits, .i32, name),
            .f32 => try self.wip.cast(
                .bitcast,
                try self.wip.cast(.trunc, bits, .i32, "unbox.word"),
                .float,
                name,
            ),
            .f16 => try self.wip.cast(
                .bitcast,
                try self.wip.cast(.trunc, bits, .i16, "unbox.word"),
                .half,
                name,
            ),
            .boolean => try self.wip.icmp(
                .ne,
                bits,
                try self.module.builder.intValue(.i64, 0),
                name,
            ),
            .f64 => try self.wip.cast(.bitcast, bits, .double, name),
            .str, .bytes => try self.unboxedText(slot, bits, name),
            // The field count is a compile-time fact, so only the
            // address of the run travels back.
            .strukt, .variant, .function => try self.wip.cast(.inttoptr, bits, .ptr, name),
            .none, .optional => unreachable, // answered above
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// The `{ptr, i64}` a str travels in, read out of a box in
    /// whichever form the text is in.
    ///
    /// **The pointer this answers may be into the box itself.**  Short
    /// text lives in the value, so a register reading one borrows the
    /// place holding it — a frame slot, an array cell, a struct's
    /// field run, or the scratch a runtime call answered into.  That is
    /// sound because a MIR register never leaves its block, so it
    /// cannot outlive any of those; what it must never do is leave the
    /// *frame*, which is why `ret` goes through `export_storage`
    /// (docs/STRINGS.md).
    fn unboxedText(
        self: *Body,
        slot: Builder.Value,
        bits: Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        const form = try self.loadBoxByte(slot, box_inline_length, "unbox.form");
        const outside = try self.wip.icmp(.eq, form, try self.outsideText(), "text.outside");
        const address = try self.wip.select(
            .normal,
            outside,
            try self.wip.cast(.inttoptr, bits, .ptr, "unbox.text"),
            try self.wip.gepStruct(self.module.value_type, slot, box_inline, "unbox.inline"),
            "text.at",
        );
        const length = try self.wip.select(
            .normal,
            outside,
            try self.loadBoxField(slot, box_length, "unbox.length"),
            try self.wip.cast(.zext, form, .i64, "inline.length"),
            "text.length",
        );
        return self.wip.buildAggregate(self.module.string_type, &.{ address, length }, name);
    }

    /// A `T?` read back out of a box: present when the tag is anything
    /// but `none`, and carrying the payload's own zero when it is not.
    ///
    /// The absent payload is chosen rather than merely left as whatever
    /// the zeroed words read as, because for a heap `T?` those words
    /// read as a handle to row zero — a live row — while the zero of an
    /// object-typed place is the *null* handle.  Nothing narrows to an
    /// absent payload and so nothing can look, but the two halves of a
    /// `T?` agree on what absence carries either way, on both engines.
    fn unboxedOptional(
        self: *Body,
        payload: types.Type.Payload,
        slot: Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        const of = payload.asType();
        const present = try self.wip.icmp(
            .ne,
            try self.loadBoxByte(slot, box_tag, "unbox.tag"),
            try self.module.builder.intValue(.i8, @intFromEnum(runtime.Tag.none)),
            "unbox.present",
        );
        const inner = try self.unboxed(of, slot, "unbox.held");
        return self.wip.buildAggregate(
            try self.module.valueType(.{ .optional = payload }),
            &.{
                try self.wip.select(.normal, present, inner, try self.zeroValue(of), "unbox.or.zero"),
                present,
            },
            name,
        );
    }

    fn loadBoxField(
        self: *Body,
        slot: Builder.Value,
        index: usize,
        name: []const u8,
    ) Error!Builder.Value {
        const address = try self.wip.gepStruct(self.module.value_type, slot, index, "unbox.at");
        return self.wip.load(.normal, .i64, address, value_alignment, name);
    }

    fn loadBoxByte(
        self: *Body,
        slot: Builder.Value,
        index: usize,
        name: []const u8,
    ) Error!Builder.Value {
        const address = try self.wip.gepStruct(self.module.value_type, slot, index, "unbox.at");
        return self.wip.load(.normal, .i8, address, byte_alignment, name);
    }

    /// What this function hands a callee: one less frame than it has
    /// itself.  Computed once, in the entry block, the first time the
    /// function calls anything — a leaf function never subtracts.
    fn calleeDepth(self: *Body) Error!Builder.Value {
        if (self.callee_depth != .none) return self.callee_depth;
        const resume_at = self.wip.cursor;
        const filled = self.entry_block.ptr(self.wip).instructions.items.len;
        std.debug.assert(filled > 0);
        self.wip.cursor = .{ .block = self.entry_block, .instruction = @intCast(filled - 1) };
        self.callee_depth = try self.wip.bin(
            .@"sub nsw",
            self.depth,
            try self.module.builder.intValue(.i64, 1),
            "callee.depth",
        );
        self.wip.cursor = resume_at;
        return self.callee_depth;
    }

    /// Call a `libluce_rt` entry point that cannot trap.
    fn callRuntime(
        self: *Body,
        which: Service,
        result: Builder.Type,
        arguments: []const Builder.Value,
        out_name: []const u8,
    ) Error!Builder.Value {
        return self.module.callService(self.wip, which, result, arguments, out_name);
    }

    /// Call a `libluce_rt` entry point that can trap, and unwind if it
    /// did.  The runtime has already told the host why, at the site.
    fn callChecked(self: *Body, which: Service, arguments: []const Builder.Value) Error!void {
        const trapped = try self.callRuntime(which, .i32, arguments, "trapped");
        const failed = try self.wip.icmp(
            .ne,
            trapped,
            try self.module.builder.intValue(.i32, 0),
            "rt.failed",
        );
        try self.propagate(failed);
    }

    /// Call a `libluce_rt` entry point that answers a value through a
    /// trailing out-pointer, and leave the answer in `register`.
    fn callAnswering(
        self: *Body,
        register: mir.Register,
        which: Service,
        arguments: []const Builder.Value,
    ) Error!void {
        const gpa = self.module.gpa;
        var all: std.ArrayList(Builder.Value) = .empty;
        defer all.deinit(gpa);
        try all.appendSlice(gpa, arguments);
        const out = try self.scratch(self.module.value_type, value_alignment, "rt.out");
        try all.append(gpa, out);
        try self.callChecked(which, all.items);
        self.produced[register].value = try self.unboxed(
            self.function.result_types[register],
            out,
            "rt.value",
        );
        // This slot belongs to this call site alone and nothing writes
        // it again before the register dies, so it is the box the
        // register was read from.
        self.produced[register].box = out;
    }

    /// The subscripts of one indexing operation, as a run of boxed
    /// values, plus how many there are.
    ///
    /// Each is boxed as a map key would be. Sequence indexes are
    /// already `i64`; enum map keys use their exact backing width.
    fn subscripts(self: *Body, of: []const mir.Register) Error!struct { Builder.Value, Builder.Value } {
        const run = try self.scratchRun(
            self.module.value_type,
            of.len,
            value_alignment,
            "indices",
        );
        for (of, 0..) |register, index| {
            const written = self.function.result_types[register];
            const stored = mir.mapKeyStorage(written);
            try self.boxAt(
                run,
                index,
                stored,
                self.produced[register].value,
            );
        }
        return .{ run, try self.module.builder.intValue(.i64, of.len) };
    }

    // -- Lists and Arrays, without the runtime call ------------------------
    //
    // `xs[i]`, `grid[r, c]`, `len(xs)` and `xs.append(v)` on a list or
    // an array are generated here rather than called: the object table
    // row, the bounds check, and the element load, inline.  A call
    // cannot be: a boxed subscript is a store the loop cannot hoist, so
    // the call stays pinned inside the loop however precisely it is
    // described (docs/CODEGEN.md).
    //
    // Two facts make it sound.  The program already knows which
    // container the target is and what it holds — `heap_types` says so,
    // statically — so the runtime's four-way switch on the object's
    // kind has one arm left at compile time; and the *kind* the
    // elements are stored at is settled by the element type alone,
    // whoever built the object (`runtime/containers.zig`'s `emptyList`),
    // so a cell's width is a constant here.
    //
    // **A list's storage moves and an array's does not**, and that is
    // the whole difference between them. An array's `dims` and
    // `elements` never move while it lives; a list's `elements` move
    // under `append`, and its `count` moves with them.  So a resolved
    // view is only ever reused across instructions that cannot move a
    // buffer — `optimize.effects.viewStable`, which already answers
    // `false` for `append_value`, `insert_value` and every call for
    // exactly this reason, and which is what ends the block a view
    // lives in.  Nothing here caches anything past that line.
    //
    // The offsets come from `runtime.layout`, measured from the Zig
    // types with `@offsetOf` and checked against a real `Runtime` by a
    // test beside them.

    /// The shape of the list or array a register holds, or null when it
    /// holds anything else — a map, a builder, or no object at all.
    const ElementShape = struct {
        element: types.Type,
        /// One for a list, which has a length and no other shape.
        rank: u8,
        /// Whether the storage can move under the program's feet.  A
        /// list's does, under `append` and `insert`; an array's never
        /// does. What reads it: `dim_size`, which is an array's
        /// question, and the append path, which is a list's.
        growable: bool,
    };

    fn elementShape(self: *Body, register: mir.Register) ?ElementShape {
        const of = self.function.result_types[register];
        if (of != .heap) return null;
        return switch (self.module.program.heap_types[of.heap]) {
            .array => |shape| .{
                .element = shape.element,
                .rank = shape.rank,
                .growable = false,
            },
            .list => |element| .{ .element = element, .rank = 1, .growable = true },
            .class, .map, .builder, .handle, .task => null,
        };
    }

    /// Whether an element of type `of` can be written in place.
    ///
    /// A store into a container frees the element it replaced and
    /// adopts the one arriving (S20, S22).  Neither happens for a
    /// scalar, so those write inline; anything that owns something —
    /// an object, and since copy-on-store a str's bytes or a
    /// struct's field run (docs/STRINGS.md) — goes on calling the
    /// runtime, which is the one place that walk is written.
    ///
    /// A *read* stays inline whatever the element type: reading an
    /// element is a borrow of it, and borrows own nothing.
    fn ownsNothing(written: types.Type) bool {
        // An enum is a number in a cell, so it writes in place like one
        // (docs/ENUMS.md D9).
        return switch (written.storage()) {
            .boolean, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char => true,
            .none, .str, .bytes, .strukt, .variant, .function, .heap, .optional => false,
            .enumeration => unreachable, // answered by storage() above
        };
    }

    /// `base + offset` bytes.
    fn byteOffset(
        self: *Body,
        base: Builder.Value,
        offset: usize,
        name: []const u8,
    ) Error!Builder.Value {
        if (offset == 0) return base;
        return self.wip.gep(.inbounds, .i8, base, &.{
            try self.module.builder.intValue(.i64, offset),
        }, name);
    }

    /// The two halves of a handle, as the row walk needs them: which
    /// row, and which occupant of it (`runtime.Handle`).
    ///
    /// Both are free.  The index is the handle's low word and the
    /// generation its high one, so a machine reads the first as a
    /// sub-register and the second as one shift.
    const Parts = struct { index: Builder.Value, generation: Builder.Value };

    fn handleParts(self: *Body, handle: Builder.Value) Error!Parts {
        const builder = self.module.builder;
        return .{
            .index = try self.wip.cast(.trunc, handle, .i32, "handle.index"),
            .generation = try self.wip.cast(
                .trunc,
                try self.wip.bin(
                    .lshr,
                    handle,
                    try builder.intValue(.i64, runtime.generation_shift),
                    "handle.high",
                ),
                .i32,
                "handle.generation",
            ),
        };
    }

    /// The object table row a handle names, having made the two checks
    /// `Runtime.resolve` makes: the null handle traps `null_object`, a
    /// freed one `use_after_free`.
    ///
    /// `resolve`'s third check — the handle inside the table's bounds —
    /// is not emitted and cannot fire: every non-null handle in a
    /// register came from `attach`, which returned the very row it
    /// names, and a row is only ever re-occupied, never removed.
    fn checkHandle(self: *Body, index: Builder.Value) Error!void {
        try self.check(try self.wip.icmp(
            .eq,
            index,
            try self.module.builder.intValue(.i32, runtime.null_index),
            "is.null",
        ), .null_object);
    }

    /// The row's generation is not the handle's, or is odd (a free row),
    /// so the object the handle names is gone — whether or not somebody
    /// else has since moved into the row. The low bit is occupancy, so a
    /// forged handle using a free row's current generation cannot expose
    /// an empty row through an inline array access.
    fn checkOccupant(
        self: *Body,
        generation: Builder.Value,
        expected: Builder.Value,
    ) Error!void {
        try self.check(try self.wip.icmp(
            .ne,
            generation,
            expected,
            "stale",
        ), .use_after_free);
        const free = try self.wip.icmp(
            .ne,
            try self.wip.bin(
                .@"and",
                generation,
                try self.module.builder.intValue(.i32, 1),
                "generation.occupied",
            ),
            try self.module.builder.intValue(.i32, 0),
            "generation.free",
        );
        try self.check(free, .use_after_free);
    }

    /// A load of a row's facts — the table base, a generation, a
    /// `dims` pointer or entry, an elements pointer, a count —
    /// carrying the rows scope (`Module.aliasScopes` has the whole
    /// argument).  The same shape as `wip.load`, so a call site
    /// changes one name and nothing else.
    fn rowLoad(
        self: *Body,
        access_kind: Builder.MemoryAccessKind,
        ty: Builder.Type,
        address: Builder.Value,
        alignment: Builder.Alignment,
        name: []const u8,
    ) Error!Builder.Value {
        const value = try self.wip.load(access_kind, ty, address, alignment, name);
        const scopes = try self.module.aliasScopes();
        try self.wip.attachMetadata(value, .@"alias.scope", scopes.rows);
        try self.wip.attachMetadata(value, .@"noalias", scopes.elements);
        return value;
    }

    /// The element-side twin: a cell load carries the elements scope
    /// and disclaims the rows one, which is what lets a loop that
    /// stores elements keep its row facts in registers.
    fn cellLoad(
        self: *Body,
        ty: Builder.Type,
        address: Builder.Value,
        alignment: Builder.Alignment,
        name: []const u8,
    ) Error!Builder.Value {
        const value = try self.wip.load(.normal, ty, address, alignment, name);
        const scopes = try self.module.aliasScopes();
        try self.wip.attachMetadata(value, .@"alias.scope", scopes.elements);
        try self.wip.attachMetadata(value, .@"noalias", scopes.rows);
        return value;
    }

    /// And the cell store, the instruction the rows scope exists to
    /// be hoisted over.
    fn cellStore(
        self: *Body,
        held: Builder.Value,
        address: Builder.Value,
        alignment: Builder.Alignment,
    ) Error!void {
        const stored = try self.wip.store(.normal, held, address, alignment);
        const scopes = try self.module.aliasScopes();
        try self.wip.attachMetadata(stored.toValue(), .@"alias.scope", scopes.elements);
        try self.wip.attachMetadata(stored.toValue(), .@"noalias", scopes.rows);
    }

    /// A write to a row's own facts — there is exactly one, the count
    /// an inline `append` bumps.  It carries the rows scope, so it
    /// stops a row load being hoisted over it and does not stop an
    /// element load.
    fn rowStore(
        self: *Body,
        held: Builder.Value,
        address: Builder.Value,
        alignment: Builder.Alignment,
    ) Error!void {
        const stored = try self.wip.store(.normal, held, address, alignment);
        const scopes = try self.module.aliasScopes();
        try self.wip.attachMetadata(stored.toValue(), .@"alias.scope", scopes.rows);
        try self.wip.attachMetadata(stored.toValue(), .@"noalias", scopes.elements);
    }

    fn resolveRow(self: *Body, register: mir.Register) Error!Builder.Value {
        const builder = self.module.builder;
        const parts = try self.handleParts(self.produced[register].value);
        try self.checkHandle(parts.index);

        const table = try self.rowLoad(
            .normal,
            .ptr,
            try self.byteOffset(self.runtime, runtime.layout.table_pointer, "table.at"),
            pointer_alignment,
            "table",
        );
        const row = try self.wip.gep(.inbounds, .i8, table, &.{try self.wip.bin(
            .@"mul nsw",
            try self.wip.cast(.zext, parts.index, .i64, "row.index"),
            try builder.intValue(.i64, runtime.layout.row_size),
            "row.at",
        )}, "row");

        try self.checkOccupant(try self.rowLoad(
            .normal,
            .i32,
            try self.byteOffset(row, runtime.layout.generation, "generation.at"),
            Builder.Alignment.fromByteUnits(4),
            "generation",
        ), parts.generation);
        return row;
    }

    /// One list or array, resolved: the element base and one axis
    /// length per rank, all as SSA values.
    ///
    /// **Where the resolve happens is the whole point.**  Resolving at
    /// every access leaves four loads — the table base, the row's
    /// generation, the `dims` pointer, and `dims[0]` — in front of
    /// every element read, and LLVM cannot hoist any of them out of a
    /// loop that also *stores* an element, because it has no way to
    /// know the two do not overlap.  Resolving once per basic block
    /// turns them into values, and a value cannot be invalidated by a
    /// store.
    ///
    /// Resolving at the handle's **first use in the block**, rather
    /// than lifting it above the loop, is what keeps the trap ordering
    /// exactly as it is: `use_after_free` still fires at the
    /// instruction it fires at today, because the block a view lives
    /// in ends at every instruction that could free anything
    /// (`effects.viewStable`).
    ///
    /// That same line is what makes a view of a *list* sound, and it
    /// is one sentence: a view dies at every instruction that could
    /// move a buffer — every call, every append, every insert — which
    /// is precisely the set `viewStable` already refuses.  Nothing is
    /// carried across one.
    const ElementView = struct {
        /// The MIR register whose handle this resolves.
        register: mir.Register,
        /// The resolved object-table row.  Inline mutations reach it
        /// after the ordinary null/stale checks, without giving up the
        /// scalar path.
        row: Builder.Value,
        /// `Object.dims.ptr`, or `.none` for a list and for a rank-1
        /// array, neither of which reads it: their one bound is
        /// `Object.elements.count`, a word in the row rather than a
        /// word behind a pointer in the row.  That saved load is not a
        /// micro-optimization — the dependent load is what stops LLVM's
        /// loop unswitching, and with it the vectorizer, on the loop
        /// around the access.
        dims: Builder.Value,
        /// `Object.elements.bytes.ptr`, indexed as the element kind's
        /// own cell type.
        elements: Builder.Value,
        /// Where this view's axis lengths start in `view_bounds`.
        bounds_at: u32,
        rank: u8,

        fn bounds(self: ElementView, body: *const Body) []const Builder.Value {
            return body.view_bounds.items[self.bounds_at..][0..self.rank];
        }
    };

    /// The LLVM type one cell of an `array[element]` is.
    ///
    /// It mirrors `runtime.Object.ElementKind`, which is what the
    /// runtime actually allocates: an `array[f64]` is `f64`s, so
    /// reading one is a `load f64` and nothing else.  The two are
    /// held together by the byte-offset test in `runtime/test.zig`,
    /// which reads an f64 array's element as an `f64`.
    fn cellType(self: *Body, written: types.Type) Builder.Type {
        // An `array[Method, n]` is an array of the backing width, which
        // is what D9 means by "at the backing width, unboxed where
        // scalars are unboxed".
        const element = written.storage();
        return switch (element) {
            .f64 => .double,
            .u64, .i64 => .i64,
            .f32 => .float,
            .u32, .i32, .char => .i32,
            .f16 => .half,
            .u16, .i16 => .i16,
            .u8, .i8, .boolean => .i8,
            // Everything whose tag or length is not settled by the
            // type keeps the 24-byte slot.
            .none, .str, .bytes, .strukt, .variant, .heap, .optional => self.module.value_type,
            .enumeration => unreachable, // answered by storage() above
            // A bare function type is never an element type: the
            // storable form is `(func(...) -> R)?`, which arrives at
            // the `.optional` arm above (docs/BINDING.md D7).
            .function => unreachable, // not an element type
        };
    }

    fn cellAlignment(written: types.Type) Builder.Alignment {
        return switch (written.storage()) {
            .boolean, .u8, .i8 => Builder.Alignment.fromByteUnits(1),
            .u16, .i16, .f16 => Builder.Alignment.fromByteUnits(2),
            .u32, .i32, .f32, .char => Builder.Alignment.fromByteUnits(4),
            .none,
            .u64,
            .i64,
            .f64,
            .str,
            .bytes,
            .strukt,
            .variant,
            .heap,
            .optional,
            => Builder.Alignment.fromByteUnits(8),
            .enumeration => unreachable, // answered by storage() above
            // A bare function type is never an element type: the
            // storable form is `(func(...) -> R)?`, which arrives at
            // the `.optional` arm above (docs/BINDING.md D7).
            .function => unreachable, // not an element type
        };
    }

    /// How many bytes one cell occupies — `Object.ElementKind.width`,
    /// answered from the program's type instead of from the object,
    /// which is the same number because the kind is a fact of the
    /// element type (`runtime/containers.zig`'s `emptyList`).
    ///
    /// Only the append path needs it: everything else indexes with a
    /// `getelementptr` over `cellType`, which does the multiply itself.
    /// This is the arithmetic that decides whether there is room, and
    /// it is in bytes because a capacity is (`layout.elements_capacity`).
    fn cellWidth(written: types.Type) u32 {
        return switch (written.storage()) {
            .boolean, .u8, .i8 => 1,
            .u16, .i16, .f16 => 2,
            .u32, .i32, .f32, .char => 4,
            .u64, .i64, .f64 => 8,
            // The boxed slot, whose size is `runtime.Value`'s and is
            // asserted against it by `runtime/test.zig`.
            .none, .str, .bytes, .strukt, .variant, .heap, .optional => @sizeOf(runtime.Value),
            .enumeration => unreachable, // answered by storage() above
            // A bare function type is never an element type: the
            // storable form is `(func(...) -> R)?`, which arrives at
            // the `.optional` arm above (docs/BINDING.md D7).
            .function => unreachable, // not an element type
        };
    }

    /// One resolution the preheader of a loop already made: the row's
    /// three facts, read once for the whole loop.
    const Hoisted = struct {
        row: Builder.Value = .none,
        generation: Builder.Value = .none,
        dims: Builder.Value = .none,
        elements: Builder.Value = .none,
        bounds_at: u32 = 0,
        made: bool = false,
    };

    fn forgetViews(self: *Body) void {
        self.views.clearRetainingCapacity();
        self.view_bounds.clearRetainingCapacity();
    }

    /// Read every row this block's loops want, once, here.
    ///
    /// The loads are made *safe rather than checked*: a null handle
    /// reads the module's dead row instead of an address 4 GB past the
    /// table, so nothing here can fault and nothing here decides
    /// anything.  Every access still tests the handle and the row's
    /// generation for itself, so a trap fires where it always did.
    fn emitHoists(self: *Body) Error!void {
        const gpa = self.module.gpa;
        const builder = self.module.builder;
        for (self.hoists.emitted[self.block]) |index| {
            const hoist = self.hoists.hoists[index];
            const handle = try self.wip.load(
                .normal,
                .i64,
                self.local_slots[hoist.local],
                Module.valueAlignment(self.function.locals[hoist.local].local_type),
                "hoist.handle",
            );
            const parts = try self.handleParts(handle);
            const table = try self.rowLoad(
                .normal,
                .ptr,
                try self.byteOffset(self.runtime, runtime.layout.table_pointer, "table.at"),
                pointer_alignment,
                "table",
            );
            const row = try self.wip.select(
                .normal,
                try self.wip.icmp(
                    .eq,
                    parts.index,
                    try builder.intValue(.i32, runtime.null_index),
                    "hoist.null",
                ),
                (try self.module.deadRow()).toValue(),
                try self.wip.gep(.inbounds, .i8, table, &.{try self.wip.bin(
                    .@"mul nsw",
                    try self.wip.cast(.zext, parts.index, .i64, "hoist.index"),
                    try builder.intValue(.i64, runtime.layout.row_size),
                    "hoist.at",
                )}, "hoist.row"),
                "row",
            );

            var made: Hoisted = .{
                .made = true,
                .row = row,
                .bounds_at = @intCast(self.hoist_bounds.items.len),
                .generation = try self.rowLoad(
                    .normal,
                    .i32,
                    try self.byteOffset(row, runtime.layout.generation, "generation.at"),
                    Builder.Alignment.fromByteUnits(4),
                    "generation",
                ),
                .elements = try self.rowLoad(
                    .normal,
                    .ptr,
                    try self.byteOffset(row, runtime.layout.elements_pointer, "elements.at"),
                    pointer_alignment,
                    "elements",
                ),
            };
            if (hoist.rank == 1) {
                try self.hoist_bounds.append(gpa, try self.rowLoad(
                    .normal,
                    .i64,
                    try self.byteOffset(row, runtime.layout.elements_count, "count.at"),
                    value_alignment,
                    "count",
                ));
            } else {
                made.dims = try self.rowLoad(
                    .normal,
                    .ptr,
                    try self.byteOffset(row, runtime.layout.array_dims, "dims.at"),
                    pointer_alignment,
                    "dims",
                );
                for (0..hoist.rank) |axis| {
                    try self.hoist_bounds.append(gpa, try self.rowLoad(
                        .normal,
                        .i64,
                        try self.wip.gep(
                            .inbounds,
                            .i64,
                            made.dims,
                            &.{try builder.intValue(.i64, axis)},
                            "dim.at",
                        ),
                        value_alignment,
                        "dim",
                    ));
                }
            }
            self.hoisted[index] = made;
        }
    }

    /// The lifted resolution this block may read for `register`, if
    /// the register is a handle read straight out of a local and some
    /// enclosing loop's preheader already resolved it.
    fn liftedView(self: *Body, register: mir.Register) ?u32 {
        const local = switch (self.function.instructions[register]) {
            .local_get => |which| which,
            else => return null,
        };
        const index = self.hoists.find(self.block, local) orelse return null;
        if (!self.hoisted[index].made) return null;
        return index;
    }

    /// The list or array in `register`, resolved — reusing the
    /// resolution already made in this block if there is one.
    fn elementView(self: *Body, register: mir.Register, shape: ElementShape) Error!ElementView {
        for (self.views.items) |found| {
            if (found.register == register) return found;
        }
        const gpa = self.module.gpa;
        if (self.liftedView(register)) |index| {
            // The loads happened in the preheader; the checks happen
            // here, which is what keeps the trap where it belongs.
            const parts = try self.handleParts(self.produced[register].value);
            try self.checkHandle(parts.index);
            try self.checkOccupant(self.hoisted[index].generation, parts.generation);
            const made: ElementView = .{
                .register = register,
                .row = self.hoisted[index].row,
                .dims = self.hoisted[index].dims,
                .elements = self.hoisted[index].elements,
                .bounds_at = @intCast(self.view_bounds.items.len),
                .rank = shape.rank,
            };
            try self.view_bounds.appendSlice(
                gpa,
                self.hoist_bounds.items[self.hoisted[index].bounds_at..][0..shape.rank],
            );
            try self.views.append(gpa, made);
            return made;
        }
        const row = try self.resolveRow(register);
        const bounds_at: u32 = @intCast(self.view_bounds.items.len);
        var dims: Builder.Value = .none;
        if (shape.rank == 1) {
            // `count` is the product of the axes, so for one axis it
            // *is* that axis — one load nearer than `dims[0]`.  A
            // A list has no `dims` at all and this is its length.
            try self.view_bounds.append(gpa, try self.rowLoad(
                .normal,
                .i64,
                try self.byteOffset(row, runtime.layout.elements_count, "count.at"),
                value_alignment,
                "count",
            ));
        } else {
            dims = try self.rowLoad(
                .normal,
                .ptr,
                try self.byteOffset(row, runtime.layout.array_dims, "dims.at"),
                pointer_alignment,
                "dims",
            );
            for (0..shape.rank) |axis| {
                try self.view_bounds.append(gpa, try self.rowLoad(
                    .normal,
                    .i64,
                    try self.wip.gep(
                        .inbounds,
                        .i64,
                        dims,
                        &.{try self.module.builder.intValue(.i64, axis)},
                        "dim.at",
                    ),
                    value_alignment,
                    "dim",
                ));
            }
        }
        const made: ElementView = .{
            .register = register,
            .row = row,
            .dims = dims,
            .elements = try self.rowLoad(
                .normal,
                .ptr,
                try self.byteOffset(row, runtime.layout.elements_pointer, "elements.at"),
                pointer_alignment,
                "elements",
            ),
            .bounds_at = bounds_at,
            .rank = shape.rank,
        };
        try self.views.append(gpa, made);
        return made;
    }

    /// The address of the element `indices` names, bound-checked axis
    /// by axis and flattened exactly as `heap.flattenIndex` does it.
    fn elementAddress(
        self: *Body,
        view: ElementView,
        element: types.Type,
        indices: []const mir.Register,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        var flat = try builder.intValue(.i64, 0);
        for (indices, view.bounds(self)) |register, size| {
            const index = self.produced[register].value;
            const below = try self.wip.icmp(.slt, index, try builder.intValue(.i64, 0), "below");
            const above = try self.wip.icmp(.sge, index, size, "above");
            try self.check(
                try self.wip.bin(.@"or", below, above, "out.of.range"),
                .index_bounds,
            );
            flat = try self.wip.bin(
                .@"add nsw",
                try self.wip.bin(.@"mul nsw", flat, size, "axis.base"),
                index,
                "flat",
            );
        }
        return self.wip.gep(
            .inbounds,
            self.cellType(element),
            view.elements,
            &.{flat},
            "element",
        );
    }

    /// Read one cell as the Luce value it holds.
    fn loadCell(self: *Body, written: types.Type, address: Builder.Value) Error!Builder.Value {
        const element = written.storage();
        return switch (element) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char => try self.cellLoad(
                self.cellType(element),
                address,
                cellAlignment(element),
                "element",
            ),
            .boolean => try self.wip.icmp(
                .ne,
                try self.cellLoad(.i8, address, cellAlignment(element), "cell"),
                try self.module.builder.intValue(.i8, 0),
                "element",
            ),
            // A boxed cell: the tag and the length are already the
            // element type's, so only the payload words are read.
            .none, .str, .bytes, .strukt, .variant, .heap, .optional => try self.unboxed(
                element,
                address,
                "element",
            ),
            .enumeration => unreachable, // answered by storage() above
            // A bare function type is never an element type: the
            // storable form is `(func(...) -> R)?`, which arrives at
            // the `.optional` arm above (docs/BINDING.md D7).
            .function => unreachable, // not an element type
        };
    }

    /// Write one cell.  The element type is the same for every slot, so
    /// a typed cell takes the payload as it stands and a boxed one
    /// keeps the tag and length `new` wrote.
    fn storeCell(
        self: *Body,
        written: types.Type,
        address: Builder.Value,
        held: Builder.Value,
    ) Error!void {
        const element = written.storage();
        switch (element) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char => try self.cellStore(
                held,
                address,
                cellAlignment(element),
            ),
            .boolean => try self.cellStore(
                try self.wip.cast(.zext, held, .i8, "cell"),
                address,
                cellAlignment(element),
            ),
            .none, .str, .bytes, .strukt, .variant, .heap, .optional => try self.fillBoxValue(
                address,
                element,
                held,
            ),
            .enumeration => unreachable, // answered by storage() above
            // A bare function type is never an element type: the
            // storable form is `(func(...) -> R)?`, which arrives at
            // the `.optional` arm above (docs/BINDING.md D7).
            .function => unreachable, // not an element type
        }
    }

    /// `len(xs)`: a list's element count, an array's first axis.
    fn emitInlineLength(
        self: *Body,
        register: mir.Register,
        target: mir.Register,
        shape: ElementShape,
    ) Error!void {
        if (shape.rank == 0) {
            self.produced[register].value = try self.module.builder.intValue(.i64, 0);
            return;
        }
        const view = try self.elementView(target, shape);
        self.produced[register].value = view.bounds(self)[0];
    }

    /// `xs.append(v)` on a list whose elements own nothing: the store
    /// and the count bump, inline, with the runtime called only to
    /// grow the buffer.
    ///
    /// **The room is measured in bytes, not in elements.**
    /// `Elements.ensureCapacity` grows a byte length geometrically and
    /// does not leave it a whole multiple of the width, so
    /// `count < capacity` would be a division — the very division the
    /// bytes run took off this path (docs/CODEGEN.md).
    /// `(count + 1) * width <= bytes.len` asks the same question with
    /// a constant multiply, and the width *is* a constant here because
    /// the storage kind is a fact of the element type
    /// (`runtime/containers.zig`'s `emptyList`).
    ///
    /// The two checks the call would have made are made here, in the
    /// same order, at the same instruction: a null handle traps
    /// `null_object`, a stale one `use_after_free`.  The growing arm
    /// resolves a second time, which costs one walk on the path that
    /// was about to allocate.
    ///
    /// The element type is the gate. A list append never *frees*
    /// anything — it only adopts what arrives — so the rule is not
    /// `index_set`'s: what it needs is that nothing has to be adopted,
    /// which is `ownsNothing`. A str, a struct and an object all
    /// go on calling `luce_rt_append`, which is the one place the
    /// ownership walk is written.
    /// Trap `immutable_object` when an inline container write may target a
    /// materialized program constant. Runtime-routed writes meet
    /// `Runtime.requireMutable`; an inline write reaches the row itself, so
    /// it reads `Object.constant` and traps the same way. Final-MIR
    /// provenance proves the check unnecessary only for locally created
    /// rows; parameters, calls, constants, and hostile alias chains keep it.
    fn checkNotConstant(
        self: *Body,
        target: mir.Register,
        row: Builder.Value,
    ) Error!void {
        if (!self.writable.mayBeConstant(target)) return;
        const flag = try self.rowLoad(
            .normal,
            .i8,
            try self.byteOffset(row, runtime.layout.constant, "constant.at"),
            Builder.Alignment.fromByteUnits(1),
            "constant",
        );
        try self.check(
            try self.wip.icmp(
                .ne,
                flag,
                try self.module.builder.intValue(.i8, 0),
                "immutable",
            ),
            .immutable_object,
        );
    }

    fn emitListAppend(
        self: *Body,
        target: mir.Register,
        held: mir.Register,
        shape: ElementShape,
    ) Error!void {
        const builder = self.module.builder;
        const one = try builder.intValue(.i64, 1);

        const row = try self.resolveRow(target);
        try self.checkNotConstant(target, row);
        const count_at = try self.byteOffset(row, runtime.layout.elements_count, "count.at");
        const count = try self.rowLoad(.normal, .i64, count_at, value_alignment, "count");
        const capacity = try self.rowLoad(
            .normal,
            .i64,
            try self.byteOffset(row, runtime.layout.elements_capacity, "capacity.at"),
            value_alignment,
            "capacity",
        );
        const next = try self.wip.bin(.@"add nuw", count, one, "count.next");
        const room = try self.wip.icmp(
            .ule,
            try self.wip.bin(
                .@"mul nuw",
                next,
                try builder.intValue(.i64, cellWidth(shape.element)),
                "room.wanted",
            ),
            capacity,
            "has.room",
        );

        const storing = try self.wip.block(1, "append.inline");
        const growing = try self.wip.block(1, "append.grow");
        const done = try self.wip.block(2, "append.done");
        _ = try self.wip.brCond(room, storing, growing, .then_likely);

        self.seek(storing);
        const elements = try self.rowLoad(
            .normal,
            .ptr,
            try self.byteOffset(row, runtime.layout.elements_pointer, "elements.at"),
            pointer_alignment,
            "elements",
        );
        try self.storeCell(
            shape.element,
            try self.wip.gep(
                .inbounds,
                self.cellType(shape.element),
                elements,
                &.{count},
                "element",
            ),
            self.produced[held].value,
        );
        try self.rowStore(next, count_at, value_alignment);
        _ = try self.wip.br(done);

        self.seek(growing);
        try self.callChecked(.luce_rt_append, &.{
            self.runtime,
            try self.boxedRegister(target, "target"),
            try self.storageOf(held),
        });
        _ = try self.wip.br(done);

        self.seek(done);
    }

    /// `a.dim(k)` on an array. The rank is a compile-time fact, so the
    /// axis check is against a constant.
    fn emitArrayDimSize(
        self: *Body,
        register: mir.Register,
        target: mir.Register,
        axis: mir.Register,
        shape: ElementShape,
    ) Error!void {
        const builder = self.module.builder;
        const view = try self.elementView(target, shape);
        const wanted = self.produced[axis].value;
        const below = try self.wip.icmp(.slt, wanted, try builder.intValue(.i64, 0), "below");
        const above = try self.wip.icmp(
            .sge,
            wanted,
            try builder.intValue(.i64, shape.rank),
            "above",
        );
        try self.check(try self.wip.bin(.@"or", below, above, "out.of.range"), .index_bounds);
        // A rank-1 array has one axis, and the check above has already
        // said the wanted one is it.
        if (shape.rank == 1) {
            self.produced[register].value = view.bounds(self)[0];
            return;
        }
        self.produced[register].value = try self.wip.load(
            .normal,
            .i64,
            try self.wip.gep(.inbounds, .i64, view.dims, &.{wanted}, "dim.at"),
            value_alignment,
            "dim",
        );
    }

    // -- Strings, without the runtime call --------------------------------
    //
    // A str already travels through generated code as an unboxed
    // `{ ptr, i64 }`, so `len`, `byte_at` and a slice are a compare and
    // a load — and boxing one to ask the runtime for it costs more than
    // the answer.  These are the same three checks `runtime/text.zig`
    // makes, in the same order, so the trap a bad index raises is the
    // same trap with the same words.

    /// Trap unless `index` falls between UTF-8 sequences: `index ==
    /// length`, or a byte that is not a continuation.
    /// `text.isStringBoundary`, inline — **including its
    /// short-circuit**, which is not decoration: the end of a str is
    /// a legal slice bound, and the byte there is one past the last,
    /// which is not ours to read.  So the load sits behind the branch,
    /// exactly as the `or` puts it behind one in Zig.
    fn checkBoundary(
        self: *Body,
        text: Builder.Value,
        length: Builder.Value,
        index: Builder.Value,
    ) Error!void {
        const builder = self.module.builder;
        const looking = try self.wip.block(1, "boundary");
        // Two ways on: the index was the end, or the byte there begins
        // a sequence.
        const settled = try self.wip.block(2, "on.boundary");
        _ = try self.wip.brCond(
            try self.wip.icmp(.eq, index, length, "at.end"),
            settled,
            looking,
            .none,
        );

        self.seek(looking);
        const byte = try self.wip.load(
            .normal,
            .i8,
            try self.wip.gep(.inbounds, .i8, text, &.{index}, "byte.at"),
            Builder.Alignment.fromByteUnits(1),
            "byte",
        );
        try self.check(try self.wip.icmp(
            .eq,
            try self.wip.bin(.@"and", byte, try builder.intValue(.i8, 0xc0), "top.bits"),
            try builder.intValue(.i8, @as(i8, @bitCast(@as(u8, 0x80)))),
            "continuation",
        ), .str_boundary);
        _ = try self.wip.br(settled);
        self.seek(settled);
    }

    /// `s.byte_at(i)` — one raw byte, below the UTF-8 layer on purpose.
    fn emitStringByte(
        self: *Body,
        register: mir.Register,
        text_register: mir.Register,
        index_register: mir.Register,
    ) Error!void {
        const builder = self.module.builder;
        const text, const length = try self.textParts(text_register, "text");
        const index = self.produced[index_register].value;
        const below = try self.wip.icmp(.slt, index, try builder.intValue(.i64, 0), "below");
        const above = try self.wip.icmp(.sge, index, length, "above");
        try self.check(
            try self.wip.bin(.@"or", below, above, "out.of.range"),
            .str_bounds,
        );
        // LLVM stores the byte in `i8`; the MIR type is `u8`. Any explicit
        // later conversion uses zero extension because these bits are a
        // magnitude (D4).
        self.produced[register].value = try self.wip.load(
            .normal,
            .i8,
            try self.wip.gep(.inbounds, .i8, text, &.{index}, "byte.at"),
            Builder.Alignment.fromByteUnits(1),
            "byte",
        );
    }

    /// `s[a:b]` — a borrow of the original bytes, checked twice: in
    /// range, and on a UTF-8 boundary at both ends.
    fn emitStringSlice(
        self: *Body,
        register: mir.Register,
        text_register: mir.Register,
        from: mir.Register,
        to: mir.Register,
    ) Error!void {
        const builder = self.module.builder;
        const text, const length = try self.textParts(text_register, "text");
        const first = self.produced[from].value;
        const end = self.produced[to].value;
        const below = try self.wip.icmp(.slt, first, try builder.intValue(.i64, 0), "below");
        const inverted = try self.wip.icmp(.slt, end, first, "inverted");
        const past = try self.wip.icmp(.sgt, end, length, "past.end");
        try self.check(try self.wip.bin(
            .@"or",
            below,
            try self.wip.bin(.@"or", inverted, past, "misordered"),
            "out.of.range",
        ), .str_bounds);
        try self.checkBoundary(text, length, first);
        try self.checkBoundary(text, length, end);
        self.produced[register].value = try self.wip.buildAggregate(self.module.string_type, &.{
            try self.wip.gep(.inbounds, .i8, text, &.{first}, "slice.at"),
            try self.wip.bin(.@"sub nsw", end, first, "slice.length"),
        }, "slice");
    }

    // -- the host table ------------------------------------------------
    //
    // Effects, and only effects, come through here.  Every service is
    // optional and a null slot traps `host_unavailable` rather than
    // touching anything (docs/V2.md's fail-closed rule), and every
    // service answers `abi.Answer`: a host that ran out of memory ends
    // the run `exhausted`, which is not a trap because nothing about
    // the program was wrong.

    const pointer_alignment = Builder.Alignment.fromByteUnits(8);

    fn loadSlot(self: *Body, slot: abi.Slot, name: []const u8) Error!Builder.Value {
        const address = try self.wip.gepStruct(
            self.module.host_type,
            self.host,
            @intFromEnum(slot),
            "slot",
        );
        return self.wip.load(.normal, .ptr, address, pointer_alignment, name);
    }

    /// The service in `slot`, or the `host_unavailable` trap that
    /// stands in for a host without it.
    fn requireSlot(self: *Body, slot: abi.Slot, name: []const u8) Error!Builder.Value {
        const service = try self.loadSlot(slot, name);
        const missing = try self.wip.icmp(
            .eq,
            service,
            try self.module.builder.nullValue(.ptr),
            "service.missing",
        );
        try self.check(missing, .host_unavailable);
        return service;
    }

    /// Call a host service and hand back what it answered, having
    /// already dealt with the one answer no caller handles itself.
    fn callHost(
        self: *Body,
        slot: abi.Slot,
        arguments: []const Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        try self.enterEffects();
        const answer = try self.invokeHost(slot, arguments, name);
        try self.leaveEffects();
        try self.checkExhausted(answer);
        try self.checkHostAnswer(answer);
        return answer;
    }

    /// The two halves of the effect lock, around one host service call
    /// (docs/THREADS.md D9).
    ///
    /// **Emitted only in a program that contains a `spawn`** — which is
    /// D11, kept structurally rather than measured: a spawn-free
    /// program's module has no `luce_rt_effects_enter` in it at all, so
    /// there is no lock to be cheap about and no branch to predict.
    /// The pair brackets the call and nothing else, which is what makes
    /// `print` from three workers line-atomic.
    ///
    /// The lock must be *left* on every path out, and there is only
    /// one: `invokeHost` emits a call and no branch, and everything
    /// that can unwind — the exhaustion check, the `no` handling —
    /// stands after the leave.
    fn enterEffects(self: *Body) Error!void {
        if (self.module.spawned.len == 0) return;
        _ = try self.callRuntime(.luce_rt_effects_enter, .void, &.{self.runtime}, "");
    }

    fn leaveEffects(self: *Body) Error!void {
        if (self.module.spawned.len == 0) return;
        _ = try self.callRuntime(.luce_rt_effects_leave, .void, &.{self.runtime}, "");
    }

    /// Call a host service that answers a plain number and cannot fail
    /// — a screen size, an argument count.
    fn callHostNumber(self: *Body, slot: abi.Slot, name: []const u8) Error!Builder.Value {
        try self.enterEffects();
        const answer = try self.invokeHost(slot, &.{}, name);
        try self.leaveEffects();
        return answer;
    }

    /// The same plain-number service with arguments — currently the
    /// terminal event-data query.  Unlike `callHost`, this callback does
    /// not return `abi.Answer`, so its result is already the number the
    /// program asked for.
    fn callHostNumberWith(
        self: *Body,
        slot: abi.Slot,
        arguments: []const Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        try self.enterEffects();
        const answer = try self.invokeHost(slot, arguments, name);
        try self.leaveEffects();
        return answer;
    }

    /// Call a host service that answers one fact about the machine:
    /// nothing to ask with, a number in an out-parameter, and an
    /// answer that may be `no`.
    ///
    /// `no` on these slots means *this host cannot tell*, so it
    /// refuses exactly as a withheld service does — `host_unavailable`
    /// at the call site, the same trap `requireSlot` raises one
    /// instruction earlier.  That is the whole reason the shape is not
    /// `callHostNumber`'s: the alternative is a host inventing a
    /// number for a machine it could not measure.
    fn callHostFact(self: *Body, slot: abi.Slot, name: []const u8) Error!Builder.Value {
        const answer_box = try self.scratch(.i64, value_alignment, name);
        const answer = try self.callHost(slot, &.{answer_box}, name);
        const untold = try self.wip.icmp(
            .ne,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.yes)),
            "fact.untold",
        );
        try self.check(untold, .host_unavailable);
        return self.wip.load(.normal, .i64, answer_box, value_alignment, name);
    }

    fn invokeHost(
        self: *Body,
        slot: abi.Slot,
        arguments: []const Builder.Value,
        name: []const u8,
    ) Error!Builder.Value {
        const gpa = self.module.gpa;
        const service = try self.requireSlot(slot, "service");
        var all: std.ArrayList(Builder.Value) = .empty;
        defer all.deinit(gpa);
        try all.append(gpa, try self.loadSlot(.context, "context"));
        try all.appendSlice(gpa, arguments);
        return self.wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            try self.module.hostType(slot),
            service,
            all.items,
            name,
        );
    }

    /// The host could not get memory: end the run `exhausted` rather
    /// than reporting a trap the program did not cause.
    fn checkExhausted(self: *Body, answer: Builder.Value) Error!void {
        const exhausted = try self.wip.icmp(
            .eq,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.exhausted)),
            "host.exhausted",
        );
        const giving_up = try self.wip.block(1, "exhausted");
        const surviving = try self.wip.block(1, "served");
        _ = try self.wip.brCond(exhausted, giving_up, surviving, .else_likely);
        self.seek(giving_up);
        _ = try self.callRuntime(.luce_rt_exhaust, .void, &.{self.runtime}, "");
        _ = try self.wip.ret(try self.module.builder.intValue(.i32, outcome_trapped));
        self.seek(surviving);
    }

    /// Validate the complete host answer protocol before any caller treats
    /// a nonzero answer as "yes".  `Answer` is a C enum, so an untrusted
    /// callback can physically return a value outside its declared set;
    /// accepting that value as success would make the generated code read
    /// uninitialized or null output buffers.  Exact `exhausted` was handled
    /// above; every remaining answer must be exactly `no` or `yes`.
    fn checkHostAnswer(self: *Body, answer: Builder.Value) Error!void {
        const not_no = try self.wip.icmp(
            .ne,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.no)),
            "host.not.no",
        );
        const not_yes = try self.wip.icmp(
            .ne,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.yes)),
            "host.not.yes",
        );
        try self.check(
            try self.wip.bin(.@"and", not_no, not_yes, "host.answer.invalid"),
            .host_unavailable,
        );
    }

    /// `file_read(path)` — the whole file as a `str`.
    ///
    /// Open-read-close over the byte channel plus `libluce_rt`'s own
    /// UTF-8 validation since version 12 (docs/BYTES.md R2), so this is
    /// one runtime call where it used to be a host call, a branch and
    /// an intern.  The box is filled here first and the runtime writes
    /// it only when the read landed: the `errored` beside this call
    /// branches away before anything reads the value, but the box is
    /// still copied into whatever carries it, so what it holds has to
    /// be a value and not whatever was on the stack.
    fn emitFileRead(self: *Body, register: mir.Register, path_register: mir.Register) Error!void {
        const path, const path_length = try self.textParts(path_register, "path");
        const box = try self.scratch(self.module.value_type, value_alignment, "read.box");
        try self.fillBoxShape(box, .str);
        try self.fillBoxValue(box, .str, (try self.module.textConstant("")).toValue());
        self.produced[register].outcome = try self.fileService(.luce_rt_file_read_text, &.{
            path,
            path_length,
            box,
        });
        self.produced[register].value = try self.unboxed(.str, box, "read.value");
        self.produced[register].box = box;
    }

    /// One `libluce_rt` file service: the arguments it takes, plus the
    /// "did the world agree" flag and the position the error is
    /// recorded at, which every one of them ends with.
    ///
    /// The runtime raises the `io_failed` itself — it is the side that
    /// knows the path a handle was opened at — so what comes back here
    /// is only the outcome the `errored` beside the call branches on.
    fn fileService(
        self: *Body,
        which: Service,
        arguments: []const Builder.Value,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        const word = Builder.Alignment.fromByteUnits(4);
        const gpa = self.module.gpa;
        const agreed = try self.scratch(.i32, word, "io.agreed");
        var all: std.ArrayList(Builder.Value) = .empty;
        defer all.deinit(gpa);
        try all.append(gpa, self.runtime);
        try all.appendSlice(gpa, arguments);
        try all.append(gpa, agreed);
        try all.append(gpa, try builder.intValue(.i32, self.index));
        try all.append(gpa, try builder.intValue(.i32, self.current));
        try self.callChecked(which, all.items);
        // `agreed` is 0 exactly when the runtime recorded an error, so
        // the outcome is the flag read the other way round.
        const said_no = try self.wip.icmp(
            .eq,
            try self.wip.load(.normal, .i32, agreed, word, "io.flag"),
            try builder.intValue(.i32, 0),
            "io.refused",
        );
        return self.wip.select(
            .normal,
            said_no,
            try builder.intValue(.i32, outcome_errored),
            try builder.intValue(.i32, outcome_ok),
            "io.outcome",
        );
    }

    /// One backend-neutral graphics service.  The runtime export receives
    /// its operation-specific arguments, then an `ok` flag and source site;
    /// a zero flag is an ordinary `io_failed` outcome, while a nonzero C
    /// return is a trap already reported by the runtime.
    fn graphicsService(
        self: *Body,
        which: Service,
        arguments: []const Builder.Value,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        const word = Builder.Alignment.fromByteUnits(4);
        const gpa = self.module.gpa;
        const agreed = try self.scratch(.i32, word, "graphics.ok");
        var all: std.ArrayList(Builder.Value) = .empty;
        defer all.deinit(gpa);
        try all.append(gpa, self.runtime);
        try all.appendSlice(gpa, arguments);
        try all.append(gpa, agreed);
        try all.append(gpa, try builder.intValue(.i32, self.index));
        try all.append(gpa, try builder.intValue(.i32, self.current));
        try self.callChecked(which, all.items);
        const refused = try self.wip.icmp(
            .eq,
            try self.wip.load(.normal, .i32, agreed, word, "graphics.flag"),
            try builder.intValue(.i32, 0),
            "graphics.refused",
        );
        return self.wip.select(
            .normal,
            refused,
            try builder.intValue(.i32, outcome_errored),
            try builder.intValue(.i32, outcome_ok),
            "graphics.outcome",
        );
    }

    /// `file_write(path, text)` and `file_append(path, text)`, which
    /// differ only in where the write starts — one `libluce_rt` door
    /// with the mode as an argument, since version 12 defined both as
    /// open-write-close over the byte channel (docs/BYTES.md R2).
    fn emitWriteText(
        self: *Body,
        register: mir.Register,
        of: []const mir.Register,
        mode: runtime.files.Mode,
    ) Error!void {
        const path, const path_length = try self.textParts(of[0], "path");
        const content, const content_length = try self.textParts(of[1], "content");
        self.produced[register].outcome = try self.fileService(.luce_rt_file_write_text, &.{
            path,
            path_length,
            content,
            content_length,
            try self.module.builder.intValue(.i64, @intFromEnum(mode)),
        });
    }

    /// A host file service said no: raise the error and answer the
    /// outcome the `errored` beside the call will branch on.  The
    /// words are built inside `libluce_rt`, so both engines report the
    /// same sentence about the same path (docs/FAILURE.md).
    fn raiseIo(
        self: *Body,
        act: mir.FileAct,
        answer: Builder.Value,
        path: Builder.Value,
        path_length: Builder.Value,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        const word = Builder.Alignment.fromByteUnits(4);
        const slot = try self.scratch(.i32, word, "io.outcome");
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_ok), slot, word);
        const raising = try self.wip.block(1, "io.failed");
        const served = try self.wip.block(2, "io.served");
        _ = try self.wip.brCond(try self.saidNo(answer), raising, served, .else_likely);

        self.seek(raising);
        try self.emitRaiseIo(act, path, path_length);
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_errored), slot, word);
        _ = try self.wip.br(served);

        self.seek(served);
        return self.wip.load(.normal, .i32, slot, word, "io.outcome");
    }

    /// The `io_failed` itself: the words are built inside `libluce_rt`
    /// from the verb and the path, so both engines report the same
    /// sentence about the same file (docs/FAILURE.md).
    fn emitRaiseIo(
        self: *Body,
        act: mir.FileAct,
        path: Builder.Value,
        path_length: Builder.Value,
    ) Error!void {
        const builder = self.module.builder;
        _ = try self.callRuntime(.luce_rt_raise_io, .void, &.{
            self.runtime,
            try builder.intValue(.i32, @intFromEnum(act)),
            path,
            path_length,
            try builder.intValue(.i32, self.index),
            try builder.intValue(.i32, self.current),
        }, "");
    }

    /// A host service that answers text it may not have: `read_line`
    /// at end of input, `env` for a variable nobody set.  Both take one
    /// str and hand back a `str?`.
    ///
    /// No branch: the answer becomes the `present` flag `luce_rt_maybe_text`
    /// reads, which parks `Value.none` in the box when the host said
    /// no.  That is the same value the interpreter parks there, so a
    /// `T?` means one thing on both engines — and the out-parameters
    /// are cleared first, because a host that answers no leaves them
    /// untouched and this side must not load what was on the stack.
    fn emitMaybeText(
        self: *Body,
        register: mir.Register,
        slot: abi.Slot,
        argument: mir.Register,
        name: []const u8,
    ) Error!void {
        const given, const given_length = try self.textParts(argument, name);
        const answered = try self.hostText(name);
        try answered.clear(self);
        const answer = try self.callHost(
            slot,
            &.{ given, given_length, answered.text, answered.length },
            name,
        );
        const present = try self.wip.cast(.zext, try self.saidYes(answer), .i32, "present");
        const bytes, const size = try answered.load(self);
        try self.callAnswering(register, .luce_rt_maybe_text, &.{
            self.runtime,
            present,
            bytes,
            size,
        });
    }

    /// `shell_run(command)` — the host returns captured text through an
    /// out-parameter. A command's exit status is part of that text; only
    /// failure to start the shell takes the error path.
    fn emitShellRun(self: *Body, register: mir.Register, command_register: mir.Register) Error!void {
        const command, const command_length = try self.textParts(command_register, "command");
        const output = try self.hostText("shell.output");
        try output.clear(self);
        const answer = try self.callHost(
            .shell_run,
            &.{ command, command_length, output.text, output.length },
            "shell",
        );

        const box = try self.scratch(self.module.value_type, value_alignment, "shell.box");
        const outcome_slot = try self.scratch(.i32, Builder.Alignment.fromByteUnits(4), "shell.outcome");
        const failing = try self.wip.block(1, "shell.failed");
        const running = try self.wip.block(1, "shell.ok");
        const done = try self.wip.block(2, "shell.done");
        _ = try self.wip.brCond(try self.saidNo(answer), failing, running, .else_likely);

        self.seek(failing);
        try self.emitRaiseIo(.run, command, command_length);
        _ = try self.wip.store(
            .normal,
            try self.module.builder.intValue(.i32, outcome_errored),
            outcome_slot,
            Builder.Alignment.fromByteUnits(4),
        );
        try self.fillBoxShape(box, .str);
        try self.fillBoxValue(box, .str, (try self.module.textConstant("")).toValue());
        _ = try self.wip.br(done);

        self.seek(running);
        const bytes, const size = try output.load(self);
        try self.callChecked(.luce_rt_intern_text, &.{
            self.runtime,
            bytes,
            size,
            box,
        });
        _ = try self.wip.store(
            .normal,
            try self.module.builder.intValue(.i32, outcome_ok),
            outcome_slot,
            Builder.Alignment.fromByteUnits(4),
        );
        _ = try self.wip.br(done);

        self.seek(done);
        self.produced[register].value = try self.unboxed(.str, box, "shell.value");
        self.produced[register].box = box;
        self.produced[register].outcome = try self.wip.load(
            .normal,
            .i32,
            outcome_slot,
            Builder.Alignment.fromByteUnits(4),
            "shell.outcome",
        );
    }

    /// `dir_list(path)` — the names the host joined, as the
    /// `list[str]` the program asked for.
    ///
    /// Two sides that do genuinely different things, like `file_read`:
    /// only the side the host said yes on has a buffer to split, and
    /// only the other one raises.  The list is an object, so the value
    /// the failing side parks is the null handle — nothing reads it,
    /// because the `errored` beside the call branches first, but a
    /// live row would be worse than a handle that traps.
    fn emitDirList(self: *Body, register: mir.Register, path_register: mir.Register) Error!void {
        const builder = self.module.builder;
        const flag = Builder.Alignment.fromByteUnits(4);
        const listed = self.function.result_types[register];
        const path, const path_length = try self.textParts(path_register, "path");
        const names = try self.hostText("names");
        try names.clear(self);
        const answer = try self.callHost(
            .dir_list,
            &.{ path, path_length, names.text, names.length },
            "listed",
        );

        const box = try self.scratch(self.module.value_type, value_alignment, "list.box");
        const outcome_slot = try self.scratch(.i32, flag, "list.outcome");
        const failing = try self.wip.block(1, "list.failed");
        const listing = try self.wip.block(1, "list.ok");
        const done = try self.wip.block(2, "list.done");
        _ = try self.wip.brCond(try self.saidNo(answer), failing, listing, .else_likely);

        self.seek(failing);
        try self.emitRaiseIo(.list, path, path_length);
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_errored), outcome_slot, flag);
        try self.fillBoxShape(box, listed);
        try self.fillBoxValue(box, listed, try self.zeroValue(listed));
        _ = try self.wip.br(done);

        self.seek(listing);
        const bytes, const size = try names.load(self);
        try self.callChecked(.luce_rt_names_list, &.{ self.runtime, bytes, size, box });
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_ok), outcome_slot, flag);
        _ = try self.wip.br(done);

        self.seek(done);
        self.produced[register].value = try self.unboxed(listed, box, "list.value");
        self.produced[register].box = box;
        self.produced[register].outcome = try self.wip.load(.normal, .i32, outcome_slot, flag, "list.outcome");
    }

    fn saidNo(self: *Body, answer: Builder.Value) Error!Builder.Value {
        return self.wip.icmp(
            .eq,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.no)),
            "said.no",
        );
    }

    fn saidYes(self: *Body, answer: Builder.Value) Error!Builder.Value {
        return self.wip.icmp(
            .ne,
            answer,
            try self.module.builder.intValue(.i32, @intFromEnum(abi.Answer.no)),
            "said.yes",
        );
    }

    /// The address and length of the str in `register`, as the two
    /// arguments a host service takes.
    fn textParts(
        self: *Body,
        register: mir.Register,
        name: []const u8,
    ) Error!struct { Builder.Value, Builder.Value } {
        const held = self.produced[register].value;
        return .{
            try self.wip.extractValue(held, &.{0}, name),
            try self.wip.extractValue(held, &.{1}, name),
        };
    }

    /// Somewhere for a host service to leave a string.  The bytes it
    /// writes here are borrowed for the duration of the call, so the
    /// caller copies them into the run's arena immediately
    /// (`luce_rt_intern_text`).
    const HostText = struct {
        text: Builder.Value,
        length: Builder.Value,

        fn load(self: HostText, body: *Body) Error!struct { Builder.Value, Builder.Value } {
            return .{
                try body.wip.load(.normal, .ptr, self.text, pointer_alignment, "host.text"),
                try body.wip.load(.normal, .i64, self.length, pointer_alignment, "host.length"),
            };
        }

        /// Empty, for a service whose `no` leaves these untouched and
        /// whose caller reads them anyway.  Two stores in front of a
        /// blocking call, and what they buy is that the load after it
        /// is never of whatever the stack happened to hold.
        fn clear(self: HostText, body: *Body) Error!void {
            const builder = body.module.builder;
            _ = try body.wip.store(
                .normal,
                try builder.nullValue(.ptr),
                self.text,
                pointer_alignment,
            );
            _ = try body.wip.store(
                .normal,
                try builder.intValue(.i64, 0),
                self.length,
                pointer_alignment,
            );
        }
    };

    fn hostText(self: *Body, name: []const u8) Error!HostText {
        return .{
            .text = try self.scratch(.ptr, pointer_alignment, name),
            .length = try self.scratch(.i64, pointer_alignment, name),
        };
    }

    // -- traps ---------------------------------------------------------

    /// Raise a trap and unwind: the current block ends with `ret i1
    /// true`, and every caller propagates.  The host is not told here
    /// — the trap waits in the runtime with its trace until the program
    /// has stopped (`runtime/trace.zig`).
    fn emitTrap(self: *Body, code: mir.TrapCode, message: Builder.Value) Error!void {
        const text = try self.wip.extractValue(message, &.{0}, "trap.text");
        const length = try self.wip.extractValue(message, &.{1}, "trap.length");
        _ = try self.callRuntime(.luce_rt_raise, .void, &.{
            self.runtime,
            try self.module.builder.intValue(.i32, @intFromEnum(code)),
            text,
            length,
        }, "");
        try self.leaveUnwinding();
    }

    /// Record this frame in the trap's call trace and hand the flag
    /// back to the caller.  Every exit on the unwinding path goes
    /// through here, so the trace is exactly the frames the trap passed
    /// through, innermost first — and nothing on the execution path
    /// touches any of it.
    fn leaveUnwinding(self: *Body) Error!void {
        _ = try self.callRuntime(.luce_rt_unwound, .void, &.{
            self.runtime,
            try self.module.builder.intValue(.i32, self.index),
            try self.module.builder.intValue(.i32, self.current),
        }, "");
        _ = try self.wip.ret(try self.module.builder.intValue(.i32, outcome_trapped));
    }

    /// Leave errored: the same edge, and deliberately *without* the
    /// frame.  An error records where it was raised and nothing else,
    /// because a return trace costs a hidden parameter, stack in the
    /// first fallible frame, and a save/restore protocol on the
    /// success path — a price on code that never fails, which
    /// docs/MODES.md forbids (docs/FAILURE.md).
    ///
    /// **`%out` is emptied on the way, and that is part of the
    /// convention.**  A caller carries a fallible call's result across
    /// the branch on its outcome, and the store that carries it stands
    /// *before* the branch — so it runs on this path too, and would
    /// otherwise copy whatever the slot happened to hold.  Emptying
    /// here rather than initializing at the call site puts the whole
    /// cost on the path that already failed: the interpreter's answer
    /// is the same, because a destination register it never wrote is
    /// still the `.none` its frame started at.
    fn leaveErrored(self: *Body) Error!void {
        if (self.result_slot != .none) {
            _ = try self.wip.store(
                .normal,
                try self.emptyValue(self.function.return_type),
                self.result_slot,
                Module.valueAlignment(self.function.return_type),
            );
        }
        _ = try self.wip.ret(try self.module.builder.intValue(.i32, outcome_errored));
    }

    /// The trap the interpreter raises for `code`, with its standard
    /// message — the two engines must report the same words.
    fn emitCodeTrap(self: *Body, code: mir.TrapCode) Error!void {
        return self.emitTrap(code, (try self.module.textConstant(code.message())).toValue());
    }

    /// `if (condition) trap(code)`.  Lowering continues in a fresh
    /// block, so callers keep emitting straight-line code.
    fn check(self: *Body, condition: Builder.Value, code: mir.TrapCode) Error!void {
        const trapping = try self.wip.block(1, "trap");
        const surviving = try self.wip.block(1, "ok");
        _ = try self.wip.brCond(condition, trapping, surviving, .else_likely);
        self.seek(trapping);
        try self.emitCodeTrap(code);
        self.seek(surviving);
    }

    // -- instructions --------------------------------------------------

    fn emitInstruction(self: *Body, register: mir.Register, instruction: mir.Instruction) Error!void {
        // Where a trap raised while lowering this instruction says it
        // happened.  Written once per instruction at compile time; the
        // running program never reads it (`runtime/trace.zig`).
        self.current = register;
        switch (instruction) {
            .const_boolean => |value| {
                self.produced[register].value = if (value) .true else .false;
            },
            // A numeric constant travels at the widest member of its
            // family and lands at the register's own width; the
            // verifier has already checked the value is exact there
            // (docs/TYPES.md §1).
            .const_integer => |value| {
                self.produced[register].value = try self.module.builder.intValue(
                    try self.module.valueType(self.function.result_types[register]),
                    value,
                );
            },
            .const_float => |value| {
                self.produced[register].value = switch (self.function.result_types[register]) {
                    .f16 => try self.module.builder.halfValue(@floatCast(value)),
                    .f32 => try self.module.builder.floatValue(@floatCast(value)),
                    else => try self.module.builder.doubleValue(value),
                };
            },
            .const_str => |constant| {
                const text = self.module.program.constants[constant];
                self.produced[register].value = (try self.module.textConstant(text)).toValue();
            },
            // A constant-container instruction is only a borrowed load
            // from this runtime's program-root table.  The prologue
            // materialized the row before any Luce instruction ran,
            // and MIR verification proved both the slot and its heap
            // type, so this operation cannot trap.
            .const_container => |constant| {
                const out = try self.scratch(
                    self.module.value_type,
                    value_alignment,
                    "constant.out",
                );
                _ = try self.callRuntime(.luce_rt_constant_load, .void, &.{
                    self.runtime,
                    try self.module.builder.intValue(.i32, constant),
                    out,
                }, "");
                self.produced[register].value = try self.unboxed(
                    self.function.result_types[register],
                    out,
                    "constant.handle",
                );
                self.produced[register].box = out;
            },
            .const_function => |named| try self.emitConstFunction(register, named),
            .call_indirect => |called| try self.emitIndirectCall(register, called),
            .local_get => |local| {
                const held = self.function.locals[local];
                const slot = self.local_slots[local];
                if (held.owns_storage or held.boxed_storage) {
                    self.produced[register].value = try self.unboxed(
                        held.local_type,
                        slot,
                        "local.get",
                    );
                    self.produced[register].box = slot;
                    return;
                }
                self.produced[register].value = try self.wip.load(
                    .normal,
                    try self.module.valueType(held.local_type),
                    slot,
                    Module.valueAlignment(held.local_type),
                    "local.get",
                );
            },
            .local_set => |set| try self.emitLocalSet(set.local, set.value),
            .weak_local_get => |local| try self.callAnswering(register, .luce_rt_weak_load, &.{
                self.runtime,
                self.local_slots[local],
            }),
            .weak_local_set => |set| try self.emitWeakStore(
                self.local_slots[set.local],
                set.value,
            ),
            .binary => |operation| try self.emitBinary(register, operation),
            .unary => |operation| try self.emitUnary(register, operation),
            .convert => |operand| try self.emitConvert(register, operand),
            .interface_make => |make| try self.emitInterfaceMake(register, make),
            .struct_make => |make| try self.emitStructMake(register, make.layout, make.fields),
            .struct_get => |get| {
                const layout = self.module.program.structs[get.layout];
                if (layout.reference) {
                    try self.callAnswering(register, .luce_rt_class_get, &.{
                        self.runtime,
                        try self.boxedRegister(get.target, "class"),
                        try self.module.builder.intValue(.i64, get.layout),
                        try self.module.builder.intValue(.i64, get.field),
                    });
                    return;
                }
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    self.produced[get.target].value,
                    &.{try self.module.builder.intValue(.i64, get.field)},
                    "field.at",
                );
                self.produced[register].value = try self.unboxed(
                    layout.fields[get.field].field_type,
                    address,
                    "field",
                );
                self.produced[register].box = address;
            },
            .weak_struct_get => |get| {
                if (self.module.program.structs[get.layout].reference) {
                    const weak = try self.scratch(self.module.value_type, value_alignment, "weak.class.field");
                    try self.callChecked(.luce_rt_class_get, &.{
                        self.runtime,
                        try self.boxedRegister(get.target, "class"),
                        try self.module.builder.intValue(.i64, get.layout),
                        try self.module.builder.intValue(.i64, get.field),
                        weak,
                    });
                    try self.callAnswering(register, .luce_rt_weak_load, &.{ self.runtime, weak });
                    return;
                }
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    self.produced[get.target].value,
                    &.{try self.module.builder.intValue(.i64, get.field)},
                    "weak.field.at",
                );
                try self.callAnswering(register, .luce_rt_weak_load, &.{ self.runtime, address });
            },
            .variant_make => |make| try self.emitVariantMake(
                register,
                make.variant,
                make.member,
                make.fields,
            ),
            // The tag is slot 0 of the run, read the way `struct_get`
            // reads a `i64` field (docs/UNION.md D8).
            .variant_tag => |tag| {
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    self.produced[tag.target].value,
                    &.{try self.module.builder.intValue(.i64, 0)},
                    "tag.at",
                );
                self.produced[register].value = try self.unboxed(.i64, address, "tag");
                self.produced[register].box = address;
            },
            // A payload field is slot `1 + field`, read exactly as
            // `struct_get` reads one — the verifier has already proven
            // the member and the field against `Program.variants`.
            .variant_field => |get| {
                const member = self.module.program.variants[get.variant].members[get.member];
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    self.produced[get.target].value,
                    &.{try self.module.builder.intValue(.i64, 1 + get.field)},
                    "payload.at",
                );
                self.produced[register].value = try self.unboxed(
                    member.fields[get.field].field_type,
                    address,
                    "payload",
                );
                self.produced[register].box = address;
            },
            .struct_set => |set| if (self.module.program.structs[set.layout].reference) {
                try self.callChecked(.luce_rt_class_set, &.{
                    self.runtime,
                    try self.boxedRegister(set.target, "class"),
                    try self.module.builder.intValue(.i64, set.layout),
                    try self.module.builder.intValue(.i64, set.field),
                    try self.storageOf(set.value),
                });
            } else try self.callAnswering(register, .luce_rt_struct_set, &.{
                self.runtime,
                try self.boxedRegister(set.target, "target"),
                try self.module.builder.intValue(.i64, set.field),
                try self.storageOf(set.value),
            }),
            .weak_struct_set => |set| {
                const weak = try self.scratch(self.module.value_type, value_alignment, "weak.field");
                try self.emitWeakStore(weak, set.value);
                if (self.module.program.structs[set.layout].reference) {
                    try self.callChecked(.luce_rt_class_set, &.{
                        self.runtime,
                        try self.boxedRegister(set.target, "class"),
                        try self.module.builder.intValue(.i64, set.layout),
                        try self.module.builder.intValue(.i64, set.field),
                        weak,
                    });
                } else {
                    try self.callAnswering(register, .luce_rt_struct_set, &.{
                        self.runtime,
                        try self.boxedRegister(set.target, "target"),
                        try self.module.builder.intValue(.i64, set.field),
                        weak,
                    });
                }
            },
            .call => |called| try self.emitCall(register, called),
            .call_inout => |called| try self.emitInoutCall(register, called),
            .interface_call => |called| try self.emitInterfaceCall(
                register,
                called.layout,
                called.method,
                called.arguments,
                called.fallible,
                self.produced[called.receiver].value,
            ),
            .interface_call_inout => |called| try self.emitInterfaceCall(
                register,
                called.layout,
                called.method,
                called.arguments,
                called.fallible,
                try self.unboxed(
                    .{ .strukt = called.layout },
                    self.local_slots[called.receiver],
                    "interface.inout",
                ),
            ),
            .spawn => |called| try self.emitSpawn(register, called),
            .intrinsic => |called| try self.emitIntrinsic(register, called),
            .heap_new => |new| try self.emitHeapNew(register, new),
            .jump => |target| {
                _ = try self.wip.br(self.blocks[target]);
            },
            .branch => |taken| {
                _ = try self.wip.brCond(
                    self.produced[taken.condition].value,
                    self.blocks[taken.then_block],
                    self.blocks[taken.else_block],
                    .none,
                );
            },
            .ret => |value| {
                if (value) |returned| {
                    _ = try self.wip.store(
                        .normal,
                        self.produced[returned].value,
                        self.result_slot,
                        Module.valueAlignment(self.function.return_type),
                    );
                }
                _ = try self.wip.ret(try self.module.builder.intValue(.i32, outcome_ok));
            },
            .trap => |code| try self.emitCodeTrap(code),
            .unwind => try self.leaveErrored(),
        }
    }

    /// Store a register into a local's slot.
    ///
    /// A slot that owns its storage holds a whole `runtime.Value`, and
    /// a str's form has to survive the store: if the register was
    /// read out of a box, the twenty-four bytes are copied across
    /// whole, so short text stays short and long text keeps pointing
    /// where it did.  A register with no box behind it is outside text
    /// by construction — a constant, a parameter, a slice, a callee's
    /// result — and is boxed the ordinary way (docs/STRINGS.md).
    fn emitLocalSet(self: *Body, local: mir.LocalId, value: mir.Register) Error!void {
        const held = self.function.locals[local];
        const slot = self.local_slots[local];
        if (!held.owns_storage and !held.boxed_storage) {
            _ = try self.wip.store(
                .normal,
                self.produced[value].value,
                slot,
                Module.valueAlignment(held.local_type),
            );
            return;
        }
        if (self.produced[value].box != .none) {
            _ = try self.wip.callMemCpy(
                slot,
                value_alignment,
                self.produced[value].box,
                value_alignment,
                try self.module.builder.intValue(.i64, @sizeOf(runtime.Value)),
                .normal,
                true,
            );
            return;
        }
        // The shape goes here, not in the entry block: an earlier store
        // may have left this slot holding inline text, and the form
        // byte has to say otherwise before the words are written.
        try self.fillBoxShape(slot, held.local_type);
        try self.fillBoxValue(slot, held.local_type, self.produced[value].value);
    }

    fn emitWeakStore(self: *Body, destination: Builder.Value, value: mir.Register) Error!void {
        try self.callChecked(.luce_rt_weak_store, &.{
            self.runtime,
            try self.boxedRegister(value, "weak.source"),
            destination,
        });
    }

    // -- conversion and struct values ----------------------------------

    /// Every numeric conversion, from the operand's type to the
    /// register's — the instruction carries no kind, because both ends
    /// are already written down (docs/TYPES.md §3).
    ///
    /// Four families, and two of them can stop the program:
    ///
    ///   * **to a float** — `sitofp` from an integer, `fpext` or
    ///     `fptrunc` between the float widths.  Never traps; a
    ///     `fptrunc` that overflows answers `inf`, because `/` is
    ///     already IEEE without traps.
    ///   * **to an integer, from a float** — truncates toward zero and
    ///     traps outside the target's range, NaN and the infinities
    ///     included.  The guard runs after `llvm.trunc`, so values such
    ///     as `-0.9` become the representable integer zero while a value
    ///     whose truncated result lies outside the destination is
    ///     refused rather than wrapped.
    ///   * **integer to integer** — range-check when the destination
    ///     cannot hold the source's whole range, then use the one
    ///     sign/zero extension or truncation the two explicit widths
    ///     require. Equal-width signedness changes need no LLVM cast:
    ///     integer types are signless in IR, but still need the range
    ///     check promised by the language.
    fn emitConvert(
        self: *Body,
        register: mir.Register,
        operand: mir.Register,
    ) Error!void {
        // **An enum converts as the integer it is stored at**
        // (docs/ENUMS.md D4): `i32(m)` reads the member's number, and
        // from here on there is nothing enum-shaped left to know — a
        // conversion out of one is the conversion out of its width,
        // range check and all.  It is the only direction: nothing
        // converts *to* an enum, because `Method(n)` answers `Method?`
        // and is a compare-and-branch tree in stage 4.
        const from = self.function.result_types[operand].storage();
        const to = self.function.result_types[register];
        const held = self.produced[operand].value;
        const target = try self.module.valueType(to);

        // `i32(m)` at an `i32` backing is the identity on the bits: the
        // whole content of the conversion is the type it lands in.
        if (from.eql(to)) {
            self.produced[register].value = held;
            return;
        }

        if (to == .char) {
            try self.checkUnicodeScalar(held, from);
            self.produced[register].value = if (from.numericBits() > 32)
                try self.wip.cast(.trunc, held, target, "char")
            else if (from.numericBits() < 32)
                try self.wip.cast(if (from.isUnsigned()) .zext else .sext, held, target, "char")
            else
                held;
            return;
        }
        if (from == .char) {
            std.debug.assert(to == .u32);
            self.produced[register].value = held;
            return;
        }

        if (to.isFloating()) {
            self.produced[register].value = if (from.isInteger())
                // A `u8`'s bits are a magnitude and every other
                // integer's carry a sign (D4), which is the whole of
                // what "unsigned" decides here.
                try self.wip.cast(
                    if (from.isUnsigned()) .uitofp else .sitofp,
                    held,
                    target,
                    "float",
                )
            else if (to.numericBits() > from.numericBits())
                try self.wip.cast(.fpext, held, target, "float")
            else
                // One `fptrunc`, so `f16(x)` from a `f64` rounds
                // once rather than twice through binary32 (§7).
                try self.wip.cast(.fptrunc, held, target, "float");
            return;
        }

        if (from.isInteger()) {
            try self.checkIntegerRange(held, from, to);
            self.produced[register].value = if (to.numericBits() < from.numericBits())
                try self.wip.cast(.trunc, held, target, "int")
            else if (to.numericBits() > from.numericBits())
                try self.wip.cast(if (from.isUnsigned()) .zext else .sext, held, target, "int")
            else
                held;
            return;
        }

        const source = try self.module.valueType(from);
        const truncated = try self.wip.callIntrinsic(
            .normal,
            .none,
            .trunc,
            &.{source},
            &.{held},
            "truncated",
        );
        try self.checkFloatRange(truncated, from, to);
        self.produced[register].value = try self.wip.cast(
            if (to.isUnsigned()) .fptoui else .fptosi,
            truncated,
            target,
            "int",
        );
    }

    /// Refuse every integer that is not a Unicode scalar before it is
    /// narrowed to the 32-bit `char` representation.  The check is made
    /// at the source width, so `char(u64.max)` cannot become `0xffffffff`
    /// first and accidentally pass a smaller comparison.
    fn checkUnicodeScalar(self: *Body, held: Builder.Value, from: types.Type) Error!void {
        std.debug.assert(from.isInteger());
        const llvm_type = try self.module.valueType(from);
        const range = from.integerRange();
        var invalid: Builder.Value = .false;

        if (range.low < 0) {
            invalid = try self.wip.icmp(
                .slt,
                held,
                try self.module.builder.intValue(llvm_type, 0),
                "char.negative",
            );
        }
        if (range.high > 0x10ffff) {
            const above = try self.wip.icmp(
                if (from.isUnsigned()) .ugt else .sgt,
                held,
                try self.module.builder.intValue(llvm_type, 0x10ffff),
                "char.above.maximum",
            );
            invalid = if (invalid == .false)
                above
            else
                try self.wip.bin(.@"or", invalid, above, "char.outside.range");
        }
        if (range.high >= 0xd800) {
            const at_or_above_surrogate = try self.wip.icmp(
                if (from.isUnsigned()) .uge else .sge,
                held,
                try self.module.builder.intValue(llvm_type, 0xd800),
                "char.surrogate.start",
            );
            const at_or_below_surrogate = try self.wip.icmp(
                if (from.isUnsigned()) .ule else .sle,
                held,
                try self.module.builder.intValue(llvm_type, 0xdfff),
                "char.surrogate.end",
            );
            const surrogate = try self.wip.bin(
                .@"and",
                at_or_above_surrogate,
                at_or_below_surrogate,
                "char.is.surrogate",
            );
            invalid = if (invalid == .false)
                surrogate
            else
                try self.wip.bin(.@"or", invalid, surrogate, "char.invalid");
        }
        try self.check(invalid, .bad_codepoint);
    }

    /// The bounds of `to`, tested on a float that has already been
    /// rounded.  NaN compares unordered with itself and with the
    /// bounds, so it is asked about separately.
    ///
    /// The upper bound is one past the top and tested with `>=`,
    /// because 2^63 and 2^31 are both exactly representable in either
    /// float width while `maxInt` itself is not.
    fn checkFloatRange(self: *Body, rounded: Builder.Value, from: types.Type, to: types.Type) Error!void {
        const bounds = to.integerRange();
        const lowest: f64 = @floatFromInt(bounds.low);
        const past_top: f64 = @floatFromInt(bounds.high + 1);
        const not_a_number = try self.wip.fcmp(.normal, .uno, rounded, rounded, "is.nan");
        // **The bound may not be finite at the source's width.**  A
        // `f16` tops out at 65504, so `i32`'s and `i64`'s bounds
        // both become infinities in binary16 — and there the test has
        // to include the bound rather than exclude it, because the
        // value it is catching *is* that infinity.  The upper test
        // needs no such care: it already includes its bound.
        const floor_is_finite = std.math.isFinite(self.narrowedBound(from, lowest));
        const too_small = try self.wip.fcmp(
            .normal,
            if (floor_is_finite) .olt else .ole,
            rounded,
            try self.floatConstant(from, lowest),
            "too.small",
        );
        const too_large = try self.wip.fcmp(
            .normal,
            .oge,
            rounded,
            try self.floatConstant(from, past_top),
            "too.large",
        );
        const outside = try self.wip.bin(
            .@"or",
            not_a_number,
            try self.wip.bin(.@"or", too_small, too_large, "off.scale"),
            "unrepresentable",
        );
        try self.check(outside, .conversion_range);
    }

    /// What a bound becomes at the source float's own width, which is
    /// where the comparison happens.  `f16` is the width that cannot
    /// hold every bound, and this is what says so.
    fn narrowedBound(_: *Body, from: types.Type, held: f64) f64 {
        return switch (from) {
            .f16 => @as(f16, @floatCast(held)),
            .f32 => @as(f32, @floatCast(held)),
            .f64 => held,
            else => unreachable, // asked only of a float source
        };
    }

    /// The destination bounds that can exclude a source value, tested
    /// at the source's width.  Only a bound inside the source range is
    /// materialized: for example, converting `u64` to `i64` needs the
    /// upper check but cannot even spell `i64.min` as an unsigned LLVM
    /// constant.  Signedness controls the comparison, not the bits.
    fn checkIntegerRange(self: *Body, held: Builder.Value, from: types.Type, to: types.Type) Error!void {
        const wide = try self.module.valueType(from);
        const source = from.integerRange();
        const target = to.integerRange();
        if (target.low <= source.low and target.high >= source.high) return;
        var outside: Builder.Value = .false;
        if (target.low > source.low) {
            outside = try self.wip.icmp(
                if (from.isUnsigned()) .ult else .slt,
                held,
                try self.module.builder.intValue(wide, target.low),
                "too.small",
            );
        }
        if (target.high < source.high) {
            const too_large = try self.wip.icmp(
                if (from.isUnsigned()) .ugt else .sgt,
                held,
                try self.module.builder.intValue(wide, target.high),
                "too.large",
            );
            outside = if (outside == .false)
                too_large
            else
                try self.wip.bin(.@"or", outside, too_large, "unrepresentable");
        }
        try self.check(outside, .conversion_range);
    }

    /// A constant of the float width `of` names.
    fn floatConstant(self: *Body, of: types.Type, held: f64) Error!Builder.Value {
        const builder = self.module.builder;
        return switch (of) {
            .f16 => builder.halfValue(@floatCast(held)),
            .f32 => builder.floatValue(@floatCast(held)),
            else => builder.doubleValue(held),
        };
    }

    /// `Point(x = 1, y = 2)`: gather the fields into a scratch run of
    /// `Value`s and let the runtime move them into storage that
    /// outlives the frame.  Each field is a store, so it arrives in the
    /// form its place has to keep (docs/STRINGS.md).
    fn emitStructMake(
        self: *Body,
        register: mir.Register,
        layout: u32,
        fields: []const mir.Register,
    ) Error!void {
        const shape = self.module.program.structs[layout];
        const run = try self.scratchRun(
            self.module.value_type,
            shape.fields.len,
            value_alignment,
            "fields",
        );
        for (fields, 0..) |field, index| {
            if (shape.fields[index].weak) {
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    run,
                    &.{try self.module.builder.intValue(.i64, index)},
                    "weak.field",
                );
                try self.emitWeakStore(address, field);
            } else {
                try self.storedAt(run, index, field);
            }
        }
        if (shape.reference) {
            try self.callAnswering(register, .luce_rt_class_make, &.{
                self.runtime,
                try self.module.builder.intValue(.i64, layout),
                try self.module.builder.intValue(
                    .i64,
                    if (shape.deinitializer) |function| @as(i64, @intCast(function)) else -1,
                ),
                run,
                try self.module.builder.intValue(.i64, shape.fields.len),
            });
        } else {
            try self.callAnswering(register, .luce_rt_struct_make, &.{
                self.runtime,
                run,
                try self.module.builder.intValue(.i64, shape.fields.len),
            });
        }
    }

    /// A union value is built by the struct path with one more slot in
    /// front (docs/UNION.md D8): slot 0 is the member index as a boxed
    /// `i64`, the member's payload fields follow, and the tail is
    /// `none` padding up to the union's one static run length — so a
    /// value's box can be re-derived from its type alone, exactly as a
    /// struct's is (`types.VariantType.runLength`).
    fn emitVariantMake(
        self: *Body,
        register: mir.Register,
        variant: u32,
        member: u32,
        fields: []const mir.Register,
    ) Error!void {
        const declared = self.module.program.variants[variant];
        const span = declared.runLength();
        const run = try self.scratchRun(
            self.module.value_type,
            span,
            value_alignment,
            "variant",
        );
        try self.boxAt(run, 0, .i64, try self.module.builder.intValue(.i64, member));
        for (fields, 0..) |field, index| {
            try self.storedAt(run, 1 + index, field);
        }
        for (1 + fields.len..span) |index| {
            try self.noneAt(run, index);
        }
        try self.callAnswering(register, .luce_rt_struct_make, &.{
            self.runtime,
            run,
            try self.module.builder.intValue(.i64, span),
        });
    }

    // -- arithmetic and comparison -------------------------------------

    fn emitBinary(self: *Body, register: mir.Register, operation: mir.Instruction.Binary) Error!void {
        const left = self.produced[operation.left].value;
        const right = self.produced[operation.right].value;
        if (operation.op.isComparison()) {
            self.produced[register].value = try self.emitCompare(operation, left, right);
            return;
        }
        switch (operation.operand_type) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => self.produced[register].value = try self.emitIntArithmetic(
                operation.op,
                operation.operand_type,
                left,
                right,
            ),
            .f16, .f32, .f64 => self.produced[register].value = try self.emitFloatArithmetic(
                operation.op,
                operation.operand_type,
                left,
                right,
            ),
            // The analyzer only admits + for strings, and the joined
            // bytes come from the runtime's arena.
            .str, .bytes => try self.callAnswering(register, .luce_rt_concat, &.{
                self.runtime,
                try self.boxedRegister(operation.left, "left"),
                try self.boxedRegister(operation.right, "right"),
            }),
            .none,
            .boolean,
            .char,
            .strukt,
            // A union is compared by match and nothing else
            // (docs/UNION.md D16): the analyzer refuses every operator
            // on one.
            .variant,
            .heap,
            // An enum is a set of names (docs/ENUMS.md D6): the
            // analyzer refuses `m + 1` and the verifier refuses the IR
            // that would say it.
            .enumeration,
            // A function value is a name for a function and nothing a
            // program may operate on (docs/FUNCTIONS.md D3): both
            // arithmetic and comparison are refused before lowering.
            .function,
            .optional,
            => return self.fail("arithmetic on a type that has none"),
        }
    }

    fn emitIntArithmetic(
        self: *Body,
        operation: mir.BinaryOp,
        of: types.Type,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const width = try self.module.valueType(of);
        const unsigned = of.isUnsigned();
        switch (operation) {
            .add => return self.emitChecked(if (unsigned) .@"uadd.with.overflow" else .@"sadd.with.overflow", width, left, right),
            .subtract => return self.emitChecked(if (unsigned) .@"usub.with.overflow" else .@"ssub.with.overflow", width, left, right),
            .multiply => return self.emitChecked(if (unsigned) .@"umul.with.overflow" else .@"smul.with.overflow", width, left, right),
            // The bit set moves bits and never checks anything but a
            // shift's count (docs/BITWISE.md R2): the trap fires
            // first, so `shl`/`ashr` only ever see a legal count and
            // no poison is manufactured.
            .bit_and => return self.wip.bin(.@"and", left, right, "bits"),
            .bit_or => return self.wip.bin(.@"or", left, right, "bits"),
            .bit_xor => return self.wip.bin(.xor, left, right, "bits"),
            .shift_left, .shift_right => {
                const builder = self.module.builder;
                const bits: i128 = of.numericBits();
                const above = try self.wip.icmp(
                    if (unsigned) .uge else .sge,
                    right,
                    try builder.intValue(width, bits),
                    "count.above",
                );
                if (unsigned) {
                    try self.check(above, .shift_out_of_range);
                } else {
                    const below = try self.wip.icmp(
                        .slt,
                        right,
                        try builder.intValue(width, 0),
                        "count.below",
                    );
                    try self.check(
                        try self.wip.bin(.@"or", below, above, "count.bad"),
                        .shift_out_of_range,
                    );
                }
                const shifted = try self.wip.bin(
                    if (operation == .shift_left) .shl else if (unsigned) .lshr else .ashr,
                    left,
                    right,
                    "bits",
                );
                if (operation == .shift_left) {
                    const restored = try self.wip.bin(if (unsigned) .lshr else .ashr, shifted, right, "restored");
                    try self.check(try self.wip.icmp(.ne, restored, left, "overflowed"), .integer_overflow);
                }
                return shifted;
            },
            // `/` is real division and always answers a float, so an
            // integer one is IR the verifier already refused
            // (docs/NUMERICS.md §2).
            .divide => return self.fail("integer division, which the language does not have"),
            // `//` and `%` floor together (docs/NUMERICS.md §3).  The
            // chip only offers the truncating pair, so each gets the
            // one correction that turns it into the flooring one, and
            // both corrections fire on the same condition: the true
            // quotient was negative and did not divide evenly.
            .floor_divide, .modulo => {
                try self.checkDivisor(of, left, right);
                if (unsigned) return self.wip.bin(
                    if (operation == .floor_divide) .udiv else .urem,
                    left,
                    right,
                    "int",
                );
                const truncated = try self.wip.bin(
                    if (operation == .floor_divide) .sdiv else .srem,
                    left,
                    right,
                    "int",
                );
                const remainder = if (operation == .modulo)
                    truncated
                else
                    try self.wip.bin(.srem, left, right, "rem");
                return self.correctToFloor(operation, width, truncated, remainder, right);
            },
            .equal,
            .not_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            => return self.fail("a comparison on the arithmetic path"),
        }
    }

    /// Turn a truncating quotient or remainder into the flooring one.
    ///
    /// The two differ exactly when the remainder is non-zero and its
    /// sign disagrees with the divisor's — which is to say when the
    /// true quotient was negative and did not come out even.  There
    /// the quotient is one *lower* than truncation gave (truncation
    /// rounds toward zero, flooring away from it) and the remainder is
    /// one divisor *higher*.
    ///
    /// It is branchless: two comparisons, an `and`, and a `select`.
    /// LLVM recognises the shape and folds it to a mask for a constant
    /// power-of-two divisor, which is why `x % 256` is `x & 255` here
    /// for every `x`, negative ones included — the thing C's remainder
    /// cannot do without a sign fixup.
    fn correctToFloor(
        self: *Body,
        operation: mir.BinaryOp,
        width: Builder.Type,
        truncated: Builder.Value,
        remainder: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        const zero = try builder.intValue(width, 0);
        const uneven = try self.wip.icmp(.ne, remainder, zero, "uneven");
        // `(a ^ b) < 0` is "the signs disagree", in one instruction
        // and without the two comparisons the words would take.
        const signs = try self.wip.bin(.xor, remainder, right, "signs");
        const opposed = try self.wip.icmp(.slt, signs, zero, "opposed");
        const needs = try self.wip.bin(.@"and", uneven, opposed, "needs.floor");
        // Plain `sub`/`add`, with no `nsw`: both arms of a `select`
        // are computed, and the discarded one must be a defined value
        // rather than poison.  Neither can wrap where it is chosen.
        const corrected = if (operation == .floor_divide)
            try self.wip.bin(.sub, truncated, try builder.intValue(width, 1), "floored")
        else
            try self.wip.bin(.add, remainder, right, "modded");
        return self.wip.select(.normal, needs, corrected, truncated, "int");
    }

    /// Arithmetic on doubles is plain IEEE 754 and never traps:
    /// division by zero and overflow produce infinities and NaN,
    /// exactly as they do in the interpreter.
    ///
    /// Two of the six are not one instruction.  `%` is the **floor**
    /// modulus, pairing with `//` under the same rule used for integers
    /// (docs/NUMERICS.md §3), and it is neither `frem`
    /// nor any host `fmod`: it goes to `libluce_rt`, so there is one
    /// implementation of a rule with a zero case and a sign
    /// correction in it.  `//` is `floor(a / b)` and that really is
    /// two instructions, so it stays here.
    fn emitFloatArithmetic(
        self: *Body,
        operation: mir.BinaryOp,
        of: types.Type,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const width = try self.module.valueType(of);
        switch (operation) {
            .modulo => {
                if (of == .f16) {
                    const wide_left = try self.wip.cast(.fpext, left, .float, "left.f32");
                    const wide_right = try self.wip.cast(.fpext, right, .float, "right.f32");
                    const wide = try self.callRuntime(
                        .luce_rt_float32_mod,
                        .float,
                        &.{ wide_left, wide_right },
                        "float",
                    );
                    return self.wip.cast(.fptrunc, wide, .half, "float.f16");
                }
                return self.callRuntime(
                    if (of == .f32) .luce_rt_float32_mod else .luce_rt_float_mod,
                    width,
                    &.{ left, right },
                    "float",
                );
            },
            .floor_divide => {
                const quotient = try self.wip.bin(.fdiv, left, right, "quotient");
                return self.wip.callIntrinsic(
                    .normal,
                    .none,
                    .floor,
                    &.{width},
                    &.{quotient},
                    "float",
                );
            },
            else => {},
        }
        const tag: Tag = switch (operation) {
            .add => .fadd,
            .subtract => .fsub,
            .multiply => .fmul,
            .divide => .fdiv,
            .floor_divide, .modulo => unreachable, // answered above
            // The verifier refuses bit operations on floats before
            // either engine sees them (docs/BITWISE.md D2).
            .bit_and,
            .bit_or,
            .bit_xor,
            .shift_left,
            .shift_right,
            => return self.fail("bit operations on the float path"),
            .equal,
            .not_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            => return self.fail("a comparison on the arithmetic path"),
        };
        // The sign of the NaN an invalid operation produces is
        // target-dependent (`0.0 / 0.0` answers a positive quiet NaN on
        // aarch64 and a negative one on x86-64), and generated code and
        // the oracle both take whatever the hardware gives: the sign is
        // unobservable in Luce, because the one surface that could show
        // it — `str(x)`, in `libluce_rt` — renders every NaN "nan".
        // So every arithmetic tag is exactly its instruction here, with
        // no canonicalizing select on the hot path.
        return self.wip.bin(tag, left, right, "float");
    }

    /// `llvm.s*.with.overflow`, then the trap the interpreter raises.
    fn emitChecked(
        self: *Body,
        intrinsic: Builder.Intrinsic,
        width: Builder.Type,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const pair = try self.wip.callIntrinsic(
            .normal,
            .none,
            intrinsic,
            &.{width},
            &.{ left, right },
            "checked",
        );
        const value = try self.wip.extractValue(pair, &.{0}, "int");
        const overflowed = try self.wip.extractValue(pair, &.{1}, "overflowed");
        try self.check(overflowed, .integer_overflow);
        return value;
    }

    /// Division traps on a zero divisor and on `minInt / -1`, the one
    /// signed division whose result is not representable.
    fn checkDivisor(self: *Body, of: types.Type, left: Builder.Value, right: Builder.Value) Error!void {
        const builder = self.module.builder;
        const width = try self.module.valueType(of);
        const zero = try builder.intValue(width, 0);
        try self.check(try self.wip.icmp(.eq, right, zero, "by.zero"), .divide_by_zero);

        if (of.isUnsigned()) return;

        const smallest = try builder.intValue(
            width,
            of.integerRange().low,
        );
        const negative_one = try builder.intValue(width, -1);
        const is_smallest = try self.wip.icmp(.eq, left, smallest, "is.smallest");
        const is_negative_one = try self.wip.icmp(.eq, right, negative_one, "is.minus.one");
        const both = try self.wip.bin(.@"and", is_smallest, is_negative_one, "overflows");
        try self.check(both, .integer_overflow);
    }

    fn emitCompare(
        self: *Body,
        operation: mir.Instruction.Binary,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        // Comparison on doubles is ordered except for `!=`, which is true
        // whenever the two are not equal — NaN included.  That is what
        // Zig's operators mean in `runtime/operators.zig`.
        if (operation.operand_type.isFloating()) {
            const condition: Builder.FloatCondition = switch (operation.op) {
                .equal => .oeq,
                .not_equal => .une,
                .less => .olt,
                .less_equal => .ole,
                .greater => .ogt,
                .greater_equal => .oge,
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
                => return self.fail("arithmetic on the comparison path"),
            };
            return self.wip.fcmp(.normal, condition, left, right, "compare");
        }

        // str and struct comparison are content, not address: the
        // runtime owns both, and a struct comparison recurses into
        // nested fields rather than comparing the slots that hold them.
        if (operation.operand_type == .str or operation.operand_type == .bytes or operation.operand_type == .strukt) {
            const answer = try self.callRuntime(.luce_rt_compare, .i32, &.{
                try self.module.builder.intValue(.i32, @intFromEnum(operation.op)),
                try self.boxedRegister(operation.left, "left"),
                try self.boxedRegister(operation.right, "right"),
            }, "compared");
            return self.wip.icmp(
                .ne,
                answer,
                try self.module.builder.intValue(.i32, 0),
                "compare",
            );
        }

        // An enum compares as the integer it is stored at, at whichever
        // of the eight explicit widths that is — and equality is the
        // whole of it (docs/ENUMS.md D6), so this is one `icmp` with no
        // numeric conversion.
        if (operation.operand_type == .enumeration) {
            const same: Builder.IntegerCondition = switch (operation.op) {
                .equal => .eq,
                .not_equal => .ne,
                .less,
                .less_equal,
                .greater,
                .greater_equal,
                => return self.fail("an ordering comparison on an enum"),
                .bit_and,
                .bit_or,
                .bit_xor,
                .shift_left,
                .shift_right,
                .add,
                .subtract,
                .multiply,
                .divide,
                .floor_divide,
                .modulo,
                => return self.fail("arithmetic on the comparison path"),
            };
            return self.wip.icmp(same, left, right, "compare");
        }

        const condition: Builder.IntegerCondition = switch (operation.operand_type) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .char => switch (operation.op) {
                .equal => .eq,
                .not_equal => .ne,
                .less => if (operation.operand_type.isUnsigned() or operation.operand_type == .char) .ult else .slt,
                .less_equal => if (operation.operand_type.isUnsigned() or operation.operand_type == .char) .ule else .sle,
                .greater => if (operation.operand_type.isUnsigned() or operation.operand_type == .char) .ugt else .sgt,
                .greater_equal => if (operation.operand_type.isUnsigned() or operation.operand_type == .char) .uge else .sge,
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
                => return self.fail("arithmetic on the comparison path"),
            },
            .boolean => switch (operation.op) {
                .equal => .eq,
                .not_equal => .ne,
                .less,
                .less_equal,
                .greater,
                .greater_equal,
                => return self.fail("an ordering comparison on Bool"),
                .bit_and,
                .bit_or,
                .bit_xor,
                .shift_left,
                .shift_right,
                .add,
                .subtract,
                .multiply,
                .divide,
                .floor_divide,
                .modulo,
                => return self.fail("arithmetic on the comparison path"),
            },
            // Object equality is identity: same object, not same
            // contents, so the handles compare directly.
            .heap => switch (operation.op) {
                .equal => .eq,
                .not_equal => .ne,
                .less,
                .less_equal,
                .greater,
                .greater_equal,
                => return self.fail("an ordering comparison on a heap object"),
                .bit_and,
                .bit_or,
                .bit_xor,
                .shift_left,
                .shift_right,
                .add,
                .subtract,
                .multiply,
                .divide,
                .floor_divide,
                .modulo,
                => return self.fail("arithmetic on the comparison path"),
            },
            .f16, .f32, .f64, .str, .bytes, .strukt, .enumeration => unreachable, // answered above
            // A function value has no equality: its receiver is not part
            // of the function type, so comparing only the named slot would
            // make two different binds equal.  The verifier refuses this
            // shape, and this arm keeps hostile MIR from reaching the old
            // partial comparison (docs/BINDING.md D6).
            .function => return self.fail("a comparison of function values"),
            // A union is compared by match and nothing else
            // (docs/UNION.md D16): the analyzer refuses `==` on one.
            .variant => return self.fail("a comparison of two unions"),
            .none => return self.fail("a comparison of None"),
            // `x == none` is `is_none` by the time it gets here, and
            // the analyzer refuses every other comparison of a `T?`
            // until it is narrowed, so no operand ever arrives wearing
            // one.
            .optional => return self.fail("a comparison of two optionals"),
        };
        return self.wip.icmp(condition, left, right, "compare");
    }

    fn emitUnary(self: *Body, register: mir.Register, operation: mir.Instruction.Unary) Error!void {
        const operand = self.produced[operation.operand].value;
        switch (operation.op) {
            .logic_not => {
                self.produced[register].value = try self.wip.bin(.xor, operand, .true, "not");
            },
            .bit_not => {
                const of = self.function.result_types[operation.operand];
                const width = try self.module.valueType(of);
                self.produced[register].value = try self.wip.bin(
                    .xor,
                    operand,
                    try self.module.builder.intValue(width, -1),
                    "complement",
                );
            },
            .negate => switch (self.function.result_types[operation.operand]) {
                .i8, .i16, .i32, .i64 => {
                    const of = self.function.result_types[operation.operand];
                    const width = try self.module.valueType(of);
                    const zero = try self.module.builder.intValue(width, 0);
                    self.produced[register].value = try self.emitChecked(
                        .@"ssub.with.overflow",
                        width,
                        zero,
                        operand,
                    );
                },
                // A true sign-bit flip, not `0.0 - x`: the two differ
                // for +0.0, and the deleted x86 backend got it wrong.
                .f16, .f32, .f64 => {
                    self.produced[register].value = try self.wip.un(.fneg, operand, "neg");
                },
                .none,
                .boolean,
                .u8,
                .u16,
                .u32,
                .u64,
                .char,
                .str,
                .bytes,
                .strukt,
                .variant,
                .heap,
                .enumeration,
                .function,
                .optional,
                => return self.fail("negation of a type that has none"),
            },
        }
    }

    // -- calls -----------------------------------------------------------

    fn emitCall(self: *Body, register: mir.Register, called: mir.Instruction.Call) Error!void {
        try self.emitDirectCall(register, called.function, .none, called.arguments);
    }

    fn emitInoutCall(
        self: *Body,
        register: mir.Register,
        called: mir.Instruction.InoutCall,
    ) Error!void {
        try self.emitDirectCall(
            register,
            called.function,
            try self.inoutDescriptor(called.receiver),
            called.arguments,
        );
    }

    /// The common direct-call convention.  `receiver` is `.none` for
    /// an ordinary call and the one aggregate occupying logical
    /// parameter zero for an inout call.
    fn emitDirectCall(
        self: *Body,
        register: mir.Register,
        function: u32,
        receiver: Builder.Value,
        explicit_arguments: []const mir.Register,
    ) Error!void {
        const gpa = self.module.gpa;
        const target = self.module.functions[function];
        const result = self.function.result_types[register];

        // The callee gets one frame less than this one has, and a call
        // that leaves it none traps here — the same call at which the
        // interpreter's frame stack refuses to grow, so the two engines
        // trap on the same call with the same trace behind them.
        const callee_depth = try self.calleeDepth();
        try self.check(
            try self.wip.icmp(
                .slt,
                callee_depth,
                try self.module.builder.intValue(.i64, 1),
                "too.deep",
            ),
            .call_depth_exceeded,
        );

        var arguments: std.ArrayList(Builder.Value) = .empty;
        defer arguments.deinit(gpa);
        try arguments.append(gpa, self.host);
        try arguments.append(gpa, self.runtime);
        try arguments.append(gpa, callee_depth);
        if (receiver != .none) try arguments.append(gpa, receiver);
        for (explicit_arguments) |argument| {
            try arguments.append(gpa, self.produced[argument].value);
        }
        var result_slot: Builder.Value = .none;
        if (result != .none) {
            result_slot = try self.scratch(
                try self.module.valueType(result),
                Module.valueAlignment(result),
                "call.result",
            );
            try arguments.append(gpa, result_slot);
        }

        const outcome = try self.wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            target.typeOf(self.module.builder),
            target.toValue(self.module.builder),
            arguments.items,
            "outcome",
        );
        if (self.module.program.functions[function].fallible) {
            try self.propagateTrapOnly(outcome);
            self.produced[register].outcome = outcome;
        } else {
            try self.propagate(try self.wip.icmp(
                .ne,
                outcome,
                try self.module.builder.intValue(.i32, outcome_ok),
                "trapped",
            ));
        }

        if (result != .none) {
            self.produced[register].value = try self.wip.load(
                .normal,
                try self.module.valueType(result),
                result_slot,
                Module.valueAlignment(result),
                "call.value",
            );
        }
    }

    /// Descriptor for a writing receiver: the pointer to the aliased
    /// slot.  Calling another writing method on `self` forwards it
    /// unchanged; calling one on an ordinary local names that slot.
    fn inoutDescriptor(self: *Body, local: mir.LocalId) Error!Builder.Value {
        if (self.function.locals[local].inout) {
            std.debug.assert(self.inout != .none);
            return self.inout;
        }
        return self.local_slots[local];
    }

    fn emitInterfaceMake(
        self: *Body,
        register: mir.Register,
        made: mir.Instruction.InterfaceMake,
    ) Error!void {
        const run = try self.scratchRun(
            self.module.value_type,
            mir.interface_run_length,
            value_alignment,
            "interface",
        );
        try self.boxAt(
            run,
            mir.interface_run_witness,
            .i64,
            try self.module.builder.intValue(.i64, made.witness + 1),
        );
        try self.storedAt(run, mir.interface_run_payload, made.receiver);
        try self.callAnswering(register, .luce_rt_struct_make, &.{
            self.runtime,
            run,
            try self.module.builder.intValue(.i64, mir.interface_run_length),
        });
    }

    /// Dispatch one interface contract slot. The runtime value owns only its
    /// payload; the one-based witness identity selects a verified static row,
    /// and the ordinary function-value adapter table performs the concrete
    /// receiver unboxing (or forwards the payload cell for an inout witness).
    fn emitInterfaceCall(
        self: *Body,
        register: mir.Register,
        layout: u32,
        method: u32,
        explicit_arguments: []const mir.Register,
        fallible: bool,
        run: Builder.Value,
    ) Error!void {
        const builder = self.module.builder;
        const gpa = self.module.gpa;
        const requirement = self.module.program.structs[layout].interface_methods[method];
        const signature = self.module.program.signatures[requirement.signature];
        const result = self.function.result_types[register];

        try self.check(
            try self.wip.icmp(
                .eq,
                try self.wip.cast(.ptrtoint, run, .i64, "interface.word"),
                try builder.intValue(.i64, 0),
                "no.interface",
            ),
            .null_object,
        );
        const witness_slot = try self.wip.gep(
            .inbounds,
            self.module.value_type,
            run,
            &.{try builder.intValue(.i64, mir.interface_run_witness)},
            "witness.slot",
        );
        const one_based = try self.unboxed(.i64, witness_slot, "witness");
        try self.check(
            try self.wip.icmp(
                .ult,
                one_based,
                try builder.intValue(.i64, 1),
                "no.witness",
            ),
            .null_object,
        );
        try self.check(
            try self.wip.icmp(
                .ugt,
                one_based,
                try builder.intValue(.i64, self.module.program.interface_witnesses.len),
                "bad.witness",
            ),
            .null_object,
        );
        const witness_index = try self.wip.bin(
            .sub,
            one_based,
            try builder.intValue(.i64, 1),
            "witness.index",
        );
        const tables = try self.module.interfaceWitnessTables();
        const layout_slot = try self.wip.gep(
            .inbounds,
            .i32,
            tables.layouts.toValue(builder),
            &.{witness_index},
            "witness.layout.slot",
        );
        const witnessed_layout = try self.wip.load(
            .normal,
            .i32,
            layout_slot,
            .fromByteUnits(4),
            "witness.layout",
        );
        try self.check(
            try self.wip.icmp(
                .ne,
                witnessed_layout,
                try builder.intValue(.i32, layout),
                "wrong.interface",
            ),
            .null_object,
        );
        const offset_slot = try self.wip.gep(
            .inbounds,
            .i32,
            tables.offsets.toValue(builder),
            &.{witness_index},
            "witness.offset.slot",
        );
        const offset = try self.wip.load(
            .normal,
            .i32,
            offset_slot,
            .fromByteUnits(4),
            "witness.offset",
        );
        const method_index = try self.wip.bin(
            .add,
            offset,
            try builder.intValue(.i32, method),
            "witness.method.index",
        );
        const method_slot = try self.wip.gep(
            .inbounds,
            .i32,
            tables.methods.toValue(builder),
            &.{try self.wip.cast(.zext, method_index, .i64, "witness.method.at")},
            "witness.method.slot",
        );
        const named = try self.wip.load(
            .normal,
            .i32,
            method_slot,
            .fromByteUnits(4),
            "witness.method",
        );
        const function_table = try self.module.functionTable();
        const target_slot = try self.wip.gep(
            .inbounds,
            .ptr,
            function_table.toValue(builder),
            &.{try self.wip.cast(.zext, named, .i64, "witness.target.at")},
            "witness.target.slot",
        );
        const target = try self.wip.load(
            .normal,
            .ptr,
            target_slot,
            .fromByteUnits(8),
            "witness.target",
        );

        const callee_depth = try self.calleeDepth();
        try self.check(
            try self.wip.icmp(
                .slt,
                callee_depth,
                try builder.intValue(.i64, 1),
                "too.deep",
            ),
            .call_depth_exceeded,
        );
        const payload_slot = try self.wip.gep(
            .inbounds,
            self.module.value_type,
            run,
            &.{try builder.intValue(.i64, mir.interface_run_payload)},
            "interface.payload",
        );
        var arguments: std.ArrayList(Builder.Value) = .empty;
        defer arguments.deinit(gpa);
        try arguments.appendSlice(gpa, &.{ self.host, self.runtime, callee_depth, payload_slot });
        for (explicit_arguments) |argument| {
            try arguments.append(gpa, self.produced[argument].value);
        }
        var result_slot: Builder.Value = .none;
        if (result != .none) {
            result_slot = try self.scratch(
                try self.module.valueType(result),
                Module.valueAlignment(result),
                "interface.result",
            );
            try arguments.append(gpa, result_slot);
        }

        const outcome = try self.wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            try self.module.indirectSignature(signature),
            target,
            arguments.items,
            "interface.outcome",
        );
        if (fallible) self.produced[register].outcome = outcome;
        try self.propagate(try self.wip.icmp(
            .ne,
            outcome,
            try builder.intValue(.i32, outcome_ok),
            "interface.trapped",
        ));
        if (result != .none) {
            self.produced[register].value = try self.wip.load(
                .normal,
                try self.module.valueType(result),
                result_slot,
                Module.valueAlignment(result),
                "interface.value",
            );
        }
    }

    /// A call **through a function value** (docs/FUNCTIONS.md D2).
    ///
    /// The value is an index, so the callee is one load out of the
    /// module's function table — the same table both engines dispatch
    /// through, one holding pointers and one holding `mir.Function`s.
    /// Everything else is `emitCall` exactly: the same three hidden
    /// arguments, the same depth check, the same out-parameter, and
    /// the same unwind edge. Ordinary function values are non-fallible;
    /// interface dispatch carries the contract's fallibility explicitly
    /// at this call site, so a fallible witness can propagate its trap.
    /// A function value: the two-slot run holding the function it names
    /// and the receiver it carries, built exactly the way a struct
    /// value is (docs/BINDING.md D12).
    ///
    /// `libluce_rt` is handed a run and told how long it is, which is
    /// all it was ever told about a struct — so a receiver of any shape
    /// travels without the runtime learning that function values exist.
    fn emitConstFunction(
        self: *Body,
        register: mir.Register,
        named: mir.Instruction.BoundFunction,
    ) Error!void {
        const run = try self.scratchRun(
            self.module.value_type,
            mir.function_run_length,
            value_alignment,
            "bound",
        );
        try self.boxAt(
            run,
            mir.function_run_named,
            .i32,
            try self.module.builder.intValue(.i32, named.function),
        );
        if (named.receiver) |receiver| {
            try self.storedAt(run, mir.function_run_receiver, receiver);
        } else {
            try self.noneAt(run, mir.function_run_receiver);
        }
        try self.callAnswering(register, .luce_rt_function_make, &.{
            self.runtime,
            run,
            try self.module.builder.intValue(.i64, mir.function_run_length),
        });
    }

    /// The function a value names, read out of its run.
    ///
    /// **The run that is nowhere is refused here**, once, for every
    /// reader: a function-typed slot that was never written holds no
    /// run, and reading one is the same mistake as using a freed
    /// object.  Whoever asks gets an index that really is in the
    /// program's table or a trap, and never a jump into nothing.
    fn namedFunction(self: *Body, value: Builder.Value, name: []const u8) Error!Builder.Value {
        try self.check(
            try self.wip.icmp(
                .eq,
                try self.wip.cast(.ptrtoint, value, .i64, "run.word"),
                try self.module.builder.intValue(.i64, 0),
                "no.run",
            ),
            .null_object,
        );
        const slot = try self.wip.gep(
            .inbounds,
            self.module.value_type,
            value,
            &.{try self.module.builder.intValue(.i64, mir.function_run_named)},
            "named.slot",
        );
        const named = try self.wip.cast(
            .trunc,
            try self.loadBoxField(slot, box_bits, "named.bits"),
            .i32,
            name,
        );
        try self.check(
            try self.wip.icmp(
                .uge,
                named,
                try self.module.builder.intValue(
                    .i32,
                    @as(i64, @intCast(self.module.program.functions.len)),
                ),
                "no.such.function",
            ),
            .null_object,
        );
        return named;
    }

    fn emitIndirectCall(
        self: *Body,
        register: mir.Register,
        called: mir.Instruction.IndirectCall,
    ) Error!void {
        const gpa = self.module.gpa;
        const signature = self.module.program.signatures[called.signature];
        const result = self.function.result_types[register];

        const callee_depth = try self.calleeDepth();
        try self.check(
            try self.wip.icmp(
                .slt,
                callee_depth,
                try self.module.builder.intValue(.i64, 1),
                "too.deep",
            ),
            .call_depth_exceeded,
        );

        // The value names a function or it names nothing, and nothing
        // is what an unwritten slot holds — the same refusal the
        // interpreter makes at the same call.
        const named = try self.namedFunction(self.produced[called.callee].value, "callee");
        const table = try self.module.functionTable();
        const slot = try self.wip.gep(
            .inbounds,
            .ptr,
            table.toValue(self.module.builder),
            &.{try self.wip.cast(.zext, named, .i64, "callee.at")},
            "callee.slot",
        );
        const target = try self.wip.load(
            .normal,
            .ptr,
            slot,
            .fromByteUnits(8),
            "callee",
        );

        var arguments: std.ArrayList(Builder.Value) = .empty;
        defer arguments.deinit(gpa);
        try arguments.append(gpa, self.host);
        try arguments.append(gpa, self.runtime);
        try arguments.append(gpa, callee_depth);
        // The receiver slot of the value's own run — the environment
        // the adapter unboxes, or the `none` a plain value carries
        // there and its adapter never reads.
        try arguments.append(gpa, try self.wip.gep(
            .inbounds,
            self.module.value_type,
            self.produced[called.callee].value,
            &.{try self.module.builder.intValue(.i64, mir.function_run_receiver)},
            "receiver.slot",
        ));
        for (called.arguments) |argument| {
            try arguments.append(gpa, self.produced[argument].value);
        }
        var result_slot: Builder.Value = .none;
        if (result != .none) {
            result_slot = try self.scratch(
                try self.module.valueType(result),
                Module.valueAlignment(result),
                "call.result",
            );
            try arguments.append(gpa, result_slot);
        }

        const outcome = try self.wip.call(
            .normal,
            Builder.CallConv.default,
            .none,
            try self.module.indirectSignature(signature),
            target,
            arguments.items,
            "outcome",
        );
        if (called.fallible) self.produced[register].outcome = outcome;
        try self.propagate(try self.wip.icmp(
            .ne,
            outcome,
            try self.module.builder.intValue(.i32, outcome_ok),
            "trapped",
        ));

        if (result != .none) {
            self.produced[register].value = try self.wip.load(
                .normal,
                try self.module.valueType(result),
                result_slot,
                Module.valueAlignment(result),
                "call.value",
            );
        }
    }

    /// `spawn f(args)` — hand the call to a worker and take the task
    /// (docs/THREADS.md D2, D3).
    ///
    /// **Nothing about the callee is emitted here.**  The arguments are
    /// boxed into a run the runtime reads, the runtime opens a second
    /// runtime and moves them into it, and the *worker's* thread enters
    /// this module through `@luce.worker`.  So a spawn is one runtime
    /// call, and the boxing is the boxing every runtime call does.
    ///
    /// There is no depth check in front of it: a worker starts on a
    /// stack of its own with a budget of its own, so the frames this
    /// function has left have nothing to say about it.
    /// Whether the function a task carries could come back errored —
    /// read out of the task's own heap shape, which is the one place
    /// it is written (docs/THREADS.md D4).
    fn taskIsFallible(self: *Body, register: mir.Register) bool {
        const held = self.function.result_types[register];
        if (held != .heap) return false;
        const shape = self.module.program.heap_types[held.heap];
        return shape == .task and shape.task.fallible;
    }

    fn emitSpawn(self: *Body, register: mir.Register, called: mir.Instruction.Call) Error!void {
        const builder = self.module.builder;
        const count = called.arguments.len;
        const frame = if (count == 0)
            try builder.nullValue(.ptr)
        else
            try self.scratchRun(self.module.value_type, count, value_alignment, "spawn.args");
        for (called.arguments, 0..) |argument, at| {
            try self.boxAt(
                frame,
                at,
                self.function.result_types[argument],
                self.produced[argument].value,
            );
        }
        const out = try self.scratch(self.module.value_type, value_alignment, "spawn.task");
        try self.callChecked(.luce_rt_spawn, &.{
            self.runtime,
            try builder.intValue(.i64, called.function),
            frame,
            try builder.intValue(.i64, count),
            out,
        });
        self.produced[register].value = try self.unboxed(
            self.function.result_types[register],
            out,
            "spawn.task.value",
        );
    }

    /// `if (trapped) return trapped` — the unwind edge after a call
    /// that cannot error, and where this frame joins the trace on the
    /// way out.
    fn propagate(self: *Body, trapped: Builder.Value) Error!void {
        const unwinding = try self.wip.block(1, "unwind");
        const surviving = try self.wip.block(1, "returned");
        _ = try self.wip.brCond(trapped, unwinding, surviving, .else_likely);
        self.seek(unwinding);
        try self.leaveUnwinding();
        self.seek(surviving);
    }

    /// The same edge after a call that *can* error: a trap still
    /// leaves immediately, an error falls through with its outcome in
    /// hand for the `errored` beside it to branch on.  Two answers in
    /// one word, which is why the flag is an `i32` and not a bit.
    fn propagateTrapOnly(self: *Body, outcome: Builder.Value) Error!void {
        const trapped = try self.wip.icmp(
            .eq,
            outcome,
            try self.module.builder.intValue(.i32, outcome_trapped),
            "rt.trapped",
        );
        try self.propagate(trapped);
    }

    /// The box `drop_storage` gives back — **the place itself**, not a
    /// fresh box built from the register.
    ///
    /// Boxing an unboxed str says its text is outside, because that
    /// is all a `{ptr, i64}` can say; handing that to the runtime with
    /// short text in the slot would ask it to free a pointer into this
    /// frame.  The register being dropped was always read out of the
    /// place being emptied — stage 4 emits the release as load, drop,
    /// store back — so the place is what to hand over, and it is one
    /// fewer copy besides.
    ///
    /// A register with no box behind it can only be carrying a struct's
    /// run, which survives the round trip whole; text without a place
    /// is refused rather than silently freed.
    fn dropped(self: *Body, register: mir.Register) Error!Builder.Value {
        if (self.produced[register].box == .none and
            carriesText(self.function.result_types[register]))
        {
            return self.fail("drop_storage of text that was not read out of a place");
        }
        return self.storageOf(register);
    }

    /// The same, for everything that asks *which form* a value's
    /// storage is in rather than merely reading its bytes.
    ///
    /// Most runtime calls read through the pointer a box hands them, so
    /// an outside box over inline bytes tells them the truth.  Three
    /// kinds would be misled: `drop_storage`, which frees;
    /// `export_storage`, which decides between a transfer and a copy;
    /// and every **store**, which keeps the value it is given, so short
    /// text has to arrive short or the place ends up holding a pointer
    /// into this frame.  All of them take the place the register was
    /// read from.  A text register with no place behind it is a
    /// constant, a parameter or a slice, and a store only ever sees one
    /// of those with an `own_storage` in between (docs/STRINGS.md).
    fn storageOf(self: *Body, register: mir.Register) Error!Builder.Value {
        if (self.produced[register].box != .none) return self.produced[register].box;
        return self.boxedRegister(register, "held");
    }

    /// Whether a value of this type can be text in its own right — the
    /// one payload whose box does not round trip, because boxing loses
    /// which form the bytes were in.
    fn carriesText(of: types.Type) bool {
        return switch (of) {
            .str, .bytes => true,
            .optional => |payload| carriesText(payload.asType()),
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .f16,
            .f32,
            .f64,
            .char,
            .strukt,
            .variant,
            .heap,
            .enumeration,
            .function,
            => false,
        };
    }

    // -- intrinsics ------------------------------------------------------

    fn emitIntrinsic(
        self: *Body,
        register: mir.Register,
        called: mir.Instruction.IntrinsicCall,
    ) Error!void {
        const rt = self.runtime;
        const of = called.arguments;
        switch (called.kind) {
            // -- value storage ----------------------------------------
            //
            // All three cross into `libluce_rt` as a boxed value, like
            // every other store site, so the unboxed `{ptr, i64}` a
            // str lives in between them does not move
            // (docs/STRINGS.md).
            .own_storage => try self.callAnswering(register, .luce_rt_own_storage, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),
            .drop_storage => {
                const out = try self.scratch(self.module.value_type, value_alignment, "rt.out");
                _ = try self.callRuntime(.luce_rt_drop_storage, .void, &.{
                    rt,
                    try self.dropped(of[0]),
                    out,
                }, "");
                self.produced[register].value = try self.unboxed(
                    self.function.result_types[register],
                    out,
                    "rt.value",
                );
                self.produced[register].box = out;
            },
            .export_storage => try self.callAnswering(register, .luce_rt_export_storage, &.{
                rt,
                try self.storageOf(of[0]),
            }),

            // -- object lifetime (ARC) --------------------------------
            //
            // A retain and a release cross as a boxed value and answer
            // nothing; the runtime touches only the objects the value
            // names, and a value naming none is a no-op (docs/MEMORY.md).
            .retain => try self.callChecked(.luce_rt_retain, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),
            .release => try self.callChecked(.luce_rt_release, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),

            // -- errors -----------------------------------------------
            //
            // The channel is the outcome word the call beside it
            // answered, so asking costs a compare and nothing else.
            .errored => {
                const outcome = self.produced[of[0]].outcome;
                if (outcome == .none) return self.fail("errored without a fallible call in its block");
                self.produced[register].value = try self.wip.icmp(
                    .eq,
                    outcome,
                    try self.module.builder.intValue(.i32, outcome_errored),
                    "errored",
                );
            },
            // The words, borrowed out of the arena that holds them —
            // the same shape `key_text` has, and for the same reason:
            // run-lifetime storage a place that keeps it copies from.
            .error_message => {
                const out = try self.scratch(self.module.value_type, value_alignment, "catch.reason");
                _ = try self.callRuntime(.luce_rt_error_message, .void, &.{ rt, out }, "");
                self.produced[register].value = try self.unboxed(.str, out, "catch.reason");
            },
            .forget => {
                _ = try self.callRuntime(.luce_rt_forget_error, .void, &.{rt}, "");
            },
            .raise_error => {
                // The pointer this hands over may address *this frame*:
                // short text lives in the value it was read out of
                // (docs/STRINGS.md).  Sound only because `raise` copies
                // before it returns, which it must anyway — the unwind
                // that follows releases what the words were read from.
                const words, const length = try self.textParts(of[0], "words");
                _ = try self.callRuntime(.luce_rt_raise_error, .void, &.{
                    rt,
                    try self.module.builder.intValue(.i32, @intFromEnum(mir.ErrorCode.user_error)),
                    words,
                    length,
                    try self.module.builder.intValue(.i32, self.index),
                    try self.module.builder.intValue(.i32, self.current),
                }, "");
            },

            // -- scalar math, generated here --------------------------
            .abs => {
                const kind = try self.numeric(of[0]);
                const width = try self.module.valueType(kind);
                if (kind.isUnsigned()) {
                    self.produced[register].value = self.produced[of[0]].value;
                } else if (kind.isInteger()) {
                    // Negating the smallest integer has no
                    // representable result at its width, so `abs`
                    // traps where the interpreter does and the
                    // intrinsic never sees the poison case.
                    const held = self.produced[of[0]].value;
                    const smallest = try self.module.builder.intValue(
                        width,
                        kind.integerRange().low,
                    );
                    try self.check(
                        try self.wip.icmp(.eq, held, smallest, "is.smallest"),
                        .integer_overflow,
                    );
                    self.produced[register].value = try self.wip.callIntrinsic(
                        .normal,
                        .none,
                        .abs,
                        &.{width},
                        &.{ held, .true },
                        "abs",
                    );
                } else self.produced[register].value = try self.wip.callIntrinsic(
                    .normal,
                    .none,
                    .fabs,
                    &.{width},
                    &.{self.produced[of[0]].value},
                    "abs",
                );
            },
            .min, .max => self.produced[register].value = try self.emitExtremum(
                called.kind == .min,
                self.produced[of[0]].value,
                self.produced[of[1]].value,
                try self.numeric(of[0]),
            ),
            // `@min(@max(middle, low), high)`, in that order: the
            // interpreter's, and the order decides the answer when the
            // bounds cross.  Both numeric kinds compose the same two
            // extrema, so a clamp inside a loop is two instructions on
            // either type rather than a call on one of them.
            .clamp => {
                const kind = try self.numeric(of[0]);
                const lifted = try self.emitExtremum(
                    false,
                    self.produced[of[0]].value,
                    self.produced[of[1]].value,
                    kind,
                );
                self.produced[register].value = try self.emitExtremum(
                    true,
                    lifted,
                    self.produced[of[2]].value,
                    kind,
                );
            },
            .sqrt => self.produced[register].value = try self.emitFloatCall(.sqrt, of[0]),
            .floor => self.produced[register].value = try self.emitFloatCall(.floor, of[0]),
            .ceil => self.produced[register].value = try self.emitFloatCall(.ceil, of[0]),
            .trunc => self.produced[register].value = try self.emitFloatCall(.trunc, of[0]),

            // -- traps and effects, generated here --------------------
            .print => {
                const text, const length = try self.textParts(of[0], "print");
                _ = try self.callHost(.print, &.{ text, length }, "printed");
            },
            .assert_true => {
                const held = self.produced[of[0]].value;
                const broken = try self.wip.bin(.xor, held, .true, "assert.failed");
                try self.check(broken, .assertion_failed);
            },
            .trap_message => try self.emitTrapMessage(called),

            // -- the runtime library, one call each -------------------
            .null_object => {
                self.produced[register].value = try self.module.builder.intValue(.i64, runtime.null_index);
            },

            // -- absence, as four moves on `{T, i1}` ------------------
            //
            // Every one of them is a register shuffle: SROA takes the
            // pair apart and the bit becomes a flag the machine was
            // already carrying.  There is no call and no memory here,
            // which is what makes `parse_i64(s) else 0` cost what the
            // parse costs and nothing more.
            .none_value => {
                self.produced[register].value = try self.zeroValue(
                    self.function.result_types[register],
                );
            },
            .is_none => {
                self.produced[register].value = try self.wip.bin(
                    .xor,
                    try self.wip.extractValue(
                        self.produced[of[0]].value,
                        &.{Module.optional_present},
                        "present",
                    ),
                    .true,
                    "is.none",
                );
            },
            // `T <: T?`: the same payload, now known to be there.
            .optional_wrap => {
                self.produced[register].value = try self.wip.buildAggregate(
                    try self.module.valueType(self.function.result_types[register]),
                    &.{ self.produced[of[0]].value, .true },
                    "wrap",
                );
            },
            // What narrowing licensed.  The analyzer has already proved
            // the bit is set, so nothing is checked here.
            .optional_unwrap => {
                self.produced[register].value = try self.wip.extractValue(
                    self.produced[of[0]].value,
                    &.{Module.optional_payload},
                    "unwrap",
                );
            },
            .len => {
                if (self.elementShape(of[0])) |shape| {
                    return self.emitInlineLength(register, of[0], shape);
                }
                try self.callAnswering(register, .luce_rt_len, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                });
            },
            .index_get => {
                if (self.elementShape(of[0])) |shape| {
                    const view = try self.elementView(of[0], shape);
                    const address = try self.elementAddress(view, shape.element, of[1..]);
                    self.produced[register].value = try self.loadCell(shape.element, address);
                    if (!ownsNothing(shape.element)) self.produced[register].box = address;
                    return;
                }
                const run, const rank = try self.subscripts(of[1..]);
                try self.callAnswering(register, .luce_rt_index_get, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    run,
                    rank,
                });
            },
            .index_set => {
                if (self.elementShape(of[0])) |shape| {
                    if (ownsNothing(shape.element)) {
                        const view = try self.elementView(of[0], shape);
                        try self.checkNotConstant(of[0], view.row);
                        const address = try self.elementAddress(
                            view,
                            shape.element,
                            of[1 .. of.len - 1],
                        );
                        try self.storeCell(
                            shape.element,
                            address,
                            self.produced[of[of.len - 1]].value,
                        );
                        return;
                    }
                }
                const held = try self.storageOf(of[of.len - 1]);
                const run, const rank = try self.subscripts(of[1 .. of.len - 1]);
                try self.callChecked(.luce_rt_index_set, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    run,
                    rank,
                    held,
                });
            },
            .list_slice => try self.callAnswering(register, .luce_rt_list_slice, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.produced[of[1]].value,
                self.produced[of[2]].value,
            }),
            .append_value => {
                if (self.elementShape(of[0])) |shape| {
                    if (shape.growable and ownsNothing(shape.element)) {
                        return self.emitListAppend(of[0], of[1], shape);
                    }
                }
                try self.callChecked(.luce_rt_append, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    try self.storageOf(of[1]),
                });
            },
            .append_ascii => try self.callChecked(.luce_rt_append_ascii, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.produced[of[1]].value,
            }),
            .pop_value => try self.callAnswering(register, .luce_rt_pop, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .insert_value => try self.callChecked(.luce_rt_insert, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.produced[of[1]].value,
                try self.storageOf(of[2]),
            }),
            .remove_entry => try self.callChecked(.luce_rt_remove, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedKey(of[1], "which"),
            }),
            .has_key => try self.callAnswering(register, .luce_rt_has_key, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedKey(of[1], "key"),
            }),
            // The answer is unboxed at the register's own type, which
            // for an enum-keyed map truncates the stored `i64` back to
            // the enum's width — the inverse of `boxedKey`'s widening,
            // and the whole of what a key costs on the way out.
            .key_at => try self.callAnswering(register, .luce_rt_key_at, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.produced[of[1]].value,
            }),
            .value_at => try self.callAnswering(register, .luce_rt_value_at, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.produced[of[1]].value,
            }),
            .dim_size => {
                // An array's question and only an array's: `dim` is
                // not a list method, and a list has no `dims` to read.
                // A hand-built module that asks one anyway goes to the
                // runtime, which answers `index_bounds` — the same
                // sentence the oracle answers.
                if (self.elementShape(of[0])) |shape| {
                    if (!shape.growable) {
                        return self.emitArrayDimSize(register, of[0], of[1], shape);
                    }
                }
                try self.callAnswering(register, .luce_rt_dim_size, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    self.produced[of[1]].value,
                });
            },
            .list_sort => try self.callChecked(.luce_rt_sort, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .list_reverse => try self.callChecked(.luce_rt_reverse, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .list_find => try self.callAnswering(register, .luce_rt_find, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "wanted"),
            }),
            .list_contains => try self.callAnswering(register, .luce_rt_contains, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "wanted"),
            }),
            .clear_object => try self.callChecked(.luce_rt_clear, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .map_keys => try self.callAnswering(register, .luce_rt_map_keys, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.answeredZero(register),
            }),
            .map_values => try self.callAnswering(register, .luce_rt_map_values, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.answeredZero(register),
            }),
            .map_get => try self.callAnswering(register, .luce_rt_map_get, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedKey(of[1], "key"),
            }),
            .map_place => try self.callAnswering(register, .luce_rt_map_place, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedKey(of[1], "key"),
                try self.boxedRegister(of[2], "zero"),
            }),
            .array_fill => try self.callChecked(.luce_rt_array_fill, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "element"),
            }),
            .copy_object => try self.callAnswering(register, .luce_rt_copy, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .str_value => try self.callAnswering(register, .luce_rt_str, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),
            .bytes_value => try self.callAnswering(register, .luce_rt_bytes, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),
            // `str(f)` — one `getelementptr` into the name table and
            // one load; the bytes are the module's own constants and
            // nobody frees them (docs/FUNCTIONS.md D3).
            .function_name => {
                const named = try self.namedFunction(self.produced[of[0]].value, "named");
                const names = try self.module.functionNames();
                const slot = try self.wip.gep(
                    .inbounds,
                    self.module.string_type,
                    names.toValue(self.module.builder),
                    &.{try self.wip.cast(.zext, named, .i64, "name.at")},
                    "name.slot",
                );
                self.produced[register].value = try self.wip.load(
                    .normal,
                    self.module.string_type,
                    slot,
                    .fromByteUnits(8),
                    "function.name",
                );
            },
            .parse_i64 => try self.callAnswering(register, .luce_rt_parse_i64, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
            }),
            .parse_str => try self.callAnswering(register, .luce_rt_parse_str, &.{
                rt,
                try self.boxedRegister(of[0], "bytes"),
            }),
            .parse_f64 => try self.callAnswering(register, .luce_rt_parse_f64, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
            }),
            .string_slice => try self.callAnswering(register, .luce_rt_string_slice, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
                self.produced[of[1]].value,
                self.produced[of[2]].value,
            }),
            .string_byte => try self.emitStringByte(register, of[0], of[1]),
            .string_find_byte => try self.callAnswering(register, .luce_rt_string_find_byte, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
                // The service takes a plain `i64`; the byte reaches it
                // as the magnitude its bits are.
                try self.wip.cast(.zext, self.produced[of[1]].value, .i64, "byte.wanted"),
                self.produced[of[2]].value,
            }),

            // -- the rest of the host services ------------------------
            // A file the world would not read or write is an error
            // and not a trap: `file_exists` in front of it is a race,
            // which is the proof a guard cannot stand in for a result
            // (docs/FAILURE.md).  Both answer an outcome the `errored`
            // beside them branches on.
            .file_read => try self.emitFileRead(register, of[0]),
            .file_write => try self.emitWriteText(register, of, .write),
            .file_append => try self.emitWriteText(register, of, .append),
            .file_delete => {
                const path, const path_length = try self.textParts(of[0], "path");
                const answer = try self.callHost(
                    .file_delete,
                    &.{ path, path_length },
                    "deleted",
                );
                self.produced[register].outcome = try self.raiseIo(.delete, answer, path, path_length);
            },
            .file_rename => {
                const from, const from_length = try self.textParts(of[0], "from");
                const to, const to_length = try self.textParts(of[1], "to");
                const answer = try self.callHost(
                    .file_rename,
                    &.{ from, from_length, to, to_length },
                    "renamed",
                );
                // The words name the file that was to move, which is
                // the one the program asked about.
                self.produced[register].outcome = try self.raiseIo(.rename, answer, from, from_length);
            },
            .dir_list => try self.emitDirList(register, of[0]),
            // Making a directory is the same shape deleting one is: a
            // path in, an outcome back.  The parents and the
            // already-there case are the *host's* rule (`abi.zig`'s
            // `DirCreateFn`), not something generated code arranges —
            // a loop here would be a second implementation of the
            // service, and the two engines would each have one.
            .dir_create => {
                const path, const path_length = try self.textParts(of[0], "path");
                const answer = try self.callHost(
                    .dir_create,
                    &.{ path, path_length },
                    "made",
                );
                self.produced[register].outcome = try self.raiseIo(.make, answer, path, path_length);
            },

            // -- backend-neutral window/GPU channel ------------------
            //
            // These doors are runtime calls rather than direct ABI calls.
            // `libluce_rt` owns native-resource validation and turns a host
            // refusal into the same fallible outcome as file I/O; the
            // generated code only boxes/unboxes the language values.
            .gpu_backend => {
                const out = try self.scratch(.i64, value_alignment, "gpu.backend");
                try self.callChecked(.luce_rt_gpu_backend, &.{ rt, out });
                self.produced[register].value = try self.wip.load(
                    .normal,
                    .i64,
                    out,
                    value_alignment,
                    "gpu.backend.value",
                );
            },
            .ui_window_open => {
                const title, const title_length = try self.textParts(of[0], "title");
                const box = try self.scratch(self.module.value_type, value_alignment, "window.box");
                const result = self.function.result_types[register];
                try self.fillBoxShape(box, result);
                try self.fillBoxValue(box, result, try self.zeroValue(result));
                self.produced[register].outcome = try self.graphicsService(.luce_rt_ui_window_open, &.{
                    title,
                    title_length,
                    self.produced[of[1]].value,
                    self.produced[of[2]].value,
                    box,
                });
                self.produced[register].value = try self.unboxed(result, box, "window.value");
                self.produced[register].box = box;
            },
            .ui_window_surface => {
                const box = try self.scratch(self.module.value_type, value_alignment, "surface.box");
                const result = self.function.result_types[register];
                try self.fillBoxShape(box, result);
                try self.fillBoxValue(box, result, try self.zeroValue(result));
                self.produced[register].outcome = try self.graphicsService(.luce_rt_ui_window_surface, &.{
                    try self.boxedRegister(of[0], "window"),
                    box,
                });
                self.produced[register].value = try self.unboxed(result, box, "surface.value");
                self.produced[register].box = box;
            },
            .gpu_surface_size => {
                const out = try self.scratch(.i64, value_alignment, "surface.size");
                self.produced[register].outcome = try self.graphicsService(.luce_rt_gpu_surface_size, &.{
                    try self.boxedRegister(of[0], "surface"),
                    self.produced[of[1]].value,
                    out,
                });
                self.produced[register].value = try self.wip.load(
                    .normal,
                    .i64,
                    out,
                    value_alignment,
                    "surface.size.value",
                );
            },
            .gpu_surface_clear => {
                self.produced[register].outcome = try self.graphicsService(.luce_rt_gpu_surface_clear, &.{
                    try self.boxedRegister(of[0], "surface"),
                    self.produced[of[1]].value,
                    self.produced[of[2]].value,
                    self.produced[of[3]].value,
                    self.produced[of[4]].value,
                });
            },
            .gpu_surface_fill_rect => {
                self.produced[register].outcome = try self.graphicsService(.luce_rt_gpu_surface_fill_rect, &.{
                    try self.boxedRegister(of[0], "surface"),
                    self.produced[of[1]].value,
                    self.produced[of[2]].value,
                    self.produced[of[3]].value,
                    self.produced[of[4]].value,
                    self.produced[of[5]].value,
                    self.produced[of[6]].value,
                    self.produced[of[7]].value,
                    self.produced[of[8]].value,
                });
            },
            .gpu_surface_present => {
                self.produced[register].outcome = try self.graphicsService(.luce_rt_gpu_surface_present, &.{
                    try self.boxedRegister(of[0], "surface"),
                });
            },

            // -- the byte channel (docs/BYTES.md) ---------------------
            //
            // Every one of these is a `libluce_rt` call and not a host
            // call, which is the shape the ruling decided: the runtime
            // holds the five host slots for the whole run, so the
            // handle's semantics — what an open answers, what a short
            // read means, when a close happens — are written once and
            // both engines reach them.  The runtime raises the
            // `io_failed` itself, with the path the handle remembers,
            // so all that is left here is the outcome to branch on.
            .file_open => {
                const path, const path_length = try self.textParts(of[0], "path");
                const box = try self.scratch(self.module.value_type, value_alignment, "open.box");
                const opened = try self.fileService(.luce_rt_file_open, &.{
                    path,
                    path_length,
                    self.produced[of[1]].value,
                    box,
                });
                const made = self.function.result_types[register];
                self.produced[register].value = try self.unboxed(made, box, "open.value");
                self.produced[register].box = box;
                self.produced[register].outcome = opened;
            },
            // The transport doors (docs/NETWORK.md), shaped like
            // `file_open`: a handle resource comes back boxed, and a
            // world that says no is an `io_failed` the runtime raised.
            .socket_connect => {
                const host, const host_length = try self.textParts(of[0], "host");
                const box = try self.scratch(self.module.value_type, value_alignment, "connect.box");
                const opened = try self.fileService(.luce_rt_socket_connect, &.{
                    host,
                    host_length,
                    self.produced[of[1]].value,
                    box,
                });
                const made = self.function.result_types[register];
                self.produced[register].value = try self.unboxed(made, box, "connect.value");
                self.produced[register].box = box;
                self.produced[register].outcome = opened;
            },
            .socket_listen => {
                const box = try self.scratch(self.module.value_type, value_alignment, "listen.box");
                const opened = try self.fileService(.luce_rt_socket_listen, &.{
                    self.produced[of[0]].value,
                    box,
                });
                const made = self.function.result_types[register];
                self.produced[register].value = try self.unboxed(made, box, "listen.value");
                self.produced[register].box = box;
                self.produced[register].outcome = opened;
            },
            .socket_accept => {
                const box = try self.scratch(self.module.value_type, value_alignment, "accept.box");
                const opened = try self.fileService(.luce_rt_socket_accept, &.{
                    try self.boxedRegister(of[0], "listener"),
                    box,
                });
                const made = self.function.result_types[register];
                self.produced[register].value = try self.unboxed(made, box, "accept.value");
                self.produced[register].box = box;
                self.produced[register].outcome = opened;
            },
            .socket_port => {
                const port = try self.scratch(.i64, value_alignment, "port.answer");
                self.produced[register].outcome = try self.fileService(.luce_rt_socket_port, &.{
                    try self.boxedRegister(of[0], "listener"),
                    port,
                });
                self.produced[register].value = try self.wip.load(
                    .normal,
                    .i64,
                    port,
                    value_alignment,
                    "port.held",
                );
            },
            .handle_read => {
                const count = try self.scratch(.i64, value_alignment, "read.count");
                self.produced[register].outcome = try self.fileService(.luce_rt_file_read, &.{
                    try self.boxedRegister(of[0], "file"),
                    try self.boxedRegister(of[1], "into"),
                    count,
                });
                self.produced[register].value = try self.wip.load(
                    .normal,
                    .i64,
                    count,
                    value_alignment,
                    "read.filled",
                );
            },
            .handle_write => {
                const count = try self.scratch(.i64, value_alignment, "write.count");
                self.produced[register].outcome = try self.fileService(.luce_rt_file_write, &.{
                    try self.boxedRegister(of[0], "file"),
                    try self.boxedRegister(of[1], "from"),
                    self.produced[of[2]].value,
                    count,
                });
                self.produced[register].value = try self.wip.load(
                    .normal,
                    .i64,
                    count,
                    value_alignment,
                    "write.landed",
                );
            },
            // `t.wait()` — join, and take the worker's answer
            // (docs/THREADS.md D4, D6).  All three endings cross here:
            // a value, an error the task's own shape says may come, and
            // a trap, which is this frame's trap now and unwinds with
            // the worker's frames already in front of its own.
            .task_wait => {
                const result = self.function.result_types[register];
                const out = try self.scratch(
                    self.module.value_type,
                    value_alignment,
                    "wait.result",
                );
                const outcome = try self.callRuntime(.luce_rt_task_wait, .i32, &.{
                    rt,
                    try self.boxedRegister(of[0], "wait.task"),
                    out,
                }, "wait.outcome");
                if (self.taskIsFallible(of[0])) {
                    try self.propagateTrapOnly(outcome);
                    self.produced[register].outcome = outcome;
                } else {
                    try self.propagate(try self.wip.icmp(
                        .ne,
                        outcome,
                        try self.module.builder.intValue(.i32, outcome_ok),
                        "wait.trapped",
                    ));
                }
                self.produced[register].value = try self.unboxed(result, out, "wait.value");
                // The box is kept, not just its contents: a worker may
                // answer text short enough to live *inside* the value,
                // and a fresh box built from the register would say
                // "outside" over a pointer into this box — which reads
                // correctly and frees catastrophically (`storageOf`).
                self.produced[register].box = out;
            },
            .handle_flush => {
                self.produced[register].outcome = try self.fileService(.luce_rt_file_flush, &.{
                    try self.boxedRegister(of[0], "file"),
                });
            },
            .read_line => try self.emitMaybeText(
                register,
                .read_line,
                of[0],
                "line",
            ),
            .env_get => try self.emitMaybeText(register, .env, of[0], "env"),
            .shell_run => try self.emitShellRun(register, of[0]),
            .print_error => {
                const text, const length = try self.textParts(of[0], "diagnostic");
                _ = try self.callHost(.print_error, &.{ text, length }, "reported");
            },
            .clock_ms => {
                self.produced[register].value = try self.callHostNumber(.clock_ms, "clock");
            },
            // The wall clock takes the machine facts' shape and not
            // the monotonic clock's: a host with no calendar answers
            // `no` and the program traps `host_unavailable`, rather
            // than a number being invented for it (`abi.EpochFn`).
            .epoch_ms => {
                self.produced[register].value = try self.callHostFact(.epoch_ms, "epoch");
            },
            .os_total_memory => {
                self.produced[register].value = try self.callHostFact(.os_total_memory, "total");
            },
            .os_available_memory => {
                self.produced[register].value =
                    try self.callHostFact(.os_available_memory, "available");
            },
            .os_cpu_count => {
                self.produced[register].value = try self.callHostFact(.os_cpu_count, "cpus");
            },
            .sleep_ms => {
                // A duration already elapsed is not a bug and not a
                // failure: the host waits no time and answers yes.
                _ = try self.callHost(.sleep_ms, &.{self.produced[of[0]].value}, "slept");
            },
            .exit_program => {
                // The host records the number at the site, while the
                // program is still leaving; the runtime records that
                // the run exited; and the frame leaves on the
                // unwinding edge, exactly as exhaustion does.  Nothing
                // is reported — an exit is not news about a bug.
                try self.enterEffects();
                _ = try self.invokeHost(.exited, &.{self.produced[of[0]].value}, "exited");
                try self.leaveEffects();
                _ = try self.callRuntime(.luce_rt_exit, .void, &.{
                    rt,
                    self.produced[of[0]].value,
                }, "");
                try self.leaveUnwinding();
                self.seek(try self.wip.block(0, "after.exit"));
            },
            // What is at a path (docs/FILESYSTEM.md D16).  The kind
            // comes back in an out-parameter and the `Answer` says
            // only whether the world would look, which is what keeps
            // "nothing is there" a value and "I was not allowed" an
            // error.  The box is cleared first for `emitMaybeText`'s
            // reason: a host that says no leaves it untouched, and
            // the load after the branch must not read the stack.
            .path_kind => {
                const path, const path_length = try self.textParts(of[0], "path");
                const box = try self.scratch(.i64, value_alignment, "kind.code");
                _ = try self.wip.store(
                    .normal,
                    try self.module.builder.intValue(.i64, 0),
                    box,
                    value_alignment,
                );
                const answer = try self.callHost(
                    .path_kind,
                    &.{ path, path_length, box },
                    "kind",
                );
                self.produced[register].outcome = try self.raiseIo(.inspect, answer, path, path_length);
                const kind = try self.wip.load(
                    .normal,
                    .i64,
                    box,
                    value_alignment,
                    "kind.value",
                );
                const below = try self.wip.icmp(
                    .slt,
                    kind,
                    try self.module.builder.intValue(.i64, 0),
                    "kind.below",
                );
                const above = try self.wip.icmp(
                    .sgt,
                    kind,
                    try self.module.builder.intValue(.i64, 3),
                    "kind.above",
                );
                try self.check(
                    try self.wip.bin(.@"or", below, above, "kind.invalid"),
                    .host_unavailable,
                );
                self.produced[register].value = kind;
            },
            .term_rows => {
                self.produced[register].value = try self.callHostNumber(.term_rows, "rows");
            },
            .term_cols => {
                self.produced[register].value = try self.callHostNumber(.term_cols, "cols");
            },
            .term_event_data => {
                self.produced[register].value = try self.callHostNumberWith(
                    .term_event_data,
                    &.{self.produced[of[0]].value},
                    "event.data",
                );
            },
            .term_clear => _ = try self.callHost(.term_clear, &.{}, "cleared"),
            .term_move => _ = try self.callHost(.term_move, &.{
                self.produced[of[0]].value,
                self.produced[of[1]].value,
            }, "moved"),
            .term_style => _ = try self.callHost(.term_style, &.{
                self.produced[of[0]].value,
                self.produced[of[1]].value,
                try self.wip.cast(.zext, self.produced[of[2]].value, .i32, "bold"),
            }, "styled"),
            .term_write => {
                const text, const length = try self.textParts(of[0], "term");
                _ = try self.callHost(.term_write, &.{ text, length }, "wrote");
            },
            .term_copy => {
                const text, const length = try self.textParts(of[0], "term");
                _ = try self.callHost(.term_copy, &.{ text, length }, "copied");
            },
            .term_flush => _ = try self.callHost(.term_flush, &.{}, "flushed"),
            .key_read => {
                // `str?`, and the answer is what decides which.
                // This is where the answer used to be dropped: only
                // `exhausted` was read, so a host saying "no key will
                // ever come" was indistinguishable from one that had
                // not got one yet, and the program asking went round
                // again forever.  `no` is end of input, the same shape
                // `read_line` takes (docs/FAILURE.md).
                const name = try self.hostText("key.name");
                const typed = try self.hostText("key.text");
                // A host that answers no leaves both untouched, and
                // both are read below whichever way it answered.
                try name.clear(self);
                try typed.clear(self);
                const answer = try self.callHost(
                    .key_read,
                    &.{ name.text, name.length, typed.text, typed.length },
                    "key",
                );
                const has_key = try self.saidYes(answer);
                const present = try self.wip.cast(.zext, has_key, .i32, "present");
                // The payload belongs to the run, not to the host's
                // buffer: copy it in before `key_text` can be asked.
                // Cleared, so end of input empties it rather than
                // leaving the last key's text standing.  A dry host
                // leaves a null pointer behind; the runtime's C door
                // quite deliberately rejects null even at length zero,
                // so select the module's canonical non-null empty text
                // on that branch.
                const typed_bytes, const typed_size = try typed.load(self);
                const remembered_bytes = try self.wip.select(
                    .normal,
                    has_key,
                    typed_bytes,
                    (try self.module.textBytes("")).toValue(),
                    "key.text.or.empty",
                );
                const remembered_size = try self.wip.select(
                    .normal,
                    has_key,
                    typed_size,
                    try self.module.builder.intValue(.i64, 0),
                    "key.length.or.zero",
                );
                try self.callChecked(.luce_rt_set_key_text, &.{ rt, remembered_bytes, remembered_size });
                const name_bytes, const name_size = try name.load(self);
                try self.callAnswering(register, .luce_rt_maybe_text, &.{
                    rt,
                    present,
                    name_bytes,
                    name_size,
                });
            },
            .key_text => {
                // The one builtin the host gate does not cover, because
                // it reaches nothing: the text belongs to the run, and a
                // program that never read a key simply gets "".
                const out = try self.scratch(self.module.value_type, value_alignment, "key.text");
                _ = try self.callRuntime(.luce_rt_key_text, .void, &.{ rt, out }, "");
                self.produced[register].value = try self.unboxed(.str, out, "key.text");
            },
        }
    }

    // -- scalar math helpers ---------------------------------------------

    /// Which numeric type a math builtin was given — its own, at its
    /// own width, because `abs`, `min`, `max` and `clamp` answer the
    /// type they were handed and `sqrt` of a `f32` is a `f32`.  The
    /// analyzer admits no other type; naming the rest keeps this file
    /// free of `else` arms.
    fn numeric(self: *Body, operand: mir.Register) Error!types.Type {
        const of = self.function.result_types[operand];
        return switch (of) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64 => of,
            .none,
            .boolean,
            .char,
            .str,
            .bytes,
            .strukt,
            .variant,
            .heap,
            .enumeration,
            .function,
            .optional,
            => self.fail("a math builtin on a type that has none"),
        };
    }

    /// `min` when `wants_minimum`, `max` otherwise.
    ///
    /// Signed integers use `llvm.smin`/`llvm.smax`; unsigned integers
    /// use `llvm.umin`/`llvm.umax`.
    ///
    /// Floating extrema spell out the semantic `operators.pick` in
    /// `libluce_rt` defines: keep the non-NaN operand, answer an ordered
    /// pair by comparison, and order the signs on a tie — `min` is
    /// negative when either zero is, `max` only when both are.  No LLVM
    /// min/max intrinsic is a portable spelling of that sentence:
    /// `minnum`/`maxnum` leave the signed-zero order to the target, and
    /// `minimumnum`/`maximumnum`, which promise it, have an x86-64
    /// lowering that can choose the other zero and even reverse an
    /// ordinary ordered pair (the vectorization it bought is recorded as
    /// parked in docs/CODEGEN.md until that lowering can be trusted).
    fn emitExtremum(
        self: *Body,
        wants_minimum: bool,
        left: Builder.Value,
        right: Builder.Value,
        kind: types.Type,
    ) Error!Builder.Value {
        const width = try self.module.valueType(kind);
        if (kind.isInteger()) {
            return self.wip.callIntrinsic(
                .normal,
                .none,
                if (kind.isUnsigned())
                    if (wants_minimum) .umin else .umax
                else if (wants_minimum)
                    .smin
                else
                    .smax,
                &.{width},
                &.{ left, right },
                "extremum",
            );
        }
        const left_is_nan = try self.wip.fcmp(.normal, .uno, left, left, "left.nan");
        const right_is_nan = try self.wip.fcmp(.normal, .uno, right, right, "right.nan");
        const left_wins = try self.wip.fcmp(
            .normal,
            if (wants_minimum) .ole else .oge,
            left,
            right,
            "left.extremum",
        );
        const ordered = try self.wip.select(.normal, left_wins, left, right, "ordered.extremum");
        const positive_zero = try self.zeroValue(kind);
        const both_zero = try self.wip.bin(
            .@"and",
            try self.wip.fcmp(.normal, .oeq, left, positive_zero, "left.zero"),
            try self.wip.fcmp(.normal, .oeq, right, positive_zero, "right.zero"),
            "both.zero",
        );
        const sign_type = switch (kind) {
            .f16 => Builder.Type.i16,
            .f32 => Builder.Type.i32,
            .f64 => Builder.Type.i64,
            else => unreachable,
        };
        const sign_mask = switch (kind) {
            .f16 => try self.module.builder.intValue(sign_type, @as(i16, @bitCast(@as(u16, 0x8000)))),
            .f32 => try self.module.builder.intValue(sign_type, @as(i32, @bitCast(@as(u32, 0x80000000)))),
            .f64 => try self.module.builder.intValue(sign_type, @as(i64, @bitCast(@as(u64, 0x8000000000000000)))),
            else => unreachable,
        };
        const integer_zero = try self.module.builder.intValue(sign_type, 0);
        const left_negative = try self.wip.icmp(
            .ne,
            try self.wip.bin(
                .@"and",
                try self.wip.cast(.bitcast, left, sign_type, "left.bits"),
                sign_mask,
                "left.sign",
            ),
            integer_zero,
            "left.negative",
        );
        const right_negative = try self.wip.icmp(
            .ne,
            try self.wip.bin(
                .@"and",
                try self.wip.cast(.bitcast, right, sign_type, "right.bits"),
                sign_mask,
                "right.sign",
            ),
            integer_zero,
            "right.negative",
        );
        const negative_zero = switch (kind) {
            .f16 => try self.module.builder.halfValue(@bitCast(@as(u16, 0x8000))),
            .f32 => try self.module.builder.floatValue(@bitCast(@as(u32, 0x80000000))),
            .f64 => try self.module.builder.doubleValue(@bitCast(@as(u64, 0x8000000000000000))),
            else => unreachable,
        };
        const negative_zero_tie = try self.wip.bin(
            if (wants_minimum) .@"or" else .@"and",
            left_negative,
            right_negative,
            "negative.zero",
        );
        const zero = try self.wip.select(.normal, negative_zero_tie, negative_zero, positive_zero, "zero.tie");
        const ordered_or_zero = try self.wip.select(.normal, both_zero, zero, ordered, "zero.extremum");
        const right_is_number = try self.wip.select(.normal, right_is_nan, left, ordered_or_zero, "right.extremum");
        return self.wip.select(.normal, left_is_nan, right, right_is_number, "extremum");
    }

    /// One of the float-only builtins, as its LLVM intrinsic, at the
    /// width its operand arrived at: `llvm.sqrt.f32` exists, and a
    /// `sqrt` of a `f32` answering a `f64` would be a narrowing
    /// waiting to happen at the next store.
    fn emitFloatCall(
        self: *Body,
        intrinsic: Builder.Intrinsic,
        operand: mir.Register,
    ) Error!Builder.Value {
        const of = try self.numeric(operand);
        if (!of.isFloating()) return self.fail("a float builtin applied to an integer");
        return self.wip.callIntrinsic(
            .normal,
            .none,
            intrinsic,
            &.{try self.module.valueType(of)},
            &.{self.produced[operand].value},
            "float",
        );
    }

    /// `new list[T]` / `new map[K, V]` / `new array[T](...)` / `new
    /// builder`. The shape is a compile-time fact, so the kind picks
    /// the entry point and only an array's sizes travel at runtime.
    // -- objects, ownership, and the words a trap carries -----------------

    /// The element zero of the list an intrinsic answers, boxed.
    ///
    /// `m.keys()` and `m.values()` build a list out of values the
    /// runtime is holding, and which *kind* its cells are is a fact of
    /// the program's element type rather than of the code that built
    /// it (`runtime/containers.zig`'s `emptyList`).  So the zero
    /// travels with the call, exactly as it does for `new list[T]`,
    /// and the lowering below may read a list's cells knowing their
    /// width.
    fn answeredZero(self: *Body, register: mir.Register) Error!Builder.Value {
        const of = self.function.result_types[register];
        if (of != .heap) return self.fail("keys or values answering no object");
        const element = switch (self.module.program.heap_types[of.heap]) {
            .list => |written| written,
            .class, .map, .array, .builder, .handle, .task => return self.fail(
                "keys or values answering something other than a list",
            ),
        };
        return self.boxed(element, try self.zeroValue(element), "element.zero");
    }

    fn emitHeapNew(self: *Body, register: mir.Register, new: mir.Instruction.HeapNew) Error!void {
        switch (self.module.program.heap_types[new.heap]) {
            .class => return self.fail("class construction uses its nominal field initializer"),
            .list => |element| try self.callAnswering(register, .luce_rt_new_list, &.{
                self.runtime,
                try self.boxed(element, try self.zeroValue(element), "element.zero"),
            }),
            .map => try self.callAnswering(register, .luce_rt_new_map, &.{self.runtime}),
            // A handle is made by a host door (`file_open`) and by
            // nothing else: `new handle` names no path, and a handle
            // with nothing behind it is the one thing this type must
            // never be able to hold.  Stage 4 refuses it; this is the
            // wall behind that.
            .handle => return self.fail("new handle"),
            // And a task is made by `spawn` and by nothing else, for
            // the same reason: a task with no worker behind it is the
            // one state this type must never hold (docs/THREADS.md D3).
            .task => return self.fail("new task"),
            .builder => try self.callAnswering(register, .luce_rt_new_builder, &.{self.runtime}),
            .array => |shape| {
                const dims = try self.scratchRun(
                    .i64,
                    new.dims.len,
                    Builder.Alignment.fromByteUnits(8),
                    "dims",
                );
                for (new.dims, 0..) |axis, index| {
                    const address = try self.wip.gep(
                        .inbounds,
                        .i64,
                        dims,
                        &.{try self.module.builder.intValue(.i64, index)},
                        "dim.at",
                    );
                    _ = try self.wip.store(
                        .normal,
                        self.produced[axis].value,
                        address,
                        Builder.Alignment.fromByteUnits(8),
                    );
                }
                const zero = try self.boxed(
                    shape.element,
                    try self.zeroValue(shape.element),
                    "element.zero",
                );
                try self.callAnswering(register, .luce_rt_new_array, &.{
                    self.runtime,
                    dims,
                    try self.module.builder.intValue(.i64, new.dims.len),
                    zero,
                });
            },
        }
    }

    /// `trap("...")` reports and unwinds from the middle of a block, so
    /// the rest of the IR block lowers into a fresh block that nothing
    /// branches to.
    fn emitTrapMessage(self: *Body, called: mir.Instruction.IntrinsicCall) Error!void {
        try self.emitTrap(.explicit_trap, self.produced[called.arguments[0]].value);
        self.seek(try self.wip.block(0, "after.trap"));
    }
};
