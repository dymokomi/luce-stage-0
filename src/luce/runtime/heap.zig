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
const vocabulary = @import("../support/vocabulary.zig");
const files = @import("files.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const workers = @import("workers.zig");

const Allocator = std.mem.Allocator;
const Handle = value.Handle;
const Value = value.Value;

// ---------------------------------------------------------------------------
// How a run stops: a trap, or an error a program can catch
// ---------------------------------------------------------------------------

/// What every fallible runtime operation can do.  `Trap` is a Luce
/// program error and its details are in `Runtime.pending`;
/// `OutOfMemory` is the arena giving up, which no Luce program can
/// cause deliberately and no Luce program can catch.
pub const Error = error{ OutOfMemory, Trap };

/// A Luce trap: a stable code (`vocabulary.TrapCode`) and the words reported
/// with it.  The message is arena-owned — `failMessage` copies whatever
/// it is handed — so it outlives the frame that raised it as well as
/// every release the unwind skips.
pub const Trap = struct {
    code: vocabulary.TrapCode,
    message: []const u8,
};

/// A Luce error: a stable code from a closed set of two, the words it
/// carries, and where it was raised (docs/FAILURE.md).
///
/// **One frame, not a trace.**  An error return trace would cost an
/// extra hidden parameter, stack in the first fallible frame, and a
/// save/restore protocol on the *success* path, because a caught error
/// has to pop what it collected — a cost on code that never fails,
/// which docs/MODES.md forbids.  So the raise site is recorded once,
/// at the raise, and nothing else is.  Traps keep their full trace.
///
/// The message is arena-owned and outlives every release the unwind
/// skips, exactly as a trap's words do; `origin` borrows names from
/// the program or the artifact's constant data.
pub const Raised = struct {
    code: vocabulary.ErrorCode,
    message: []const u8,
    origin: trace.Frame,
};

pub const MapEntry = struct { key: Value, value: Value };

/// Where a run's memory comes from.  Luce has two kinds of data with
/// two different lifetimes, so it takes two allocators, and mixing them
/// up is what made freed objects unreclaimable for as long as there was
/// only one.
// ---------------------------------------------------------------------------
// Where a run's memory comes from
// ---------------------------------------------------------------------------

pub const Memory = struct {
    /// Run-lifetime storage, and nothing a program can grow without
    /// bound: the words of a trap, the interpreter's per-layout struct
    /// zero templates, and the text a host service hands back before it
    /// is copied into owned storage.  The caller drops it whole once it
    /// has read whatever it publishes.
    ///
    /// **String bytes and struct field runs no longer live here**
    /// (docs/STRINGS.md).  They have an owner and a death point now, so
    /// they come from `objects` like everything else that is freed.
    arena: Allocator,

    /// Everything with a death point: the elements of every List, Map,
    /// and Array, a Builder's bytes, a Map's hash index, the object
    /// table — and, since copy-on-store, every String's bytes and every
    /// struct value's field run.  Scope ownership frees them while the
    /// program runs, so this allocator has to give memory back, which
    /// an arena cannot.  Pass an ordinary freeing allocator; under
    /// `std.testing.allocator` anything not reclaimed is a reported
    /// leak, which is what proves the ownership rules.
    objects: Allocator,
};

/// Who frees an object (OWNERSHIP.md): `loose` — a fresh value or
/// statement temporary; `container` — an element some container
/// adopted and frees with itself; `binding` — a named local of one
/// specific call frame, released when that scope exits; `program` — a
/// constant container held until the runtime ends (CONSTANTS.md R-C).
// ---------------------------------------------------------------------------
// Objects, and who owns one
// ---------------------------------------------------------------------------

pub const OwnedBy = struct { serial: u64, local: u32 };

/// An explicitly laid-out ownership discriminator and its binding
/// payload.  Generated code checks `kind` before an inline mutation,
/// so it is a plain measured field rather than a tagged-union detail.
pub const Owner = struct {
    /// The owner class generated code may inspect through `layout`.
    kind: Kind = .loose,
    /// Meaningful only for `.binding`; zeroed for the other kinds.
    binding: OwnedBy = .{ .serial = 0, .local = 0 },

    pub const Kind = enum(u32) {
        loose,
        container,
        binding,
        program,
    };

    pub const loose: Owner = .{};
    pub const container: Owner = .{ .kind = .container };
    pub const program: Owner = .{ .kind = .program };

    /// The owner naming one local in one live call frame.
    pub fn bound(binding: OwnedBy) Owner {
        return .{ .kind = .binding, .binding = binding };
    }
};

/// The generation a row is retired at: reached, it is never handed
/// out again.
///
/// **Generations do not wrap.**  slotmap accepts wraparound after 2³¹
/// reuses and EnTT's 12-bit version wraps routinely; here a stale
/// handle catching up with a live one is a use-after-free that stops
/// trapping, and S9 is a safety guarantee rather than an ECS
/// convenience.  So the last generation a row can hold is
/// `retired - 1`, the free that ends it puts the row *out* of the free
/// list instead of back on it, and no handle ever carries `retired`.
/// The cost is at most one leaked row per four billion frees of that
/// same row.
pub const retired: u32 = std.math.maxInt(u32);

/// The handle number of a `.file` row whose file has already been
/// closed.  No host may name a file with it, and nothing closes it.
pub const no_file: i64 = -1;

pub const Object = struct {
    /// Which occupant of this row is the current one.  A handle names
    /// this object only while the two agree; every free moves it on,
    /// which is what makes a stale handle stay stale across the reuse
    /// of its row (`Runtime.freeObject`).
    ///
    /// Generated code reads this field itself, at `layout.generation`
    /// — a measured offset, because Zig orders a plain struct's
    /// fields as it pleases.
    generation: u32 = 0,

    /// The next row on `Runtime.free_row`, or `value.null_index` at
    /// the end of it.  Meaningful only while this row is free; a live
    /// row's link is not read.
    ///
    /// The list is threaded through the rows rather than kept beside
    /// them because `freeObject` cannot fail — an allocation there
    /// would have to choose between a leak and an error path no
    /// caller could do anything with — and because it is free: these
    /// four bytes and the generation's together fill the tail padding
    /// a row already had, so it is the 128 bytes it always was.
    next_free: u32 = value.null_index,

    owner: Owner = .loose,

    /// The elements of a List or an Array — a field of the row rather
    /// than a payload inside `data`, which is a deliberate exception
    /// and the only one.
    ///
    /// Compiled code indexes an Array *inline*: no runtime call, no
    /// boxed subscript, just the bounds check and the element load
    /// docs/CODEGEN.md describes.  To emit that it needs the byte
    /// offset of the element pointer and the count at **compile**
    /// time, and Zig promises a layout for a struct field while
    /// promising nothing for a tagged union's payload.  So the one
    /// shape generated code walks lives here, where `@offsetOf` can
    /// answer for it (`layout` below), and every other kind's storage
    /// stays in `data`, reached only through a checked switch.
    ///
    /// Meaningful when `data` is `.list` or `.array`; `.empty`
    /// otherwise, and `.empty` again once the object is released.
    elements: Elements = .empty,

    /// An Array's axis lengths, `rank` of them, immutable after `new`.
    /// A row field for the same reason `elements` is one: a rank-2
    /// index is generated inline and reads this at a measured offset.
    /// Meaningful exactly when `data == .array`.
    dims: []i64 = &.{},

    data: Data,

    pub const Data = union(enum) {
        /// The elements are `Object.elements`, which for a List is
        /// allocated ahead of `count` — see `Elements.capacity`.
        list,
        map: Map,
        /// The elements are `Object.elements` and the shape is
        /// `Object.dims`, for the reason above.
        array,
        builder: std.ArrayList(u8),
        /// An open file, as the host numbers it (docs/BYTES.md R5).
        ///
        /// **A resource, owned exactly as memory is.**  The binding
        /// that received it owns it, the owning scope's end closes it,
        /// `give`/`return`/`free` mean what OWNERSHIP.md says, and a
        /// use after close traps `use_after_free` because it is the
        /// same mistake.  What is different from every other kind is
        /// only that its release reaches outside the process, which is
        /// why `Runtime` holds the host's channel for the whole run
        /// (`files`): `freeObject` is where a scope's end arrives, and
        /// nothing is standing there to hand a host in.
        file: File,
        /// A running worker (docs/THREADS.md D3).
        ///
        /// A resource on exactly the terms `file` is one, and the same
        /// sentence covers it: the binding that received it owns it,
        /// the owning scope's end releases it, and `give`/`return`/
        /// `free` mean what OWNERSHIP.md says.  What "release" *is* is
        /// the only thing that differs — for a file it is a close and
        /// for a task it is a **join**, which is why an orphan thread
        /// is as unrepresentable in Luce as a leaked list (D5).
        ///
        /// The pointer is null once the worker has been joined and its
        /// runtime closed, which `wait` does early and the scope's end
        /// does otherwise; a task whose worker is gone is spent, and
        /// touching it again traps `use_after_free`.
        task: ?*workers.Worker,
    };

    /// An open file: the number the host knows it by, and the path it
    /// was opened at.
    ///
    /// **The path is kept because an error has to name it.**  "the read
    /// failed" without saying which file is a message that helps
    /// nobody (docs/FAILURE.md), and a handle two hundred lines from
    /// its `open` is exactly where a reader has stopped being able to
    /// supply the name themselves.  The bytes are the object's, freed
    /// with it.
    pub const File = struct {
        handle: i64,
        path: []const u8,
    };

    /// A run of elements stored at their real width — the storage a
    /// List and an Array share.
    ///
    /// **The elements are stored as themselves, not as `Value`s.**  An
    /// `array(double, n)` is `f64`s, a `list(byte)` is bytes, a
    /// `list(long)` is `i64`s; only the kinds whose tag or length is
    /// not a compile-time fact — Strings, structs, objects — keep the
    /// 24-byte slot.  Three reasons, in the order they matter:
    /// compiled code loads and stores an element with one instruction
    /// and no unboxing; a `double` array is a third of the memory
    /// traffic of a boxed one, which is what a numeric loop is bound
    /// by; and a run of tagged slots is not something that can ever be
    /// handed to a SIMD unit or a GPU.  `Value` is the *boundary* type
    /// — how an element crosses into a caller — never the storage
    /// type, and nothing outside this struct needs to know the
    /// difference: `at` and `put` speak `Value` on both sides.
    ///
    /// A List reached this mechanism after `std.zip` measured what the
    /// boxed slot costs: `list(byte)` was twenty-four bytes an element
    /// and is now one (docs/BYTES.md R1).  The only difference between
    /// the two containers here is that a List's `bytes` runs ahead of
    /// its `count` so that `append` is amortized, and an Array's does
    /// not because an Array never grows.
    pub const Elements = struct {
        /// How one element is stored.
        kind: ElementKind = .value,
        /// The storage, `kind.width()` bytes an element — one pointer
        /// whatever the kind, so compiled code loads it from one
        /// place.  Allocated at `Value`'s alignment, which every kind
        /// is satisfied by.  Its length is the *capacity* in bytes;
        /// `count` says how many of them hold an element.
        bytes: Storage = &.{},
        /// How many elements there are: for an Array the product of
        /// `dims`, and for a rank-1 array its one and only bound.
        /// Compiled code bound-checks a rank-1 index against this
        /// rather than against `dims[0]`, which saves it the load
        /// through `dims` — and that indirection is exactly what stops
        /// LLVM vectorizing the loop around it.
        count: usize = 0,

        pub const empty: Elements = .{};

        /// Element storage, at `Value`'s alignment so every kind fits.
        pub const Storage = []align(@alignOf(Value)) u8;

        /// How many elements `bytes` has room for.
        pub fn capacity(self: Elements) usize {
            return self.bytes.len / self.kind.width();
        }

        /// Element `index`, as the `Value` every caller speaks.
        pub fn at(self: Elements, index: usize) Value {
            return switch (self.kind) {
                .value => self.cells(Value)[index],
                .double => Value.ofDouble(self.cells(f64)[index]),
                .long => Value.ofLong(self.cells(i64)[index]),
                .float => Value.ofFloat(self.cells(f32)[index]),
                .int => Value.ofInt(self.cells(i32)[index]),
                .half => Value.ofHalf(self.cells(f16)[index]),
                .short => Value.ofShort(self.cells(i16)[index]),
                .byte => Value.ofByte(self.cells(u8)[index]),
                .boolean => Value.ofBoolean(self.cells(u8)[index] != 0),
            };
        }

        /// Write element `index`.  The value's type is the container's
        /// element type — the analyzer settled that — so only the
        /// payload travels.
        pub fn put(self: Elements, index: usize, held: Value) void {
            switch (self.kind) {
                .value => self.cells(Value)[index] = held,
                .double => self.cells(f64)[index] = held.asDouble(),
                .long => self.cells(i64)[index] = held.asLong(),
                .float => self.cells(f32)[index] = held.asFloat(),
                .int => self.cells(i32)[index] = held.asInt(),
                .half => self.cells(f16)[index] = held.asHalf(),
                .short => self.cells(i16)[index] = held.asShort(),
                .byte => self.cells(u8)[index] = held.asByte(),
                .boolean => self.cells(u8)[index] = @intFromBool(held.asBoolean()),
            }
        }

        /// Every element set to `held` — `new`'s zero fill and
        /// `a.fill(v)`.
        pub fn fill(self: Elements, held: Value) void {
            switch (self.kind) {
                .value => @memset(self.cells(Value), held),
                .double => @memset(self.cells(f64), held.asDouble()),
                .long => @memset(self.cells(i64), held.asLong()),
                .float => @memset(self.cells(f32), held.asFloat()),
                .int => @memset(self.cells(i32), held.asInt()),
                .half => @memset(self.cells(f16), held.asHalf()),
                .short => @memset(self.cells(i16), held.asShort()),
                .byte => @memset(self.cells(u8), held.asByte()),
                .boolean => @memset(self.cells(u8), @intFromBool(held.asBoolean())),
            }
        }

        /// The live elements as their own storage type.  `T` must be
        /// `kind`'s cell type; every caller either switches on the
        /// kind or knows it from the value it is about to store.
        pub fn cells(self: Elements, comptime T: type) []T {
            const base: [*]T = @ptrCast(@alignCast(self.bytes.ptr));
            return base[0..self.count];
        }

        /// The bytes an element occupies, from `start` for `many` of
        /// them — how a growable run moves a tail without knowing what
        /// it holds.
        fn span(self: Elements, start: usize, many: usize) []u8 {
            const width = self.kind.width();
            return self.bytes[start * width ..][0 .. many * width];
        }

        // -- growth, which only a List does ------------------------------

        /// Room for `wanted` elements, growing geometrically.  The
        /// storage is the caller's allocator's; a run that cannot grow
        /// answers `error.OutOfMemory` and is left exactly as it was.
        ///
        /// The arithmetic is in **bytes**, not elements, and that is
        /// not a detail: `capacity()` divides by a width the compiler
        /// does not know, and an integer division on the hot path of
        /// every `append` measured as a real cost on the `strings`
        /// benchmark.  A multiply says the same thing.
        pub fn ensureCapacity(
            self: *Elements,
            allocator: Allocator,
            wanted: usize,
        ) Allocator.Error!void {
            const width = self.kind.width();
            const needed = std.math.mul(usize, wanted, width) catch
                return error.OutOfMemory;
            if (needed <= self.bytes.len) return;
            var grown = self.bytes.len;
            if (grown < 8 * width) grown = 8 * width;
            while (grown < needed) grown = grown +| grown / 2 +| width;
            const bytes = try allocator.alignedAlloc(u8, .of(Value), grown);
            @memcpy(bytes[0 .. self.count * width], self.bytes[0 .. self.count * width]);
            allocator.free(self.bytes);
            self.bytes = bytes;
        }

        /// Add one element at the end.
        pub fn append(
            self: *Elements,
            allocator: Allocator,
            held: Value,
        ) Allocator.Error!void {
            try self.ensureCapacity(allocator, self.count + 1);
            self.count += 1;
            self.put(self.count - 1, held);
        }

        /// Add one element at `index`, moving the rest along.  The
        /// caller has already checked that `index` is in range.
        pub fn insert(
            self: *Elements,
            allocator: Allocator,
            index: usize,
            held: Value,
        ) Allocator.Error!void {
            try self.ensureCapacity(allocator, self.count + 1);
            self.count += 1;
            const moved = self.count - 1 - index;
            if (moved != 0) {
                std.mem.copyBackwards(
                    u8,
                    self.span(index + 1, moved),
                    self.span(index, moved),
                );
            }
            self.put(index, held);
        }

        /// Take the element at `index` out, keeping the order of the
        /// rest, and hand it back so the caller can free what it owned.
        pub fn orderedRemove(self: *Elements, index: usize) Value {
            const taken = self.at(index);
            const moved = self.count - 1 - index;
            if (moved != 0) {
                std.mem.copyForwards(
                    u8,
                    self.span(index, moved),
                    self.span(index + 1, moved),
                );
            }
            self.count -= 1;
            return taken;
        }

        /// Take the last element out, or null when there is none.
        pub fn pop(self: *Elements) ?Value {
            if (self.count == 0) return null;
            // Read before shrinking: `cells` is bounded by `count`.
            const taken = self.at(self.count - 1);
            self.count -= 1;
            return taken;
        }

        /// Empty the run, keeping the storage for reuse.
        pub fn clear(self: *Elements) void {
            self.count = 0;
        }

        pub fn deinit(self: *Elements, allocator: Allocator) void {
            allocator.free(self.bytes);
            self.* = .{ .kind = self.kind };
        }
    };

    /// How a List or an Array stores one element.
    pub const ElementKind = enum(u32) {
        /// A 24-byte `Value`: a String, a struct, or an object handle
        /// — anything the element type does not settle to one machine
        /// word.  The only kind that can own something.
        value,
        double,
        long,
        boolean,
        /// The narrow widths, **appended**: an `array(int, n)` is
        /// `i32` cells and an `array(float, n)` is `f32` cells, which
        /// is half the memory and twice the lanes in the same vector
        /// register (docs/TYPES.md §6).
        float,
        int,
        /// The storage widths, appended in their turn.  These are what
        /// the narrow types are *for* (§10): an `array(byte, n)` is one
        /// byte an element, an eighth of what the same array of `long`
        /// costs, and the same vector register that holds two `double`s
        /// holds eight `half`s.
        half,
        short,
        byte,

        /// The cell type `Array.cells` reads, so a switch with an
        /// `inline else` gets the storage type for free.
        pub fn Cell(comptime self: ElementKind) type {
            return switch (self) {
                .value => Value,
                .double => f64,
                .long => i64,
                .float => f32,
                .int => i32,
                .half => f16,
                .short => i16,
                .byte => u8,
                .boolean => u8,
            };
        }

        pub fn width(self: ElementKind) usize {
            return switch (self) {
                .value => @sizeOf(Value),
                .double => @sizeOf(f64),
                .long => @sizeOf(i64),
                .float => @sizeOf(f32),
                .int => @sizeOf(i32),
                .half => @sizeOf(f16),
                .short => @sizeOf(i16),
                .byte => 1,
                .boolean => 1,
            };
        }

        /// How to store an element whose zero is `zero`.
        ///
        /// The element *type* lives in the program's type table, which
        /// the runtime deliberately does not know — but `newArray`
        /// already takes the element zero for exactly that reason, and
        /// its tag is the type.  So the kind arrives with the array
        /// and nothing new crosses the boundary.
        pub fn of(zero: Value) ElementKind {
            return switch (zero.tag) {
                .double => .double,
                .long => .long,
                .float => .float,
                .int => .int,
                .half => .half,
                .short => .short,
                .byte => .byte,
                .boolean => .boolean,
                .none, .string, .strukt, .object => .value,
            };
        }
    };

    /// Give the object's storage back and leave an empty thing of the
    /// same kind behind.
    ///
    /// What does *not* happen here is the row leaving the table.
    /// `freeObject` decides the row's fate — reuse or retirement —
    /// and this only reclaims what the object was holding.
    ///
    /// Releasing twice reclaims nothing the second time: an empty
    /// List, Map or Builder holds no allocation and an empty slice
    /// frees nothing.  That is what lets `Runtime.deinit` sweep every
    /// row without first asking which of them are still occupied.
    ///
    /// The kind is kept on purpose.  Nothing reads a freed object's
    /// data — the row's generation has moved on, so `resolve` traps
    /// `use_after_free` and the ownership walks skip it — but an empty
    /// List is a far better thing for a bug to find than a dangling
    /// pointer, and it costs a store.
    pub fn release(self: *Object, allocator: Allocator) void {
        switch (self.data) {
            .list => self.elements.deinit(allocator),
            .map => |*map| {
                map.deinit(allocator);
                self.data = .{ .map = .empty };
            },
            .array => {
                allocator.free(self.dims);
                self.dims = &.{};
                self.elements.deinit(allocator);
            },
            .builder => |*builder| {
                builder.deinit(allocator);
                self.data = .{ .builder = .empty };
            },
            // The host owns the file; `Runtime.freeObject` has already
            // told it to close, and there is no storage of ours here.
            // The number is blanked so the end-of-run sweep, which
            // releases every row occupied or not, does not close a
            // second time what ownership already closed.
            .file => |open| {
                allocator.free(open.path);
                self.data = .{ .file = .{ .handle = no_file, .path = "" } };
            },
            // `Runtime.freeObject` has already joined the worker and
            // closed its runtime; the pointer is blanked so the
            // end-of-run sweep does not join a second time what
            // ownership already joined.
            .task => self.data = .{ .task = null },
        }
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
/// against the same two payloads (long and String — the only key types
/// the analyzer admits) for that reason.
// ---------------------------------------------------------------------------
// The map behind a Map
// ---------------------------------------------------------------------------

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
    pub fn find(self: *const Map, key: *const Value) ?usize {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        var at = hashOf(key) & mask;
        while (true) : (at = (at + 1) & mask) {
            const position = self.slots[at];
            if (position == free_slot) return null;
            if (value.keyEquals(&self.entries.items[position].key, key)) return position;
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
        var at = hashOf(&self.entries.items[position].key) & mask;
        while (self.slots[at] != free_slot) at = (at + 1) & mask;
        self.slots[at] = position;
    }

    /// The hash `find` probes with.  Keys are long or String — the
    /// analyzer admits nothing else — and this reads exactly the two
    /// payloads `value.keyEquals` compares, so equal keys always hash
    /// equally.  Ints go through a bit mixer rather than being used
    /// raw: sequential keys are the common case and linear probing
    /// wants their low bits spread.
    fn hashOf(key: *const Value) usize {
        return switch (key.view()) {
            .long => |held| @truncate(std.hash.int(@as(u64, @bitCast(held)))),
            .string => |held| @truncate(std.hash.Wyhash.hash(0, held)),
            else => unreachable, // the analyzer keys maps by long or String
        };
    }
};

// ---------------------------------------------------------------------------
// How large a container may be
// ---------------------------------------------------------------------------

/// The most elements a container of `kind` may hold.
///
/// **The flat `max_array_elements = 1 << 24` is gone.**  It was a
/// safety valve rather than a design limit, and it was denominated in
/// the wrong unit (docs/TYPES.md): it counted elements, so an
/// `array(byte, n)` was refused at 16 MB and an `array(double, n)` at
/// 128 MB, for no reason either of them could see.  A machine's memory
/// is what limits an array, and a request the machine cannot meet is an
/// `allocation_failed` trap at the site that asked — located like every
/// other trap, and not a silent policy refusal at an arbitrary number.
///
/// What survives is the one thing a ceiling is *load-bearing* for:
/// docs/VECTOR.md's width table proves a narrow-element integer
/// reduction trap-free by bounding `N·M`, where `N` is the element cap
/// and `M` the element type's largest magnitude.  That proof needs a
/// ceiling per element width and not one number, so the ceilings here
/// are computed from the proof's own obligations — the largest `N` that
/// keeps `N·M` inside a `long` — in `i128`, because `i64` is the width
/// the arithmetic is *about* and a wrapped bound reports that
/// everything fits.
///
/// Kinds no integer reduction can name — `long` (no row qualifies),
/// the floats, `bool`, and the boxed slot — carry no proof obligation,
/// so their only ceiling is the one that keeps a byte count from
/// overflowing a `usize`.  RAM decides, and says so by failing.
pub fn maxElements(kind: Object.ElementKind) usize {
    return switch (kind) {
        // `byte × short`, the widest provable term a `byte` element
        // takes part in (VECTOR.md's multiply-accumulate table).
        .byte => proofCeiling(255 * 32768),
        // `short × short`, evaluated at `int`.
        .short => proofCeiling(1 << 30),
        // A plain `int` sum; no `int` product qualifies at any width.
        .int => proofCeiling(1 << 31),
        .value, .double, .long, .float, .half, .boolean => std.math.maxInt(usize) /
            kind.width(),
    };
}

/// The largest element count that keeps `count · magnitude` inside a
/// `long`, computed in `i128` at comptime.
fn proofCeiling(comptime magnitude: i128) usize {
    const bound = @divFloor(@as(i128, std.math.maxInt(i64)), magnitude);
    return @intCast(@min(bound, @as(i128, std.math.maxInt(usize))));
}

// ---------------------------------------------------------------------------
// What compiled code walks
// ---------------------------------------------------------------------------

/// Where an object row's fields sit, in bytes, for the one reader that
/// cannot call a function to ask: generated machine code
/// (`08_llvm/lower.zig`), which indexes a `List` or an `Array` inline.
///
/// Nothing here is *written down* — every offset is measured from the
/// Zig types above with `@offsetOf`, so the two cannot drift, and the
/// test at the foot of this file reads a real `Runtime` through these
/// numbers and checks it sees the fields it means to.  That is the same
/// bargain `runtime/value.zig` strikes for the 24-byte `Value`: one
/// layout, asserted rather than assumed.
///
/// The compiler and `libluce_rt` are built from this file by one Zig
/// compiler for one target, so a measured offset is the same number on
/// both sides.  An artifact is not portable across runtime builds —
/// neither is the `Value` layout, nor the service signatures.
pub const layout = struct {
    /// `Runtime.table.items.ptr` — the base of the object table.
    pub const table_pointer = @offsetOf(Runtime, "table") +
        @offsetOf(std.ArrayList(Object), "items") + slice_pointer;
    /// One row.
    pub const row_size = @sizeOf(Object);
    pub const row_alignment = @alignOf(Object);
    /// `Object.generation` — a `u32`.  The row holds the object a
    /// handle names exactly while the two are equal, so the liveness
    /// test generated code emits is this one load and one compare,
    /// and a reused row fails it for every handle but the newest.
    pub const generation = @offsetOf(Object, "generation");
    /// `Object.owner.kind` — the `u32` generated code compares before
    /// an inline mutation whose receiver may have come through a
    /// parameter (CONSTANTS.md R-D).
    pub const owner_kind = @offsetOf(Object, "owner") + @offsetOf(Owner, "kind");
    /// The value of `Owner.Kind.program`, beside the measured offset
    /// so generated code never writes down either half of the check.
    pub const owner_program: u32 = @intFromEnum(Owner.Kind.program);
    /// `Object.dims.ptr` — `[*]i64`, one entry per axis.  An Array's
    /// alone: a List has no shape but its length.  The rank is a
    /// compile-time fact, so the length is not read, and only a
    /// rank-2-or-higher access reads this at all — rank 1 and every
    /// List bound-check against `elements_count`, one load nearer.
    pub const array_dims = @offsetOf(Object, "dims") + slice_pointer;
    /// `Object.elements.bytes.ptr` — the elements, in the element
    /// kind's own storage (`Object.ElementKind`), which the program
    /// knows statically.  A List's and an Array's alike: the run is
    /// one field, shared, at one offset (`Object.elements`).
    pub const elements_pointer = @offsetOf(Object, "elements") +
        @offsetOf(Object.Elements, "bytes") + slice_pointer;
    /// `Object.elements.bytes.len` — the room, **in bytes**, not in
    /// elements: `Elements.ensureCapacity` grows a byte length and
    /// need not leave it a whole multiple of the width.  What an
    /// inline `append` compares against, and the reason it compares
    /// `(count + 1) * width` rather than a count.
    pub const elements_capacity = @offsetOf(Object, "elements") +
        @offsetOf(Object.Elements, "bytes") + slice_count;
    /// `Object.elements.count` — a List's length, an Array's product
    /// of the axes, and the one bound a rank-1 index is checked
    /// against.  An inline `append` writes it.
    pub const elements_count = @offsetOf(Object, "elements") +
        @offsetOf(Object.Elements, "count");

    /// `Runtime.constant_roots.ptr` — one `Value` per reachable
    /// constant-container pool row, materialized for this runtime.
    pub const constant_roots_pointer = @offsetOf(Runtime, "constant_roots") + slice_pointer;
    /// `Runtime.constant_roots.len`, measured for the layout proof and
    /// bounds diagnostics; verified generated code indexes directly.
    pub const constant_roots_count = @offsetOf(Runtime, "constant_roots") + slice_count;

    /// A Zig slice is `{ ptr, len }`, in that order, on every target.
    /// Named here rather than spelled `0` at four call sites, and
    /// checked by the same test.
    pub const slice_pointer = 0;
    pub const slice_count = @sizeOf(usize);
};

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

    /// Every row the run has ever needed; handles index this table.
    /// The `Object`s sit in it directly rather than behind pointers —
    /// a handle is one bounds check and one load, not two.
    ///
    /// Rows are reused: a freed one goes on `free_row` and the next
    /// `new` moves into it, so the table grows to the program's peak
    /// object count and not to the number of objects it ever made.
    /// What keeps that from turning a use-after-free into somebody
    /// else's object is the generation each row carries: a handle
    /// names the row's *current* occupant only, and a stale one traps
    /// `use_after_free` (S9) exactly as it did when rows were retained
    /// forever.
    ///
    /// A row is never *removed*, only re-occupied, so a handle is
    /// always in bounds or null — which is why generated code omits
    /// the bounds check that `resolve` still makes for its Zig
    /// callers.
    ///
    /// Because the objects are inline, `resolve` hands out a pointer
    /// into a slice that moves when the table grows.  Nothing may hold
    /// an `*Object` across a call that can allocate a new object —
    /// re-resolve, or work through a copy of the object's contents,
    /// whose buffers the table does not own.
    table: std.ArrayList(Object) = .empty,

    /// Handles for this runtime's materialized constant containers,
    /// indexed by the program's pruned constant-container pool.  The
    /// slice is object-allocator-owned; its entries borrow rows whose
    /// owner is `.program` and own no value storage themselves.
    constant_roots: []Value = &.{},

    /// Live rows owned by the program root.  These rows are excluded
    /// from the ownership leak census and are reclaimed only by abort
    /// or by the runtime's final sweep (CONSTANTS.md R-C).
    program_root_count: u32 = 0,

    /// True only while the eager constant prologue is constructing
    /// this runtime's roots.  The C boundary uses it to turn allocator
    /// failure into the located `allocation_failed` trap promised for
    /// materialization, rather than the run-wide exhausted status.
    materializing_constants: bool = false,

    /// The first row free for reuse, or `value.null_index` when there
    /// is none.  A last-in-first-out list threaded through
    /// `Object.next_free`, so a free costs two stores and an
    /// allocation costs two loads, and neither can fail.
    free_row: u32 = value.null_index,

    /// Objects allocated and not yet freed — the leak census the host
    /// reports when a program returns (`Success.leaked_objects`).
    /// Memory is explicit in Luce, so what a program did not free is
    /// part of what it did.
    live: u32 = 0,

    /// Unique per call: object ownership names (serial, local) pairs,
    /// so recursion never confuses two frames' bindings.  u64 — a run
    /// has no instruction limit of any kind, so 2^32 calls is an
    /// afternoon, and a wrapped serial would let ownership confuse
    /// two frames.
    next_serial: u64 = 1,

    /// The trap raised by the operation that most recently returned
    /// `error.Trap`.  This is the ceval-style pending-error pattern —
    /// no per-operation outcome plumbing.
    pending: ?Trap = null,

    /// The error a `try`-able call left behind, or null when the last
    /// one returned.  Separate from `pending` because the two are
    /// different acts: a trap ends the program, an error is news a
    /// caller may `catch` — and only one of them is ever set, because
    /// an error that is not caught unwinds without running any code
    /// that could trap.
    ///
    /// This is the whole of the error channel on the interpreter.
    /// Compiled code carries the *outcome* in the value a Luce
    /// function returns and reads this only for the words
    /// (docs/CODEGEN.md).
    raised: ?Raised = null,

    /// Set when the arena gave up.  A C caller cannot see
    /// `error.OutOfMemory`, so the exports record it here and the
    /// entry wrapper turns it into a distinct status.
    exhausted: bool = false,

    /// Set when the program said `exit(status)`.  The unwind rides
    /// the trap edge exactly as exhaustion does — every frame
    /// returns, nothing is reported — and `luce_rt_status` turns
    /// this into a status of its own so a host can tell "the program
    /// chose to stop" from every other way a run ends.
    exit_status: ?i64 = null,

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
    /// One owned slot, replaced by `setKeyText` and released with the
    /// run; `key_text` hands out a borrow of it, and storing that
    /// borrow copies like every other store (docs/STRINGS.md).
    last_key_text: []const u8 = "",

    /// The host's file-handle channel, installed once at the start of a
    /// run (`runtime/files.zig`).  Held rather than passed because a
    /// handle's close happens at a scope's end, inside `freeObject`,
    /// where no caller is standing to hand a host in.  Empty until
    /// installed, and every slot is fail-closed like every other
    /// effect.
    files: files.Channel = .{},

    /// The host's thread channel, installed once at the start of a run
    /// and inherited by every worker (docs/THREADS.md D8).  Held rather
    /// than passed for the reason `files` is: a task's join happens at
    /// the end of the scope that owns it, inside `freeObject`, where no
    /// caller is standing to hand a host in.  Empty until installed,
    /// and fail-closed like every other effect.
    workers: workers.Channel = .{},

    /// How this engine makes a runtime for a worker and runs one
    /// function in it (docs/THREADS.md).  Not a *host* service — a
    /// machine supplies threads, and what to run on one is the
    /// engine's own answer, which is exactly why the two arms differ
    /// here and nowhere else.
    nursery: workers.Nursery = .{},

    /// The one lock every runtime in this program shares, or null when
    /// nothing has spawned (docs/THREADS.md D9, D11).  Allocated by the
    /// **root** runtime at its first spawn and handed down to every
    /// worker, which is sound with no counting because a scope's end
    /// joins: every worker is finished before the root's run is, so the
    /// root outlives all of them by construction.
    effects: ?*workers.Effects = null,

    /// What a leaked object costs in a run this one started
    /// (docs/THREADS.md).  A worker's census is added here as its
    /// runtime closes, so a program's total is one number however many
    /// runtimes it used, and the two-engine comparison sees one honest
    /// answer.
    inherited_leaks: i64 = 0,

    /// How many frames a run may take, as this program was started
    /// with.  Recorded so a worker can be given a **fresh** budget
    /// rather than what is left of its spawner's (docs/THREADS.md D1):
    /// a worker's frames are its own thread's, so it starts from the
    /// number every run starts from.  Zero until a spawn-capable run
    /// installs it, which is the only thing that ever reads it.
    depth_budget: i64 = 0,

    /// True on the runtime that allocated `effects` — the root of a
    /// program's runtimes, the only one that gives it back.
    owns_effects: bool = false,

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
    /// The storage a container still holds goes with it: a leaked
    /// `List(String)` leaked its strings too, and they come from the
    /// same allocator now (docs/STRINGS.md).  What this cannot reach is
    /// storage held only by a *binding* of a frame a trap unwound past
    /// — the engines sweep their own frames for that, because only they
    /// know where the frames are.
    ///
    /// Every row is swept, occupied or not: releasing a row whose
    /// object ownership already released reclaims nothing, because
    /// `Object.release` left the empty value of its kind behind.
    pub fn deinit(self: *Runtime) void {
        // The program root is the last owner to die (CONSTANTS.md
        // R-C).  Ordinary leaks and resources are reclaimed first;
        // constant rows follow in a separate, explicit pass.
        for (self.table.items) |*object| {
            if (object.owner.kind != .program) self.sweep(object);
        }
        for (self.table.items) |*object| {
            if (object.owner.kind == .program) self.sweep(object);
        }
        self.table.deinit(self.objects);
        if (self.constant_roots.len != 0) self.objects.free(self.constant_roots);
        self.unwound.deinit(self.objects);
        if (self.last_key_text.len != 0) self.objects.free(self.last_key_text);
        // The shared lock belongs to the runtime that made it, and by
        // the time that one ends every worker has been joined (D5), so
        // there is nobody left who could be holding it.
        if (self.owns_effects) {
            if (self.effects) |shared| self.objects.destroy(shared);
            self.effects = null;
        }
        self.* = undefined;
    }

    /// Objects this run and every worker under it left alive — the
    /// census, as one number (docs/THREADS.md D10).  A worker's total
    /// is folded in as its runtime closes, so a leak in a worker is a
    /// leak in the program and both engines report the same figure.
    pub fn leaked(self: *const Runtime) i64 {
        return @as(i64, self.live) - @as(i64, self.program_root_count) +
            self.inherited_leaks;
    }

    /// Release one row during the final sweep.  The caller decides the
    /// owner order; this gives storage back directly because every row
    /// is swept and no ownership walk may run twice at teardown.
    fn sweep(self: *Runtime, object: *Object) void {
        switch (object.data) {
            // Only a `Value` element can be holding storage; a packed
            // cell owns nothing (docs/BYTES.md R1).
            .list, .array => if (object.elements.kind == .value) {
                for (object.elements.cells(Value)) |item| self.dropStorage(item);
            },
            .map => |map| for (map.entries.items) |entry| {
                self.dropStorage(entry.key);
                self.dropStorage(entry.value);
            },
            .builder => {},
            // A handle the program leaked is still an open file: the
            // run gives it back even though ownership did not.
            .file => |open| self.closeFile(open.handle),
            // And a task the program leaked is still a running thread:
            // the sweep joins it, for the same reason and with the
            // same silence (`workers.release`).
            .task => |held| if (held) |worker| workers.release(self, worker),
        }
        object.release(self.objects);
    }

    /// The one lock this program's runtimes share, made on demand.
    ///
    /// **A program that never spawns never gets here**, which is the
    /// whole of D11 in the runtime: no allocation, no lock, no branch
    /// on a spawn-free path, because the field stays null and every
    /// guard below is written against it.
    pub fn sharedEffects(self: *Runtime) Error!*workers.Effects {
        if (self.effects) |held| return held;
        const made = try self.objects.create(workers.Effects);
        made.* = .{};
        self.effects = made;
        self.owns_effects = true;
        return made;
    }

    /// Take the effect lock, if this program has one (D9).  Paired with
    /// `leaveEffects`, and recursive, so a service that reaches another
    /// one does not deadlock on itself.
    pub fn enterEffects(self: *Runtime) void {
        if (self.effects) |shared| shared.enter();
    }

    pub fn leaveEffects(self: *Runtime) void {
        if (self.effects) |shared| shared.leave();
    }

    /// Remember the text payload of the key just read.  One owned slot
    /// per run rather than a fresh allocation per keystroke: a draw
    /// loop reads a key every frame, and the previous payload is dead
    /// the moment the next one arrives.
    pub fn setKeyText(self: *Runtime, bytes: []const u8) Error!void {
        const copied = if (bytes.len == 0) "" else try self.objects.dupe(u8, bytes);
        if (self.last_key_text.len != 0) self.objects.free(self.last_key_text);
        self.last_key_text = copied;
    }

    /// A serial no other live frame carries.  One per call.
    pub fn takeSerial(self: *Runtime) u64 {
        const serial = self.next_serial;
        self.next_serial += 1;
        return serial;
    }

    // -- the trap channel ------------------------------------------------

    /// Record `code` with its standard message and unwind.
    pub fn fail(self: *Runtime, code: vocabulary.TrapCode) Error {
        return self.failMessage(code, code.message());
    }

    /// Record `code` with words of the program's own (`trap("...")`).
    ///
    /// **The words are copied here, and that is not optional.**  The
    /// channel used to store the borrow, on the argument that a trap
    /// unwinds *past* every release, so nothing gives the bytes back
    /// before the report reads them.  That argument was about the wrong
    /// hazard.  Nothing frees a trap message and the words still go: a
    /// String short enough to live *inside* its value (`value.zig`) has
    /// no allocation at all, and the value it lives in is a slot in the
    /// frame that raised the trap — an `alloca` on the compiled path, a
    /// register on the interpreter's.  The trap edge returns out of that
    /// frame immediately and the report is only read once the whole run
    /// has stopped, so the words handed over are read after the storage
    /// holding them has gone: `trap("not a number: " + text)` reported
    /// stack litter (GitHub #28).  A frame ending is not a release, and
    /// no rule about releases could have covered it.  So the trap
    /// channel owns its words exactly as the error channel does, and
    /// takes them here, while the frame that raised the trap is still
    /// standing.  The copy goes in the values arena, which nothing
    /// releases and the run drops whole after the report; an arena that
    /// cannot hold it falls back to the code's own static words rather
    /// than to a borrow that may already be gone.
    ///
    /// Standard traps pay the copy too, for their static text, because
    /// two doors with two contracts is what let one of them be wrong —
    /// and a trap is a run's last act, so it is one `dupe` per run.
    ///
    /// Nothing is announced here.  Both engines read the trap back out
    /// once the program has stopped — the interpreter from `pending`
    /// directly, a compiled artifact through `luce_rt_report` — because
    /// a trap's call trace does not exist until unwinding is over
    /// (trace.zig).
    pub fn failMessage(self: *Runtime, code: vocabulary.TrapCode, message: []const u8) Error {
        const words = self.arena.dupe(u8, message) catch code.message();
        self.pending = .{ .code = code, .message = words };
        return error.Trap;
    }

    // -- the error channel -------------------------------------------------
    //
    // Errors are news, not bugs (docs/FAILURE.md), so unlike a trap
    // they do not end the run: they wait here until the frame that
    // asked propagates them or a `catch` forgets them.

    /// Record an error raised at `origin`.
    ///
    /// **The words are copied here, and that is not optional.**  An
    /// error unwinds *through* releases — that is the whole difference
    /// from a trap, which unwinds past them — so `error("x: " + String(n))`
    /// hands over bytes a statement temporary is about to give back.
    /// The copy goes in the values arena, which nothing releases and
    /// the run drops whole.  An arena that cannot hold it falls back
    /// to the code's own words rather than losing the error.
    pub fn raise(
        self: *Runtime,
        code: vocabulary.ErrorCode,
        message: []const u8,
        origin: trace.Frame,
    ) void {
        const words = self.arena.dupe(u8, message) catch code.message();
        self.raised = .{ .code = code, .message = words, .origin = origin };
    }

    /// The error a host file service's `no` becomes.  The words name
    /// the path, because "the file operation failed" without saying
    /// which file is a message that helps nobody — and they are built
    /// here, once, so both engines report the same sentence.  An arena
    /// that cannot hold them falls back to the code's own words rather
    /// than losing the error.
    pub fn raiseIo(
        self: *Runtime,
        act: vocabulary.FileAct,
        path: []const u8,
        origin: trace.Frame,
    ) void {
        // Built in the arena already, so it skips `raise`'s copy.
        const words = std.fmt.allocPrint(self.arena, "{s}{s}", .{ act.verb(), path }) catch {
            self.raised = .{
                .code = .io_failed,
                .message = vocabulary.ErrorCode.io_failed.message(),
                .origin = origin,
            };
            return;
        };
        self.raised = .{ .code = .io_failed, .message = words, .origin = origin };
    }

    /// `catch`: the error is handled, so the channel is empty again.
    /// The words go back with the arena at the end of the run; there
    /// is nothing to free here and nothing that outlives it.
    pub fn forget(self: *Runtime) void {
        self.raised = null;
    }

    /// Where instruction `instruction` of function `function` was
    /// written, resolved through the artifact's own tables.  A caller
    /// with no tables — the interpreter, which reads the program it is
    /// walking — builds its frames itself and never comes here.
    pub fn frameAt(self: *const Runtime, function: u32, instruction: u32) trace.Frame {
        if (function >= self.functions.len) return .{
            .function = "".ptr,
            .function_length = 0,
            .source = "".ptr,
            .source_length = 0,
            .line = 0,
            .column = 0,
        };
        const info = self.functions[function];
        var line: u32 = 0;
        var column: u32 = 0;
        if (info.origins) |origins| {
            if (instruction < info.origin_count) {
                line = origins[instruction].line;
                column = origins[instruction].column;
            }
        }
        return .{
            .function = info.name,
            .function_length = info.name_length,
            .source = info.source,
            .source_length = info.source_length,
            .line = line,
            .column = column,
        };
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
        self.unwound.append(self.objects, self.frameAt(function, instruction)) catch {
            self.dropped_frames +|= 1;
        };
    }

    // -- allocation --------------------------------------------------------

    /// Begin eager materialization for `count` reachable constant
    /// containers.  The handle table is this runtime's and is released
    /// by `abortConstants` or `deinit`; allocation failure is the
    /// located container trap promised before `main`, never exhaustion.
    pub fn beginConstants(self: *Runtime, count: u32) Error!void {
        if (self.materializing_constants or
            self.constant_roots.len != 0 or
            self.program_root_count != 0)
        {
            return self.fail(.not_owned);
        }
        self.materializing_constants = true;
        errdefer self.materializing_constants = false;
        if (count == 0) return;
        const roots = self.objects.alloc(Value, count) catch
            return self.fail(.allocation_failed);
        @memset(roots, Value.none);
        self.constant_roots = roots;
    }

    /// Publish one fully built loose container into the program root.
    /// The handle is borrowed by the table and stays live until abort
    /// or runtime teardown; a failed publication leaves it loose for
    /// `discardLoose` to reclaim.  Invalid state, slot, handle, or
    /// ownership traps `not_owned`/the handle's ordinary liveness trap.
    pub fn publishConstant(self: *Runtime, slot: u32, held: Value) Error!void {
        if (!self.materializing_constants or slot >= self.constant_roots.len) {
            return self.fail(.not_owned);
        }
        if (!self.constant_roots[slot].isNone()) return self.fail(.not_owned);
        if (held.tag != .object) return self.fail(.not_owned);
        const object = try self.resolve(held);
        if (object.owner.kind != .loose) return self.fail(.not_owned);
        object.owner = .program;
        self.constant_roots[slot] = held;
        self.program_root_count += 1;
    }

    /// The constant-container handle at `slot`.  It is a borrow of the
    /// runtime's program-root table and is invalid after teardown.
    /// Verified MIR guarantees the slot exists and was materialized,
    /// so this access cannot fail and performs no bounds recovery.
    pub fn constant(self: *const Runtime, slot: u32) Value {
        return self.constant_roots[slot];
    }

    /// Complete materialization.  From here allocator failure is an
    /// exhausted run again, and every published root remains frozen.
    pub fn finishConstants(self: *Runtime) void {
        self.materializing_constants = false;
    }

    /// Abandon a failed prologue: destroy every root it published and
    /// give back the table.  The caller first passes any current,
    /// unpublished construction to `discardLoose`, since no table slot
    /// names that object yet.
    pub fn abortConstants(self: *Runtime) void {
        for (self.constant_roots) |*root| {
            if (root.tag == .object) self.destroyObject(root.asObject());
            root.* = .none;
        }
        if (self.constant_roots.len != 0) self.objects.free(self.constant_roots);
        self.constant_roots = &.{};
        self.program_root_count = 0;
        self.materializing_constants = false;
    }

    /// Destroy an unpublished, partially filled loose container.  It
    /// consumes only that construction; a bound, adopted, stale, or
    /// already published handle is deliberately left alone.
    pub fn discardLoose(self: *Runtime, held: Value) void {
        if (held.tag != .object) return;
        const handle = held.asObject();
        const object = self.liveObject(handle) orelse return;
        if (object.owner.kind != .loose) return;
        self.destroyObject(handle);
    }

    /// A fresh empty list whose elements are stored at the width of
    /// `zero`'s type (docs/BYTES.md R1).  The element zero comes from
    /// the caller for the same reason `newArray` takes one: the
    /// element *type* lives in the program's type table, which the
    /// runtime deliberately does not know, and the zero's tag is the
    /// type.
    pub fn newList(self: *Runtime, zero: Value) Error!Value {
        return self.attach(.{
            .data = .list,
            .elements = .{ .kind = .of(zero) },
        });
    }

    pub fn newMap(self: *Runtime) Error!Value {
        return self.attach(.{ .data = .{ .map = .empty } });
    }

    pub fn newBuilder(self: *Runtime) Error!Value {
        return self.attach(.{ .data = .{ .builder = .empty } });
    }

    /// A fresh object naming a file the host has already opened
    /// (docs/BYTES.md R5).  Loose like every other `new`: the binding
    /// that receives it owns it, and its scope's end closes it.
    pub fn newFile(self: *Runtime, handle: i64, path: []const u8) Error!Value {
        const kept = try self.objects.dupe(u8, path);
        errdefer self.objects.free(kept);
        return self.attach(.{ .data = .{ .file = .{ .handle = handle, .path = kept } } });
    }

    /// A fresh object owning a worker that is already on its way
    /// (docs/THREADS.md D3).  Loose like every other `new`: the binding
    /// that receives it owns it, and its scope's end joins.
    pub fn newTask(self: *Runtime, worker: *workers.Worker) Error!Value {
        return self.attach(.{ .data = .{ .task = worker } });
    }

    /// Move `held` out of this runtime and into `target` — what a
    /// spawn's arguments and a wait's result both do (docs/THREADS.md
    /// D2, D4).
    ///
    /// **An object moves; a value copies.**  Nothing about that is new:
    /// it is S32 applied at one more site.  The object half is a deep
    /// re-own into the target followed by a free here, which is the
    /// correct floor and not a placeholder — a handle is an index into
    /// this table and a string's bytes came from this allocator, so
    /// there is no representation the two runtimes could share.  The
    /// value half frees nothing, because the caller's own storage is
    /// still the caller's: `spawn f(name)` leaves `name` exactly as a
    /// call would.
    pub fn moveInto(self: *Runtime, target: *Runtime, held: Value) Error!Value {
        const carried = try target.copyFrom(self, held);
        self.freeObjectsIn(held);
        return carried;
    }

    /// Tell the host a handle is finished with.  Called from the two
    /// places a file's life can end — the owning scope, and the run's
    /// own sweep of what a program leaked — neither of which has
    /// anybody to report a failure to, so the answer is not read: a
    /// host that cannot close has already lost the file.
    fn closeFile(self: *Runtime, handle: i64) void {
        if (handle == no_file) return;
        const service = self.files.close orelse return;
        // A close is a host call like any other, and this is the one
        // that happens with no engine standing (docs/THREADS.md D9).
        self.enterEffects();
        defer self.leaveEffects();
        _ = service(self.files.context, handle);
    }

    /// A fresh array of `dims`, every element `zero`.  The element zero
    /// comes from the caller because it depends on the program's type
    /// table, which the runtime deliberately does not know.
    pub fn newArray(self: *Runtime, dims: []const i64, zero: Value) Error!Value {
        const kind: Object.ElementKind = .of(zero);
        const ceiling = maxElements(kind);
        const shape = try self.objects.alloc(i64, dims.len);
        errdefer self.objects.free(shape);
        var total: usize = 1;
        for (dims, shape) |size, *dimension| {
            if (size < 0) return self.fail(.index_bounds);
            dimension.* = size;
            total = std.math.mul(usize, total, @intCast(size)) catch
                return self.fail(.allocation_failed);
            if (total > ceiling) return self.fail(.allocation_failed);
        }
        // The machine, not a policy number, is what limits an array
        // (`maxElements`): a request it cannot meet is a located trap
        // rather than the run ending `exhausted` somewhere else.
        const elements = self.objects.alignedAlloc(
            u8,
            .of(Value),
            total * kind.width(),
        ) catch return self.fail(.allocation_failed);
        errdefer self.objects.free(elements);
        const stored: Object.Elements = .{
            .kind = kind,
            .bytes = elements,
            .count = total,
        };
        try self.fillElements(stored, zero);
        return self.attach(.{ .data = .array, .dims = shape, .elements = stored });
    }

    /// Every cell of `stored` set to `held`.  A cell owns whatever
    /// storage it holds, so each one takes its own copy — `new
    /// array(Point, 100)` is a hundred field runs, not one shared a
    /// hundred times.  The zero of a String is empty text, which owns
    /// nothing, so the common case is still one `@memset`.
    pub fn fillElements(self: *Runtime, stored: Object.Elements, held: Value) Error!void {
        // A value with no allocation of its own — a scalar, a handle,
        // empty or inline text — is the same twenty-four bytes in
        // every cell, so filling is one `@memset`.
        if (stored.kind != .value or !held.ownsStorage()) {
            stored.fill(held);
            return;
        }
        const cells = stored.cells(Value);
        // A failed copy leaves the cells it already filled owned by the
        // array, which the caller releases; the rest stay empty.
        @memset(cells, .{ .tag = held.tag });
        for (cells) |*cell| cell.* = try self.ownValue(held);
    }

    /// Adopt an already-built run of elements as a new list — what the
    /// list-producing operations (`xs[a:b]`, `m.keys()`, `m.values()`)
    /// hand back once they have filled their elements in.
    pub fn attachList(self: *Runtime, elements: Object.Elements) Error!Value {
        return self.attach(.{ .data = .list, .elements = elements });
    }

    /// Put `storage` in a table row and hand back a loose handle.
    ///
    /// A row a previous object vacated is taken in preference to a
    /// fresh one; it keeps the generation its last occupant's death
    /// left it at, so the handle handed out here differs from every
    /// handle that row's earlier occupants were named by.  Only when
    /// the free list is empty does the table grow.
    ///
    /// On failure the storage is untouched and still the caller's to
    /// release — every caller here builds it under an `errdefer`.
    fn attach(self: *Runtime, storage: Object) Error!Value {
        if (self.free_row != value.null_index) {
            const index = self.free_row;
            const row = &self.table.items[index];
            self.free_row = row.next_free;
            const generation = row.generation;
            row.* = storage;
            row.generation = generation;
            self.live += 1;
            return Value.ofObject(.{ .index = index, .generation = generation });
        }
        const index: u32 = @intCast(self.table.items.len);
        try self.table.append(self.objects, storage);
        self.live += 1;
        return Value.ofObject(.{ .index = index });
    }

    // -- value storage ---------------------------------------------------
    //
    // A String's bytes and a struct value's field run are *storage*: a
    // heap allocation with exactly one owner — the binding, container
    // element, map key, struct field, or statement temporary that holds
    // it (docs/STRINGS.md).
    //
    // **A store site never copies.**  Every value handed to one is
    // already the store's to keep: stage 4 says `own_storage` in front
    // of it wherever the source is a borrow, and says nothing where the
    // source is this statement's own fresh value, which is how a
    // temporary's allocation moves into the place instead of being
    // duplicated.  So the copy is written once, in the IR, where the
    // decision that elides it can be seen — and `ownValue` below is
    // that one copy, reached from `own_storage` and from the runtime's
    // own duplications (`deepCopy`, a map's key, an array's fill).
    //
    // `dropStorage` is the matching death point, and it frees
    // nothing else — objects belong to the ownership walks above.

    /// A copy of `held` whose storage nothing else owns.  Scalars and
    /// object handles pass through untouched: an object field of a
    /// struct aliases, exactly as S26 says, and only the value fields
    /// are duplicated.
    ///
    /// Text that fits inside a value owns nothing and needs no
    /// allocator, and an empty run answers itself — which is also what
    /// makes a program constant safe to "own": storing one copies it,
    /// and the constant itself is never reached by a release.
    pub fn ownValue(self: *Runtime, held: Value) Error!Value {
        switch (held.tag) {
            .string => {
                const text = held.asString();
                // Short text is the value: copying the slot copies the
                // bytes, so there is nothing to allocate and nothing to
                // give back.  This is where the allocation copy-on-store
                // bought goes away again (docs/STRINGS.md).
                if (Value.fitsInline(text.len)) return .ofInlineText(held.tag, text);
                const copied = try self.objects.dupe(u8, text);
                return .ofOutside(held.tag, copied);
            },
            .strukt => {
                const source = held.asStruct();
                if (source.len == 0) return held;
                const run = try self.objects.alloc(Value, source.len);
                var filled: usize = 0;
                errdefer {
                    for (run[0..filled]) |field| self.dropStorage(field);
                    self.objects.free(run);
                }
                for (source, run) |field, *slot| {
                    slot.* = try self.ownValue(field);
                    filled += 1;
                }
                return Value.ofStruct(run);
            },
            else => return held,
        }
    }

    /// Give back the storage `held` owns — its bytes, or its field run
    /// and every value field inside it.  Objects are left alone: they
    /// have their own death point, and a struct copy shares them.
    ///
    /// Safe on anything that owns nothing, which is what makes a
    /// released slot safe to release again: every release writes the
    /// emptied value back, and an empty value frees nothing.
    pub fn dropStorage(self: *Runtime, held: Value) void {
        switch (held.tag) {
            .string => {
                // Inline text is the value, and a value is not an
                // allocation: there is nothing here to give back.
                if (!held.ownsStorage()) return;
                const start: [*]u8 = @ptrFromInt(@as(usize, @intCast(held.bits)));
                self.objects.free(start[0..@intCast(held.length)]);
            },
            .strukt => {
                if (held.bits == 0 or held.length == 0) return;
                const fields = held.asStruct();
                for (fields) |field| self.dropStorage(field);
                self.objects.free(fields);
            },
            else => {},
        }
    }

    /// What a released place holds afterwards: the same tag, no
    /// storage.  Releasing it again frees nothing, and reading it is
    /// what reading an unassigned local always was.
    pub fn emptied(held: Value) Value {
        return switch (held.tag) {
            // An emptied String is inline and zero bytes long, which
            // reads as `""` — the same thing it read as before, and
            // nothing to free.
            .string, .strukt => .{ .tag = held.tag },
            else => held,
        };
    }

    /// `held` with storage that outlives the frame it was made in —
    /// what `ret` hands the caller (docs/STRINGS.md).
    ///
    /// Inline text is the one form that cannot leave: on the compiled
    /// path the bytes sit in a frame slot, and the `{ptr, length}` the
    /// caller receives would point into a frame that has gone.  So
    /// inline text is copied out to an allocation the caller owns, and
    /// everything else — outside text, a struct's run, a scalar, a
    /// handle — is already frame-independent and moves untouched.
    ///
    /// This is a *transfer*, not a copy: the caller of a
    /// String-returning function owns exactly one allocation either
    /// way, which is why `ret` costs no more allocations than it did
    /// before short text lived in the value at all.
    pub fn exportValue(self: *Runtime, held: Value) Error!Value {
        switch (held.tag) {
            .string => {
                if (!held.textIsInline()) return held;
                const text = held.asString();
                // Empty text has nothing to allocate and no address
                // worth handing out, so it leaves as the static one.
                if (text.len == 0) return .ofOutside(held.tag, "");
                return .ofOutside(held.tag, try self.objects.dupe(u8, text));
            },
            else => return held,
        }
    }

    // -- struct storage ------------------------------------------------
    //
    // A struct value is a run of `Value`s the value owns.  That run is
    // never written to after it is built — `setField` allocates a fresh
    // one — so a struct stays an immutable value; what changed with
    // copy-on-store is that the run has a death point, so two places
    // never share one (docs/STRINGS.md).

    /// A fresh struct value holding `fields`, owning its run and every
    /// value field in it.
    ///
    /// **Consumes every field**: each one is stored as it stands, and
    /// on failure every one of them is released, so a caller that
    /// handed over a fresh value never has to take it back.
    pub fn makeStruct(self: *Runtime, fields: []const Value) Error!Value {
        if (fields.len == 0) return Value.ofStruct(&.{});
        const stored = self.objects.alloc(Value, fields.len) catch |mistake| {
            for (fields) |field| self.dropStorage(field);
            return mistake;
        };
        @memcpy(stored, fields);
        return Value.ofStruct(stored);
    }

    /// `held` with field `index` replaced, as a fresh value that owns
    /// everything in it.  The source is left intact — its own owner
    /// releases it — so its untouched fields are copied, not moved.
    ///
    /// **Consumes `to`**, like every other store site.
    pub fn setField(self: *Runtime, held: Value, index: usize, to: Value) Error!Value {
        const source = held.asStruct();
        const stored = self.objects.alloc(Value, source.len) catch |mistake| {
            self.dropStorage(to);
            return mistake;
        };
        // The unwind releases the copies it made and `to` once each:
        // `to` is the one field it never reads out of the run, so
        // whether the walk had reached it yet does not matter.
        var filled: usize = 0;
        errdefer {
            for (stored[0..filled], 0..) |field, at| {
                if (at != index) self.dropStorage(field);
            }
            self.dropStorage(to);
            self.objects.free(stored);
        }
        for (source, stored, 0..) |field, *slot, at| {
            slot.* = if (at == index) to else try self.ownValue(field);
            filled += 1;
        }
        return Value.ofStruct(stored);
    }

    // -- resolution ---------------------------------------------------------

    /// Resolve a handle to its live object, or fail: null slots trap
    /// null_object, freed ones use_after_free.
    ///
    /// The generation is the whole liveness test.  A handle whose
    /// generation is not the row's names an object that has been
    /// freed, whether or not somebody else has since moved into the
    /// row — so reuse costs the reader nothing and hides nothing.
    ///
    /// The pointer is into the object table and is only good until the
    /// next object is allocated (see `table`).
    pub fn resolve(self: *Runtime, held: Value) Error!*Object {
        const handle = held.asObject();
        if (handle.index == value.null_index) return self.fail(.null_object);
        if (handle.index >= self.table.items.len) return self.fail(.use_after_free);
        const found = &self.table.items[handle.index];
        if (found.generation != handle.generation) return self.fail(.use_after_free);
        return found;
    }

    /// Resolve a live object for a write, trapping when the program
    /// root owns it.  Every boxed mutation reaches the shared
    /// `requireMutable` owner gate through this wrapper or after its
    /// own first resolution; generated inline writes perform the same
    /// measured owner-kind check (`layout.owner_kind`, CONSTANTS.md
    /// R-D).  This wrapper carries `resolve`'s null/stale traps and
    /// pointer lifetime, and adds the `immutable_object` trap before
    /// returning a program-owned row.
    pub inline fn resolveMutable(self: *Runtime, held: Value) Error!*Object {
        const found = try self.resolve(held);
        try self.requireMutable(found);
        return found;
    }

    /// The owner half of `resolveMutable`, for a caller which already
    /// resolved the row to establish another operation-specific
    /// contract.  Kept inline with its wrapper so ordinary mutators pay
    /// for one handle walk and one owner comparison, not two calls.
    pub inline fn requireMutable(self: *Runtime, found: *Object) Error!void {
        if (found.owner.kind == .program) return self.fail(.immutable_object);
    }

    /// The live object behind a handle, or null when the handle is null,
    /// out of range, or already freed.  Ownership walks use this: they
    /// must never trap, because they run on paths that are already
    /// unwinding or already correct.
    ///
    /// The null handle's index is out of every table's bounds, so the
    /// range test answers it too.
    fn liveObject(self: *Runtime, handle: Handle) ?*Object {
        if (handle.index >= self.table.items.len) return null;
        const object = &self.table.items[handle.index];
        if (object.generation != handle.generation) return null;
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
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner.kind != .program) {
                    object.owner = .bound(.{ .serial = serial, .local = local });
                }
            },
            .strukt => |fields| for (fields) |field| self.bind(field, serial, local),
            else => {},
        }
    }

    /// The objects in `held` were adopted by a container (S20).
    pub fn adopt(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner.kind != .program) object.owner = .container;
            },
            .strukt => |fields| for (fields) |field| self.adopt(field),
            else => {},
        }
    }

    /// The objects in `held` belong to nobody yet: pop results and
    /// returned values (the receiver adopts or binds them next).
    pub fn loosen(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner.kind != .program) object.owner = .loose;
            },
            .strukt => |fields| for (fields) |field| self.loosen(field),
            else => {},
        }
    }

    /// On return, everything the finished frame still owned in the
    /// returned value moves out loose; the caller owns it (S16).
    pub fn loosenFromFrame(self: *Runtime, held: Value, serial: u64) void {
        switch (held.view()) {
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner.kind == .binding and object.owner.binding.serial == serial) {
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
            .object => |handle| {
                const object = self.liveObject(handle) orelse return;
                if (object.owner.kind == .binding and
                    object.owner.binding.serial == serial and
                    object.owner.binding.local == local)
                {
                    self.freeObject(handle);
                }
            },
            .strukt => |fields| for (fields) |field| self.unbind(field, serial, local),
            else => {},
        }
    }

    /// Free one object and everything it owns, recursively (S20), give
    /// its storage back, and offer its row to the next `new`.
    ///
    /// The order is deliberate all the way through.  The generation
    /// moves first, so the object is dead before its own elements are
    /// walked and an element naming it stops the walk instead of
    /// recursing forever.  The elements are walked next, while they
    /// are still there, and only then can the buffer holding them go.
    /// The row joins the free list last, once nothing about it is
    /// still being read.  Nothing here allocates, so the pointer into
    /// the table stays good across all of it.
    pub fn freeObject(self: *Runtime, handle: Handle) void {
        const object = self.liveObject(handle) orelse return;
        // The program root is sticky: releases reached through an
        // alias, a damaged module, or an unwinding ownership walk are
        // safe no-ops.  The source front line refuses them by name.
        if (object.owner.kind == .program) return;
        self.destroyObject(handle);
    }

    /// End a live object regardless of whether its owner is the
    /// program root.  Ordinary releases enter through `freeObject`;
    /// only failed materialization uses this on `.program` rows.
    fn destroyObject(self: *Runtime, handle: Handle) void {
        const object = self.liveObject(handle) orelse return;
        const was_program = object.owner.kind == .program;
        object.generation += 1;
        self.live -= 1;
        if (was_program) self.program_root_count -= 1;
        switch (object.data) {
            // Only a `Value` element can hold an object; a `f64`, an
            // `i64` or a byte cell owns nothing and has nothing to walk.
            .list, .array => if (object.elements.kind == .value) {
                for (object.elements.cells(Value)) |item| self.freeValue(item);
            },
            .map => |map| for (map.entries.items) |entry| {
                // A map owns its keys' storage as well as its values';
                // keys are long or String, so there is never an object
                // in one.
                self.dropStorage(entry.key);
                self.freeValue(entry.value);
            },
            .builder => {},
            // The scope's end is the close (docs/BYTES.md R5).
            .file => |open| self.closeFile(open.handle),
            // And for a worker the scope's end is the join
            // (docs/THREADS.md D5).
            .task => |held| if (held) |worker| workers.release(self, worker),
        }
        object.release(self.objects);
        // A row that has run out of generations is retired rather than
        // handed out again: see `retired`.
        if (object.generation != retired) {
            object.next_free = self.free_row;
            self.free_row = handle.index;
        }
    }

    /// Drop a value a container owned outright — an overwrite, a
    /// remove, a clear, or the element walk of `freeObject`.  Both
    /// halves of ownership end here: the objects it holds are freed,
    /// and the storage it holds is given back.
    pub fn freeValue(self: *Runtime, held: Value) void {
        self.freeObjectsIn(held);
        self.dropStorage(held);
    }

    /// The object half of `freeValue`, on its own: everything a struct
    /// value's fields name, without touching the run they sit in.
    pub fn freeObjectsIn(self: *Runtime, held: Value) void {
        switch (held.view()) {
            .object => |handle| self.freeObject(handle),
            .strukt => |fields| for (fields) |field| self.freeObjectsIn(field),
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
            .object => |handle| {
                if (handle.index == value.null_index) return;
                const found = self.liveObject(handle) orelse
                    return self.fail(.use_after_free);
                if (found.owner.kind == .container or found.owner.kind == .program) {
                    return self.fail(.not_owned);
                }
                if (expected) |owner| {
                    if (!(found.owner.kind == .binding and
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
        return self.copyFrom(self, held);
    }

    /// The same walk, reading out of `source` and building in `self`.
    ///
    /// **Two runtimes is the general case and one is the special one.**
    /// `copy xs` is this with both ends the same; a worker's arguments
    /// and its result are this with two ends, because a handle is an
    /// index into *one* table and a string's bytes come from *one*
    /// allocator, so nothing an object is made of survives being
    /// carried across (docs/THREADS.md).  Every allocation here is
    /// `self`'s and every read is `source`'s, which is the whole of the
    /// difference; writing the walk twice would have been two places
    /// for one semantic.
    pub fn copyFrom(self: *Runtime, source: *Runtime, held: Value) Error!Value {
        switch (held.view()) {
            .object => |handle| {
                if (handle.index == value.null_index) return held;
                if (source.liveObject(handle) == null) return self.fail(.use_after_free);
                const index = handle.index;
                // Each arm copies the source object's contents out
                // before recursing: the walk allocates objects, which
                // moves the table, and the source's own buffers do not
                // move with it.
                var storage: Object = switch (source.table.items[index].data) {
                    .list => blk: {
                        const run = source.table.items[index].elements;
                        var copied: Object.Elements = .{ .kind = run.kind };
                        errdefer copied.deinit(self.objects);
                        try copied.ensureCapacity(self.objects, run.count);
                        // Packed cells own nothing, so the whole run
                        // copies as bytes; only a `Value` element needs
                        // a walk of its own.
                        if (run.kind != .value) {
                            @memcpy(copied.bytes[0..run.bytes.len], run.bytes);
                            copied.count = run.count;
                        } else {
                            // `run` is a copy of the row's descriptor, so
                            // the buffer it names stays put while the
                            // walk allocates and moves either table.
                            for (run.cells(Value)) |item| {
                                const duplicate = try self.copyFrom(source, item);
                                copied.count += 1;
                                copied.put(copied.count - 1, duplicate);
                            }
                        }
                        break :blk .{ .data = .list, .elements = copied };
                    },
                    .map => |map| blk: {
                        var copied: Map = .empty;
                        errdefer copied.deinit(self.objects);
                        for (map.entries.items) |entry| {
                            // The key's bytes are the source map's, so
                            // the copy takes its own: a `map(string, T)`
                            // whose keys are longer than a value holds
                            // would otherwise be two maps over one run
                            // of bytes, and two frees of it.
                            const key = try self.ownValue(entry.key);
                            errdefer self.dropStorage(key);
                            try copied.insert(self.objects, .{
                                .key = key,
                                .value = try self.copyFrom(source, entry.value),
                            });
                        }
                        break :blk .{ .data = .{ .map = copied } };
                    },
                    .array => blk: {
                        const run = source.table.items[index].elements;
                        const dims = try self.objects.dupe(i64, source.table.items[index].dims);
                        errdefer self.objects.free(dims);
                        const elements = try self.objects.alignedAlloc(
                            u8,
                            .of(Value),
                            run.bytes.len,
                        );
                        errdefer self.objects.free(elements);
                        const copied: Object.Elements = .{
                            .kind = run.kind,
                            .bytes = elements,
                            .count = run.count,
                        };
                        // Cells that own nothing copy as bytes; only a
                        // `Value` element needs a walk of its own.
                        if (run.kind == .value) {
                            for (run.cells(Value), copied.cells(Value)) |item, *slot| {
                                slot.* = try self.copyFrom(source, item);
                            }
                        } else {
                            @memcpy(elements, run.bytes);
                        }
                        break :blk .{ .data = .array, .dims = dims, .elements = copied };
                    },
                    .builder => |builder| blk: {
                        var copied: std.ArrayList(u8) = .empty;
                        errdefer copied.deinit(self.objects);
                        try copied.appendSlice(self.objects, builder.items);
                        break :blk .{ .data = .{ .builder = copied } };
                    },
                    // A second Luce handle on one open file would be
                    // two owners of one resource, which is the thing
                    // scope ownership exists to make impossible.  Stage
                    // 4 refuses `copy f` by name; this is the wall
                    // behind it, for IR that arrived some other way.
                    .file => return self.fail(.not_owned),
                    // A task is one worker's, and a second handle on it
                    // would be two joiners of one thread.  Stage 4
                    // refuses `copy t` by name; this is the wall behind
                    // it (docs/THREADS.md D3).
                    .task => return self.fail(.not_owned),
                };
                errdefer storage.release(self.objects);
                const duplicate = try self.attach(storage);
                // The copy's own elements belong to it.
                const made = &self.table.items[duplicate.asObject().index];
                switch (made.data) {
                    .list, .array => if (made.elements.kind == .value) {
                        for (made.elements.cells(Value)) |item| self.adopt(item);
                    },
                    .map => |map| for (map.entries.items) |entry| self.adopt(entry.value),
                    .builder, .file, .task => {},
                }
                return duplicate;
            },
            .strukt => |fields| {
                if (fields.len == 0) return held;
                const copied = try self.objects.alloc(Value, fields.len);
                var filled: usize = 0;
                errdefer {
                    for (copied[0..filled]) |field| self.dropStorage(field);
                    self.objects.free(copied);
                }
                for (fields, copied) |field, *slot| {
                    slot.* = try self.copyFrom(source, field);
                    filled += 1;
                }
                return Value.ofStruct(copied);
            },
            // A String is a value, and the copy owns its own bytes:
            // `copy xs` of a `List(String)` used to hand back a second
            // container sharing the first's (docs/STRINGS.md).
            else => return self.ownValue(held),
        }
    }
};

/// Flatten a multi-dimensional index against the array's dims;
/// null when any index is out of range.
pub fn flattenIndex(dims: []const i64, indices: []const Value) ?usize {
    var flat: usize = 0;
    for (dims, indices) |size, held| {
        const index = held.asLong();
        if (index < 0 or index >= size) return null;
        flat = flat * @as(usize, @intCast(size)) + @as(usize, @intCast(index));
    }
    return flat;
}
