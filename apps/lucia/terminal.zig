//! The interactive command loop over one open Fabric.
//!
//! Reads one command per line, dispatches it through the command set,
//! and reconciles after each: changes since the last seen generation
//! expand through the fiber index into a dirty closure, the long-lived
//! spool advances past clean records, and dirty watches are
//! re-demanded.  Push invalidates; pull evaluates.  The prompt appears
//! only when standard input is a tty and shows the selected texel's
//! name.

const std = @import("std");
const loom = @import("loom");
const command_line = @import("command_line.zig");
const command_set = @import("command_set.zig");
const session_mod = @import("session.zig");
const evaluators = @import("evaluators.zig");
const boundary = @import("boundary.zig");
const luce_service = @import("luce_service.zig");
const common = @import("commands/common.zig");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Spool = loom.spool.Spool;
const Registry = loom.spool.Registry;
const FiberIndex = loom.fiber_index.FiberIndex;
const TexelId = loom.texel_id.TexelId;
const Session = session_mod.Session;

pub const Terminal = struct {
    allocator: Allocator,
    io: std.Io,
    store: *Store,
    registry: Registry,
    spool: Spool,
    index: FiberIndex,
    luce: luce_service.LuceService,
    session: Session,
    seen: u64,

    /// Fills self in place: the spool and session keep pointers into
    /// self, so a Terminal must never move once set up.  Ensures the
    /// boundary texels exist and builds the fiber index.
    pub fn setup(
        self: *Terminal,
        allocator: Allocator,
        io: std.Io,
        store: *Store,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .registry = Registry.init(allocator),
            .spool = undefined,
            .index = FiberIndex.init(allocator),
            .luce = luce_service.LuceService.init(allocator),
            .session = undefined,
            .seen = 0,
        };
        errdefer {
            self.registry.deinit();
            self.index.deinit();
            self.luce.deinit();
        }
        try evaluators.registerAll(&self.registry);
        try self.registry.put(luce_service.evaluator_name, self.luce.evaluator());
        self.spool = Spool.init(allocator, store, &self.registry);
        self.session = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .spool = &self.spool,
            .out = out,
            .err = err,
            .luce = &self.luce,
        };
        boundary.ensureBoundary(allocator, io, store) catch {
            try err.print("lucia: cannot create boundary texels\n", .{});
        };
        try self.index.build(store);
        self.seen = store.generation;
    }

    pub fn deinit(self: *Terminal) void {
        self.session.deinit();
        self.spool.deinit();
        self.index.deinit();
        self.luce.deinit();
        self.registry.deinit();
        self.* = undefined;
    }

    /// Handle one typed line: observe it on the keyboard boundary,
    /// dispatch it, and reconcile.  Returns false when the session
    /// should end.
    pub fn dispatch(self: *Terminal, line: []const u8) !bool {
        // The keyboard boundary observes every interaction before the
        // command runs, so keyboard.line always holds the newest line.
        const typed = std.mem.trimEnd(u8, line, "\r\n");
        boundary.observeKeyboard(self.allocator, self.store, typed) catch {};

        // Code entry swallows whole lines until the closing ".".
        if (self.session.collecting != null) {
            try self.collectCode(typed);
            try self.settle();
            return true;
        }

        const words = try command_line.splitWords(self.allocator, line) orelse {
            try self.session.err.print("lucia: unbalanced quotes\n", .{});
            try self.settle();
            return true;
        };
        defer command_line.freeWordSlice(self.allocator, words);
        if (words.len == 0) {
            try self.settle();
            return true;
        }

        const result = try command_set.run(&self.session, words);
        if (result == .exit) return false;
        if (result == .unknown) {
            try self.session.err.print("lucia: unknown command {s} (try help)\n", .{words[0]});
        }
        try self.settle();
        return true;
    }

    /// Run standalone Luce source (the --luce bootstrap path): compile
    /// with fabric enabled, execute, report, and settle the intents.
    pub fn script(self: *Terminal, source: []const u8) !void {
        const palette = self.session.palette;
        switch (try self.luce.runScript(source)) {
            .ok => {},
            .diagnostics => |rendered| {
                defer self.allocator.free(rendered);
                try self.session.err.print("lucia: {s}luce compile failed\n{s}{s}", .{
                    palette.sgr(.err),
                    rendered,
                    palette.sgr(.reset),
                });
            },
            .trap => |message| {
                defer self.allocator.free(message);
                try self.session.err.print("lucia: {s}luce trap: {s}{s}\n", .{
                    palette.sgr(.err),
                    message,
                    palette.sgr(.reset),
                });
            },
        }
        try self.settle();
        try self.session.out.flush();
    }

    /// Apply computed fabric intents and reconcile until quiet.  A
    /// re-demanded watch may evaluate a template that computes more
    /// intents; the round bound keeps a runaway spawner from wedging
    /// the terminal.
    fn settle(self: *Terminal) !void {
        var rounds: usize = 0;
        while (true) : (rounds += 1) {
            try self.applyFabricIntents();
            try self.reconcile();
            if (self.luce.pending.items.len == 0) return;
            if (rounds >= 4) {
                try self.session.err.print(
                    "lucia: fabric intents still arriving after {d} rounds; stopping\n",
                    .{rounds},
                );
                const stalled = self.luce.takePending();
                defer self.allocator.free(stalled);
                for (stalled) |*intent| {
                    var dropped = intent.*;
                    dropped.deinit(self.allocator);
                }
                return;
            }
        }
    }

    /// One transaction creates every pending texel: name, typed ports,
    /// content, evaluator, and initial output sources.
    fn applyFabricIntents(self: *Terminal) !void {
        if (self.luce.pending.items.len == 0) return;
        const batch = self.luce.takePending();
        defer {
            for (batch) |*intent| {
                var owned = intent.*;
                owned.deinit(self.allocator);
            }
            self.allocator.free(batch);
        }

        var transaction = self.store.begin() catch {
            try self.session.err.print("lucia: fabric intents failed to apply\n", .{});
            return;
        };
        defer transaction.deinit();

        var made: std.ArrayList(TexelId) = .empty;
        defer made.deinit(self.allocator);
        for (batch) |intent| {
            const id = try self.buildIntent(&transaction, intent);
            try made.append(self.allocator, id);
        }
        transaction.commit() catch {
            try self.session.err.print("lucia: fabric intents failed to commit\n", .{});
            return;
        };
        const palette = self.session.palette;
        for (batch, made.items) |intent, id| {
            var buffer: [TexelId.text_size]u8 = undefined;
            try self.session.out.print("{s}created {s}{s} {s}{s}{s}\n", .{
                palette.sgr(.created),
                intent.name,
                palette.sgr(.reset),
                palette.sgr(.identity),
                id.format(&buffer)[0..8],
                palette.sgr(.reset),
            });
        }
    }

    fn buildIntent(
        self: *Terminal,
        transaction: *loom.store.Transaction,
        intent: luce_service.PendingTexel,
    ) !TexelId {
        const allocator = self.allocator;
        var texel = loom.texel.Texel.init(TexelId.generate(self.io));
        defer texel.deinit(allocator);

        try common.setName(allocator, &texel, intent.name);
        for (intent.inputs) |port| {
            try texel.putInput(allocator, try loom.texel.InputPort.init(allocator, port.name, port.declared));
        }
        for (intent.outputs) |port| {
            try texel.putOutput(allocator, try loom.texel.OutputPort.init(allocator, port.name, port.declared));
        }
        if (intent.content) |source| {
            try texel.setContent(allocator, try loom.value.Value.initText(allocator, source));
        }
        if (intent.evaluator) |name| {
            try texel.setEvaluator(allocator, name);
        }
        for (intent.sets) |set| {
            const output = texel.mutableOutput(set.output) orelse continue;
            var cloned = try set.value.clone(allocator);
            output.setSource(allocator, cloned) catch cloned.deinit(allocator);
        }
        try transaction.put(&texel);
        return texel.id;
    }

    /// Reconcile the disposable machinery with whatever the last
    /// command (or keyboard observation) changed, then re-demand only
    /// the dirty watches.
    fn reconcile(self: *Terminal) !void {
        const current = self.store.generation;
        if (current == self.seen) return;

        var full = false;
        var dirty: []TexelId = &.{};
        defer self.allocator.free(dirty);
        if (try self.store.changesSince(self.allocator, self.seen)) |changed| {
            defer self.allocator.free(changed);
            try self.index.apply(self.store, changed);
            dirty = try self.index.downstream(self.allocator, changed);
            self.spool.advance(self.seen, current, dirty);
        } else {
            // The change ring no longer reaches the seen baseline:
            // rebuild the disposable machinery and revalidate everything.
            try self.index.build(self.store);
            self.spool.clear();
            full = true;
        }
        self.seen = current;

        for (self.session.watches.items) |*watch| {
            if (!full and !loom.fiber_index.contains(dirty, watch.texel)) continue;
            const outcome = self.spool.demand(watch.texel, watch.output) catch continue;
            const rendered = try common.outcomeText(self.allocator, outcome);
            if (std.mem.eql(u8, rendered, watch.last)) {
                self.allocator.free(rendered);
                continue;
            }
            self.allocator.free(watch.last);
            watch.last = rendered;
            try common.printOutcome(&self.session, watch.texel, watch.output, outcome);
        }
    }

    // One line of code entry: accumulate, or commit on the closing
    // "." and report compile diagnostics against the texel's ports.
    fn collectCode(self: *Terminal, typed: []const u8) !void {
        const collect = &self.session.collecting.?;
        if (!std.mem.eql(u8, typed, ".")) {
            try collect.text.appendSlice(self.allocator, typed);
            try collect.text.append(self.allocator, '\n');
            return;
        }

        var finished = self.session.collecting.?;
        self.session.collecting = null;
        defer finished.deinit(self.allocator);
        const texel = finished.texel;

        {
            var transaction = self.store.begin() catch return self.codeFailed();
            defer transaction.deinit();
            const current = transaction.get(texel) orelse return self.codeFailed();
            var changed = try current.clone(self.allocator);
            defer changed.deinit(self.allocator);
            const source = try loom.value.Value.initText(self.allocator, finished.text.items);
            changed.setContent(self.allocator, source) catch return self.codeFailed();
            transaction.put(&changed) catch return self.codeFailed();
            transaction.commit() catch return self.codeFailed();
        }

        // The source is committed either way; diagnostics tell the
        // user what still needs fixing before demand can compute.
        const committed = self.store.get(texel) orelse return;
        if (try self.luce.check(committed)) |rendered| {
            defer self.allocator.free(rendered);
            const palette = self.session.palette;
            try self.session.err.print("lucia: {s}luce compile failed\n{s}{s}", .{
                palette.sgr(.err),
                rendered,
                palette.sgr(.reset),
            });
        }
    }

    fn codeFailed(self: *Terminal) !void {
        try self.session.err.print("lucia: code commit failed\n", .{});
    }

    // The prompt names the selection: "lucia>", or "lucia alpha>" while
    // the texel named alpha is selected (its short id when unnamed).
    fn printPrompt(self: *Terminal) !void {
        if (self.session.collecting != null) {
            try self.session.out.print("... ", .{});
            return;
        }
        const palette = self.session.palette;
        if (self.session.hasSelection() and self.store.has(self.session.selected)) {
            const label = try common.texelLabel(self.allocator, self.store, self.session.selected);
            defer self.allocator.free(label);
            try self.session.out.print("lucia {s}{s}{s}> ", .{
                palette.sgr(.prompt),
                label,
                palette.sgr(.reset),
            });
        } else {
            try self.session.out.print("lucia> ", .{});
        }
    }

    /// The read-dispatch loop.  The reader supplies typed lines; the
    /// prompt appears only when interactive.
    pub fn run(self: *Terminal, reader: *std.Io.Reader, interactive: bool) !void {
        while (true) {
            if (interactive) try self.printPrompt();
            try self.session.out.flush();

            const line = reader.takeDelimiter('\n') catch |mistake| switch (mistake) {
                error.StreamTooLong => {
                    try self.session.err.print("lucia: line too long\n", .{});
                    return;
                },
                error.ReadFailed => return,
            } orelse {
                if (interactive) try self.session.out.print("\n", .{});
                try self.session.out.flush();
                return;
            };
            if (!try self.dispatch(line)) return;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = loom.volume;

const Bench = struct {
    memory: volume_mod.MemoryVolume,
    store: Store,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    terminal: Terminal,

    // Fills self in place: the terminal keeps pointers into self.
    fn setup(self: *Bench, allocator: Allocator) !void {
        self.memory = try volume_mod.MemoryVolume.init(allocator, 64);
        errdefer self.memory.deinit();
        self.store = try Store.create(allocator, self.memory.volume());
        errdefer self.store.deinit();
        self.out = .init(allocator);
        self.err = .init(allocator);
        try self.terminal.setup(
            allocator,
            testing.io,
            &self.store,
            &self.out.writer,
            &self.err.writer,
        );
    }

    fn deinit(self: *Bench) void {
        self.terminal.deinit();
        self.err.deinit();
        self.out.deinit();
        self.store.deinit();
        self.memory.deinit();
    }

    fn script(self: *Bench, lines: []const []const u8) !void {
        for (lines) |line| {
            try testing.expect(try self.terminal.dispatch(line));
        }
    }
};

test "scripted session: sources, concat, watch fires through reconcile" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new left",
        "output value text",
        "set value hello",
        "new right",
        "output value text",
        "set value world",
        "new join",
        "eval concat",
        "input left text",
        "input right text",
        "output value text",
        "connect left left value",
        "connect right right value",
        "pull value",
        "watch value",
        "select left",
        "set value HELLO",
    });
    try testing.expect(!try bench.terminal.dispatch("exit"));

    const printed = bench.out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "helloworld") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "join.value = helloworld") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "join.value = HELLOworld") != null);
    try testing.expectEqualStrings("", bench.err.written());
}

test "keyboard boundary observes every line and stays volatile" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    // Three lines dispatched so far -> count observed three times; the
    // pull happens on the fourth line, after its own observation.
    try bench.script(&.{ "list", "select keyboard", "watch count", "pull line" });
    const printed = bench.out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "keyboard.count = ") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "pull line") != null);

    // Observations are volatile: reopening the same volume reverts the
    // keyboard to its durable snapshot.
    var reopened = try Store.open(allocator, bench.memory.volume());
    defer reopened.deinit();
    const id = common.findNamed(&reopened, boundary.keyboard_name).?;
    const port = reopened.get(id).?.getOutput("count").?;
    try testing.expectEqual(@as(i64, 0), port.source.?.int);
}

test "errors: unknown commands, unbalanced quotes, bad arguments" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "definitely-not-a-command",
        "say \"broken",
        "new",
        "select nowhere",
        "pull value",
    });
    const complaints = bench.err.written();
    try testing.expect(std.mem.indexOf(u8, complaints, "unknown command definitely-not-a-command") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "unbalanced quotes") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "usage: new NAME") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "no texel named nowhere") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "no texel selected") != null);
}

test "luce texels compute, recompile on edit, and fire watches" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new source",
        "output value int",
        "set value 21",
        "new doubler",
        "eval luce",
        "input value int",
        "output value int",
        "connect value source value",
        "code",
        "fn evaluate():",
        "    output.value = input.value * 2",
        ".",
        "pull value",
        "watch value",
        // Editing the source recompiles on the next demand.
        "code",
        "fn evaluate():",
        "    output.value = input.value * 3",
        ".",
        "pull value",
        // An upstream change re-fires the watch through reconcile.
        "select source",
        "set value 10",
    });
    const printed = bench.out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "42") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "63") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "doubler.value = 30") != null);
    try testing.expectEqualStrings("", bench.err.written());
}

test "luce boundary slice: keyboard count drives a computed watch" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new counter",
        "eval luce",
        "input count int",
        "output value int",
        "connect count keyboard count",
        "code",
        "fn evaluate():",
        "    output.value = input.count * 10",
        ".",
        "watch value",
        "list",
        "list",
    });
    // Every dispatched line observes the keyboard, so the watch keeps
    // moving: the two list lines each advance count by one.
    const printed = bench.out.written();
    const first = std.mem.indexOf(u8, printed, "counter.value = ").?;
    const second = std.mem.indexOfPos(u8, printed, first + 1, "counter.value = ").?;
    try testing.expect(std.mem.indexOfPos(u8, printed, second + 1, "counter.value = ") != null);
    try testing.expectEqualStrings("", bench.err.written());
}

test "luce compile diagnostics report at code time and demand time" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new broken",
        "eval luce",
        "output value int",
        "code",
        "fn evaluate():",
        "    output.value = input.ghost",
        ".",
        "pull value",
    });
    const complaints = bench.err.written();
    // Reported once when the source commits, and again as the error
    // outcome of the demanded output.
    try testing.expect(std.mem.indexOf(u8, complaints, "luce compile failed") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "no input port named ghost") != null);
    try testing.expect(std.mem.indexOf(u8, complaints, "error: luce compile failed") != null);
}

test "luce traps surface as error outcomes, never partial output" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new divider",
        "eval luce",
        "input value int",
        "output value int",
        "connect value keyboard count",
        "code",
        "fn evaluate():",
        "    output.value = 100 / (input.value - input.value)",
        ".",
        "pull value",
    });
    const complaints = bench.err.written();
    try testing.expect(std.mem.indexOf(u8, complaints, "luce trap: division by zero") != null);
    // The name port keeps its passthrough value despite the trap.
    const label = try common.texelLabel(allocator, &bench.store, bench.terminal.session.selected);
    defer allocator.free(label);
    try testing.expectEqualStrings("divider", label);
}

test "bootstrap: a luce template texel creates a texel that computes" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    // newAdd is a template: demanding its output computes an intent
    // for a fresh adder texel, complete with ports, evaluator, and
    // Luce content.  The terminal applies the intent after dispatch.
    try bench.script(&.{
        "new newAdd",
        "eval luce",
        "output made int",
        "code",
        "fn evaluate():",
        "    let adder = create_texel(\"adder\")",
        "    texel_input(adder, \"left\", \"int\")",
        "    texel_input(adder, \"right\", \"int\")",
        "    texel_output(adder, \"value\", \"int\")",
        "    texel_evaluator(adder, \"luce\")",
        "    texel_content(adder, \"fn evaluate():\\n    output.value = input.left + input.right\\n\")",
        "    output.made = 1",
        ".",
        "pull made",
    });
    try testing.expect(std.mem.indexOf(u8, bench.out.written(), "created adder") != null);

    // The spawned adder is an ordinary texel: wire two sources into it
    // and demand its sum.
    try bench.script(&.{
        "new five",
        "output value int",
        "set value 5",
        "new seven",
        "output value int",
        "set value 7",
        "select adder",
        "connect left five value",
        "connect right seven value",
        "pull value",
    });
    try testing.expect(std.mem.indexOf(u8, bench.out.written(), "12") != null);
    try testing.expectEqualStrings("", bench.err.written());

    // Re-demanding the unchanged template replays the cached outcome
    // and creates nothing new.
    try bench.script(&.{ "select newAdd", "pull made", "find adder" });
    const listing = bench.out.written();
    const first = std.mem.indexOf(u8, listing, "created adder").?;
    try testing.expect(std.mem.indexOfPos(u8, listing, first + 1, "created adder") == null);
}

test "the luce command fires a template by hand, repeatedly" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new stamp",
        "eval luce",
        "output note text",
        "code",
        "fn evaluate():",
        "    let t = create_texel(\"stamped\")",
        "    texel_output(t, \"value\", \"int\")",
        "    texel_set(t, \"value\", 9)",
        "    output.note = \"stamped one\"",
        ".",
        // Fire the template twice by hand; each run creates a texel.
        "luce stamp",
        "luce stamp",
    });
    const printed = bench.out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "note = stamped one") != null);
    const first = std.mem.indexOf(u8, printed, "created stamped").?;
    try testing.expect(std.mem.indexOfPos(u8, printed, first + 1, "created stamped") != null);
    try testing.expectEqualStrings("", bench.err.written());
}

test "script runs standalone bootstrap source against the fabric" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.terminal.script(
        \\fn evaluate():
        \\    let greeter = create_texel("greeter")
        \\    texel_output(greeter, "text", "text")
        \\    texel_set(greeter, "text", "woven from a script")
        \\
    );
    try testing.expect(std.mem.indexOf(u8, bench.out.written(), "created greeter") != null);
    try bench.script(&.{ "select greeter", "pull text" });
    try testing.expect(std.mem.indexOf(u8, bench.out.written(), "woven from a script") != null);
    try testing.expectEqualStrings("", bench.err.written());

    // Broken bootstrap source reports diagnostics, changes nothing.
    try bench.terminal.script("fn evaluate(:\n");
    try testing.expect(std.mem.indexOf(u8, bench.err.written(), "luce compile failed") != null);
}

test "ports move and drop with fibers preserved and guarded" {
    const allocator = testing.allocator;
    var bench: Bench = undefined;
    try bench.setup(allocator);
    defer bench.deinit();

    try bench.script(&.{
        "new source",
        "output value text",
        "set value alpha",
        "new sink",
        "eval upper",
        "input text text",
        "output value text",
        "connect text source value",
        // Renaming the bound output rewires the sink's fiber.
        "select source",
        "move out value payload",
        "select sink",
        "pull value",
        // A connected output refuses to drop; the input side drops fine.
        "select source",
        "drop out payload",
        "select sink",
        "disconnect text",
        "drop in text",
    });
    const printed = bench.out.written();
    try testing.expect(std.mem.indexOf(u8, printed, "ALPHA") != null);
    const complaints = bench.err.written();
    try testing.expect(std.mem.indexOf(u8, complaints, "output payload is still connected") != null);
}
