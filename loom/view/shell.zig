//! The presentation shell — trusted, non-persistent View runtime.
//!
//! The Shell owns evaluator instances and presentation state (surfaces,
//! focus) but no Texels or other durable Fabric state.  It demands View
//! interfaces through its own Spool, composites presented surfaces into
//! one frame, and routes edits back into the Store as ordinary
//! transactions.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const texel_id = @import("../fabric/texel_id.zig");
const value_mod = @import("../fabric/value.zig");
const spool_mod = @import("../evaluation/spool.zig");
const evaluators = @import("evaluators.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Registry = spool_mod.Registry;
const Spool = spool_mod.Spool;

pub const Error = error{
    OutOfMemory,
    MissingTexel,
    NotAView,
    EmptyLabel,
    OutOfRange,
    NoFocus,
    Unavailable,
    NotEditable,
    StoreFailed,
};

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------
//
// One presented View: its identity plus the accessibility label the
// shell speaks for it.
//
pub const Surface = struct {
    view: TexelId,
    label: []u8,
};

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

pub const Shell = struct {
    allocator: Allocator,
    store: *Store,
    prose: evaluators.ProseViewEvaluator,
    table: evaluators.TableViewEvaluator,
    registry: Registry,
    spool: Spool,
    surfaces: std.ArrayList(Surface),
    focus_index: ?usize,

    /// Fills self in place: the spool keeps pointers into self, so a
    /// Shell must never move once set up.
    pub fn setup(self: *Shell, allocator: Allocator, store: *Store) !void {
        self.* = .{
            .allocator = allocator,
            .store = store,
            .prose = .{},
            .table = .{},
            .registry = Registry.init(allocator),
            .spool = undefined,
            .surfaces = .empty,
            .focus_index = null,
        };
        errdefer self.registry.deinit();
        try self.registry.put(evaluators.prose_view_evaluator, self.prose.evaluator());
        try self.registry.put(evaluators.table_view_evaluator, self.table.evaluator());
        self.spool = Spool.init(allocator, store, &self.registry);
    }

    pub fn deinit(self: *Shell) void {
        for (self.surfaces.items) |surface| self.allocator.free(surface.label);
        self.surfaces.deinit(self.allocator);
        self.spool.deinit();
        self.registry.deinit();
        self.* = undefined;
    }

    /// Present one View.  The texel must exist and carry a view
    /// evaluator; the label is what accessibility speaks for it.
    pub fn add(self: *Shell, view: TexelId, label: []const u8) Error!void {
        if (label.len == 0) return error.EmptyLabel;
        const texel = self.store.get(view) orelse return error.MissingTexel;
        const evaluator = texel.evaluatorName();
        if (!std.mem.eql(u8, evaluator, evaluators.prose_view_evaluator) and
            !std.mem.eql(u8, evaluator, evaluators.table_view_evaluator))
        {
            return error.NotAView;
        }
        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);
        try self.surfaces.append(self.allocator, .{ .view = view, .label = owned });
    }

    pub fn size(self: *const Shell) usize {
        return self.surfaces.items.len;
    }

    pub fn focus(self: *Shell, index: usize) Error!void {
        if (index >= self.surfaces.items.len) return error.OutOfRange;
        self.focus_index = index;
    }

    pub fn focused(self: *const Shell) ?usize {
        return self.focus_index;
    }

    /// Demand one View's rendered interface.  The caller owns the text.
    pub fn interface(self: *Shell, view: TexelId) Error![]u8 {
        const outcome = self.spool.demand(view, evaluators.interface_output) catch
            return error.OutOfMemory;
        if (outcome.* != .available or outcome.available.tag() != .text) {
            return error.Unavailable;
        }
        return try self.allocator.dupe(u8, outcome.available.text);
    }

    /// Composite every presented surface into one labelled frame.  The
    /// caller owns the text.
    pub fn compose(self: *Shell) Error![]u8 {
        var frame: std.ArrayList(u8) = .empty;
        errdefer frame.deinit(self.allocator);
        for (self.surfaces.items) |surface| {
            const content = try self.interface(surface.view);
            defer self.allocator.free(content);
            if (frame.items.len != 0) try frame.append(self.allocator, '\n');
            try frame.append(self.allocator, '[');
            try frame.appendSlice(self.allocator, surface.label);
            try frame.appendSlice(self.allocator, "]\n");
            try frame.appendSlice(self.allocator, content);
            try frame.append(self.allocator, '\n');
        }
        return frame.toOwnedSlice(self.allocator);
    }

    /// The accessibility labels of every surface, in presentation
    /// order.  The caller owns the array; the labels stay borrowed.
    pub fn accessibilityLabels(self: *const Shell) Error![][]const u8 {
        const labels = try self.allocator.alloc([]const u8, self.surfaces.items.len);
        for (self.surfaces.items, labels) |surface, *label| label.* = surface.label;
        return labels;
    }

    /// Route one edit from the focused interface back into the Fabric:
    /// replace the text source on a source texel's output.  Computed
    /// texels are never edited directly.
    pub fn edit(self: *Shell, source: TexelId, output_name: []const u8, text: []const u8) Error!void {
        if (self.focus_index == null) return error.NoFocus;

        var transaction = self.store.begin() catch return error.StoreFailed;
        defer transaction.deinit();

        const current = transaction.get(source) orelse return error.MissingTexel;
        if (current.evaluator != null) return error.NotEditable;
        var changed = try current.clone(self.allocator);
        defer changed.deinit(self.allocator);
        const output = changed.mutableOutput(output_name) orelse return error.NotEditable;
        if (output.declared != .text) return error.NotEditable;
        output.setSource(self.allocator, try Value.initText(self.allocator, text)) catch
            return error.NotEditable;
        transaction.put(&changed) catch return error.StoreFailed;
        transaction.commit() catch return error.StoreFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");
const texel_mod = @import("../fabric/texel.zig");
const Texel = texel_mod.Texel;
const OutputPort = texel_mod.OutputPort;

fn textSource(allocator: Allocator, text: []const u8) !Texel {
    var item = Texel.init(TexelId.generate(testing.io));
    errdefer item.deinit(allocator);
    var output = try OutputPort.init(allocator, "text", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try item.putOutput(allocator, output);
    return item;
}

fn expectInterfaces(shell: *Shell, prose: TexelId, table: TexelId, text: []const u8) !void {
    const allocator = testing.allocator;

    const rendered = try shell.interface(prose);
    defer allocator.free(rendered);
    const expected = try std.mem.concat(allocator, u8, &.{ "body: ", text });
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, rendered);

    const tabled = try shell.interface(table);
    defer allocator.free(tabled);
    const row = try std.mem.concat(allocator, u8, &.{ "| body  | ", text });
    defer allocator.free(row);
    try testing.expect(std.mem.indexOf(u8, tabled, "| Field | Value") != null);
    try testing.expect(std.mem.indexOf(u8, tabled, row) != null);
    try testing.expect(std.mem.indexOf(u8, tabled, "body:") == null);
}

test "two views share one source and edits round-trip through the store" {
    const allocator = testing.allocator;
    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var source = try textSource(allocator, "alpha");
    defer source.deinit(allocator);
    var prose = try evaluators.makeProseView(allocator, TexelId.generate(testing.io), &.{"body"});
    defer prose.deinit(allocator);
    var table = try evaluators.makeTableView(allocator, TexelId.generate(testing.io), &.{"body"});
    defer table.deinit(allocator);

    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.put(&source);
        try transaction.put(&prose);
        try transaction.put(&table);
        try transaction.connect(prose.id, "body", source.id, "text");
        try transaction.connect(table.id, "body", source.id, "text");
        try transaction.commit();
    }

    var shell: Shell = undefined;
    try shell.setup(allocator, &store);
    defer shell.deinit();

    try shell.add(prose.id, "Article");
    try shell.add(table.id, "Data table");
    try testing.expectEqual(@as(usize, 2), shell.size());
    try testing.expectError(error.MissingTexel, shell.add(TexelId.generate(testing.io), "Ghost"));
    try testing.expectError(error.NotAView, shell.add(source.id, "Source"));

    const labels = try shell.accessibilityLabels();
    defer allocator.free(labels);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("Article", labels[0]);
    try testing.expectEqualStrings("Data table", labels[1]);

    try expectInterfaces(&shell, prose.id, table.id, "alpha");

    {
        const frame = try shell.compose();
        defer allocator.free(frame);
        const article = std.mem.indexOf(u8, frame, "[Article]\nbody: alpha").?;
        const data = std.mem.indexOf(u8, frame, "[Data table]\n+-------+").?;
        try testing.expect(article < data);
    }

    // Edits require focus and land as ordinary durable commits.
    try testing.expectError(error.NoFocus, shell.edit(source.id, "text", "beta"));
    try shell.focus(0);
    try shell.edit(source.id, "text", "beta");
    try expectInterfaces(&shell, prose.id, table.id, "beta");

    try shell.focus(1);
    try testing.expectEqual(@as(?usize, 1), shell.focused());
    try shell.edit(source.id, "text", "gamma");
    try expectInterfaces(&shell, prose.id, table.id, "gamma");

    // Computed texels refuse direct edits.
    try testing.expectError(error.NotEditable, shell.edit(prose.id, "interface", "nope"));

    // A reopened store presents the same edited Fabric.
    var reopened = try Store.open(allocator, memory.volume());
    defer reopened.deinit();
    var second: Shell = undefined;
    try second.setup(allocator, &reopened);
    defer second.deinit();
    try second.add(prose.id, "Article");
    try second.add(table.id, "Data table");
    try expectInterfaces(&second, prose.id, table.id, "gamma");
    const frame = try second.compose();
    defer allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "body: gamma") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "| body  | gamma") != null);
}
