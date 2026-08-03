//! Luce types and the Texel Port schema the compiler binds against.
//!
//! The Port schema, not the source, establishes which input and output
//! members exist and what types they carry.  Loom hands the compiler a
//! schema derived from the Texel's ports; the type checker knows Luce
//! types only — no backend types appear here.

const std = @import("std");

/// The value types a Port can carry into or out of a Luce evaluator.
pub const PortType = enum {
    boolean,
    int,
    float,
    string,
    bytes,

    pub fn luceName(self: PortType) []const u8 {
        return switch (self) {
            .boolean => "Bool",
            .int => "Int",
            .float => "Float",
            .string => "String",
            .bytes => "Bytes",
        };
    }
};

pub const Port = struct {
    name: []const u8,
    declared: PortType,
};

/// Borrowed schema handed to compile(); the compiler copies what the
/// program keeps.
pub const PortSchema = struct {
    inputs: []const Port = &.{},
    outputs: []const Port = &.{},

    pub fn findInput(self: PortSchema, name: []const u8) ?u32 {
        for (self.inputs, 0..) |port, index| {
            if (std.mem.eql(u8, port.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn findOutput(self: PortSchema, name: []const u8) ?u32 {
        for (self.outputs, 0..) |port, index| {
            if (std.mem.eql(u8, port.name, name)) return @intCast(index);
        }
        return null;
    }
};

pub const EntryMode = enum {
    evaluator,
    script,
};

/// Host-controlled compile options. Entry mode selects the required
/// source contract independently from authority: `allow_host` grants
/// the host builtins (console, files, arguments, terminal).
pub const CompileOptions = struct {
    entry_mode: EntryMode = .evaluator,
    allow_host: bool = false,
    /// Display name for the root module in debug info ("dice.luc") —
    /// what a runtime trap location reports.  "" falls back to
    /// "main.luc".  Imported modules always report "PREFIX.luc".
    source_name: []const u8 = "",
    /// Stage 7, the whole of it (`07_optimize`): on for every artifact;
    /// `luce ir --full` clears it to show the raw lowering, unreached
    /// functions and all.  The name is older than the stage — it was
    /// one pass, dead-code elimination, when the flag was added.
    prune: bool = true,
};

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// A Luce type: a scalar, a structure (by index into the program's
/// layout table), a heap object shape (by index into the program's
/// heap type table), an optional `T?`, or none (the absence of a
/// value).  Heap type indexes are interned by the analyzer, so equal
/// shapes share one index and equality is an index comparison.
pub const Type = union(enum) {
    none,
    boolean,
    int,
    float,
    string,
    bytes,
    strukt: u32,
    heap: u32,
    /// `T?` — a `T` that may be absent (docs/FAILURE.md).  `?` means
    /// nullable and only nullable; it never carries a reason.
    optional: Payload,

    /// What a `T?` may hold.  A union of its own rather than a
    /// `*Type`, so `T??` and `None?` are *unrepresentable* rather than
    /// merely refused: there is one level of absence and no way to
    /// write a second.
    pub const Payload = union(enum) {
        boolean,
        int,
        float,
        string,
        bytes,
        strukt: u32,
        heap: u32,

        pub fn asType(self: Payload) Type {
            return switch (self) {
                .boolean => .boolean,
                .int => .int,
                .float => .float,
                .string => .string,
                .bytes => .bytes,
                .strukt => |index| .{ .strukt = index },
                .heap => |index| .{ .heap = index },
            };
        }

        pub fn eql(self: Payload, other: Payload) bool {
            return switch (self) {
                .strukt => |index| other == .strukt and other.strukt == index,
                .heap => |index| other == .heap and other.heap == index,
                else => std.meta.activeTag(self) == std.meta.activeTag(other),
            };
        }
    };

    pub fn eql(self: Type, other: Type) bool {
        return switch (self) {
            .strukt => |index| other == .strukt and other.strukt == index,
            .heap => |index| other == .heap and other.heap == index,
            .optional => |payload| other == .optional and payload.eql(other.optional),
            else => std.meta.activeTag(self) == std.meta.activeTag(other),
        };
    }

    pub fn fromPort(declared: PortType) Type {
        return switch (declared) {
            .boolean => .boolean,
            .int => .int,
            .float => .float,
            .string => .string,
            .bytes => .bytes,
        };
    }

    pub fn isNumeric(self: Type) bool {
        return self == .int or self == .float;
    }

    /// `T` written as `T?`, or null when there is no such type: `None`
    /// has no value to be absent, and `T??` does not exist.
    pub fn optionalOf(base: Type) ?Type {
        return switch (base) {
            .none, .optional => null,
            .boolean => .{ .optional = .boolean },
            .int => .{ .optional = .int },
            .float => .{ .optional = .float },
            .string => .{ .optional = .string },
            .bytes => .{ .optional = .bytes },
            .strukt => |index| .{ .optional = .{ .strukt = index } },
            .heap => |index| .{ .optional = .{ .heap = index } },
        };
    }

    /// The `T` inside a `T?`, or null when this is not an optional.
    pub fn held(self: Type) ?Type {
        return switch (self) {
            .optional => |payload| payload.asType(),
            else => null,
        };
    }
};

/// The shape of one heap object type: what a List holds, a Map's key
/// and value, an Array's element and rank, or a Builder.
pub const HeapType = union(enum) {
    list: Type,
    map: struct { key: Type, value: Type },
    array: struct { element: Type, rank: u8 },
    builder,

    pub fn eql(self: HeapType, other: HeapType) bool {
        return switch (self) {
            .list => |element| other == .list and element.eql(other.list),
            .map => |pair| other == .map and
                pair.key.eql(other.map.key) and pair.value.eql(other.map.value),
            .array => |shape| other == .array and
                shape.element.eql(other.array.element) and shape.rank == other.array.rank,
            .builder => other == .builder,
        };
    }
};

pub const StructField = struct {
    name: []const u8, // arena-owned by the program
    field_type: Type,
};

pub const StructLayout = struct {
    name: []const u8, // arena-owned by the program
    fields: []StructField,

    pub fn findField(self: StructLayout, name: []const u8) ?u32 {
        for (self.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) return @intCast(index);
        }
        return null;
    }
};

/// The written name of a type, for diagnostics.  Struct names resolve
/// through the layout table; heap type names render recursively
/// (`List(Int)`, `Map(String, List(Int))`, `Array(Float, _, _)`), an
/// optional takes the `?` it is written with, so the caller supplies
/// an allocator and owns the result.
pub fn typeName(
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    of: Type,
) error{OutOfMemory}![]u8 {
    var written: std.ArrayList(u8) = .empty;
    errdefer written.deinit(allocator);
    try writeTypeName(&written, allocator, layouts, heap_types, of);
    return written.toOwnedSlice(allocator);
}

fn writeTypeName(
    written: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    layouts: []const StructLayout,
    heap_types: []const HeapType,
    of: Type,
) error{OutOfMemory}!void {
    switch (of) {
        .none => try written.appendSlice(allocator, "None"),
        .boolean => try written.appendSlice(allocator, "Bool"),
        .int => try written.appendSlice(allocator, "Int"),
        .float => try written.appendSlice(allocator, "Float"),
        .string => try written.appendSlice(allocator, "String"),
        .bytes => try written.appendSlice(allocator, "Bytes"),
        .strukt => |index| try written.appendSlice(allocator, layouts[index].name),
        .heap => |index| switch (heap_types[index]) {
            .list => |element| {
                try written.appendSlice(allocator, "List(");
                try writeTypeName(written, allocator, layouts, heap_types, element);
                try written.appendSlice(allocator, ")");
            },
            .map => |pair| {
                try written.appendSlice(allocator, "Map(");
                try writeTypeName(written, allocator, layouts, heap_types, pair.key);
                try written.appendSlice(allocator, ", ");
                try writeTypeName(written, allocator, layouts, heap_types, pair.value);
                try written.appendSlice(allocator, ")");
            },
            .array => |shape| {
                try written.appendSlice(allocator, "Array(");
                try writeTypeName(written, allocator, layouts, heap_types, shape.element);
                for (0..shape.rank) |_| try written.appendSlice(allocator, ", _");
                try written.appendSlice(allocator, ")");
            },
            .builder => try written.appendSlice(allocator, "Builder"),
        },
        .optional => |payload| {
            try writeTypeName(written, allocator, layouts, heap_types, payload.asType());
            try written.appendSlice(allocator, "?");
        },
    }
}

test "type equality distinguishes struct indices" {
    try std.testing.expect(Type.eql(.int, .int));
    try std.testing.expect(!Type.eql(.int, .float));
    try std.testing.expect(Type.eql(.{ .strukt = 2 }, .{ .strukt = 2 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .{ .strukt = 3 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .int));
}

test "an optional is its payload plus one level, and never two" {
    const maybe_int = Type.optionalOf(.int).?;
    try std.testing.expect(maybe_int.eql(.{ .optional = .int }));
    try std.testing.expect(!maybe_int.eql(.int));
    try std.testing.expect(maybe_int.held().?.eql(.int));
    try std.testing.expectEqual(@as(?Type, null), (Type{ .int = {} }).held());

    // `T??` and `None?` have no representation to reach.
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(maybe_int));
    try std.testing.expectEqual(@as(?Type, null), Type.optionalOf(.none));

    // Payload identity is the payload's own: two `Point?`s are equal,
    // a `Point?` and a `Line?` are not.
    try std.testing.expect(Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 2 } }));
    try std.testing.expect(!Type.optionalOf(.{ .strukt = 2 }).?.eql(.{ .optional = .{ .strukt = 3 } }));

    // An `Int?` is not a number: arithmetic needs it narrowed first.
    try std.testing.expect(!maybe_int.isNumeric());
}

test "an optional type writes the ? it was written with" {
    const written = try typeName(std.testing.allocator, &.{}, &.{.{ .list = .int }}, .{ .optional = .{ .heap = 0 } });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("List(Int)?", written);
}
