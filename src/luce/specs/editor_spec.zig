//! The flagship program, driven by a scripted keyboard.
//!
//! `examples/editor/editor.luc` is the largest thing written in Luce, and
//! until now the only thing standing behind it was a compile test:
//! nothing said what it *did*.  That is exactly the guarantee a
//! restructuring needs, and `docs/METHODS.md` named the line where its
//! absence would have cost something — `editor.luc`'s backspace branch
//! deliberately measures against the content *before* the erase, and
//! an implied writing `self` has no second copy to measure against.  A
//! conversion that missed it would move the cursor by the wrong number
//! of bytes and nothing would have noticed.
//!
//! So this drives the editor through every key it handles and compares
//! the whole terminal transcript byte for byte, on **both engines**
//! (`specs/agree.zig`).  The transcript below was recorded from the
//! editor as it stood before the merge into `struct State`; the same
//! bytes after it are the proof the memo asked for.
//!
//! It is deliberately one long script rather than several short ones:
//! what is under test is a state machine, and the interesting bugs are
//! the ones where an earlier key changes what a later one does.

const std = @import("std");
const agree = @import("agree.zig");

const testing = std.testing;

/// The program itself, not a copy of it.  A test that pins a
/// transcript against its own inline copy of a program pins nothing.
const editor = @embedFile("editor.luc");
const editor_model = @embedFile("editor_model.luc");
const editor_files = [_]agree.File{
    .{ .name = "editor_model", .source = editor_model },
};

/// Every key the editor handles, in an order where each one can be
/// seen to have changed what the next one did: type, move by word and
/// by line, split a line, indent, erase from both sides, save, and
/// quit through the unsaved-changes gate.
const script = [_]agree.World.Key{
    .{ .name = "text", .text = "ab" },
    .{ .name = "enter" },
    // **`éxy`, and the cursor left twice, on purpose.**  The backspace
    // below is the branch that measures against the content as it was
    // *before* the erase (docs/METHODS.md), and the two readings agree
    // on almost everything — `previous_boundary` walks back over UTF-8
    // continuation bytes, and after an erase the byte at the old
    // cursor's left is the *following* character's first byte, which
    // is never a continuation.  They part company in exactly one
    // shape: a **two-byte** character erased with single-byte text
    // after the cursor, where the byte that slides into place is the
    // second byte of what follows.  Two earlier versions of this
    // script — all-ASCII, then multi-byte in the wrong position —
    // both let a mutation reverting the snapshot through, and the
    // mutation sweep is what said so each time.
    .{ .name = "text", .text = "éxy" },
    .{ .name = "left" },
    .{ .name = "left" },
    .{ .name = "backspace" },
    .{ .name = "up" },
    .{ .name = "end" },
    .{ .name = "tab" },
    .{ .name = "home" },
    .{ .name = "down" },
    .{ .name = "right" },
    .{ .name = "delete" },
    .{ .name = "page_down" },
    .{ .name = "ctrl_s" },
    .{ .name = "ctrl_q" },
    .{ .name = "ctrl_q" },
};

fn drive() !agree.Session {
    var world: agree.World = .withFile("notes.txt", "hello\nworld\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &script;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    return agree.compareProgram(&program, .{ .world = world });
}

test "the editor draws the same frames, key for key, on both engines" {
    var session = try drive();
    defer session.deinit();

    // The two engines agreed on every byte of this — that is what
    // `compare` asserted before it answered — so what is left to pin
    // is that the *program* still does what it did.
    //
    // As a length and a hash, and deliberately: the transcript is
    // several thousand bytes of frames, and a copy of it in this file
    // would be something no reader could check and every reader would
    // update by pasting whatever came out.  A number cannot be updated
    // that way without noticing.  What a person *can* read is the file
    // the keys left behind, which the test below pins in full.
    // Recorded from the editor as it stood before the merge into
    // `struct State`.  If this moves, the restructuring changed what
    // the program draws — which is exactly the thing docs/METHODS.md
    // said could go quietly wrong.
    try testing.expectEqual(@as(usize, 31856), session.printed().len);
    try testing.expectEqual(
        @as(u64, 5049734095918354461),
        std.hash.Wyhash.hash(0, session.printed()),
    );
}

test "the editor's keys reach the file, and the unsaved gate holds" {
    var session = try drive();
    defer session.deinit();

    // Ctrl-S wrote, so the world holds what the editing produced —
    // and the exact bytes are what the backspace branch decides.
    const left = session.file().?;
    try testing.expectEqualStrings("notes.txt", left.name);
    try testing.expectEqualStrings(expected_content, left.content);
}

/// What the scripted keys leave in the file.
const expected_content = "ab    \nxhello\nworld\n";

test "Enter carries indentation and opens one level after a code colon" {
    const keys = [_]agree.World.Key{
        .{ .name = "text", .text = "if true:" },
        .{ .name = "enter" },
        .{ .name = "text", .text = "print" },
        .{ .name = "enter" },
        // A colon inside a string is not a block opener.
        .{ .name = "text", .text = "value = \"not a block:\"" },
        .{ .name = "enter" },
        // A comment after a colon does not hide the block opener.
        .{ .name = "text", .text = "if true: # comment" },
        .{ .name = "enter" },
        .{ .name = "text", .text = "done" },
        .{ .name = "ctrl_s" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings(
        "if true:\n    print\n    value = \"not a block:\"\n    if true: # comment\n        done",
        session.file().?.content,
    );
}

test "a save that will not land says what the runtime said, not what the editor guessed" {
    // `save` used to build "cannot write " and the path itself, which
    // is the program writing the runtime's sentence a second time and
    // happening to agree with it.  `catch reason:` reads the words the
    // error carried, so the status line is the answer rather than a
    // guess (docs/FAILURE.md).
    const keys = [_]agree.World.Key{
        .{ .name = "text", .text = "x" },
        .{ .name = "ctrl_s" },
        .{ .name = "ctrl_q" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "hello\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    world.refuse_writes = true;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    const shown = try screenText(session.printed());
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "cannot write notes.txt") != null);
    // The write was refused, so nothing about the file moved.
    try testing.expectEqualStrings("hello\n", session.file().?.content);
}

test "Ctrl-B saves, runs the current file and shows the host transcript" {
    const keys = [_]agree.World.Key{
        .{ .name = "ctrl_b" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "print(\"hello\")\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    const shown = try screenText(session.printed());
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "mock shell: loom luce 'notes.txt'") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "exit status: 0") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "─ output ") != null);
}

test "the file pane is optional and receives focus through the pane cycle" {
    const keys = [_]agree.World.Key{
        .{ .name = "ctrl_e" },
        .{ .name = "ctrl_w" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "hello\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    const shown = try screenText(session.printed());
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "[files]") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "┌ files") != null);
}

/// The characters a transcript put on the screen, with the frame
/// bookkeeping taken out.
///
/// The editor colours per character, so it calls `term_write` once per
/// character and the transcript is one `[write]` line each: what a
/// reader sees as a sentence is never a substring of it.  The caller
/// owns the result.
fn screenText(transcript: []const u8) ![]u8 {
    var shown: std.ArrayList(u8) = .empty;
    errdefer shown.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, transcript, '\n');
    while (lines.next()) |line| {
        const prefix = "[write]";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        try shown.appendSlice(testing.allocator, line[prefix.len..]);
    }
    return shown.toOwnedSlice(testing.allocator);
}
