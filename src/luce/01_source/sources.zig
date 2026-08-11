//! The source registry: every file a compile loaded, by identity.
//!
//! One compile is many files — the root, the standard library modules
//! it reaches, the sibling modules it imports — and every span the
//! compiler produces points into exactly one of them.  This is where
//! that correspondence lives: give it a `FileId` and it answers with
//! the module's name, the path a diagnostic should print, its text,
//! and the line and column of any offset in that text.
//!
//! Ownership: the registry owns every byte it holds.  Text handed to
//! `add` is taken over (freed by `deinit`), so a caller may drop the
//! buffer it read from disk as soon as it has registered it, and a
//! diagnostic stays renderable after the compile's arenas are gone.
//!
//! Identity: a `FileId` is an index into the registry in load order,
//! so the root is always `root_file` (0).  Ids are stable for the
//! life of the registry.

const std = @import("std");
const positions = @import("positions.zig");

const Allocator = std.mem.Allocator;
const Place = positions.Place;

pub const Error = error{OutOfMemory};

/// A loaded file, by position in the registry.
pub const FileId = u32;

/// The root is loaded first, so it always has this id.
pub const root_file: FileId = 0;

/// Where a file came from — the difference matters to diagnostics
/// ("that error is in the standard library, not in your code") and to
/// resolution, which reads it back to see that `import std.math` and
/// `import math` are not both claiming the binding `math`.
pub const Kind = enum { root, standard, imported };

pub const File = struct {
    kind: Kind,
    /// The opaque root token the host chose for this file — which
    /// project root it belongs to (docs/PACKAGES.md D7).  The compiler
    /// never learns what a root *is*: the token keys the registry
    /// together with `name`, and resolution hands it back to the
    /// host's loader on every load this file causes.  "" is the
    /// rootless program, and today's only value.
    root: []u8,
    /// The module's full name as an import spells it — "geo",
    /// "geo.shapes", "std.math" — and its identity within `root`;
    /// "" for the root file.
    name: []u8,
    /// The namespace call sites use for it: the name's last segment,
    /// or the alias an `import ... as` chose.  One module holds one
    /// binding for the whole program — the prefix every qualified
    /// declaration name is built from — so resolution refuses a
    /// second spelling rather than recording it.  "" for the root.
    binding: []u8,
    /// How a diagnostic names it: the root's display name as the host
    /// gave it ("editor.luc"), or NAME.luc for a module.
    path: []u8,
    /// The prepared text (see encoding.zig): no BOM, LF line endings,
    /// valid UTF-8.  Every span in this file indexes *this* buffer.
    text: []u8,
    /// Byte offset where each line begins, ascending; always at least
    /// one entry, because line 1 begins at offset 0 even when the file
    /// is empty.  Built once at registration — every debug build turns
    /// thousands of offsets into origins, and the alternative is a
    /// scan of the whole file per lookup.
    line_starts: []u32,
};

/// One resolution the registry remembers: within `namespace` — the
/// opaque root token of the file the import was written in — the
/// import spelled `name` means `file`.  A claim is not a file: one
/// file may be claimed from several namespaces under several
/// spellings (a package module is `geo.shapes` to its consumer and
/// `shapes` to a sibling inside the package), and the claims are what
/// keep those spellings answering the one module rather than loading
/// it twice (docs/PACKAGES.md D4, D7).
const Claim = struct {
    namespace: []u8,
    name: []u8,
    file: FileId,
};

pub const Sources = struct {
    allocator: Allocator,
    list: std.ArrayList(File) = .empty,
    claims: std.ArrayList(Claim) = .empty,

    pub fn init(allocator: Allocator) Sources {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Sources) void {
        for (self.list.items) |file| {
            self.allocator.free(file.root);
            self.allocator.free(file.name);
            self.allocator.free(file.binding);
            self.allocator.free(file.path);
            self.allocator.free(file.text);
            self.allocator.free(file.line_starts);
        }
        self.list.deinit(self.allocator);
        for (self.claims.items) |made| {
            self.allocator.free(made.namespace);
            self.allocator.free(made.name);
        }
        self.claims.deinit(self.allocator);
        self.* = undefined;
    }

    /// Register a prepared source text and answer its id.  The
    /// registry takes ownership of `text` (allocated by the same
    /// allocator) and copies `root`, `name`, `binding` and `path`.
    /// Ownership transfers even when this fails: a caller that hands
    /// text over never has to free it, so there is one rule rather
    /// than two.
    pub fn add(
        self: *Sources,
        kind: Kind,
        root: []const u8,
        name: []const u8,
        binding: []const u8,
        path: []const u8,
        text: []u8,
    ) Error!FileId {
        errdefer self.allocator.free(text);
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_binding = try self.allocator.dupe(u8, binding);
        errdefer self.allocator.free(owned_binding);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const line_starts = try indexLines(self.allocator, text);
        errdefer self.allocator.free(line_starts);
        try self.list.append(self.allocator, .{
            .kind = kind,
            .root = owned_root,
            .name = owned_name,
            .binding = owned_binding,
            .path = owned_path,
            .text = text,
            .line_starts = line_starts,
        });
        return @intCast(self.list.items.len - 1);
    }

    pub fn count(self: *const Sources) usize {
        return self.list.items.len;
    }

    /// The file, or null when the id names nothing — which happens
    /// only for diagnostics raised before any file was registered.
    /// The pointer is borrowed until the next `add`; the text it
    /// points at is not, since each file's bytes are their own
    /// allocation and never move.
    pub fn at(self: *const Sources, file: FileId) ?*const File {
        if (file >= self.list.items.len) return null;
        return &self.list.items[file];
    }

    /// The id of the module named `name` within `root`, or null.  The
    /// pair is the key (docs/PACKAGES.md D7): one name may mean
    /// different modules under different roots, so dedup and cycle
    /// termination ask with the importing file's root.  Linear over a
    /// list that a project keeps to a few dozen entries.
    pub fn find(self: *const Sources, root: []const u8, name: []const u8) ?FileId {
        for (self.list.items, 0..) |file, index| {
            if (std.mem.eql(u8, file.root, root) and
                std.mem.eql(u8, file.name, name)) return @intCast(index);
        }
        return null;
    }

    /// The id of the file the host already opened at `path` for `root`,
    /// or null.  This is what keeps a module reached under two
    /// spellings — `geo.shapes` from the consumer, `shapes` from inside
    /// the package — one module: whatever the import said, the host
    /// answered with one file, and one file is one set of declarations
    /// (docs/PACKAGES.md D4).  Textual, like the self-import check: two
    /// spellings of one path are the host's problem, and it is the host
    /// that answered with these.
    pub fn findByPath(self: *const Sources, root: []const u8, path: []const u8) ?FileId {
        if (path.len == 0) return null;
        for (self.list.items, 0..) |file, index| {
            if (std.mem.eql(u8, file.root, root) and
                std.mem.eql(u8, file.path, path)) return @intCast(index);
        }
        return null;
    }

    /// The id of the standard module named `name` ("std.math"), or
    /// null.  The library is embedded and identical wherever it is
    /// imported from, so one program holds one copy of each std module
    /// and every namespace that imports it claims that copy.
    pub fn findStandard(self: *const Sources, name: []const u8) ?FileId {
        for (self.list.items, 0..) |file, index| {
            if (file.kind == .standard and std.mem.eql(u8, file.name, name)) return @intCast(index);
        }
        return null;
    }

    /// Remember that within `namespace`, the import spelled `name`
    /// resolved to `file`.  Both strings are copied.
    pub fn recordClaim(
        self: *Sources,
        namespace: []const u8,
        name: []const u8,
        file: FileId,
    ) Error!void {
        const owned_namespace = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(owned_namespace);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.claims.append(self.allocator, .{
            .namespace = owned_namespace,
            .name = owned_name,
            .file = file,
        });
    }

    /// The file that `name`, written in `namespace`, already resolved
    /// to — or null when this spelling has not been asked here yet.
    /// This is resolution's memory: asking again answers the module
    /// already loaded, which is how a cycle terminates, and stage 4
    /// reads it back to know which module an import binding names.
    pub fn claim(self: *const Sources, namespace: []const u8, name: []const u8) ?FileId {
        for (self.claims.items) |made| {
            if (std.mem.eql(u8, made.namespace, namespace) and
                std.mem.eql(u8, made.name, name)) return made.file;
        }
        return null;
    }

    /// The id of the module *bound* as `binding` within `namespace`,
    /// or null — the question collision asks: whichever module it
    /// names, a binding may hold only one (`luce.import.collision`).
    /// Asked of the claims, because the binding lives where the import
    /// was written: a package's entry module belongs to the package's
    /// root, but the `geo` its consumer writes is a claim on the
    /// consumer's namespace.
    pub fn findBinding(self: *const Sources, namespace: []const u8, binding: []const u8) ?FileId {
        for (self.claims.items) |made| {
            if (!std.mem.eql(u8, made.namespace, namespace)) continue;
            if (std.mem.eql(u8, self.bindingOf(made.file), binding)) return made.file;
        }
        return null;
    }

    /// The binding this file was registered under; "" when unknown,
    /// which is also the root file's binding.
    pub fn bindingOf(self: *const Sources, file: FileId) []const u8 {
        const found = self.at(file) orelse return "";
        return found.binding;
    }

    /// The opaque root token this file was registered under; "" when
    /// unknown, which is also the rootless program's token.
    pub fn rootOf(self: *const Sources, file: FileId) []const u8 {
        const found = self.at(file) orelse return "";
        return found.root;
    }

    /// How a diagnostic should name this file; "" when unknown.
    pub fn pathOf(self: *const Sources, file: FileId) []const u8 {
        const found = self.at(file) orelse return "";
        return found.path;
    }

    /// The file's text; "" when unknown.
    pub fn textOf(self: *const Sources, file: FileId) []const u8 {
        const found = self.at(file) orelse return "";
        return found.text;
    }

    /// The text of `line` (counting from 1) without its terminator;
    /// "" when the file or the line is unknown.  A diagnostic carries
    /// this rather than a promise to re-read the file: the bytes here
    /// are the ones its span indexes, and the file on disk may have
    /// moved on since.
    pub fn lineText(self: *const Sources, file: FileId, line: usize) []const u8 {
        const found = self.at(file) orelse return "";
        if (line == 0 or line > found.line_starts.len) return "";
        const start = found.line_starts[line - 1];
        const end = if (line < found.line_starts.len)
            found.line_starts[line] - 1 // the '\n' that ended it
        else
            @as(u32, @intCast(found.text.len));
        return found.text[start..end];
    }

    /// Line and column of a byte offset in `file`, counting from 1.
    /// Binary search over the line index: the offset-to-origin call
    /// happens once per instruction in a debug build, so it may not
    /// be a scan.  An offset past the end reports the last line, and
    /// an unknown file reports 1:1.
    pub fn place(self: *const Sources, file: FileId, offset: usize) Place {
        const found = self.at(file) orelse return .{ .line = 1, .column = 1 };
        const starts = found.line_starts;
        const clamped: u32 = @intCast(@min(offset, found.text.len));
        var low: usize = 0;
        var high: usize = starts.len;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (starts[middle] <= clamped) low = middle else high = middle;
        }
        return .{ .line = low + 1, .column = clamped - starts[low] + 1 };
    }
};

/// Offsets of the first byte of every line.  A file ending in a
/// newline gets one more entry, for the empty line after it: that is
/// where the lexer's end-of-file span points, and where a diagnostic
/// about "the missing thing at the end" belongs.
fn indexLines(allocator: Allocator, text: []const u8) Error![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);
    for (text, 0..) |character, offset| {
        if (character == '\n') try starts.append(allocator, @intCast(offset + 1));
    }
    return starts.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn addText(sources: *Sources, kind: Kind, name: []const u8, path: []const u8, text: []const u8) !FileId {
    // add() takes ownership even on failure, so there is nothing to
    // clean up here.  The binding defaults to the name, which is what
    // an alias-free import produces.
    const owned = try testing.allocator.dupe(u8, text);
    return sources.add(kind, "", name, name, path, owned);
}

test "the registry owns what it holds and hands back identity" {
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();

    const root = try addText(&sources, .root, "", "editor.luc", "func main():\n    return\n");
    const geo = try addText(&sources, .imported, "geo", "geo.luc", "func area() -> long:\n    return 4\n");

    try testing.expectEqual(root_file, root);
    try testing.expectEqual(@as(FileId, 1), geo);
    try testing.expectEqual(@as(usize, 2), sources.count());
    try testing.expectEqualStrings("editor.luc", sources.pathOf(root));
    try testing.expectEqualStrings("geo.luc", sources.pathOf(geo));
    try testing.expectEqual(geo, sources.find("", "geo").?);
    try testing.expectEqual(root, sources.find("", "").?);
    try testing.expectEqual(@as(?FileId, null), sources.find("", "nope"));
    try testing.expect(sources.at(2) == null);
    try testing.expectEqualStrings("", sources.pathOf(7));
}

test "one name under two roots is two modules, found by the pair" {
    // The pair key is what keeps two roots' same-named modules apart
    // (docs/PACKAGES.md D7): `util` in the project and `util` inside a
    // package must never answer for each other.
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();

    const project_text = try testing.allocator.dupe(u8, "func here() -> long:\n    return 1\n");
    const ours = try sources.add(.imported, "", "util", "util", "util.luc", project_text);
    const package_text = try testing.allocator.dupe(u8, "func there() -> long:\n    return 2\n");
    const theirs = try sources.add(.imported, "pkg", "util", "util", "pkg/util.luc", package_text);

    try testing.expect(ours != theirs);
    try testing.expectEqual(ours, sources.find("", "util").?);
    try testing.expectEqual(theirs, sources.find("pkg", "util").?);
    try testing.expectEqual(@as(?FileId, null), sources.find("elsewhere", "util"));
    try testing.expectEqualStrings("", sources.rootOf(ours));
    try testing.expectEqualStrings("pkg", sources.rootOf(theirs));
    // An unknown file's root is the rootless token, like its path.
    try testing.expectEqualStrings("", sources.rootOf(9999));
}

test "a binding is its own key: an aliased module is found by either question" {
    // `import geo.shapes as gs`: identity answers dedup, the binding
    // answers collision, and the two are different columns.
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();

    const text = try testing.allocator.dupe(u8, "func area() -> long:\n    return 4\n");
    const shapes = try sources.add(.imported, "", "geo.shapes", "gs", "geo/shapes.luc", text);
    try sources.recordClaim("", "geo.shapes", shapes);

    try testing.expectEqual(shapes, sources.find("", "geo.shapes").?);
    try testing.expectEqual(shapes, sources.findBinding("", "gs").?);
    // Neither question answers the other's key.
    try testing.expectEqual(@as(?FileId, null), sources.find("", "gs"));
    try testing.expectEqual(@as(?FileId, null), sources.findBinding("", "geo.shapes"));
    // The binding is scoped to the claiming namespace like everything
    // else.
    try testing.expectEqual(@as(?FileId, null), sources.findBinding("pkg", "gs"));
    try testing.expectEqualStrings("gs", sources.bindingOf(shapes));
    // An unknown file's binding is the root file's, like its path.
    try testing.expectEqualStrings("", sources.bindingOf(9999));
}

test "a claim remembers a resolution; one file may be claimed from two namespaces" {
    // A package module is `geo.shapes` to its consumer and `shapes`
    // to a file inside the package.  Both claims answer the one file,
    // which is what keeps its declarations one set (docs/PACKAGES.md
    // D4); the file itself is found again by the path the host opened.
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();

    const text = try testing.allocator.dupe(u8, "func area() -> long:\n    return 4\n");
    const shapes = try sources.add(.imported, "geo-1.2.0", "geo.shapes", "shapes", ".luce/packages/geo-1.2.0/shapes.luc", text);
    try sources.recordClaim("", "geo.shapes", shapes);
    try sources.recordClaim("geo-1.2.0", "shapes", shapes);

    try testing.expectEqual(shapes, sources.claim("", "geo.shapes").?);
    try testing.expectEqual(shapes, sources.claim("geo-1.2.0", "shapes").?);
    try testing.expectEqual(@as(?FileId, null), sources.claim("", "shapes"));
    try testing.expectEqual(@as(?FileId, null), sources.claim("geo-1.2.0", "geo.shapes"));

    // The binding holds in both claiming namespaces.
    try testing.expectEqual(shapes, sources.findBinding("", "shapes").?);
    try testing.expectEqual(shapes, sources.findBinding("geo-1.2.0", "shapes").?);

    // The path is the file's identity within its root.
    try testing.expectEqual(shapes, sources.findByPath("geo-1.2.0", ".luce/packages/geo-1.2.0/shapes.luc").?);
    try testing.expectEqual(@as(?FileId, null), sources.findByPath("", ".luce/packages/geo-1.2.0/shapes.luc"));
    try testing.expectEqual(@as(?FileId, null), sources.findByPath("geo-1.2.0", ""));
}

test "place resolves an offset against the file it belongs to" {
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();

    const first = try addText(&sources, .root, "", "main.luc", "ab\ncd\n");
    const second = try addText(&sources, .imported, "geo", "geo.luc", "one\ntwo\nthree\n");

    try testing.expectEqual(Place{ .line = 1, .column = 1 }, sources.place(first, 0));
    try testing.expectEqual(Place{ .line = 1, .column = 3 }, sources.place(first, 2));
    try testing.expectEqual(Place{ .line = 2, .column = 1 }, sources.place(first, 3));

    // The same offset in a different file is a different place: this
    // is what a single shared buffer could never say.
    try testing.expectEqual(Place{ .line = 2, .column = 1 }, sources.place(second, 4));
    try testing.expectEqual(Place{ .line = 3, .column = 2 }, sources.place(second, 9));
}

test "place agrees with the reference scan on every offset" {
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();
    // Blank lines, a line without a newline at the end, and the two
    // texts that differ only in their terminator.
    for ([_][]const u8{
        "func main():\n\n    let a = 1\n    print(string(a))\nlast line, no newline",
        "func main():\n\n    return\n",
        "",
        "\n",
    }) |text| {
        const file = try addText(&sources, .root, "", "main.luc", text);
        for (0..text.len + 2) |offset| {
            try testing.expectEqual(
                positions.place(text, @min(offset, text.len)),
                sources.place(file, offset),
            );
        }
    }
}

test "lineText and place agree: the line of an offset contains that offset" {
    // What a rendered diagnostic rests on — the caret is placed by
    // `column` and drawn under `lineText`, so the two disagreeing puts
    // the caret under the wrong character or off the end.
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();
    for ([_][]const u8{
        "func main():\n\n    let a = 1\n    print(string(a))\nlast line, no newline",
        "one\r\ntwo\r\n", // registered as prepared text would never be, on purpose
        "\n\n\n",
        "no newline at all",
        "",
    }) |text| {
        const file = try addText(&sources, .root, "", "main.luc", text);
        for (0..text.len + 1) |offset| {
            const at = sources.place(file, offset);
            const line = sources.lineText(file, at.line);
            // The column indexes the line, and the byte it names is
            // the byte at the offset (except one past the end, where
            // there is nothing to name).
            try testing.expect(at.column - 1 <= line.len);
            if (offset < text.len and text[offset] != '\n') {
                try testing.expectEqual(text[offset], line[at.column - 1]);
            }
            // A line never carries its own terminator.
            try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
        }
        // Past the end there is no line, rather than a wrong one.
        try testing.expectEqualStrings("", sources.lineText(file, 0));
        try testing.expectEqualStrings("", sources.lineText(file, 9999));
    }
    try testing.expectEqualStrings("", sources.lineText(9999, 1));
}

test "an empty file is one line and an offset past the end clamps to it" {
    var sources = Sources.init(testing.allocator);
    defer sources.deinit();
    const empty = try addText(&sources, .root, "", "empty.luc", "");
    try testing.expectEqual(@as(usize, 1), sources.at(empty).?.line_starts.len);
    try testing.expectEqual(Place{ .line = 1, .column = 1 }, sources.place(empty, 0));
    try testing.expectEqual(Place{ .line = 1, .column = 1 }, sources.place(empty, 99));

    // The position after a final newline is where the lexer's
    // end-of-file span lands: the empty line that follows.
    const ended = try addText(&sources, .imported, "geo", "geo.luc", "a\n");
    try testing.expectEqual(Place{ .line = 2, .column = 1 }, sources.place(ended, 2));
}
