//! Fabric intents — how Luce programs weave new Texels.
//!
//! Ordinary Luce is pure: an evaluator that calls the fabric builtins
//! does not touch the Fabric itself.  It computes *intents* — complete
//! descriptions of texels to create — which the trusted boundary (the
//! lucia terminal) validates and applies as ordinary transactions
//! after the evaluation returns.  Because evaluation is demand-driven
//! and cached, a template texel fires exactly when its inputs move:
//! re-demanding an unchanged template replays the cached outcome and
//! creates nothing.
//!
//! The builtins are gated by the compile options: only a trusted host
//! enables them, and everything they produce lives in the evaluation
//! arena until the host copies what it applies.

const std = @import("std");
const types = @import("types.zig");

pub const PortSpec = struct {
    name: []const u8,
    declared: types.PortType,
};

pub const SourceValue = union(enum) {
    boolean: bool,
    int: i64,
    float: f64,
    text: []const u8,
};

pub const SetSource = struct {
    output: []const u8,
    value: SourceValue,
};

/// One image the program intends to create on the host — the same
/// storage lucia create makes.  Only the trusted boundary performs it.
pub const NewImage = struct {
    path: []const u8,
    pages: u64,
};

/// One texel the program intends to create: its name, typed ports,
/// optional Luce content and evaluator, and initial output sources.
/// All slices are evaluation-arena-owned.
pub const NewTexel = struct {
    name: []const u8,
    inputs: std.ArrayList(PortSpec) = .empty,
    outputs: std.ArrayList(PortSpec) = .empty,
    content: ?[]const u8 = null,
    evaluator: ?[]const u8 = null,
    sets: std.ArrayList(SetSource) = .empty,
};

/// Everything one evaluation intends to change outside itself, in
/// order.  Arena-owned; hosts copy what they apply.
pub const Intents = struct {
    images: std.ArrayList(NewImage) = .empty,
    texels: std.ArrayList(NewTexel) = .empty,

    pub fn isEmpty(self: *const Intents) bool {
        return self.images.items.len == 0 and self.texels.items.len == 0;
    }
};

/// The port type names the builtins accept, matching the terminal's
/// TYPE vocabulary.
pub fn portTypeNamed(name: []const u8) ?types.PortType {
    const Named = struct {
        name: []const u8,
        declared: types.PortType,
    };
    const named = [_]Named{
        .{ .name = "bool", .declared = .boolean },
        .{ .name = "int", .declared = .int },
        .{ .name = "real", .declared = .float },
        .{ .name = "text", .declared = .string },
        .{ .name = "bytes", .declared = .bytes },
    };
    for (named) |candidate| {
        if (std.mem.eql(u8, name, candidate.name)) return candidate.declared;
    }
    return null;
}
