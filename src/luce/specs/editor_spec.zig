//! The flagship program, driven by a scripted keyboard.
//!
//! `programs/editor.luc` is the largest thing written in Luce, and
//! until now the only thing standing behind it was a compile test:
//! nothing said what it *did*.  That is exactly the guarantee a
//! restructuring needs, and `docs/METHODS.md` named the line where its
//! absence would have cost something — `editor.luc`'s backspace branch
//! deliberately measures against the content *before* the erase, and
//! under `var self` there is no second name to measure against.  A
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

/// Every key the editor handles, in an order where each one can be
/// seen to have changed what the next one did: type, move by word and
/// by line, split a line, indent, erase from both sides, save, and
/// quit through the unsaved-changes gate.
const script = [_]agree.World.Key{
    .{ .name = "text", .text = "ab" },
    .{ .name = "enter" },
    .{ .name = "text", .text = "cd" },
    .{ .name = "left" },
    // Backspace against a shortened line: the branch that reads the
    // content as it was *before* the erase (docs/METHODS.md).
    .{ .name = "backspace" },
    .{ .name = "up" },
    .{ .name = "end" },
    .{ .name = "tab" },
    .{ .name = "home" },
    .{ .name = "down" },
    .{ .name = "right" },
    .{ .name = "delete" },
    .{ .name = "page_up" },
    .{ .name = "page_down" },
    .{ .name = "ctrl_s" },
    .{ .name = "ctrl_q" },
    .{ .name = "ctrl_q" },
};

fn drive() !agree.Session {
    var world: agree.World = .withFile("notes.txt", "hello\nworld\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &script;
    return agree.compare(editor, .{ .world = world });
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
    try testing.expectEqual(@as(usize, 31834), session.printed().len);
    try testing.expectEqual(
        @as(u64, 4313717895958081035),
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
const expected_content = "ab    \ndello\nworld\n";
