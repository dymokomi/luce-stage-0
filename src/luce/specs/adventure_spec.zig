//! The adventure engine, played through on both engines.
//!
//! `examples/adventure/adventure.luc` and the four modules it imports are the
//! largest thing written in Luce — a project rather than a file, and
//! the only program in the tree where a struct in one module is built
//! by a factory in a second, handed to a third, and saved by a fourth.
//! What that buys the language is coverage no thousand-line corpus of
//! small programs has: the ownership rules meet a real data model, the
//! visibility rules meet a real module boundary, and the failure rules
//! meet a real disk.
//!
//! So this drives the whole game through a scripted keyboard — one
//! `read_line` a turn, the way a pipe drives it — and compares the
//! entire transcript, the save file left behind, and the way the run
//! ended, byte for byte, on both engines (`specs/agree.zig`).
//!
//! It is deliberately one long playthrough rather than a test per
//! verb: what is under test is a state machine over a mutable world,
//! and the interesting bugs are the ones where an earlier turn changes
//! what a later one does — a door unlocked twenty lines ago, a thing
//! whose room index moved, a save written before a drop and loaded
//! after it.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");

const testing = std.testing;

/// The programs themselves, not copies of them: a spec that pinned
/// its own inline copy of a program would pin nothing.
const root = @embedFile("adventure.luc");

const modules = [_]agree.File{
    .{ .name = "world", .source = @embedFile("world.luc") },
    .{ .name = "story", .source = @embedFile("story.luc") },
    .{ .name = "command", .source = @embedFile("command.luc") },
    .{ .name = "journal", .source = @embedFile("journal.luc") },
};

/// Compile the project once and play `script` against `world`.  The
/// caller owns the session.
fn play(script: []const []const u8, world: agree.World) !agree.Session {
    var scripted = world;
    scripted.lines = script;
    var program = try agree.project(root, &modules);
    defer program.deinit();
    return agree.compareProgram(&program, .{ .world = scripted });
}

/// A world with no file in it and no arguments: a new game.
fn fresh() agree.World {
    var world: agree.World = .{};
    world.arguments = &.{};
    return world;
}

/// Every turn of a finished game.  Ordered so that each of the four
/// modules is asked something the previous turns changed: the locked
/// door is tried before the key exists and after, the save is written
/// before a drop and loaded after it, and the last move opens the
/// second door with the thing found behind the first.
const winning = [_][]const u8{
    "help",
    "dance",
    "i",
    "north",
    "north",
    "down",
    "east",
    "south",
    "east",
    "take brass key",
    "x brass key",
    "west",
    "north",
    "down",
    "take iron crank",
    "up",
    "west",
    "take glass lens",
    "take leather journal",
    "drop leather journal",
    "i",
    "save",
    "east",
    "up",
    "load",
    "up",
    "east",
    "up",
    "up",
};

test "a whole game plays the same, turn for turn, on both engines" {
    var session = try play(&winning, fresh());
    defer session.deinit();

    // The two engines agreed on every byte of the transcript before
    // `compare` answered — that is what a spec here *is*.  What is
    // left to pin is that the program still does what it did, and it
    // is pinned as a length and a hash for the reason the editor's is:
    // four kilobytes of prose in this file is something no reader
    // would check and every reader would update by pasting whatever
    // came out.  A number cannot be updated that way without noticing,
    // and the sentences a person can actually read are checked by name
    // below.
    try testing.expectEqual(@as(usize, 3418), session.printed().len);
    try testing.expectEqual(
        @as(u64, 13891474034538433332),
        std.hash.Wyhash.hash(0, session.printed()),
    );

    // The run ended because the story did, not because anything went
    // wrong: the loop stopped on its own and scope ownership freed the
    // realm, the save and every list either of them held (S33).
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);

    const transcript = session.printed();
    // A locked door says what it wants, and stays shut.
    try expectSaid(transcript, "The way down is locked. It wants a brass key.");
    // …and opens once, with the thing it asked for.
    try expectSaid(transcript, "The brass key turns, and the way down opens.");
    try expectSaid(transcript, "The iron crank turns, and the way up opens.");
    // A verb the parser has never heard of quotes the player back.
    try expectSaid(transcript, "I do not know how to dance.");
    // A room seen a second time is announced short, without its
    // paragraph — `look(at, brief = …)`, defaulted at every other site.
    try expectSaid(transcript, "Hall\nWays out: south, west, up, down.");
    // The load came back with what the save was holding, which is the
    // one place a `copy` of a private list crosses a module boundary.
    try expectSaid(transcript, "Loaded adventure.sav, carrying brass key, iron crank, glass lens.");
    // And the story ended.
    try expectSaid(transcript, "You finished the story in 26 turns.");
}

test "the save the game wrote is the save the game reads" {
    var session = try play(&winning, fresh());
    defer session.deinit();

    // Both engines left this world in the same state — `settle`
    // compared them — so what is pinned here is the format itself:
    // five lines, in the order `journal.Save.text` writes them, and
    // the inverse of what `journal.read` took apart twenty turns
    // before the game ended.
    const left = session.file().?;
    try testing.expectEqualStrings("adventure.sav", left.name);
    try testing.expectEqualStrings(
        \\adventure 1
        \\room Library
        \\moves 22
        \\held brass key|iron crank|glass lens
        \\seen Gate|Courtyard|Hall|Library|Cellar|Garden
        \\
    , left.content);
}

test "quit ends the run with a status, and says what the game came to" {
    var session = try play(&.{ "north", "east", "take brass key", "quit" }, fresh());
    defer session.deinit();

    // `exit(0)` is the fourth way a run ends, and the one a player
    // asks for by name: not a trap, because nothing is wrong, and not
    // an error, because nothing failed (docs/LANGUAGE.md).
    try testing.expectEqual(agree.End{ .exited = 0 }, session.end);
    try expectSaid(session.printed(), "You walked into 3 rooms and are carrying 1 thing.");
}

test "a save named on the command line that is not there ends the run as news" {
    // The premise of the run was "resume this game".  There is no game
    // to play instead, so `main` says `try` and the error travels out
    // of three files — `journal.read`, `std.files.read`, the host —
    // with nothing written for it on the way (docs/FAILURE.md).
    var world = fresh();
    world.arguments = &[_][]const u8{"rescue"};
    var program = try agree.project(root, &modules);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    try testing.expectEqual(agree.End{ .errored = .io_failed }, session.end);
    // `journal.named` gave the bare name the game's own extension,
    // and the host's own sentence is what came back — not a second
    // one the program guessed and happened to agree with.
    try testing.expectEqualStrings("cannot read rescue.sav", session.message());
}

test "a save that names a room this story has not got is refused by name" {
    // The other end of the same chain, and the one that is the
    // program's own words: the file read fine, and what was in it
    // does not describe this game.  `world.Realm.mark_seen` raises,
    // `journal.Save.into` passes it on with `try`, and `main` never
    // catches it.
    var world = fresh();
    world.arguments = &[_][]const u8{"rescue.sav"};
    world.place("rescue.sav",
        \\adventure 1
        \\room Hall
        \\moves 3
        \\held brass key
        \\seen Gate|Scullery
        \\
    );
    var program = try agree.project(root, &modules);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    try testing.expectEqual(agree.End{ .errored = .user_error }, session.end);
    try testing.expectEqualStrings(
        "the save has been in Scullery, which this story has no room called",
        session.message(),
    );
}

test "a save file that is not one is refused before anything is restored" {
    var world = fresh();
    world.arguments = &[_][]const u8{"notes.txt"};
    world.place("notes.txt", "hello\nworld\n");
    var program = try agree.project(root, &modules);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    try testing.expectEqual(agree.End{ .errored = .user_error }, session.end);
    // The path already had an extension, so `journal.named` left it
    // alone, and `paths.base` is what the sentence quotes.
    try testing.expectEqualStrings(
        "notes.txt does not begin \"adventure 1\" and is not a save of this game",
        session.message(),
    );
}

test "a save the world refuses mid-game is said and played past" {
    // The same failure, arriving at the other decision.  A player
    // typing `save` is still standing in a room, so the loop catches
    // the reason with `catch reason:`, says it, and asks again.  The
    // attempted turn has already incremented the in-place receiver;
    // SELF deliberately does not roll a write back when a later disk
    // operation raises (docs/SELF.md D4).
    var world = fresh();
    world.refuse_writes = true;
    var session = try play(&.{ "north", "save", "i", "quit" }, world);
    defer session.deinit();

    try testing.expectEqual(agree.End{ .exited = 0 }, session.end);
    try expectSaid(session.printed(), "The world says no: cannot write adventure.sav");
    // The room tally counts the successful travel, independently of
    // the attempted save's move counter.
    try expectSaid(session.printed(), "You walked into 2 rooms and are carrying 0 things.");
    // Nothing was written.
    try testing.expectEqual(@as(?@TypeOf(session.file().?), null), session.file());
}

test "the modules answer a program of somebody else's, through their public surface" {
    // The visibility positive.  `world` and `story` are written to be
    // imported, and this is a second root that imports them: it builds
    // the realm with the story's own factory, walks it with the
    // realm's own questions, and never names one of the private fields
    // the game itself cannot name either.  If a `private` marker ever
    // moves onto something a caller genuinely needs, this stops
    // compiling before the game does.
    var program = try agree.project(
        \\import world
        \\import story
        \\import std.strings
        \\
        \\func main():
        \\    var realm = story.build()
        \\    var at = story.start(realm)
        \\    realm.visit(at)
        \\    assert(realm.name_at(at) == "Gate")
        \\    let way = realm.way_out(at, "north")
        \\    if way == none:
        \\        trap("the gate has no way north")
        \\    at = way.beyond()
        \\    realm.visit(at)
        \\    assert(realm.name_at(at) == "Courtyard")
        \\    let ways = realm.ways_out(at)
        \\    assert(ways.join(" ") == "south north east")
        \\    let bench = realm.thing_in(at, "stone bench")
        \\    if bench == none:
        \\        trap("the courtyard has lost its bench")
        \\    assert(not bench.liftable())
        \\    assert(not realm.pick_up(at, "stone bench"))
        \\    let places, things = realm.tally()
        \\    assert(places == 2 and things == 0)
        \\    assert(len(story.ending(realm, at, 1)) == 0)
        \\
    , &modules);
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "what the root may not reach: the model's own fields, and the factory that answers" {
    // The visibility negative, and the reason the model is written the
    // way it is.  These two refusals are what make `world.Room.make`
    // the only door: a field the module keeps cannot be read from
    // outside it, and a struct with a required private field cannot be
    // built from outside it either — which is the sentence that names
    // the factory pattern (docs/VISIBILITY.md §3).
    //
    // A compile-time fact has no engine to disagree about, so this one
    // runs nothing; it lives here rather than beside the driver
    // because the modules it is about are this file's.
    try expectPrivate(
        \\import world
        \\
        \\func main():
        \\    let room = world.Room.make(name = "Cell", description = "dark")
        \\    print(room.description)
        \\
    , "description of Room is private to world");
    try expectPrivate(
        \\import world
        \\
        \\func main():
        \\    let room = world.Room(name = "Cell")
        \\    print(room.name)
        \\
    , "Room cannot be constructed here: description is marked private in world and has no default; construction belongs to a public function of world");
}

/// The program's own modules, as the compiler's loader sees them.
const Loaded = struct {
    fn find(
        context: *anyopaque,
        arena: std.mem.Allocator,
        name: []const u8,
        from_root: []const u8,
    ) error{OutOfMemory}!luce.source.Found {
        _ = context;
        _ = from_root; // One rootless table; the token distinguishes nothing here.
        for (modules) |file| {
            if (std.mem.eql(u8, file.name, name)) {
                return .{ .text = .{ .bytes = try arena.dupe(u8, file.source) } };
            }
        }
        return .missing;
    }
};

/// Compile `source` against the real modules and demand exactly one
/// refusal, whose code is `luce.sema.private` and whose words are
/// `saying`.
fn expectPrivate(source: []const u8, saying: []const u8) !void {
    var nobody: u8 = 0;
    var result = try luce.compile.compileProject(
        testing.allocator,
        source,
        .{ .context = &nobody, .load = Loaded.find },
        .{ .allow_host = true },
    );
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected '{s}', but this compiled:\n{s}", .{ saying, source });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), result.failure.count());
    const found = result.failure.at(0).?;
    try testing.expectEqualStrings("luce.sema.private", found.code);
    try testing.expectEqualStrings(saying, found.message);
}

/// Demand one sentence of a transcript, with a readable failure.
fn expectSaid(transcript: []const u8, sentence: []const u8) !void {
    if (std.mem.indexOf(u8, transcript, sentence) != null) return;
    std.debug.print("the transcript never said:\n{s}\n", .{sentence});
    return error.TestUnexpectedResult;
}
