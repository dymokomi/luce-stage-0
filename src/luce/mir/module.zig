//! The serialized module — a verified Luce program between the
//! compiler's two halves.
//!
//! The format is a direct serialization of the IR: shared string
//! constants, constant-container declarations, struct layouts,
//! heap-type shapes, functions with their instruction pools and
//! blocks, and the entry function.  Decoding re-runs the IR
//! verifier, so a damaged or hand-forged module is rejected instead of
//! executed; instruction *types* beyond the verifier's checks are
//! trusted, so treat a module like an executable — decode only what
//! you built or trust.
//!
//! **It is a seam, not a deliverable.**  What `luce build` writes is
//! machine code (`docs/CODEGEN.md`); these bytes are the front end's
//! hand-over to the back end and the artifact's cache key.  Two things
//! ride on them and nothing else does: `artifact.sourceHash` names the
//! program an artifact was built from, and `loom` hands the compiler a
//! module rather than a source file, which is what lets loom carry no
//! code generator (`apps/loom/runner.zig`).  When one has to reach a
//! disk on the way it is written as `.lcm` (`extension` below).
//!
//! Any change to the instruction set, the intrinsic list, or the trap
//! codes must bump `format_version`; there is no migration, a stale
//! module simply recompiles from its .luc source.

const std = @import("std");
const mir = @import("../mir.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;

pub const magic = "LUCE";
/// 18 — `key_read` answers `str?` rather than `str`.  The
/// intrinsic list is unchanged and the wire shape with it, but the
/// *type* the verifier demands of `key_read`'s result is not, so a
/// module written under 17 would either fail verification or, worse,
/// pass it and lower against the wrong shape.
///
/// 20 — the command line stopped being an ambient service and became
/// `main`'s parameter (docs/LANGUAGE.md).  Two intrinsics left the set
/// (`arg_count`, `arg_get`) and one trap code with them
/// (`argument_bounds`), so every instruction tag after them renumbers;
/// the entry may now carry one parameter, which the verifier checks.
///
/// 22 — `u8`, `i16` and `f16` join `types.Type` (docs/TYPES.md
/// step 5).  A type travels as a bare `u8` of its tag's ordinal, and
/// the three land *in ladder order* rather than on the end, so every
/// tag from `i32` up renumbers.  That is safe here for exactly one
/// reason and it is this line: the version moved with them, so a
/// module written under 21 is refused by name instead of decoded
/// against the wrong tags.  Appending would have been the rule had
/// the version *not* moved — it is what `runtime.Value.Tag`, which is
/// ABI rather than wire, still does.
///
/// 25 — `exit_program` joins the intrinsics (docs/LANGUAGE.md's
/// fourth way a run ends), appended inside the host group, so every
/// tag after `dir_list` renumbers under the same one-line warrant.
/// 27 — the bit set arrives (docs/BITWISE.md): five `BinaryOp` tags
/// and one `UnaryOp`, appended, plus `shift_out_of_range` in the trap
/// codes, appended likewise.
///
/// 28 — enums arrive (docs/ENUMS.md).  A table of them joins the
/// program between the heap types and the functions, and
/// `types.Type` grows a tag for one — placed beside `strukt` and
/// `heap`, which are the other two types that index a table, so
/// `optional` renumbers.  Safe for the reason 22's note gives and no
/// other: the version moved with it.
/// 30 — threads arrive (docs/THREADS.md).  One instruction (`spawn`,
/// beside `call` because it is one), one intrinsic (`task_wait`), and
/// one heap type (`task`, carrying the spawned function's result type
/// and its fallibility) — all appended, and the version moves with
/// them because `Instruction` is written by tag ordinal and `spawn`
/// lands in the middle of the union rather than on the end.
///
/// 31 — function values arrive (docs/FUNCTIONS.md).  A table of
/// signatures joins the program between the enums and the functions,
/// `types.Type` grows a tag for one — placed beside `enumeration`,
/// which is the other type that indexes a table, so `optional`
/// renumbers — and two instructions join `Instruction`: `const_function`
/// beside the other constants and `call_indirect` beside `call`, both in
/// the middle of the union rather than on the end.  Safe for the reason
/// 22's note gives and no other: the version moved with them.
///
/// 32 — implied writing receivers arrive (docs/SELF.md). `call_inout`
/// joins the instruction set and a local gains the `inout` bit that
/// makes logical parameter zero alias its caller's mutable binding.
///
/// 33 — constant containers arrive (docs/CONSTANTS.md): a second
/// constant pool, its flat recursive value encoding, `const_container`,
/// and the `immutable_object` trap.  All are wire surface.
///
/// 34 — ownership cycles are refused at every retaining store.  The
/// `ownership_cycle` trap is appended to the stable trap vocabulary.
///
/// 35 — `shell_run` joins the intrinsic set behind `std.os.run`.
/// It is appended, but the tag is still part of the serialized program,
/// so an older decoder must refuse it rather than guess.
///
/// 36 — `term_event_data` joins the intrinsic set behind `term.io`'s
/// mouse and resize accessors.
///
/// 38 — tagged unions arrive (docs/UNION.md).  A table of them joins
/// the program between the enums and the signatures, `types.Type`
/// grows a `variant` tag — placed beside `enumeration`, the other
/// types that index a table, so `function` and `optional` renumber —
/// and three instructions join `Instruction` beside the struct trio
/// they mirror, so every tag after `struct_set` renumbers.  Safe for
/// the reason 22's note gives and no other: the version moved with
/// them.
///
/// 39 — declaration names are root-qualified (docs/PACKAGES.md D7).
/// The wire *shape* did not move an inch: names were always free
/// blobs.  What moved is what they mean — a package module's
/// functions, structs, enums, unions and constants serialize as
/// `root/binding.name` ("geo-1.2.0/util.twice") where they used to
/// serialize as `binding.name` — so two packages each shipping a
/// `util` can never merge in one module, and a trace names the
/// package a frame came from.  A module written under 38 would decode
/// and run, which is exactly why the version must refuse it: the
/// same program's bytes, and therefore its `artifact.sourceHash`,
/// changed under it.
///
/// 40 — `dir_create` and `epoch_ms` join the intrinsic set: a
/// directory made with its parents, and the wall clock `clock_ms`
/// deliberately is not.  Both land *inside* the host group beside the
/// services they belong with — `dir_create` after `dir_list`,
/// `epoch_ms` after `sleep_ms` — rather than on the end, so every tag
/// after them renumbers.  That is safe here for exactly one reason and
/// it is this line: the version moved with them, so a module written
/// under 39 is refused by name instead of decoded against the wrong
/// tags.
///
/// 41 — bound methods arrive (docs/BINDING.md).  A function value grows
/// from a bare index to `{function, receiver}`: `const_function` writes
/// an extra optional register, so its payload is wider than any 40
/// decoder expects, and a function value's runtime shape moves from an
/// `i32` to a two-slot field run.  Nothing was appended and nothing
/// renumbered — one instruction's payload changed — which is exactly
/// the kind of change a stale decoder would read straight past, so the
/// version is what refuses it.
///
/// 42 — `file_exists` leaves `mir.Intrinsic` and `path_kind` takes a
/// place in the host group after `dir_create` (docs/FILESYSTEM.md
/// D17).  One name out and one name in, both in the middle of the
/// union, so every tag after them renumbers *twice over* — which is
/// safe for exactly one reason and it is this line: the version moved
/// with them, so a module written under 41 is refused by name instead
/// of decoded against the wrong tags.  Not a rename: the answer
/// changed shape as well as spelling, from a bool that could not tell
/// absence from refusal to a `i64` beside the error channel.
///
/// 43 — function parameter ownership verbs join `mir.Function` so the
/// verifier can tie a function value's `Signature.Parameter.gives` to the
/// function it names.  A stale module otherwise lets an indirect call omit
/// the `give_object` handoff while the callee still binds the incoming graph.
///
/// 44 — the backend-neutral `std.ui`/`std.gpu` resource operations join the
/// intrinsic set.  They are appended after `path_kind`, so old modules must
/// not reinterpret a later tag as a different host operation.
///
/// 45 — compiler-generated interface layouts are marked so their private
/// function fields remain distinct from source struct fields, and bound
/// witnesses plus indirect calls record fallibility. Ordinary function
/// values remain non-fallible because their source type has no `!` spelling.
///
/// 46 — scope ownership is retired for objects (docs/MEMORY.md): objects
/// live until the runtime sweeps at exit, so the `object_bind` and
/// `object_unbind` instructions leave `Instruction`, the `free_object` and
/// `give_object` intrinsics leave `Intrinsic`, and `mir.Function` drops the
/// per-parameter `parameter_gives` wire it carried since 43.  Names left
/// the middle of two unions, so every tag after them renumbers — safe for
/// exactly one reason and it is this line: the version moved with them, so
/// a module written under 45 is refused by name instead of decoded against
/// the wrong tags.
///
/// 47 — ARC arrives (docs/MEMORY.md): the `retain` and `release` intrinsics
/// join `Intrinsic`, appended after `term_event_data` so no tag before them
/// renumbers.  A 46 module has no way to spell them, so the bump is only the
/// usual refuse-a-stale-module warrant rather than a renumbering one.
///
/// 48 — the explicit numeric vocabulary replaces the old numeric ladder.
/// `types.Type` gains four integer tags, every integer constant widens from
/// i64 to i128 on the wire so it can represent the full u64 range, and enum
/// backing tags grow to all eight integer widths.
///
/// 49 — the explicit text vocabulary is complete. `char` and `bytes` join
/// `types.Type`, character literals produce scalar constants, `bytes_value`
/// joins the intrinsic set, and `parse_string` is replaced by `parse_str`
/// over immutable bytes. A 48 module cannot describe these values and must
/// be refused rather than interpreted with the new tag ordinals.
///
/// 50 — zeroing weak storage joins the language. Struct layouts and locals
/// record weak slots, the instruction set gains dedicated weak load/store
/// operations, and reference layouts carry their identity bit. A 49 module
/// cannot distinguish owning from non-owning storage.
///
/// 51 — final class identity joins the heap descriptor table.
///
/// 52 — reference layouts may name a hidden deinitializer function.
///
/// 53 — closure storage becomes an explicit layout kind, and a local can
/// preserve the boxed storage representation without owning it. A 52 module
/// can describe neither a trusted compiler environment nor the inline-safe
/// bridge into a mutable cell, and would misread every later field.
///
/// 54 — the unused cross-family numeric comparison intrinsic leaves the wire
/// set; numeric parsing is named for its exact result (`parse_i64` and
/// `parse_f64`); and the public text trap names become `str_bounds` and
/// `str_boundary`. These changes alter serialized enum ordinals or names.
///
/// 55 — dead `chr_code` and `ord_text` intrinsics leave the wire set; their
/// work is performed by checked scalar conversions. The unused
/// `ownership_cycle` trap from the manual-ownership design leaves as well.
///
/// 56 — interface existentials store one static witness identity and one
/// owned payload instead of one bound receiver copy per method. Interface
/// requirements record mutability/fallibility, witness rows are serialized,
/// and dedicated make/call instructions replace forged struct fields.
///
/// 57 — the `file` heap shape is renamed `handle`: the raw descriptor
/// currency behind files.File and the coming std.network, spellable only
/// in embedded standard source. The byte channel becomes three directly
/// callable standard intrinsics instead of compiler-routed receiver
/// methods; no instruction shape changes, but the type vocabulary does.
///
/// 58 — the transport intrinsics arrive (docs/NETWORK.md):
/// `socket_connect`, `socket_listen`, `socket_accept`, `socket_port`,
/// appended after `bytes_value`. Connected sockets travel the existing
/// handle byte channel, so no other instruction changes.
///
/// When this number moves, move the sentence below with it — the two
/// must change together so concurrent format changes meet as a merge
/// conflict here instead of silently sharing one version number.
/// This comment last moved for format 58.
pub const format_version: u32 = 65;

/// What a serialized module is called when it has to sit on a disk.
/// Named here because this file owns the format, and named at all
/// because two processes have to agree on it: `loom` writes one and
/// `luce build` reads it back (`docs/CODEGEN.md`).
pub const extension = ".lcm";

pub const DecodeError = error{
    OutOfMemory,
    InvalidModule,
    UnsupportedVersion,
};

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Serialize a verified program.  The caller owns the returned bytes.
pub fn encode(gpa: Allocator, program: *const mir.Program) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var writer: Writer = .{ .gpa = gpa, .out = &out };

    try writer.bytes(magic);
    try writer.int(u32, format_version);

    try writer.int(u32, @intCast(program.constants.len));
    for (program.constants) |constant| try writer.blob(constant);

    try writer.int(u32, @intCast(program.container_constants.len));
    for (program.container_constants) |constant| try writer.containerConstant(constant);

    try writer.int(u32, @intCast(program.structs.len));
    for (program.structs) |layout| {
        try writer.blob(layout.name);
        try writer.int(u8, @intFromBool(layout.interface));
        try writer.int(u8, @intFromBool(layout.closure_storage));
        try writer.int(u8, @intFromBool(layout.reference));
        try writer.int(u8, @intFromBool(layout.deinitializer != null));
        if (layout.deinitializer) |function| try writer.int(u32, function);
        try writer.int(u32, @intCast(layout.fields.len));
        for (layout.fields) |field| {
            try writer.blob(field.name);
            try writer.int(u8, @intFromBool(field.weak));
            try writer.valueType(field.field_type);
        }
        try writer.int(u32, @intCast(layout.interface_methods.len));
        for (layout.interface_methods) |method| {
            try writer.blob(method.name);
            try writer.int(u32, method.signature);
            try writer.int(u8, @intFromBool(method.mutating));
            try writer.int(u8, @intFromBool(method.fallible));
        }
    }

    try writer.int(u32, @intCast(program.heap_types.len));
    for (program.heap_types) |descriptor| try writer.heapType(descriptor);

    try writer.int(u32, @intCast(program.enums.len));
    for (program.enums) |declared| {
        try writer.blob(declared.name);
        try writer.int(u8, @intFromEnum(declared.backing));
        try writer.int(u32, @intCast(declared.members.len));
        for (declared.members) |member| {
            try writer.blob(member.name);
            try writer.int(i128, member.value);
        }
    }

    try writer.int(u32, @intCast(program.variants.len));
    for (program.variants) |declared| {
        try writer.blob(declared.name);
        try writer.int(u32, @intCast(declared.members.len));
        for (declared.members) |member| {
            try writer.blob(member.name);
            try writer.int(u32, @intCast(member.fields.len));
            for (member.fields) |field| {
                try writer.blob(field.name);
                try writer.int(u8, @intFromBool(field.weak));
                try writer.valueType(field.field_type);
            }
        }
    }

    try writer.int(u32, @intCast(program.signatures.len));
    for (program.signatures) |signature| {
        try writer.int(u32, @intCast(signature.parameters.len));
        for (signature.parameters) |parameter| {
            try writer.valueType(parameter.value_type);
        }
        try writer.valueType(signature.result);
    }

    try writer.int(u32, @intCast(program.interface_witnesses.len));
    for (program.interface_witnesses) |witness| {
        try writer.int(u32, witness.interface);
        try writer.valueType(witness.receiver);
        try writer.int(u32, @intCast(witness.methods.len));
        for (witness.methods) |method| try writer.int(u32, method);
    }

    try writer.int(u32, @intCast(program.functions.len));
    for (program.functions) |*function| try writer.function(function);
    try writer.int(u32, program.entry_function);

    return out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),

    fn bytes(self: *Writer, data: []const u8) error{OutOfMemory}!void {
        try self.out.appendSlice(self.gpa, data);
    }

    fn int(self: *Writer, comptime T: type, value: T) error{OutOfMemory}!void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        try self.out.appendSlice(self.gpa, &encoded);
    }

    fn blob(self: *Writer, data: []const u8) error{OutOfMemory}!void {
        try self.int(u32, @intCast(data.len));
        try self.bytes(data);
    }

    fn valueType(self: *Writer, of: types.Type) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(of)));
        if (of == .strukt) try self.int(u32, of.strukt);
        if (of == .heap) try self.int(u32, of.heap);
        if (of == .variant) try self.int(u32, of.variant);
        if (of == .function) try self.int(u32, of.function);
        // The width travels with the index, as it does in memory: the
        // decoder rebuilds the whole reference without reaching into
        // the enum table, which is read later in the stream.
        if (of == .enumeration) {
            try self.int(u32, of.enumeration.index);
            try self.int(u8, @intFromEnum(of.enumeration.backing));
        }
        // A `T?` writes its payload as a type of its own, which cannot
        // be optional in turn: one tag byte, then the payload's.
        if (of == .optional) try self.valueType(of.optional.asType());
    }

    fn heapType(self: *Writer, descriptor: types.HeapType) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(descriptor)));
        switch (descriptor) {
            .class => |layout| try self.int(u32, layout),
            .list => |element| try self.valueType(element),
            .map => |pair| {
                try self.valueType(pair.key);
                try self.valueType(pair.value);
            },
            .array => |shape| {
                try self.valueType(shape.element);
                try self.int(u8, shape.rank);
            },
            .builder, .handle => {},
            .task => |work| {
                try self.valueType(work.result);
                try self.int(u8, @intFromBool(work.fallible));
            },
            .channel => |element| try self.valueType(element),
        }
    }

    fn constantValue(self: *Writer, constant: mir.ConstantValue) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(constant)));
        switch (constant) {
            .boolean => |value| try self.int(u8, @intFromBool(value)),
            .integer => |value| try self.int(i128, value),
            .float => |value| try self.int(u64, @bitCast(value)),
            .str => |index| try self.int(u32, index),
            .strukt => |value| {
                try self.int(u32, value.layout);
                try self.int(u32, @intCast(value.fields.len));
                for (value.fields) |field| try self.constantValue(field);
            },
            .absent => {},
        }
    }

    fn containerConstant(self: *Writer, constant: mir.ContainerConstant) error{OutOfMemory}!void {
        try self.blob(constant.name);
        try self.int(u32, constant.heap);
        try self.int(u8, @intFromEnum(std.meta.activeTag(constant.payload)));
        switch (constant.payload) {
            .sequence => |values| {
                try self.int(u32, @intCast(values.len));
                for (values) |value| try self.constantValue(value);
            },
            .map => |entries| {
                try self.int(u32, @intCast(entries.len));
                for (entries) |entry| {
                    try self.constantValue(entry.key);
                    try self.constantValue(entry.value);
                }
            },
        }
        try self.blob(constant.source);
        try self.int(u32, constant.origin.line);
        try self.int(u32, constant.origin.column);
    }

    fn registers(self: *Writer, list: []const mir.Register) error{OutOfMemory}!void {
        try self.int(u32, @intCast(list.len));
        for (list) |register| try self.int(u32, register);
    }

    fn function(self: *Writer, of: *const mir.Function) error{OutOfMemory}!void {
        try self.blob(of.name);
        try self.int(u32, of.parameter_count);
        try self.valueType(of.return_type);
        try self.int(u8, @intFromBool(of.fallible));

        try self.int(u32, @intCast(of.locals.len));
        for (of.locals) |local| {
            try self.blob(local.name);
            try self.valueType(local.local_type);
            try self.int(u8, @intFromBool(local.owns_storage));
            try self.int(u8, @intFromBool(local.boxed_storage));
            try self.int(u8, @intFromBool(local.weak));
            try self.int(u8, @intFromBool(local.inout));
        }

        try self.int(u32, @intCast(of.instructions.len));
        for (of.instructions, of.result_types) |encoded, result_type| {
            try self.instruction(encoded);
            try self.valueType(result_type);
        }

        try self.int(u32, @intCast(of.blocks.len));
        for (of.blocks) |block| try self.registers(block.items);

        // Debug info: the source file name and one line:column per
        // instruction; a --release build writes "" and zero.
        try self.blob(of.source);
        try self.int(u32, @intCast(of.origins.len));
        for (of.origins) |origin| {
            try self.int(u32, origin.line);
            try self.int(u32, origin.column);
        }
    }

    fn instruction(self: *Writer, of: mir.Instruction) error{OutOfMemory}!void {
        try self.int(u8, @intFromEnum(std.meta.activeTag(of)));
        switch (of) {
            .const_boolean => |value| try self.int(u8, @intFromBool(value)),
            .const_integer => |value| try self.int(i128, value),
            .const_float => |value| try self.int(u64, @bitCast(value)),
            .const_str => |constant| try self.int(u32, constant),
            .const_container => |constant| try self.int(u32, constant),
            .const_function => |named| {
                try self.int(u32, named.function);
                try self.int(u8, @intFromBool(named.receiver != null));
                if (named.receiver) |receiver| try self.int(u32, receiver);
                try self.int(u8, @intFromBool(named.fallible));
            },
            .local_get => |local| try self.int(u32, local),
            .local_set => |set| {
                try self.int(u32, set.local);
                try self.int(u32, set.value);
            },
            .weak_local_get => |local| try self.int(u32, local),
            .weak_local_set => |set| {
                try self.int(u32, set.local);
                try self.int(u32, set.value);
            },
            .binary => |binary| {
                try self.int(u8, @intFromEnum(binary.op));
                try self.valueType(binary.operand_type);
                try self.int(u32, binary.left);
                try self.int(u32, binary.right);
            },
            .unary => |unary| {
                try self.int(u8, @intFromEnum(unary.op));
                try self.int(u32, unary.operand);
            },
            .convert => |operand| try self.int(u32, operand),
            .interface_make => |make| {
                try self.int(u32, make.layout);
                try self.int(u32, make.witness);
                try self.int(u32, make.receiver);
            },
            .struct_make => |make| {
                try self.int(u32, make.layout);
                try self.registers(make.fields);
            },
            .struct_get => |get| {
                try self.int(u32, get.target);
                try self.int(u32, get.layout);
                try self.int(u32, get.field);
            },
            .struct_set => |set| {
                try self.int(u32, set.target);
                try self.int(u32, set.layout);
                try self.int(u32, set.field);
                try self.int(u32, set.value);
            },
            .weak_struct_get => |get| {
                try self.int(u32, get.target);
                try self.int(u32, get.layout);
                try self.int(u32, get.field);
            },
            .weak_struct_set => |set| {
                try self.int(u32, set.target);
                try self.int(u32, set.layout);
                try self.int(u32, set.field);
                try self.int(u32, set.value);
            },
            .variant_make => |make| {
                try self.int(u32, make.variant);
                try self.int(u32, make.member);
                try self.registers(make.fields);
            },
            .variant_tag => |tag| try self.int(u32, tag.target),
            .variant_field => |get| {
                try self.int(u32, get.target);
                try self.int(u32, get.variant);
                try self.int(u32, get.member);
                try self.int(u32, get.field);
            },
            .call, .spawn => |call| {
                try self.int(u32, call.function);
                try self.registers(call.arguments);
            },
            .call_inout => |call| {
                try self.int(u32, call.function);
                try self.int(u32, call.receiver);
                try self.registers(call.arguments);
            },
            .interface_call => |call| {
                try self.int(u32, call.receiver);
                try self.int(u32, call.layout);
                try self.int(u32, call.method);
                try self.registers(call.arguments);
                try self.int(u8, @intFromBool(call.fallible));
            },
            .interface_call_inout => |call| {
                try self.int(u32, call.receiver);
                try self.int(u32, call.layout);
                try self.int(u32, call.method);
                try self.registers(call.arguments);
                try self.int(u8, @intFromBool(call.fallible));
            },
            .call_indirect => |call| {
                try self.int(u32, call.callee);
                try self.int(u32, call.signature);
                try self.registers(call.arguments);
                try self.int(u8, @intFromBool(call.fallible));
            },
            .intrinsic => |intrinsic| {
                try self.int(u8, @intFromEnum(intrinsic.kind));
                try self.registers(intrinsic.arguments);
            },
            .heap_new => |new| {
                try self.int(u32, new.heap);
                try self.registers(new.dims);
            },
            .jump => |target| try self.int(u32, target),
            .branch => |branch| {
                try self.int(u32, branch.condition);
                try self.int(u32, branch.then_block);
                try self.int(u32, branch.else_block);
            },
            .ret => |value| {
                try self.int(u8, @intFromBool(value != null));
                if (value) |returned| try self.int(u32, returned);
            },
            .trap => |code| try self.int(u8, @intFromEnum(code)),
            .unwind => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Deserialize and verify a module.  The caller owns the returned
/// program (deinit); the program copies everything it keeps, so the
/// input bytes may be freed immediately.
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!mir.Program {
    var program: mir.Program = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    var reader: Reader = .{ .data = data };
    const found_magic = try reader.take(magic.len);
    if (!std.mem.eql(u8, found_magic, magic)) return error.InvalidModule;
    const version = try reader.int(u32);
    if (version != format_version) return error.UnsupportedVersion;

    const constant_count = try reader.count();
    const constants = try arena.alloc([]const u8, constant_count);
    for (constants) |*slot| slot.* = try arena.dupe(u8, try reader.blob());
    program.constants = constants;

    const container_constant_count = try reader.count();
    const container_constants = try arena.alloc(mir.ContainerConstant, container_constant_count);
    for (container_constants) |*slot| slot.* = try reader.containerConstant(arena);
    program.container_constants = container_constants;

    const struct_count = try reader.count();
    const structs = try arena.alloc(types.StructLayout, struct_count);
    for (structs) |*layout| {
        layout.name = try arena.dupe(u8, try reader.blob());
        layout.interface = (try reader.int(u8)) != 0;
        layout.closure_storage = (try reader.int(u8)) != 0;
        layout.reference = (try reader.int(u8)) != 0;
        layout.deinitializer = if ((try reader.int(u8)) != 0)
            try reader.int(u32)
        else
            null;
        const field_count = try reader.count();
        const fields = try arena.alloc(types.StructField, field_count);
        for (fields) |*field| {
            field.name = try arena.dupe(u8, try reader.blob());
            field.weak = (try reader.int(u8)) != 0;
            field.field_type = try reader.valueType();
        }
        layout.fields = fields;
        const method_count = try reader.count();
        const methods = try arena.alloc(types.InterfaceMethod, method_count);
        for (methods) |*method| {
            method.name = try arena.dupe(u8, try reader.blob());
            method.signature = try reader.int(u32);
            method.mutating = (try reader.int(u8)) != 0;
            method.fallible = (try reader.int(u8)) != 0;
        }
        layout.interface_methods = methods;
    }
    program.structs = structs;

    const heap_count = try reader.count();
    const heap_types = try arena.alloc(types.HeapType, heap_count);
    for (heap_types) |*descriptor| descriptor.* = try reader.heapType();
    program.heap_types = heap_types;

    const enum_count = try reader.count();
    const enums = try arena.alloc(types.EnumType, enum_count);
    for (enums) |*declared| {
        declared.name = try arena.dupe(u8, try reader.blob());
        declared.backing = try reader.enumTag(types.Type.EnumRef.Backing);
        const member_count = try reader.count();
        const members = try arena.alloc(types.EnumMember, member_count);
        for (members) |*member| {
            member.name = try arena.dupe(u8, try reader.blob());
            member.value = try reader.int(i128);
        }
        declared.members = members;
    }
    program.enums = enums;

    const variant_count = try reader.count();
    const variants = try arena.alloc(types.VariantType, variant_count);
    for (variants) |*declared| {
        declared.name = try arena.dupe(u8, try reader.blob());
        const member_count = try reader.count();
        const members = try arena.alloc(types.VariantMember, member_count);
        for (members) |*member| {
            member.name = try arena.dupe(u8, try reader.blob());
            const field_count = try reader.count();
            const fields = try arena.alloc(types.StructField, field_count);
            for (fields) |*field| {
                field.name = try arena.dupe(u8, try reader.blob());
                field.weak = (try reader.int(u8)) != 0;
                field.field_type = try reader.valueType();
            }
            member.fields = fields;
        }
        declared.members = members;
    }
    program.variants = variants;

    const signature_count = try reader.count();
    const signatures = try arena.alloc(types.Signature, signature_count);
    for (signatures) |*signature| {
        const parameter_count = try reader.count();
        const parameters = try arena.alloc(types.Signature.Parameter, parameter_count);
        for (parameters) |*parameter| {
            parameter.value_type = try reader.valueType();
        }
        signature.parameters = parameters;
        signature.result = try reader.valueType();
    }
    program.signatures = signatures;

    const witness_count = try reader.count();
    const witnesses = try arena.alloc(mir.InterfaceWitness, witness_count);
    for (witnesses) |*witness| {
        witness.interface = try reader.int(u32);
        witness.receiver = try reader.valueType();
        const method_count = try reader.count();
        const methods = try arena.alloc(u32, method_count);
        for (methods) |*method| method.* = try reader.int(u32);
        witness.methods = methods;
    }
    program.interface_witnesses = witnesses;

    const function_count = try reader.count();
    const functions = try arena.alloc(mir.Function, function_count);
    for (functions) |*function| try reader.function(arena, function);
    program.functions = functions;
    program.entry_function = try reader.int(u32);
    if (reader.offset != data.len) return error.InvalidModule;

    mir.verify(gpa, &program) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };
    return program;
}

const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    /// Cap per-list allocation before contents are read, so a short
    /// hostile module cannot request absurd allocations up front.
    const max_count = 1 << 24;
    /// Source expressions are bounded to 400 levels before lowering.
    /// Repeat the bound at the wire boundary so a forged chain of
    /// nested struct values cannot consume the native stack.
    const max_recursive_depth = 400;

    fn take(self: *Reader, length: usize) DecodeError![]const u8 {
        if (self.data.len - self.offset < length) return error.InvalidModule;
        const slice = self.data[self.offset .. self.offset + length];
        self.offset += length;
        return slice;
    }

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn count(self: *Reader) DecodeError!usize {
        const value = try self.int(u32);
        if (value > max_count) return error.InvalidModule;
        // Every list element costs at least one byte on the wire, so
        // a count larger than the remaining input is a lie — and
        // rejecting it here keeps decode's allocations proportional
        // to the input instead of trusting a four-byte field.
        if (value > self.data.len - self.offset) return error.InvalidModule;
        return value;
    }

    fn blob(self: *Reader) DecodeError![]const u8 {
        const length = try self.count();
        return self.take(length);
    }

    fn enumTag(self: *Reader, comptime T: type) DecodeError!T {
        const raw = try self.int(u8);
        return std.enums.fromInt(T, raw) orelse error.InvalidModule;
    }

    fn valueType(self: *Reader) DecodeError!types.Type {
        return self.valueTypeAt(0);
    }

    fn valueTypeAt(self: *Reader, depth: u32) DecodeError!types.Type {
        if (depth > max_recursive_depth) return error.InvalidModule;
        const tag = try self.enumTag(std.meta.Tag(types.Type));
        return switch (tag) {
            .none => .none,
            .boolean => .boolean,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .f16 => .f16,
            .f32 => .f32,
            .f64 => .f64,
            .char => .char,
            .str => .str,
            .bytes => .bytes,
            .strukt => .{ .strukt = try self.int(u32) },
            .heap => .{ .heap = try self.int(u32) },
            .variant => .{ .variant = try self.int(u32) },
            .function => .{ .function = try self.int(u32) },
            .enumeration => .{ .enumeration = .{
                .index = try self.int(u32),
                .backing = try self.enumTag(types.Type.EnumRef.Backing),
            } },
            // `T??` has no representation, so a payload that decodes
            // as optional is a damaged module, not a nested one.
            .optional => types.Type.optionalOf(try self.valueTypeAt(depth + 1)) orelse
                return error.InvalidModule,
        };
    }

    fn heapType(self: *Reader) DecodeError!types.HeapType {
        const tag = try self.enumTag(std.meta.Tag(types.HeapType));
        return switch (tag) {
            .class => .{ .class = try self.int(u32) },
            .list => .{ .list = try self.valueType() },
            .map => .{ .map = .{
                .key = try self.valueType(),
                .value = try self.valueType(),
            } },
            .array => .{ .array = .{
                .element = try self.valueType(),
                .rank = try self.int(u8),
            } },
            .builder => .builder,
            .handle => .handle,
            .task => .{ .task = .{
                .result = try self.valueType(),
                .fallible = (try self.int(u8)) != 0,
            } },
            .channel => .{ .channel = try self.valueType() },
        };
    }

    fn constantValue(self: *Reader, arena: Allocator, depth: u32) DecodeError!mir.ConstantValue {
        if (depth > max_recursive_depth) return error.InvalidModule;
        const tag = try self.enumTag(std.meta.Tag(mir.ConstantValue));
        return switch (tag) {
            .boolean => blk: {
                const raw = try self.int(u8);
                if (raw > 1) return error.InvalidModule;
                break :blk .{ .boolean = raw != 0 };
            },
            .integer => .{ .integer = try self.int(i128) },
            .float => .{ .float = @bitCast(try self.int(u64)) },
            .str => .{ .str = try self.int(u32) },
            .strukt => blk: {
                const layout = try self.int(u32);
                const field_count = try self.count();
                const fields = try arena.alloc(mir.ConstantValue, field_count);
                for (fields) |*field| field.* = try self.constantValue(arena, depth + 1);
                break :blk .{ .strukt = .{ .layout = layout, .fields = fields } };
            },
            .absent => .absent,
        };
    }

    fn containerConstant(self: *Reader, arena: Allocator) DecodeError!mir.ContainerConstant {
        const name = try arena.dupe(u8, try self.blob());
        const heap = try self.int(u32);
        const tag = try self.enumTag(std.meta.Tag(mir.ContainerConstant.Payload));
        const payload: mir.ContainerConstant.Payload = switch (tag) {
            .sequence => blk: {
                const value_count = try self.count();
                const values = try arena.alloc(mir.ConstantValue, value_count);
                for (values) |*value| value.* = try self.constantValue(arena, 0);
                break :blk .{ .sequence = values };
            },
            .map => blk: {
                const entry_count = try self.count();
                const entries = try arena.alloc(mir.ContainerConstant.MapEntry, entry_count);
                for (entries) |*entry| {
                    entry.key = try self.constantValue(arena, 0);
                    entry.value = try self.constantValue(arena, 0);
                }
                break :blk .{ .map = entries };
            },
        };
        return .{
            .name = name,
            .heap = heap,
            .payload = payload,
            .source = try arena.dupe(u8, try self.blob()),
            .origin = .{
                .line = try self.int(u32),
                .column = try self.int(u32),
            },
        };
    }

    fn registers(self: *Reader, arena: Allocator) DecodeError![]mir.Register {
        const register_count = try self.count();
        const list = try arena.alloc(mir.Register, register_count);
        for (list) |*register| register.* = try self.int(u32);
        return list;
    }

    fn function(self: *Reader, arena: Allocator, out: *mir.Function) DecodeError!void {
        out.name = try arena.dupe(u8, try self.blob());
        out.parameter_count = try self.int(u32);
        out.return_type = try self.valueType();
        out.fallible = (try self.int(u8)) != 0;

        const local_count = try self.count();
        const locals = try arena.alloc(mir.Local, local_count);
        for (locals) |*local| {
            local.name = try arena.dupe(u8, try self.blob());
            local.local_type = try self.valueType();
            local.owns_storage = (try self.int(u8)) != 0;
            local.boxed_storage = (try self.int(u8)) != 0;
            local.weak = (try self.int(u8)) != 0;
            local.inout = (try self.int(u8)) != 0;
        }
        out.locals = locals;

        const instruction_count = try self.count();
        const instructions = try arena.alloc(mir.Instruction, instruction_count);
        const result_types = try arena.alloc(types.Type, instruction_count);
        for (instructions, result_types) |*decoded, *result_type| {
            decoded.* = try self.instruction(arena);
            result_type.* = try self.valueType();
        }
        out.instructions = instructions;
        out.result_types = result_types;

        const block_count = try self.count();
        const blocks = try arena.alloc(mir.Block, block_count);
        for (blocks) |*block| block.items = try self.registers(arena);
        out.blocks = blocks;

        // Debug info is all-or-nothing per function; reject a table
        // that disagrees with the instruction count before allocating.
        out.source = try arena.dupe(u8, try self.blob());
        const origin_count = try self.count();
        if (origin_count != 0 and origin_count != instruction_count) return error.InvalidModule;
        const origins = try arena.alloc(mir.Origin, origin_count);
        for (origins) |*origin| {
            origin.line = try self.int(u32);
            origin.column = try self.int(u32);
        }
        out.origins = origins;
    }

    fn instruction(self: *Reader, arena: Allocator) DecodeError!mir.Instruction {
        const tag = try self.enumTag(std.meta.Tag(mir.Instruction));
        return switch (tag) {
            .const_boolean => .{ .const_boolean = (try self.int(u8)) != 0 },
            .const_integer => .{ .const_integer = try self.int(i128) },
            .const_float => .{ .const_float = @bitCast(try self.int(u64)) },
            .const_str => .{ .const_str = try self.int(u32) },
            .const_container => .{ .const_container = try self.int(u32) },
            .const_function => blk: {
                const named = try self.int(u32);
                const bound = (try self.int(u8)) != 0;
                break :blk .{ .const_function = .{
                    .function = named,
                    .receiver = if (bound) try self.int(u32) else null,
                    .fallible = (try self.int(u8)) != 0,
                } };
            },
            .local_get => .{ .local_get = try self.int(u32) },
            .local_set => .{ .local_set = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .weak_local_get => .{ .weak_local_get = try self.int(u32) },
            .weak_local_set => .{ .weak_local_set = .{
                .local = try self.int(u32),
                .value = try self.int(u32),
            } },
            .binary => .{ .binary = .{
                .op = try self.enumTag(mir.BinaryOp),
                .operand_type = try self.valueType(),
                .left = try self.int(u32),
                .right = try self.int(u32),
            } },
            .unary => .{ .unary = .{
                .op = try self.enumTag(mir.UnaryOp),
                .operand = try self.int(u32),
            } },
            .convert => .{ .convert = try self.int(u32) },
            .interface_make => .{ .interface_make = .{
                .layout = try self.int(u32),
                .witness = try self.int(u32),
                .receiver = try self.int(u32),
            } },
            .struct_make => .{ .struct_make = .{
                .layout = try self.int(u32),
                .fields = try self.registers(arena),
            } },
            .struct_get => .{ .struct_get = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
            } },
            .struct_set => .{ .struct_set = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
                .value = try self.int(u32),
            } },
            .weak_struct_get => .{ .weak_struct_get = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
            } },
            .weak_struct_set => .{ .weak_struct_set = .{
                .target = try self.int(u32),
                .layout = try self.int(u32),
                .field = try self.int(u32),
                .value = try self.int(u32),
            } },
            .variant_make => .{ .variant_make = .{
                .variant = try self.int(u32),
                .member = try self.int(u32),
                .fields = try self.registers(arena),
            } },
            .variant_tag => .{ .variant_tag = .{
                .target = try self.int(u32),
            } },
            .variant_field => .{ .variant_field = .{
                .target = try self.int(u32),
                .variant = try self.int(u32),
                .member = try self.int(u32),
                .field = try self.int(u32),
            } },
            .call => .{ .call = .{
                .function = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .call_inout => .{ .call_inout = .{
                .function = try self.int(u32),
                .receiver = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .interface_call => .{ .interface_call = .{
                .receiver = try self.int(u32),
                .layout = try self.int(u32),
                .method = try self.int(u32),
                .arguments = try self.registers(arena),
                .fallible = (try self.int(u8)) != 0,
            } },
            .interface_call_inout => .{ .interface_call_inout = .{
                .receiver = try self.int(u32),
                .layout = try self.int(u32),
                .method = try self.int(u32),
                .arguments = try self.registers(arena),
                .fallible = (try self.int(u8)) != 0,
            } },
            .spawn => .{ .spawn = .{
                .function = try self.int(u32),
                .arguments = try self.registers(arena),
            } },
            .call_indirect => .{ .call_indirect = .{
                .callee = try self.int(u32),
                .signature = try self.int(u32),
                .arguments = try self.registers(arena),
                .fallible = (try self.int(u8)) != 0,
            } },
            .intrinsic => .{ .intrinsic = .{
                .kind = try self.enumTag(mir.Intrinsic),
                .arguments = try self.registers(arena),
            } },
            .heap_new => .{ .heap_new = .{
                .heap = try self.int(u32),
                .dims = try self.registers(arena),
            } },
            .jump => .{ .jump = try self.int(u32) },
            .branch => .{ .branch = .{
                .condition = try self.int(u32),
                .then_block = try self.int(u32),
                .else_block = try self.int(u32),
            } },
            .ret => blk: {
                const has_value = (try self.int(u8)) != 0;
                break :blk .{ .ret = if (has_value) try self.int(u32) else null };
            },
            .trap => .{ .trap = try self.enumTag(mir.TrapCode) },
            .unwind => .unwind,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const compile_mod = @import("../compile.zig");
const interpreter = @import("../interpreter.zig");

fn compileScriptWith(source: []const u8, prune: bool) !mir.Program {
    var result = try compile_mod.compile(testing.allocator, source, .{
        .allow_host = true,
        .prune = prune,
    });
    switch (result) {
        .success => |program| return program,
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            result.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

fn compileScript(source: []const u8) !mir.Program {
    return compileScriptWith(source, true);
}

fn constantContainerProgram() !mir.Program {
    var program: mir.Program = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    program.constants = try arena.dupe([]const u8, &.{ "unused", "alpha", "beta", "alpha" });
    program.structs = try arena.dupe(types.StructLayout, &.{.{
        .name = "Label",
        .fields = try arena.dupe(types.StructField, &.{
            .{ .name = "text", .field_type = .str },
            .{ .name = "fallback", .field_type = .{ .optional = .i64 } },
            .{ .name = "enabled", .field_type = .boolean },
        }),
    }});
    program.heap_types = try arena.dupe(types.HeapType, &.{
        .{ .list = .{ .strukt = 0 } },
        .{ .map = .{ .key = .str, .value = .i64 } },
        .{ .array = .{ .element = .f64, .rank = 1 } },
    });

    const label_fields = try arena.dupe(mir.ConstantValue, &.{
        .{ .str = 1 },
        .absent,
        .{ .boolean = true },
    });
    const labels = try arena.dupe(mir.ConstantValue, &.{.{
        .strukt = .{ .layout = 0, .fields = label_fields },
    }});
    const entries = try arena.dupe(mir.ContainerConstant.MapEntry, &.{
        .{ .key = .{ .str = 1 }, .value = .{ .integer = 10 } },
        .{ .key = .{ .str = 2 }, .value = .{ .integer = 20 } },
    });
    const measurements = try arena.dupe(mir.ConstantValue, &.{
        .{ .float = 1.5 },
        .{ .float = 2.5 },
    });
    const same_measurements = try arena.dupe(mir.ConstantValue, &.{
        .{ .float = 1.5 },
        .{ .float = 2.5 },
    });
    program.container_constants = try arena.dupe(mir.ContainerConstant, &.{
        .{
            .name = "labels",
            .heap = 0,
            .payload = .{ .sequence = labels },
            .source = "tables.luc",
            .origin = .{ .line = 4, .column = 1 },
        },
        .{
            .name = "scores",
            .heap = 1,
            .payload = .{ .map = entries },
            .source = "tables.luc",
            .origin = .{ .line = 8, .column = 1 },
        },
        .{
            .name = "measurements",
            .heap = 2,
            .payload = .{ .sequence = measurements },
            .source = "tables.luc",
            .origin = .{ .line = 12, .column = 1 },
        },
        // Identical contents are still a different declaration and a
        // different runtime object.
        .{
            .name = "same_measurements",
            .heap = 2,
            .payload = .{ .sequence = same_measurements },
            .source = "tables.luc",
            .origin = .{ .line = 13, .column = 1 },
        },
    });

    const instructions = try arena.dupe(mir.Instruction, &.{
        .{ .const_container = 0 },
        .{ .const_container = 1 },
        .{ .const_container = 2 },
        .{ .ret = null },
    });
    const blocks = try arena.dupe(mir.Block, &.{.{
        .items = try arena.dupe(mir.Register, &.{ 0, 1, 2, 3 }),
    }});
    program.functions = try arena.dupe(mir.Function, &.{.{
        .name = "main",
        .parameter_count = 0,
        .return_type = .none,
        .locals = &.{},
        .instructions = instructions,
        .result_types = try arena.dupe(types.Type, &.{
            .{ .heap = 0 },
            .{ .heap = 1 },
            .{ .heap = 2 },
            .none,
        }),
        .blocks = blocks,
    }});
    return program;
}

test "constant containers round-trip with declaration identity and exact values" {
    var program = try constantContainerProgram();
    defer program.deinit();
    try mir.verify(testing.allocator, &program);

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 4), loaded.container_constants.len);
    try testing.expectEqualStrings("measurements", loaded.container_constants[2].name);
    try testing.expectEqualStrings("same_measurements", loaded.container_constants[3].name);
    try testing.expectEqual(@as(u32, 12), loaded.container_constants[2].origin.line);
    try testing.expectEqual(@as(usize, 2), loaded.container_constants[2].payload.sequence.len);
    try testing.expectEqual(@as(f64, 2.5), loaded.container_constants[2].payload.sequence[1].float);
    try testing.expect(loaded.container_constants[0].payload.sequence[0].strukt.fields[1] == .absent);
    const dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "constant container#0 labels: list[Label] = [Label(text=data#1, fallback=none, enabled=true)]") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    mir.strip(&loaded);
    try testing.expectEqualStrings("", loaded.container_constants[0].source);
    try testing.expectEqual(mir.Origin{ .line = 0, .column = 0 }, loaded.container_constants[0].origin);
    try mir.verify(testing.allocator, &loaded);
}

test "constant container rows are exhaustively verified after decode" {
    var program = try constantContainerProgram();
    defer program.deinit();
    try mir.verify(testing.allocator, &program);

    // An absent value is legal in the optional struct field above,
    // but nowhere at the container's top level.
    const saved_label = program.container_constants[0].payload.sequence[0];
    program.container_constants[0].payload.sequence[0] = .absent;
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    program.container_constants[0].payload.sequence[0] = saved_label;

    // Two distinct string slots with equal bytes are the same map key.
    program.container_constants[1].payload.map[1].key = .{ .str = 3 };
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    program.container_constants[1].payload.map[1].key = .{ .str = 2 };

    const saved_entries = program.container_constants[1].payload.map;
    program.container_constants[1].payload = .{ .map = &.{} };
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    const empty_map_module = try encode(testing.allocator, &program);
    defer testing.allocator.free(empty_map_module);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, empty_map_module));
    program.container_constants[1].payload = .{ .map = saved_entries };

    const saved_origin = program.container_constants[0].origin;
    program.container_constants[0].origin.line = 0;
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    program.container_constants[0].origin = saved_origin;

    // Rank is not redundantly stored in the row: only rank one is
    // admitted, and its length comes from the sequence itself.
    program.heap_types[2].array.rank = 2;
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    program.heap_types[2].array.rank = 1;

    // Row three is unused by every instruction and still part of the
    // module's trust boundary.  Encode the damage to prove decode's
    // verifier checks the pool whole rather than on demand.
    const saved_measurement = program.container_constants[3].payload.sequence[0];
    program.container_constants[3].payload.sequence[0] = .{ .str = 99 };
    const damaged = try encode(testing.allocator, &program);
    defer testing.allocator.free(damaged);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, damaged));
    program.container_constants[3].payload.sequence[0] = saved_measurement;

    program.functions[0].instructions[0] = .{ .const_container = 99 };
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
}

test "constant struct shapes are rejected before execution" {
    var program = try constantContainerProgram();
    defer program.deinit();

    const held = &program.container_constants[0].payload.sequence[0].strukt;
    const declared_fields = held.fields;
    held.fields = declared_fields[0 .. declared_fields.len - 1];
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    const short_module = try encode(testing.allocator, &program);
    defer testing.allocator.free(short_module);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, short_module));

    held.fields = declared_fields;
    const declared_layout = held.layout;
    held.layout = std.math.maxInt(u32);
    try testing.expectError(error.BadConstant, mir.verify(testing.allocator, &program));
    const unknown_layout_module = try encode(testing.allocator, &program);
    defer testing.allocator.free(unknown_layout_module);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, unknown_layout_module));
    held.layout = declared_layout;
}

test "constant value decode depth is bounded" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var writer: Writer = .{ .gpa = testing.allocator, .out = &bytes };
    try writer.bytes(magic);
    try writer.int(u32, format_version);
    try writer.int(u32, 0); // strings
    try writer.int(u32, 1); // container rows
    try writer.blob("deep");
    try writer.int(u32, 0); // heap row, never reached
    const PayloadTag = std.meta.Tag(mir.ContainerConstant.Payload);
    const ValueTag = std.meta.Tag(mir.ConstantValue);
    try writer.int(u8, @intFromEnum(@as(PayloadTag, .sequence)));
    try writer.int(u32, 1);
    for (0..Reader.max_recursive_depth + 1) |_| {
        try writer.int(u8, @intFromEnum(@as(ValueTag, .strukt)));
        try writer.int(u32, 0);
        try writer.int(u32, 1);
    }
    try testing.expectError(error.InvalidModule, decode(testing.allocator, bytes.items));
}

test "a compiled program round-trips through the module format" {
    const source =
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\func length(point: Point) -> f64:
        \\    return sqrt(point.x * point.x + point.y * point.y)
        \\
        \\func main():
        \\    var point = Point(x = 3.0, y = 4.0)
        \\    point.x = 6.0
        \\    var total: i64 = 0
        \\    for index in range(0, 5):
        \\        if index % 2 == 0:
        \\            total = total + index
        \\    print("length ready")
        \\    let text = "π = " + "3.14159"[0:4]
        \\    var points = list[f64]()
        \\    points.append(length(point))
        \\    var counts = map[str, i64]()
        \\    counts[text] = len(points)
        \\    var grid = array[i64](2, 3)
        \\    grid[1, 2] = total
        \\    for value in points:
        \\        total = total + i64(value)
        \\
    ;
    var program = try compileScript(source);
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    // The decoded program prints identically — same structs, functions,
    // instructions, and constants.
    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);

    // Encoding the decoded program is byte-identical: the format is a
    // fixed point.
    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "an inout receiver and call round-trip through the current format" {
    var program = try compileScript(
        \\struct Counter:
        \\    value: i64
        \\
        \\    func add(amount: i64):
        \\        self.value = self.value + amount
        \\
        \\func main():
        \\    var counter = Counter(value = 1)
        \\    counter.add(2)
        \\    assert(counter.value == 3)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    var saw_inout = false;
    var saw_call = false;
    for (loaded.functions) |function| {
        if (function.parameter_count != 0 and function.locals[0].inout) {
            saw_inout = true;
            try testing.expectEqualStrings("self", function.locals[0].name);
        }
        for (function.instructions) |instruction| switch (instruction) {
            .call_inout => |call| {
                saw_call = true;
                try testing.expectEqual(@as(usize, 1), call.arguments.len);
            },
            else => {},
        };
    }
    try testing.expect(saw_inout);
    try testing.expect(saw_call);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "weak locals, fields, and operations round-trip through the current format" {
    var program = try compileScript(
        \\struct Observer:
        \\    weak target: list[i64]? = none
        \\
        \\func main():
        \\    let source = [42]
        \\    weak var local: list[i64]? = source
        \\    var observer = Observer()
        \\    observer.target = local
        \\    assert(observer.target != none)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.structs.len);
    try testing.expect(loaded.structs[0].fields[0].weak);
    var saw_weak_local = false;
    var saw_local_get = false;
    var saw_local_set = false;
    var saw_field_get = false;
    var saw_field_set = false;
    for (loaded.functions) |function| {
        for (function.locals) |local| saw_weak_local = saw_weak_local or local.weak;
        for (function.instructions) |instruction| switch (instruction) {
            .weak_local_get => saw_local_get = true,
            .weak_local_set => saw_local_set = true,
            .weak_struct_get => saw_field_get = true,
            .weak_struct_set => saw_field_set = true,
            else => {},
        };
    }
    try testing.expect(saw_weak_local);
    try testing.expect(saw_local_get and saw_local_set);
    try testing.expect(saw_field_get and saw_field_set);

    const dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "weak target: list[i64]?") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "weak_local_get") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "weak_struct_set") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "a boxed storage bridge survives the module round trip without becoming an owner" {
    var program = try compileScript(
        \\func main():
        \\    var text = "forty"
        \\    let finish: func() -> str = func():
        \\        text += "-two"
        \\        return text
        \\    assert(finish() == "forty-two")
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    var found_bridge = false;
    for (loaded.functions) |function| {
        for (function.locals) |local| {
            if (!std.mem.eql(u8, local.name, "text")) continue;
            if (!local.boxed_storage or local.owns_storage) continue;
            found_bridge = true;
        }
    }
    try testing.expect(found_bridge);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "a class heap descriptor and hidden deinitializer round-trip together" {
    var program = try compileScript(
        \\class Resource:
        \\    value: i64
        \\    deinit:
        \\        self.value += 1
        \\
        \\func main():
        \\    let resource = Resource(value = 1)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    try testing.expectEqual(@as(usize, 1), loaded.structs.len);
    try testing.expect(loaded.structs[0].reference);
    const finalizer = loaded.structs[0].deinitializer orelse
        return error.TestUnexpectedResult;
    try testing.expect(finalizer < loaded.functions.len);
    try testing.expectEqualStrings("Resource.deinit", loaded.functions[finalizer].name);
    try testing.expectEqual(@as(u32, 1), loaded.functions[finalizer].parameter_count);
    try testing.expectEqual(types.Type.none, loaded.functions[finalizer].return_type);

    var class_heap: ?u32 = null;
    for (loaded.heap_types, 0..) |descriptor, index| switch (descriptor) {
        .class => |layout| if (layout == 0) {
            class_heap = @intCast(index);
        },
        else => {},
    };
    try testing.expect(class_heap != null);
    try testing.expect(loaded.functions[finalizer].locals[0].local_type.eql(.{
        .heap = class_heap.?,
    }));

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "function signatures, values, lambdas, and indirect calls round-trip" {
    const source =
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func apply(f: func(i64) -> i64, n: i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    print(str(chosen))
        \\    print(str(apply((n) -> n + 1, 4)))
        \\
    ;
    var program = try compileScript(source);
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    try testing.expect(loaded.signatures.len != 0);
    var saw_constant = false;
    var saw_indirect_call = false;
    var saw_name = false;
    for (loaded.functions) |function| {
        for (function.instructions) |instruction| switch (instruction) {
            .const_function => saw_constant = true,
            .call_indirect => saw_indirect_call = true,
            .intrinsic => |call| if (call.kind == .function_name) {
                saw_name = true;
            },
            else => {},
        };
    }
    try testing.expect(saw_constant);
    try testing.expect(saw_indirect_call);
    try testing.expect(saw_name);
}

test "decoded function types and conversions are verified before execution" {
    var program = try compileScriptWith(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let chosen: func(i64) -> i64 = twice
        \\    print(str(chosen))
        \\
    , false);
    defer program.deinit();
    const arena = program.arena.allocator();
    try testing.expect(program.signatures.len != 0);

    // An unused local still reaches both engines' frame construction.
    // A function type outside the signature table must therefore be
    // rejected even though no instruction consumes it.
    const entry = &program.functions[program.entry_function];
    const original_locals = entry.locals;
    const damaged_locals = try arena.alloc(mir.Local, original_locals.len + 1);
    @memcpy(damaged_locals[0..original_locals.len], original_locals);
    damaged_locals[original_locals.len] = .{
        .name = "damaged",
        .local_type = .{ .function = @intCast(program.signatures.len) },
    };
    entry.locals = damaged_locals;
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }
    entry.locals = original_locals;

    // An unused signature row is equally part of the decoded type
    // table.  Its own parameter types are checked without waiting for a
    // const or call instruction to happen to name the row.
    const original_signatures = program.signatures;
    const damaged_signatures = try arena.alloc(types.Signature, original_signatures.len + 1);
    @memcpy(damaged_signatures[0..original_signatures.len], original_signatures);
    damaged_signatures[original_signatures.len] = .{
        .parameters = try arena.dupe(types.Signature.Parameter, &.{.{
            .value_type = .{ .function = @intCast(damaged_signatures.len) },
        }}),
        .result = .none,
    };
    program.signatures = damaged_signatures;
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }
    program.signatures = original_signatures;

    // A bounded row can still be malformed when it recursively names
    // itself.  Decoding maps the verifier's cycle refusal to the same
    // public InvalidModule result as an out-of-bounds type.
    damaged_signatures[original_signatures.len].parameters[0].value_type = .{
        .function = @intCast(original_signatures.len),
    };
    program.signatures = damaged_signatures;
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }
    program.signatures = original_signatures;

    // A function value is a run with a function index in it, and no
    // engine ever hands that index to a program: converting one to an
    // `i32` is not a language conversion and must not decode as one.
    var function_value: ?mir.Register = null;
    var storing: ?mir.Register = null;
    for (entry.instructions, 0..) |instruction, register| switch (instruction) {
        .const_function => function_value = @intCast(register),
        // The store of a function value, whichever register carries it
        // by then: the value owns a run, so an ownership instruction
        // may stand between the constant and the slot it lands in.
        .local_set => |set| if (entry.result_types[set.value] == .function) {
            storing = @intCast(register);
        },
        else => {},
    };
    try testing.expect(function_value != null);
    try testing.expect(storing != null);
    const original_instruction = entry.instructions[storing.?];
    const original_result = entry.result_types[storing.?];
    entry.instructions[storing.?] = .{ .convert = function_value.? };
    entry.result_types[storing.?] = .i32;
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }
    entry.instructions[storing.?] = original_instruction;
    entry.result_types[storing.?] = original_result;
}

test "a decoded bound function value rejects a forged receiver" {
    var program = try compileScript(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func main():
        \\    let scale = Scale(factor = 2)
        \\    let f: func(i64) -> i64 = scale.times
        \\    let n: i64 = 3
        \\    print(str(f(n)))
        \\
    );
    defer program.deinit();

    const Site = struct { function: usize, instruction: usize };
    var site: ?Site = null;
    var scalar: ?mir.Register = null;
    for (program.functions, 0..) |*function, function_index| {
        for (function.instructions, 0..) |instruction, register| {
            switch (instruction) {
                .const_function => |named| if (named.receiver != null) {
                    site = .{ .function = function_index, .instruction = register };
                    for (function.result_types, 0..) |result, candidate| {
                        if (result.eql(.i64)) scalar = @intCast(candidate);
                    }
                },
                else => {},
            }
        }
    }
    try testing.expect(site != null);
    try testing.expect(scalar != null);

    const found = site.?;
    const function = &program.functions[found.function];
    const original = function.instructions[found.instruction].const_function.receiver;

    // A receiver register that is outside the function is a malformed
    // operand, not a reason for either decoder or verifier to index past
    // the register table.
    function.instructions[found.instruction].const_function.receiver = @intCast(function.instructions.len + 1);
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }

    // A register of the wrong value type is just as invalid even though
    // it is in bounds.  The verifier must tie the receiver to parameter
    // zero of the method it names.
    function.instructions[found.instruction].const_function.receiver = scalar.?;
    {
        const encoded = try encode(testing.allocator, &program);
        defer testing.allocator.free(encoded);
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
    }

    function.instructions[found.instruction].const_function.receiver = original;
}

test "an optional type round-trips with its payload, and T?? is rejected" {
    var program = try compileScript(
        \\struct Slot:
        \\    held: str?
        \\
        \\func widen(n: i64) -> i64?:
        \\    return n
        \\
        \\func main():
        \\    var counted: i64? = none
        \\    counted = widen(3)
        \\    var slot = Slot(held = none)
        \\    slot.held = "there"
        \\    var listed: list[i64]? = none
        \\    listed = list[i64]()
        \\    listed.append(1)
        \\    assert((counted else 0) == 3)
        \\    assert(slot.held != none)
        \\    assert(len(listed) == 1)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "i64?") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "list[i64]?") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    // A payload that decodes as optional is a damaged module: `T??`
    // has no representation, so it must be refused rather than nested.
    const nested = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(nested);
    const optional_tag: u8 = @intFromEnum(std.meta.activeTag(@as(types.Type, .{ .optional = .i64 })));
    var damaged = false;
    for (nested, 0..) |byte, at| {
        if (byte != optional_tag or at + 1 >= nested.len) continue;
        if (nested[at + 1] != optional_tag) {
            nested[at + 1] = optional_tag;
            damaged = true;
            break;
        }
    }
    try testing.expect(damaged);
    if (decode(testing.allocator, nested)) |decoded| {
        // Some byte positions are not a type tag at all, so the module
        // may still be well formed — but it must never hold a `T??`.
        var owned = decoded;
        defer owned.deinit();
        for (owned.functions) |function| {
            for (function.result_types) |of| try testing.expect(of.held() == null or of.held().? != .optional);
        }
    } else |mistake| {
        try testing.expect(mistake != error.OutOfMemory);
    }
}

test "debug origins round-trip; strip removes them and shrinks the module" {
    var program = try compileScript(
        \\func twice(value: i64) -> i64:
        \\    return value * 2
        \\
        \\func main():
        \\    let sum = twice(4) + twice(5)
        \\
    );
    defer program.deinit();

    const debug_encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(debug_encoded);
    var debug_loaded = try decode(testing.allocator, debug_encoded);
    defer debug_loaded.deinit();
    for (debug_loaded.functions, program.functions) |loaded, original| {
        try testing.expectEqualStrings(original.source, loaded.source);
        try testing.expectEqual(original.instructions.len, loaded.origins.len);
        try testing.expectEqualSlices(mir.Origin, original.origins, loaded.origins);
    }
    // Bench compiles without a source_name; the root falls back.
    try testing.expectEqualStrings("main.luc", debug_loaded.functions[0].source);

    mir.strip(&program);
    const release_encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(release_encoded);
    try testing.expect(release_encoded.len < debug_encoded.len);
    var release_loaded = try decode(testing.allocator, release_encoded);
    defer release_loaded.deinit();
    for (release_loaded.functions) |function| {
        try testing.expectEqual(@as(usize, 0), function.origins.len);
        try testing.expectEqualStrings("", function.source);
    }
}

test "an origins table that disagrees with the instruction count is rejected" {
    var program = try compileScript(
        \\func main():
        \\    print("hi")
        \\
    );
    defer program.deinit();
    // Damage in memory, then encode: one origin too few.
    const function = &program.functions[0];
    function.origins = function.origins[0 .. function.origins.len - 1];
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

// A decoded module *running* is a fact about the language rather
// than about the format, so it is proved on both engines in
// `specs/format_spec.zig` — which also pins the round trip's bytes,
// because those bytes are the artifact key.

test "truncated, oversold, and damaged modules are rejected" {
    var program = try compileScript(
        \\func main():
        \\    return
        \\
    );
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // Wrong magic.
    var wrong_magic = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(wrong_magic);
    wrong_magic[0] = 'X';
    try testing.expectError(error.InvalidModule, decode(testing.allocator, wrong_magic));

    // Future version.
    var future = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(future);
    future[4] = 0xff;
    try testing.expectError(error.UnsupportedVersion, decode(testing.allocator, future));

    // Every truncation fails cleanly instead of crashing.
    var length = encoded.len;
    while (length > 0) : (length -= 1) {
        try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded[0..length -| 1]));
    }

    // Trailing garbage is rejected too.
    const padded = try std.mem.concat(testing.allocator, u8, &.{ encoded, "extra" });
    defer testing.allocator.free(padded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, padded));
}

test "a damaged register reference fails verification, not execution" {
    var program = try compileScript(
        \\func main():
        \\    let value = 1 + 2
        \\
    );
    defer program.deinit();

    // Corrupt an operand register to point far out of range; the
    // decoder's verifier pass must reject the module.
    program.functions[0].instructions[2] = .{ .binary = .{
        .op = .add,
        .operand_type = .i64,
        .left = 900,
        .right = 901,
    } };
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

// A compact program touching every interesting wire shape: structs,
// heap types, intrinsics, calls, branches, value-storage instructions.
//
// **Loop-free on purpose.**  The mutation test below runs what it
// decodes, and a run has to end for the suite to end.  Nothing bounds
// how long a Luce program runs — `while true:` is a legal program —
// so termination is a property of the corpus, not of the engine, and
// the corpus keeps it by being acyclic (see `forwardOnly`).
const mutation_source =
    \\struct Point:
    \\    x: f64
    \\    tag: str
    \\
    \\const seeds: list[i64] = [3, 1, 2]
    \\
    \\func total(values: list[i64]) -> i64:
    \\    return values[0] + values[1] + values[2]
    \\
    \\func main():
    \\    var xs: list[i64] = [3, 1, 2]
    \\    xs.sort()
    \\    var ages = map[str, i64]()
    \\    ages["ada"] = total(xs)
    \\    let point = Point(x = sqrt(4.0), tag = "p"[0:1])
    \\    assert(seeds[0] == 3)
    \\    if point.x > 1.0 and ages.has("ada"):
    \\        xs.append(i64(point.x))
    \\    assert(len(xs) == 4)
    \\
;

/// True when no terminator in `program` jumps to a block at or before
/// its own — which, with a call-depth bound in front of recursion, is
/// enough to make every run end.
///
/// The unmutated module satisfies this by construction and the test
/// asserts that it does; a flipped byte that turns a forward jump into
/// a back edge is skipped, because how long a damaged program runs is
/// not what this test is about and no engine promises it stops.
fn forwardOnly(program: *const mir.Program) bool {
    for (program.functions) |function| {
        for (function.blocks, 0..) |block, index| {
            const last = block.items[block.items.len - 1];
            switch (function.instructions[last]) {
                .jump => |target| if (target <= index) return false,
                .branch => |branch| {
                    if (branch.then_block <= index or branch.else_block <= index) return false;
                },
                else => {},
            }
        }
    }
    return true;
}

test "single-byte damage is rejected or runs to a clean outcome — never a crash" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    try testing.expect(forwardOnly(&program));

    // Every byte, six adversarial values: decode must reject or the
    // program must run to a clean success/trap.  This is the
    // corpus-mode stand-in for fuzzing the trust boundary; any panic
    // here is a verifier hole (a real one was found this way).
    //
    // **The interpreter is a sanitizer here, not a reference engine.**
    // Every test that runs a *Luce program* runs it on both engines
    // and compares them (docs/ENGINE.md, step 8); this one does not,
    // and the reason is that a mutant is not a Luce program: no source
    // produces it, nothing specifies what it should print, and the
    // lowering refuses damaged IR by design, so there is no second
    // arm to compare against and nothing for two engines to agree
    // about.  What is under test is the decoder's trust boundary, and
    // an engine that walks every instruction with bounds checks is
    // the instrument that finds a hole in it.
    var ran: usize = 0;
    var looping: usize = 0;
    for (0..encoded.len) |index| {
        for ([_]u8{ 0x00, 0x01, 0x02, 0x7f, 0x80, 0xff }) |value| {
            if (encoded[index] == value) continue;
            const mutant = try testing.allocator.dupe(u8, encoded);
            defer testing.allocator.free(mutant);
            mutant[index] = value;
            var decoded = decode(testing.allocator, mutant) catch continue;
            defer decoded.deinit();
            if (!forwardOnly(&decoded)) {
                looping += 1;
                continue;
            }
            ran += 1;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            // Objects draw on the same arena as values here, and
            // deliberately: a damaged module may *leak* value storage
            // — an `own_storage` whose paired `local_set` a flipped
            // byte redirected leaves its bytes in a register nothing
            // sweeps (docs/STRINGS.md) — and this test is about
            // termination and crashes, not about reclamation.  Every
            // other suite runs the runtime under
            // `std.testing.allocator`, which is where reclamation is
            // proved.
            _ = try interpreter.run(
                .{ .arena = arena.allocator(), .objects = arena.allocator() },
                &decoded,
                .{ .call_depth = 64 },
                null,
            );
        }
    }

    // The skip is a narrow one — a handful of block-index bytes — and
    // saying so here is what keeps it from quietly swallowing the
    // corpus if the lowering or the format ever changes shape.
    try testing.expect(looping * 20 < ran);
}

test "decode allocates in proportion to its input" {
    var program = try compileScript(mutation_source);
    defer program.deinit();
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);

    // A one-byte flip must never turn a small module into a huge
    // allocation request: every count is bounded by the remaining
    // input (`Reader.count`), so the whole decode is O(input) with the
    // widest decoded element as its constant.
    //
    // **That constant is computed rather than guessed.**  A magic
    // multiplier is a number that goes quietly wrong when a decoded
    // type grows a field, and this test would then fail for a reason
    // that has nothing to do with what it proves.  The arena never
    // reuses what it frees, so the headroom is a small multiple of the
    // bound rather than the bound itself.
    const widest = @max(
        @sizeOf(mir.Function),
        @sizeOf(mir.Instruction),
        @sizeOf(mir.Local),
        @sizeOf(mir.Block),
        @sizeOf(types.StructLayout),
        @sizeOf(types.StructField),
        @sizeOf(types.VariantType),
        @sizeOf(types.VariantMember),
        @sizeOf(types.HeapType),
        @sizeOf(types.Type),
        @sizeOf(mir.ContainerConstant),
        @sizeOf(mir.ContainerConstant.MapEntry),
        @sizeOf(mir.ConstantValue),
    );
    const cap = 8 * widest * encoded.len + 4096;
    const scratch = try testing.allocator.alloc(u8, cap);
    defer testing.allocator.free(scratch);
    for (0..encoded.len) |index| {
        for ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff }) |value| {
            if (encoded[index] == value) continue;
            const mutant = try testing.allocator.dupe(u8, encoded);
            defer testing.allocator.free(mutant);
            mutant[index] = value;
            var fixed = std.heap.FixedBufferAllocator.init(scratch);
            if (decode(fixed.allocator(), mutant)) |decoded| {
                var owned = decoded;
                owned.deinit();
            } else |mistake| {
                try testing.expect(mistake != error.OutOfMemory);
            }
        }
    }
}

test "the wire surface is fingerprinted: change it, bump format_version" {
    var hasher = std.hash.Wyhash.init(0);
    inline for (comptime std.meta.fieldNames(mir.Instruction)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.Intrinsic)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.TrapCode)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ErrorCode)) |name| hasher.update(name);
    // **The type tags are wire surface too**: a type travels as the
    // ordinal of its tag (`Writer.valueType`), so adding, removing or
    // reordering one renumbers every tag after it — which is exactly
    // the silent misreading a version bump exists to prevent.  Enums
    // arriving is what showed this was missing: the instruction set did
    // not move an inch and the wire did.
    inline for (comptime std.meta.fieldNames(types.Type)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(types.HeapType)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(types.StructLayout)) |name| hasher.update(name);
    // And the signature table's own shape, for the same reason: a
    // parameter's verb travels as a byte beside its type, so a field
    // added to `Signature.Parameter` moves the wire (docs/FUNCTIONS.md).
    inline for (comptime std.meta.fieldNames(types.Signature)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(types.Signature.Parameter)) |name| hasher.update(name);
    // Local flags are wire surface too: `inout` changes how both
    // engines interpret local zero without changing its type.
    inline for (comptime std.meta.fieldNames(mir.Local)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.Function)) |name| hasher.update(name);
    // A constant row has two wire-tagged unions of its own and three
    // nested record shapes.  Fingerprint every name rather than only
    // the instruction that indexes the table, or a payload edit could
    // silently leave the version behind.
    inline for (comptime std.meta.fieldNames(mir.ConstantValue)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ConstantValue.Struct)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ContainerConstant)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ContainerConstant.Payload)) |name| hasher.update(name);
    inline for (comptime std.meta.fieldNames(mir.ContainerConstant.MapEntry)) |name| hasher.update(name);
    // If this fails you changed the instruction set, the intrinsics,
    // or the trap or error codes: bump format_version and update BOTH
    // numbers.
    //
    // **It fingerprints the names and nothing else**, so it catches an
    // intrinsic added, removed or renamed and cannot catch one whose
    // *type* changed — `key_read` going from `str` to `str?`
    // moved this number and left the hash alone.  A version bump is
    // still required for that, and this test is not what will remind
    // you.
    // 36 -> 37: `map_get` lost its fallback operand and answers `V?`;
    // `list_find` answers `i64?` — the instruction *names* are
    // unchanged (the hash below did not move), which is exactly the
    // shape-changed case the paragraph above warns the hash cannot
    // catch.
    // 37 -> 38: tagged unions (docs/UNION.md) — `types.Type` grows the
    // `variant` tag and `Instruction` grows the `variant_*` trio, both
    // in the middle of their unions, so the wire renumbers.
    // 38 -> 39: root-qualified declaration names (docs/PACKAGES.md
    // D7) — no tag moved and the hash below did not either; what
    // changed is the *content* of the name blobs, which is the other
    // shape-changed case the paragraph above warns the hash cannot
    // catch.
    // 39 -> 40: `dir_create` and `epoch_ms` join `mir.Intrinsic`, in
    // the middle of the host group rather than at its end, so the hash
    // moves with the two new names *and* every tag after them
    // renumbers.
    // 40 -> 41: bound methods (docs/BINDING.md) — `const_function`
    // grows a receiver register beside the function it names, so its
    // payload widened while every tag stayed put.  The hash below did
    // not move, which is the shape-changed case the paragraph above
    // warns it cannot catch.
    // 41 -> 42: `file_exists` leaves `mir.Intrinsic` and `path_kind`
    // joins it after `dir_create` (docs/FILESYSTEM.md D17), so the
    // hash moves with both names *and* every tag between `file_write`
    // and the end of the union renumbers.
    // 42 -> 43: `mir.Function` records the `give` bit for each parameter,
    // so an indirect function-value call cannot disagree with the callee's
    // ownership handoff.
    // 43 -> 44: the backend-neutral window/GPU intrinsic names are appended
    // after `path_kind`.
    // 44 -> 45: compiler-generated interface witness entries record whether
    // their concrete target is fallible.
    // 45 -> 46: scope ownership is retired for objects (docs/MEMORY.md).
    // `object_bind`/`object_unbind` leave `Instruction` and
    // `free_object`/`give_object` leave `Intrinsic`, both from the middle
    // of their unions, so the hash moves with the four names *and* every
    // tag after them renumbers; `mir.Function` drops `parameter_gives`,
    // which moves the hash again.
    // 46 -> 47: ARC arrives — the `retain` and `release` intrinsics are
    // appended after `term_event_data`, so the hash moves with the two new
    // names and no tag before them renumbers.
    // 48 -> 49: `char` and `bytes` join `types.Type`, `bytes_value` is
    // appended to `Intrinsic`, and `parse_string` is renamed `parse_str`.
    // 49 -> 50: locals and struct fields record weak storage, reference
    // layouts record identity, and four dedicated weak operations join
    // `Instruction`.
    // 50 -> 51: the appended class heap descriptor gives reference-kind
    // layouts an ARC object-handle machine type.
    // 51 -> 52: class layouts name their hidden deinitializer and the trap
    // vocabulary appends class_resurrection.
    // 52 -> 53: layouts record private closure storage so bare function
    // captures remain valid without making them legal source fields, and
    // locals distinguish a boxed representation bridge from a storage owner.
    // 53 -> 54: the obsolete cross-family numeric comparison intrinsic is
    // removed, numeric parsing names its exact result widths, and the
    // text-boundary trap names use the public `str` vocabulary.
    // 54 -> 55: the dead `chr_code` and `ord_text` intrinsics and the
    // retired manual-ownership `ownership_cycle` trap are removed.
    // 55 -> 56: owned interface existentials add three instructions and
    // explicit contract/witness metadata; method count no longer changes a
    // value's physical representation.
    // 56 -> 57: the `file` heap shape is renamed `handle` (the std-only
    // descriptor currency behind files.File), changing the wire tag name
    // the fingerprint hashes without changing any instruction shape.
    // 57 -> 58: four transport intrinsics append after `bytes_value`.
    // 58 -> 59: `term_copy` joins the terminal group after `term_write`
    // (docs/STD.md), so the hash moves with the new name and every tag
    // after it renumbers.
    // 59 -> 60: `os_standard_stream` joins after `shell_run` and
    // `shell_run` itself grows an input argument — the second is the
    // shape-changed case the hash cannot catch, the first moves it.
    // 60 -> 61: the four child doors — `process_spawn`, `process_ready`,
    // `process_wait`, `process_finish_input` — join after
    // `os_standard_stream`.
    // 61 -> 62: `key_read` grows its timeout argument — the
    // shape-changed case the hash cannot catch, so only the version
    // moves.
    // 62 -> 63: channels arrive — the `channel` heap tag, nine
    // `channel_*` intrinsics after `task_wait`, and the
    // `channel_closed` error code all join the wire.
    // 63 -> 64: the filesystem completes — `path_size`,
    // `path_modified`, `dir_remove`, and `tree_remove` join after the
    // channel intrinsics (docs/FILESYSTEM.md).
    // 64 -> 65: `extend_list` joins at the end (the #24 ruling:
    // Zig's appendSlice as `xs.extend(ys)`).
    try testing.expectEqual(@as(u32, 65), format_version);
    try testing.expectEqual(@as(u64, 14365741767081459941), hasher.final());
}

test "an enum round-trips with its members, and a foreign width is rejected" {
    var program = try compileScript(
        \\enum Method(u8):
        \\    stored = 0
        \\    deflated = 8
        \\
        \\struct Entry:
        \\    method: Method
        \\    fallback: Method?
        \\
        \\const MODES = [Method.stored, Method.deflated]
        \\const BINDINGS = {Method.stored: Method.deflated}
        \\const ENTRIES = [
        \\    Entry(method = Method.deflated, fallback = Method.stored),
        \\    Entry(method = Method.stored, fallback = none),
        \\]
        \\
        \\func main():
        \\    var m = Method.stored
        \\    m = Method.deflated
        \\    var seen = list[Method]()
        \\    seen.append(m)
        \\    assert(seen[0] == Method.deflated)
        \\    assert(str(m) == "deflated")
        \\    assert(i32(m) == 8)
        \\    assert(MODES[0] == Method.stored)
        \\    assert(BINDINGS[Method.stored] == Method.deflated)
        \\    assert((ENTRIES[0].fallback else Method.deflated) == Method.stored)
        \\    assert(ENTRIES[1].fallback == none)
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "enum Method(u8):") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "deflated = 8") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "list[Method]") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "MODES: list[Method] = [Method.stored, Method.deflated]") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "BINDINGS: map[Method, Method] = {Method.stored: Method.deflated}") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "ENTRIES: list[Entry] = [Entry(method=Method.deflated, fallback=Method.stored), Entry(method=Method.stored, fallback=none)]") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    // **The width in a type and the width in the table are one fact**
    // (`types.Type.EnumRef`), so a module where they disagree is
    // damaged and must be refused rather than read at whichever of the
    // two an engine happens to consult.
    var widened = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(widened);
    const table_at = std.mem.indexOf(u8, widened, "Method").? + "Method".len;
    try testing.expectEqual(@intFromEnum(types.Type.EnumRef.Backing.u8), widened[table_at]);
    widened[table_at] = @intFromEnum(types.Type.EnumRef.Backing.i64);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, widened));
}

test "a union round-trips with its members and payload fields" {
    var program = try compileScript(
        \\union Shape:
        \\    empty
        \\    circle(radius: f64)
        \\    rect(width: f64, height: f64)
        \\
        \\func main():
        \\    var s = Shape.circle(radius = 2.0)
        \\    s = Shape.empty
        \\    var total: f64 = 0.0
        \\    match s:
        \\        empty:
        \\            total = 0.0
        \\        circle(radius):
        \\            total = radius
        \\        rect(width, height):
        \\            total = width * height
        \\    assert(total == 0.0)
        \\    assert(str(s) == "empty")
        \\
    );
    defer program.deinit();

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();

    const original_dump = try mir.print(testing.allocator, &program);
    defer testing.allocator.free(original_dump);
    const loaded_dump = try mir.print(testing.allocator, &loaded);
    defer testing.allocator.free(loaded_dump);
    try testing.expectEqualStrings(original_dump, loaded_dump);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "union Shape:") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "rect(width: f64, height: f64)") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "variant_make Shape.circle") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "variant_tag") != null);
    try testing.expect(std.mem.indexOf(u8, loaded_dump, "variant_field") != null);

    const again = try encode(testing.allocator, &loaded);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, encoded, again);

    // A member index past the table is a damaged module, refused the
    // way an enum register holding no member is.
    var damaged = false;
    for (loaded.functions) |function| {
        for (function.instructions) |instruction| {
            if (instruction != .variant_make) continue;
            if (instruction.variant_make.member != 1) continue;
            damaged = true;
        }
    }
    try testing.expect(damaged);
    var forged = program;
    for (forged.functions) |*function| {
        for (function.instructions) |*instruction| {
            if (instruction.* != .variant_make) continue;
            instruction.variant_make.member = 9;
        }
    }
    const bad = try encode(testing.allocator, &forged);
    defer testing.allocator.free(bad);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, bad));
}

fn expectReversedInterfaceWitness(program: *const mir.Program) !void {
    const layout_index: u32 = for (program.structs, 0..) |layout, index| {
        if (layout.interface and std.mem.eql(u8, layout.name, "Pair")) {
            break @intCast(index);
        }
    } else return error.TestUnexpectedResult;
    const layout = program.structs[layout_index];
    try testing.expectEqual(@as(usize, 0), layout.fields.len);
    try testing.expectEqual(@as(usize, 2), layout.interface_methods.len);
    try testing.expectEqualStrings("left", layout.interface_methods[0].name);
    try testing.expectEqualStrings("right", layout.interface_methods[1].name);

    var saw_value = false;
    for (program.functions) |function| {
        for (function.instructions) |instruction| {
            if (instruction != .interface_make or instruction.interface_make.layout != layout_index) continue;
            const witness = program.interface_witnesses[instruction.interface_make.witness];
            try testing.expectEqual(layout_index, witness.interface);
            try testing.expectEqual(@as(usize, 2), witness.methods.len);
            try testing.expectEqualStrings("Reversed.left", program.functions[witness.methods[0]].name);
            try testing.expectEqualStrings("Reversed.right", program.functions[witness.methods[1]].name);
            saw_value = true;
        }
    }
    try testing.expect(saw_value);
}

test "interface witness slots keep contract order across serialization" {
    var program = try compileScript(
        \\interface Pair:
        \\    func left() -> i64
        \\    func right() -> i64
        \\
        \\struct Reversed: Pair:
        \\    marker: i64
        \\    func right() -> i64:
        \\        return self.marker + 2
        \\    func left() -> i64:
        \\        return self.marker + 1
        \\
        \\func sum(value: Pair) -> i64:
        \\    return value.left() + value.right()
        \\
        \\func main():
        \\    print(str(sum(Reversed(marker = 39))))
        \\
    );
    defer program.deinit();
    try expectReversedInterfaceWitness(&program);

    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    var loaded = try decode(testing.allocator, encoded);
    defer loaded.deinit();
    try expectReversedInterfaceWitness(&loaded);
}

test "an enum register holding no member is refused" {
    var program = try compileScript(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func main():
        \\    var m = Method.stored
        \\    m = Method.deflated
        \\    assert(m == Method.deflated)
        \\
    );
    defer program.deinit();

    // The one promise an enum makes is that every value of it is a
    // member (docs/ENUMS.md), and `match` spends it: with every member
    // named, the last arm is the fallthrough and nothing traps.  A
    // hand-made module that puts 3 in a `Method` register is what that
    // promise has to be defended against.
    for (program.functions[0].instructions, program.functions[0].result_types) |*instruction, of| {
        if (of != .enumeration or instruction.* != .const_integer) continue;
        instruction.* = .{ .const_integer = 3 };
        break;
    }
    const encoded = try encode(testing.allocator, &program);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidModule, decode(testing.allocator, encoded));
}

// The module boundary is hostile-input code: a `.lcm` may have come from a
// stale cache or from a process that is not ours.  The property is stronger
// than "decode does not crash": every accepted byte string must still be a
// verified program, and every refusal must stay within the decoder's public
// error set.
test "fuzz: arbitrary module bytes either refuse or produce verified MIR" {
    try testing.fuzz({}, decodeAnything, .{ .corpus = &.{
        "",
        "LUCE",
        "LUCE\x00\x00\x00\x00",
        "LUCE\x2A\x00\x00\x00",
        "LUCE\x29\x00\x00\x00",
        "LUCE\x2A\x00\x00\x00\x00\x00\x00\x00",
    } });
}

fn decodeAnything(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const length = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 'L', 4),
        .value(u8, 'U', 4),
        .value(u8, 'C', 4),
        .value(u8, 'E', 4),
        .value(u8, 0x2A, 4),
        .value(u8, 0x00, 4),
    });

    const decoded = decode(testing.allocator, buffer[0..length]) catch |failure| switch (failure) {
        error.InvalidModule, error.UnsupportedVersion => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var program = decoded;
    defer program.deinit();
    try mir.verify(testing.allocator, &program);
}
