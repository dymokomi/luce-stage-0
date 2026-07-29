//! The first Lucia acceptance proof, from docs/LOOM.md: durable
//! material living in multiple arrangements, computation over it, two
//! Views sharing it, editing through the shell, restart, and an
//! existing tool reaching it through a file projection.

const std = @import("std");
const volume_mod = @import("storage/volume.zig");
const texel_id = @import("fabric/texel_id.zig");
const value_mod = @import("fabric/value.zig");
const texel_mod = @import("fabric/texel.zig");
const store_mod = @import("fabric/store.zig");
const spool_mod = @import("evaluation/spool.zig");
const arrangement = @import("organization/arrangement.zig");
const view_evaluators = @import("view/evaluators.zig");
const shell_mod = @import("view/shell.zig");
const manifest_mod = @import("projection/manifest.zig");
const projection_mod = @import("projection/projection.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const TexelId = texel_id.TexelId;
const Value = value_mod.Value;
const Texel = texel_mod.Texel;
const InputPort = texel_mod.InputPort;
const OutputPort = texel_mod.OutputPort;
const Store = store_mod.Store;
const Spool = spool_mod.Spool;
const Registry = spool_mod.Registry;
const Outcome = spool_mod.Outcome;
const OutcomeMap = spool_mod.OutcomeMap;
const Shell = shell_mod.Shell;

// proof.append: body text + suffix text -> text.
const AppendEvaluator = struct {
    fn evaluator(self: *AppendEvaluator) spool_mod.Evaluator {
        return .{ .context = self, .evaluateFn = run };
    }

    fn run(
        context: *anyopaque,
        allocator: Allocator,
        computed: *const Texel,
        inputs: *const OutcomeMap,
        outputs: *OutcomeMap,
    ) spool_mod.Error!void {
        _ = context;
        _ = computed;
        const body = inputs.get("body") orelse .unavailable;
        const suffix = inputs.get("suffix") orelse .unavailable;
        if (body != .available or suffix != .available) {
            try outputs.put(allocator, "text", .unavailable);
            return;
        }
        const joined = try std.mem.concat(allocator, u8, &.{
            body.available.text,
            suffix.available.text,
        });
        try outputs.put(allocator, "text", .{ .available = .{ .text = joined } });
    }
};

fn source(allocator: Allocator, id: TexelId, text: []const u8) !Texel {
    var item = Texel.init(id);
    errdefer item.deinit(allocator);
    var output = try OutputPort.init(allocator, "text", .text);
    try output.setSource(allocator, try Value.initText(allocator, text));
    try item.putOutput(allocator, output);
    return item;
}

/// A fresh disposable Spool over the durable Store must produce the
/// expected computed text.
fn checkDemand(store: *const Store, computed: TexelId, expected: []const u8) !void {
    const allocator = testing.allocator;
    var append: AppendEvaluator = .{};
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.put("proof.append", append.evaluator());
    var spool = Spool.init(allocator, store, &registry);
    defer spool.deinit();

    const outcome = try spool.demand(computed, "text");
    try testing.expect(outcome.* == .available);
    try testing.expectEqualStrings(expected, outcome.available.text);
}

/// A fresh Shell over the durable Store must composite both Views with
/// the shared material text.
fn checkViews(store: *Store, prose: TexelId, table: TexelId, text: []const u8) !void {
    const allocator = testing.allocator;
    var shell: Shell = undefined;
    try shell.setup(allocator, store);
    defer shell.deinit();
    try shell.add(prose, "Prose");
    try shell.add(table, "Table");

    const frame = try shell.compose();
    defer allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, text) != null);
    try testing.expect(std.mem.indexOf(u8, frame, "body:") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "| Field |") != null);
}

/// An existing tool edits the projected file without the Store: read,
/// replace, write back.
fn outsideEdit(io: std.Io, directory: std.Io.Dir, path: []const u8) !void {
    const allocator = testing.allocator;
    const file = try directory.openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const size: usize = @intCast(try file.length(io));
    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);

    const edited = try std.mem.replaceOwned(u8, allocator, content, "view two", "tool edit");
    defer allocator.free(edited);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, edited, 0);
    try file.sync(io);
}

test "first lucia proof: material, computation, views, projection, restart" {
    const allocator = testing.allocator;
    const io = testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "projection", .default_dir);

    const material_id = TexelId.generate(io);
    const suffix_id = TexelId.generate(io);
    const computed_id = TexelId.generate(io);
    const first_context_id = TexelId.generate(io);
    const second_context_id = TexelId.generate(io);
    const prose_id = TexelId.generate(io);
    const table_id = TexelId.generate(io);

    {
        var file = try volume_mod.FileVolume.create(io, scratch.dir, "loom.img", 256);
        defer file.close();
        var store = try Store.create(allocator, file.volume());
        defer store.deinit();

        // Durable material, a computation over it, two arrangements
        // holding it under different names, and two Views sharing it.
        var material = try source(allocator, material_id, "original text");
        defer material.deinit(allocator);
        var suffix = try source(allocator, suffix_id, "!");
        defer suffix.deinit(allocator);

        var computed = Texel.init(computed_id);
        defer computed.deinit(allocator);
        try computed.setEvaluator(allocator, "proof.append");
        try computed.putInput(allocator, try InputPort.init(allocator, "body", .text));
        try computed.putInput(allocator, try InputPort.init(allocator, "suffix", .text));
        try computed.putOutput(allocator, try OutputPort.init(allocator, "text", .text));

        var first_context = try arrangement.create(allocator, first_context_id);
        defer first_context.deinit(allocator);
        var second_context = try arrangement.create(allocator, second_context_id);
        defer second_context.deinit(allocator);
        try arrangement.add(allocator, &first_context, "draft", material_id);
        try arrangement.add(allocator, &second_context, "published", material_id);

        var prose = try view_evaluators.makeProseView(allocator, prose_id, &.{"body"});
        defer prose.deinit(allocator);
        var table = try view_evaluators.makeTableView(allocator, table_id, &.{"body"});
        defer table.deinit(allocator);

        {
            var transaction = try store.begin();
            defer transaction.deinit();
            try transaction.put(&material);
            try transaction.put(&suffix);
            try transaction.put(&computed);
            try transaction.put(&first_context);
            try transaction.put(&second_context);
            try transaction.put(&prose);
            try transaction.put(&table);
            try transaction.connect(computed_id, "body", material_id, "text");
            try transaction.connect(computed_id, "suffix", suffix_id, "text");
            try transaction.connect(prose_id, "body", material_id, "text");
            try transaction.connect(table_id, "body", material_id, "text");
            try transaction.commit();
        }

        try checkDemand(&store, computed_id, "original text!");

        // Editing through either focused View lands on the shared
        // material; both Views render the newest text.
        {
            var shell: Shell = undefined;
            try shell.setup(allocator, &store);
            defer shell.deinit();
            try shell.add(prose_id, "Prose");
            try shell.add(table_id, "Table");
            try shell.focus(0);
            try shell.edit(material_id, "text", "view one");
            try shell.focus(1);
            try shell.edit(material_id, "text", "view two");
        }
        try checkViews(&store, prose_id, table_id, "view two");

        // An existing tool reaches the material through the file
        // projection and its edit flows back into the Fabric.
        var manifest: manifest_mod.Manifest = .{};
        defer manifest.deinit(allocator);
        try manifest.put(allocator, material_id, "text", .text, "material.txt");
        var projection = projection_mod.FileProjection.init(allocator, io, scratch.dir);
        defer projection.deinit();
        try projection.exportFrom(&store, &manifest, "projection");
        try outsideEdit(io, scratch.dir, "projection/material.txt");
        try projection.importChanges(&store);

        try checkDemand(&store, computed_id, "tool edit!");
        try checkViews(&store, prose_id, table_id, "tool edit");
    }

    // Restart: everything above must survive reopening the image.
    {
        var file = try volume_mod.FileVolume.open(io, scratch.dir, "loom.img");
        defer file.close();
        var store = try Store.open(allocator, file.volume());
        defer store.deinit();

        try testing.expect(store.has(material_id));
        const first_context = store.get(first_context_id).?;
        const second_context = store.get(second_context_id).?;
        try arrangement.validate(allocator, first_context, &store);
        try arrangement.validate(allocator, second_context, &store);

        var first_entries = try arrangement.inspect(allocator, first_context);
        defer arrangement.deinitEntries(allocator, &first_entries);
        var second_entries = try arrangement.inspect(allocator, second_context);
        defer arrangement.deinitEntries(allocator, &second_entries);
        try testing.expectEqual(@as(usize, 1), first_entries.items.len);
        try testing.expectEqual(@as(usize, 1), second_entries.items.len);
        try testing.expectEqualStrings("draft", first_entries.items[0].name);
        try testing.expectEqualStrings("published", second_entries.items[0].name);
        try testing.expect(first_entries.items[0].texel.eql(material_id));
        try testing.expect(second_entries.items[0].texel.eql(material_id));

        try checkDemand(&store, computed_id, "tool edit!");
        try checkViews(&store, prose_id, table_id, "tool edit");
    }
}
