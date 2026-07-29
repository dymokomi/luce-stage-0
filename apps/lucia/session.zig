//! Terminal session state shared by every command.

const std = @import("std");
const loom = @import("loom");

const Allocator = std.mem.Allocator;
const Store = loom.store.Store;
const Spool = loom.spool.Spool;
const TexelId = loom.texel_id.TexelId;

// ---------------------------------------------------------------------------
// Watch
// ---------------------------------------------------------------------------
//
// One event-activated subscription: re-demand this endpoint after a
// change and print it when its rendered outcome moves from the last one
// shown.
//
pub const Watch = struct {
    texel: TexelId,
    output: []u8,
    last: []u8,

    pub fn deinit(self: *Watch, allocator: Allocator) void {
        allocator.free(self.output);
        allocator.free(self.last);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
//
// Terminal state shared by commands: the open store and spool (borrowed
// from the Terminal, which owns them), the writers commands print to,
// the watch list, and the selected texel.  The selection is unset until
// select (or new) picks a texel to work on.
//
pub const Session = struct {
    allocator: Allocator,
    io: std.Io,
    store: *Store,
    spool: *Spool,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    selected: TexelId = .unset,
    watches: std.ArrayList(Watch) = .empty,

    pub fn deinit(self: *Session) void {
        for (self.watches.items) |*watch| watch.deinit(self.allocator);
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasSelection(self: *const Session) bool {
        return !self.selected.isUnset();
    }

    pub fn findWatch(self: *const Session, texel: TexelId, output: []const u8) ?usize {
        for (self.watches.items, 0..) |watch, index| {
            if (watch.texel.eql(texel) and std.mem.eql(u8, watch.output, output)) {
                return index;
            }
        }
        return null;
    }
};
