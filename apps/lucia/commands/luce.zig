//! luce ID|NAME — execute a texel's Luce code once, right now.
//!
//! Demand decides when ordinary evaluation happens; this command is
//! the direct lever: compile the texel's content against its ports,
//! resolve its bound inputs through the session spool, run it, and
//! print what it wrote.  Outputs are shown, not published — the
//! Fabric's values still come from demand — but fabric intents the
//! program computes do apply, which is how a template texel is fired
//! by hand as many times as needed.

const std = @import("std");
const loom = @import("loom");
const luce = @import("luce");
const command = @import("../command.zig");
const common = @import("common.zig");
const image = @import("../image.zig");
const luce_file_host = @import("../luce_file_host.zig");
const luce_service = @import("../luce_service.zig");
const ops = @import("../ops.zig");
const view = @import("../view.zig");
const view_shell = @import("../view_shell.zig");

const Session = command.Session;
const Error = command.Error;
const Result = command.Result;

pub const entry: command.Command = .{
    .name = "luce",
    .alias = "lu",
    .argument_count = 1,
    .maximum_argument_count = 2,
    .usage = "luce ID|NAME | luce editor TARGET",
    .run = run,
};

fn run(session: *Session, words: []const []const u8) Error!Result {
    if (words.len == 3) {
        if (!std.mem.eql(u8, words[1], "editor")) {
            try session.err.print("usage: {s}\n", .{entry.usage});
            return .err;
        }
        return runEditor(session, words[2]);
    }
    return runOnce(session, words);
}

fn runOnce(session: *Session, words: []const []const u8) Error!Result {
    const palette = session.palette;
    const id = try common.resolveTexel(session, words[1]) orelse return .err;
    const texel = session.store.get(id).?;

    if (texel.content == null) {
        try session.err.print("lucia: {s} has no luce source (use code)\n", .{words[1]});
        return .err;
    }
    if (try session.luce.check(texel)) |rendered| {
        defer session.allocator.free(rendered);
        try session.err.print("lucia: {s}luce compile failed\n{s}{s}", .{
            palette.sgr(.err),
            rendered,
            palette.sgr(.reset),
        });
        return .err;
    }
    const program = session.luce.cachedFor(texel) orelse return .err;

    var arena = std.heap.ArenaAllocator.init(session.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Resolve each program input through the spool.  Demand borrows
    // invalidate on the next demand, so every value is copied into the
    // run's arena immediately.
    const input_frame = try scratch.alloc(luce.backend.InputValue, program.inputs.len);
    for (program.inputs, input_frame) |port, *slot| {
        const declared = texel.getInput(port.name) orelse {
            slot.* = .unavailable;
            continue;
        };
        const binding = declared.binding orelse {
            slot.* = .unavailable;
            continue;
        };
        const outcome = try session.spool.demand(binding.source, binding.output);
        slot.* = switch (luce_service.LuceService.fromOutcome(outcome.*, port.declared)) {
            .unavailable => .unavailable,
            .value => |value| .{ .value = switch (value) {
                .string => |text| .{ .string = try scratch.dupe(u8, text) },
                .bytes => |bytes| .{ .bytes = try scratch.dupe(u8, bytes) },
                else => value,
            } },
        };
    }
    const output_frame = try scratch.alloc(?luce.backend.RuntimeValue, program.outputs.len);
    @memset(output_frame, null);

    const result = try session.luce.evaluateProgram(
        scratch,
        program,
        input_frame,
        output_frame,
    );
    switch (result) {
        .unavailable => {
            try session.out.print("{s}unavailable{s} (an input this program reads is not available)\n", .{
                palette.sgr(.unavailable),
                palette.sgr(.reset),
            });
            return .ok;
        },
        .trap => |trapped| {
            try session.err.print("lucia: {s}luce trap: {s}{s}\n", .{
                palette.sgr(.err),
                trapped.message,
                palette.sgr(.reset),
            });
            return .err;
        },
        .success => |intents| {
            for (program.outputs, output_frame) |port, written| {
                const value = written orelse continue;
                var converted = try luce_service.LuceService.toValue(session.allocator, value);
                defer converted.deinit(session.allocator);
                const rendered = try common.valueText(session.allocator, converted);
                defer session.allocator.free(rendered);
                try session.out.print("{s}{s}{s} {s}= {s}{s}\n", .{
                    palette.sgr(.port),
                    port.name,
                    palette.sgr(.reset),
                    palette.sgr(.value),
                    rendered,
                    palette.sgr(.reset),
                });
            }
            try session.luce.copyIntents(intents);
            return .ok;
        },
    }
}

const EditorHost = struct {
    session: *Session,
    program: *const luce.ir.Program,
    target: loom.texel_id.TexelId,
    target_label: []u8,
    capability: loom.capability.Capability,
    content: []u8,
    interface: []u8,
    cursor: i64 = 0,
    dirty: bool = false,
    scroll: i64 = 0,

    fn init(
        session: *Session,
        program: *const luce.ir.Program,
        target: loom.texel_id.TexelId,
    ) !EditorHost {
        const texel = session.store.get(target) orelse return error.MissingTexel;
        const source = if (texel.content) |content|
            if (content.tag() == .text) content.text else ""
        else
            "";
        const owned_content = try session.allocator.dupe(u8, source);
        errdefer session.allocator.free(owned_content);
        const target_label = try common.texelLabel(session.allocator, session.store, target);
        errdefer session.allocator.free(target_label);
        const empty_interface = try session.allocator.dupe(u8, "");
        errdefer session.allocator.free(empty_interface);

        var scope_buffer: [loom.texel_id.TexelId.text_size]u8 = undefined;
        const capability = try session.authority.issue(
            session.io,
            "set_content",
            target.format(&scope_buffer),
        );
        return .{
            .session = session,
            .program = program,
            .target = target,
            .target_label = target_label,
            .capability = capability,
            .content = owned_content,
            .interface = empty_interface,
        };
    }

    fn deinit(self: *EditorHost) void {
        self.session.allocator.free(self.target_label);
        _ = self.session.authority.revoke(self.capability);
        self.capability.deinit(self.session.allocator);
        self.session.allocator.free(self.content);
        self.session.allocator.free(self.interface);
        self.* = undefined;
    }

    fn evaluate(context: *anyopaque, action: view.Action) !view.Evaluation {
        const self: *EditorHost = @ptrCast(@alignCast(context));
        const allocator = self.session.allocator;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const inputs = try arena.alloc(luce.backend.InputValue, self.program.inputs.len);
        for (self.program.inputs, inputs) |port, *slot| {
            slot.* = .{ .value = if (std.mem.eql(u8, port.name, "content"))
                .{ .string = self.content }
            else if (std.mem.eql(u8, port.name, "cursor"))
                .{ .int = self.cursor }
            else if (std.mem.eql(u8, port.name, "dirty"))
                .{ .boolean = self.dirty }
            else if (std.mem.eql(u8, port.name, "key"))
                .{ .string = action.key }
            else if (std.mem.eql(u8, port.name, "text"))
                .{ .string = action.text }
            else if (std.mem.eql(u8, port.name, "scroll"))
                .{ .int = self.scroll }
            else if (std.mem.eql(u8, port.name, "rows"))
                .{ .int = action.rows }
            else if (std.mem.eql(u8, port.name, "cols"))
                .{ .int = action.cols }
            else if (std.mem.eql(u8, port.name, "target"))
                .{ .string = self.target_label }
            else
                return error.InvalidView };
        }

        const outputs = try arena.alloc(?luce.backend.RuntimeValue, self.program.outputs.len);
        @memset(outputs, null);
        const result = try self.session.luce.evaluateView(arena, self.program, inputs, outputs);
        switch (result) {
            .success => {},
            .unavailable, .trap => return error.ViewEvaluationFailed,
        }

        const content = try allocator.dupe(u8, try stringOutput(self.program, outputs, "content"));
        errdefer allocator.free(content);
        const interface = try allocator.dupe(u8, try stringOutput(self.program, outputs, "interface"));
        errdefer allocator.free(interface);
        const cursor = try intOutput(self.program, outputs, "cursor");
        const scroll = try intOutput(self.program, outputs, "scroll");
        const dirty = try boolOutput(self.program, outputs, "dirty");
        const save_requested = try boolOutput(self.program, outputs, "save");
        const quit = try boolOutput(self.program, outputs, "quit");
        const cursor_row = try intOutput(self.program, outputs, "cursor_row");
        const cursor_col = try intOutput(self.program, outputs, "cursor_col");

        allocator.free(self.content);
        allocator.free(self.interface);
        self.content = content;
        self.interface = interface;
        self.cursor = cursor;
        self.scroll = scroll;
        self.dirty = dirty;
        return .{
            .frame = .{
                .interface = self.interface,
                .cursor_row = cursor_row,
                .cursor_col = cursor_col,
                .quit = quit,
            },
            .save = save_requested,
        };
    }

    fn save(context: *anyopaque) !void {
        const self: *EditorHost = @ptrCast(@alignCast(context));
        try saveContent(
            self.session.allocator,
            &self.session.authority,
            self.session.store,
            self.capability,
            self.target,
            self.content,
        );
    }
};

fn saveContent(
    allocator: std.mem.Allocator,
    authority: *const loom.capability.Authority,
    store: *loom.store.Store,
    capability: loom.capability.Capability,
    target: loom.texel_id.TexelId,
    content: []const u8,
) !void {
    var scope_buffer: [loom.texel_id.TexelId.text_size]u8 = undefined;
    const scope = target.format(&scope_buffer);
    if (!authority.verify(capability, "set_content", scope)) {
        return error.CapabilityDenied;
    }
    try ops.setContent(allocator, store, target, content);
}

fn runEditor(session: *Session, target_word: []const u8) Error!Result {
    const interactive = std.Io.File.stdin().isTty(session.io) catch false;
    if (!interactive) {
        try session.err.print("lucia: luce editor needs an interactive terminal\n", .{});
        return .err;
    }

    const editor_id = try common.resolveTexel(session, "editor") orelse return .err;
    const target_id = try common.resolveTexel(session, target_word) orelse return .err;
    const editor = session.store.get(editor_id).?;
    if (!editorSchema(editor)) {
        try session.err.print("lucia: editor has the wrong View schema\n", .{});
        return .err;
    }
    if (editor.content == null) {
        try session.err.print("lucia: editor has no luce source\n", .{});
        return .err;
    }
    if (try session.luce.checkView(editor)) |rendered| {
        defer session.allocator.free(rendered);
        try session.err.print("lucia: luce editor compile failed\n{s}", .{rendered});
        return .err;
    }
    const program = session.luce.cachedViewFor(editor) orelse return .err;

    var host = EditorHost.init(session, program, target_id) catch return error.OutOfMemory;
    defer host.deinit();
    var presenter: view.Presenter = .{
        .context = &host,
        .evaluateFn = EditorHost.evaluate,
        .saveFn = EditorHost.save,
    };
    view_shell.run(session.io, &presenter) catch {
        try session.err.print("lucia: the View could not run on this terminal\n", .{});
        return .err;
    };
    return .ok;
}

fn editorSchema(texel: *const loom.texel.Texel) bool {
    const Port = struct { name: []const u8, declared: loom.value.ValueType };
    const inputs = [_]Port{
        .{ .name = "content", .declared = .text },
        .{ .name = "cursor", .declared = .int },
        .{ .name = "dirty", .declared = .boolean },
        .{ .name = "key", .declared = .text },
        .{ .name = "text", .declared = .text },
        .{ .name = "scroll", .declared = .int },
        .{ .name = "rows", .declared = .int },
        .{ .name = "cols", .declared = .int },
        .{ .name = "target", .declared = .text },
    };
    const outputs = [_]Port{
        .{ .name = "content", .declared = .text },
        .{ .name = "cursor", .declared = .int },
        .{ .name = "dirty", .declared = .boolean },
        .{ .name = "scroll", .declared = .int },
        .{ .name = "interface", .declared = .text },
        .{ .name = "cursor_row", .declared = .int },
        .{ .name = "cursor_col", .declared = .int },
        .{ .name = "save", .declared = .boolean },
        .{ .name = "quit", .declared = .boolean },
    };
    if (texel.inputs.items.len != inputs.len) return false;
    if (texel.outputs.items.len != outputs.len + 1) return false;
    for (inputs) |expected| {
        const port = texel.getInput(expected.name) orelse return false;
        if (port.declared != expected.declared) return false;
    }
    for (outputs) |expected| {
        const port = texel.getOutput(expected.name) orelse return false;
        if (port.declared != expected.declared) return false;
    }
    const name = texel.getOutput("name") orelse return false;
    return name.declared == .text;
}

fn outputNamed(
    program: *const luce.ir.Program,
    outputs: []const ?luce.backend.RuntimeValue,
    name: []const u8,
) !luce.backend.RuntimeValue {
    for (program.outputs, outputs) |port, output| {
        if (std.mem.eql(u8, port.name, name)) return output orelse error.InvalidView;
    }
    return error.InvalidView;
}

fn stringOutput(program: *const luce.ir.Program, outputs: []const ?luce.backend.RuntimeValue, name: []const u8) ![]const u8 {
    return switch (try outputNamed(program, outputs, name)) {
        .string => |text| text,
        else => error.InvalidView,
    };
}

fn intOutput(program: *const luce.ir.Program, outputs: []const ?luce.backend.RuntimeValue, name: []const u8) !i64 {
    return switch (try outputNamed(program, outputs, name)) {
        .int => |number| number,
        else => error.InvalidView,
    };
}

fn boolOutput(program: *const luce.ir.Program, outputs: []const ?luce.backend.RuntimeValue, name: []const u8) !bool {
    return switch (try outputNamed(program, outputs, name)) {
        .boolean => |flag| flag,
        else => error.InvalidView,
    };
}

test "bootstrap editor frames and scoped durable save are headless" {
    const allocator = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try image.create(allocator, std.testing.io, scratch.dir, "editor.img", 64);

    var editor_id: loom.texel_id.TexelId = undefined;
    var target_id: loom.texel_id.TexelId = undefined;
    {
        var opened: image.Opened = undefined;
        try opened.setup(allocator, std.testing.io, scratch.dir, "editor.img");
        defer opened.deinit();

        var service = luce_service.LuceService.init(allocator);
        defer service.deinit();
        const bootstrap_file = try std.Io.Dir.cwd().openFile(
            std.testing.io,
            "bootstrap/editor.luc",
            .{},
        );
        defer bootstrap_file.close(std.testing.io);
        const bootstrap_size: usize = @intCast(try bootstrap_file.length(std.testing.io));
        const bootstrap_source = try allocator.alloc(u8, bootstrap_size);
        defer allocator.free(bootstrap_source);
        try std.testing.expectEqual(
            bootstrap_source.len,
            try bootstrap_file.readPositionalAll(std.testing.io, bootstrap_source, 0),
        );
        switch (try service.runScript(bootstrap_source)) {
            .ok => return error.TestUnexpectedResult,
            .diagnostics => |rendered| {
                defer allocator.free(rendered);
                return error.TestUnexpectedResult;
            },
            .trap => |message| {
                defer allocator.free(message);
                try std.testing.expectEqualStrings("file host unavailable", message);
            },
        }
        try std.testing.expectEqual(@as(usize, 0), service.pending.items.len);

        var authority = loom.capability.Authority.init(allocator);
        defer authority.deinit();
        var reader = luce_file_host.FileReader.init(std.testing.io, .cwd(), &authority);
        var file_host: luce_file_host.ScriptHost = undefined;
        try file_host.setup(
            allocator,
            &reader,
            "bootstrap/editor.luc",
        );
        defer file_host.deinit();
        switch (try service.runScriptHosted(bootstrap_source, file_host.host())) {
            .ok => {},
            .diagnostics => |rendered| {
                defer allocator.free(rendered);
                std.debug.print("bootstrap diagnostics:\n{s}", .{rendered});
                return error.TestUnexpectedResult;
            },
            .trap => |message| {
                defer allocator.free(message);
                std.debug.print("bootstrap trap: {s}\n", .{message});
                return error.TestUnexpectedResult;
            },
        }
        const applied = try service.applyTexels(std.testing.io, &opened.store);
        defer {
            for (applied) |made| allocator.free(made.name);
            allocator.free(applied);
        }
        try std.testing.expectEqual(@as(usize, 1), applied.len);
        try std.testing.expectEqualStrings("editor", applied[0].name);
        editor_id = applied[0].id;

        const editor = opened.store.get(editor_id).?;
        try std.testing.expect(editorSchema(editor));
        try std.testing.expectEqualStrings("luce", editor.evaluator.?);
        try std.testing.expect(editor.content != null);
        const evaluator_file = try std.Io.Dir.cwd().openFile(
            std.testing.io,
            "bootstrap/editor_view.luc",
            .{},
        );
        defer evaluator_file.close(std.testing.io);
        const evaluator_size: usize = @intCast(try evaluator_file.length(std.testing.io));
        const evaluator_source = try allocator.alloc(u8, evaluator_size);
        defer allocator.free(evaluator_source);
        try std.testing.expectEqual(
            evaluator_source.len,
            try evaluator_file.readPositionalAll(std.testing.io, evaluator_source, 0),
        );
        try std.testing.expectEqualStrings(evaluator_source, editor.content.?.text);
        try expectSource(editor, "content", .{ .text = "" });
        try expectSource(editor, "cursor", .{ .int = 0 });
        try expectSource(editor, "dirty", .{ .boolean = false });
        try expectSource(editor, "scroll", .{ .int = 0 });
        try expectSource(editor, "interface", .{ .text = "" });
        try expectSource(editor, "cursor_row", .{ .int = 0 });
        try expectSource(editor, "cursor_col", .{ .int = 0 });
        try expectSource(editor, "save", .{ .boolean = false });
        try expectSource(editor, "quit", .{ .boolean = false });
        try std.testing.expect((try service.checkView(editor)) == null);
        const program = service.cachedViewFor(editor).?;

        target_id = try ops.createTexel(
            allocator,
            std.testing.io,
            &opened.store,
            .{ .name = "target", .content = "A" },
        );
        const other_id = try ops.createTexel(
            allocator,
            std.testing.io,
            &opened.store,
            .{ .name = "other", .content = "B" },
        );

        var registry = loom.spool.Registry.init(allocator);
        defer registry.deinit();
        var spool = loom.spool.Spool.init(allocator, &opened.store, &registry);
        defer spool.deinit();
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(allocator);
        defer err.deinit();
        var session: Session = .{
            .allocator = allocator,
            .io = std.testing.io,
            .store = &opened.store,
            .spool = &spool,
            .out = &out.writer,
            .err = &err.writer,
            .luce = &service,
            .files = undefined,
            .authority = loom.capability.Authority.init(allocator),
        };
        defer session.deinit();
        var session_reader = luce_file_host.FileReader.init(
            std.testing.io,
            .cwd(),
            &session.authority,
        );
        session.files = &session_reader;

        var host = try EditorHost.init(&session, program, target_id);
        defer host.deinit();
        var presenter: view.Presenter = .{
            .context = &host,
            .evaluateFn = EditorHost.evaluate,
            .saveFn = EditorHost.save,
        };
        _ = try presenter.step(.{ .rows = 24, .cols = 80 });
        const inserted = try presenter.step(.{
            .key = "text",
            .text = "λ",
            .rows = 24,
            .cols = 80,
        });
        try std.testing.expectEqualStrings("λA", host.content);
        try std.testing.expectEqual(@as(i64, 2), host.cursor);
        try std.testing.expect(host.dirty);
        try std.testing.expect(std.mem.indexOf(u8, inserted.interface, "λA") != null);

        host.target = other_id;
        try std.testing.expectError(
            error.CapabilityDenied,
            presenter.step(.{ .key = "save", .rows = 24, .cols = 80 }),
        );
        try expectContent(opened.store.get(other_id).?, "B");

        host.target = target_id;
        _ = try presenter.step(.{ .key = "save", .rows = 24, .cols = 80 });
        try expectContent(opened.store.get(target_id).?, "λA");
        try expectContent(opened.store.get(other_id).?, "B");
    }

    var reopened: image.Opened = undefined;
    try reopened.setup(allocator, std.testing.io, scratch.dir, "editor.img");
    defer reopened.deinit();
    const persisted_editor = reopened.store.get(editor_id).?;
    try std.testing.expect(editorSchema(persisted_editor));
    try std.testing.expectEqualStrings("luce", persisted_editor.evaluator.?);
    const evaluator_file = try std.Io.Dir.cwd().openFile(
        std.testing.io,
        "bootstrap/editor_view.luc",
        .{},
    );
    defer evaluator_file.close(std.testing.io);
    const evaluator_size: usize = @intCast(try evaluator_file.length(std.testing.io));
    const evaluator_source = try allocator.alloc(u8, evaluator_size);
    defer allocator.free(evaluator_source);
    try std.testing.expectEqual(
        evaluator_source.len,
        try evaluator_file.readPositionalAll(std.testing.io, evaluator_source, 0),
    );
    try std.testing.expectEqualStrings(evaluator_source, persisted_editor.content.?.text);
    try expectContent(reopened.store.get(target_id).?, "λA");
}

fn expectSource(texel: *const loom.texel.Texel, name: []const u8, expected: loom.value.Value) !void {
    const source = texel.getOutput(name).?.source.?;
    try std.testing.expect(source.eql(expected));
}

fn expectContent(texel: *const loom.texel.Texel, expected: []const u8) !void {
    try std.testing.expect(texel.content != null);
    try std.testing.expectEqualStrings(expected, texel.content.?.text);
}
