//! std.network, on both engines (docs/NETWORK.md).
//!
//! The world simulates the smallest transport that still proves the
//! contract: one listener, one connected pair, short writes, and a
//! close the other end can see.  What these specs hold is the whole
//! visible surface — the door opens and says its port, a dial reaches
//! an accept, bytes cross both directions through the short-write
//! loop, a dropped endpoint reads as end of stream, a refused world is
//! a catchable `io_failed` naming the transport verb, and a host with
//! no channel at all fails closed before touching anything.  Blocking
//! behavior deliberately is not here: a single-threaded oracle cannot
//! block for a peer, so the fixture refuses where reality would wait,
//! and real blocking belongs to the shipped host and its product
//! smoke tests.

const std = @import("std");
const testing = std.testing;
const agree = @import("agree.zig");
const luce = @import("luce");

const hosted = struct {
    const imports = "import std.network\n\n";

    fn source(body: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ imports, body });
    }

    fn printsGiven(body: []const u8, provided: agree.Provided, expected: []const u8) !void {
        const program = try source(body);
        defer testing.allocator.free(program);
        return agree.printsGiven(program, provided, expected);
    }

    fn prints(body: []const u8, expected: []const u8) !void {
        return printsGiven(body, .{}, expected);
    }

    fn trapGiven(body: []const u8, provided: agree.Provided, code: luce.mir.TrapCode) !void {
        const program = try source(body);
        defer testing.allocator.free(program);
        return agree.trapGiven(program, provided, code);
    }
};

test "a listener opens, says its port, and carries one round trip" {
    // The whole happy path in one program: listen(0) answers the
    // world's ephemeral port, the dial reaches the accept, five bytes
    // cross in short pieces — the world takes three at a time, so the
    // write loop is proven, not assumed — and a reply crosses back the
    // other way.
    try hosted.prints(
        \\func send(conn: network.Connection, data: array[u8, _], count: i64) -> !:
        \\    var at: i64 = 0
        \\    while at < count:
        \\        var piece = new array[u8](count - at)
        \\        var held: i64 = 0
        \\        while at + held < count:
        \\            piece[held] = data[at + held]
        \\            held += 1
        \\        let landed = try conn.write(piece, held)
        \\        if landed <= 0:
        \\            error("the write made no progress")
        \\        at += landed
        \\    try conn.flush()
        \\
        \\func take(conn: network.Connection, count: i64) -> list[u8]!:
        \\    var got = new list[u8]
        \\    var buffer = new array[u8](count)
        \\    while len(got) < count:
        \\        let landed = try conn.read(buffer)
        \\        if landed == 0:
        \\            error("the peer finished early")
        \\        var at: i64 = 0
        \\        while at < landed:
        \\            got.append(buffer[at])
        \\            at += 1
        \\    return got
        \\
        \\func main() -> !:
        \\    let door = try network.listen(0)
        \\    print(str(try door.port()))
        \\
        \\    let client = try network.connect("localhost", try door.port())
        \\    let served = try door.accept()
        \\
        \\    var hello = new array[u8](5)
        \\    var at: i64 = 0
        \\    while at < 5:
        \\        hello[at] = u8(104 + at)
        \\        at += 1
        \\    try send(client, hello, 5)
        \\    let heard = try take(served, 5)
        \\    print(str(heard[0]) + " " + str(heard[4]))
        \\
        \\    var reply = new array[u8](2)
        \\    reply[0] = 111
        \\    reply[1] = 107
        \\    try send(served, reply, 2)
        \\    let answered = try take(client, 2)
        \\    print(str(answered[0]) + " " + str(answered[1]))
        \\
    , "49152\n104 108\n111 107\n");
}

test "dropping the dialing end is the served end's end of stream" {
    // The client lives only inside `dial_and_send`: returning releases
    // it, the release closes the socket, and the served end then
    // drains the byte that was written and reads zero — the same
    // sentence a file ends with, from a peer instead of a disk.
    try hosted.prints(
        \\func dial_and_send(door: network.Listener) -> network.Connection!:
        \\    let client = try network.connect("localhost", 4000)
        \\    let served = try door.accept()
        \\    var one = new array[u8](1)
        \\    one[0] = 42
        \\    let sent = try client.write(one, 1)
        \\    if sent != 1:
        \\        error("the byte did not land")
        \\    return served
        \\
        \\func main() -> !:
        \\    let door = try network.listen(4000)
        \\    let served = try dial_and_send(door)
        \\    var buffer = new array[u8](8)
        \\    let drained = try served.read(buffer)
        \\    print("drained " + str(drained) + " worth " + str(buffer[0]))
        \\    let finished = try served.read(buffer)
        \\    print("finished " + str(finished))
        \\
    , "drained 1 worth 42\nfinished 0\n");
}

test "a refused world answers io_failed naming the transport verb" {
    var refused: agree.Provided = .{};
    refused.world.refuse_network = true;
    try hosted.printsGiven(
        \\func dial() -> !:
        \\    let held = try network.connect("localhost", 80)
        \\
        \\func open_door() -> !:
        \\    let held = try network.listen(80)
        \\
        \\func main():
        \\    dial() catch reason:
        \\        print(reason)
        \\    open_door() catch reason:
        \\        print(reason)
        \\
    , refused, "cannot connect to localhost\ncannot listen on :80\n");
}

test "an accept with nobody dialing is the world refusing, not a hang" {
    // Reality would block; the single-threaded fixture refuses
    // instead, and the refusal travels the ordinary error channel
    // naming the door it happened on.
    try hosted.prints(
        \\func wait_for_peer(door: network.Listener) -> !:
        \\    let held = try door.accept()
        \\
        \\func main() -> !:
        \\    let door = try network.listen(5000)
        \\    wait_for_peer(door) catch reason:
        \\        print(reason)
        \\
    , "cannot accept on :5000\n");
}

test "a worker inherits the transport channel" {
    // A worker's runtime is its own; the host's channels are the
    // run's.  A listener opened inside a spawned function proves the
    // socket channel crossed with the rest — the regression this
    // pins was a worker that trapped `host_unavailable` at `listen`
    // while its parent dialed happily.
    try hosted.prints(
        \\func open_door() -> i64!:
        \\    let door = try network.listen(0)
        \\    return try door.port()
        \\
        \\func main() -> !:
        \\    let worker = spawn open_door()
        \\    print(str(try worker.wait()))
        \\
    , "49152\n");
}

test "a host without the transport channel fails closed" {
    // The gate is the reached operation, not the import: a missing
    // channel traps `host_unavailable` before touching anything, on
    // both engines, and no `catch` stands in a trap's way.
    try hosted.trapGiven(
        \\func main() -> !:
        \\    let held = try network.listen(80)
        \\
    , .{ .network = false }, .host_unavailable);
}
