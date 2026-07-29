//! File projection — a controlled boundary between selected Fabric
//! outputs and one host directory.
//!
//! The projection has no Fabric identity and owns no Store.  Export
//! writes each manifest entry to its relative filename under the root;
//! import reads the same files back and commits genuine content changes
//! as one transaction.  The tree is verified before either direction
//! moves bytes: unexpected files, symlinks, extra hard links, and
//! anything else that is not exactly the manifest shape refuse the
//! whole operation.  Digests decide "changed"; revisions captured at
//! export time guard against clobbering Fabric-side edits.

const std = @import("std");
const store_mod = @import("../fabric/store.zig");
const texel_mod = @import("../fabric/texel.zig");
const value_mod = @import("../fabric/value.zig");
const manifest_mod = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Transaction = store_mod.Transaction;
const Texel = texel_mod.Texel;
const Value = value_mod.Value;
const Manifest = manifest_mod.Manifest;
const Entry = manifest_mod.Entry;

pub const Error = error{
    OutOfMemory,
    NotExported,
    EmptyManifest,
    MissingOutput,
    UnexpectedFile,
    StaleRevision,
    HostFailed,
    StoreFailed,
};

pub const digest_size = 64;

/// Lowercase hex SHA-256 of the projected bytes; the change detector
/// for import and the projection's content witness.
pub fn contentDigest(bytes: []const u8) [digest_size]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

// ---------------------------------------------------------------------------
// Record
// ---------------------------------------------------------------------------
//
// In-memory state captured when one output was last synchronized.
// Records parallel the projection's manifest entries by index.
//
pub const Record = struct {
    revision: u64,
    digest: [digest_size]u8,
};

// ---------------------------------------------------------------------------
// FileProjection
// ---------------------------------------------------------------------------

pub const FileProjection = struct {
    allocator: Allocator,
    io: std.Io,
    base: std.Io.Dir,
    manifest: Manifest = .{},
    records: std.ArrayList(Record) = .empty,
    root: ?[]u8 = null,

    pub fn init(allocator: Allocator, io: std.Io, base: std.Io.Dir) FileProjection {
        return .{ .allocator = allocator, .io = io, .base = base };
    }

    pub fn deinit(self: *FileProjection) void {
        self.manifest.deinit(self.allocator);
        self.records.deinit(self.allocator);
        if (self.root) |root| self.allocator.free(root);
        self.* = undefined;
    }

    pub fn isExported(self: *const FileProjection) bool {
        return self.root != null;
    }

    pub fn count(self: *const FileProjection) usize {
        return self.records.items.len;
    }

    pub fn at(self: *const FileProjection, index: usize) ?Record {
        if (index >= self.records.items.len) return null;
        return self.records.items[index];
    }

    /// Write every manifest entry into the directory (relative to the
    /// projection's base) and capture revisions and digests.  The
    /// directory must exist and contain nothing outside the manifest.
    pub fn exportFrom(
        self: *FileProjection,
        store: *const Store,
        source_manifest: *const Manifest,
        directory: []const u8,
    ) Error!void {
        if (source_manifest.count() == 0) return error.EmptyManifest;
        if (directory.len == 0) return error.HostFailed;

        var root = self.openRoot(directory) catch return error.HostFailed;
        defer root.close(self.io);
        try self.checkTree(root, "", source_manifest);

        var captured: std.ArrayList(Record) = .empty;
        errdefer captured.deinit(self.allocator);
        for (source_manifest.entries.items) |*entry| {
            const bytes = try self.entryBytes(store, entry);
            defer self.allocator.free(bytes.content);
            try self.writeFile(root, entry.filename, bytes.content);
            try captured.append(self.allocator, .{
                .revision = bytes.revision,
                .digest = contentDigest(bytes.content),
            });
        }

        var owned_manifest = try source_manifest.clone(self.allocator);
        errdefer owned_manifest.deinit(self.allocator);
        const owned_root = try self.allocator.dupe(u8, directory);

        self.manifest.deinit(self.allocator);
        self.manifest = owned_manifest;
        self.records.deinit(self.allocator);
        self.records = captured;
        if (self.root) |old| self.allocator.free(old);
        self.root = owned_root;
    }

    /// Read every projected file back and commit genuine content
    /// changes into the Store as one transaction.  Refused when the
    /// tree deviates from the manifest or when a projected output moved
    /// in the Fabric since it was captured.
    pub fn importChanges(self: *FileProjection, store: *Store) Error!void {
        const directory = self.root orelse return error.NotExported;

        var root = self.openRoot(directory) catch return error.HostFailed;
        defer root.close(self.io);
        try self.checkTree(root, "", &self.manifest);

        const Change = struct {
            index: usize,
            content: []u8,
            digest: [digest_size]u8,
        };
        var changes: std.ArrayList(Change) = .empty;
        defer {
            for (changes.items) |change| self.allocator.free(change.content);
            changes.deinit(self.allocator);
        }

        for (self.records.items, 0..) |record, index| {
            const entry = &self.manifest.entries.items[index];
            try currentRevision(store, entry, record);
            const content = try self.readFile(root, entry.filename);
            const digest = contentDigest(content);
            if (std.mem.eql(u8, &digest, &record.digest)) {
                self.allocator.free(content);
                continue;
            }
            errdefer self.allocator.free(content);
            try changes.append(self.allocator, .{
                .index = index,
                .content = content,
                .digest = digest,
            });
        }
        if (changes.items.len == 0) return;

        var transaction = store.begin() catch return error.StoreFailed;
        defer transaction.deinit();
        for (changes.items) |change| {
            const entry = &self.manifest.entries.items[change.index];
            try self.putChange(&transaction, entry, self.records.items[change.index], change.content);
        }
        transaction.commit() catch return error.StoreFailed;

        for (changes.items) |change| {
            const entry = &self.manifest.entries.items[change.index];
            const texel = store.get(entry.texel) orelse return error.MissingOutput;
            const output = texel.getOutput(entry.output) orelse return error.MissingOutput;
            self.records.items[change.index] = .{
                .revision = output.revision,
                .digest = change.digest,
            };
        }
    }

    // Fabric side --------------------------------------------------------

    const Captured = struct {
        content: []u8,
        revision: u64,
    };

    fn entryBytes(self: *FileProjection, store: *const Store, entry: *const Entry) Error!Captured {
        const texel = store.get(entry.texel) orelse return error.MissingOutput;
        const output = texel.getOutput(entry.output) orelse return error.MissingOutput;
        if (output.declared != entry.declared) return error.MissingOutput;
        const source = output.source orelse return error.MissingOutput;
        if (source.tag() != entry.declared) return error.MissingOutput;

        const content = switch (entry.declared) {
            .text => try self.allocator.dupe(u8, source.text),
            .blob => blk: {
                const loaded = store.getBlob(source.blob) orelse return error.MissingOutput;
                break :blk try self.allocator.dupe(u8, loaded);
            },
            else => return error.MissingOutput,
        };
        return .{ .content = content, .revision = output.revision };
    }

    /// The projected output must still sit at the captured revision;
    /// otherwise the Fabric moved and the projection is stale.
    fn currentRevision(store: *const Store, entry: *const Entry, record: Record) Error!void {
        const texel = store.get(entry.texel) orelse return error.MissingOutput;
        const output = texel.getOutput(entry.output) orelse return error.MissingOutput;
        if (output.declared != entry.declared) return error.MissingOutput;
        if (output.source == null) return error.MissingOutput;
        if (output.revision != record.revision) return error.StaleRevision;
    }

    fn putChange(
        self: *FileProjection,
        transaction: *Transaction,
        entry: *const Entry,
        record: Record,
        content: []const u8,
    ) Error!void {
        const current = transaction.get(entry.texel) orelse return error.MissingOutput;
        var changed = current.clone(self.allocator) catch return error.OutOfMemory;
        defer changed.deinit(self.allocator);
        const output = changed.mutableOutput(entry.output) orelse return error.MissingOutput;
        if (output.declared != entry.declared) return error.MissingOutput;
        if (output.revision != record.revision) return error.StaleRevision;

        const value: Value = switch (entry.declared) {
            .text => Value.initText(self.allocator, content) catch return error.OutOfMemory,
            .blob => .{ .blob = transaction.putBlob(content) catch return error.StoreFailed },
            else => return error.MissingOutput,
        };
        output.setSource(self.allocator, value) catch return error.StoreFailed;
        transaction.put(&changed) catch return error.StoreFailed;
    }

    // Host side ----------------------------------------------------------

    fn openRoot(self: *FileProjection, directory: []const u8) !std.Io.Dir {
        return self.base.openDir(self.io, directory, .{
            .iterate = true,
            .follow_symlinks = false,
        });
    }

    /// The projection root may contain exactly the manifest shape:
    /// single-linked regular files the manifest projects and
    /// directories on the way to them.  Anything else refuses the
    /// operation before any byte moves.
    fn checkTree(
        self: *FileProjection,
        directory: std.Io.Dir,
        prefix: []const u8,
        manifest: *const Manifest,
    ) Error!void {
        var entries = directory.iterate();
        while (entries.next(self.io) catch return error.HostFailed) |item| {
            const path = if (prefix.len == 0)
                try self.allocator.dupe(u8, item.name)
            else
                try std.mem.join(self.allocator, "/", &.{ prefix, item.name });
            defer self.allocator.free(path);

            const status = directory.statFile(self.io, item.name, .{
                .follow_symlinks = false,
            }) catch return error.HostFailed;
            switch (status.kind) {
                .file => {
                    if (status.nlink != 1) return error.UnexpectedFile;
                    if (!manifest.hasFile(path)) return error.UnexpectedFile;
                },
                .directory => {
                    if (!manifest.hasDirectory(path)) return error.UnexpectedFile;
                    var child = directory.openDir(self.io, item.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch return error.HostFailed;
                    defer child.close(self.io);
                    try self.checkTree(child, path, manifest);
                },
                else => return error.UnexpectedFile,
            }
        }
    }

    const Parent = struct {
        directory: std.Io.Dir,
        owned: bool,
        leaf: []const u8,

        fn close(self: Parent, io: std.Io) void {
            if (self.owned) self.directory.close(io);
        }
    };

    /// Walk the filename's directory components under the root, never
    /// following symlinks, creating missing directories only on the
    /// write path.
    fn openParent(self: *FileProjection, root: std.Io.Dir, filename: []const u8, create: bool) Error!Parent {
        var directory = root;
        var owned = false;
        errdefer if (owned) directory.close(self.io);

        var rest = filename;
        while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const part = rest[0..slash];
            rest = rest[slash + 1 ..];
            const child = directory.openDir(self.io, part, .{
                .follow_symlinks = false,
            }) catch |mistake| child: {
                if (!create or mistake != error.FileNotFound) return error.HostFailed;
                directory.createDir(self.io, part, .default_dir) catch |made| {
                    if (made != error.PathAlreadyExists) return error.HostFailed;
                };
                break :child directory.openDir(self.io, part, .{
                    .follow_symlinks = false,
                }) catch return error.HostFailed;
            };
            if (owned) directory.close(self.io);
            directory = child;
            owned = true;
        }
        if (rest.len == 0) return error.HostFailed;
        return .{ .directory = directory, .owned = owned, .leaf = rest };
    }

    fn readFile(self: *FileProjection, root: std.Io.Dir, filename: []const u8) Error![]u8 {
        const parent = try self.openParent(root, filename, false);
        defer parent.close(self.io);

        const file = parent.directory.openFile(self.io, parent.leaf, .{
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch return error.HostFailed;
        defer file.close(self.io);

        const status = file.stat(self.io) catch return error.HostFailed;
        if (status.kind != .file or status.nlink != 1) return error.UnexpectedFile;
        if (status.size > std.math.maxInt(usize)) return error.HostFailed;

        const content = try self.allocator.alloc(u8, @intCast(status.size));
        errdefer self.allocator.free(content);
        const loaded = file.readPositionalAll(self.io, content, 0) catch return error.HostFailed;
        if (loaded != content.len) return error.HostFailed;
        return content;
    }

    fn writeFile(self: *FileProjection, root: std.Io.Dir, filename: []const u8, content: []const u8) Error!void {
        const parent = try self.openParent(root, filename, true);
        defer parent.close(self.io);

        const file = parent.directory.openFile(self.io, parent.leaf, .{
            .mode = .write_only,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch |mistake| file: {
            if (mistake != error.FileNotFound) return error.HostFailed;
            break :file parent.directory.createFile(self.io, parent.leaf, .{
                .exclusive = true,
            }) catch return error.HostFailed;
        };
        defer file.close(self.io);

        const status = file.stat(self.io) catch return error.HostFailed;
        if (status.kind != .file or status.nlink != 1) return error.UnexpectedFile;
        file.setLength(self.io, 0) catch return error.HostFailed;
        file.writePositionalAll(self.io, content, 0) catch return error.HostFailed;
        file.sync(self.io) catch return error.HostFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const volume_mod = @import("../storage/volume.zig");
const texel_id = @import("../fabric/texel_id.zig");
const TexelId = texel_id.TexelId;
const OutputPort = texel_mod.OutputPort;

fn patternedBlob(allocator: Allocator, edited: bool) ![]u8 {
    const content = try allocator.alloc(u8, volume_mod.page_size * 3 + 37);
    for (content, 0..) |*byte, index| byte.* = @truncate(index * 17 + 3);
    if (edited) {
        var index: usize = volume_mod.page_size - 5;
        while (index < content.len) : (index += volume_mod.page_size) {
            content[index] ^= 0x5a;
        }
    }
    return content;
}

fn expectOutputText(store: *const Store, id: TexelId, output: []const u8, expected: []const u8) !void {
    const texel = store.get(id) orelse return error.TestUnexpectedResult;
    const port = texel.getOutput(output) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expected, port.source.?.text);
}

fn expectOutputBlob(store: *const Store, id: TexelId, output: []const u8, expected: []const u8) !void {
    const texel = store.get(id) orelse return error.TestUnexpectedResult;
    const port = texel.getOutput(output) orelse return error.TestUnexpectedResult;
    const loaded = store.getBlob(port.source.?.blob) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, expected, loaded);
}

test "export, host edits, guarded import, and reopen" {
    const allocator = testing.allocator;
    const io = testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "files", .default_dir);

    const text_id = TexelId.generate(io);
    const blob_id = TexelId.generate(io);
    const original_blob = try patternedBlob(allocator, false);
    defer allocator.free(original_blob);
    const edited_blob = try patternedBlob(allocator, true);
    defer allocator.free(edited_blob);

    {
        var file = try volume_mod.FileVolume.create(io, scratch.dir, "store.img", 256);
        defer file.close();
        var store = try Store.create(allocator, file.volume());
        defer store.deinit();

        {
            var transaction = try store.begin();
            defer transaction.deinit();

            var text = Texel.init(text_id);
            defer text.deinit(allocator);
            var text_output = try OutputPort.init(allocator, "text", .text);
            try text_output.setSource(allocator, try Value.initText(allocator, "original text\n"));
            try text.putOutput(allocator, text_output);
            try transaction.put(&text);

            const reference = try transaction.putBlob(original_blob);
            var blob = Texel.init(blob_id);
            defer blob.deinit(allocator);
            var blob_output = try OutputPort.init(allocator, "blob", .blob);
            try blob_output.setSource(allocator, .{ .blob = reference });
            try blob.putOutput(allocator, blob_output);
            try transaction.put(&blob);
            try transaction.commit();
        }

        var manifest: Manifest = .{};
        defer manifest.deinit(allocator);
        try manifest.put(allocator, text_id, "text", .text, "notes/message.txt");
        try manifest.put(allocator, blob_id, "blob", .blob, "assets/data.bin");

        var projection = FileProjection.init(allocator, io, scratch.dir);
        defer projection.deinit();
        try projection.exportFrom(&store, &manifest, "files");
        try testing.expect(projection.isExported());
        try testing.expectEqual(@as(usize, 2), projection.count());

        // The captured digest is plain SHA-256 of the projected bytes.
        const record = projection.at(0).?;
        try testing.expect(record.revision != 0);
        try testing.expectEqualStrings(
            "84bd16f91ec8f223cad47630cf98cc04521ba112acb13942d20865060c28f3d3",
            &record.digest,
        );

        // An outside tool edits both projected files.
        var files = try scratch.dir.openDir(io, "files", .{});
        defer files.close(io);
        {
            const edited = try files.createFile(io, "notes/message.txt", .{});
            defer edited.close(io);
            try edited.writePositionalAll(io, "edited text\n", 0);
        }
        {
            const edited = try files.createFile(io, "assets/data.bin", .{});
            defer edited.close(io);
            try edited.writePositionalAll(io, edited_blob, 0);
        }

        // A file outside the manifest refuses the import.
        {
            const extra = try files.createFile(io, "extra.txt", .{});
            extra.close(io);
        }
        try testing.expectError(error.UnexpectedFile, projection.importChanges(&store));
        try files.deleteFile(io, "extra.txt");

        // A symlink in place of a projected file refuses the import.
        try files.rename("notes/message.txt", files, "notes/message.txt.saved", io);
        try files.symLink(io, "/etc/passwd", "notes/message.txt", .{});
        try testing.expectError(error.UnexpectedFile, projection.importChanges(&store));
        try files.deleteFile(io, "notes/message.txt");
        try files.rename("notes/message.txt.saved", files, "notes/message.txt", io);

        try projection.importChanges(&store);
        try testing.expectEqual(@as(usize, 2), store.count());
        try expectOutputText(&store, text_id, "text", "edited text\n");
        try expectOutputBlob(&store, blob_id, "blob", edited_blob);

        // A second import with no further edits is a no-op.
        try projection.importChanges(&store);
    }

    // The imported content is durable across reopen.
    {
        var file = try volume_mod.FileVolume.open(io, scratch.dir, "store.img");
        defer file.close();
        var reopened = try Store.open(allocator, file.volume());
        defer reopened.deinit();
        try testing.expectEqual(@as(usize, 2), reopened.count());
        try expectOutputText(&reopened, text_id, "text", "edited text\n");
        try expectOutputBlob(&reopened, blob_id, "blob", edited_blob);
    }
}

test "export requires content and a clean tree" {
    const allocator = testing.allocator;
    const io = testing.io;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try scratch.dir.createDir(io, "files", .default_dir);

    var memory = try volume_mod.MemoryVolume.init(allocator, 32);
    defer memory.deinit();
    var store = try Store.create(allocator, memory.volume());
    defer store.deinit();

    var projection = FileProjection.init(allocator, io, scratch.dir);
    defer projection.deinit();

    var empty: Manifest = .{};
    defer empty.deinit(allocator);
    try testing.expectError(error.EmptyManifest, projection.exportFrom(&store, &empty, "files"));
    try testing.expectError(error.NotExported, projection.importChanges(&store));

    // The manifest names an output the store does not carry.
    var missing: Manifest = .{};
    defer missing.deinit(allocator);
    try missing.put(allocator, TexelId.generate(io), "text", .text, "ghost.txt");
    try testing.expectError(error.MissingOutput, projection.exportFrom(&store, &missing, "files"));
}
