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
/// source contract independently from authority to compute Fabric
/// intents.
pub const CompileOptions = struct {
    entry_mode: EntryMode = .evaluator,
    allow_fabric: bool = false,
};

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// A Luce type: a scalar, a structure (by index into the program's
/// layout table), or none (the absence of a value).
pub const Type = union(enum) {
    none,
    boolean,
    int,
    float,
    string,
    bytes,
    strukt: u32,

    pub fn eql(self: Type, other: Type) bool {
        return switch (self) {
            .strukt => |index| other == .strukt and other.strukt == index,
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
/// through the layout table.
pub fn typeName(layouts: []const StructLayout, of: Type) []const u8 {
    return switch (of) {
        .none => "None",
        .boolean => "Bool",
        .int => "Int",
        .float => "Float",
        .string => "String",
        .bytes => "Bytes",
        .strukt => |index| layouts[index].name,
    };
}

test "type equality distinguishes struct indices" {
    try std.testing.expect(Type.eql(.int, .int));
    try std.testing.expect(!Type.eql(.int, .float));
    try std.testing.expect(Type.eql(.{ .strukt = 2 }, .{ .strukt = 2 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .{ .strukt = 3 }));
    try std.testing.expect(!Type.eql(.{ .strukt = 2 }, .int));
}
