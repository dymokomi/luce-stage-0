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
            .session = undefined,
            .seen = 0,
        };
        errdefer {
            self.registry.deinit();
            self.index.deinit();
        }
        try evaluators.registerAll(&self.registry);
        self.spool = Spool.init(allocator, store, &self.registry);
        self.session = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .spool = &self.spool,
            .out = out,
            .err = err,
        };
        boundary.ensureBoundary(allocator, io, store) catch {
            try err.print("loom: cannot create boundary texels\n", .{});
        };
        try self.index.build(store);
        self.seen = store.generation;
    }

    pub fn deinit(self: *Terminal) void {
        self.session.deinit();
        self.spool.deinit();
        self.index.deinit();
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

        const words = try command_line.splitWords(self.allocator, line) orelse {
            try self.session.err.print("loom: unbalanced quotes\n", .{});
            try self.reconcile();
            return true;
        };
        defer command_line.freeWordSlice(self.allocator, words);
        if (words.len == 0) {
            try self.reconcile();
            return true;
        }

        const result = try command_set.run(&self.session, words);
        if (result == .exit) return false;
        if (result == .unknown) {
            try self.session.err.print("loom: unknown command {s} (try help)\n", .{words[0]});
        }
        try self.reconcile();
        return true;
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

    // The prompt names the selection: "loom>", or "loom alpha>" while
    // the texel named alpha is selected (its short id when unnamed).
    fn printPrompt(self: *Terminal) !void {
        if (self.session.hasSelection() and self.store.has(self.session.selected)) {
            const label = try common.texelLabel(self.allocator, self.store, self.session.selected);
            defer self.allocator.free(label);
            try self.session.out.print("loom {s}> ", .{label});
        } else {
            try self.session.out.print("loom> ", .{});
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
                    try self.session.err.print("loom: line too long\n", .{});
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
