//! The texel editor: ports and code, side by side in one screen.
//!
//! The editor works on a private clone of the texel — exactly a
//! transaction's view of the world.  The ports pane adds, renames,
//! retypes, deletes ports and sets output source values; the code pane
//! edits the Luce content with line numbers, syntax highlighting, and
//! auto-indent.  Ctrl+T (or Tab from the ports pane) jumps between
//! them, Ctrl+S asks the host to commit everything atomically, Ctrl+Q
//! leaves without saving.  The editor itself never touches the Store:
//! the hosting command owns commits, so this whole state machine runs
//! headless under tests.

const std = @import("std");
const loom = @import("loom");
const color = @import("../color.zig");
const key_mod = @import("key.zig");
const buffer_mod = @import("buffer.zig");
const highlight = @import("highlight.zig");

const Allocator = std.mem.Allocator;
const Texel = loom.texel.Texel;
const InputPort = loom.texel.InputPort;
const OutputPort = loom.texel.OutputPort;
const TexelId = loom.texel_id.TexelId;
const Value = loom.value.Value;
const ValueType = loom.value.ValueType;
const Key = key_mod.Key;
const Buffer = buffer_mod.Buffer;

pub const Pane = enum { ports, code };

const PromptKind = enum {
    add_input_name,
    add_input_type,
    add_output_name,
    add_output_type,
    rename,
    retype,
    set_value,
};

const Prompt = struct {
    kind: PromptKind,
    text: std.ArrayList(u8) = .empty,
    carry: std.ArrayList(u8) = .empty,

    fn deinit(self: *Prompt, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.carry.deinit(allocator);
        self.* = undefined;
    }
};

pub const Editor = struct {
    allocator: Allocator,
    palette: color.Palette,
    label: []u8, // display name of the texel
    texel: Texel, // the working clone; the host commits it
    buffer: Buffer,
    pane: Pane = .ports,
    port_row: usize = 0,
    scroll: usize = 0,
    rows: usize = 24,
    columns: usize = 80,
    status: std.ArrayList(u8) = .empty,
    prompt: ?Prompt = null,
    done: bool = false,
    save_requested: bool = false,

    /// Takes ownership of the texel clone.  The label is copied.
    pub fn init(
        allocator: Allocator,
        palette: color.Palette,
        label: []const u8,
        texel: Texel,
    ) !Editor {
        const source = if (texel.content) |content|
            (if (content == .text) content.text else "")
        else
            "";
        var buffer = try Buffer.init(allocator, source);
        errdefer buffer.deinit();
        return .{
            .allocator = allocator,
            .palette = palette,
            .label = try allocator.dupe(u8, label),
            .texel = texel,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.allocator.free(self.label);
        self.texel.deinit(self.allocator);
        self.buffer.deinit();
        self.status.deinit(self.allocator);
        if (self.prompt) |*prompt| prompt.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resize(self: *Editor, rows: usize, columns: usize) void {
        self.rows = @max(rows, 6);
        self.columns = @max(columns, 20);
    }

    fn setStatus(self: *Editor, comptime format: []const u8, arguments: anytype) !void {
        self.status.clearRetainingCapacity();
        const rendered = try std.fmt.allocPrint(self.allocator, format, arguments);
        defer self.allocator.free(rendered);
        try self.status.appendSlice(self.allocator, rendered);
    }

    /// The host commits on request; this reports how it went.
    pub fn takeSaveRequest(self: *Editor) bool {
        const asked = self.save_requested;
        self.save_requested = false;
        return asked;
    }

    pub fn reportSave(self: *Editor, message: []const u8) !void {
        try self.setStatus("{s}", .{message});
    }

    // Input ----------------------------------------------------------------

    pub fn feed(self: *Editor, key: Key) !void {
        if (self.prompt != null) return self.feedPrompt(key);
        switch (key) {
            .control => |letter| switch (letter) {
                'q' => self.done = true,
                's' => self.save_requested = true,
                't' => self.pane = if (self.pane == .ports) .code else .ports,
                else => {},
            },
            else => switch (self.pane) {
                .ports => try self.feedPorts(key),
                .code => try self.feedCode(key),
            },
        }
    }

    fn feedPorts(self: *Editor, key: Key) !void {
        switch (key) {
            .tab => self.pane = .code,
            .up => {
                if (self.port_row > 0) self.port_row -= 1;
            },
            .down => {
                if (self.port_row + 1 < self.portCount()) self.port_row += 1;
            },
            .character => |letter| switch (letter) {
                'i' => try self.openPrompt(.add_input_name, "", "new input name"),
                'o' => try self.openPrompt(.add_output_name, "", "new output name"),
                'r' => {
                    if (self.portCount() == 0) return;
                    try self.openPrompt(.rename, "", "new port name");
                },
                't' => {
                    if (self.portCount() == 0) return;
                    try self.openPrompt(.retype, "", "new type (bool int real text bytes texel blob)");
                },
                'v' => {
                    if (self.selectedOutput() == null) {
                        try self.setStatus("values live on Output Ports (inputs get theirs through fibers)", .{});
                        return;
                    }
                    try self.openPrompt(.set_value, "", "value");
                },
                'd' => try self.deleteSelected(),
                else => {},
            },
            else => {},
        }
    }

    fn feedCode(self: *Editor, key: Key) !void {
        switch (key) {
            .character => |letter| try self.buffer.insert(letter),
            .enter => try self.buffer.newline(),
            .tab => try self.buffer.insertSlice("    "),
            .backspace => try self.buffer.backspace(),
            .delete => try self.buffer.delete(),
            .up => self.buffer.up(),
            .down => self.buffer.down(),
            .left => self.buffer.left(),
            .right => self.buffer.right(),
            .home => self.buffer.home(),
            .end => self.buffer.lineEnd(),
            .page_up => self.buffer.page(-@as(isize, @intCast(self.codeRows()))),
            .page_down => self.buffer.page(@intCast(self.codeRows())),
            else => {},
        }
    }

    fn feedPrompt(self: *Editor, key: Key) !void {
        const prompt = &self.prompt.?;
        switch (key) {
            .character => |letter| try prompt.text.append(self.allocator, letter),
            .backspace => {
                if (prompt.text.items.len > 0) {
                    _ = prompt.text.pop();
                }
            },
            .escape => {
                prompt.deinit(self.allocator);
                self.prompt = null;
                try self.setStatus("cancelled", .{});
            },
            .enter => try self.completePrompt(),
            else => {},
        }
    }

    fn openPrompt(self: *Editor, kind: PromptKind, carry: []const u8, hint: []const u8) !void {
        var prompt: Prompt = .{ .kind = kind };
        errdefer prompt.deinit(self.allocator);
        try prompt.carry.appendSlice(self.allocator, carry);
        self.prompt = prompt;
        try self.setStatus("{s}", .{hint});
    }

    fn completePrompt(
        self: *Editor,
    ) !void {
        var prompt = self.prompt.?;
        self.prompt = null;
        defer prompt.deinit(self.allocator);
        const entered = std.mem.trim(u8, prompt.text.items, " ");
        if (entered.len == 0) {
            try self.setStatus("cancelled", .{});
            return;
        }
        switch (prompt.kind) {
            .add_input_name => try self.openPromptCarry(.add_input_type, entered, "input type (bool int real text bytes texel blob)"),
            .add_output_name => try self.openPromptCarry(.add_output_type, entered, "output type (bool int real text bytes texel blob)"),
            .add_input_type => try self.addPort(true, prompt.carry.items, entered),
            .add_output_type => try self.addPort(false, prompt.carry.items, entered),
            .rename => try self.renameSelected(entered),
            .retype => try self.retypeSelected(entered),
            .set_value => try self.setSelectedValue(entered),
        }
    }

    fn openPromptCarry(self: *Editor, kind: PromptKind, carry: []const u8, hint: []const u8) !void {
        try self.openPrompt(kind, carry, hint);
    }

    // Port operations -------------------------------------------------------

    fn portCount(self: *const Editor) usize {
        return self.texel.inputCount() + self.texel.outputCount();
    }

    fn selectedInput(self: *const Editor) ?*const InputPort {
        if (self.port_row < self.texel.inputCount()) {
            return self.texel.inputAt(self.port_row);
        }
        return null;
    }

    fn selectedOutput(self: *const Editor) ?*const OutputPort {
        const inputs = self.texel.inputCount();
        if (self.port_row >= inputs and self.port_row < self.portCount()) {
            return self.texel.outputAt(self.port_row - inputs);
        }
        return null;
    }

    fn parseTypeName(text: []const u8) ?ValueType {
        const Named = struct {
            name: []const u8,
            declared: ValueType,
        };
        const named = [_]Named{
            .{ .name = "bool", .declared = .boolean },
            .{ .name = "int", .declared = .int },
            .{ .name = "real", .declared = .real },
            .{ .name = "text", .declared = .text },
            .{ .name = "bytes", .declared = .bytes },
            .{ .name = "texel", .declared = .texel },
            .{ .name = "blob", .declared = .blob },
        };
        for (named) |candidate| {
            if (std.mem.eql(u8, text, candidate.name)) return candidate.declared;
        }
        return null;
    }

    fn addPort(self: *Editor, is_input: bool, name: []const u8, type_text: []const u8) !void {
        const declared = parseTypeName(type_text) orelse {
            try self.setStatus("unknown type {s}", .{type_text});
            return;
        };
        if (is_input) {
            if (self.texel.hasInput(name)) {
                try self.setStatus("input {s} already exists", .{name});
                return;
            }
            const port = try InputPort.init(self.allocator, name, declared);
            self.texel.putInput(self.allocator, port) catch {
                try self.setStatus("cannot add input {s}", .{name});
                return;
            };
        } else {
            if (self.texel.hasOutput(name)) {
                try self.setStatus("output {s} already exists", .{name});
                return;
            }
            const port = try OutputPort.init(self.allocator, name, declared);
            self.texel.putOutput(self.allocator, port) catch {
                try self.setStatus("cannot add output {s}", .{name});
                return;
            };
        }
        try self.setStatus("added {s} {s} {s}", .{
            if (is_input) @as([]const u8, "input") else "output",
            name,
            type_text,
        });
    }

    fn renameSelected(self: *Editor, name: []const u8) !void {
        if (self.selectedInput()) |input| {
            if (self.texel.hasInput(name)) {
                try self.setStatus("input {s} already exists", .{name});
                return;
            }
            var renamed = try InputPort.init(self.allocator, name, input.declared);
            errdefer renamed.deinit(self.allocator);
            if (input.binding) |binding| {
                const fiber = try loom.texel.Fiber.init(self.allocator, binding.source, binding.output);
                renamed.bind(self.allocator, fiber) catch {};
            }
            const old = try self.allocator.dupe(u8, input.name);
            defer self.allocator.free(old);
            _ = self.texel.removeInput(self.allocator, old);
            try self.texel.putInput(self.allocator, renamed);
            try self.setStatus("renamed {s} to {s}", .{ old, name });
            return;
        }
        if (self.selectedOutput()) |output| {
            if (self.texel.hasOutput(name)) {
                try self.setStatus("output {s} already exists", .{name});
                return;
            }
            var renamed = try OutputPort.init(self.allocator, name, output.declared);
            errdefer renamed.deinit(self.allocator);
            if (output.source) |source| {
                const carried = try source.clone(self.allocator);
                renamed.setSource(self.allocator, carried) catch {};
            }
            const old = try self.allocator.dupe(u8, output.name);
            defer self.allocator.free(old);
            _ = self.texel.removeOutput(self.allocator, old);
            try self.texel.putOutput(self.allocator, renamed);
            try self.setStatus("renamed {s} to {s} (rewire consumers with mv if bound)", .{ old, name });
            return;
        }
    }

    fn retypeSelected(self: *Editor, type_text: []const u8) !void {
        const declared = parseTypeName(type_text) orelse {
            try self.setStatus("unknown type {s}", .{type_text});
            return;
        };
        if (self.selectedInput()) |input| {
            const name = try self.allocator.dupe(u8, input.name);
            defer self.allocator.free(name);
            _ = self.texel.removeInput(self.allocator, name);
            try self.texel.putInput(self.allocator, try InputPort.init(self.allocator, name, declared));
            try self.setStatus("{s} is now {s} (binding dropped)", .{ name, type_text });
            return;
        }
        if (self.selectedOutput()) |output| {
            const name = try self.allocator.dupe(u8, output.name);
            defer self.allocator.free(name);
            _ = self.texel.removeOutput(self.allocator, name);
            try self.texel.putOutput(self.allocator, try OutputPort.init(self.allocator, name, declared));
            try self.setStatus("{s} is now {s} (value cleared)", .{ name, type_text });
            return;
        }
    }

    fn setSelectedValue(self: *Editor, text: []const u8) !void {
        const output = self.selectedOutput() orelse return;
        const name = try self.allocator.dupe(u8, output.name);
        defer self.allocator.free(name);

        var value: Value = switch (output.declared) {
            .boolean => if (std.mem.eql(u8, text, "true"))
                .{ .boolean = true }
            else if (std.mem.eql(u8, text, "false"))
                .{ .boolean = false }
            else {
                try self.setStatus("bool value must be true or false", .{});
                return;
            },
            .int => .{ .int = std.fmt.parseInt(i64, text, 10) catch {
                try self.setStatus("{s} is not an int", .{text});
                return;
            } },
            .real => .{ .real = std.fmt.parseFloat(f64, text) catch {
                try self.setStatus("{s} is not a real", .{text});
                return;
            } },
            .text => try Value.initText(self.allocator, text),
            .bytes => try Value.initBytes(self.allocator, text),
            else => {
                try self.setStatus("cannot type a {s} value here", .{@tagName(output.declared)});
                return;
            },
        };
        const mutable = self.texel.mutableOutput(name).?;
        mutable.setSource(self.allocator, value) catch {
            value.deinit(self.allocator);
            try self.setStatus("value does not fit {s}", .{name});
            return;
        };
        try self.setStatus("{s} = {s}", .{ name, text });
    }

    fn deleteSelected(self: *Editor) !void {
        if (self.selectedInput()) |input| {
            const name = try self.allocator.dupe(u8, input.name);
            defer self.allocator.free(name);
            _ = self.texel.removeInput(self.allocator, name);
            try self.setStatus("dropped input {s}", .{name});
        } else if (self.selectedOutput()) |output| {
            const name = try self.allocator.dupe(u8, output.name);
            defer self.allocator.free(name);
            _ = self.texel.removeOutput(self.allocator, name);
            try self.setStatus("dropped output {s} (consumers must disconnect)", .{name});
        }
        if (self.port_row >= self.portCount() and self.port_row > 0) {
            self.port_row -= 1;
        }
    }

    // Rendering -------------------------------------------------------------

    fn codeRows(self: *const Editor) usize {
        return self.rows - 2;
    }

    /// Draw the whole frame: header, pane, status line.  The host adds
    /// screen control (clear, cursor placement).
    pub fn render(self: *Editor, writer: *std.Io.Writer) !void {
        const palette = self.palette;
        try writer.print("{s}edit {s}{s}  [{s}]  ^S save  ^Q quit  ^T switch pane{s}\n", .{
            palette.sgr(.bold),
            self.label,
            palette.sgr(.reset),
            @tagName(self.pane),
            if (self.buffer.changed) "  *" else "",
        });

        switch (self.pane) {
            .ports => try self.renderPorts(writer),
            .code => try self.renderCode(writer),
        }

        if (self.prompt) |prompt| {
            try writer.print("{s}{s}: {s}_{s}\n", .{
                palette.sgr(.prompt),
                self.status.items,
                prompt.text.items,
                palette.sgr(.reset),
            });
        } else {
            try writer.print("{s}{s}{s}\n", .{
                palette.sgr(.dim),
                self.status.items,
                palette.sgr(.reset),
            });
        }
    }

    fn renderPorts(self: *Editor, writer: *std.Io.Writer) !void {
        const palette = self.palette;
        var row: usize = 0;
        try writer.print("{s}inputs:{s}\n", .{ palette.sgr(.bold), palette.sgr(.reset) });
        for (0..self.texel.inputCount()) |index| {
            const input = self.texel.inputAt(index).?;
            try self.renderRowMarker(writer, row);
            try writer.print("{s}{s}{s} {s}", .{
                palette.sgr(.port),
                input.name,
                palette.sgr(.reset),
                typeName(input.declared),
            });
            if (input.binding) |binding| {
                var buffer: [TexelId.text_size]u8 = undefined;
                try writer.print(" {s}<- {s}.{s}{s}", .{
                    palette.sgr(.dim),
                    binding.source.format(&buffer)[0..8],
                    binding.output,
                    palette.sgr(.reset),
                });
            } else {
                try writer.print(" {s}(unbound){s}", .{ palette.sgr(.dim), palette.sgr(.reset) });
            }
            try writer.writeAll("\n");
            row += 1;
        }
        try writer.print("{s}outputs:{s}\n", .{ palette.sgr(.bold), palette.sgr(.reset) });
        for (0..self.texel.outputCount()) |index| {
            const output = self.texel.outputAt(index).?;
            try self.renderRowMarker(writer, row);
            try writer.print("{s}{s}{s} {s}", .{
                palette.sgr(.port),
                output.name,
                palette.sgr(.reset),
                typeName(output.declared),
            });
            if (output.source) |source| {
                const rendered = try valueText(self.allocator, source);
                defer self.allocator.free(rendered);
                try writer.print(" {s}= {s}{s}", .{
                    palette.sgr(.value),
                    rendered,
                    palette.sgr(.reset),
                });
            } else {
                try writer.print(" {s}(no value){s}", .{ palette.sgr(.dim), palette.sgr(.reset) });
            }
            try writer.writeAll("\n");
            row += 1;
        }
        try writer.print(
            "\n{s}i input  o output  r rename  t type  v value  d delete  Tab code{s}\n",
            .{ palette.sgr(.dim), palette.sgr(.reset) },
        );
    }

    fn renderRowMarker(self: *Editor, writer: *std.Io.Writer, row: usize) !void {
        if (row == self.port_row) {
            try writer.print("{s} >{s} ", .{ self.palette.sgr(.prompt), self.palette.sgr(.reset) });
        } else {
            try writer.writeAll("   ");
        }
    }

    fn renderCode(self: *Editor, writer: *std.Io.Writer) !void {
        const palette = self.palette;
        const visible = self.codeRows();
        if (self.buffer.row < self.scroll) {
            self.scroll = self.buffer.row;
        } else if (self.buffer.row >= self.scroll + visible) {
            self.scroll = self.buffer.row - visible + 1;
        }

        for (self.scroll..@min(self.scroll + visible, self.buffer.lineCount())) |index| {
            const marker = if (index == self.buffer.row) ">" else " ";
            try writer.print("{s}{d:>4}{s}{s} ", .{
                palette.sgr(.line_number),
                index + 1,
                marker,
                palette.sgr(.reset),
            });
            try highlight.writeLine(writer, self.allocator, palette, self.buffer.line(index));
            try writer.writeAll("\n");
        }
    }
};

fn typeName(declared: ValueType) []const u8 {
    return switch (declared) {
        .none => "none",
        .boolean => "bool",
        .int => "int",
        .real => "real",
        .text => "text",
        .bytes => "bytes",
        .texel => "texel",
        .blob => "blob",
    };
}

fn valueText(allocator: Allocator, value: Value) ![]u8 {
    return switch (value) {
        .none => try allocator.dupe(u8, "none"),
        .boolean => |flag| try allocator.dupe(u8, if (flag) "true" else "false"),
        .int => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .real => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .text => |text| try std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
        .bytes => |bytes| try std.fmt.allocPrint(allocator, "{d} bytes", .{bytes.len}),
        .texel => try allocator.dupe(u8, "texel"),
        .blob => try allocator.dupe(u8, "blob"),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn feedText(editor: *Editor, text: []const u8) !void {
    for (text) |character| try editor.feed(.{ .character = character });
}

fn renderFrame(editor: *Editor) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    try editor.render(&sink.writer);
    return testing.allocator.dupe(u8, sink.written());
}

fn testEditor() !Editor {
    var texel = Texel.init(TexelId.generate(testing.io));
    errdefer texel.deinit(testing.allocator);
    try texel.putOutput(
        testing.allocator,
        try OutputPort.init(testing.allocator, "value", .int),
    );
    try texel.setContent(
        testing.allocator,
        try Value.initText(testing.allocator, "fn evaluate():\n    output.value = 1\n"),
    );
    return Editor.init(testing.allocator, .{}, "sample", texel);
}

test "ports pane adds, renames, values, and deletes ports" {
    var editor = try testEditor();
    defer editor.deinit();

    // Add an input: i, name, enter, type, enter.
    try editor.feed(.{ .character = 'i' });
    try feedText(&editor, "left");
    try editor.feed(.enter);
    try feedText(&editor, "int");
    try editor.feed(.enter);
    try testing.expect(editor.texel.hasInput("left"));

    // Set a value on the output row (inputs come first).
    editor.port_row = 1;
    try editor.feed(.{ .character = 'v' });
    try feedText(&editor, "41");
    try editor.feed(.enter);
    try testing.expectEqual(@as(i64, 41), editor.texel.getOutput("value").?.source.?.int);

    // Rename the output.
    try editor.feed(.{ .character = 'r' });
    try feedText(&editor, "total");
    try editor.feed(.enter);
    try testing.expect(editor.texel.hasOutput("total"));
    try testing.expectEqual(@as(i64, 41), editor.texel.getOutput("total").?.source.?.int);

    // Delete the input row.
    editor.port_row = 0;
    try editor.feed(.{ .character = 'd' });
    try testing.expect(!editor.texel.hasInput("left"));

    const frame = try renderFrame(&editor);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "total int = 41") != null);
}

test "code pane edits with auto-indent and renders line numbers" {
    var editor = try testEditor();
    defer editor.deinit();
    try editor.feed(.{ .control = 't' }); // to code pane
    try testing.expectEqual(Pane.code, editor.pane);

    // Go to end of file and add an indented line.
    editor.buffer.down();
    editor.buffer.lineEnd();
    try editor.feed(.enter);
    try feedText(&editor, "output.value = 2");

    const frame = try renderFrame(&editor);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "   1  fn evaluate():") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "output.value = 2") != null);

    const text = try editor.buffer.text();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "    output.value = 2\n") != null);
}

test "save request and quit flow through the host" {
    var editor = try testEditor();
    defer editor.deinit();
    try editor.feed(.{ .control = 's' });
    try testing.expect(editor.takeSaveRequest());
    try testing.expect(!editor.takeSaveRequest());
    try editor.reportSave("saved");
    try testing.expect(std.mem.indexOf(u8, editor.status.items, "saved") != null);
    try editor.feed(.{ .control = 'q' });
    try testing.expect(editor.done);
}

test "syntax colors appear in the code pane when enabled" {
    var texel = Texel.init(TexelId.generate(testing.io));
    errdefer texel.deinit(testing.allocator);
    try texel.setContent(
        testing.allocator,
        try Value.initText(testing.allocator, "let x = 1\n"),
    );
    var editor = try Editor.init(testing.allocator, .{ .enabled = true }, "vivid", texel);
    defer editor.deinit();
    editor.pane = .code;

    const frame = try renderFrame(&editor);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[35mlet\x1b[0m") != null);
}
