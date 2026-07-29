//! Capabilities: no ambient access.
//!
//! A Capability is an opaque bearer token for one exact operation and
//! scope, meaningful only to the local Authority that issued it.  This
//! boundary uses process randomness and a local grant table; it is not
//! production cryptography and is not suitable for authority across
//! trust domains.  Both encodings (LUCAP for one capability, LUAUTH for
//! a grant table) are frozen contracts shared with the C++ tree.

const std = @import("std");
const value_mod = @import("../fabric/value.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;

pub const token_size = 32;
const capability_version: u32 = 1;
const capability_magic = [8]u8{ 'L', 'U', 'C', 'A', 'P', 0, 0, 0 };
const authority_magic = [8]u8{ 'L', 'U', 'A', 'U', 'T', 'H', 0, 0 };
const max_name_size = 4096;
const max_grant_count = 65536;

pub const Error = error{ InvalidArgument, OutOfMemory };

const Token = [token_size]u8;

fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= max_name_size and
        std.mem.findScalar(u8, name, 0) == null;
}

// ---------------------------------------------------------------------------
// Capability
// ---------------------------------------------------------------------------

pub const Capability = struct {
    token: Token = @splat(0),
    operation: []u8,
    scope: []u8,

    pub fn clone(self: Capability, allocator: Allocator) !Capability {
        const operation = try allocator.dupe(u8, self.operation);
        errdefer allocator.free(operation);
        return .{
            .token = self.token,
            .operation = operation,
            .scope = try allocator.dupe(u8, self.scope),
        };
    }

    pub fn deinit(self: *Capability, allocator: Allocator) void {
        allocator.free(self.operation);
        allocator.free(self.scope);
        self.* = undefined;
    }

    pub fn valid(self: Capability) bool {
        return !std.mem.allEqual(u8, &self.token, 0) and validName(self.operation) and
            validName(self.scope);
    }
};

/// Deterministic, versioned bytes encoding of one capability.
pub fn encodeCapability(allocator: Allocator, capability: Capability) Error!Value {
    if (!capability.valid()) return Error.InvalidArgument;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &capability_magic);
    try appendU32(allocator, &bytes, capability_version);
    try bytes.appendSlice(allocator, &capability.token);
    try appendU32(allocator, &bytes, @intCast(capability.operation.len));
    try bytes.appendSlice(allocator, capability.operation);
    try appendU32(allocator, &bytes, @intCast(capability.scope.len));
    try bytes.appendSlice(allocator, capability.scope);
    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

/// Strict decode consuming the complete payload.
pub fn decodeCapability(allocator: Allocator, value: Value) Error!Capability {
    if (value.tag() != .bytes) return Error.InvalidArgument;
    const bytes = value.bytes;

    var reader: ByteReader = .{ .data = bytes };
    const magic = reader.take(capability_magic.len) orelse return Error.InvalidArgument;
    if (!std.mem.eql(u8, magic, &capability_magic)) return Error.InvalidArgument;
    if ((reader.u32Value() orelse return Error.InvalidArgument) != capability_version) {
        return Error.InvalidArgument;
    }

    var decoded: Capability = .{ .operation = undefined, .scope = undefined };
    const token = reader.take(token_size) orelse return Error.InvalidArgument;
    @memcpy(&decoded.token, token);

    const operation = reader.string() orelse return Error.InvalidArgument;
    const scope = reader.string() orelse return Error.InvalidArgument;
    if (!reader.done()) return Error.InvalidArgument;

    decoded.operation = try allocator.dupe(u8, operation);
    errdefer allocator.free(decoded.operation);
    decoded.scope = try allocator.dupe(u8, scope);
    if (!decoded.valid()) {
        allocator.free(decoded.operation);
        allocator.free(decoded.scope);
        return Error.InvalidArgument;
    }
    return decoded;
}

// ---------------------------------------------------------------------------
// Authority
// ---------------------------------------------------------------------------
//
// Local issuer and verifier.  The grant table can be encoded into a
// trusted authority Texel and restored after restart.
//
pub const Authority = struct {
    allocator: Allocator,
    grants: std.AutoHashMapUnmanaged(Token, Grant) = .empty,

    const Grant = struct {
        operation: []u8,
        scope: []u8,
    };

    pub fn init(allocator: Allocator) Authority {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Authority) void {
        self.clearGrants();
        self.grants.deinit(self.allocator);
        self.* = undefined;
    }

    /// Mint a fresh token for one operation and scope.  Randomness
    /// crosses the explicit Io boundary.
    pub fn issue(self: *Authority, io: std.Io, operation: []const u8, scope: []const u8) !Capability {
        if (!validName(operation) or !validName(scope)) return Error.InvalidArgument;

        var token: Token = undefined;
        while (true) {
            io.random(&token);
            if (std.mem.allEqual(u8, &token, 0)) continue;
            if (!self.grants.contains(token)) break;
        }

        const grant: Grant = .{
            .operation = try self.allocator.dupe(u8, operation),
            .scope = try self.allocator.dupe(u8, scope),
        };
        errdefer {
            self.allocator.free(grant.operation);
            self.allocator.free(grant.scope);
        }
        try self.grants.put(self.allocator, token, grant);

        const issued: Capability = .{
            .token = token,
            .operation = try self.allocator.dupe(u8, operation),
            .scope = try self.allocator.dupe(u8, scope),
        };
        return issued;
    }

    pub fn verify(self: *const Authority, capability: Capability, operation: []const u8, scope: []const u8) bool {
        if (!capability.valid()) return false;
        if (!std.mem.eql(u8, capability.operation, operation)) return false;
        if (!std.mem.eql(u8, capability.scope, scope)) return false;

        const grant = self.grants.get(capability.token) orelse return false;
        return std.mem.eql(u8, grant.operation, capability.operation) and
            std.mem.eql(u8, grant.scope, capability.scope);
    }

    pub fn count(self: *const Authority) usize {
        return self.grants.count();
    }

    /// Deterministic bytes encoding of the grant table, sorted by token
    /// so equal tables always produce equal bytes.
    pub fn encode(self: *const Authority) Error!Value {
        if (self.grants.count() > max_grant_count) return Error.InvalidArgument;
        const allocator = self.allocator;

        var tokens: std.ArrayList(Token) = .empty;
        defer tokens.deinit(allocator);
        var keys = self.grants.keyIterator();
        while (keys.next()) |key| try tokens.append(allocator, key.*);
        std.mem.sort(Token, tokens.items, {}, tokenLess);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, &authority_magic);
        try appendU32(allocator, &bytes, capability_version);
        try appendU32(allocator, &bytes, @intCast(tokens.items.len));
        for (tokens.items) |token| {
            const grant = self.grants.get(token).?;
            if (!validName(grant.operation) or !validName(grant.scope)) {
                return Error.InvalidArgument;
            }
            try bytes.appendSlice(allocator, &token);
            try appendU32(allocator, &bytes, @intCast(grant.operation.len));
            try bytes.appendSlice(allocator, grant.operation);
            try appendU32(allocator, &bytes, @intCast(grant.scope.len));
            try bytes.appendSlice(allocator, grant.scope);
        }
        return .{ .bytes = try bytes.toOwnedSlice(allocator) };
    }

    /// Replace the grant table from an encoded value; strict decode.
    pub fn restore(self: *Authority, value: Value) Error!void {
        if (value.tag() != .bytes) return Error.InvalidArgument;
        const allocator = self.allocator;

        var reader: ByteReader = .{ .data = value.bytes };
        const magic = reader.take(authority_magic.len) orelse return Error.InvalidArgument;
        if (!std.mem.eql(u8, magic, &authority_magic)) return Error.InvalidArgument;
        if ((reader.u32Value() orelse return Error.InvalidArgument) != capability_version) {
            return Error.InvalidArgument;
        }
        const grant_count = reader.u32Value() orelse return Error.InvalidArgument;
        if (grant_count > max_grant_count) return Error.InvalidArgument;

        var restored: std.AutoHashMapUnmanaged(Token, Grant) = .empty;
        errdefer {
            var grants = restored.valueIterator();
            while (grants.next()) |grant| {
                allocator.free(grant.operation);
                allocator.free(grant.scope);
            }
            restored.deinit(allocator);
        }

        var index: u32 = 0;
        while (index < grant_count) : (index += 1) {
            var token: Token = undefined;
            const raw = reader.take(token_size) orelse return Error.InvalidArgument;
            @memcpy(&token, raw);
            const operation = reader.string() orelse return Error.InvalidArgument;
            const scope = reader.string() orelse return Error.InvalidArgument;
            if (!validName(operation) or !validName(scope) or restored.contains(token)) {
                return Error.InvalidArgument;
            }
            const grant: Grant = .{
                .operation = try allocator.dupe(u8, operation),
                .scope = undefined,
            };
            errdefer allocator.free(grant.operation);
            const owned_scope = try allocator.dupe(u8, scope);
            errdefer allocator.free(owned_scope);
            try restored.put(allocator, token, .{
                .operation = grant.operation,
                .scope = owned_scope,
            });
        }
        if (!reader.done()) return Error.InvalidArgument;

        self.clearGrants();
        self.grants.deinit(allocator);
        self.grants = restored;
    }

    fn clearGrants(self: *Authority) void {
        var grants = self.grants.valueIterator();
        while (grants.next()) |grant| {
            self.allocator.free(grant.operation);
            self.allocator.free(grant.scope);
        }
        self.grants.clearRetainingCapacity();
    }

    fn tokenLess(_: void, left: Token, right: Token) bool {
        return std.mem.order(u8, &left, &right) == .lt;
    }
};

// ---------------------------------------------------------------------------
// Byte reading
// ---------------------------------------------------------------------------

const ByteReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn take(self: *ByteReader, size: usize) ?[]const u8 {
        if (size > self.data.len - self.offset) return null;
        const slice = self.data[self.offset..][0..size];
        self.offset += size;
        return slice;
    }

    fn u32Value(self: *ByteReader) ?u32 {
        const slice = self.take(4) orelse return null;
        return std.mem.readInt(u32, slice[0..4], .little);
    }

    fn string(self: *ByteReader) ?[]const u8 {
        const length = self.u32Value() orelse return null;
        return self.take(length);
    }

    fn done(self: *const ByteReader) bool {
        return self.offset == self.data.len;
    }
};

fn appendU32(allocator: Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try bytes.appendSlice(allocator, &encoded);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "issue, verify, and reject mismatched or foreign capabilities" {
    const allocator = testing.allocator;
    var authority = Authority.init(allocator);
    defer authority.deinit();

    var capability = try authority.issue(std.testing.io, "write", "notes");
    defer capability.deinit(allocator);

    try testing.expect(authority.verify(capability, "write", "notes"));
    try testing.expect(!authority.verify(capability, "read", "notes"));
    try testing.expect(!authority.verify(capability, "write", "elsewhere"));

    // A different authority never accepts this token.
    var stranger = Authority.init(allocator);
    defer stranger.deinit();
    try testing.expect(!stranger.verify(capability, "write", "notes"));

    try testing.expectError(Error.InvalidArgument, authority.issue(std.testing.io, "", "x"));
}

test "capability round-trips through its value encoding" {
    const allocator = testing.allocator;
    var authority = Authority.init(allocator);
    defer authority.deinit();

    var capability = try authority.issue(std.testing.io, "print", "documents");
    defer capability.deinit(allocator);

    var encoded = try encodeCapability(allocator, capability);
    defer encoded.deinit(allocator);
    var decoded = try decodeCapability(allocator, encoded);
    defer decoded.deinit(allocator);

    try testing.expect(std.mem.eql(u8, &capability.token, &decoded.token));
    try testing.expect(authority.verify(decoded, "print", "documents"));

    // Corruption is refused.
    encoded.bytes[encoded.bytes.len - 1] ^= 1;
    var tampered = try decodeCapability(allocator, encoded);
    defer tampered.deinit(allocator);
    try testing.expect(!authority.verify(tampered, "print", "documents"));
}

test "the grant table encodes deterministically and restores" {
    const allocator = testing.allocator;
    var authority = Authority.init(allocator);
    defer authority.deinit();

    var first = try authority.issue(std.testing.io, "write", "notes");
    defer first.deinit(allocator);
    var second = try authority.issue(std.testing.io, "read", "photos");
    defer second.deinit(allocator);

    var encoded = try authority.encode();
    defer encoded.deinit(allocator);
    var again = try authority.encode();
    defer again.deinit(allocator);
    try testing.expectEqualSlices(u8, encoded.bytes, again.bytes);

    var restored = Authority.init(allocator);
    defer restored.deinit();
    try restored.restore(encoded);
    try testing.expectEqual(@as(usize, 2), restored.count());
    try testing.expect(restored.verify(first, "write", "notes"));
    try testing.expect(restored.verify(second, "read", "photos"));
}
