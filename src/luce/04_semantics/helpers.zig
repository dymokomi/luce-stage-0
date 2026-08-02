//! Small standalone helpers shared across the analyzer modules.

const std = @import("std");
const ast = @import("../03_parse.zig").ast;
const mir = @import("../06_mir.zig");

/// A dotted chain of bare names in front of a call, collected
/// inner-to-outer: for geo.Text.width(...) the parts are
/// [width-side first] and the head is "geo".
pub const Chain = struct {
    parts: [3][]const u8,
    count: usize,

    pub fn head(self: *const Chain) []const u8 {
        return self.parts[self.count - 1];
    }
};

/// Walk a dotted expression to collect the chain of bare names (up to
/// three deep).  Returns null when any link is not a bare name or field
/// of one — the expression is a value method, not a namespaced call.
pub fn dottedChain(target: *const ast.Expression) ?Chain {
    var chain: Chain = .{ .parts = undefined, .count = 0 };
    var walk = target;
    while (true) {
        switch (walk.*) {
            .name => |name| {
                if (chain.count == 3) return null;
                chain.parts[chain.count] = name.text;
                chain.count += 1;
                return chain;
            },
            .field => |field| {
                if (chain.count == 3) return null;
                chain.parts[chain.count] = field.name;
                chain.count += 1;
                walk = field.target;
            },
            else => return null,
        }
    }
}

/// Line and column of a byte offset against a module's precomputed
/// line-start table (binary search for the last start <= offset).
pub fn placeOf(line_starts: []const u32, offset: u32) mir.Origin {
    var low: usize = 0;
    var high: usize = line_starts.len;
    while (low + 1 < high) {
        const middle = (low + high) / 2;
        if (line_starts[middle] <= offset) low = middle else high = middle;
    }
    return .{ .line = @intCast(low + 1), .column = offset - line_starts[low] + 1 };
}

pub fn compareOrder(op: ast.BinaryOp, a: anytype, b: @TypeOf(a)) bool {
    return switch (op) {
        .equal => a == b,
        .not_equal => a != b,
        .less => a < b,
        .less_equal => a <= b,
        .greater => a > b,
        .greater_equal => a >= b,
        else => unreachable,
    };
}

/// Conservative all-paths-return: a block returns when some statement
/// certainly returns; an if returns only when both arms do.  Loops
/// never guarantee a return.
pub fn returnsOnAllPaths(block: ast.Block) bool {
    for (block.statements) |statement| {
        switch (statement) {
            .return_statement => return true,
            .conditional => |conditional| {
                if (conditional.else_block) |else_block| {
                    if (returnsOnAllPaths(conditional.then_block) and
                        returnsOnAllPaths(else_block)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}
