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
//! define internal i1 @"luce.3.gcd"(ptr %host, ptr %rt, i64 %depth, i64 %0, i64 %1, ptr %out)
//! ```
//!
//! whose `i1` result is the **trapped** flag: true means the program is
//! unwinding, and the caller must return true in turn without reading
//! `%out`.  Traps in Luce are fatal and uncatchable, so the flag only
//! ever travels one way.  A returned value is written through `%out`,
//! which is absent when the function returns nothing.
//!
//! That convention is internal — `internal` linkage, no stability
//! promise — and it was chosen over the zero-cost alternative (a
//! `noreturn` host callback plus `longjmp`) because it needs no
//! platform unwinding machinery and works unchanged on wasm32, which
//! docs/CODEGEN.md names as a required target.
//!
//! `luce_main` (see `abi.zig`) is the one exported wrapper: it opens a
//! runtime, calls the entry function, and turns the flag into a status
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
const mir = @import("../06_mir.zig");
const optimize = @import("../07_optimize.zig");
const loops = @import("loops.zig");
const runtime = @import("../runtime.zig");
const types = @import("../support/types.zig");
const abi = @import("abi.zig");
const artifact = @import("artifact.zig");
const effects = @import("runtime_effects.zig");

const Service = effects.Service;

const Allocator = std.mem.Allocator;
const Builder = std.zig.llvm.Builder;
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
    /// ("intrinsic.map_get", "Float") and is static storage — nothing
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
    /// `{ ptr, i64 }` — how a Luce String travels in generated code.
    string_type: Builder.Type = .none,
    /// `{ i64, i64, i64 }` — `runtime.Value`, how anything travels into
    /// `libluce_rt`.  The layout is asserted against the Zig struct in
    /// `runtime/value.zig`.
    value_type: Builder.Type = .none,

    /// One LLVM function per Luce function, parallel to
    /// `program.functions`.
    functions: []Builder.Function.Index = &.{},

    /// The zero value of each struct layout, as a pointer to a private
    /// constant run of `Value`s.  Built on first use, shared by every
    /// zero-initialized local and array element — safe because struct
    /// storage is never written to after it is built (`struct_set`
    /// allocates a fresh run), which is the same reason the interpreter
    /// shares one template per layout.
    struct_zeros: []?Builder.Constant = &.{},

    /// Interned `{ ptr, i64 }` constants for text, keyed by content.
    /// Keys are borrowed from the program's arena or from static
    /// storage, both of which outlive this module.
    texts: std.StringHashMapUnmanaged(Builder.Constant) = .empty,

    /// Declarations of the `libluce_rt` entry points this module calls,
    /// one slot per `effects.Service`, filled on first use.
    services: std.EnumMap(Service, Builder.Function.Index) = .{},

    /// `llvm.minimumnum.f64` and `llvm.maximumnum.f64`, in that order,
    /// declared on first use (`floatExtremum`).
    float_extrema: [2]?Builder.Function.Index = .{ null, null },

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

    fn deinit(self: *Module) void {
        self.gpa.free(self.functions);
        self.gpa.free(self.struct_zeros);
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
    fn valueType(self: *Module, of: types.Type) Error!Builder.Type {
        return switch (of) {
            .none => .void,
            .boolean => .i1,
            .int => .i64,
            .float => .double,
            .string => self.string_type,
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
            // a `T?` — `look(raw)` against `func look(xs: List(Int)?)`
            // borrows one in without a diagnostic, and the interpreter
            // answers "present" because absence there is the tag, not
            // the payload.  A sentinel would answer "absent" and the
            // two engines would part company.  Int, Float, Bool,
            // String and structs have no spare value to sentinel with
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
            .file_read => builder.fnType(.i32, &.{ .ptr, .ptr, .i64, .ptr, .ptr }, .normal),
            .file_write => builder.fnType(.i32, &.{ .ptr, .ptr, .i64, .ptr, .i64 }, .normal),
            .file_exists => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .arg_count, .term_rows, .term_cols => builder.fnType(.i64, &.{.ptr}, .normal),
            .arg => builder.fnType(.i32, &.{ .ptr, .i64, .ptr, .ptr }, .normal),
            .term_clear, .term_flush => builder.fnType(.i32, &.{.ptr}, .normal),
            .term_move => builder.fnType(.i32, &.{ .ptr, .i64, .i64 }, .normal),
            .term_style => builder.fnType(.i32, &.{ .ptr, .i64, .i64, .i32 }, .normal),
            .term_write => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
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
            .file_append, .file_rename => builder.fnType(
                .i32,
                &.{ .ptr, .ptr, .i64, .ptr, .i64 },
                .normal,
            ),
            .file_delete => builder.fnType(.i32, &.{ .ptr, .ptr, .i64 }, .normal),
            .dir_list => builder.fnType(.i32, &.{ .ptr, .ptr, .i64, .ptr, .ptr }, .normal),
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

    /// `llvm.minimumnum.f64` when `wants_minimum`, `llvm.maximumnum.f64`
    /// otherwise, interned per module.
    ///
    /// These are IEEE 754-2019 `minimumNumber`/`maximumNumber`: the
    /// operand that is a number when the other is NaN, and `-0.0` below
    /// `+0.0` — the one shape of extremum that is fully specified, so
    /// LLVM's constant folder and every target's instruction give the
    /// same answer, which is the property `emitExtremum` needs.
    ///
    /// They are declared by name rather than through
    /// `Builder.Intrinsic`, whose table in the pinned standard library
    /// predates them.  A declaration whose name is an intrinsic's *is*
    /// that intrinsic to LLVM — it recognizes the name on the way in and
    /// attaches the intrinsic's own attributes — so nothing about the
    /// module differs from one the enum could have built.
    fn floatExtremum(self: *Module, wants_minimum: bool) Error!Builder.Function.Index {
        const slot: usize = if (wants_minimum) 0 else 1;
        if (self.float_extrema[slot]) |found| return found;
        const signature_type = try self.builder.fnType(.double, &.{ .double, .double }, .normal);
        const declared = try self.builder.addFunction(
            signature_type,
            try self.builder.strtabString(
                if (wants_minimum) "llvm.minimumnum.f64" else "llvm.maximumnum.f64",
            ),
            .default,
        );
        declared.setLinkage(.external, self.builder);
        self.float_extrema[slot] = declared;
        return declared;
    }

    /// Frame alignment for a value of `of`.  Only types `valueType`
    /// accepts ever reach a frame slot; the rest are named anyway so
    /// this file stays free of `else` arms.
    fn valueAlignment(of: types.Type) Builder.Alignment {
        return switch (of) {
            .boolean => Builder.Alignment.fromByteUnits(1),
            .none,
            .int,
            .float,
            .string,
            .strukt,
            .heap,
            .optional,
            => Builder.Alignment.fromByteUnits(8),
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

    /// A `{ ptr, i64 }` constant for `text` — how a Luce String travels
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
    /// entry per Luce function, in program order, holding its name, the
    /// file it came from, and one `line:column` per instruction
    /// (`runtime/trace.zig`).  Answers a pointer to the table.
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

    /// The retired row a lifted resolution reads for a null handle:
    /// `{ generation = runtime.retired, everything else zero }`.
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
        for (layout.fields) |field| {
            // The analyzer rejects struct cycles, so this bottoms out.
            try fields.append(self.gpa, try self.zeroField(field.field_type));
        }

        const run_type = try self.builder.arrayType(layout.fields.len, self.value_type);
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

    /// One field of a zero struct, as a constant `runtime.Value`.  The
    /// zeroes here are the interpreter's (`Machine.zeroValue`): an empty
    /// String is length zero, and an object-typed field is the null
    /// handle, which traps rather than touching anything.
    fn zeroField(self: *Module, of: types.Type) Error!Builder.Constant {
        const tag: runtime.Tag, const bits: Builder.Constant = switch (of) {
            .none => .{ .none, try self.builder.intConst(.i64, 0) },
            .boolean => .{ .boolean, try self.builder.intConst(.i64, 0) },
            .int => .{ .int, try self.builder.intConst(.i64, 0) },
            .float => .{ .float, try self.builder.intConst(.i64, 0) },
            .string => .{ .string, try self.builder.intConst(.i64, 0) },
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
        };
        const length: u64 = switch (of) {
            .strukt => |nested| self.program.structs[nested].fields.len,
            else => 0,
        };
        // An empty String's zero says its bytes are outside, at the
        // null address, none of them — which reads as `""` and owns
        // nothing, the same value `Value.ofString("")` is.
        const form: u8 = switch (of) {
            .string => runtime.text_outside,
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

        for (self.program.functions, 0..) |*function, index| {
            try self.lowerFunction(function, @intCast(index));
        }
        try self.lowerEntry();
        try self.describeArtifact();
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
    /// `artifact.generator` is stamped and never passed in: it is what
    /// wrote these instructions, so it is this file's answer to give
    /// and no caller's to choose.
    fn describeArtifact(self: *Module) Error!void {
        const tag_type = try self.builder.structType(
            .normal,
            &.{ .i64, .i32, .i32, .ptr, .i64, .i64, .i32, .i32, .i64 },
        );
        const debug_build = for (self.program.functions) |function| {
            if (function.origins.len != 0) break true;
        } else false;
        const initializer = try self.builder.structConst(tag_type, &.{
            try self.builder.intConst(.i64, @as(i64, @bitCast(artifact.magic))),
            try self.builder.intConst(.i32, artifact.format),
            try self.builder.intConst(.i32, abi.version),
            try self.textBytes(artifact.machine),
            try self.builder.intConst(.i64, artifact.machine.len),
            try self.builder.intConst(.i64, @as(i64, @bitCast(self.options.source_hash))),
            try self.builder.intConst(.i32, @intFromBool(debug_build)),
            try self.builder.intConst(.i32, 0),
            try self.builder.intConst(.i64, @as(i64, @bitCast(artifact.generator))),
        });
        const variable = try self.builder.addVariable(
            try self.builder.strtabString(artifact.symbol),
            tag_type,
            .default,
        );
        try variable.setInitializer(initializer, self.builder);
        variable.setMutability(.constant, self.builder);
        variable.ptrConst(self.builder).global.setLinkage(.external, self.builder);
    }

    /// `i1 (ptr host, ptr rt, i64 depth, params..., ptr out?)` — see the
    /// file header.
    fn signature(self: *Module, function: *const mir.Function) Error!Builder.Type {
        var parameters: std.ArrayList(Builder.Type) = .empty;
        defer parameters.deinit(self.gpa);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .ptr);
        try parameters.append(self.gpa, .i64);
        for (function.locals[0..function.parameter_count]) |parameter| {
            try parameters.append(self.gpa, try self.valueType(parameter.local_type));
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
            if (parameter.local_type != .strukt) continue;
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
    fn resultSize(of: types.Type) u32 {
        return switch (of) {
            .boolean => 1,
            .int, .float, .strukt, .heap => 8,
            // `{ ptr, i64 }` — how a String travels.
            .string => 16,
            // `{T, i1}`: the payload, then one byte for the bit,
            // rounded up to the payload's own alignment.  A Bool
            // payload aligns to 1, so `{i1, i1}` really is two bytes —
            // and `dereferenceable` must not claim more than the
            // caller's `alloca` provides.
            .optional => |payload| switch (payload) {
                .boolean => 2,
                .int, .float, .strukt, .heap => 16,
                .string => 24,
            },
            // Never reached: a function returning nothing has no slot.
            .none => 0,
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
        // `func main():` or `func main(args: List(String)):`, and
        // nothing else — stage 4's `checkEntry` is what says so, and
        // this is the shape that survived it (docs/METHODS.md).
        if (entry.parameter_count > 1) return self.fail("an entry function with parameters");
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
                try self.builder.intValue(.i64, self.program.functions.len),
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

        // A host that allows no frames at all refuses the entry
        // function itself, exactly as the interpreter's frame stack
        // does before it pushes anything.  Nothing ran, so the trap
        // carries no trace.
        const refused = try wip.block(1, "too.deep");
        const calling = try wip.block(1, "calling");
        // Two ways in, or three when the command line has to be built:
        // that build is the one thing between the depth check and the
        // call that can run out of memory.
        const ending = try wip.block(if (takes_arguments) 3 else 2, "ended");
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
        // move (OWNERSHIP.md S44, docs/METHODS.md).  A host that
        // supplies neither service yields an empty list; the only way
        // this can fail is running out of memory for the list itself.
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
        _ = try wip.br(ending);

        wip.cursor = .{ .block = ending };
        const outcome = try wip.load(.normal, .i32, outcome_slot, word, "outcome.word");
        // Three answers, and each one is somebody's to hear: a trap
        // with its trace, an error with its raise site, a finished run
        // with its leak census (docs/FAILURE.md).
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
        try self.reportLeaks(
            &wip,
            host,
            context,
            started,
            try wip.bin(.@"or", trapped, errored, "no.census"),
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
    /// and its trace is complete.  A run that ended any other way
    /// reports nothing, which `luce_rt_report` decides for itself — the
    /// branch here only spares a finished run the call.
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

    /// Tell the host what the run did not free, when it has somewhere
    /// to put it and the run finished.  A run that trapped or errored
    /// publishes nothing, so it reports nothing.
    fn reportLeaks(
        self: *Module,
        wip: *Builder.WipFunction,
        host: Builder.Value,
        context: Builder.Value,
        started: Builder.Value,
        trapped: Builder.Value,
    ) Error!void {
        const service_fn = try self.loadHostSlot(wip, host, .finished, "finished.fn");
        const missing = try wip.icmp(
            .eq,
            service_fn,
            try self.builder.nullValue(.ptr),
            "finished.missing",
        );
        const skip = try wip.bin(.@"or", missing, trapped, "no.census");
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
    /// This call's ownership serial, minted in the entry block the
    /// first time a binding needs one.  `.none` until then: a function
    /// that owns nothing never asks for one.
    serial: Builder.Value = .none,

    /// Value produced by each IR register.  A register whose result
    /// type is `.none` keeps `.none` here.  Registers never cross
    /// blocks (the verifier enforces it), so one array per function is
    /// enough.
    values: []Builder.Value = &.{},
    /// The `runtime.Value` each register was read out of, where there
    /// was one: a runtime call's answer slot, an array cell, a struct's
    /// field run, a local's own slot.  `.none` for a register built any
    /// other way.
    ///
    /// It exists because unboxing a String throws away which form its
    /// text was in, and three places need that back: a store into a
    /// slot that owns its storage, which must keep short text short;
    /// `drop_storage`, which must not free a pointer into a frame; and
    /// `export_storage`, which must not transfer one out of the frame
    /// (docs/STRINGS.md).
    ///
    /// The three are reachable only from a register that *has* a box.
    /// A store into an owning slot is preceded by `own_storage` or by
    /// a fresh producer, and both answer into one; the two intrinsics
    /// take their argument from the same place.  What is left without
    /// one — a constant, a parameter, a slice — reaches none of them
    /// without an `own_storage` in between, and `dropped` refuses text
    /// that arrives at the freeing one anyway.
    boxes: []Builder.Value = &.{},
    /// The *outcome* each fallible call or intrinsic answered, kept
    /// beside its value: `2` where it came back errored.  Only the
    /// `errored` that stands beside it ever reads one, and only in the
    /// same block, so this is the whole of the error channel on the
    /// compiled path — no load, no runtime call (docs/CODEGEN.md).
    outcomes: []Builder.Value = &.{},
    /// One entry-block `alloca` per Luce local.
    local_slots: []Builder.Value = &.{},
    /// The first LLVM block of each IR block.  An IR block that
    /// contains a checked operation continues into further LLVM blocks,
    /// which no jump ever targets.
    blocks: []BlockIndex = &.{},

    /// Arrays already resolved in the block being filled, and the axis
    /// lengths they carry.  Both are cleared at every block boundary
    /// and by any instruction `effects.viewStable` refuses.
    views: std.ArrayList(ArrayView) = .empty,
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
        gpa.free(self.values);
        gpa.free(self.boxes);
        gpa.free(self.outcomes);
        gpa.free(self.local_slots);
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

        self.values = try gpa.alloc(Builder.Value, function.instructions.len);
        @memset(self.values, .none);
        self.boxes = try gpa.alloc(Builder.Value, function.instructions.len);
        @memset(self.boxes, .none);
        self.outcomes = try gpa.alloc(Builder.Value, function.instructions.len);
        @memset(self.outcomes, .none);
        self.local_slots = try gpa.alloc(Builder.Value, function.locals.len);
        @memset(self.local_slots, .none);
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
            // A resolved Array is SSA, so it reaches only the blocks
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
                .const_int,
                .const_float,
                .const_string,
                .local_get,
                .local_set,
                .binary,
                .unary,
                .convert,
                .struct_make,
                .struct_get,
                .struct_set,
                .call,
                .intrinsic,
                .heap_new,
                .object_bind,
                .object_unbind,
                => return self.fail("a block without a terminator"),
            }
        }
        return counts;
    }

    /// What a local's slot holds.
    ///
    /// A slot that owns its storage holds a whole `runtime.Value`,
    /// because that is the only shape short text fits in: unbox a
    /// String into `{ptr, i64}` and the form is gone, so a slot that
    /// stored one would be pointing at whatever scratch the runtime
    /// answered into (docs/STRINGS.md).  Every other slot — a
    /// parameter, a spill, anything that borrows — keeps the register
    /// shape it always had, which is what keeps a String parameter's
    /// inner loop two words in registers.
    fn slotType(self: *Body, local: mir.Local) Error!Builder.Type {
        if (local.owns_storage) return self.module.value_type;
        return self.module.valueType(local.local_type);
    }

    fn slotAlignment(local: mir.Local) Builder.Alignment {
        if (local.owns_storage) return value_alignment;
        return Module.valueAlignment(local.local_type);
    }

    /// Entry-block frame: one `alloca` per local, parameters stored in,
    /// every other local zeroed the way the interpreter zeroes it.
    fn emitFrame(self: *Body) Error!void {
        const function = self.function;
        for (function.locals, self.local_slots) |local, *slot| {
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
            const stored = if (index < function.parameter_count)
                self.wip.arg(@intCast(index + 3))
            else if (local.owns_storage)
                // A slot that owns its storage starts empty, not at
                // the shared zero: `structZero` is one constant run
                // per layout, and a release must never hand a shared
                // run back (docs/STRINGS.md).
                try self.emptyValue(local.local_type)
            else
                try self.zeroValue(local.local_type);
            if (local.owns_storage) {
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

    fn zeroValue(self: *Body, of: types.Type) Error!Builder.Value {
        return switch (of) {
            .boolean => .false,
            .int => try self.module.builder.intValue(.i64, 0),
            .float => try self.module.builder.doubleValue(0.0),
            .string => (try self.module.textConstant("")).toValue(),
            // The zero of an object-typed place is the null handle;
            // using it traps rather than touching anything.
            .heap => try self.module.builder.intValue(.i64, runtime.null_index),
            .strukt => |layout| (try self.module.structZero(layout)).toValue(),
            .none => self.fail("a local of type None"),
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
        };
    }

    /// What a slot that owns its storage holds before anything is
    /// stored in it: the same shape, owning nothing, so the release it
    /// is going to get frees nothing (docs/STRINGS.md).  A String's
    /// zero is already empty; a struct's is a null run, which
    /// `luce_rt_drop_storage` answers for.
    fn emptyValue(self: *Body, of: types.Type) Error!Builder.Value {
        return switch (of) {
            .strukt => try self.module.builder.nullValue(.ptr),
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
    /// and the length for everything but a String.  Those are written
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
        return self.boxed(self.function.result_types[register], self.values[register], name);
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

    /// Element `index` of a run, filled with a value the run is going
    /// to **keep**.
    ///
    /// A store must not lose which form a String's text was in, so a
    /// register that was read out of a box is copied across whole, the
    /// way `emitLocalSet` fills a slot that owns its storage; a
    /// register with no box behind it is outside text by construction
    /// and boxes the ordinary way (docs/STRINGS.md).
    fn storedAt(self: *Body, run: Builder.Value, index: usize, register: mir.Register) Error!void {
        const of = self.function.result_types[register];
        if (self.boxes[register] == .none) {
            return self.boxAt(run, index, of, self.values[register]);
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
            self.boxes[register],
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
        return switch (of) {
            .none => .none,
            .boolean => .boolean,
            .int => .int,
            .string => .string,
            .heap => .object,
            .float => .float,
            .strukt => .strukt,
            .optional => self.fail("the tag of a T? read from its type"),
        };
    }

    /// The `bits` word a value of `of` puts in a box.
    fn boxBits(self: *Body, of: types.Type, held: Builder.Value) Error!Builder.Value {
        return switch (of) {
            .none => try self.module.builder.intValue(.i64, 0),
            .boolean => try self.wip.cast(.zext, held, .i64, "box.bits"),
            // A handle already *is* the `bits` word `Value` carries.
            .int, .heap => held,
            .float => try self.wip.cast(.bitcast, held, .i64, "box.bits"),
            .strukt => try self.wip.cast(.ptrtoint, held, .i64, "box.bits"),
            .string => try self.wip.cast(
                .ptrtoint,
                try self.wip.extractValue(held, &.{0}, "box.text"),
                .i64,
                "box.bits",
            ),
            .optional => self.fail("the bits of a T? read from its type"),
        };
    }

    /// The `length` word a value of `of` puts in a box.  Every type but
    /// String has one the type alone decides, which is what lets
    /// `fillBoxShape` write it once in the entry block.
    fn boxLength(self: *Body, of: types.Type, held: Builder.Value) Error!Builder.Value {
        const builder = self.module.builder;
        return switch (of) {
            .none, .boolean, .int, .heap, .float => try builder.intValue(.i64, 0),
            .strukt => |layout| try builder.intValue(
                .i64,
                self.module.program.structs[layout].fields.len,
            ),
            .string => try self.wip.extractValue(held, &.{1}, "box.length"),
            .optional => self.fail("the length of a T? read from its type"),
        };
    }

    /// Whether `of`'s length is settled by the type rather than the
    /// value — true for everything but a String, whose length travels
    /// with its bytes.
    fn boxLengthIsFixed(of: types.Type) bool {
        return of != .string;
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
        // **Generated code never writes inline text.**  A String in a
        // register is `{ptr, i64}` and boxing one says so, which is
        // what keeps a box one store per word; the runtime is the side
        // that decides to inline, at the store sites where it copies
        // anyway (docs/STRINGS.md).  So the form byte is a constant
        // here and rides to the entry block with the tag.
        if (of == .string) {
            try self.storeBoxByte(slot, box_inline_length, try self.outsideText());
        }
        if (boxLengthIsFixed(of)) {
            try self.storeBoxField(slot, box_length, try self.boxLength(of, .none));
        }
    }

    fn outsideText(self: *Body) Error!Builder.Value {
        return self.module.builder.intValue(.i8, runtime.text_outside);
    }

    /// The word — or, for a String, the two words — that carry the
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
        // a value that is not text, so a present String's constant
        // serves for both.
        if (of == .string) {
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
    fn unboxed(self: *Body, of: types.Type, slot: Builder.Value, name: []const u8) Error!Builder.Value {
        if (of == .none) return .none;
        if (of == .optional) return self.unboxedOptional(of.optional, slot, name);
        const bits = try self.loadBoxField(slot, box_bits, "unbox.bits");
        return switch (of) {
            .int, .heap => bits,
            .boolean => try self.wip.icmp(
                .ne,
                bits,
                try self.module.builder.intValue(.i64, 0),
                name,
            ),
            .float => try self.wip.cast(.bitcast, bits, .double, name),
            .string => try self.unboxedText(slot, bits, name),
            // The field count is a compile-time fact, so only the
            // address of the run travels back.
            .strukt => try self.wip.cast(.inttoptr, bits, .ptr, name),
            .none, .optional => unreachable, // answered above
        };
    }

    /// The `{ptr, i64}` a String travels in, read out of a box in
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

    /// This call's ownership serial, minted once in the entry block.
    fn frameSerial(self: *Body) Error!Builder.Value {
        if (self.serial != .none) return self.serial;
        const resume_at = self.wip.cursor;
        const filled = self.entry_block.ptr(self.wip).instructions.items.len;
        std.debug.assert(filled > 0);
        self.wip.cursor = .{ .block = self.entry_block, .instruction = @intCast(filled - 1) };
        self.serial = try self.module.callService(
            self.wip,
            .luce_rt_serial,
            .i64,
            &.{self.runtime},
            "serial",
        );
        self.wip.cursor = resume_at;
        return self.serial;
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
        self.values[register] = try self.unboxed(
            self.function.result_types[register],
            out,
            "rt.value",
        );
        // This slot belongs to this call site alone and nothing writes
        // it again before the register dies, so it is the box the
        // register was read from.
        self.boxes[register] = out;
    }

    /// The subscripts of one indexing operation, as a run of boxed
    /// values, plus how many there are.
    fn subscripts(self: *Body, of: []const mir.Register) Error!struct { Builder.Value, Builder.Value } {
        const run = try self.scratchRun(
            self.module.value_type,
            of.len,
            value_alignment,
            "indices",
        );
        for (of, 0..) |register, index| {
            try self.boxAt(
                run,
                index,
                self.function.result_types[register],
                self.values[register],
            );
        }
        return .{ run, try self.module.builder.intValue(.i64, of.len) };
    }

    // -- Arrays, without the runtime call ---------------------------------
    //
    // `a[i]`, `grid[r, c]`, and `len(a)` on an `Array` are generated
    // here rather than called: the object table row, the bounds check,
    // and the element load, inline.  A call cannot be: a boxed
    // subscript is a store the loop cannot hoist, so the call stays
    // pinned inside the loop however precisely it is described
    // (docs/CODEGEN.md).
    //
    // Two facts make it sound.  The program already knows the target is
    // an Array and what it holds — `heap_types` says so, statically —
    // so the runtime's four-way switch on the object's kind has one
    // arm left at compile time.  And an Array's `dims` and `elements`
    // never move while it lives: only the row's generation changes,
    // which is why this is the container the inline path starts with
    // and a List, whose buffer moves under `append`, is still a call.
    //
    // The offsets come from `runtime.layout`, measured from the Zig
    // types with `@offsetOf` and checked against a real `Runtime` by a
    // test beside them.

    /// The shape of the Array a register holds, or null when it holds
    /// anything else — a List, a Map, a Builder, or no object at all.
    const ArrayShape = struct { element: types.Type, rank: u8 };

    fn arrayShape(self: *Body, register: mir.Register) ?ArrayShape {
        const of = self.function.result_types[register];
        if (of != .heap) return null;
        return switch (self.module.program.heap_types[of.heap]) {
            .array => |shape| .{ .element = shape.element, .rank = shape.rank },
            .list, .map, .builder => null,
        };
    }

    /// Whether an element of type `of` can be written in place.
    ///
    /// A store into a container frees the element it replaced and
    /// adopts the one arriving (S20, S22).  Neither happens for a
    /// scalar, so those write inline; anything that owns something —
    /// an object, and since copy-on-store a String's bytes or a
    /// struct's field run (docs/STRINGS.md) — goes on calling the
    /// runtime, which is the one place that walk is written.
    ///
    /// A *read* stays inline whatever the element type: reading an
    /// element is a borrow of it, and borrows own nothing.
    fn ownsNothing(of: types.Type) bool {
        return switch (of) {
            .boolean, .int, .float => true,
            .none, .string, .strukt, .heap, .optional => false,
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

    /// The row's generation is not the handle's, so the object the
    /// handle names is gone — whether or not somebody else has since
    /// moved into the row.  One load and one compare, which is what it
    /// cost when a row was retained forever.
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
    }

    fn resolveRow(self: *Body, register: mir.Register) Error!Builder.Value {
        const builder = self.module.builder;
        const parts = try self.handleParts(self.values[register]);
        try self.checkHandle(parts.index);

        const table = try self.wip.load(
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

        try self.checkOccupant(try self.wip.load(
            .normal,
            .i32,
            try self.byteOffset(row, runtime.layout.generation, "generation.at"),
            Builder.Alignment.fromByteUnits(4),
            "generation",
        ), parts.generation);
        return row;
    }

    /// One Array, resolved: the element base and one axis length per
    /// rank, all as SSA values.
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
    const ArrayView = struct {
        /// The MIR register whose handle this resolves.
        register: mir.Register,
        /// `Object.array.dims.ptr`, or `.none` for a rank-1 array,
        /// which never reads it: its one bound is `Object.array.count`,
        /// a word in the row rather than a word behind a pointer in
        /// the row.  That saved load is not a micro-optimization — the
        /// dependent load is what stops LLVM's loop unswitching, and
        /// with it the vectorizer, on the loop around the access.
        dims: Builder.Value,
        /// `Object.array.elements.ptr`, indexed as the element kind's
        /// own cell type.
        elements: Builder.Value,
        /// Where this view's axis lengths start in `view_bounds`.
        bounds_at: u32,
        rank: u8,

        fn bounds(self: ArrayView, body: *const Body) []const Builder.Value {
            return body.view_bounds.items[self.bounds_at..][0..self.rank];
        }
    };

    /// The LLVM type one cell of an `Array(element)` is.
    ///
    /// It mirrors `runtime.Object.ElementKind`, which is what the
    /// runtime actually allocates: an `Array(Float)` is `f64`s, so
    /// reading one is a `load double` and nothing else.  The two are
    /// held together by the byte-offset test in `runtime/test.zig`,
    /// which reads a Float array's element as an `f64`.
    fn cellType(self: *Body, element: types.Type) Builder.Type {
        return switch (element) {
            .float => .double,
            .int => .i64,
            .boolean => .i8,
            // Everything whose tag or length is not settled by the
            // type keeps the 24-byte slot.
            .none, .string, .strukt, .heap, .optional => self.module.value_type,
        };
    }

    fn cellAlignment(element: types.Type) Builder.Alignment {
        return switch (element) {
            .boolean => Builder.Alignment.fromByteUnits(1),
            .none,
            .int,
            .float,
            .string,
            .strukt,
            .heap,
            .optional,
            => Builder.Alignment.fromByteUnits(8),
        };
    }

    /// One resolution the preheader of a loop already made: the row's
    /// three facts, read once for the whole loop.
    const Hoisted = struct {
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
            const table = try self.wip.load(
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
                .bounds_at = @intCast(self.hoist_bounds.items.len),
                .generation = try self.wip.load(
                    .normal,
                    .i32,
                    try self.byteOffset(row, runtime.layout.generation, "generation.at"),
                    Builder.Alignment.fromByteUnits(4),
                    "generation",
                ),
                .elements = try self.wip.load(
                    .normal,
                    .ptr,
                    try self.byteOffset(row, runtime.layout.array_elements, "elements.at"),
                    pointer_alignment,
                    "elements",
                ),
            };
            if (hoist.rank == 1) {
                try self.hoist_bounds.append(gpa, try self.wip.load(
                    .normal,
                    .i64,
                    try self.byteOffset(row, runtime.layout.array_count, "count.at"),
                    value_alignment,
                    "count",
                ));
            } else {
                made.dims = try self.wip.load(
                    .normal,
                    .ptr,
                    try self.byteOffset(row, runtime.layout.array_dims, "dims.at"),
                    pointer_alignment,
                    "dims",
                );
                for (0..hoist.rank) |axis| {
                    try self.hoist_bounds.append(gpa, try self.wip.load(
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

    /// The Array in `register`, resolved — reusing the resolution
    /// already made in this block if there is one.
    fn arrayView(self: *Body, register: mir.Register, shape: ArrayShape) Error!ArrayView {
        for (self.views.items) |found| {
            if (found.register == register) return found;
        }
        const gpa = self.module.gpa;
        if (self.liftedView(register)) |index| {
            // The loads happened in the preheader; the checks happen
            // here, which is what keeps the trap where it belongs.
            const parts = try self.handleParts(self.values[register]);
            try self.checkHandle(parts.index);
            try self.checkOccupant(self.hoisted[index].generation, parts.generation);
            const made: ArrayView = .{
                .register = register,
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
            // *is* that axis — one load nearer than `dims[0]`.
            try self.view_bounds.append(gpa, try self.wip.load(
                .normal,
                .i64,
                try self.byteOffset(row, runtime.layout.array_count, "count.at"),
                value_alignment,
                "count",
            ));
        } else {
            dims = try self.wip.load(
                .normal,
                .ptr,
                try self.byteOffset(row, runtime.layout.array_dims, "dims.at"),
                pointer_alignment,
                "dims",
            );
            for (0..shape.rank) |axis| {
                try self.view_bounds.append(gpa, try self.wip.load(
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
        const made: ArrayView = .{
            .register = register,
            .dims = dims,
            .elements = try self.wip.load(
                .normal,
                .ptr,
                try self.byteOffset(row, runtime.layout.array_elements, "elements.at"),
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
    fn arrayElement(
        self: *Body,
        view: ArrayView,
        element: types.Type,
        indices: []const mir.Register,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        var flat = try builder.intValue(.i64, 0);
        for (indices, view.bounds(self)) |register, size| {
            const index = self.values[register];
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
    fn loadCell(self: *Body, element: types.Type, address: Builder.Value) Error!Builder.Value {
        return switch (element) {
            .float, .int => try self.wip.load(
                .normal,
                self.cellType(element),
                address,
                cellAlignment(element),
                "element",
            ),
            .boolean => try self.wip.icmp(
                .ne,
                try self.wip.load(.normal, .i8, address, cellAlignment(element), "cell"),
                try self.module.builder.intValue(.i8, 0),
                "element",
            ),
            // A boxed cell: the tag and the length are already the
            // element type's, so only the payload words are read.
            .none, .string, .strukt, .heap, .optional => try self.unboxed(
                element,
                address,
                "element",
            ),
        };
    }

    /// Write one cell.  The element type is the same for every slot, so
    /// a typed cell takes the payload as it stands and a boxed one
    /// keeps the tag and length `new` wrote.
    fn storeCell(
        self: *Body,
        element: types.Type,
        address: Builder.Value,
        held: Builder.Value,
    ) Error!void {
        switch (element) {
            .float, .int => _ = try self.wip.store(
                .normal,
                held,
                address,
                cellAlignment(element),
            ),
            .boolean => _ = try self.wip.store(
                .normal,
                try self.wip.cast(.zext, held, .i8, "cell"),
                address,
                cellAlignment(element),
            ),
            .none, .string, .strukt, .heap, .optional => try self.fillBoxValue(
                address,
                element,
                held,
            ),
        }
    }

    /// `len(a)` on an Array: the first axis.
    fn emitArrayLength(
        self: *Body,
        register: mir.Register,
        target: mir.Register,
        shape: ArrayShape,
    ) Error!void {
        if (shape.rank == 0) {
            self.values[register] = try self.module.builder.intValue(.i64, 0);
            return;
        }
        const view = try self.arrayView(target, shape);
        self.values[register] = view.bounds(self)[0];
    }

    /// `a.dim(k)` on an Array.  The rank is a compile-time fact, so the
    /// axis check is against a constant.
    fn emitArrayDimSize(
        self: *Body,
        register: mir.Register,
        target: mir.Register,
        axis: mir.Register,
        shape: ArrayShape,
    ) Error!void {
        const builder = self.module.builder;
        const view = try self.arrayView(target, shape);
        const wanted = self.values[axis];
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
            self.values[register] = view.bounds(self)[0];
            return;
        }
        self.values[register] = try self.wip.load(
            .normal,
            .i64,
            try self.wip.gep(.inbounds, .i64, view.dims, &.{wanted}, "dim.at"),
            value_alignment,
            "dim",
        );
    }

    // -- Strings, without the runtime call --------------------------------
    //
    // A String already travels through generated code as an unboxed
    // `{ ptr, i64 }`, so `len`, `byte_at` and a slice are a compare and
    // a load — and boxing one to ask the runtime for it costs more than
    // the answer.  These are the same three checks `runtime/text.zig`
    // makes, in the same order, so the trap a bad index raises is the
    // same trap with the same words.

    /// Trap unless `index` falls between UTF-8 sequences: `index ==
    /// length`, or a byte that is not a continuation.
    /// `text.isStringBoundary`, inline — **including its
    /// short-circuit**, which is not decoration: the end of a String is
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
        ), .string_boundary);
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
        const index = self.values[index_register];
        const below = try self.wip.icmp(.slt, index, try builder.intValue(.i64, 0), "below");
        const above = try self.wip.icmp(.sge, index, length, "above");
        try self.check(
            try self.wip.bin(.@"or", below, above, "out.of.range"),
            .string_bounds,
        );
        self.values[register] = try self.wip.cast(.zext, try self.wip.load(
            .normal,
            .i8,
            try self.wip.gep(.inbounds, .i8, text, &.{index}, "byte.at"),
            Builder.Alignment.fromByteUnits(1),
            "byte",
        ), .i64, "byte.value");
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
        const first = self.values[from];
        const end = self.values[to];
        const below = try self.wip.icmp(.slt, first, try builder.intValue(.i64, 0), "below");
        const inverted = try self.wip.icmp(.slt, end, first, "inverted");
        const past = try self.wip.icmp(.sgt, end, length, "past.end");
        try self.check(try self.wip.bin(
            .@"or",
            below,
            try self.wip.bin(.@"or", inverted, past, "misordered"),
            "out.of.range",
        ), .string_bounds);
        try self.checkBoundary(text, length, first);
        try self.checkBoundary(text, length, end);
        self.values[register] = try self.wip.buildAggregate(self.module.string_type, &.{
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
        const answer = try self.invokeHost(slot, arguments, name);
        try self.checkExhausted(answer);
        return answer;
    }

    /// Call a host service that answers a plain number and cannot fail
    /// — a screen size, an argument count.
    fn callHostNumber(self: *Body, slot: abi.Slot, name: []const u8) Error!Builder.Value {
        return self.invokeHost(slot, &.{}, name);
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
        const negative = try self.wip.icmp(
            .slt,
            answer,
            try self.module.builder.intValue(.i32, 0),
            "host.exhausted",
        );
        const giving_up = try self.wip.block(1, "exhausted");
        const surviving = try self.wip.block(1, "served");
        _ = try self.wip.brCond(negative, giving_up, surviving, .else_likely);
        self.seek(giving_up);
        _ = try self.callRuntime(.luce_rt_exhaust, .void, &.{self.runtime}, "");
        _ = try self.wip.ret(try self.module.builder.intValue(.i32, outcome_trapped));
        self.seek(surviving);
    }

    /// `file_read`, whose two outcomes do genuinely different things:
    /// only the side the host said yes on has bytes to intern, and
    /// reading the out-parameters on the other side would read
    /// whatever was on the stack.  So the branch comes first and the
    /// two answers meet in a slot.
    fn emitFileRead(self: *Body, register: mir.Register, path_register: mir.Register) Error!void {
        const builder = self.module.builder;
        const flag = Builder.Alignment.fromByteUnits(4);
        const path, const path_length = try self.textParts(path_register, "path");
        const content = try self.hostText("read");
        const answer = try self.callHost(
            .file_read,
            &.{ path, path_length, content.text, content.length },
            "read",
        );

        // One box, filled on both sides.  It has to be a whole
        // `runtime.Value` rather than the register shape because the
        // text the host handed over may be short enough to live in the
        // value, and a caller carrying this result across the branch on
        // its outcome copies the box, not the register
        // (docs/STRINGS.md).
        const box = try self.scratch(self.module.value_type, value_alignment, "read.box");
        const outcome_slot = try self.scratch(.i32, flag, "read.outcome");
        const failing = try self.wip.block(1, "read.failed");
        const reading = try self.wip.block(1, "read.ok");
        const done = try self.wip.block(2, "read.done");
        _ = try self.wip.brCond(try self.saidNo(answer), failing, reading, .else_likely);

        self.seek(failing);
        try self.emitRaiseIo(.read, path, path_length);
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_errored), outcome_slot, flag);
        // The `errored` beside this call branches away before anything
        // reads the value — but the box is still copied into whatever
        // carries it, so it holds the empty String rather than
        // whatever was on the stack.
        try self.fillBoxShape(box, .string);
        try self.fillBoxValue(box, .string, (try self.module.textConstant("")).toValue());
        _ = try self.wip.br(done);

        self.seek(reading);
        const bytes, const size = try content.load(self);
        try self.callChecked(.luce_rt_intern_text, &.{ self.runtime, bytes, size, box });
        _ = try self.wip.store(.normal, try builder.intValue(.i32, outcome_ok), outcome_slot, flag);
        _ = try self.wip.br(done);

        self.seek(done);
        self.values[register] = try self.unboxed(.string, box, "read.value");
        self.boxes[register] = box;
        self.outcomes[register] = try self.wip.load(.normal, .i32, outcome_slot, flag, "read.outcome");
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
    /// String and hand back a `String?`.
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

    /// `dir_list(path)` — the names the host joined, as the
    /// `List(String)` the program asked for.
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
        self.values[register] = try self.unboxed(listed, box, "list.value");
        self.boxes[register] = box;
        self.outcomes[register] = try self.wip.load(.normal, .i32, outcome_slot, flag, "list.outcome");
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

    /// The address and length of the String in `register`, as the two
    /// arguments a host service takes.
    fn textParts(
        self: *Body,
        register: mir.Register,
        name: []const u8,
    ) Error!struct { Builder.Value, Builder.Value } {
        const held = self.values[register];
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
                self.values[register] = if (value) .true else .false;
            },
            .const_int => |value| {
                self.values[register] = try self.module.builder.intValue(.i64, value);
            },
            .const_float => |value| {
                self.values[register] = try self.module.builder.doubleValue(value);
            },
            .const_string => |constant| {
                const text = self.module.program.constants[constant];
                self.values[register] = (try self.module.textConstant(text)).toValue();
            },
            .local_get => |local| {
                const held = self.function.locals[local];
                const slot = self.local_slots[local];
                if (held.owns_storage) {
                    self.values[register] = try self.unboxed(
                        held.local_type,
                        slot,
                        "local.get",
                    );
                    self.boxes[register] = slot;
                    return;
                }
                self.values[register] = try self.wip.load(
                    .normal,
                    try self.module.valueType(held.local_type),
                    slot,
                    Module.valueAlignment(held.local_type),
                    "local.get",
                );
            },
            .local_set => |set| try self.emitLocalSet(set.local, set.value),
            .binary => |operation| try self.emitBinary(register, operation),
            .unary => |operation| try self.emitUnary(register, operation),
            .convert => |operation| try self.emitConvert(register, operation.kind, operation.operand),
            .struct_make => |make| try self.emitStructMake(register, make.layout, make.fields),
            .struct_get => |get| {
                const layout = self.module.program.structs[get.layout];
                const address = try self.wip.gep(
                    .inbounds,
                    self.module.value_type,
                    self.values[get.target],
                    &.{try self.module.builder.intValue(.i64, get.field)},
                    "field.at",
                );
                self.values[register] = try self.unboxed(
                    layout.fields[get.field].field_type,
                    address,
                    "field",
                );
                self.boxes[register] = address;
            },
            .struct_set => |set| try self.callAnswering(register, .luce_rt_struct_set, &.{
                self.runtime,
                try self.boxedRegister(set.target, "target"),
                try self.module.builder.intValue(.i64, set.field),
                try self.storageOf(set.value),
            }),
            .call => |called| try self.emitCall(register, called),
            .intrinsic => |called| try self.emitIntrinsic(register, called),
            .heap_new => |new| try self.emitHeapNew(register, new),
            .object_bind => |bind| try self.emitOwnership(.luce_rt_bind, bind.value, bind.local),
            .object_unbind => |unbind| try self.emitOwnership(
                .luce_rt_unbind,
                unbind.value,
                unbind.local,
            ),
            .jump => |target| {
                _ = try self.wip.br(self.blocks[target]);
            },
            .branch => |taken| {
                _ = try self.wip.brCond(
                    self.values[taken.condition],
                    self.blocks[taken.then_block],
                    self.blocks[taken.else_block],
                    .none,
                );
            },
            .ret => |value| {
                if (value) |returned| {
                    // Whatever this frame still owned in the returned
                    // value moves to the caller (S16): loose until
                    // something there binds it.  A struct is walked too,
                    // because its fields may hold objects.
                    if (self.function.return_type == .heap or
                        self.function.return_type == .strukt)
                    {
                        _ = try self.callRuntime(.luce_rt_loosen_from_frame, .void, &.{
                            self.runtime,
                            try self.boxedRegister(returned, "returned"),
                            try self.frameSerial(),
                        }, "");
                    }
                    _ = try self.wip.store(
                        .normal,
                        self.values[returned],
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
    /// a String's form has to survive the store: if the register was
    /// read out of a box, the twenty-four bytes are copied across
    /// whole, so short text stays short and long text keeps pointing
    /// where it did.  A register with no box behind it is outside text
    /// by construction — a constant, a parameter, a slice, a callee's
    /// result — and is boxed the ordinary way (docs/STRINGS.md).
    fn emitLocalSet(self: *Body, local: mir.LocalId, value: mir.Register) Error!void {
        const held = self.function.locals[local];
        const slot = self.local_slots[local];
        if (!held.owns_storage) {
            _ = try self.wip.store(
                .normal,
                self.values[value],
                slot,
                Module.valueAlignment(held.local_type),
            );
            return;
        }
        if (self.boxes[value] != .none) {
            _ = try self.wip.callMemCpy(
                slot,
                value_alignment,
                self.boxes[value],
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
        try self.fillBoxValue(slot, held.local_type, self.values[value]);
    }

    // -- conversion and struct values ----------------------------------

    /// `Float(x)` widens; `Int(x)` **rounds half away from zero** and
    /// traps outside the i64 range, NaN and the infinities included
    /// (docs/NUMERICS.md §7).  The guards are the interpreter's, value
    /// for value (`runtime/operators.zig`), because a conversion that
    /// disagrees at the boundary is a different language — and so is
    /// the rounding, which is `llvm.round`, the intrinsic whose
    /// definition *is* "half away from zero".  The range check runs
    /// before the rounding, so a value rounding would push past 2^63
    /// is refused rather than wrapped.
    fn emitConvert(
        self: *Body,
        register: mir.Register,
        kind: mir.ConvertKind,
        operand: mir.Register,
    ) Error!void {
        const held = self.values[operand];
        switch (kind) {
            .int_to_float => {
                self.values[register] = try self.wip.cast(.sitofp, held, .double, "float");
            },
            .float_to_int => {
                const builder = self.module.builder;
                const rounded = try self.wip.callIntrinsic(
                    .normal,
                    .none,
                    .round,
                    &.{.double},
                    &.{held},
                    "rounded",
                );
                // NaN compares unordered with itself and with the
                // bounds, so it has to be asked about separately.
                const not_a_number = try self.wip.fcmp(.normal, .uno, rounded, rounded, "is.nan");
                const too_small = try self.wip.fcmp(
                    .normal,
                    .olt,
                    rounded,
                    try builder.doubleValue(-9223372036854775808.0),
                    "too.small",
                );
                const too_large = try self.wip.fcmp(
                    .normal,
                    .oge,
                    rounded,
                    try builder.doubleValue(9223372036854775808.0),
                    "too.large",
                );
                const outside = try self.wip.bin(
                    .@"or",
                    not_a_number,
                    try self.wip.bin(.@"or", too_small, too_large, "off.scale"),
                    "unrepresentable",
                );
                try self.check(outside, .conversion_range);
                self.values[register] = try self.wip.cast(.fptosi, rounded, .i64, "int");
            },
        }
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
            try self.storedAt(run, index, field);
        }
        try self.callAnswering(register, .luce_rt_struct_make, &.{
            self.runtime,
            run,
            try self.module.builder.intValue(.i64, shape.fields.len),
        });
    }

    // -- arithmetic and comparison -------------------------------------

    fn emitBinary(self: *Body, register: mir.Register, operation: mir.Instruction.Binary) Error!void {
        const left = self.values[operation.left];
        const right = self.values[operation.right];
        if (operation.op.isComparison()) {
            self.values[register] = try self.emitCompare(operation, left, right);
            return;
        }
        switch (operation.operand_type) {
            .int => self.values[register] = try self.emitIntArithmetic(operation.op, left, right),
            .float => self.values[register] = try self.emitFloatArithmetic(
                operation.op,
                left,
                right,
            ),
            // The analyzer only admits + for strings, and the joined
            // bytes come from the runtime's arena.
            .string => try self.callAnswering(register, .luce_rt_concat, &.{
                self.runtime,
                try self.boxedRegister(operation.left, "left"),
                try self.boxedRegister(operation.right, "right"),
            }),
            .none,
            .boolean,
            .strukt,
            .heap,
            .optional,
            => return self.fail("arithmetic on a type that has none"),
        }
    }

    fn emitIntArithmetic(
        self: *Body,
        operation: mir.BinaryOp,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        switch (operation) {
            .add => return self.emitChecked(.@"sadd.with.overflow", left, right),
            .subtract => return self.emitChecked(.@"ssub.with.overflow", left, right),
            .multiply => return self.emitChecked(.@"smul.with.overflow", left, right),
            // `/` is real division and always answers a Float, so an
            // integer one is IR the verifier already refused
            // (docs/NUMERICS.md §2).
            .divide => return self.fail("integer division, which the language does not have"),
            // `//` and `%` floor together (docs/NUMERICS.md §3).  The
            // chip only offers the truncating pair, so each gets the
            // one correction that turns it into the flooring one, and
            // both corrections fire on the same condition: the true
            // quotient was negative and did not divide evenly.
            .floor_divide, .modulo => {
                try self.checkDivisor(left, right);
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
                return self.correctToFloor(operation, truncated, remainder, right);
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
        truncated: Builder.Value,
        remainder: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const builder = self.module.builder;
        const zero = try builder.intValue(.i64, 0);
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
            try self.wip.bin(.sub, truncated, try builder.intValue(.i64, 1), "floored")
        else
            try self.wip.bin(.add, remainder, right, "modded");
        return self.wip.select(.normal, needs, corrected, truncated, "int");
    }

    /// Float arithmetic is plain IEEE 754 and never traps: division by
    /// zero and overflow produce infinities and NaN, exactly as they do
    /// in the interpreter.
    ///
    /// Two of the six are not one instruction.  `%` is the **floor**
    /// modulus, pairing with `//` so that promotion introduces no
    /// discontinuity (docs/NUMERICS.md §3), and it is neither `frem`
    /// nor any host `fmod`: it goes to `libluce_rt`, so there is one
    /// implementation of a rule with a zero case and a sign
    /// correction in it.  `//` is `floor(a / b)` and that really is
    /// two instructions, so it stays here.
    fn emitFloatArithmetic(
        self: *Body,
        operation: mir.BinaryOp,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        switch (operation) {
            .modulo => return self.callRuntime(
                .luce_rt_float_mod,
                .double,
                &.{ left, right },
                "float",
            ),
            .floor_divide => {
                const quotient = try self.wip.bin(.fdiv, left, right, "quotient");
                return self.wip.callIntrinsic(
                    .normal,
                    .none,
                    .floor,
                    &.{.double},
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
            .equal,
            .not_equal,
            .less,
            .less_equal,
            .greater,
            .greater_equal,
            => return self.fail("a comparison on the arithmetic path"),
        };
        return self.wip.bin(tag, left, right, "float");
    }

    /// `llvm.s*.with.overflow`, then the trap the interpreter raises.
    fn emitChecked(
        self: *Body,
        intrinsic: Builder.Intrinsic,
        left: Builder.Value,
        right: Builder.Value,
    ) Error!Builder.Value {
        const pair = try self.wip.callIntrinsic(
            .normal,
            .none,
            intrinsic,
            &.{.i64},
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
    fn checkDivisor(self: *Body, left: Builder.Value, right: Builder.Value) Error!void {
        const builder = self.module.builder;
        const zero = try builder.intValue(.i64, 0);
        try self.check(try self.wip.icmp(.eq, right, zero, "by.zero"), .divide_by_zero);

        const smallest = try builder.intValue(.i64, std.math.minInt(i64));
        const negative_one = try builder.intValue(.i64, -1);
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
        // Float comparison is ordered except for `!=`, which is true
        // whenever the two are not equal — NaN included.  That is what
        // Zig's operators mean in `runtime/operators.zig`.
        if (operation.operand_type == .float) {
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
                => return self.fail("arithmetic on the comparison path"),
            };
            return self.wip.fcmp(.normal, condition, left, right, "compare");
        }

        // String and struct comparison are content, not address: the
        // runtime owns both, and a struct comparison recurses into
        // nested fields rather than comparing the slots that hold them.
        if (operation.operand_type == .string or operation.operand_type == .strukt) {
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

        const condition: Builder.IntegerCondition = switch (operation.operand_type) {
            .int => switch (operation.op) {
                .equal => .eq,
                .not_equal => .ne,
                .less => .slt,
                .less_equal => .sle,
                .greater => .sgt,
                .greater_equal => .sge,
                .add,
                .subtract,
                .multiply,
                .divide,
                .floor_divide,
                .modulo,
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
                .add,
                .subtract,
                .multiply,
                .divide,
                .floor_divide,
                .modulo,
                => return self.fail("arithmetic on the comparison path"),
            },
            .float, .string, .strukt => unreachable, // answered above
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
        const operand = self.values[operation.operand];
        switch (operation.op) {
            .logic_not => {
                self.values[register] = try self.wip.bin(.xor, operand, .true, "not");
            },
            .negate => switch (self.function.result_types[operation.operand]) {
                .int => {
                    const zero = try self.module.builder.intValue(.i64, 0);
                    self.values[register] = try self.emitChecked(
                        .@"ssub.with.overflow",
                        zero,
                        operand,
                    );
                },
                // A true sign-bit flip, not `0.0 - x`: the two differ
                // for +0.0, and the deleted x86 backend got it wrong.
                .float => {
                    self.values[register] = try self.wip.un(.fneg, operand, "neg");
                },
                .none,
                .boolean,
                .string,
                .strukt,
                .heap,
                .optional,
                => return self.fail("negation of a type that has none"),
            },
        }
    }

    // -- calls -----------------------------------------------------------

    fn emitCall(self: *Body, register: mir.Register, called: mir.Instruction.Call) Error!void {
        const gpa = self.module.gpa;
        const target = self.module.functions[called.function];
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
        for (called.arguments) |argument| {
            try arguments.append(gpa, self.values[argument]);
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
        if (self.module.program.functions[called.function].fallible) {
            try self.propagateTrapOnly(outcome);
            self.outcomes[register] = outcome;
        } else {
            try self.propagate(try self.wip.icmp(
                .ne,
                outcome,
                try self.module.builder.intValue(.i32, outcome_ok),
                "trapped",
            ));
        }

        if (result != .none) {
            self.values[register] = try self.wip.load(
                .normal,
                try self.module.valueType(result),
                result_slot,
                Module.valueAlignment(result),
                "call.value",
            );
        }
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
    /// Boxing an unboxed String says its text is outside, because that
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
        if (self.boxes[register] == .none and
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
        if (self.boxes[register] != .none) return self.boxes[register];
        return self.boxedRegister(register, "held");
    }

    /// Whether a value of this type can be text in its own right — the
    /// one payload whose box does not round trip, because boxing loses
    /// which form the bytes were in.
    fn carriesText(of: types.Type) bool {
        return switch (of) {
            .string => true,
            .optional => |payload| carriesText(payload.asType()),
            .none, .boolean, .int, .float, .strukt, .heap => false,
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
            // String lives in between them does not move
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
                self.values[register] = try self.unboxed(
                    self.function.result_types[register],
                    out,
                    "rt.value",
                );
                self.boxes[register] = out;
            },
            .export_storage => try self.callAnswering(register, .luce_rt_export_storage, &.{
                rt,
                try self.storageOf(of[0]),
            }),

            // -- errors -----------------------------------------------
            //
            // The channel is the outcome word the call beside it
            // answered, so asking costs a compare and nothing else.
            .errored => {
                const outcome = self.outcomes[of[0]];
                if (outcome == .none) return self.fail("errored without a fallible call in its block");
                self.values[register] = try self.wip.icmp(
                    .eq,
                    outcome,
                    try self.module.builder.intValue(.i32, outcome_errored),
                    "errored",
                );
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
            .abs => switch (try self.numeric(of[0])) {
                .int => {
                    // Negating the smallest i64 has no representable
                    // result, so `abs` traps where the interpreter does
                    // and the intrinsic never sees the poison case.
                    const held = self.values[of[0]];
                    const smallest = try self.module.builder.intValue(
                        .i64,
                        std.math.minInt(i64),
                    );
                    try self.check(
                        try self.wip.icmp(.eq, held, smallest, "is.smallest"),
                        .integer_overflow,
                    );
                    self.values[register] = try self.wip.callIntrinsic(
                        .normal,
                        .none,
                        .abs,
                        &.{.i64},
                        &.{ held, .true },
                        "abs",
                    );
                },
                .float => self.values[register] = try self.wip.callIntrinsic(
                    .normal,
                    .none,
                    .fabs,
                    &.{.double},
                    &.{self.values[of[0]]},
                    "abs",
                ),
            },
            .min, .max => self.values[register] = try self.emitExtremum(
                called.kind == .min,
                self.values[of[0]],
                self.values[of[1]],
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
                    self.values[of[0]],
                    self.values[of[1]],
                    kind,
                );
                self.values[register] = try self.emitExtremum(
                    true,
                    lifted,
                    self.values[of[2]],
                    kind,
                );
            },
            .sqrt => self.values[register] = try self.emitFloatCall(.sqrt, of[0]),
            .floor => self.values[register] = try self.emitFloatCall(.floor, of[0]),
            .ceil => self.values[register] = try self.emitFloatCall(.ceil, of[0]),
            .trunc => self.values[register] = try self.emitFloatCall(.trunc, of[0]),

            // Comparison across the Int/Float line is exact, so it is
            // a call and not a widening (docs/NUMERICS.md).  The
            // operator arrives as an Int register — a constant every
            // time — and narrows to the `i32` the C surface takes.
            .compare_int_float => {
                const answer = try self.callRuntime(.luce_rt_compare_int_float, .i32, &.{
                    try self.wip.cast(.trunc, self.values[of[0]], .i32, "op"),
                    self.values[of[1]],
                    self.values[of[2]],
                }, "compared");
                self.values[register] = try self.wip.icmp(
                    .ne,
                    answer,
                    try self.module.builder.intValue(.i32, 0),
                    "compare",
                );
            },

            // -- traps and effects, generated here --------------------
            .print => {
                const text, const length = try self.textParts(of[0], "print");
                _ = try self.callHost(.print, &.{ text, length }, "printed");
            },
            .assert_true => {
                const held = self.values[of[0]];
                const broken = try self.wip.bin(.xor, held, .true, "assert.failed");
                try self.check(broken, .assertion_failed);
            },
            .trap_message => try self.emitTrapMessage(called),

            // -- the runtime library, one call each -------------------
            .null_object => {
                self.values[register] = try self.module.builder.intValue(.i64, runtime.null_index);
            },

            // -- absence, as four moves on `{T, i1}` ------------------
            //
            // Every one of them is a register shuffle: SROA takes the
            // pair apart and the bit becomes a flag the machine was
            // already carrying.  There is no call and no memory here,
            // which is what makes `parse_int(s) else 0` cost what the
            // parse costs and nothing more.
            .none_value => {
                self.values[register] = try self.zeroValue(
                    self.function.result_types[register],
                );
            },
            .is_none => {
                self.values[register] = try self.wip.bin(
                    .xor,
                    try self.wip.extractValue(
                        self.values[of[0]],
                        &.{Module.optional_present},
                        "present",
                    ),
                    .true,
                    "is.none",
                );
            },
            // `T <: T?`: the same payload, now known to be there.
            .optional_wrap => {
                self.values[register] = try self.wip.buildAggregate(
                    try self.module.valueType(self.function.result_types[register]),
                    &.{ self.values[of[0]], .true },
                    "wrap",
                );
            },
            // What narrowing licensed.  The analyzer has already proved
            // the bit is set, so nothing is checked here.
            .optional_unwrap => {
                self.values[register] = try self.wip.extractValue(
                    self.values[of[0]],
                    &.{Module.optional_payload},
                    "unwrap",
                );
            },
            .len => {
                // A String is `{ ptr, i64 }` in a register already, so
                // its length is the second word and nothing else.
                if (self.function.result_types[of[0]] == .string) {
                    self.values[register] = try self.wip.extractValue(
                        self.values[of[0]],
                        &.{1},
                        "length",
                    );
                    return;
                }
                if (self.arrayShape(of[0])) |shape| {
                    return self.emitArrayLength(register, of[0], shape);
                }
                try self.callAnswering(register, .luce_rt_len, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                });
            },
            .index_get => {
                if (self.arrayShape(of[0])) |shape| {
                    const view = try self.arrayView(of[0], shape);
                    const address = try self.arrayElement(view, shape.element, of[1..]);
                    self.values[register] = try self.loadCell(shape.element, address);
                    if (!ownsNothing(shape.element)) self.boxes[register] = address;
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
                if (self.arrayShape(of[0])) |shape| {
                    if (ownsNothing(shape.element)) {
                        const view = try self.arrayView(of[0], shape);
                        const address = try self.arrayElement(
                            view,
                            shape.element,
                            of[1 .. of.len - 1],
                        );
                        try self.storeCell(
                            shape.element,
                            address,
                            self.values[of[of.len - 1]],
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
                self.values[of[1]],
                self.values[of[2]],
            }),
            .append_value => try self.callChecked(.luce_rt_append, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.storageOf(of[1]),
            }),
            .append_ascii => try self.callChecked(.luce_rt_append_ascii, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.values[of[1]],
            }),
            .pop_value => try self.callAnswering(register, .luce_rt_pop, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .insert_value => try self.callChecked(.luce_rt_insert, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.values[of[1]],
                try self.storageOf(of[2]),
            }),
            .remove_entry => try self.callChecked(.luce_rt_remove, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "which"),
            }),
            .has_key => try self.callAnswering(register, .luce_rt_has_key, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "key"),
            }),
            .key_at => try self.callAnswering(register, .luce_rt_key_at, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.values[of[1]],
            }),
            .value_at => try self.callAnswering(register, .luce_rt_value_at, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                self.values[of[1]],
            }),
            .dim_size => {
                if (self.arrayShape(of[0])) |shape| {
                    return self.emitArrayDimSize(register, of[0], of[1], shape);
                }
                try self.callAnswering(register, .luce_rt_dim_size, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    self.values[of[1]],
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
            }),
            .map_values => try self.callAnswering(register, .luce_rt_map_values, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .map_get => try self.callAnswering(register, .luce_rt_map_get, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "key"),
                try self.boxedRegister(of[2], "fallback"),
            }),
            .array_fill => try self.callChecked(.luce_rt_array_fill, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
                try self.boxedRegister(of[1], "element"),
            }),
            .free_object => {
                const owner = try self.namedBinding(of);
                try self.callChecked(.luce_rt_free, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    owner.owned,
                    owner.serial,
                    owner.local,
                });
            },
            .give_object => {
                const owner = try self.namedBinding(of);
                try self.callAnswering(register, .luce_rt_give, &.{
                    rt,
                    try self.boxedRegister(of[0], "target"),
                    owner.owned,
                    owner.serial,
                    owner.local,
                });
            },
            .copy_object => try self.callAnswering(register, .luce_rt_copy, &.{
                rt,
                try self.boxedRegister(of[0], "target"),
            }),
            .str_value => try self.callAnswering(register, .luce_rt_str, &.{
                rt,
                try self.boxedRegister(of[0], "held"),
            }),
            .parse_int => try self.callAnswering(register, .luce_rt_parse_int, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
            }),
            .parse_float => try self.callAnswering(register, .luce_rt_parse_float, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
            }),
            .chr_code => try self.callAnswering(register, .luce_rt_chr, &.{
                rt,
                self.values[of[0]],
            }),
            .ord_text => try self.callAnswering(register, .luce_rt_ord, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
            }),
            .string_slice => try self.emitStringSlice(register, of[0], of[1], of[2]),
            .string_byte => try self.emitStringByte(register, of[0], of[1]),
            .string_find_byte => try self.callAnswering(register, .luce_rt_string_find_byte, &.{
                rt,
                try self.boxedRegister(of[0], "text"),
                self.values[of[1]],
                self.values[of[2]],
            }),

            // -- the rest of the host services ------------------------
            // A file the world would not read or write is an error
            // and not a trap: `file_exists` in front of it is a race,
            // which is the proof a guard cannot stand in for a result
            // (docs/FAILURE.md).  Both answer an outcome the `errored`
            // beside them branches on.
            .file_read => try self.emitFileRead(register, of[0]),
            .file_write => {
                const path, const path_length = try self.textParts(of[0], "path");
                const content, const content_length = try self.textParts(of[1], "content");
                const answer = try self.callHost(
                    .file_write,
                    &.{ path, path_length, content, content_length },
                    "wrote",
                );
                self.outcomes[register] = try self.raiseIo(.write, answer, path, path_length);
            },
            .file_append => {
                const path, const path_length = try self.textParts(of[0], "path");
                const content, const content_length = try self.textParts(of[1], "content");
                const answer = try self.callHost(
                    .file_append,
                    &.{ path, path_length, content, content_length },
                    "appended",
                );
                self.outcomes[register] = try self.raiseIo(.append, answer, path, path_length);
            },
            .file_delete => {
                const path, const path_length = try self.textParts(of[0], "path");
                const answer = try self.callHost(
                    .file_delete,
                    &.{ path, path_length },
                    "deleted",
                );
                self.outcomes[register] = try self.raiseIo(.delete, answer, path, path_length);
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
                self.outcomes[register] = try self.raiseIo(.rename, answer, from, from_length);
            },
            .dir_list => try self.emitDirList(register, of[0]),
            .read_line => try self.emitMaybeText(
                register,
                .read_line,
                of[0],
                "line",
            ),
            .env_get => try self.emitMaybeText(register, .env, of[0], "env"),
            .print_error => {
                const text, const length = try self.textParts(of[0], "diagnostic");
                _ = try self.callHost(.print_error, &.{ text, length }, "reported");
            },
            .clock_ms => {
                self.values[register] = try self.callHostNumber(.clock_ms, "clock");
            },
            .sleep_ms => {
                // A duration already elapsed is not a bug and not a
                // failure: the host waits no time and answers yes.
                _ = try self.callHost(.sleep_ms, &.{self.values[of[0]]}, "slept");
            },
            .file_exists => {
                const path, const path_length = try self.textParts(of[0], "path");
                const answer = try self.callHost(.file_exists, &.{ path, path_length }, "exists");
                self.values[register] = try self.saidYes(answer);
            },
            .term_rows => {
                self.values[register] = try self.callHostNumber(.term_rows, "rows");
            },
            .term_cols => {
                self.values[register] = try self.callHostNumber(.term_cols, "cols");
            },
            .term_clear => _ = try self.callHost(.term_clear, &.{}, "cleared"),
            .term_move => _ = try self.callHost(.term_move, &.{
                self.values[of[0]],
                self.values[of[1]],
            }, "moved"),
            .term_style => _ = try self.callHost(.term_style, &.{
                self.values[of[0]],
                self.values[of[1]],
                try self.wip.cast(.zext, self.values[of[2]], .i32, "bold"),
            }, "styled"),
            .term_write => {
                const text, const length = try self.textParts(of[0], "term");
                _ = try self.callHost(.term_write, &.{ text, length }, "wrote");
            },
            .term_flush => _ = try self.callHost(.term_flush, &.{}, "flushed"),
            .key_read => {
                // `String?`, and the answer is what decides which.
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
                const present = try self.wip.cast(.zext, try self.saidYes(answer), .i32, "present");
                // The payload belongs to the run, not to the host's
                // buffer: copy it in before `key_text` can be asked.
                // Cleared, so end of input empties it rather than
                // leaving the last key's text standing.
                const typed_bytes, const typed_size = try typed.load(self);
                try self.callChecked(.luce_rt_set_key_text, &.{ rt, typed_bytes, typed_size });
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
                self.values[register] = try self.unboxed(.string, out, "key.text");
            },
        }
    }

    // -- scalar math helpers ---------------------------------------------

    /// Which of the two numeric types a math builtin was given.  The
    /// analyzer admits no others; naming the rest keeps this file free
    /// of `else` arms.
    const Numeric = enum { int, float };

    fn numeric(self: *Body, operand: mir.Register) Error!Numeric {
        return switch (self.function.result_types[operand]) {
            .int => .int,
            .float => .float,
            .none,
            .boolean,
            .string,
            .strukt,
            .heap,
            .optional,
            => self.fail("a math builtin on a type that has none"),
        };
    }

    /// `min` when `wants_minimum`, `max` otherwise.
    ///
    /// Int is `llvm.smin`/`llvm.smax`, which mean exactly one thing.
    ///
    /// Float is `llvm.minimumnum`/`llvm.maximumnum`, which mean exactly
    /// what the interpreter's `@min` means and are the only extremum
    /// intrinsics that mean anything at all: `llvm.minnum` leaves
    /// `(-0.0, +0.0)` unspecified, so LLVM's constant folder and the
    /// target's instruction disagree — which is why this was once a
    /// runtime call — and `llvm.minimum` is specified there but
    /// propagates NaN, where Luce answers the operand that is a number.
    /// The 754-2019 pair is both: `-0.0` below `+0.0`, and NaN as an
    /// identity rather than an absorber.
    ///
    /// That last property is what makes an extremum *reduction* fast.
    /// A `min` with no NaN case to steer around is associative and
    /// commutative on the nose, so LLVM's vectorizer may reorder one
    /// without reassociating anything — `vmin` over a million elements
    /// becomes `fminnm.2d` four lanes at a time and beats the scalar
    /// `a < b ? a : b` loop a C compiler is stuck with, while the answer
    /// stays the same value it would have accumulated one at a time.
    /// `08_llvm/test.zig` holds both engines to the same answer for
    /// every signed zero and NaN pairing, scalar and reduced.
    fn emitExtremum(
        self: *Body,
        wants_minimum: bool,
        left: Builder.Value,
        right: Builder.Value,
        kind: Numeric,
    ) Error!Builder.Value {
        switch (kind) {
            .int => return self.wip.callIntrinsic(
                .normal,
                .none,
                if (wants_minimum) .smin else .smax,
                &.{.i64},
                &.{ left, right },
                "extremum",
            ),
            .float => {
                const target = try self.module.floatExtremum(wants_minimum);
                const builder = self.module.builder;
                return self.wip.call(
                    .normal,
                    Builder.CallConv.default,
                    .none,
                    target.typeOf(builder),
                    target.toValue(builder),
                    &.{ left, right },
                    "extremum",
                );
            },
        }
    }

    /// One of the Float-only builtins, as its LLVM intrinsic.
    fn emitFloatCall(
        self: *Body,
        intrinsic: Builder.Intrinsic,
        operand: mir.Register,
    ) Error!Builder.Value {
        switch (try self.numeric(operand)) {
            .float => {},
            .int => return self.fail("a Float builtin applied to an Int"),
        }
        return self.wip.callIntrinsic(
            .normal,
            .none,
            intrinsic,
            &.{.double},
            &.{self.values[operand]},
            "float",
        );
    }

    /// `new List(T)` / `new Map(K, V)` / `new Array(T, ...)` / `new
    /// Builder`.  The shape is a compile-time fact, so the kind picks
    /// the entry point and only an array's sizes travel at runtime.
    // -- objects, ownership, and the words a trap carries -----------------

    fn emitHeapNew(self: *Body, register: mir.Register, new: mir.Instruction.HeapNew) Error!void {
        switch (self.module.program.heap_types[new.heap]) {
            .list => try self.callAnswering(register, .luce_rt_new_list, &.{self.runtime}),
            .map => try self.callAnswering(register, .luce_rt_new_map, &.{self.runtime}),
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
                        self.values[axis],
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

    /// `object_bind` / `object_unbind`: the binding that received a
    /// fresh object owns it, and releases it when the scope exits
    /// (docs/OWNERSHIP.md).
    fn emitOwnership(
        self: *Body,
        which: Service,
        value: mir.Register,
        local: mir.LocalId,
    ) Error!void {
        _ = try self.callRuntime(which, .void, &.{
            self.runtime,
            try self.boxedRegister(value, "bound"),
            try self.frameSerial(),
            try self.module.builder.intValue(.i32, local),
        }, "");
    }

    /// The binding `free`/`give` must verify against.  A second
    /// argument names an owned local; without one the verb only checks
    /// that no container owns the object (S6, S23).
    fn namedBinding(self: *Body, arguments: []const mir.Register) Error!struct {
        owned: Builder.Value,
        serial: Builder.Value,
        local: Builder.Value,
    } {
        const builder = self.module.builder;
        if (arguments.len != 2) return .{
            .owned = try builder.intValue(.i32, 0),
            .serial = try builder.intValue(.i64, 0),
            .local = try builder.intValue(.i32, 0),
        };
        return .{
            .owned = try builder.intValue(.i32, 1),
            .serial = try self.frameSerial(),
            .local = try self.wip.cast(.trunc, self.values[arguments[1]], .i32, "local"),
        };
    }

    /// `trap("...")` reports and unwinds from the middle of a block, so
    /// the rest of the IR block lowers into a fresh block that nothing
    /// branches to.
    fn emitTrapMessage(self: *Body, called: mir.Instruction.IntrinsicCall) Error!void {
        try self.emitTrap(.explicit_trap, self.values[called.arguments[0]]);
        self.seek(try self.wip.block(0, "after.trap"));
    }
};
