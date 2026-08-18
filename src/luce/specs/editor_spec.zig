//! The flagship program, driven by a scripted keyboard.
//!
//! `examples/editor/editor.luc` is the largest thing written in Luce, and
//! until now the only thing standing behind it was a compile test:
//! nothing said what it *did*.  That is exactly the guarantee a
//! restructuring needs, and `docs/SELF.md` named the line where its
//! absence would have cost something — `editor.luc`'s backspace branch
//! deliberately measures against the content *before* the erase, and
//! an implied writing `self` has no second copy to measure against.  A
//! conversion that missed it would move the cursor by the wrong number
//! of bytes and nothing would have noticed.
//!
//! The scripts here drive the editor through every key it handles and compare
//! the whole terminal transcript byte for byte on **both engines**
//! (`specs/agree.zig`). The program is a retained component tree over one
//! shared model; termui owns the loop and routes each event through it.
//!
//! The first script is deliberately one long one rather than several
//! short ones: what is under test is a state machine, and the
//! interesting bugs are the ones where an earlier key changes what a
//! later one does.  The scripts after it are the keys that cannot be
//! reached from where the long one ends, or that need a world of their
//! own — a pane, a refused write, a mouse.

const std = @import("std");
const agree = @import("agree.zig");

const testing = std.testing;

/// The program itself, not a copy of it.  A test that pins a
/// transcript against its own inline copy of a program pins nothing.
const editor = @embedFile("editor.luc");

/// The editor's own modules and the package it draws through, served the way
/// a store serves them (docs/PACKAGES.md D4). Package internals carry both
/// bare and qualified names because their own imports are bare while the
/// editor imports only the `termui` facade.
const editor_files = [_]agree.File{
    .{ .name = "model", .source = @embedFile("model.luc") },
    .{ .name = "document", .source = @embedFile("document.luc") },
    .{ .name = "history", .source = @embedFile("history.luc") },
    .{ .name = "highlight", .source = @embedFile("highlight.luc") },
    .{ .name = "listing", .source = @embedFile("listing.luc") },
    .{ .name = "session", .source = @embedFile("session.luc") },
    .{ .name = "ui.workbench", .source = @embedFile("ui/workbench.luc"), .path = "ui/workbench.luc" },
    .{ .name = "ui.source", .source = @embedFile("ui/source.luc"), .path = "ui/source.luc" },
    .{ .name = "ui.filelist", .source = @embedFile("ui/filelist.luc"), .path = "ui/filelist.luc" },
    .{ .name = "ui.console", .source = @embedFile("ui/console.luc"), .path = "ui/console.luc" },
    .{ .name = "ui.statusbar", .source = @embedFile("ui/statusbar.luc"), .path = "ui/statusbar.luc" },
    .{ .name = "ui.keymap", .source = @embedFile("ui/keymap.luc"), .path = "ui/keymap.luc" },
    .{ .name = "ui.theme", .source = @embedFile("ui/theme.luc"), .path = "ui/theme.luc" },
} ++ termui_files;

const termui_root = "termui-0.5.0";
const termui_files = package("termui", @embedFile("termui/termui.luc")) ++
    package("model", @embedFile("termui/model.luc")) ++
    package("input", @embedFile("termui/input.luc")) ++
    package("constraints", @embedFile("termui/constraints.luc")) ++
    package("layout", @embedFile("termui/layout.luc")) ++
    package("canvas", @embedFile("termui/canvas.luc")) ++
    package("view", @embedFile("termui/view.luc")) ++
    package("widgets", @embedFile("termui/widgets.luc")) ++
    package("runtime", @embedFile("termui/runtime.luc"));

/// One package module under both of its spellings.  Every bare spelling
/// but the entry module's is pinned with `from` to the package's own
/// root, so a package module's `import surface` reaches it while a
/// consumer's bare import of the same name does not — the editor and
/// termui both have a `layout` module, and this keeps them apart the way
/// the real store's root token does, rather than leaning on file order.
/// The entry module is the exception: a consumer imports it bare
/// (`import termui`), so its bare row must resolve from any root — and
/// `termui` never collides with a consumer module name, so leaving it
/// open is safe.
fn package(comptime name: []const u8, comptime source: []const u8) [2]agree.File {
    const at = termui_root ++ "/" ++ name ++ ".luc";
    const internal: ?[]const u8 = if (std.mem.eql(u8, name, "termui")) null else termui_root;
    return .{
        .{ .name = name, .source = source, .path = at, .root = termui_root, .from = internal },
        .{ .name = "termui." ++ name, .source = source, .path = at, .root = termui_root },
    };
}

/// Every key the editor handles, in an order where each one can be
/// seen to have changed what the next one did: type, move by word and
/// by line, split a line, indent, erase from both sides, save, and
/// quit through the unsaved-changes gate.
const script = [_]agree.World.Key{
    .{ .name = "text", .text = "ab" },
    .{ .name = "enter" },
    // **`éxy`, and the cursor left twice, on purpose.**  The backspace
    // below is the branch that measures against the content as it was
    // *before* the erase (docs/SELF.md), and the two readings agree
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
    // Re-recorded for declarative termui v0.3. The same eighteen keys over
    // the same file once left 31,856 bytes of terminal traffic; the retained
    // front buffer now needs 5,216. If this moves, the program drew something
    // else, so the readable state assertions below must justify the change.
    try testing.expectEqual(@as(usize, 5216), session.printed().len);
    try testing.expectEqual(
        @as(u64, 5925325842466829948),
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
    // The terminal wraps long shell transcripts at its 80-column edge, so
    // the complete command is not one contiguous screen substring.  Pin
    // the executable-first command prefix and its generated output name
    // separately; together they keep Ctrl-B's build-and-run contract while
    // matching what a user can actually see.
    try testing.expect(std.mem.indexOf(u8, shown, "mock shell: luce build 'notes.txt' --emit=exe") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "notes.txt.run") != null);
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
    try testing.expect(std.mem.indexOf(u8, shown, "─ files") != null);
}

test "Ctrl-O opens the output pane, and Escape hands focus back to the text" {
    // The three keys the long script cannot reach: it ends in the
    // editor with a file to save, and these move focus somewhere else
    // first.  `escape` is answered before pane dispatch, so what proves
    // it is where the next character lands.
    const keys = [_]agree.World.Key{
        .{ .name = "ctrl_o" },
        .{ .name = "page_up" },
        .{ .name = "escape" },
        .{ .name = "text", .text = "Z" },
        .{ .name = "ctrl_s" },
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
    try testing.expect(std.mem.indexOf(u8, shown, "[output]") != null);
    try testing.expectEqualStrings("Zhello\n", session.file().?.content);
}

test "a mouse click lands the cursor before editing" {
    const keys = [_]agree.World.Key{
        .{ .name = "mouse_press", .row = 1, .column = 6, .button = 0 },
        .{ .name = "text", .text = "Z" },
        .{ .name = "ctrl_s" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "hello\nworld\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("hello\nwZorld\n", session.file().?.content);
}

test "shift selects, the clipboard round-trips, and a drag extends" {
    // Home, then shift+end takes the first line; ctrl_x cuts it;
    // ctrl_v twice pastes it back doubled.  Then a mouse press and a
    // drag select "wor" on the next line and typing replaces it — the
    // whole selection model driven through the real event stream, and
    // the copy handed to the host clipboard on both engines.
    const keys = [_]agree.World.Key{
        .{ .name = "home" },
        .{ .name = "end", .modifiers = 1 },
        .{ .name = "ctrl_x" },
        .{ .name = "ctrl_v" },
        .{ .name = "ctrl_v" },
        .{ .name = "mouse_press", .row = 1, .column = 5, .button = 0 },
        .{ .name = "mouse_drag", .row = 1, .column = 8, .button = 0 },
        .{ .name = "text", .text = "W" },
        .{ .name = "ctrl_s" },
        .{ .name = "ctrl_q" },
    };
    var world: agree.World = .withFile("notes.txt", "hello\nworld\n");
    world.arguments = &[_][]const u8{"notes.txt"};
    world.keys = &keys;
    var program = try agree.project(editor, &editor_files);
    defer program.deinit();
    var session = try agree.compareProgram(&program, .{ .world = world });
    defer session.deinit();

    // "hello" cut then pasted twice = "hellohello"; "wor" dragged over
    // and replaced by W leaves "Wld".  The cut hit the host clipboard.
    try testing.expectEqualStrings("hellohello\nWld\n", session.file().?.content);
    try testing.expect(std.mem.indexOf(u8, session.printed(), "[copy]hello") != null);
}

/// What the screen said, frame by frame.
///
/// **This has to replay the transcript now, and that is the migration
/// showing through.**  The editor used to repaint every cell of every
/// frame, so concatenating the `[write]` payloads *was* the screen.
/// It draws through termui now, which writes only the cells that
/// changed since the last frame (docs/TERMUI.md D2) — so a sentence
/// on the screen is no longer a substring of the transcript unless
/// every one of its cells happened to change.  So the moves and the
/// writes go back into a grid, and every `[flush]` — one per frame —
/// appends what a person was looking at.  The answer is what the
/// editor showed at any point in the session, which is what the
/// assertions below have always been asking.  The caller owns it.
fn screenText(transcript: []const u8) ![]u8 {
    const rows = 24;
    const columns = 80;
    // One cell holds one character, which may be several bytes.
    const Cell = struct { bytes: [8]u8 = " ".* ++ [_]u8{0} ** 7, length: u8 = 1 };
    var grid: [rows][columns]Cell = @splat(@splat(.{}));
    var row: usize = 0;
    var column: usize = 0;

    var shown: std.ArrayList(u8) = .empty;
    errdefer shown.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, transcript, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[clear]")) {
            grid = @splat(@splat(.{}));
            row = 0;
            column = 0;
        } else if (std.mem.startsWith(u8, line, "[move]")) {
            const text = line["[move]".len..];
            const comma = std.mem.indexOfScalar(u8, text, ',') orelse continue;
            row = std.fmt.parseInt(usize, text[0..comma], 10) catch continue;
            column = std.fmt.parseInt(usize, text[comma + 1 ..], 10) catch continue;
        } else if (std.mem.startsWith(u8, line, "[write]")) {
            var characters = (std.unicode.Utf8View.init(line["[write]".len..]) catch continue).iterator();
            while (characters.nextCodepointSlice()) |character| {
                if (row < rows and column < columns and character.len <= 8) {
                    var cell: Cell = .{ .length = @intCast(character.len) };
                    @memcpy(cell.bytes[0..character.len], character);
                    grid[row][column] = cell;
                }
                column += 1;
            }
        } else if (std.mem.startsWith(u8, line, "[flush]")) {
            for (grid) |painted| {
                for (painted) |cell| try shown.appendSlice(testing.allocator, cell.bytes[0..cell.length]);
                try shown.append(testing.allocator, '\n');
            }
        }
    }
    return shown.toOwnedSlice(testing.allocator);
}
