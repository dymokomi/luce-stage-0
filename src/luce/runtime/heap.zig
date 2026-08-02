//! The object heap and its ownership machinery — the heart of
//! `libluce_rt`.
//!
//! Luce's heap objects (`List`, `Map`, `Array`, `Builder`) are freed by
//! scope ownership, ratified S1–S43 in docs/OWNERSHIP.md and proven by
//! `specs/ownership_spec.zig`.  Every rule those specs describe lives
//! in this file, once: the binding that received a fresh object owns
//! it, containers own what they adopt, `give`/`copy`/`free` move or end
//! ownership, and a use after free traps rather than reading freed
//! memory.
//!
//! `Runtime` is the whole of a running program's state that is not the
//! program: the two allocators a run draws on (`Memory`), the object
//! table handles index, the frame-serial counter, and the trap channel.
//! It is what a compiled artifact holds a pointer to for its whole run.

const std = @import("std");
const mir = @import("../06_mir.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;

/// What every fallible runtime operation can do.  `Trap` is a Luce
/// program error and its details are in `Runtime.pending`;
/// `OutOfMemory` is the arena giving up, which no Luce program can
/// cause deliberately and no Luce program can catch.
pub const Error = error{ OutOfMemory, Trap };

/// A Luce trap: a stable code (`mir.TrapCode`) and the words reported
/// with it.  The message is either static — `code.message()` — or
/// arena-owned, so it outlives the operation that raised it.
pub const Trap = struct {
    code: mir.TrapCode,
    message: []const u8,
};

pub const MapEntry = struct { key: Value, value: Value };

/// Where a run's memory comes from.  Luce has two kinds of data with
/// two different lifetimes, so it takes two allocators, and mixing them
/// up is what made freed objects unreclaimable for as long as there was
/// only one.
pub const Memory = struct {
    /// Run-lifetime storage: String bytes, struct field runs, the words
    /// of a trap.  A Luce value has no owner and no death point — `let
    /// b = a` copies it, containers copy it in, nothing ever frees one
    /// — so there is nothing to reclaim individually and this is an
    /// arena the caller drops whole once it has copied out whatever it
    /// publishes.
    arena: Allocator,

    /// Heap-object storage: the elements of every List, Map, and Array,
    /// a Builder's bytes, a Map's hash index, and the object table
    /// itself.  Objects *do* have a death point — `freeObject`, which
    /// scope ownership drives — so this allocator has to give memory
    /// back, which an arena cannot.  Pass an ordinary freeing
    /// allocator; under `std.testing.allocator` an object whose storage
    /// is not reclaimed is a reported leak.
    objects: Allocator,
};

/// Who frees an object (OWNERSHIP.md): `loose` — a fresh value or
/// statement temporary; `container` — an element some container
/// adopted and frees with itself; `binding` — a named local of one
/// specific call frame, released when that scope exits.
pub const OwnedBy = struct { serial: u64, local: u32 };

pub const Owner = union(enum) {
    loose,
    container,
    binding: OwnedBy,
};

pub const Object = struct {
    alive: bool = true,
    owner: Owner = .loose,
    data: Data,

    pub const Data = union(enum) {
        list: std.ArrayList(Value),
        map: Map,
        array: Array,
        builder: std.ArrayList(u8),

        /// Give the contents back and leave an empty thing of the same
        /// kind behind.
        ///
        /// The kind is kept on purpose.  Nothing reads a freed object's
        /// data — `alive` is false, so `resolve` traps `use_after_free`
        /// and the ownership walks skip it — but an empty List is a far
        /// better thing for a bug to find than a dangling pointer, and
        /// it costs a store.
        pub fn release(self: *Data, allocator: Allocator) void {
            switch (self.*) {
                .list => |*list| {
                    list.deinit(allocator);
                    self.* = .{ .list = .empty };
                },
                .map => |*map| {
                    map.deinit(allocator);
                    self.* = .{ .map = .empty };
                },
                .array => |shape| {
                    allocator.free(shape.dims);
                    allocator.free(shape.elements);
                    self.* = .{ .array = .{ .dims = &.{}, .elements = &.{} } };
                },
                .builder => |*builder| {
                    builder.deinit(allocator);
                    self.* = .{ .builder = .empty };
                },
            }
        }
    };

    pub const Array = struct { dims: []i64, elements: []Value };

    /// Give the object's storage back.  What does *not* happen here is
    /// the object leaving the table — the slot and its handle stay dead
    /// forever, which is what makes S9 a clean trap rather than
    /// undefined behaviour.  Only the storage is reclaimed, never the
    /// identity.
    pub fn release(self: *Object, allocator: Allocator) void {
        self.data.release(allocator);
    }
};

/// A Luce Map: entries in insertion order, plus a hash index into them.
///
/// Insertion order is part of the language — `key_at`, `value_at`, and
/// `for key in m` all read the entries by position — so the entries
/// stay a dense array in the order they arrived, exactly as they always
/// were.  What is new is `slots`: an open-addressed table of *positions
/// into that array*, so a lookup hashes and probes instead of scanning.
/// This is the Python 3.7 / Swift `OrderedDictionary` layout, and it is
/// why `m[k]`, `m.has(k)`, `m.get(k, d)` and `m[k] = v` are O(1) rather
/// than O(len).
///
/// `hashOf` and `value.keyEquals` must agree exactly: equal keys hash
/// equally, or a lookup walks past its own entry.  They are written
/// against the same two payloads (Int and String — the only key types
/// the analyzer admits) for that reason.
pub const Map = struct {
    entries: std.ArrayList(MapEntry) = .empty,
    /// Entry positions, `free_slot` where nothing lives.  Always a
    /// power of two long, or empty before the first insert.
    slots: []u32 = &.{},

    pub const empty: Map = .{};

    /// The slot value meaning "nothing here".  No entry can carry it:
    /// a map cannot hold `maxInt(u32)` entries.
    const free_slot: u32 = std.math.maxInt(u32);

    /// Slots stay at most three-quarters full; below that, linear
    /// probing stays short.
    fn wantedSlots(entries: usize) usize {
        var size: usize = 8;
        while (size * 3 < entries * 4) size *= 2;
        return size;
    }

    pub fn deinit(self: *Map, allocator: Allocator) void {
        self.entries.deinit(allocator);
        allocator.free(self.slots);
        self.* = .empty;
    }

    /// Where `key` sits in `entries`, or null when the map has no such
    /// key.  The probe stops at the first free slot: insertion never
    /// leaves a gap in a run, and removal reindexes.
    pub fn find(self: *const Map, key: Value) ?usize {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        var at = hashOf(key) & mask;
        while (true) : (at = (at + 1) & mask) {
            const position = self.slots[at];
            if (position == free_slot) return null;
            if (value.keyEquals(self.entries.items[position].key, key)) return position;
        }
    }

    /// Add an entry the map does not already hold — the caller has
    /// asked `find` first, which is how every door here works (a store
    /// has to know whether it is replacing an owned value).
    pub fn insert(self: *Map, allocator: Allocator, entry: MapEntry) Allocator.Error!void {
        const filled = self.entries.items.len + 1;
        if (filled * 4 > self.slots.len * 3) {
            const grown = try allocator.alloc(u32, wantedSlots(filled));
            allocator.free(self.slots);
            self.slots = grown;
            self.reindex();
        }
        const position: u32 = @intCast(self.entries.items.len);
        try self.entries.append(allocator, entry);
        self.place(position);
    }

    /// Drop the entry at `at`, keeping the order of the rest, and hand
    /// it back so the caller can free what it owned.
    pub fn removeAt(self: *Map, at: usize) MapEntry {
        const removed = self.entries.orderedRemove(at);
        // Every later entry just moved down one, so every stored
        // position after `at` is now wrong: rebuild rather than patch.
        // `remove` was O(len) before this change and stays O(len) —
        // shifting the entries costs that much on its own.
        self.reindex();
        return removed;
    }

    /// Drop every entry, keeping the storage for reuse.
    pub fn clear(self: *Map) void {
        self.entries.clearRetainingCapacity();
        @memset(self.slots, free_slot);
    }

    /// Rebuild the index from the entries: after a growth, and after a
    /// removal renumbers them.
    fn reindex(self: *Map) void {
        @memset(self.slots, free_slot);
        for (0..self.entries.items.len) |position| self.place(@intCast(position));
    }

    /// Record one entry's position in the first free slot at or after
    /// its hash.  The caller guarantees room, so the probe terminates.
    fn place(self: *Map, position: u32) void {
        const mask = self.slots.len - 1;
        var at = hashOf(self.entries.items[position].key) & mask;
        while (self.slots[at] != free_slot) at = (at + 1) & mask;
        self.slots[at] = position;
    }

    /// The hash `find` probes with.  Keys are Int or String — the
    /// analyzer admits nothing else — and this reads exactly the two
    /// payloads `value.keyEquals` compares, so equal keys always hash
    /// equally.  Ints go through a bit mixer rather than being used
    /// raw: sequential keys are the common case and linear probing
    /// wants their low bits spread.
    fn hashOf(key: Value) usize {
        return switch (key.view()) {
            .int => |held| @truncate(std.hash.int(@as(u64, @bitCast(held)))),
            .string => |held| @truncate(std.hash.Wyhash.hash(0, held)),
            else => unreachable, // the analyzer keys maps by Int or String
        };
    }
};

/// A safety valve, not a design limit: one array allocation cannot
/// exceed this many elements.
pub const max_array_elements = 1 << 24;

// ---------------------------------------------------------------------------
// The runtime instance
// ---------------------------------------------------------------------------

pub const Runtime = struct {
    /// Run-lifetime storage — `Memory.arena`.  String bytes, struct
    /// field runs, and the words of a trap come from here and live
    /// until the caller drops the arena.
    arena: Allocator,

    /// Heap-object storage — `Memory.objects`.  Container contents and
    /// the object table come from here, and `freeObject` gives them
    /// back.
    objects: Allocator,

    /// Every object the run allocated, alive or freed; handles index
    /// this table.  The `Object`s sit in it directly rather than behind
    /// pointers — a handle is one bounds check and one load, not two.
    ///
    /// Slots are never reused, so a freed handle stays detectably dead
    /// for the whole run: that is what makes a use-after-free a clean
    /// `use_after_free` trap (S9) instead of undefined behaviour, and
    /// it is the accepted alternative to a borrow checker.  Only the
    /// *storage* of a freed object comes back (`Object.release`); its
    /// identity never does.
    ///
    /// Because the objects are inline, `resolve` hands out a pointer
    /// into a slice that moves when the table grows.  Nothing may hold
    /// an `*Object` across a call that can allocate a new object —
    /// re-resolve, or work through a copy of the object's contents,
    /// whose buffers the table does not own.
    table: std.ArrayList(Object) = .empty,

    /// Objects allocated and not yet freed — the leak census the host
    /// reports when a program returns (`Success.leaked_objects`).
    /// Memory is explicit in Luce, so what a program did not free is
    /// part of what it did.
    live: u32 = 0,

    /// Unique per call: object ownership names (serial, local) pairs,
    /// so recursion never confuses two frames' bindings.  u64 — loom
    /// runs with an unlimited step budget, so 2^32 calls is an
    /// afternoon, and a wrapped serial would let ownership confuse
    /// two frames.
    next_serial: u64 = 1,

    /// The trap raised by the operation that most recently returned
    /// `error.Trap`.  This is the ceval-style pending-error pattern —
    /// no per-operation outcome plumbing.
    pending: ?Trap = null,

    /// Set when the arena gave up.  A C caller cannot see
    /// `error.OutOfMemory`, so the exports record it here and the
    /// entry wrapper turns it into a distinct status.
    exhausted: bool = false,

    /// What a compiled artifact's functions are called, and where
    /// their instructions came from (trace.zig).  Empty for the
    /// interpreter, which reads the program it is walking instead.
    functions: []const trace.FunctionInfo = &.{},

    /// The frames a trapped compiled program recorded on its way out,
    /// innermost first.  Only ever written after a trap, so the
    /// execution path never touches it.
    unwound: std.ArrayList(trace.Frame) = .empty,

    /// Frames the cap or a failed allocation cut from `unwound`; the
    /// host reports them as "... N more frames".
    dropped_frames: u32 = 0,

    /// The text payload of the most recent `key_read`, which `key_text`
    /// answers.  Per-run state rather than per-engine state: the
    /// interpreter and compiled code read and write this one field, so
    /// `key_text` cannot mean two different things (docs/CODEGEN.md).
    /// Static or arena-owned, like every other string the runtime hands
    /// out.
    last_key_text: []const u8 = "",

    pub fn init(memory: Memory) Runtime {
        return .{ .arena = memory.arena, .objects = memory.objects };
    }

    /// End the run: give back the object table and the contents of
    /// everything still alive in it.
    ///
    /// Scope ownership frees objects as their scopes end, but a run
    /// does not always end at the bottom of a scope — a trap unwinds
    /// past every release (S34), and a program that leaks is reported
    /// rather than corrected.  Whatever ownership did not free is
    /// released here, so a run's memory always comes back, and a leak
    /// stays a number in the census rather than becoming a leak of the
    /// host's memory too.
    ///
    /// Values (Strings, struct field runs) are not touched: they live
    /// in `arena`, which belongs to the caller.
    pub fn deinit(self: *Runtime) void {
        for (self.table.items) |*object| {
            if (object.alive) object.release(self.objects);
        }
        self.table.deinit(self.objects);
        self.unwound.deinit(self.objects);
        self.* = undefined;
    }

    /// A serial no other live frame carries.  One per call.
    pub fn takeSerial(self: *Runtime) u64 {
        const serial = self.next_serial;
        self.next_serial += 1;
        return serial;
    }

    // -- the trap channel ------------------------------------------------

    /// Record `code` with its standard message and unwind.
    pub fn fail(self: *Runtime, code: mir.TrapCode) Error {
        return self.failMessage(code, code.message());
    }

    /// Record `code` with words of the program's own (`trap("...")`).
    /// `message` must outlive the run: static text or arena storage.
    ///
    /// Nothing is announced here.  Both engines read the trap back out
    /// once the program has stopped — the interpreter from `pending`
    /// directly, a compiled artifact through `luce_rt_report` — because
    /// a trap's call trace does not exist until unwinding is over
    /// (trace.zig).
    pub fn failMessage(self: *Runtime, code: mir.TrapCode, message: []const u8) Error {
        self.pending = .{ .code = code, .message = message };
        return error.Trap;
    }

    // -- the unwind trace --------------------------------------------------

    /// Record one frame of a trapped compiled program's call stack:
    /// the function it was in and the instruction it was at.  Called
    /// once per frame as the trap unwinds, innermost first, so the
    /// order the frames arrive in is the order they are reported.
    ///
    /// Everything that can go wrong here — a table that does not
    /// describe this function, a trace already at its cap, an
    /// allocation that fails because the arena is what failed in the
    /// first place — costs a frame, never the report.
    pub fn recordFrame(self: *Runtime, function: u32, instruction: u32) void {
        if (function >= self.functions.len) return;
        if (self.unwound.items.len >= trace.max_frames) {
            self.dropped_frames +|= 1;
            return;
        }
        const info = self.functions[function];
        var line: u32 = 0;
        var column: u32 = 0;
        if (info.origins) |origins| {
            if (instruction < info.origin_count) {
                line = origins[instruction].line;
                column = origins[instruction].column;
            }
        }
        self.unwound.append(self.objects, .{
            .function = info.name,
            .function_length = info.name_length,
            .source = info.source,
            .source_length = info.source_length,
            .line = line,
            .column = column,
        }) catch {
            self.dropped_frames +|= 1;
        };
    }

    // -- allocation --------------------------------------------------------

    pub fn newList(self: *Runtime) Error!Value {
        return self.attach(.{ .list = .empty });
    }

    pub fn newMap(self: *Runtime) Error!Value {
        return self.attach(.{ .map = .empty });
    }

    pub fn newBuilder(self: *Runtime) Error!Value {
        return self.attach(.{ .builder = .empty });
    }

    /// A fresh array of `dims`, every element `zero`.  The element zero
    /// comes from the caller because it depends on the program's type
    /// table, which the runtime deliberately does not know.
    pub fn newArray(self: *Runtime, dims: []const i64, zero: Value) Error!Value {
        const shape = try self.objects.alloc(i64, dims.len);
        errdefer self.objects.free(shape);
        var total: usize = 1;
        for (dims, shape) |size, *dimension| {
            if (size < 0 or size > max_array_elements) return self.fail(.index_bounds);
            dimension.* = size;
            total = std.math.mul(usize, total, @intCast(size)) catch
                return self.fail(.index_bounds);
            if (total > max_array_elements) return self.fail(.index_bounds);
        }
        const elements = try self.objects.alloc(Value, total);
        errdefer self.objects.free(elements);
        @memset(elements, zero);
        return self.attach(.{ .array = .{ .dims = shape, .elements = elements } });
    }

    /// Adopt an already-built list as a new object — what the
    /// list-producing operations (`xs[a:b]`, `m.keys()`, `m.values()`)
    /// hand back once they have filled their elements in.
    pub fn attachList(self: *Runtime, elements: std.ArrayList(Value)) Error!Value {
        return self.attach(.{ .list = elements });
    }

    /// Put `data` in the object table and hand back a loose handle.
    /// On failure `data` is untouched and still the caller's to
    /// release — every caller here builds it under an `errdefer`.
    fn attach(self: *Runtime, data: Object.Data) Error!Value {
        const index: u32 = @intCast(self.table.items.len);
        try self.table.append(self.objects, .{ .data = data });
        self.live += 1;
        return Value.ofObject(index);
    }

    // -- struct storage ------------------------------------------------
    //
    // A struct value is a run of `Value`s in arena storage.  That run is
    // never written to after it is built — `setField` allocates a fresh
    // one — so two copies of a struct can share it, which is what makes
    // struct assignment an ordinary value copy (docs/LANGUAGE.md).

    /// A fresh struct value holding `fields`.
    pub fn makeStruct(self: *Runtime, fields: []const Value) Error!Value {
        const stored = try self.arena.alloc(Value, fields.len);
        @memcpy(stored, fields);
        return Value.ofStruct(stored);
    }

    /// `held` with field `index` replaced, as a fresh value.
    pub fn setField(self: *Runtime, held: Value, index: usize, to: Value) Error!Value {
        const source = held.asStruct();
        const stored = try self.arena.alloc(Value, source.len);
        @memcpy(stored, source);
        stored[index] = to;
        return Value.ofStruct(stored);
    }

    // -- resolution ---------------------------------------------------------

    /// Resolve a handle to its live object, or fail: null slots trap
    /// null_object, freed ones use_after_free.
    ///
    /// The pointer is into the object table and is only good until the
    /// next object is allocated (see `table`).
    pub fn resolve(self: *Runtime, held: Value) Error!*Object {
        const index = held.asObject();
        if (index == value.null_index) return self.fail(.null_object);
        if (index >= self.table.items.len) return self.fail(.use_after_free);
        const found = &self.table.items[index];
        if (!found.alive) return self.fail(.use_after_free);
        return found;
    }

    /// The live object behind a handle, or null when the handle is null,
    /// out of range, or already freed.  Ownership walks use this: they
    /// must never trap, because they run on paths that are already
    /// unwinding or already correct.
    fn liveObject(self: *Runtime, index: u32) ?*Object {
        if (index == value.null_index or index >= self.table.items.len) return null;
        const object = &self.table.items[index];
        if (!object.alive) return null;
        return object;
    }

    // -- ownership walks ------------------------------------------------
    //
    // Bind/adopt/release walk a value's top objects: the object a
    // handle names, or a struct's object fields recursively.  They
    // never descend into an object's elements — those already belong
    // to it.  Nesting depth is bounded by the (finite) type shape.

    /// The objects in `held` now belong to `local` of frame `serial`.
    pub fn bind(self: *Runtime, held: Value, serial: u64, local: u32) void {
        switch (held.view()) {
            .object => |index| {
                const object = self.liveObject(index) orelse return;
                object.owner = .{ .binding = .{ .serial = serial, .local = local } };
            },
            .strukt => |fields| for (fields) |field| self.bind(field, serial, local),
            else => {},
        }
    }

    /// The objects in `held` were adopted by a container (S20).
    pub fn adopt(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |index| {
                const object = self.liveObject(index) orelse return;
                object.owner = .container;
            },
            .strukt => |fields| for (fields) |field| self.adopt(field),
            else => {},
        }
    }

    /// The objects in `held` belong to nobody yet: pop results and
    /// returned values (the receiver adopts or binds them next).
    pub fn loosen(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |index| {
                const object = self.liveObject(index) orelse return;
                object.owner = .loose;
            },
            .strukt => |fields| for (fields) |field| self.loosen(field),
            else => {},
        }
    }

    /// On return, everything the finished frame still owned in the
    /// returned value moves out loose; the caller owns it (S16).
    pub fn loosenFromFrame(self: *Runtime, held: Value, serial: u64) void {
        switch (held.view()) {
            .object => |index| {
                const object = self.liveObject(index) orelse return;
                if (object.owner == .binding and object.owner.binding.serial == serial) {
                    object.owner = .loose;
                }
            },
            .strukt => |fields| for (fields) |field| self.loosenFromFrame(field, serial),
            else => {},
        }
    }

    /// Free the objects in `held` still bound to (serial, local); the
    /// scope-exit release.  Objects owned elsewhere by now are left
    /// alone, which makes releases safe on every path.
    pub fn unbind(self: *Runtime, held: Value, serial: u64, local: u32) void {
        switch (held.view()) {
            .object => |index| {
                const object = self.liveObject(index) orelse return;
                if (object.owner == .binding and
                    object.owner.binding.serial == serial and
                    object.owner.binding.local == local)
                {
                    self.freeObject(index);
                }
            },
            .strukt => |fields| for (fields) |field| self.unbind(field, serial, local),
            else => {},
        }
    }

    /// Free one object and everything it owns, recursively (S20), and
    /// give its storage back.
    ///
    /// The two halves are in that order on purpose: the elements have
    /// to be walked while they are still there, and only then can the
    /// buffer holding them go.  Neither half allocates, so the pointer
    /// into the table stays good across both.
    pub fn freeObject(self: *Runtime, index: u32) void {
        const object = &self.table.items[index];
        if (!object.alive) return;
        object.alive = false;
        self.live -= 1;
        switch (object.data) {
            .list => |list| for (list.items) |item| self.freeValue(item),
            .map => |map| for (map.entries.items) |entry| self.freeValue(entry.value),
            .array => |array| for (array.elements) |item| self.freeValue(item),
            .builder => {},
        }
        object.release(self.objects);
    }

    /// Free the objects in a value unconditionally (owned elements
    /// being dropped by their container: overwrite, remove, clear).
    pub fn freeValue(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |index| {
                if (self.liveObject(index) != null) self.freeObject(index);
            },
            .strukt => |fields| for (fields) |field| self.freeValue(field),
            else => {},
        }
    }

    /// give/free verification (S23): never an object a container
    /// owns, and — when the verb names an owned binding — only an
    /// object that binding still owns (an alias may have moved it).
    /// Struct values check every filled field; unfilled fields are
    /// simply carried along.
    pub fn checkGivable(self: *Runtime, held: Value, expected: ?OwnedBy) Error!void {
        switch (held.view()) {
            .object => |index| {
                if (index == value.null_index) return;
                if (index >= self.table.items.len) return self.fail(.use_after_free);
                const found = &self.table.items[index];
                if (!found.alive) return self.fail(.use_after_free);
                if (found.owner == .container) return self.fail(.not_owned);
                if (expected) |owner| {
                    if (!(found.owner == .binding and
                        found.owner.binding.serial == owner.serial and
                        found.owner.binding.local == owner.local))
                    {
                        return self.fail(.not_owned);
                    }
                }
            },
            .strukt => |fields| for (fields) |field| try self.checkGivable(field, expected),
            else => {},
        }
    }

    /// Deep copy (S31): duplicate the object and everything it owns,
    /// recursively.  Values pass through; unfilled slots stay unfilled
    /// (only the copy verb itself demands a filled top-level object).
    pub fn deepCopy(self: *Runtime, held: Value) Error!Value {
        switch (held.view()) {
            .object => |index| {
                if (index == value.null_index) return held;
                if (index >= self.table.items.len) return self.fail(.use_after_free);
                if (!self.table.items[index].alive) return self.fail(.use_after_free);
                // Each arm copies the source object's contents out
                // before recursing: `deepCopy` allocates objects, which
                // moves the table, and the source's own buffers do not
                // move with it.
                var storage: Object.Data = switch (self.table.items[index].data) {
                    .list => |list| blk: {
                        var copied: std.ArrayList(Value) = .empty;
                        errdefer copied.deinit(self.objects);
                        try copied.ensureTotalCapacity(self.objects, list.items.len);
                        for (list.items) |item| {
                            copied.appendAssumeCapacity(try self.deepCopy(item));
                        }
                        break :blk .{ .list = copied };
                    },
                    .map => |map| blk: {
                        var copied: Map = .empty;
                        errdefer copied.deinit(self.objects);
                        for (map.entries.items) |entry| {
                            try copied.insert(self.objects, .{
                                .key = entry.key,
                                .value = try self.deepCopy(entry.value),
                            });
                        }
                        break :blk .{ .map = copied };
                    },
                    .array => |array| blk: {
                        const dims = try self.objects.dupe(i64, array.dims);
                        errdefer self.objects.free(dims);
                        const elements = try self.objects.alloc(Value, array.elements.len);
                        errdefer self.objects.free(elements);
                        for (array.elements, elements) |item, *slot| {
                            slot.* = try self.deepCopy(item);
                        }
                        break :blk .{ .array = .{ .dims = dims, .elements = elements } };
                    },
                    .builder => |builder| blk: {
                        var copied: std.ArrayList(u8) = .empty;
                        errdefer copied.deinit(self.objects);
                        try copied.appendSlice(self.objects, builder.items);
                        break :blk .{ .builder = copied };
                    },
                };
                errdefer storage.release(self.objects);
                const duplicate = try self.attach(storage);
                // The copy's own elements belong to it.
                switch (self.table.items[duplicate.asObject()].data) {
                    .list => |list| for (list.items) |item| self.adopt(item),
                    .map => |map| for (map.entries.items) |entry| self.adopt(entry.value),
                    .array => |array| for (array.elements) |item| self.adopt(item),
                    .builder => {},
                }
                return duplicate;
            },
            .strukt => |fields| {
                const copied = try self.arena.alloc(Value, fields.len);
                for (fields, copied) |field, *slot| {
                    slot.* = try self.deepCopy(field);
                }
                return Value.ofStruct(copied);
            },
            else => return held,
        }
    }
};

/// Flatten a multi-dimensional index against the array's dims;
/// null when any index is out of range.
pub fn flattenIndex(dims: []const i64, indices: []const Value) ?usize {
    var flat: usize = 0;
    for (dims, indices) |size, held| {
        const index = held.asInt();
        if (index < 0 or index >= size) return null;
        flat = flat * @as(usize, @intCast(size)) + @as(usize, @intCast(index));
    }
    return flat;
}
