//! Process-argument and terminal-line parsing for the loom app.

const std = @import("std");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// CommandLine
// ---------------------------------------------------------------------------
//
// Parsed process command line: one command word, named options, and
// positionals.  Every option (--name) consumes the following argument
// as its value.  The parsed slices borrow argv; argv must outlive the
// CommandLine.
//
pub const CommandLine = struct {
    const Option = struct {
        name: []const u8,
        value: []const u8,
    };

    command: []const u8,
    options: std.ArrayList(Option) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,

    pub fn parse(allocator: Allocator, arguments: []const [:0]const u8) !?CommandLine {
        if (arguments.len < 2) return null;

        var line: CommandLine = .{ .command = arguments[1] };
        errdefer line.deinit(allocator);
        var index: usize = 2;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            if (std.mem.startsWith(u8, argument, "--")) {
                if (index + 1 >= arguments.len) return null;
                index += 1;
                try line.options.append(allocator, .{
                    .name = argument,
                    .value = arguments[index],
                });
            } else {
                try line.positionals.append(allocator, argument);
            }
        }
        return line;
    }

    pub fn deinit(self: *CommandLine, allocator: Allocator) void {
        self.options.deinit(allocator);
        self.positionals.deinit(allocator);
        self.* = undefined;
    }

    pub fn option(self: *const CommandLine, name: []const u8, fallback: []const u8) []const u8 {
        for (self.options.items) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate.value;
        }
        return fallback;
    }

    pub fn optionU64(self: *const CommandLine, name: []const u8, fallback: u64) u64 {
        for (self.options.items) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) {
                return std.fmt.parseInt(u64, candidate.value, 10) catch fallback;
            }
        }
        return fallback;
    }

    pub fn positionalCount(self: *const CommandLine) usize {
        return self.positionals.items.len;
    }

    pub fn positional(self: *const CommandLine, index: usize) ?[]const u8 {
        if (index >= self.positionals.items.len) return null;
        return self.positionals.items[index];
    }
};

// ---------------------------------------------------------------------------
// splitWords
// ---------------------------------------------------------------------------

/// Split one line into whitespace-separated words; double quotes group
/// words.  Returns null on an unbalanced quote.  The caller owns the
/// returned words (free with freeWords).
pub fn splitWords(allocator: Allocator, line: []const u8) !?[][]u8 {
    var words: std.ArrayList([]u8) = .empty;
    errdefer freeWords(allocator, &words);
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);

    var in_word = false;
    var quoted = false;
    for (line) |character| {
        if (quoted) {
            if (character == '"') {
                quoted = false;
            } else {
                try word.append(allocator, character);
            }
            continue;
        }
        switch (character) {
            '"' => {
                quoted = true;
                in_word = true;
            },
            ' ', '\t', '\n', '\r' => {
                if (in_word) {
                    try words.append(allocator, try word.toOwnedSlice(allocator));
                    in_word = false;
                }
            },
            else => {
                try word.append(allocator, character);
                in_word = true;
            },
        }
    }
    if (quoted) {
        freeWords(allocator, &words);
        return null;
    }
    if (in_word) {
        try words.append(allocator, try word.toOwnedSlice(allocator));
    }
    return try words.toOwnedSlice(allocator);
}

pub fn freeWordSlice(allocator: Allocator, words: [][]u8) void {
    for (words) |word| allocator.free(word);
    allocator.free(words);
}

fn freeWords(allocator: Allocator, words: *std.ArrayList([]u8)) void {
    for (words.items) |word| allocator.free(word);
    words.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "command line separates command, options, and positionals" {
    const allocator = testing.allocator;
    const arguments = [_][:0]const u8{ "loom", "create", "image.bin", "--pages", "128" };

    var line = (try CommandLine.parse(allocator, &arguments)).?;
    defer line.deinit(allocator);

    try testing.expectEqualStrings("create", line.command);
    try testing.expectEqual(@as(usize, 1), line.positionalCount());
    try testing.expectEqualStrings("image.bin", line.positional(0).?);
    try testing.expectEqual(@as(u64, 128), line.optionU64("--pages", 64));
    try testing.expectEqual(@as(u64, 64), line.optionU64("--missing", 64));

    const empty = [_][:0]const u8{"loom"};
    try testing.expectEqual(@as(?CommandLine, null), try CommandLine.parse(allocator, &empty));
    const dangling = [_][:0]const u8{ "loom", "create", "--pages" };
    try testing.expectEqual(@as(?CommandLine, null), try CommandLine.parse(allocator, &dangling));
}

test "split words groups quotes and refuses unbalanced ones" {
    const allocator = testing.allocator;

    const words = (try splitWords(allocator, "  set value \"hello world\"\n")).?;
    defer freeWordSlice(allocator, words);
    try testing.expectEqual(@as(usize, 3), words.len);
    try testing.expectEqualStrings("set", words[0]);
    try testing.expectEqualStrings("value", words[1]);
    try testing.expectEqualStrings("hello world", words[2]);

    try testing.expectEqual(@as(?[][]u8, null), try splitWords(allocator, "say \"broken"));

    const empty = (try splitWords(allocator, "   \t \n")).?;
    defer freeWordSlice(allocator, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
