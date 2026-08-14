//! One line of Caddy's JSON access log, read into a flat record.
//!
//! Caddy writes an object per request holding rather more than this
//! collector counts: TLS parameters, response headers, timings.  What
//! is taken is the nine fields below, and a line missing any of the
//! ones that identify the request is skipped rather than guessed at.
//!
//! Everything returned borrows from the arena the caller passes in,
//! which is expected to be reset between lines.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What one request tells us.  All slices borrow the parse arena.
pub const Record = struct {
    /// Unix seconds, floored.  Caddy writes a float.
    at: i64,
    host: []const u8,
    uri: []const u8,
    method: []const u8,
    /// The address Caddy attributed the request to.
    client: []const u8,
    agent: []const u8,
    referrer: []const u8,
    status: u16,
    size: i64,
};

/// Read one line.  Answers null for a line that is not a request —
/// a malformed line, or one of Caddy's own non-access messages if the
/// logger is ever pointed at a shared file.
pub fn parse(arena: Allocator, line: []const u8) ?Record {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        trimmed,
        .{},
    ) catch return null;

    const top = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    const request = switch (top.get("request") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    const headers = switch (request.get("headers") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => null,
    };

    return .{
        .at = seconds(top.get("ts")) orelse return null,
        .host = string(request.get("host")) orelse return null,
        .uri = string(request.get("uri")) orelse return null,
        .method = string(request.get("method")) orelse "GET",
        // `client_ip` is what Caddy decided after any trusted proxy
        // header; `remote_ip` is who actually connected.  Prefer the
        // decision, fall back to the fact.
        .client = string(request.get("client_ip")) orelse
            string(request.get("remote_ip")) orelse "",
        .agent = header(headers, "User-Agent"),
        .referrer = header(headers, "Referer"),
        .status = code(top.get("status")),
        .size = whole(top.get("size")) orelse 0,
    };
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn whole(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn seconds(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |i| i,
        .float => |f| if (f > 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn code(value: ?std.json.Value) u16 {
    const number = whole(value) orelse return 0;
    if (number < 0 or number > 999) return 0;
    return @intCast(number);
}

/// A header Caddy wrote as an array of values; the first is the one.
fn header(headers: ?std.json.ObjectMap, name: []const u8) []const u8 {
    const map = headers orelse return "";
    const entry = map.get(name) orelse return "";
    return switch (entry) {
        .array => |list| if (list.items.len == 0) "" else string(list.items[0]) orelse "",
        .string => |s| s,
        else => "",
    };
}

const testing = std.testing;

fn parseForTest(arena: Allocator, line: []const u8) !Record {
    return parse(arena, line) orelse error.NotARequest;
}

test "a real access line reads back field for field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const line =
        \\{"level":"info","ts":1786655249.803775,"logger":"http.log.access.log0",
        \\"msg":"handled request","request":{"remote_ip":"209.81.33.152","remote_port":"62208",
        \\"client_ip":"209.81.33.152","proto":"HTTP/2.0","method":"GET","host":"luce.luciaos.com",
        \\"uri":"/guides/toolchain/","headers":{"User-Agent":["curl/8.7.1"],
        \\"Referer":["https://luciaos.com/"],"Accept":["*/*"]}},"bytes_read":0,
        \\"duration":0.00040192,"size":4776,"status":200}
    ;
    const flat = try std.mem.replaceOwned(u8, arena_state.allocator(), line, "\n", "");

    const record = try parseForTest(arena_state.allocator(), flat);
    try testing.expectEqual(@as(i64, 1786655249), record.at);
    try testing.expectEqualStrings("luce.luciaos.com", record.host);
    try testing.expectEqualStrings("/guides/toolchain/", record.uri);
    try testing.expectEqualStrings("GET", record.method);
    try testing.expectEqualStrings("209.81.33.152", record.client);
    try testing.expectEqualStrings("curl/8.7.1", record.agent);
    try testing.expectEqualStrings("https://luciaos.com/", record.referrer);
    try testing.expectEqual(@as(u16, 200), record.status);
    try testing.expectEqual(@as(i64, 4776), record.size);
}

test "missing headers are absent, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const record = try parseForTest(
        arena_state.allocator(),
        \\{"ts":1786655249.5,"request":{"client_ip":"1.2.3.4","host":"loom.luciaos.com","uri":"/","method":"GET"},"status":304}
        ,
    );
    try testing.expectEqualStrings("", record.agent);
    try testing.expectEqualStrings("", record.referrer);
    try testing.expectEqual(@as(i64, 0), record.size);
    try testing.expectEqual(@as(u16, 304), record.status);
}

test "lines that are not requests are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(parse(arena, "") == null);
    try testing.expect(parse(arena, "   ") == null);
    try testing.expect(parse(arena, "not json at all") == null);
    try testing.expect(parse(arena, "{\"level\":\"info\",\"msg\":\"serving\"}") == null);
    // A request with no timestamp cannot be put on a day.
    try testing.expect(parse(arena,
        \\{"request":{"host":"x","uri":"/"},"status":200}
    ) == null);
    // Truncated: a half-written line at the end of a live log.
    try testing.expect(parse(arena, "{\"ts\":1786655249.5,\"request\":{\"host\"") == null);
}

test "escapes in a uri and an agent survive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const record = try parseForTest(
        arena_state.allocator(),
        \\{"ts":1,"request":{"client_ip":"::1","host":"luce.luciaos.com","uri":"/search?q=a%20b\"c","method":"GET","headers":{"User-Agent":["Mozilla/5.0 (\"quoted\")"]}},"status":200}
        ,
    );
    try testing.expectEqualStrings("/search?q=a%20b\"c", record.uri);
    try testing.expectEqualStrings("Mozilla/5.0 (\"quoted\")", record.agent);
}
