//! std.http, on both engines.
//!
//! The world plays the server: `canned_reply` makes any dial succeed
//! against a peer that has already answered and hung up, so a
//! single-threaded spec runs a whole exchange — request written,
//! reply parsed — and the request the client sent is inspectable
//! afterward in the world's `toward_served` queue.  What these specs
//! hold: the request line and headers the client writes, the status
//! and headers it reads back, Content-Length and chunked bodies, a
//! 404 travelling as data, and the honest refusals — https, and a
//! reply that is not HTTP.

const std = @import("std");
const testing = std.testing;
const agree = @import("agree.zig");

const hosted = struct {
    const imports = "import std.http\nimport std.strings\n\n";

    fn source(body: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ imports, body });
    }

    fn compare(body: []const u8, provided: agree.Provided) !agree.Session {
        const program = try source(body);
        defer testing.allocator.free(program);
        return agree.compare(program, provided);
    }

    fn printsGiven(body: []const u8, provided: agree.Provided, expected: []const u8) !void {
        const program = try source(body);
        defer testing.allocator.free(program);
        return agree.printsGiven(program, provided, expected);
    }
};

fn served(reply: []const u8) agree.Provided {
    var provided: agree.Provided = .{};
    provided.world.canned_reply = reply;
    return provided;
}

/// The request bytes one arm's client wrote, for asserting the wire.
fn requestOf(world: anytype) []const u8 {
    return world.toward_served[0..world.toward_served_length];
}

test "a get reads status, headers, and a content-length body" {
    var session = try hosted.compare(
        \\func main() -> !:
        \\    let page = try http.get("http://example.test/index.html")
        \\    print(str(page.status))
        \\    let kind = page.headers.get("content-type")
        \\    if kind == none:
        \\        print("no kind")
        \\        return
        \\    print(kind)
        \\    var held = new list[u8]
        \\    for b in page.body:
        \\        held.append(b)
        \\    let text = strings.from_bytes(held)
        \\    if text == none:
        \\        print("not text")
        \\        return
        \\    print(text)
        \\
    , served("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"));
    defer session.deinit();

    try testing.expectEqualStrings("200\ntext/plain\nhello\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
    // Both arms put the same request on the wire: the asked-for path,
    // the host the URL named, and the one-shot connection promise.
    for ([_][]const u8{
        requestOf(&session.reference.world),
        requestOf(&session.capture.world),
    }) |request| {
        try testing.expect(std.mem.startsWith(u8, request, "GET /index.html HTTP/1.1\r\n"));
        try testing.expect(std.mem.indexOf(u8, request, "\r\nHost: example.test\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, request, "\r\nConnection: close\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, request, "\r\n\r\n"));
    }
}

test "a chunked reply is decoded into the body it framed" {
    try hosted.printsGiven(
        \\func main() -> !:
        \\    let page = try http.get("http://example.test/")
        \\    var held = new list[u8]
        \\    for b in page.body:
        \\        held.append(b)
        \\    let text = strings.from_bytes(held)
        \\    if text == none:
        \\        print("not text")
        \\        return
        \\    print(str(len(page.body)) + " " + text)
        \\
    , served("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), "11 hello world\n");
}

test "a 404 is an answer, not an error" {
    try hosted.printsGiven(
        \\func main() -> !:
        \\    let page = try http.get("http://example.test/absent")
        \\    print("answered " + str(page.status))
        \\
    , served("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"), "answered 404\n");
}

test "a post carries its body, its type, and its length" {
    var session = try hosted.compare(
        \\func main() -> !:
        \\    var note = strings.to_bytes("dear server")
        \\    let page = try http.post("http://example.test/notes", note, "text/plain")
        \\    print(str(page.status))
        \\
    , served("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n"));
    defer session.deinit();

    try testing.expectEqualStrings("201\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
    for ([_][]const u8{
        requestOf(&session.reference.world),
        requestOf(&session.capture.world),
    }) |request| {
        try testing.expect(std.mem.startsWith(u8, request, "POST /notes HTTP/1.1\r\n"));
        try testing.expect(std.mem.indexOf(u8, request, "\r\nContent-Type: text/plain\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, request, "\r\nContent-Length: 11\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, request, "\r\n\r\ndear server"));
    }
}

test "https and non-http urls are refused with the reason" {
    try hosted.printsGiven(
        \\func fetch(url: str) -> !:
        \\    let held = try http.get(url)
        \\
        \\func main():
        \\    fetch("https://example.test/") catch reason:
        \\        print(str(strings.starts_with(reason, "https is not supported yet")))
        \\    fetch("ftp://example.test/") catch reason:
        \\        print(reason)
        \\
    , .{}, "true\nnot an http url: ftp://example.test/\n");
}

test "a reply that is not HTTP is an error naming what came" {
    try hosted.printsGiven(
        \\func fetch() -> !:
        \\    let held = try http.get("http://example.test/")
        \\
        \\func main():
        \\    fetch() catch reason:
        \\        print(reason)
        \\
    , served("SMTP ready\r\n\r\n"), "not an HTTP reply: SMTP ready\n");
}
